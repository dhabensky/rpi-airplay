/* uxplay-menu decides when to repaint the idle menu from two inputs it does
 * not control: uxplay's event FIFO and /etc/default/uxplay. Both are parsed
 * here against a real FIFO and real files -- a drain that loses a line split
 * across reads, or a config read that mistakes a comment for a value, would
 * repaint over a live session or push the wrong overscan margins. Its
 * UXPLAY_MENU_* interval overrides are parsed here too: a half-parsed value
 * would either busy-loop the daemon or silently ignore what a test asked for. */
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../uxplay-menu-parse.h"

/* More than a pipe's 64KB capacity, so the backlog case really is the one a
 * daemon attaching late would find. */
#define BACKLOG_PAIRS 10000

static char fifo_path[128];
static char conf_path[128];

static void write_conf(const char *body) {
    FILE *f = fopen(conf_path, "w");
    assert(f);
    fputs(body, f);
    fclose(f);
}

static void expect_overscan(const char *body, const char *expected) {
    char out[64];
    write_conf(body);
    assert(overscan_compose(conf_path, out, sizeof(out)) == 0);
    if (strcmp(out, expected) != 0) {
        fprintf(stderr, "FAIL: config \"%s\" composed \"%s\", expected \"%s\"\n",
                body, out, expected);
        exit(1);
    }
}

/* The daemon keeps its default on a refusal, so "refused" must never come back
 * with a value written; kept is what it would have kept. */
static void expect_tunable_refused(const char *s, long min, long max) {
    long v = 4242;
    if (tunable_parse(s, min, max, &v) == 0 || v != 4242) {
        fprintf(stderr, "FAIL: tunable_parse(\"%s\", %ld, %ld) accepted it as %ld\n",
                s ? s : "(null)", min, max, v);
        exit(1);
    }
}

static void expect_tunable_ok(const char *s, long min, long max, long expected) {
    long v = 4242;
    if (tunable_parse(s, min, max, &v) != 0 || v != expected) {
        fprintf(stderr, "FAIL: tunable_parse(\"%s\", %ld, %ld) gave %ld, expected %ld\n",
                s, min, max, v, expected);
        exit(1);
    }
}

static void expect_state(struct event_drain *drain, int fd,
                        enum session_state expected, const char *what) {
    enum session_state got = event_drain_read(drain, fd);
    if (got != expected) {
        fprintf(stderr, "FAIL: %s drained %d, expected %d\n", what, got, expected);
        exit(1);
    }
}

static void write_all(int fd, const char *s) {
    size_t len = strlen(s);
    assert(write(fd, s, len) == (ssize_t) len);
}

int main(void) {
    snprintf(fifo_path, sizeof(fifo_path), "/tmp/uxplay-menu-test-%d-fifo", (int) getpid());
    snprintf(conf_path, sizeof(conf_path), "/tmp/uxplay-menu-test-%d-conf", (int) getpid());
    unlink(fifo_path);
    unlink(conf_path);
    alarm(60);

    /* --- the event channel --- */
    assert(mkfifo(fifo_path, 0600) == 0);
    /* O_RDWR exactly as the daemon opens it: no EOF when no writer is
     * attached, so a drain of nothing is a drain of nothing. */
    int fd = open(fifo_path, O_RDWR | O_NONBLOCK);
    assert(fd >= 0);
    struct event_drain drain = {{0}, 0};

    expect_state(&drain, fd, SESSION_UNKNOWN, "an untouched fifo");

    write_all(fd, "session-begin\n");
    expect_state(&drain, fd, SESSION_BEGIN, "a lone session-begin");

    write_all(fd, "session-end\n");
    expect_state(&drain, fd, SESSION_END, "a lone session-end");

    /* Nothing new since the last drain: history is gone, and that is NOT the
     * same answer as "idle" -- see UxPlay/event_fifo.h. */
    expect_state(&drain, fd, SESSION_UNKNOWN, "a second drain of the same fifo");

    /* Only the last complete line decides. */
    write_all(fd, "session-end\nsession-begin\nsession-end\nsession-begin\n");
    expect_state(&drain, fd, SESSION_BEGIN, "four queued transitions");

    /* A line split across writes must survive the drain that saw only its
     * first half, and must not be mistaken for a complete line. */
    write_all(fd, "session-begin\nsession-e");
    expect_state(&drain, fd, SESSION_BEGIN, "a truncated trailing line");
    write_all(fd, "nd\n");
    expect_state(&drain, fd, SESSION_END, "the completed split line");

    /* Unrecognized lines must not overwrite a real transition. */
    write_all(fd, "session-begin\nsession-paused\n\n");
    expect_state(&drain, fd, SESSION_BEGIN, "an unknown line after a begin");

    /* An over-long line is truncated into the carry buffer instead of running
     * past it, cannot smuggle a state in, and must not corrupt the line that
     * follows it. */
    char overlong[256];
    memset(overlong, 'x', sizeof(overlong) - 1);
    overlong[sizeof(overlong) - 1] = '\0';
    write_all(fd, overlong);
    expect_state(&drain, fd, SESSION_UNKNOWN, "an unterminated over-long line");
    assert(drain.partial_len == sizeof(drain.partial) - 1);
    write_all(fd, "\nsession-end\n");
    expect_state(&drain, fd, SESSION_END, "an over-long line then a session-end");

    /* The backlog a daemon starting after uxplay actually finds: more than a
     * pipe holds, drained in one call. */
    long queued = 0;
    for (long i = 0; i < BACKLOG_PAIRS; i++) {
        if (write(fd, "session-begin\nsession-end\n", 26) != 26) {
            break;
        }
        queued++;
    }
    assert(queued > 0);
    expect_state(&drain, fd, SESSION_END, "a full pipe of buffered history");
    close(fd);

    /* --- the config file --- */
    char out[64];

    /* No file at all is the same as every margin at its default. */
    unlink(conf_path);
    assert(overscan_compose(conf_path, out, sizeof(out)) == 0);
    assert(strcmp(out, "0 0 0 0\n") == 0);

    expect_overscan("UXPLAY_OVERSCAN_LEFT=16\nUXPLAY_OVERSCAN_RIGHT=17\n"
                    "UXPLAY_OVERSCAN_TOP=18\nUXPLAY_OVERSCAN_BOTTOM=19\n",
                    "16 17 18 19\n");
    /* The shipped file's real shape: comments, quotes, an unrelated key. */
    expect_overscan("# margins\nUXPLAY_OVERSCAN_LEFT=\"16\"\n"
                    "  UXPLAY_OVERSCAN_BOTTOM=4\n"
                    "UXPLAY_DISPLAY_NAME=\"Living Room TV\"\n",
                    "16 0 0 4\n");
    /* A commented-out assignment is not an assignment. */
    expect_overscan("#UXPLAY_OVERSCAN_LEFT=16\n# UXPLAY_OVERSCAN_TOP=8\n",
                    "0 0 0 0\n");
    /* A key must match exactly, not as a prefix. */
    expect_overscan("UXPLAY_OVERSCAN_LEFT_EDGE=16\nUXPLAY_OVERSCAN_TOPMOST=8\n",
                    "0 0 0 0\n");
    /* The key has to be followed by '=' specifically: a dropped '=' is not
     * an assignment, and the digits after it are not a margin. */
    expect_overscan("UXPLAY_OVERSCAN_LEFT 42\nUXPLAY_OVERSCAN_TOP=8\n", "0 0 8 0\n");
    /* Non-numeric or empty values fall back to the default rather than
     * composing a line uxplay would reject. */
    expect_overscan("UXPLAY_OVERSCAN_LEFT=\nUXPLAY_OVERSCAN_RIGHT=wide\n"
                    "UXPLAY_OVERSCAN_TOP=8\n",
                    "0 0 8 0\n");
    /* Later assignment wins, as the shell sourcing this file would do. */
    expect_overscan("UXPLAY_OVERSCAN_LEFT=4\nUXPLAY_OVERSCAN_LEFT=9\n", "9 0 0 0\n");
    expect_overscan("UXPLAY_OVERSCAN_LEFT=-4\n", "-4 0 0 0\n");

    /* --- the UXPLAY_MENU_* overrides --- */

    /* A valid override in range, and the bounds themselves. */
    expect_tunable_ok("5", 1, 86400, 5);
    expect_tunable_ok("1", 1, 86400, 1);
    expect_tunable_ok("86400", 1, 86400, 86400);

    /* Junk of every shape keeps the default rather than half-parsing: no
     * value, no digits, trailing text or unit, a float, whitespace. */
    expect_tunable_refused(NULL, 1, 60000);
    expect_tunable_refused("", 1, 60000);
    expect_tunable_refused("later", 1, 60000);
    expect_tunable_refused("5s", 1, 60000);
    expect_tunable_refused("5 ", 1, 60000);
    expect_tunable_refused(" 5", 1, 60000);
    expect_tunable_refused("2.5", 1, 60000);
    expect_tunable_refused("0x10", 1, 60000);
    expect_tunable_refused("99999999999999999999", 1, 60000);

    /* Out of range either way, including the values just outside it. */
    expect_tunable_refused("0", 1, 60000);
    expect_tunable_refused("-1", 1, 60000);
    expect_tunable_refused("60001", 1, 60000);

    /* Zero is a real setting for the overscan retry budget (push once, do not
     * retry) and the only knob whose minimum is 0. */
    expect_tunable_ok("0", 0, 1000, 0);
    expect_tunable_refused("-1", 0, 1000);

    /* A buffer that cannot hold the line must be reported, never truncated
     * into a different update. */
    write_conf("UXPLAY_OVERSCAN_LEFT=1000\nUXPLAY_OVERSCAN_RIGHT=1000\n"
               "UXPLAY_OVERSCAN_TOP=1000\nUXPLAY_OVERSCAN_BOTTOM=1000\n");
    char tiny[8];
    assert(overscan_compose(conf_path, tiny, sizeof(tiny)) == -1);

    unlink(fifo_path);
    unlink(conf_path);
    printf("PASS: event drain correct across %ld buffered transitions, split, "
           "unknown and over-long lines; overscan composed from 10 config shapes; "
           "17 UXPLAY_MENU_* override strings accepted or refused as intended\n",
           queued * 2);
    return 0;
}
