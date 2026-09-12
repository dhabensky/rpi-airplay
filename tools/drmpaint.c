/* Diagnostic-only tool: paints a pixel-accurate overscan calibration ruler
 * directly onto the DRM primary plane and holds it there until Enter is
 * pressed. Companion to tools/drmdump.c -- that one reads the real scanout,
 * this one writes a known, exact pattern to it, so a single photo of the
 * physical screen tells us precisely how many pixels the TV's own overscan
 * crops on each edge (something no Pi-side software can otherwise see,
 * since that cropping happens inside the TV's scaler, after the signal
 * leaves the Pi -- see PROGRESS.md, 2026-09-12).
 *
 * Pattern: alternating black/white bands, 10px thick, inset from each of
 * the 4 edges up to 200px, so bands are directly countable in a photo
 * (each visible band = 10px of that edge NOT cropped). Reference marker
 * lines in fixed colors at known distances make counting easier without
 * needing to count every single band:
 *   green  @  50px from each edge
 *   red    @ 100px from each edge
 *   blue   @ 150px from each edge
 * Interior is mid-gray so band edges are unambiguous against it.
 *
 * Needs the uxplay.service (or anything else using kmssink) to be stopped
 * first -- this tool takes DRM master on the primary plane directly via the
 * legacy SetCrtc call and holds it until it exits.
 *
 * Usage: drmpaint [/dev/dri/cardN] [seconds]
 * Holds the pattern for `seconds` (default 180), then releases and exits.
 * Duration-based rather than stdin-driven so it works cleanly when launched
 * detached over SSH (a closed/redirected stdin would EOF immediately).
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static void put_px(uint8_t *map, uint32_t pitch, int x, int y, uint8_t r, uint8_t g, uint8_t b) {
    uint8_t *p = map + (size_t) y * pitch + (size_t) x * 4;
    p[0] = b; p[1] = g; p[2] = r; p[3] = 0;
}

static void band_color(int dist, uint8_t *r, uint8_t *g, uint8_t *b) {
    if (dist == 50)      { *r = 0;   *g = 255; *b = 0;   return; } /* green */
    if (dist == 100)     { *r = 255; *g = 0;   *b = 0;   return; } /* red */
    if (dist == 150)     { *r = 0;   *g = 0;   *b = 255; return; } /* blue */
    int band = dist / 10;
    if (band % 2 == 0) { *r = *g = *b = 0; }       /* black */
    else               { *r = *g = *b = 255; }     /* white */
}

int main(int argc, char **argv) {
    const char *card = argc > 1 ? argv[1] : "/dev/dri/card0";
    int hold_seconds = argc > 2 ? atoi(argv[2]) : 180;

    int fd = open(card, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("drmModeGetResources"); return 1; }

    drmModeConnector *conn = NULL;
    for (int i = 0; i < res->count_connectors; i++) {
        drmModeConnector *c = drmModeGetConnector(fd, res->connectors[i]);
        if (c && c->connection == DRM_MODE_CONNECTED && c->count_modes > 0) { conn = c; break; }
        if (c) drmModeFreeConnector(c);
    }
    if (!conn) { fprintf(stderr, "no connected connector with a mode found\n"); return 1; }

    drmModeEncoder *enc = drmModeGetEncoder(fd, conn->encoder_id);
    if (!enc) { fprintf(stderr, "drmModeGetEncoder failed: %s\n", strerror(errno)); return 1; }
    uint32_t crtc_id = enc->crtc_id;
    drmModeModeInfo mode = conn->modes[0];
    uint32_t W = mode.hdisplay, H = mode.vdisplay;
    fprintf(stderr, "using connector %u, crtc %u, mode %ux%u\n", conn->connector_id, crtc_id, W, H);

    struct drm_mode_create_dumb creq;
    memset(&creq, 0, sizeof(creq));
    creq.width = W; creq.height = H; creq.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) { perror("CREATE_DUMB"); return 1; }

    uint32_t fb_id;
    if (drmModeAddFB(fd, W, H, 24, 32, creq.pitch, creq.handle, &fb_id) < 0) {
        perror("drmModeAddFB"); return 1;
    }

    struct drm_mode_map_dumb mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.handle = creq.handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) { perror("MAP_DUMB"); return 1; }

    uint8_t *map = mmap(NULL, creq.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, mreq.offset);
    if (map == MAP_FAILED) { perror("mmap"); return 1; }

    /* mid-gray interior */
    for (uint32_t y = 0; y < H; y++)
        for (uint32_t x = 0; x < W; x++)
            put_px(map, creq.pitch, x, y, 128, 128, 128);

    /* rulers: for every pixel within 200px of an edge, color by distance
     * to the NEAREST edge (so corners get both rulers' bands correctly). */
    for (uint32_t y = 0; y < H; y++) {
        for (uint32_t x = 0; x < W; x++) {
            int dl = x, drr = W - 1 - x, dt = y, db = H - 1 - y;
            int d = dl; if (drr < d) d = drr; if (dt < d) d = dt; if (db < d) d = db;
            if (d < 200) {
                uint8_t r, g, b;
                band_color(d, &r, &g, &b);
                put_px(map, creq.pitch, x, y, r, g, b);
            }
        }
    }

    if (drmModeSetCrtc(fd, crtc_id, fb_id, 0, 0, &conn->connector_id, 1, &mode) < 0) {
        perror("drmModeSetCrtc"); return 1;
    }

    fprintf(stderr, "pattern displayed on %ux%u -- holding for %d seconds\n", W, H, hold_seconds);
    sleep((unsigned int) hold_seconds);

    munmap(map, creq.size);
    drmModeRmFB(fd, fb_id);
    struct drm_mode_destroy_dumb dreq;
    memset(&dreq, 0, sizeof(dreq));
    dreq.handle = creq.handle;
    drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &dreq);
    drmModeFreeEncoder(enc);
    drmModeFreeConnector(conn);
    drmModeFreeResources(res);
    close(fd);
    return 0;
}
