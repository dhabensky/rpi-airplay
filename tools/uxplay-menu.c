/* Resident supervisor for the idle menu screen (uxplay-menu.service).
 * Attempts a repaint when uxplay reports a session end on its -efifo event
 * channel, when /etc/default/uxplay is edited, and periodically (IP/SSID
 * can change). It is also uxplay's only source of overscan margins, pushed
 * into the -ofifo channel at startup, on every edit, and again whenever
 * uxplay recreates that FIFO. Rendering itself stays in
 * /usr/local/bin/uxplay-menu-render, which is also what decides whether
 * painting is safe right now (it refuses while uxplay still holds any ESTAB
 * connection to a client).
 *
 * One poll() loop over the event FIFO, an inotify fd and two timerfds;
 * every fd is non-blocking and every wait is bounded, so no consumer or
 * producer of these FIFOs can ever stall this process.
 *
 * Usage: uxplay-menu      (paths are compile-time, see the defines below;
 *                         intervals default to the values below and can be
 *                         overridden per UXPLAY_MENU_*, see tunables_init)
 */
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include "uxplay-menu-parse.h"

/* Outside uxplay.service's RuntimeDirectory=uxplay on purpose: systemd
 * deletes and recreates /run/uxplay around every uxplay restart, and a FIFO
 * replaced at this path is unrecoverable here (see UxPlay/event_fifo.h). */
#define EVENT_FIFO_PATH "/run/uxplay-events.fifo"
/* uxplay writes the event FIFO as this group; /etc/tmpfiles.d/uxplay.conf
 * normally creates it before either process starts. */
#define EVENT_FIFO_GROUP "uxplay"
/* systemd's RuntimeDirectory=uxplay destroys and recreates this directory
 * around every uxplay restart, so both the directory and the FIFO in it are
 * watched to re-seed the margins afterwards. */
#define OFIFO_DIR "/run/uxplay"
#define OFIFO_NAME "overscan.fifo"
#define OFIFO_PATH OFIFO_DIR "/" OFIFO_NAME
#define RUN_DIR "/run"
#define RUN_OFIFO_DIR_NAME "uxplay"
#define CONF_DIR "/etc/default"
#define CONF_NAME "uxplay"
/* Watched the way RUN_DIR is, so CONF_DIR being replaced wholesale is
 * recovered from at once instead of at the next refresh. */
#define ETC_DIR "/etc"
#define CONF_DIR_NAME "default"
#define CONF_PATH CONF_DIR "/" CONF_NAME
#define RENDER_CMD "/usr/local/bin/uxplay-menu-render"

/* Production values, each overridable from the environment by
 * tunables_init() so a test need not wait out a five-minute interval. */
static long refresh_secs = 300;
/* Collapses a burst of triggers (several inotify events per editor save)
 * into one repaint. */
static long settle_ms = 250;
/* Measured on the lost-connection path: with the client still holding its
 * RTSP control connection, the guard still sees an ESTAB socket ~0.3s after
 * the event and skips the repaint; that socket is gone by ~1.4s. */
static long retry_ms = 1000;
/* uxplay creates its -ofifo and opens its own end some way into startup, so
 * a seeding push has to outlast that; a landed push ends the retries. */
static long overscan_retry_ms = 1000;
static long overscan_tries_max = 15;
/* A renderer that never finishes would stall every later trigger, so it is
 * killed well past a real repaint (measured on the Pi: 348-360ms). */
static long child_limit_ms = 30000;
/* fork() failures are transient (EAGAIN), so back the repaint off instead
 * of spinning on it. */
#define SPAWN_RETRY_MS 1000
#define CHILD_POLL_MS 100

static void logmsg(const char *fmt, ...) {
    va_list ap;
    fprintf(stderr, "uxplay-menu: ");
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long) ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/* A rejected override keeps the default, and every interval has a minimum of
 * 1, so none can collapse to zero and busy-loop this process. */
static void tunable(const char *name, long *value, long min, long max) {
    const char *s = getenv(name);
    if (!s || !*s) {
        return;
    }
    long v;
    if (tunable_parse(s, min, max, &v) != 0) {
        logmsg("ignoring %s=\"%s\": want an integer %ld..%ld, keeping %ld",
               name, s, min, max, *value);
        return;
    }
    logmsg("override in effect: %s=%ld (default %ld)", name, v, *value);
    *value = v;
}

/* Read once at startup; uxplay-menu.service sets none of these. */
static void tunables_init(void) {
    tunable("UXPLAY_MENU_REFRESH_SECS", &refresh_secs, 1, 86400);
    tunable("UXPLAY_MENU_SETTLE_MS", &settle_ms, 1, 60000);
    tunable("UXPLAY_MENU_RETRY_MS", &retry_ms, 1, 60000);
    tunable("UXPLAY_MENU_OVERSCAN_RETRY_MS", &overscan_retry_ms, 1, 60000);
    /* 0 is a real setting here, the same "push once, do not retry" this code
     * asks for itself on an edit-triggered push. */
    tunable("UXPLAY_MENU_OVERSCAN_TRIES", &overscan_tries_max, 0, 1000);
    tunable("UXPLAY_MENU_CHILD_LIMIT_MS", &child_limit_ms, 1, 600000);
}

/* --- sd_notify, by hand: one datagram to $NOTIFY_SOCKET, so this tool needs
 * no libsystemd link for a protocol that is a single sendmsg(). --- */

static int notify_fd = -1;
static struct sockaddr_un notify_addr;
static socklen_t notify_addr_len;

static void notify_init(void) {
    const char *socket_path = getenv("NOTIFY_SOCKET");
    if (!socket_path || !*socket_path) {
        return;
    }
    size_t len = strlen(socket_path);
    if (len >= sizeof(notify_addr.sun_path)) {
        logmsg("NOTIFY_SOCKET path too long, liveness notifications disabled");
        return;
    }
    notify_fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (notify_fd < 0) {
        logmsg("socket(AF_UNIX) failed: %s", strerror(errno));
        return;
    }
    memset(&notify_addr, 0, sizeof(notify_addr));
    notify_addr.sun_family = AF_UNIX;
    memcpy(notify_addr.sun_path, socket_path, len);
    /* "@" means the abstract namespace, whose names start with a NUL. */
    if (notify_addr.sun_path[0] == '@') {
        notify_addr.sun_path[0] = '\0';
    }
    notify_addr_len = (socklen_t) (offsetof(struct sockaddr_un, sun_path) + len);
}

static void notify_send(const char *state) {
    if (notify_fd < 0) {
        return;
    }
    if (sendto(notify_fd, state, strlen(state), MSG_NOSIGNAL,
               (struct sockaddr *) &notify_addr, notify_addr_len) < 0) {
        logmsg("notify \"%s\" failed: %s", state, strerror(errno));
    }
}

/* --- setup --- */

static int event_fifo_open(void) {
    if (mkfifo(EVENT_FIFO_PATH, 0660) < 0) {
        if (errno != EEXIST) {
            logmsg("mkfifo %s failed: %s", EVENT_FIFO_PATH, strerror(errno));
            return -1;
        }
    } else {
        /* mkfifo()'s mode is masked by the umask, and uxplay opens this
         * read-write; group ownership is what lets it. */
        struct group *gr = getgrnam(EVENT_FIFO_GROUP);
        if (chmod(EVENT_FIFO_PATH, 0660) < 0) {
            logmsg("chmod 0660 %s failed: %s", EVENT_FIFO_PATH, strerror(errno));
        }
        if (!gr) {
            logmsg("no %s group: %s stays root-only and uxplay cannot write it",
                   EVENT_FIFO_GROUP, EVENT_FIFO_PATH);
        } else if (chown(EVENT_FIFO_PATH, 0, gr->gr_gid) < 0) {
            logmsg("chown root:%s %s failed: %s",
                   EVENT_FIFO_GROUP, EVENT_FIFO_PATH, strerror(errno));
        }
    }
    /* O_RDWR keeps a write end open here too, so the FIFO never reports EOF
     * while uxplay is stopped and buffered events survive its restart. */
    int fd = open(EVENT_FIFO_PATH, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        logmsg("open %s failed: %s", EVENT_FIFO_PATH, strerror(errno));
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) < 0 || !S_ISFIFO(st.st_mode)) {
        logmsg("%s is not a fifo", EVENT_FIFO_PATH);
        close(fd);
        return -1;
    }
    return fd;
}

static int wd_conf = -1;
static int wd_etc = -1;
static int wd_run = -1;
static int wd_ofifo_dir = -1;

static void ofifo_dir_watch(int fd) {
    wd_ofifo_dir = inotify_add_watch(fd, OFIFO_DIR, IN_CREATE | IN_MOVED_TO);
}

/* A watch dies with its directory, so wd_etc calls this again the moment
 * CONF_DIR reappears (the periodic refresh is only the backstop). */
static int conf_dir_watch(int fd) {
    wd_conf = inotify_add_watch(fd, CONF_DIR,
                                IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE |
                                IN_MOVE_SELF);
    return wd_conf;
}

/* Watches directories, not files: the config's inode is replaced by any
 * editor that saves by rename, and uxplay's -ofifo by every uxplay start. */
static int conf_watch_open(void) {
    int fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (fd < 0) {
        logmsg("inotify_init1 failed: %s", strerror(errno));
        return -1;
    }
    if (conf_dir_watch(fd) < 0) {
        logmsg("inotify_add_watch %s failed: %s", CONF_DIR, strerror(errno));
        close(fd);
        return -1;
    }
    wd_etc = inotify_add_watch(fd, ETC_DIR, IN_CREATE | IN_MOVED_TO);
    if (wd_etc < 0) {
        logmsg("inotify_add_watch %s failed: %s", ETC_DIR, strerror(errno));
    }
    wd_run = inotify_add_watch(fd, RUN_DIR, IN_CREATE | IN_MOVED_TO);
    if (wd_run < 0) {
        logmsg("inotify_add_watch %s failed: %s", RUN_DIR, strerror(errno));
    }
    ofifo_dir_watch(fd);
    return fd;
}

static int timer_open(long interval_ms) {
    int fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (fd < 0) {
        logmsg("timerfd_create failed: %s", strerror(errno));
        return -1;
    }
    struct itimerspec spec;
    spec.it_value.tv_sec = interval_ms / 1000;
    spec.it_value.tv_nsec = (interval_ms % 1000) * 1000000;
    spec.it_interval = spec.it_value;
    if (timerfd_settime(fd, 0, &spec, NULL) < 0) {
        logmsg("timerfd_settime failed: %s", strerror(errno));
        close(fd);
        return -1;
    }
    return fd;
}

/* --- work --- */

static void drain_fd(int fd) {
    char buf[4096];
    while (read(fd, buf, sizeof(buf)) > 0) {
        ;
    }
}

#define WATCH_CONF  0x1
#define WATCH_OFIFO 0x2

/* Drains the inotify fd, returning which of the two watched things the
 * events actually named. */
static int watch_read(int fd) {
    char buf[4096] __attribute__((aligned(__alignof__(struct inotify_event))));
    int seen = 0;
    ssize_t n;

    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        for (char *p = buf; p < buf + n; ) {
            const struct inotify_event *ev = (const struct inotify_event *) p;
            const char *name = ev->len > 0 ? ev->name : "";
            if (ev->wd == wd_conf && strcmp(name, CONF_NAME) == 0) {
                seen |= WATCH_CONF;
            } else if (ev->wd == wd_etc && strcmp(name, CONF_DIR_NAME) == 0) {
                /* CONF_DIR is back: re-arm and re-read it now. */
                if (wd_conf < 0) {
                    conf_dir_watch(fd);
                }
                seen |= WATCH_CONF;
            } else if (ev->wd == wd_run && strcmp(name, RUN_OFIFO_DIR_NAME) == 0) {
                /* The FIFO lands in here moments later; watch for it and let
                 * the push's own retries cover the gap. */
                ofifo_dir_watch(fd);
                seen |= WATCH_OFIFO;
            } else if (ev->wd == wd_ofifo_dir && strcmp(name, OFIFO_NAME) == 0) {
                seen |= WATCH_OFIFO;
            } else if (ev->wd == wd_ofifo_dir && (ev->mask & IN_IGNORED)) {
                wd_ofifo_dir = -1;
            } else if (ev->wd == wd_conf && (ev->mask & (IN_IGNORED | IN_MOVE_SELF))) {
                /* CONF_DIR was deleted or moved aside; the ETC_DIR watch
                 * re-arms this one as soon as the path is back, so the deaf
                 * window is the settle delay and not a refresh period. */
                if (ev->mask & IN_MOVE_SELF) {
                    inotify_rm_watch(fd, wd_conf);
                }
                wd_conf = -1;
            }
            p += sizeof(struct inotify_event) + ev->len;
        }
    }
    return seen;
}

/* One log line per failure episode: a uxplay that keeps restarting would
 * otherwise get one per retry, indefinitely. */
static int overscan_fail_logged;

/* uxplay's margins come from here alone, so this is both the seeding push
 * and the live update. Returns 0 once the line is in the FIFO. */
static int overscan_push(void) {
    char line[64];
    if (overscan_compose(CONF_PATH, line, sizeof(line)) < 0) {
        logmsg("could not compose an overscan update from %s", CONF_PATH);
        return -1;
    }
    /* Non-blocking: before uxplay opens its end this fails with ENOENT or
     * ENXIO instead of waiting for it. */
    int fd = open(OFIFO_PATH, O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (!overscan_fail_logged) {
            logmsg("skipping overscan push \"%.*s\": %s (%s)",
                   (int) strlen(line) - 1, line, OFIFO_PATH, strerror(errno));
            overscan_fail_logged = 1;
        }
        return -1;
    }
    int pushed = 0;
    size_t len = strlen(line);
    if (write(fd, line, len) != (ssize_t) len) {
        if (!overscan_fail_logged) {
            logmsg("overscan push to %s failed: %s", OFIFO_PATH, strerror(errno));
            overscan_fail_logged = 1;
        }
    } else {
        logmsg("pushed overscan \"%.*s\" to %s", (int) len - 1, line, OFIFO_PATH);
        overscan_fail_logged = 0;
        pushed = 1;
    }
    close(fd);
    return pushed ? 0 : -1;
}

static long long repaint_at;
static long long overscan_at;
static long overscan_tries;
static int repaint_retries;
static const char *repaint_reason = "startup";

/* Keeps the earliest pending attempt, so repeated triggers coalesce without
 * pushing the repaint further away. */
static void repaint_schedule(long delay_ms, const char *reason) {
    long long when = now_ms() + delay_ms;
    if (repaint_at == 0 || when < repaint_at) {
        repaint_at = when;
    }
    repaint_reason = reason;
}

/* tries is how many further attempts a failed push may make, bounding the
 * wait for a uxplay that is starting but has not opened its -ofifo yet. An
 * edit gets 0: nothing re-pushes it until the next edit or uxplay restart. */
static void overscan_schedule(long delay_ms, long tries) {
    long long when = now_ms() + delay_ms;
    if (overscan_at == 0 || when < overscan_at) {
        overscan_at = when;
    }
    if (tries > overscan_tries) {
        overscan_tries = tries;
    }
}

static pid_t repaint_spawn(void) {
    pid_t pid = fork();
    if (pid == 0) {
        execl(RENDER_CMD, RENDER_CMD, (char *) NULL);
        _exit(127);
    }
    if (pid < 0) {
        logmsg("fork for %s failed: %s", RENDER_CMD, strerror(errno));
    } else {
        logmsg("repainting (%s)", repaint_reason);
    }
    return pid;
}

int main(void) {
    /* A vanished overscan reader must be an error return, not a death. */
    signal(SIGPIPE, SIG_IGN);

    tunables_init();
    int event_fd = event_fifo_open();
    int conf_fd = conf_watch_open();
    int refresh_fd = timer_open(refresh_secs * 1000L);
    if (event_fd < 0 || conf_fd < 0 || refresh_fd < 0) {
        return 1;
    }

    notify_init();
    int watchdog_fd = -1;
    const char *watchdog_usec = getenv("WATCHDOG_USEC");
    if (notify_fd >= 0 && watchdog_usec) {
        long long usec = atoll(watchdog_usec);
        if (usec > 0) {
            /* Half the interval: one lost ping must not trip the watchdog. */
            watchdog_fd = timer_open((long) (usec / 2000));
        }
    }
    if (watchdog_fd < 0) {
        logmsg("no watchdog configured (WATCHDOG_USEC=%s)",
               watchdog_usec ? watchdog_usec : "unset");
    }
    notify_send("READY=1");

    /* Events buffered before this process attached describe history, not the
     * present, so they only get discarded here -- the renderer's own check
     * is what keeps the first repaint off a live session. */
    struct event_drain drain = {{0}, 0};
    enum session_state stale = event_drain_read(&drain, event_fd);
    logmsg("started; buffered event history ended at %s",
           stale == SESSION_BEGIN ? "session-begin" :
           stale == SESSION_END ? "session-end" : "no complete line");
    overscan_schedule(0, overscan_tries_max);
    repaint_schedule(0, "startup");

    pid_t child = -1;
    long long child_started = 0;

    for (;;) {
        struct pollfd fds[4] = {{0, 0, 0}};
        int nfds = 0;
        int idx_event = nfds; fds[nfds].fd = event_fd;   fds[nfds++].events = POLLIN;
        int idx_conf = nfds;  fds[nfds].fd = conf_fd;    fds[nfds++].events = POLLIN;
        int idx_refresh = nfds; fds[nfds].fd = refresh_fd; fds[nfds++].events = POLLIN;
        int idx_watchdog = -1;
        if (watchdog_fd >= 0) {
            idx_watchdog = nfds; fds[nfds].fd = watchdog_fd; fds[nfds++].events = POLLIN;
        }

        long long due = repaint_at;
        if (overscan_at && (due == 0 || overscan_at < due)) {
            due = overscan_at;
        }
        int timeout = -1;
        if (due) {
            long long wait_ms = due - now_ms();
            timeout = wait_ms > 0 ? (int) wait_ms : 0;
        }
        if (child > 0 && (timeout < 0 || timeout > CHILD_POLL_MS)) {
            timeout = CHILD_POLL_MS;
        }
        int ready = poll(fds, nfds, timeout);
        if (ready < 0 && errno != EINTR) {
            logmsg("poll failed: %s", strerror(errno));
            return 1;
        }
        /* revents is only meaningful for a successful poll(); the timed work
         * below still runs on an EINTR or a timeout. */
        if (ready > 0) {
            if (fds[idx_event].revents & POLLIN) {
                if (event_drain_read(&drain, event_fd) == SESSION_END) {
                    repaint_retries = 1;
                    repaint_schedule(settle_ms, "session end");
                }
            }
            if (fds[idx_conf].revents & POLLIN) {
                int seen = watch_read(conf_fd);
                if (seen & WATCH_CONF) {
                    /* One save can arrive as several inotify events; settle
                     * first so uxplay gets one update and the menu one
                     * repaint. */
                    overscan_schedule(settle_ms, 0);
                    repaint_schedule(settle_ms, "config change");
                }
                if (seen & WATCH_OFIFO) {
                    overscan_schedule(settle_ms, overscan_tries_max);
                }
            }
            if (fds[idx_refresh].revents & POLLIN) {
                drain_fd(refresh_fd);
                /* A re-armed watch means CONF_DIR is back, so re-read what is
                 * in it now; the repaint below covers the menu text. */
                if (wd_conf < 0 && conf_dir_watch(conf_fd) >= 0) {
                    overscan_schedule(settle_ms, 0);
                }
                repaint_schedule(0, "periodic refresh");
            }
            if (idx_watchdog >= 0 && (fds[idx_watchdog].revents & POLLIN)) {
                drain_fd(watchdog_fd);
                notify_send("WATCHDOG=1");
            }
        }

        if (overscan_at && now_ms() >= overscan_at) {
            overscan_at = 0;
            if (overscan_push() == 0) {
                overscan_tries = 0;
            } else if (overscan_tries > 0) {
                overscan_tries--;
                overscan_at = now_ms() + overscan_retry_ms;
            }
        }

        if (child > 0) {
            int status = 0;
            pid_t reaped = waitpid(child, &status, WNOHANG);
            if (reaped == child || (reaped < 0 && errno != EINTR)) {
                /* A renderer that never succeeds is otherwise invisible: the
                 * daemon stays healthy and only logs the optimistic attempt. */
                if (reaped == child && WIFSIGNALED(status)) {
                    logmsg("%s killed by signal %d", RENDER_CMD, WTERMSIG(status));
                } else if (reaped == child && WIFEXITED(status) && WEXITSTATUS(status) != 0) {
                    logmsg("%s exited %d", RENDER_CMD, WEXITSTATUS(status));
                } else if (reaped < 0) {
                    logmsg("waitpid for %s failed: %s", RENDER_CMD, strerror(errno));
                }
                child = -1;
                if (repaint_retries > 0) {
                    repaint_retries--;
                    repaint_schedule(retry_ms, "session end, retry");
                }
            } else if (now_ms() - child_started > child_limit_ms) {
                /* A wedged renderer would silently stop every later repaint
                 * while this process still looks healthy. */
                logmsg("%s exceeded %ldms, killing it", RENDER_CMD, child_limit_ms);
                kill(child, SIGKILL);
            }
        }
        if (child < 0 && repaint_at && now_ms() >= repaint_at) {
            pid_t spawned = repaint_spawn();
            if (spawned > 0) {
                repaint_at = 0;
                child = spawned;
                child_started = now_ms();
            } else {
                repaint_at = now_ms() + SPAWN_RETRY_MS;
            }
        }
    }
}
