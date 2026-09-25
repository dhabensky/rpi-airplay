/* Input-side helpers for uxplay-menu: what uxplay's event FIFO and
 * /etc/default/uxplay currently say. Split out from the daemon's poll loop
 * so tools/tests/test_uxplay_menu_parse.c can exercise them standalone.
 */
#ifndef UXPLAY_MENU_PARSE_H
#define UXPLAY_MENU_PARSE_H

#include <stddef.h>

/* UNKNOWN covers a drain that delivered no complete line, which cannot
 * distinguish "no session yet" from "history already consumed" -- and even a
 * non-empty drain's last line can lie, see UxPlay/event_fifo.h. */
enum session_state {
    SESSION_UNKNOWN = 0,
    SESSION_BEGIN,
    SESSION_END
};

/* Holds a line split across reads so no transition is lost mid-drain. */
struct event_drain {
    char partial[64];
    size_t partial_len;
};

/* Reads fd (expected non-blocking) until it has nothing more, returning the
 * last complete line's state. Unrecognized and over-long lines are ignored. */
enum session_state event_drain_read(struct event_drain *drain, int fd);

/* Parses one interval/budget override: a plain integer in min..max, nothing
 * else (no unit suffix, no whitespace, no partial parse). Returns 0 and sets
 * out on success, -1 otherwise, leaving out alone. */
int tunable_parse(const char *s, long min, long max, long *out);

/* Composes uxplay's -ofifo update line ("l r t b\n") from conf_path's
 * UXPLAY_OVERSCAN_{LEFT,RIGHT,TOP,BOTTOM}; a missing file, key or value
 * leaves that margin at 0. Returns 0, or -1 if out is too small. */
int overscan_compose(const char *conf_path, char *out, size_t out_len);

#endif /* UXPLAY_MENU_PARSE_H */
