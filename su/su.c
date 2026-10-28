/*
 * ghost_su — userspace root shell broker for the LDY-AN00 GhostLock exploit.
 *
 * The exploit's escalated child (uid 0, SID u:r:kernel:s0, SELinux permissive)
 * runs `su --daemon`.  The daemon listens on a UNIX socket and, for each
 * connecting ADB shell (uid 2000), forks /system/bin/sh with root
 * credentials and the socket as stdio.
 *
 * Any later `adb shell` can then run:
 *   /data/local/tmp/su                 # interactive root shell
 *   /data/local/tmp/su -c 'id'         # one root command
 *
 * The daemon accepts only uid 0 and uid 2000 (the adb shell user) via
 * SO_PEERCRED; other apps are rejected.  Root is per-boot: the daemon and
 * the exploit state disappear on reboot.
 *
 * Build: aarch64-linux-gnu-gcc -static -O2 -o su su/su.c
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#define SU_SOCKET "/data/local/tmp/.ghost_su.sock"
#define SU_SHELL  "/system/bin/sh"
#define ADB_SHELL_UID 2000

static int write_all(int fd, const void *buf, size_t len)
{
    const char *p = buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static void daemonize(void)
{
    pid_t p = fork();
    if (p < 0)
        _exit(1);
    if (p > 0)
        _exit(0);
    if (setsid() < 0)
        _exit(1);
    p = fork();
    if (p < 0)
        _exit(1);
    if (p > 0)
        _exit(0);
    if (chdir("/") != 0)
        _exit(1);
    umask(0);
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, STDIN_FILENO);
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO)
            close(fd);
    }
    /* Reap forked shells; never die on a closed terminal. */
    signal(SIGCHLD, SIG_IGN);
    signal(SIGHUP, SIG_IGN);
}

static int daemon_main(void)
{
    daemonize();

    /* Keep the broker out of the low-memory killer's way. */
    int oom = open("/proc/self/oom_score_adj", O_WRONLY | O_CLOEXEC);
    if (oom >= 0) {
        ssize_t wr = write(oom, "-1000", 5);
        (void)wr;
        close(oom);
    }

    unlink(SU_SOCKET);
    int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (s < 0)
        return 1;

    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    strncpy(sa.sun_path, SU_SOCKET, sizeof(sa.sun_path) - 1);
    if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) != 0)
        return 1;
    (void)chmod(SU_SOCKET, 0666);
    if (listen(s, 16) != 0)
        return 1;

    for (;;) {
        int c = accept4(s, NULL, NULL, SOCK_CLOEXEC);
        if (c < 0) {
            if (errno == EINTR)
                continue;
            usleep(100000);
            continue;
        }

        /* Only root and the adb shell user may ask for a root shell. */
        struct ucred cr;
        socklen_t cl = sizeof(cr);
        if (getsockopt(c, SOL_SOCKET, SO_PEERCRED, &cr, &cl) != 0 ||
            (cr.uid != 0 && cr.uid != ADB_SHELL_UID)) {
            close(c);
            continue;
        }

        pid_t p = fork();
        if (p == 0) {
            close(s);
            dup2(c, STDIN_FILENO);
            dup2(c, STDOUT_FILENO);
            dup2(c, STDERR_FILENO);
            if (c > STDERR_FILENO)
                close(c);
            execl(SU_SHELL, "sh", "-i", (char *)NULL);
            _exit(127);
        }
        close(c);
    }
}

static int client_main(int argc, char **argv)
{
    const char *cmd = NULL;
    if (argc == 3 && strcmp(argv[1], "-c") == 0) {
        cmd = argv[2];
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [-c command]\n", argv[0]);
        return 2;
    }

    int s = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (s < 0) {
        perror("su: socket");
        return 1;
    }
    struct sockaddr_un sa;
    memset(&sa, 0, sizeof(sa));
    sa.sun_family = AF_UNIX;
    strncpy(sa.sun_path, SU_SOCKET, sizeof(sa.sun_path) - 1);
    if (connect(s, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
        fprintf(stderr, "su: root daemon not running; run ./root.sh first\n");
        close(s);
        return 1;
    }

    if (cmd) {
        if (write_all(s, cmd, strlen(cmd)) != 0 ||
            write_all(s, "\n", 1) != 0) {
            close(s);
            return 1;
        }
        shutdown(s, SHUT_WR);
    }

    int tty = isatty(STDIN_FILENO);
    struct termios saved;
    if (tty && tcgetattr(STDIN_FILENO, &saved) == 0) {
        struct termios raw = saved;
        cfmakeraw(&raw);
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }

    int stdin_open = (cmd == NULL);
    char buf[8192];
    for (;;) {
        struct pollfd pfd[2];
        pfd[0].fd = stdin_open ? STDIN_FILENO : -1;
        pfd[0].events = POLLIN;
        pfd[0].revents = 0;
        pfd[1].fd = s;
        pfd[1].events = POLLIN;
        pfd[1].revents = 0;

        int r = poll(pfd, 2, -1);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (pfd[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n > 0) {
                if (write_all(s, buf, (size_t)n) != 0)
                    break;
            } else {
                stdin_open = 0;
                shutdown(s, SHUT_WR);
            }
        }
        if (pfd[1].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t n = read(s, buf, sizeof(buf));
            if (n > 0) {
                if (write_all(STDOUT_FILENO, buf, (size_t)n) != 0)
                    break;
            } else {
                break;
            }
        }
    }

    if (tty)
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &saved);
    close(s);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc >= 2 && strcmp(argv[1], "--daemon") == 0)
        return daemon_main();
    return client_main(argc, argv);
}
