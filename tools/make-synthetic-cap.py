#!/usr/bin/env python3
# Packs a raw H.264 Annex-B elementary stream into UxPlay's .cap capture
# format (see uxplay.cpp's cap_write()/replay_feeder()):
#   [type:1][mono_ns:8][ntp:8][len:4][data:len]
# type 'C' = ct header (codec type in the ntp field, e.g. 8 = H264)
# type 'V' = one video access unit (frame)
#
# Exists because real .cap files can only be recorded from an actual live
# AirPlay mirroring session (see PROGRESS.md's "capture/replay harness"
# section) -- there's no way to trigger one from a script (no CLI/OSS
# AirPlay mirror sender exists, and macOS Control Center resists both UI
# automation and the private AVOutputContext/AVOutputDeviceMenuController
# APIs). This synthesizes a valid, decodable .cap purely from any H.264
# elementary stream (e.g. one generated locally by ffmpeg), letting
# tools/test-reconnect-e2e.sh exercise the real reconnect code path
# (UX_RECONNECT_MODE=real) on real Pi hardware fully autonomously.
#
# Usage: make-synthetic-cap.py <in.h264> <out.cap> [fps]
import struct
import sys

def find_nals(data):
    # yields (nal_type, start_offset_incl_startcode, end_offset)
    i = 0
    starts = []
    while i < len(data) - 3:
        if data[i] == 0 and data[i+1] == 0 and data[i+2] == 1:
            starts.append((i, 3))
            i += 3
        elif i < len(data) - 4 and data[i] == 0 and data[i+1] == 0 and data[i+2] == 0 and data[i+3] == 1:
            starts.append((i, 4))
            i += 4
        else:
            i += 1
    nals = []
    for idx, (offset, sc_len) in enumerate(starts):
        nal_start = offset
        nal_type = data[offset + sc_len] & 0x1F
        nal_end = starts[idx + 1][0] if idx + 1 < len(starts) else len(data)
        nals.append((nal_type, nal_start, nal_end))
    return nals

def group_frames(data):
    # Accumulate NALs; a VCL NAL (type 1 = non-IDR slice, 5 = IDR slice)
    # completes the current access unit. Leading non-VCL NALs (7=SPS,
    # 8=PPS) accumulate into whatever access unit follows them -- exactly
    # matching a real AirPlay sender's first frame (SPS+PPS+IDR together,
    # confirmed by extract_sps_pps()'s own expectation in uxplay.cpp).
    nals = find_nals(data)
    frames = []
    current = []
    for nal_type, start, end in nals:
        current.append((nal_type, start, end))
        if nal_type in (1, 5):
            frames.append(current)
            current = []
    if current:
        if frames:
            frames[-1] = frames[-1] + current
        else:
            frames.append(current)
    out = []
    for frame in frames:
        start = frame[0][1]
        end = frame[-1][2]
        out.append(data[start:end])
    return out

def main():
    if len(sys.argv) < 3:
        print(f"usage: {sys.argv[0]} <in.h264> <out.cap> [fps=10]", file=sys.stderr)
        sys.exit(1)
    h264_path, cap_path = sys.argv[1], sys.argv[2]
    fps = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
    with open(h264_path, "rb") as f:
        data = f.read()
    frames = group_frames(data)
    print(f"parsed {len(frames)} access units", file=sys.stderr)

    frame_interval_ns = int(1_000_000_000 / fps)
    with open(cap_path, "wb") as out:
        # 'C' record: ct=8 (H264), stored in the ntp field per cap_write()'s
        # own format comment ("'C' ct header (ct in ntp field)")
        out.write(struct.pack("<cQQI", b"C", 0, 8, 0))
        t = 0
        for fr in frames:
            out.write(struct.pack("<cQQI", b"V", t, 0, len(fr)))
            out.write(fr)
            t += frame_interval_ns
    print(f"wrote {cap_path}: {len(frames)} video frames over {t/1e9:.1f}s", file=sys.stderr)

if __name__ == "__main__":
    main()
