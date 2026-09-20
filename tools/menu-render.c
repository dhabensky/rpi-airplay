/* Renders text onto the DRM primary plane (/dev/fb0) via GStreamer's
 * textoverlay (Pango), for the idle menu screen -- image-builder/files/
 * usr/local/bin/uxplay-menu-render is the wrapper that composes the text
 * (device name/IP/SSID/instructions) and invokes this tool; this tool
 * knows nothing about where that text comes from, only how to paint it.
 * Same direct-buffer-write technique as zero-fb0 (see that script's
 * header for why this can't conflict with uxplay's own DRM-master
 * ownership) -- no DRM calls here, just a plain write() into /dev/fb0.
 *
 * Usage: menu-render "<text>"        (or pipe text via stdin if no arg)
 * Resolution comes from /sys/class/graphics/fb0/virtual_size, pixel
 * format from bits_per_pixel -- no hardcoding. Only 16bpp (RGB565,
 * GStreamer caps format RGB16) is currently supported, matching this
 * project's actual hardware.
 */
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

static int read_fb_size(const char *path, int *w, int *h) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int n = fscanf(f, "%d,%d", w, h);
    fclose(f);
    return n == 2 ? 0 : -1;
}

static int read_fb_int(const char *path, int *v) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int n = fscanf(f, "%d", v);
    fclose(f);
    return n == 1 ? 0 : -1;
}

static char *read_stdin_text(void) {
    static char buf[8192];
    size_t len = fread(buf, 1, sizeof(buf) - 1, stdin);
    buf[len] = '\0';
    return buf;
}

int main(int argc, char **argv) {
    gst_init(&argc, &argv);

    char *text = (argc > 1) ? argv[1] : read_stdin_text();
    if (!text || !*text) {
        fprintf(stderr, "menu-render: no text given (argv[1] or stdin)\n");
        return 1;
    }

    int w, h, bpp;
    if (read_fb_size("/sys/class/graphics/fb0/virtual_size", &w, &h) < 0) {
        fprintf(stderr, "menu-render: cannot read fb0 virtual_size: %s\n", strerror(errno));
        return 1;
    }
    if (read_fb_int("/sys/class/graphics/fb0/bits_per_pixel", &bpp) < 0) {
        fprintf(stderr, "menu-render: cannot read fb0 bits_per_pixel: %s\n", strerror(errno));
        return 1;
    }

    const char *gst_format;
    if (bpp == 16) {
        gst_format = "RGB16";
    } else {
        fprintf(stderr, "menu-render: unsupported fb0 bits_per_pixel=%d (only 16bpp/RGB565 supported)\n", bpp);
        return 1;
    }
    size_t expected_size = (size_t) w * (size_t) h * (size_t) bpp / 8;

    char pipeline_desc[512];
    snprintf(pipeline_desc, sizeof(pipeline_desc),
        "videotestsrc pattern=black num-buffers=1 ! "
        "video/x-raw,width=%d,height=%d ! "
        "textoverlay name=overlay valignment=center halignment=center "
        "shaded-background=true font-desc=\"Sans, 36\" ! "
        "videoconvert ! video/x-raw,format=%s ! appsink name=sink sync=false",
        w, h, gst_format);

    GError *err = NULL;
    GstElement *pipeline = gst_parse_launch(pipeline_desc, &err);
    if (!pipeline) {
        fprintf(stderr, "menu-render: gst_parse_launch failed: %s\n", err ? err->message : "unknown error");
        return 1;
    }

    GstElement *overlay = gst_bin_get_by_name(GST_BIN(pipeline), "overlay");
    if (!overlay) {
        fprintf(stderr, "menu-render: could not find textoverlay element in pipeline\n");
        return 1;
    }
    g_object_set(overlay, "text", text, NULL);
    gst_object_unref(overlay);

    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    if (!sink) {
        fprintf(stderr, "menu-render: could not find appsink element in pipeline\n");
        return 1;
    }

    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        fprintf(stderr, "menu-render: pipeline failed to reach PLAYING\n");
        gst_object_unref(sink);
        gst_object_unref(pipeline);
        return 1;
    }

    GstSample *sample = gst_app_sink_pull_sample(GST_APP_SINK(sink));
    gst_object_unref(sink);
    if (!sample) {
        fprintf(stderr, "menu-render: no sample produced (pipeline error or empty EOS)\n");
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        return 1;
    }

    GstBuffer *buffer = gst_sample_get_buffer(sample);
    GstMapInfo map;
    if (!buffer || !gst_buffer_map(buffer, &map, GST_MAP_READ)) {
        fprintf(stderr, "menu-render: gst_buffer_map failed\n");
        gst_sample_unref(sample);
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        return 1;
    }

    if (map.size != expected_size) {
        fprintf(stderr,
            "menu-render: rendered buffer size %zu bytes does not match fb0's expected %zu "
            "bytes (%dx%d @ %dbpp) -- refusing to write, possible stride/padding mismatch\n",
            (size_t) map.size, expected_size, w, h, bpp);
        gst_buffer_unmap(buffer, &map);
        gst_sample_unref(sample);
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        return 1;
    }

    int fb = open("/dev/fb0", O_WRONLY);
    if (fb < 0) {
        perror("menu-render: open /dev/fb0");
        gst_buffer_unmap(buffer, &map);
        gst_sample_unref(sample);
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        return 1;
    }
    ssize_t written = write(fb, map.data, map.size);
    if (written < 0 || (size_t) written != map.size) {
        perror("menu-render: write /dev/fb0");
        close(fb);
        gst_buffer_unmap(buffer, &map);
        gst_sample_unref(sample);
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
        return 1;
    }
    close(fb);

    gst_buffer_unmap(buffer, &map);
    gst_sample_unref(sample);
    gst_element_set_state(pipeline, GST_STATE_NULL);
    gst_object_unref(pipeline);
    return 0;
}
