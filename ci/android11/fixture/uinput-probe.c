/* SPDX-License-Identifier: MIT */
/* Register a disposable Android guest node for IDC discovery. Emits no events. */
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <linux/uinput.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(void)
{
    struct uinput_setup setup = {
        .id = {.bustype = BUS_VIRTUAL, .version = 1},
        .name = "tizen_detent",
    };
    int fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
    if (fd < 0) {
        perror("open /dev/uinput");
        return 1;
    }
    fprintf(stderr, "OPEN /dev/uinput OK\n");

    if (ioctl(fd, UI_SET_EVBIT, EV_REL) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_X) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_Y) < 0 ||
        ioctl(fd, UI_SET_RELBIT, REL_WHEEL) < 0 ||
        ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
        ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
        ioctl(fd, UI_DEV_SETUP, &setup) < 0 ||
        ioctl(fd, UI_DEV_CREATE) < 0) {
        perror("uinput capability/setup/create ioctl");
        close(fd);
        return 1;
    }

    fprintf(stderr, "CREATE tizen_detent OK; no events emitted\n");
    /* Wait for a single stdin byte from the host while EventHub scans the node. */
    int got_byte = getchar() != EOF;
    int destroy = ioctl(fd, UI_DEV_DESTROY);
    if (destroy < 0) {
        perror("UI_DEV_DESTROY");
    }
    close(fd);
    return got_byte && destroy == 0 ? 0 : 1;
}
