"""Guards against the DRM primary plane's backing buffer (/dev/fb0)
getting re-dirtied by console text SOMETIME during a real boot, well
after zero-fb0 (uxplay.service's ExecStartPre) already ran once, early.
Whatever's on fb0 becomes visible wherever nothing else covers the
screen -- the TV's pillarbox margins for non-16:9 content.

Needs a REAL boot: -replay never goes through one, so this reboots the
actual device. Does not use uxplay_binary/pi_uxplay_deployed -- the bug
is in image-builder/files/ (zero-fb0, the systemd unit's ExecStartPre)
and customize-boot.sh's cmdline.txt/config.txt, not in the uxplay_debug
binary itself, so there is no "old ref" to build and compare here; this
test only makes sense against whatever image is currently flashed.
"""
from __future__ import annotations

import time

import pytest

SETTLE_S = 90  # generous margin over how long console cursor / late boot messages take to settle on a Pi 3B+


@pytest.mark.pi_hardware
def test_fb0_stays_black_through_real_boot(pi_target, trace_dir):
    from perfetto_trace import Trace

    trace = Trace(process_name="fb0-stays-black")
    t0 = time.monotonic()

    # The reboot command itself always reports a dbus-org.freedesktop.login1
    # error on this device (a broken-but-harmless unit, see PROGRESS.md) --
    # the reboot proceeds regardless.
    pi_target.ssh("reboot", timeout=10)
    trace.add_instant("boot", "reboot requested", time.monotonic() - t0)

    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and pi_target.ping_once():
        time.sleep(1)
    trace.add_instant("boot", "went down", time.monotonic() - t0)

    assert pi_target.wait_reachable(timeout_s=90), "device never came back up on the network after reboot"
    trace.add_instant("boot", "network reachable again", time.monotonic() - t0)

    assert pi_target.wait_service_active(timeout_s=120), "uxplay.service never became active after reboot"
    trace.add_instant("boot", "uxplay.service active", time.monotonic() - t0)

    time.sleep(SETTLE_S)
    trace.add_instant("boot", f"settled ({SETTLE_S}s)", time.monotonic() - t0)

    r = pi_target.ssh("cmp /dev/fb0 /dev/zero 2>&1", timeout=30)
    fb0_diff = r.stdout.strip()
    trace.add_instant("fb0", "checked", time.monotonic() - t0, {"cmp_output": fb0_diff or "(identical)"})
    trace.write(str(trace_dir / "fb0_stays_black.json"))

    assert "differ" not in fb0_diff, (
        f"/dev/fb0 has non-zero content well after boot ({fb0_diff}) -- shows through the TV's pillarbox "
        f"margins during mirroring. Pull a copy: tools/pissh -g /dev/fb0 "
        f"build/fb0-fail.raw && ffmpeg -f rawvideo -pixel_format rgb565le -video_size 1920x1080 "
        f"-i build/fb0-fail.raw -frames:v 1 build/fb0-fail.png"
    )
