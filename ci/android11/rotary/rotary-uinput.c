/* Synthetic input only. Run in an isolated Linux/Android test guest. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void stop(int sig) { (void)sig; stopping = 1; }

static int emit(int fd, unsigned short type, unsigned short code, int value)
{
    if (fd < 0)
        return printf("%hu %hu %d\n", type, code, value) < 0 ? -1 : 0;
    struct input_event event = {.type = type, .code = code, .value = value};
    ssize_t count;
    do {
        count = write(fd, &event, sizeof(event));
    } while (count < 0 && errno == EINTR && !stopping);
    if (count != sizeof(event)) {
        if (count >= 0)
            errno = EIO;
        return -1;
    }
    return 0;
}

static int frame(int fd, int wheel, int hall)
{
    if (wheel && emit(fd, EV_REL, REL_WHEEL, wheel) < 0)
        return -1;
    if (emit(fd, EV_REL, REL_X, hall) < 0)
        return -1;
    return emit(fd, EV_SYN, SYN_REPORT, 0);
}

int main(int argc, char **argv)
{
    bool dry = false, wrong_name = false, reverse = false;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--dry-run")) dry = true;
        else if (!strcmp(argv[i], "--wrong-name")) wrong_name = true;
        else if (!strcmp(argv[i], "--reverse")) reverse = true;
        else {
            fprintf(stderr, "Usage: %s [--dry-run] [--wrong-name] [--reverse]\n", argv[0]);
            return 2;
        }
    }
    const char *name = wrong_name ? "tizen_detent_unmatched" : "tizen_detent";
    int fd = -1;
    if (!dry) {
        struct sigaction action = {.sa_handler = stop};
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGINT, &action, NULL) || sigaction(SIGTERM, &action, NULL)) {
            perror("sigaction");
            return 1;
        }
        fd = open("/dev/uinput", O_WRONLY | O_CLOEXEC);
        if (fd < 0) {
            perror("/dev/uinput");
            return 1;
        }

        /*
         * Matches the real tizen_bezel driver's registered capability set
         * (drivers/input/misc/tizen_bezel.c bezel_setup_input_dev(): EV_KEY
         * with BTN_LEFT, and EV_REL with REL_X, REL_Y, REL_WHEEL), so Android
         * EventHub/InputReader classifies this synthetic device the same way
         * it would classify the real driver's node. BTN_LEFT and REL_Y are
         * registered capabilities only -- like the real driver, this
         * generator never emits a BTN_LEFT key event or a REL_Y motion.
         */
        struct uinput_setup setup = {.id = {.bustype = BUS_VIRTUAL, .version = 1}};
        snprintf(setup.name, sizeof(setup.name), "%s", name);
        if (ioctl(fd, UI_SET_EVBIT, EV_REL) < 0 ||
            ioctl(fd, UI_SET_RELBIT, REL_WHEEL) < 0 ||
            ioctl(fd, UI_SET_RELBIT, REL_X) < 0 ||
            ioctl(fd, UI_SET_RELBIT, REL_Y) < 0 ||
            ioctl(fd, UI_SET_EVBIT, EV_KEY) < 0 ||
            ioctl(fd, UI_SET_KEYBIT, BTN_LEFT) < 0 ||
            ioctl(fd, UI_DEV_SETUP, &setup) < 0 ||
            ioctl(fd, UI_DEV_CREATE) < 0) {
            perror("uinput setup/create");
            close(fd);
            return 1;
        }
    }
    /*
     * Printed in both --dry-run and real modes so a host-only test can
     * confirm the intended capability set without opening /dev/uinput.
     */
    fprintf(stderr, "Capabilities: EV_REL(REL_WHEEL,REL_X,REL_Y) EV_KEY(BTN_LEFT)\n");
    fprintf(stderr, "%s %s. Commands: cw, ccw, x, quit\n",
            dry ? "Dry-run name" : "Registered", name);
    char *line = NULL;
    size_t size = 0;
    int result = 0;
    int sign = reverse ? -1 : 1;
    while (!stopping && getline(&line, &size, stdin) >= 0) {
        line[strcspn(line, "\r\n")] = '\0';
        if (!strcmp(line, "quit")) break;
        if (!strcmp(line, "cw")) result = frame(fd, sign, 5);
        else if (!strcmp(line, "ccw")) result = frame(fd, -sign, 6);
        else if (!strcmp(line, "x")) result = frame(fd, 0, 5);
        else {
            fprintf(stderr, "Unknown command: %s\n", line);
            result = -1;
            break;
        }
        if (result < 0) {
            perror("input frame");
            break;
        }
    }
    if (ferror(stdin) && !stopping) {
        perror("stdin");
        result = -1;
    }
    free(line);
    if (fd >= 0) {
        if (ioctl(fd, UI_DEV_DESTROY) < 0) {
            perror("UI_DEV_DESTROY");
            result = -1;
        }
        close(fd);
    }
    return result < 0 ? 1 : 0;
}
