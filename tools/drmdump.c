/* Diagnostic-only tool: dumps the raw pixel content DRM is actually scanning
 * out on each active CRTC, straight from its dumb-buffer framebuffer, into
 * one raw file per CRTC. Exists because both prior attempts at reading the
 * real screen output failed: `ffmpeg -f kmsgrab` errored on every pixel
 * format tried, and /dev/fb0 turned out to be a decoupled fbdev-emulation
 * buffer unrelated to the live DRM scanout (see PROGRESS.md, 2026-09-12).
 *
 * Needs CAP_SYS_ADMIN (run as root) -- DRM_IOCTL_MODE_GETFB is restricted to
 * root/DRM-master on modern kernels specifically to stop one process reading
 * another's screen content (the same class of concern this project's own
 * frozen-frame info-disclosure fix addressed, commit 5a84a7e).
 *
 * Usage: drmdump [/dev/dri/cardN] [output-path-prefix]
 * Writes <prefix>.crtcN.raw plus a matching <prefix>.crtcN.info line on
 * stderr (width, height, pitch, bpp, depth) needed to interpret the raw
 * bytes -- typically 32bpp XRGB8888, decodable with:
 *   ffmpeg -f rawvideo -pixel_format bgra -video_size WxH -i out.crtcN.raw out.png
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

static int dump_fb(int fd, const char *outprefix, const char *label, uint32_t fb_id) {
    drmModeFB *fb = drmModeGetFB(fd, fb_id);
    if (!fb) {
        fprintf(stderr, "%s: drmModeGetFB(%u) failed: %s\n", label, fb_id, strerror(errno));
        return 0;
    }
    fprintf(stderr, "%s: fb %u %ux%u pitch=%u bpp=%u depth=%u handle=%u\n",
            label, fb->fb_id, fb->width, fb->height, fb->pitch, fb->bpp, fb->depth, fb->handle);

    struct drm_mode_map_dumb mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.handle = fb->handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) {
        fprintf(stderr, "%s: DRM_IOCTL_MODE_MAP_DUMB failed: %s\n", label, strerror(errno));
        drmModeFreeFB(fb);
        return 0;
    }

    size_t size = (size_t) fb->pitch * fb->height;
    void *map = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, mreq.offset);
    if (map == MAP_FAILED) {
        fprintf(stderr, "%s: mmap failed: %s\n", label, strerror(errno));
        drmModeFreeFB(fb);
        return 0;
    }

    char path[512];
    snprintf(path, sizeof(path), "%s.%s.raw", outprefix, label);
    int ok = 0;
    FILE *out = fopen(path, "wb");
    if (!out) {
        fprintf(stderr, "%s: fopen(%s) failed: %s\n", label, path, strerror(errno));
    } else {
        fwrite(map, 1, size, out);
        fclose(out);
        fprintf(stderr, "%s: wrote %s (%zu bytes, %ux%u pitch=%u bpp=%u)\n",
                label, path, size, fb->width, fb->height, fb->pitch, fb->bpp);
        ok = 1;
    }

    munmap(map, size);
    drmModeFreeFB(fb);
    return ok;
}

int main(int argc, char **argv) {
    const char *card = argc > 1 ? argv[1] : "/dev/dri/card0";
    const char *outprefix = argc > 2 ? argv[2] : "/tmp/drmdump";

    int fd = open(card, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    /* Universal planes: without this cap, the kernel hides primary/cursor
     * planes from drmModeGetPlaneResources() and only shows overlay planes --
     * exactly the ones this tool needs to see to tell primary from overlay. */
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) < 0) {
        fprintf(stderr, "DRM_CLIENT_CAP_UNIVERSAL_PLANES failed: %s\n", strerror(errno));
    }

    int dumped = 0;

    /* Primary approach: read each PLANE's own currently-attached fb_id
     * directly (drmModeGetPlane -> ->fb_id). This reflects atomic KMS commits
     * correctly. drmModeGetCrtc()->buffer_id (the legacy CRTC API) does NOT
     * reliably track atomic plane commits on this driver -- confirmed empirically:
     * it kept reporting the same stale fb id across a plane-86 atomic update that
     * demonstrably succeeded per kmssink's own log output, so it is only used
     * here as a documented fallback/cross-check, not the primary source of truth. */
    drmModePlaneRes *pres = drmModeGetPlaneResources(fd);
    if (pres) {
        for (uint32_t i = 0; i < pres->count_planes; i++) {
            drmModePlane *plane = drmModeGetPlane(fd, pres->planes[i]);
            if (!plane) continue;
            fprintf(stderr, "plane %u: crtc_id=%u fb_id=%u\n", plane->plane_id, plane->crtc_id, plane->fb_id);
            if (plane->fb_id) {
                char label[64];
                snprintf(label, sizeof(label), "plane%u", plane->plane_id);
                dumped += dump_fb(fd, outprefix, label, plane->fb_id);
            }
            drmModeFreePlane(plane);
        }
        drmModeFreePlaneResources(pres);
    } else {
        fprintf(stderr, "drmModeGetPlaneResources failed: %s\n", strerror(errno));
    }

    /* Cross-check / fallback: legacy per-CRTC fb, kept for comparison in logs. */
    drmModeRes *res = drmModeGetResources(fd);
    if (res) {
        for (int i = 0; i < res->count_crtcs; i++) {
            drmModeCrtc *crtc = drmModeGetCrtc(fd, res->crtcs[i]);
            if (!crtc) continue;
            fprintf(stderr, "(legacy) CRTC %u: buffer_id=%u\n", crtc->crtc_id, crtc->buffer_id);
            drmModeFreeCrtc(crtc);
        }
        drmModeFreeResources(res);
    }

    close(fd);
    return dumped > 0 ? 0 : 1;
}
