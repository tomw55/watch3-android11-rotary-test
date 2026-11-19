/* SPDX-License-Identifier: GPL-2.0-only */
#include "model.h"
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

u32 dpu_translate_fmt_to_dpp(u32 format);
int source_check_limitation(int idx, struct decon_win_config *config);

/* ARM64 LP64/natural-alignment expectations, checked here on the LP64 host.
 * A real ARM64 compilation is a separate acceptance criterion, not inferred.
 */
_Static_assert(sizeof(void *) == 8 && sizeof(int) == 4, "LP64 test host required");
_Static_assert(sizeof(enum decon_pixel_format) == 4, "no short enums");
_Static_assert(sizeof(dma_addr_t) == 8 && _Alignof(dma_addr_t) == 8, "64-bit DMA address");
_Static_assert(MAX_DECON_WIN == 3, "not the Gear S3 seven-window header");
_Static_assert(sizeof(struct dpp_params) == 48, "DPP layout");
_Static_assert(sizeof(struct decon_win_config) == 200, "window layout");
_Static_assert(sizeof(struct decon_win_config_data) == 808, "request layout");
_Static_assert(offsetof(struct decon_win_config, fd_idma) == 8, "dma-buf offsets");
_Static_assert(offsetof(struct decon_win_config, acq_fence) == 20, "acquire offset");
_Static_assert(offsetof(struct decon_win_config, rel_fence) == 24, "release offset");
_Static_assert(offsetof(struct decon_win_config, dpp_parm) == 48, "DPP offset");
_Static_assert(offsetof(struct decon_win_config, src) == 144, "source frame offset");
_Static_assert(offsetof(struct decon_win_config, dst) == 168, "destination frame offset");
_Static_assert(offsetof(struct decon_win_config, compression) == 193, "compression offset");
_Static_assert(offsetof(struct decon_win_config_data, config) == 8, "array offset");
_Static_assert(DECON_PIXEL_FORMAT_RGBA_8888 == 2, "format value");
_Static_assert(DECON_PIXEL_FORMAT_BGRA_8888 == 3, "format value");
_Static_assert(DECON_PIXEL_FORMAT_RGBX_8888 == 6, "format value");
_Static_assert(S3CFB_WIN_CONFIG == 0x432846d1UL, "complete encoded ioctl, including size");

enum { FREE, BORROWED, OWNED };
struct fake {
    int fds[64], dup_calls, close_calls, submits, fail_dup;
    int submit_error, no_fence, alias, signalled, quiescent;
};
static unsigned groups;
#define GROUP(name) do { ++groups; printf("PASS %s\n", name); } while (0)

static int allocate(struct fake *m)
{
    for (int i = 0; i < 64; ++i)
        if (m->fds[i] == FREE) { m->fds[i] = OWNED; return i; }
    return -EMFILE;
}
static int fake_dup(void *ctx, int fd)
{
    struct fake *m = ctx;
    ++m->dup_calls;
    if (m->fail_dup == m->dup_calls) return -EMFILE;
    if (fd < 0 || fd >= 64 || m->fds[fd] == FREE) return -EBADF;
    return allocate(m);
}
static void fake_close(void *ctx, int fd)
{
    struct fake *m = ctx;
    assert(fd >= 0 && fd < 64 && m->fds[fd] == OWNED);
    m->fds[fd] = FREE;
    ++m->close_calls;
}
static int fake_submit(void *ctx, unsigned long cmd, struct decon_win_config_data *r)
{
    struct fake *m = ctx;
    ++m->submits;
    assert(cmd == 0x432846d1UL);
    assert(r->config[0].state == DECON_WIN_STATE_BUFFER);
    assert(source_check_limitation(0, &r->config[0]) == 0);
    assert(r->config[0].dpp_parm.addr[0] == 0); /* Kernel-owned address */
    assert(r->config[0].fd_idma[1] == -1 && r->config[0].fd_idma[2] == -1);
    assert(r->fd_odma == -1 && r->retire_fence == -1);
    for (int i = 1; i <= MAX_DECON_WIN; ++i)
        assert(r->config[i].state == DECON_WIN_STATE_DISABLED);
    if (m->alias) r->retire_fence = r->config[0].fd_idma[0];
    else if (!m->no_fence) r->retire_fence = allocate(m);
    return m->submit_error;
}
static int fake_wait(void *ctx, int fd)
{
    struct fake *m = ctx;
    assert(fd >= 0 && fd < 64 && m->fds[fd] == OWNED);
    return m->signalled ? 0 : -ETIMEDOUT;
}
static int fake_quiescent(void *ctx) { return ((struct fake *)ctx)->quiescent; }
static struct w3_ops ops_for(struct fake *m)
{
    return (struct w3_ops){m, fake_dup, fake_close, fake_submit, fake_wait, fake_quiescent};
}
static struct w3_buffer buffer(void)
{
    return (struct w3_buffer){.borrowed_fd=10, .borrowed_acquire=11,
        .width=360, .height=360, .stride_pixels=384, .allocation_height=360,
        .allocation_bytes=384u*360u*4u, .format=W3_RGBA8888, .linear=true};
}
static void setup(struct fake *m, struct w3_frame *f)
{
    memset(m, 0, sizeof(*m));
    m->fds[10] = m->fds[11] = BORROWED;
    w3_init(f);
}
static void clean(const struct fake *m)
{
    assert(m->fds[10] == BORROWED && m->fds[11] == BORROWED);
    for (int i = 0; i < 64; ++i) assert(m->fds[i] != OWNED);
}

static void test_success(void)
{
    struct fake m; struct w3_frame f; setup(&m, &f);
    struct w3_ops ops = ops_for(&m); struct w3_buffer b = buffer();
    assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == 0);
    assert(f.buffer_fd == 0); /* FD zero is a valid owned descriptor. */
    assert(f.request.config[0].src.f_w == 384);
    assert(f.request.config[0].dst.f_w == 360);
    assert(f.request.config[0].plane_alpha == 255);
    assert(f.request.config[0].blending == DECON_BLENDING_NONE);
    assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == -EINVAL);
    assert(w3_wait(&f, &ops) == -EINVAL);
    assert(w3_submit(&f, &ops) == 0);
    assert(w3_submit(&f, &ops) == -EINVAL);
    assert(w3_wait(&f, &ops) == -ETIMEDOUT);
    assert(f.state == W3_PENDING && w3_release(&f, &ops) == -EBUSY);
    m.signalled = 1;
    assert(w3_wait(&f, &ops) == 0 && f.state == W3_FENCE_DONE);
    assert(w3_release(&f, &ops) == -EBUSY); /* Retire is not buffer release. */
    assert(m.close_calls == 0);
    m.quiescent = -EIO;
    assert(w3_release(&f, &ops) == -EBUSY);
    m.quiescent = 1;
    assert(w3_release(&f, &ops) == 0 && m.close_calls == 3);
    assert(w3_release(&f, &ops) == 0 && m.close_calls == 3);
    clean(&m); GROUP("full frame / timeout / retire / explicit quiescence / no double close");
}

static void test_formats(void)
{
    const enum decon_pixel_format expected[] = {DECON_PIXEL_FORMAT_RGBA_8888,
        DECON_PIXEL_FORMAT_RGBX_8888, DECON_PIXEL_FORMAT_BGRA_8888};
    const u32 dpp_expected[] = {DECON_PIXEL_FORMAT_ABGR_8888,
        DECON_PIXEL_FORMAT_XBGR_8888, DECON_PIXEL_FORMAT_ARGB_8888};
    for (int i = 0; i < 3; ++i) {
        enum decon_pixel_format out;
        assert(w3_translate_format((enum w3_format)i, &out) == 0 && out == expected[i]);
        assert(dpu_translate_fmt_to_dpp((u32)out) == dpp_expected[i]);
        struct fake m; struct w3_frame f; setup(&m, &f);
        struct w3_ops ops = ops_for(&m); struct w3_buffer b = buffer();
        b.format = (enum w3_format)i;
        assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == 0);
        assert(f.request.config[0].format == expected[i]);
        assert(source_check_limitation(0, &f.request.config[0]) == 0);
        assert(w3_release(&f, &ops) == 0); clean(&m);
    }
    enum decon_pixel_format out;
    assert(w3_translate_format((enum w3_format)-1, &out) == -ENOTSUP);
    assert(w3_translate_format((enum w3_format)INT_MAX, &out) == -ENOTSUP);
    assert(w3_translate_format(W3_RGBA8888, NULL) == -EINVAL);
    GROUP("three Android-reference format mappings / real kernel DPP translation / unknown rejection");
}

static void invalid_buffer(struct w3_buffer b, int expected)
{
    struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
    assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == expected);
    assert(m.submits == 0 && m.dup_calls == 0 && f.state == W3_EMPTY); clean(&m);
}
static void test_rejections(void)
{
    struct w3_buffer b;
#define BAD(field, value, err) do { b = buffer(); b.field = value; invalid_buffer(b, err); } while (0)
    BAD(width, 0, -EINVAL); BAD(width, 359, -EINVAL); BAD(width, 361, -EINVAL);
    BAD(height, 0, -EINVAL); BAD(height, 359, -EINVAL); BAD(height, 361, -EINVAL);
    BAD(stride_pixels, 359, -EINVAL); BAD(allocation_height, 359, -EINVAL);
    BAD(allocation_bytes, 0, -ENOSPC); BAD(allocation_bytes, 384u*360u*4u-1u, -ENOSPC);
    BAD(stride_pixels, UINT32_MAX, -EOVERFLOW);
    BAD(allocation_height, UINT32_MAX, -EOVERFLOW);
    BAD(allocation_bytes, UINT64_MAX, -EOVERFLOW);
    BAD(borrowed_fd, -1, -EBADF); BAD(borrowed_acquire, -2, -EBADF);
    BAD(linear, false, -ENOTSUP); BAD(protected_content, true, -ENOTSUP);
    BAD(format, (enum w3_format)999, -ENOTSUP);
    BAD(borrowed_acquire, -1, -EINVAL);
#undef BAD
    struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
    b = buffer();
    assert(w3_prepare(&f, &b, W3_SYNC_UNKNOWN, &ops) == -ENOTSUP);
    assert(w3_prepare(&f, &b, W3_SYNC_DISABLED, &ops) == -ENOTSUP);
    assert(m.dup_calls == 0);
    assert(w3_prepare(NULL, &b, W3_SYNC_RETIRE_ONLY, &ops) == -EINVAL);
    assert(w3_prepare(&f, NULL, W3_SYNC_RETIRE_ONLY, &ops) == -EINVAL);
    assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, NULL) == -EINVAL);
    GROUP("19 malformed/unsupported buffer cases / unknown sync / null arguments");
}

static void test_duplicates(void)
{
    for (int failure = 1; failure <= 2; ++failure) {
        struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
        struct w3_buffer b = buffer(); m.fail_dup = failure;
        assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == -EMFILE);
        assert(f.state == W3_EMPTY && m.submits == 0);
        clean(&m);
    }
    struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
    struct w3_buffer b = buffer(); b.borrowed_fd = 63;
    assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == -EBADF); clean(&m);
    GROUP("both duplicate failures / invalid borrowed descriptor / rollback");
}

static void test_cpu_complete(void)
{
    struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
    memset(&f, 0, sizeof(f)); /* Regression: zero initialization must not invent acquire FD 0. */
    struct w3_buffer b = buffer(); b.cpu_complete = true; b.borrowed_acquire = -1;
    assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == 0);
    assert(f.request.config[0].acq_fence == -1 && m.dup_calls == 1);
    assert(w3_release(&f, &ops) == 0); clean(&m);
    GROUP("explicit completed CPU producer / no acquire fence / cancellation");
}

static void test_submit_failures(void)
{
    for (int mode = 0; mode < 5; ++mode) {
        struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
        struct w3_buffer b = buffer();
        assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == 0);
        switch (mode) {
        case 0: m.submit_error = -EIO; m.no_fence = 1; break;
        case 1: m.submit_error = -EFAULT; break; /* queued work + copyout-like failure */
        case 2: m.no_fence = 1; break; /* success without usable fence is NOT success */
        case 3: m.alias = 1; break;
        case 4: m.submit_error = 1; break;
        }
        int ret = w3_submit(&f, &ops);
        assert(ret == (mode == 0 ? -EIO : mode == 1 ? -EFAULT : -EPROTO));
        assert(f.state == W3_UNCERTAIN && w3_release(&f, &ops) == -EBUSY);
        assert(w3_submit(&f, &ops) == -EINVAL); /* no blind retry */
        assert(m.close_calls == 0);
        m.quiescent = 1;
        assert(w3_release(&f, &ops) == 0); clean(&m);
    }
    GROUP("five submission failure/ambiguity cases / quarantine / no blind retry");
}

static void test_source_rejections(void)
{
    struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
    struct w3_buffer b = buffer();
    assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == 0);
    const struct decon_win_config original = f.request.config[0];
    struct decon_win_config w;
#define REJECT(field, value) do { w = original; w.field = value; assert(source_check_limitation(0, &w) == -EINVAL); } while (0)
    REJECT(compression, true); REJECT(plane_alpha, -1); REJECT(plane_alpha, 256);
    REJECT(idma_type, IDMA_VG1); REJECT(format, DECON_PIXEL_FORMAT_MAX);
    REJECT(blending, DECON_BLENDING_MAX); REJECT(dst.w, 0); REJECT(dst.w, 15);
    REJECT(dst.x, -1); REJECT(dst.f_w, 359); REJECT(dpp_parm.rot, DPP_ROT_90);
    REJECT(dpp_parm.hdr_std, DPP_HDR_HLG); REJECT(dpp_parm.comp_src, DPP_COMP_SRC_GPU);
    REJECT(dpp_parm.min_luminance, 1); REJECT(dpp_parm.max_luminance, 1);
#undef REJECT
    assert(w3_release(&f, &ops) == 0); clean(&m);
    GROUP("15 real Samsung limitation-check negative controls");
}

static void test_repeated(void)
{
    struct fake m; struct w3_frame f; setup(&m, &f); struct w3_ops ops = ops_for(&m);
    struct w3_buffer b = buffer();
    for (int i = 0; i < 1000; ++i) {
        assert(w3_prepare(&f, &b, W3_SYNC_RETIRE_ONLY, &ops) == 0);
        assert(w3_submit(&f, &ops) == 0);
        m.signalled = 1;
        assert(w3_wait(&f, &ops) == 0);
        m.quiescent = 1;
        assert(w3_release(&f, &ops) == 0); clean(&m);
    }
    assert(m.submits == 1000 && m.close_calls == 3000);
    GROUP("1000 repeated model lifecycles / zero outstanding owned descriptors");
}

int main(void)
{
    printf("ABI window=%zu request=%zu ioctl=0x%lx host_pointer=%zu\n",
           sizeof(struct decon_win_config), sizeof(struct decon_win_config_data),
           (unsigned long)S3CFB_WIN_CONFIG, sizeof(void *));
    test_success(); test_formats(); test_rejections(); test_duplicates();
    test_cpu_complete(); test_submit_failures(); test_source_rejections(); test_repeated();
    printf("PASS %u host-only test groups; hardware/Android HAL runtime NOT RUN\n", groups);
    return 0;
}
