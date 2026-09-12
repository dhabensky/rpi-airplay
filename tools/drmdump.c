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

static void fourcc_str(uint32_t fmt, char out[5]) {
    out[0] = (char) (fmt & 0xff);
    out[1] = (char) ((fmt >> 8) & 0xff);
    out[2] = (char) ((fmt >> 16) & 0xff);
    out[3] = (char) ((fmt >> 24) & 0xff);
    out[4] = '\0';
}

/* Real decoded video frames land on the overlay plane as multi-planar
 * buffers (e.g. NV12) with a DRM format modifier -- the legacy GETFB ioctl
 * used below for simple dumb buffers fails on these with EINVAL. GETFB2
 * (modifier/multi-plane aware) + PRIME export is the correct path for them.
 * Each of up to 4 sub-planes (e.g. NV12's Y and UV) is written to its own
 * file, named with its index, pitch and offset so it can be reassembled. A
 * non-zero modifier means the bytes are in some vendor-specific tiled
 * layout, NOT simple raster order -- that's noted on stderr since this tool
 * does not attempt to de-tile. */
static int dump_fb2(int fd, const char *outprefix, const char *label, uint32_t fb_id) {
    drmModeFB2 *fb = drmModeGetFB2(fd, fb_id);
    if (!fb) {
        fprintf(stderr, "%s: drmModeGetFB2(%u) failed: %s\n", label, fb_id, strerror(errno));
        return 0;
    }
    char fmt[5];
    fourcc_str(fb->pixel_format, fmt);
    fprintf(stderr, "%s: fb2 %u %ux%u format=%s modifier=0x%llx flags=0x%x\n",
            label, fb->fb_id, fb->width, fb->height, fmt,
            (unsigned long long) fb->modifier, fb->flags);
    if (fb->modifier != 0 /* DRM_FORMAT_MOD_LINEAR */) {
        fprintf(stderr, "%s: NOTE non-linear modifier -- raw bytes are tiled, not simple %s raster order\n", label, fmt);
    }

    int ok = 0;
    for (int p = 0; p < 4; p++) {
        if (!fb->handles[p]) continue;
        int prime_fd = -1;
        if (drmPrimeHandleToFD(fd, fb->handles[p], DRM_CLOEXEC | DRM_RDWR, &prime_fd) < 0) {
            fprintf(stderr, "%s: plane %d drmPrimeHandleToFD failed: %s\n", label, p, strerror(errno));
            continue;
        }
        off_t len = lseek(prime_fd, 0, SEEK_END);
        if (len <= 0) {
            /* Some drivers don't support SEEK_END sizing on the dmabuf fd;
             * fall back to a pitch*height estimate for this sub-plane. */
            len = (off_t) fb->pitches[p] * fb->height;
        }
        void *map = mmap(NULL, (size_t) len, PROT_READ, MAP_SHARED, prime_fd, 0);
        if (map == MAP_FAILED) {
            fprintf(stderr, "%s: plane %d mmap failed: %s\n", label, p, strerror(errno));
            close(prime_fd);
            continue;
        }
        char path[512];
        snprintf(path, sizeof(path), "%s.%s.p%d.raw", outprefix, label, p);
        FILE *out = fopen(path, "wb");
        if (!out) {
            fprintf(stderr, "%s: plane %d fopen(%s) failed: %s\n", label, p, path, strerror(errno));
        } else {
            fwrite(map, 1, (size_t) len, out);
            fclose(out);
            fprintf(stderr, "%s: plane %d wrote %s (%lld bytes, pitch=%u offset=%u)\n",
                    label, p, path, (long long) len, fb->pitches[p], fb->offsets[p]);
            ok = 1;
        }
        munmap(map, (size_t) len);
        close(prime_fd);
    }

    drmModeFreeFB2(fb);
    return ok;
}

static int dump_fb(int fd, const char *outprefix, const char *label, uint32_t fb_id) {
    drmModeFB *fb = drmModeGetFB(fd, fb_id);
    if (!fb) {
        if (errno == EINVAL) {
            fprintf(stderr, "%s: drmModeGetFB(%u) got EINVAL (likely multi-planar/modifier fb) -- trying GETFB2\n", label, fb_id);
            return dump_fb2(fd, outprefix, label, fb_id);
        }
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

/* Prints the plane's atomic CRTC_X/CRTC_Y/CRTC_W/CRTC_H properties -- the
 * actual on-screen destination rectangle a plane is composited into. This
 * is NOT the same as the plane's own framebuffer dimensions (fb2's
 * width/height above): kmssink's render-rectangle property changes where
 * and at what size the buffer is scaled onto the CRTC via exactly these
 * atomic properties, while the underlying decoded video buffer keeps its
 * own native/source dimensions regardless -- confirmed empirically
 * (source stayed 1662x1080 across different render-rectangle settings).
 * These 4 properties aren't exposed by the legacy drmModeGetPlane() struct
 * at all on an atomic-only driver, hence reading them the long way here. */
static void print_plane_dest_rect(int fd, uint32_t plane_id) {
    drmModeObjectProperties *props = drmModeObjectGetProperties(fd, plane_id, DRM_MODE_OBJECT_PLANE);
    if (!props) {
        fprintf(stderr, "plane %u: drmModeObjectGetProperties failed: %s\n", plane_id, strerror(errno));
        return;
    }
    int64_t x = -1, y = -1, w = -1, h = -1;
    for (uint32_t i = 0; i < props->count_props; i++) {
        drmModePropertyRes *prop = drmModeGetProperty(fd, props->props[i]);
        if (!prop) continue;
        uint64_t val = props->prop_values[i];
        if (!strcmp(prop->name, "CRTC_X")) x = (int64_t) val;
        else if (!strcmp(prop->name, "CRTC_Y")) y = (int64_t) val;
        else if (!strcmp(prop->name, "CRTC_W")) w = (int64_t) val;
        else if (!strcmp(prop->name, "CRTC_H")) h = (int64_t) val;
        drmModeFreeProperty(prop);
    }
    drmModeFreeObjectProperties(props);
    fprintf(stderr, "plane %u: on-screen dest rect CRTC_X=%lld CRTC_Y=%lld CRTC_W=%lld CRTC_H=%lld\n",
            plane_id, (long long) x, (long long) y, (long long) w, (long long) h);
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
    /* Needed for print_plane_dest_rect() below: CRTC_X/Y/W/H are atomic KMS
     * properties, only exposed to a client that has opted into atomic mode
     * -- confirmed empirically (without this, drmModeObjectGetProperties
     * still returns other plane properties, e.g. "type"/"rotation", but not
     * these 4). */
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1) < 0) {
        fprintf(stderr, "DRM_CLIENT_CAP_ATOMIC failed: %s\n", strerror(errno));
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
                print_plane_dest_rect(fd, plane->plane_id);
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
