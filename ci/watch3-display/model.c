/* SPDX-License-Identifier: GPL-2.0-only */
#include "model.h"
#include <errno.h>
#include <limits.h>
#include <string.h>

void w3_init(struct w3_frame *f)
{
    memset(f, 0, sizeof(*f));
    f->buffer_fd = f->acquire_fd = f->retire_fd = -1;
}

int w3_translate_format(enum w3_format format, enum decon_pixel_format *out)
{
    if (!out) return -EINVAL;
    /* Same named mappings as the reference Android ExynosDisplay.cpp:88-100.
     * Physical byte order/colours on R840 remain NOT RUN.
     */
    switch (format) {
    case W3_RGBA8888: *out = DECON_PIXEL_FORMAT_RGBA_8888; return 0;
    case W3_RGBX8888: *out = DECON_PIXEL_FORMAT_RGBX_8888; return 0;
    case W3_BGRA8888: *out = DECON_PIXEL_FORMAT_BGRA_8888; return 0;
    default: return -ENOTSUP;
    }
}

static int valid_ops(const struct w3_ops *ops)
{
    return ops && ops->dup && ops->close && ops->submit && ops->wait && ops->quiescent;
}

static void drop(const struct w3_ops *ops, int *fd)
{
    int owned = *fd;
    *fd = -1; /* Never retry a consumed close or close the descriptor twice. */
    if (owned >= 0) ops->close(ops->ctx, owned);
}

int w3_prepare(struct w3_frame *f, const struct w3_buffer *b,
               enum w3_sync sync, const struct w3_ops *ops)
{
    enum decon_pixel_format fmt;
    uint64_t size;
    struct decon_win_config *win;
    if (!f || !b || !valid_ops(ops) || f->state != W3_EMPTY) return -EINVAL;
    /* Explicit model profile only; never infer this from SYNC_FILE or from
     * the mere existence of fence fields in decon.h.
     */
    if (sync != W3_SYNC_RETIRE_ONLY) return -ENOTSUP;
    if (b->borrowed_fd < 0 || b->borrowed_acquire < -1) return -EBADF;
    if (!b->linear || b->protected_content) return -ENOTSUP;
    if (!b->cpu_complete && b->borrowed_acquire < 0) return -EINVAL;
    if (b->width != 360 || b->height != 360 || b->stride_pixels < b->width ||
        b->allocation_height < b->height) return -EINVAL;
    /* The driver's config_size and alloc_size are u32 (core.c:1558-1559).
     * Reject multiplication overflow/truncation BEFORE serializing a request.
     */
    size = (uint64_t)b->stride_pixels * b->allocation_height;
    if (size > UINT32_MAX / 4u || b->allocation_bytes > UINT32_MAX) return -EOVERFLOW;
    size *= 4u;
    if (size > b->allocation_bytes) return -ENOSPC;
    if (w3_translate_format(b->format, &fmt)) return -ENOTSUP;

    memset(&f->request, 0, sizeof(f->request));
    f->request.retire_fence = f->request.fd_odma = -1;
    for (size_t i = 0; i < MAX_DECON_WIN + 1u; ++i) {
        struct decon_win_config *w = &f->request.config[i];
        for (size_t j = 0; j < 3; ++j) w->fd_idma[j] = -1;
        w->acq_fence = w->rel_fence = -1;
    }
    f->buffer_fd = ops->dup(ops->ctx, b->borrowed_fd);
    if (f->buffer_fd < 0) { int error = f->buffer_fd; w3_init(f); return error; }
    if (b->borrowed_acquire >= 0) {
        f->acquire_fd = ops->dup(ops->ctx, b->borrowed_acquire);
        if (f->acquire_fd < 0) {
            int error = f->acquire_fd;
            drop(ops, &f->buffer_fd);
            w3_init(f);
            return error;
        }
    }
    win = &f->request.config[0];
    win->state = DECON_WIN_STATE_BUFFER;
    win->fd_idma[0] = f->buffer_fd;
    win->acq_fence = f->acquire_fd;
    win->plane_alpha = 255;
    win->blending = DECON_BLENDING_NONE;
    win->idma_type = IDMA_G0; /* Source-allowed candidate, not proven board routing. */
    win->format = fmt;
    win->src.w = win->dst.w = 360;
    win->src.h = win->dst.h = 360;
    win->src.f_w = b->stride_pixels;
    win->src.f_h = b->allocation_height;
    win->dst.f_w = win->dst.f_h = 360;
    /* Rotation/HDR/compression/protection, regions and DMA addresses stay zero.
     * The kernel imports the dma-buf and fills dpp_parm.addr itself.
     */
    f->state = W3_PREPARED;
    return 0;
}

int w3_submit(struct w3_frame *f, const struct w3_ops *ops)
{
    int ret, returned;
    if (!f || !valid_ops(ops) || f->state != W3_PREPARED) return -EINVAL;
    f->state = W3_UNCERTAIN; /* An error can occur AFTER a kernel queued work. */
    ret = ops->submit(ops->ctx, S3CFB_WIN_CONFIG, &f->request);
    returned = f->request.retire_fence;
    if (returned == f->buffer_fd || (returned >= 0 && returned == f->acquire_fd))
        return -EPROTO; /* No double-close if a broken backend aliases an input. */
    if (returned >= 0) f->retire_fd = returned;
    if (ret) return ret < 0 ? ret : -EPROTO;
    if (returned < 0) return -EPROTO;
    f->state = W3_PENDING;
    return 0;
}

int w3_wait(struct w3_frame *f, const struct w3_ops *ops)
{
    int ret;
    if (!f || !valid_ops(ops) || f->state != W3_PENDING) return -EINVAL;
    ret = ops->wait(ops->ctx, f->retire_fd);
    if (ret == 0) f->state = W3_FENCE_DONE;
    return ret > 0 ? -EPROTO : ret;
}

int w3_release(struct w3_frame *f, const struct w3_ops *ops)
{
    if (!f || !valid_ops(ops)) return -EINVAL;
    if (f->state == W3_EMPTY) return 0;
    /* Fence completion alone does NOT prove that the current scanout buffer
     * is no longer in use. Only the synthetic backend can confirm quiescence.
     */
    if (f->state != W3_PREPARED && ops->quiescent(ops->ctx) != 1) return -EBUSY;
    drop(ops, &f->retire_fd);
    drop(ops, &f->acquire_fd);
    drop(ops, &f->buffer_fd);
    w3_init(f);
    return 0;
}
