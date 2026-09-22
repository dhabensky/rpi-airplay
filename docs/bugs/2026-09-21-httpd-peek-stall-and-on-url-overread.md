# httpd: a stalled peek wedges every connection; `on_url()` reads past the fed buffer

Status: **RESOLVED (2026-09-21).** Both defects fixed, unit- and
protocol-tested, deployed live (`b2dcc44d1f67…`). Found while chasing
"mirroring doesn't stop" — which turned out to be a client-side macOS
issue instead (`2026-09-22-stop-mirroring-not-honored-client-side.md`).
These are real, independent, latent defects, not that symptom's cause.

## Defect 1 — head-of-line blocking in `httpd_thread()`

`httpd.c`'s single serial thread peeks the first 8 bytes of every new
request to recognise reverse-HTTP responses (`HTTP/1.1`, `EVENT/1.0`),
which must bypass the llhttp parser. That peek was a captive
`while (readstart < 8)` loop over a **blocking socket with no timeout**:
a client that sent a few bytes and went silent held the loop — and with
it every other connection's request — indefinitely.

Fix (`lib/httpd.c`):
- `SO_RCVTIMEO` (5ms) on every accepted socket in
  `httpd_accept_connection()`, so a single `recv()` can never block
  forever.
- The captive loop became **one `recv()` attempt per `select()` pass**,
  with partial progress persisted on the connection (`peek_buf`,
  `peek_len`, `peek_retries_left`) instead of on the stack, and a retry
  budget (`HTTPD_PEEK_MAX_RETRIES`) reset on any forward progress. A
  stalled peer now delays only itself.

## Defect 2 — `on_url()` reads 8 bytes past the fed buffer

`on_url()` (`lib/http_request.c`) copied the protocol string with
`strncpy(request->protocol, at + length + 1, 8)` — unconditionally, with
no check that those 8 bytes are inside the buffer llhttp was actually
fed. **This is upstream UxPlay's own code** (upstream `23030f1`, present
in this fork's base `df67c212a4`), not something the fork introduced.

It was latent only because the old captive loop happened to read up to
1024 bytes at once, so in practice the whole request line — protocol
string included — was already in the buffer. Defect 1's fix removed that
accident, and the read started landing in stale memory: a request line
completing within the peeked bytes (e.g. `GET / RTSP/1.0`, or any
fragmented continuation) yielded a corrupted protocol string, i.e. a real
heap/stack over-read.

Fix (`lib/http_request.c`): `http_request_add_data()` records
`feed_end = data + datalen` immediately before `llhttp_execute()`, and
`on_url()` copies at most `feed_end - (at + length + 1)` bytes, never
more than 8, and nothing at all when that is `<= 0`. Since `on_url()` can
only fire synchronously inside `llhttp_execute()`, `feed_end` is always
the current call's buffer.

## How the fix was reached (5 rounds, 4 independent reviews)

Worth recording because four of the five rounds were wrong in an
instructive way:

1. `SO_RCVTIMEO` + non-captive peek loop (defect 1).
2. Review: the restructuring hard-capped the peek at `8 - peek_len` and
   hardcoded `recv_datalen = 8`, which broke `on_url()` — reproduced, not
   theorised.
3. Split the `peek_len == 0` (read up to 1024) and `peek_len > 0` paths.
   Review: corruption still reachable on the fragmented-continuation
   path, with an 8-byte `peek_buf`.
4. `peek_buf` grown to `HTTPD_BUFFER_SIZE` (1024, shared with
   `httpd_thread()`'s own `buffer`), `recv_datalen` set to the true
   accumulated count. This made the symptom unreachable through
   `httpd.c` — but left the real defect in place.
5. Bounded `on_url()` itself (defect 2). Verified with ASan/UBSan: the
   round-4 tree aborts with a genuine heap-buffer-overflow, round 5 is
   clean across 56 runs; plus 75 runs on real Pi hardware, zero failures.

The lesson matching this project's pattern: rounds 1-4 kept moving the
conditions under which a defect was reachable, each looking verified in
isolation. Only round 5 removed the defect.

## Tests added

- `UxPlay/tests/test_on_url_protocol_bounds.c` — `make unit-tests`, 14
  split points across the request line.
- `UxPlay/tools/synthetic-client.cpp` — new modes `peekstall`,
  `shorturl`, `shorturlfrag`, `shorturlsweep <split> [N]`, driving the
  real server over loopback from a genuinely separate process.
- `tools/pytest/test_httpd_peek_stall.py`,
  `test_httpd_short_url_protocol.py`,
  `test_httpd_short_url_frag_protocol.py`,
  `test_httpd_short_url_sweep_protocol.py` — Docker-only, no Pi needed.
  Each module's docstring records which earlier revision it was confirmed
  to fail against, per this project's bug-fix protocol.
