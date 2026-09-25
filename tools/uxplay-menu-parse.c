#include "uxplay-menu-parse.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EVENT_BEGIN "session-begin"
#define EVENT_END   "session-end"

enum session_state event_drain_read(struct event_drain *drain, int fd) {
    enum session_state last = SESSION_UNKNOWN;
    char buf[4096];
    ssize_t n;

    while ((n = read(fd, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < n; i++) {
            if (buf[i] != '\n') {
                if (drain->partial_len < sizeof(drain->partial) - 1) {
                    drain->partial[drain->partial_len++] = buf[i];
                }
                continue;
            }
            drain->partial[drain->partial_len] = '\0';
            drain->partial_len = 0;
            if (strcmp(drain->partial, EVENT_BEGIN) == 0) {
                last = SESSION_BEGIN;
            } else if (strcmp(drain->partial, EVENT_END) == 0) {
                last = SESSION_END;
            }
        }
    }
    return last;
}

int tunable_parse(const char *s, long min, long max, long *out) {
    if (!s || !*s) {
        return -1;
    }
    /* strtol would skip leading whitespace and accept the rest. */
    if (*s != '-' && (*s < '0' || *s > '9')) {
        return -1;
    }
    char *end;
    errno = 0;
    long v = strtol(s, &end, 10);
    if (errno != 0 || *end != '\0' || v < min || v > max) {
        return -1;
    }
    *out = v;
    return 0;
}

/* Matches one "KEY=value" shell assignment, tolerating leading whitespace
 * and a quoted value; anything else (comment, other key, non-integer) is
 * left for the caller's default. */
static int conf_int(const char *line, const char *key, int *out) {
    while (*line == ' ' || *line == '\t') {
        line++;
    }
    size_t key_len = strlen(key);
    if (strncmp(line, key, key_len) != 0 || line[key_len] != '=') {
        return -1;
    }
    const char *value = line + key_len + 1;
    if (*value == '"' || *value == '\'') {
        value++;
    }
    char *end;
    errno = 0;
    long parsed = strtol(value, &end, 10);
    if (end == value || errno != 0 || parsed < INT_MIN || parsed > INT_MAX) {
        return -1;
    }
    *out = (int) parsed;
    return 0;
}

int overscan_compose(const char *conf_path, char *out, size_t out_len) {
    static const char *const keys[4] = {
        "UXPLAY_OVERSCAN_LEFT", "UXPLAY_OVERSCAN_RIGHT",
        "UXPLAY_OVERSCAN_TOP", "UXPLAY_OVERSCAN_BOTTOM"
    };
    int margin[4] = {0, 0, 0, 0};

    FILE *f = fopen(conf_path, "r");
    if (f) {
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            for (int k = 0; k < 4; k++) {
                conf_int(line, keys[k], &margin[k]);
            }
        }
        fclose(f);
    }
    int n = snprintf(out, out_len, "%d %d %d %d\n",
                     margin[0], margin[1], margin[2], margin[3]);
    return (n > 0 && (size_t) n < out_len) ? 0 : -1;
}
