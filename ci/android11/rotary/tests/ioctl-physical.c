/* SPDX-License-Identifier: MIT
 * Includes real sources. No open/ioctl/write/close reaches an input device.
 */
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static unsigned long requests[32];
static int values[32], calls, opened, closed, count;
static struct uinput_setup actual;
static struct input_event events[64];
static char physical[80];
static int mock_open(const char *path, int flags, ...)
{
    assert(!strcmp(path, "/dev/uinput"));
    assert(flags == (O_WRONLY | O_CLOEXEC));
    ++opened;
    return 99;
}
static int mock_close(int fd) { assert(fd == 99); ++closed; return 0; }
static ssize_t mock_write(int fd, const void *data, size_t size)
{
    assert(fd == 99 && size == sizeof(struct input_event));
    assert(count < (int)(sizeof(events) / sizeof(events[0])));
    memcpy(&events[count++], data, size);
    return (ssize_t)size;
}
static int mock_ioctl(int fd, unsigned long request, ...)
{
    assert(fd == 99 && calls < 32);
    requests[calls] = request;
    va_list args;
    va_start(args, request);
    switch (request) {
    case UI_SET_EVBIT: case UI_SET_RELBIT: case UI_SET_KEYBIT:
        values[calls] = va_arg(args, int); break;
    case UI_SET_PHYS:
        snprintf(physical, sizeof(physical), "%s", va_arg(args, const char *)); break;
    case UI_DEV_SETUP: actual = *va_arg(args, struct uinput_setup *); break;
    case UI_DEV_CREATE: case UI_DEV_DESTROY: break;
    default: assert(!"Unexpected ioctl");
    }
    va_end(args);
    ++calls;
    return 0;
}

#define open mock_open
#define close mock_close
#define ioctl mock_ioctl
#define main generator_main
#ifdef TEST_PROBE
#include "../../fixture/uinput-probe.c"
#else
#define write mock_write
#ifndef ROTARY_GENERATOR_SOURCE
#define ROTARY_GENERATOR_SOURCE "../rotary-uinput.c"
#endif
#include ROTARY_GENERATOR_SOURCE
#undef write
#endif
#undef main
#undef open
#undef close
#undef ioctl

int main(int argc, char **argv)
{
    FILE *old = stdin;
#ifdef TEST_PROBE
    (void)argc; (void)argv;
    /* Keep the unused mock available under strict compilation. */
    (void)mock_write;
    stdin = fmemopen((void *)"q\n", 2, "r");
    assert(stdin && generator_main() == 0);
#else
    char script[] = "cw\nccw\ncw\ncw\ncw\nccw\nccw\nccw\nx\nquit\n";
    stdin = fmemopen(script, sizeof(script) - 1, "r");
    assert(stdin && generator_main(argc, argv) == 0);
#endif
    fclose(stdin); stdin = old;
    assert(opened == 1 && closed == 1 && calls == 10);
    const unsigned long order[] = {UI_SET_EVBIT, UI_SET_RELBIT, UI_SET_RELBIT,
        UI_SET_RELBIT, UI_SET_EVBIT, UI_SET_KEYBIT, UI_SET_PHYS,
        UI_DEV_SETUP, UI_DEV_CREATE, UI_DEV_DESTROY};
    assert(!memcmp(requests, order, sizeof(order)));
#ifdef TEST_PROBE
    const int bits[] = {EV_REL, REL_X, REL_Y, REL_WHEEL, EV_KEY, BTN_LEFT};
#else
    const int bits[] = {EV_REL, REL_WHEEL, REL_X, REL_Y, EV_KEY, BTN_LEFT};
#endif
    assert(!memcmp(values, bits, sizeof(bits)));
    /* Independent literals from the stock observation and Samsung source. */
    assert(actual.id.bustype == 0x0006 && actual.id.vendor == 0x0001);
    assert(actual.id.product == 0x0001 && actual.id.version == 0x0100);
    assert(!strcmp(physical, "tizen_detent"));
    bool wrong = false, reverse = false;
    for (int i = 1; i < argc; ++i) {
        wrong |= !strcmp(argv[i], "--wrong-name");
        reverse |= !strcmp(argv[i], "--reverse");
    }
    assert(!strcmp(actual.name, wrong ? "tizen_detent_unmatched" : "tizen_detent"));
#ifdef TEST_PROBE
    (void)reverse; assert(count == 0);
#else
    const int direction[] = {1, -1, 1, 1, 1, -1, -1, -1};
    const int masks[] = {5, 6, 5, 3, 6, 3, 5, 6};
    const int reversed[] = {3, 6, 3, 5, 6, 5, 3, 6};
    assert(count == 26);
    for (int i = 0; i < 8; ++i) {
        assert(events[3*i].type == EV_REL && events[3*i].code == REL_WHEEL);
        assert(events[3*i].value == direction[i] * (reverse ? -1 : 1));
        assert(events[3*i+1].type == EV_REL && events[3*i+1].code == REL_X);
        assert(events[3*i+1].value == (reverse ? reversed[i] : masks[i]));
        assert(events[3*i+2].type == EV_SYN && events[3*i+2].code == SYN_REPORT);
    }
    assert(events[24].type == EV_REL && events[24].code == REL_X && events[24].value == 5);
    assert(events[25].type == EV_SYN && events[25].code == SYN_REPORT);
#endif
    puts("PASS actual source intercepted ioctls, stock identity and ordered frames; no hardware access");
    return 0;
}
