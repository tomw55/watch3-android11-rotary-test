/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef WATCH3_DISPLAY_MODEL_H
#define WATCH3_DISPLAY_MODEL_H
#include <stddef.h>
#include <stdint.h>
#include "abi/watch3_decon_abi.h"

/* Host-only contracts, not Android HAL numeric constants or exported ABI. */
enum w3_format { W3_RGBA8888, W3_RGBX8888, W3_BGRA8888 };
enum w3_sync { W3_SYNC_UNKNOWN, W3_SYNC_DISABLED, W3_SYNC_RETIRE_ONLY };
enum w3_state { W3_EMPTY, W3_PREPARED, W3_UNCERTAIN, W3_PENDING, W3_FENCE_DONE };
struct w3_buffer {
    int borrowed_fd, borrowed_acquire;
    uint32_t width, height, stride_pixels, allocation_height;
    uint64_t allocation_bytes;
    enum w3_format format;
    bool linear, protected_content, cpu_complete;
};
struct w3_ops {
    void *ctx;
    /* Model backends only. No production open/ioctl implementation supplied.
     * dup returns a new, unique owned descriptor; close consumes once.
     * submit returns 0 or a negative errno, with an owned retire FD on success.
     * wait returns 0 only after signal; quiescent returns 1 ONLY after backend
     * confirms all references/scanout ended. A retire signal is NOT that proof.
     */
    int (*dup)(void *, int);
    void (*close)(void *, int);
    int (*submit)(void *, unsigned long, struct decon_win_config_data *);
    int (*wait)(void *, int);
    int (*quiescent)(void *);
};
struct w3_frame {
    enum w3_state state;
    int buffer_fd, acquire_fd, retire_fd;
    struct decon_win_config_data request;
};
void w3_init(struct w3_frame *frame);
int w3_translate_format(enum w3_format format, enum decon_pixel_format *out);
int w3_prepare(struct w3_frame *frame, const struct w3_buffer *buffer,
               enum w3_sync sync, const struct w3_ops *ops);
int w3_submit(struct w3_frame *frame, const struct w3_ops *ops);
int w3_wait(struct w3_frame *frame, const struct w3_ops *ops);
int w3_release(struct w3_frame *frame, const struct w3_ops *ops);
#endif
