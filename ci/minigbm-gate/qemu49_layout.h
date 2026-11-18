/* QEMU-only 32-bit RGB layout, not a general minigbm format implementation. */
#ifndef QEMU49_LAYOUT_H
#define QEMU49_LAYOUT_H
#include <errno.h>
#include <stdint.h>
static int qemu49_rgb_layout(uint32_t width, uint32_t height, uint32_t *stride,
                            uint32_t *resource_height, uint32_t *size)
{
    uint64_t w = ((uint64_t)width + 63) & ~UINT64_C(63);
    uint64_t h = ((uint64_t)height + 63) & ~UINT64_C(63);
    const uint64_t limit = UINT32_MAX & ~UINT64_C(4095);
    if (!width || !height) return -EINVAL;
    if (w > UINT32_MAX / 4 || h > limit / (w * 4)) return -EOVERFLOW;
    uint64_t bytes = (w * 4 * h + 4095) & ~UINT64_C(4095);
    if (bytes > limit) return -EOVERFLOW;
    *stride = (uint32_t)(w * 4);
    *resource_height = (uint32_t)h;
    *size = (uint32_t)bytes;
    return 0;
}
#endif
