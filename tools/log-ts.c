/* Prefixes every log line with a UTC ISO-8601 millisecond timestamp
 * (2026-09-22T01:39:45.894) on stdout.
 *
 * Usage: log-ts -- <command> [args...]   runs <command>, merging its
 *   stdout+stderr through the prefixer, and exits the way it did (same
 *   exit code, or death by the same signal).
 *        <producer> | log-ts            plain stdin filter.
 *
 * uxplay.service (image-builder/files/etc/systemd/system/uxplay.service)
 * uses the first form, so /var/log/uxplay.log carries timestamps without a
 * second log file and without a separately killable filter process that
 * could leave the service alive but mute. Output is line-buffered, so a
 * `tail -F` consumer sees each line as soon as the producer writes it.
 */
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static const int quit_signals[] = {SIGTERM, SIGINT, SIGHUP};
#define N_QUIT_SIGNALS ((int) (sizeof quit_signals / sizeof quit_signals[0]))

/* 0 on clean EOF, 1 on any read or write error: a log we cannot write has
 * to become a visible failure rather than silently vanishing. */
static int timestamp_stream(FILE *in) {
    char *line = NULL;
    size_t cap = 0;
    ssize_t len;
    int rc = 0;

    while ((len = getline(&line, &cap, in)) > 0) {
        struct timespec now;
        struct tm utc;
        char stamp[32];

        clock_gettime(CLOCK_REALTIME, &now);
        gmtime_r(&now.tv_sec, &utc);
        strftime(stamp, sizeof stamp, "%Y-%m-%dT%H:%M:%S", &utc);
        printf("%s.%03ld ", stamp, now.tv_nsec / 1000000L);
        /* fwrite, not printf: the line is passed through byte-for-byte. */
        fwrite(line, 1, (size_t) len, stdout);
        /* One ferror check covers both calls above -- any failure latches. */
        if (ferror(stdout)) {
            rc = 1;
            break;
        }
    }
    if (ferror(in)) rc = 1;
    if (fflush(stdout) != 0) rc = 1;
    free(line);
    return rc;
}

/* Runs argv as a child whose stdout+stderr feed timestamp_stream, then
 * reproduces how the child ended so a supervisor above (systemd's
 * Restart=) sees exactly what running the child directly would show. */
static int supervise(char **argv) {
    int fds[2];
    if (pipe(fds) != 0) {
        perror("log-ts: pipe");
        return 1;
    }

    pid_t child = fork();
    if (child < 0) {
        perror("log-ts: fork");
        return 1;
    }
    if (child == 0) {
        /* SIG_IGN is inherited across exec -- restore defaults so the child
         * still dies on SIGTERM the way an unwrapped process would. */
        for (int i = 0; i < N_QUIT_SIGNALS; i++) signal(quit_signals[i], SIG_DFL);
        close(fds[0]);
        if (dup2(fds[1], STDOUT_FILENO) < 0 || dup2(fds[1], STDERR_FILENO) < 0) _exit(127);
        if (fds[1] > STDERR_FILENO) close(fds[1]);
        execvp(argv[0], argv);
        fprintf(stderr, "log-ts: exec %s: %s\n", argv[0], strerror(errno));
        _exit(127);
    }

    close(fds[1]);
    FILE *in = fdopen(fds[0], "r");
    int rc = 1;
    if (!in) {
        perror("log-ts: fdopen");
    } else {
        rc = timestamp_stream(in);
        fclose(in);
    }
    /* Never keep the child running once its output is going nowhere. */
    if (rc != 0) kill(child, SIGTERM);

    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) { }
    if (rc != 0) return rc;
    if (WIFSIGNALED(status)) {
        signal(WTERMSIG(status), SIG_DFL);
        raise(WTERMSIG(status));
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc == 1) return timestamp_stream(stdin);
    if (argc < 3 || strcmp(argv[1], "--") != 0) {
        fprintf(stderr, "usage: %s [-- <command> [args...]]\n", argv[0]);
        return 2;
    }
    /* Outlive a SIGTERM aimed at the whole service so the child's shutdown
     * lines still get timestamped and written. */
    for (int i = 0; i < N_QUIT_SIGNALS; i++) signal(quit_signals[i], SIG_IGN);
    return supervise(argv + 2);
}
