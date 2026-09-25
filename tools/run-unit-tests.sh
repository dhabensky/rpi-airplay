#!/bin/bash
# Compiles and runs UxPlay/tests/*.c and tools/tests/*.c against the shared
# Dockerfile tooling image. A non-zero exit here (an assert() firing, or a
# segfault) IS the fail signal -- `make unit-tests` succeeding at all means
# every test passed. UxPlay/ is bind-mounted read-only and copied to a
# container-local path first, same reasoning as tools/build-uxplay.sh (keep
# the host's submodule checkout untouched).
set -euo pipefail
cd "$(dirname "$0")/.."

docker build -q -t rpi-airplay-buildenv -f Dockerfile .

docker run --rm \
  -v "$PWD/UxPlay":/mnt/UxPlay-src:ro \
  -v "$PWD/tools":/mnt/tools:ro \
  rpi-airplay-buildenv \
  bash -c '
    set -euo pipefail
    mkdir -p /src
    cp -r /mnt/UxPlay-src /src/UxPlay
    cd /src/UxPlay/tests

    # Zero dependencies beyond the one function under test -- no GStreamer,
    # no mocking. See the test file'"'"'s own header comment for why this matters.
    gcc -O0 -g -Wall -Wextra -Werror \
      -o /tmp/test_raop_conn_policy \
      test_raop_conn_policy.c ../lib/raop_conn_policy.c
    /tmp/test_raop_conn_policy

    gcc -O0 -g -Wall -Wextra -Werror \
      -o /tmp/test_netlink_addr_watch \
      test_netlink_addr_watch.c ../lib/netlink_addr_watch.c
    /tmp/test_netlink_addr_watch

    gcc -O0 -g -Wall -Wextra -Werror -pthread \
      -o /tmp/test_event_fifo_nonblocking \
      test_event_fifo_nonblocking.c ../event_fifo.c ../lib/logger.c
    /tmp/test_event_fifo_nonblocking

    # Pulls in llhttp verbatim (vendored, not -Wextra-clean) alongside the
    # function under test -- -Wall -Werror only, matching the gstreamer tests
    # below for the same reason.
    gcc -O0 -g -Wall -Werror \
      -o /tmp/test_on_url_protocol_bounds \
      test_on_url_protocol_bounds.c ../lib/http_request.c \
      ../lib/llhttp/api.c ../lib/llhttp/http.c ../lib/llhttp/llhttp.c \
      -I../lib -I../lib/llhttp
    /tmp/test_on_url_protocol_bounds

    # Pulls in renderers/audio_renderer.c directly (file-static symbols) --
    # needs GStreamer + the app plugin'"'"'s headers (gst/app/gstappsrc.h).
    gcc -O0 -g -Wall \
      -o /tmp/test_bus_callback_null_renderer \
      test_bus_callback_null_renderer.c \
      $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0)
    /tmp/test_bus_callback_null_renderer

    # Pulls in renderers/video_renderer.c directly (file-static symbols) --
    # needs gstreamer-video-1.0 for gst/video/videooverlay.h etc.
    gcc -O0 -g -Wall \
      -o /tmp/test_release_display_epoch_guard \
      test_release_display_epoch_guard.c \
      $(pkg-config --cflags --libs gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0)
    /tmp/test_release_display_epoch_guard

    # The wrapper repo'"'"'s own tools/, not the UxPlay fork: uxplay-menu'"'"'s
    # event-FIFO drain and /etc/default/uxplay parsing.
    cd /mnt/tools/tests
    gcc -O0 -g -Wall -Wextra -Werror \
      -o /tmp/test_uxplay_menu_parse \
      test_uxplay_menu_parse.c ../uxplay-menu-parse.c
    /tmp/test_uxplay_menu_parse
  '
