// SPDX-License-Identifier: Apache-2.0
// kexec_pf — load a kernel Image + initramfs with kexec_file_load() and
// reboot into it. The hardware watchdog is armed first, so a kernel/initramfs
// that hangs resets the board back to the stock kernel (nothing is written to
// flash by this tool).
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/reboot.h>
#include <sys/syscall.h>
#include <linux/reboot.h>
#include <linux/watchdog.h>

#ifndef __NR_kexec_file_load
#define __NR_kexec_file_load 294
#endif

static int pet_pid = -1;

static void disarm_watchdog(void) {
    if (pet_pid > 0) { kill(pet_pid, SIGTERM); pet_pid = -1; }
    int fd = open("/dev/watchdog", O_WRONLY);
    if (fd >= 0) { write(fd, "V", 1); close(fd); }
}

static int arm_watchdog(int timeout_s) {
    int fd = open("/dev/watchdog", O_WRONLY);
    if (fd < 0) {
        fprintf(stderr, "watchdog: not available (%s)\n", strerror(errno));
        return -1;
    }
    int t = timeout_s;
    ioctl(fd, WDIOC_SETTIMEOUT, &t);
    pet_pid = fork();
    if (pet_pid == 0) {
        // Pet in a child; it dies with the kernel on kexec, which lets the
        // watchdog fire if the next kernel/initramfs never comes up.
        for (;;) { write(fd, "1", 1); sleep(5); }
    }
    printf("watchdog: armed, timeout=%ds, petter pid=%d\n", t, pet_pid);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <Image> <initramfs.cpio.gz> <cmdline>\n", argv[0]);
        return 2;
    }
    const char* image = argv[1];
    const char* initrd = argv[2];
    const char* cmdline = argv[3];

    int kfd = open(image, O_RDONLY);
    if (kfd < 0) { perror("open Image"); return 1; }
    int ifd = open(initrd, O_RDONLY);
    if (ifd < 0) { perror("open initramfs"); return 1; }

    printf("loading kernel: %s\nloading initrd: %s\ncmdline: %s\n", image, initrd, cmdline);
    long rc = syscall(__NR_kexec_file_load, kfd, ifd, (unsigned long)strlen(cmdline) + 1,
                      cmdline, 0UL);
    if (rc != 0) {
        fprintf(stderr, "kexec_file_load failed: %s\n", strerror(errno));
        return 1;
    }
    printf("kexec_file_load: ok\n");

    arm_watchdog(120);
    sync();
    printf("rebooting into the kexec'd kernel (RB_KEXEC)\n");
    syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
            LINUX_REBOOT_CMD_KEXEC, NULL);
    perror("reboot(RB_KEXEC)");
    disarm_watchdog();
    return 1;
}
