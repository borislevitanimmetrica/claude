/*
 * qat.c — send an AT command to /dev/at_mdm0 and print the response.
 *
 * READ-ONLY for our purposes now: we'll invoke with AT+CGSN or AT+EGMR=0,7
 * to verify the AT-command tunnel reaches the modem and returns real data.
 *
 * The command is passed as argv[1] verbatim (no CR/LF needed; the tool
 * appends "\r"). Response is read for up to 2 seconds and dumped as both
 * raw hex and ASCII-with-CR/LF-visible.
 *
 * Safety: this tool sends whatever argv[1] says. Do NOT invoke with
 * AT+EGMR=1,... (write) until we've confirmed the read path works and
 * every byte of the payload has been reviewed. IMEI is irreversible.
 *
 * Build:
 *   aarch64-linux-gnu-gcc -O2 -Wall -static -o qat qat.c
 * Run:
 *   adb -s 9385711f push qat /data/local/tmp/qat
 *   adb -s 9385711f shell 'su -c "/data/local/tmp/qat \"AT\""'
 *   adb -s 9385711f shell 'su -c "/data/local/tmp/qat \"AT+CGSN\""'
 *   adb -s 9385711f shell 'su -c "/data/local/tmp/qat \"AT+EGMR=0,7\""'
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <termios.h>
#include <sys/select.h>
#include <sys/time.h>

#define AT_DEVICE  "/dev/at_mdm0"
#define READ_MS    2000
#define BUF_SIZE   4096

static void hexdump(const unsigned char *p, size_t n) {
    printf("--- response (%zu bytes) ---\n", n);
    /* text form with escaped CR/LF for readability */
    printf("text: ");
    for (size_t i = 0; i < n; i++) {
        unsigned c = p[i];
        if (c == '\r') printf("\\r");
        else if (c == '\n') printf("\\n\n      ");
        else if (c >= 0x20 && c < 0x7f) putchar(c);
        else printf("\\x%02x", c);
    }
    printf("\n");
    /* raw hex */
    printf("hex:  ");
    for (size_t i = 0; i < n; i++) {
        printf("%02x ", p[i]);
        if ((i & 15) == 15 && i + 1 < n) printf("\n      ");
    }
    printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s \"AT+COMMAND\"\n", argv[0]);
        return 1;
    }

    int fd = open(AT_DEVICE, O_RDWR | O_NOCTTY);
    if (fd < 0) { perror("open " AT_DEVICE); return 1; }

    /* Configure raw mode so no line-discipline processing mangles bytes. */
    struct termios t;
    if (tcgetattr(fd, &t) == 0) {
        cfmakeraw(&t);
        t.c_cc[VMIN] = 0;
        t.c_cc[VTIME] = 0;
        if (tcsetattr(fd, TCSANOW, &t) < 0) {
            perror("tcsetattr (non-fatal)");
        }
    } else {
        /* Not a tty — some smd nodes aren't real ttys. Continue anyway. */
        fprintf(stderr, "note: %s is not a tty (tcgetattr: %s) — proceeding raw\n",
                AT_DEVICE, strerror(errno));
    }

    /* Drain any pending bytes so we start clean. */
    unsigned char drain[256];
    fd_set rf;
    struct timeval tv;
    for (int i = 0; i < 5; i++) {
        FD_ZERO(&rf); FD_SET(fd, &rf);
        tv.tv_sec = 0; tv.tv_usec = 50000;
        int r = select(fd + 1, &rf, NULL, NULL, &tv);
        if (r <= 0) break;
        (void)read(fd, drain, sizeof(drain));
    }

    /* Build the command with CR terminator. Most Qualcomm AT interpreters
     * accept CR alone; some want CRLF. Send CR — the interpreter echoes back
     * so we'll see whichever it wanted. */
    size_t cmd_len = strlen(argv[1]);
    char cmd[BUF_SIZE];
    if (cmd_len + 2 > sizeof(cmd)) {
        fprintf(stderr, "command too long\n"); close(fd); return 1;
    }
    memcpy(cmd, argv[1], cmd_len);
    cmd[cmd_len++] = '\r';

    printf("--- sending %zu bytes: \"%s\\r\" ---\n", cmd_len, argv[1]);
    printf("hex:  ");
    for (size_t i = 0; i < cmd_len; i++) printf("%02x ", (unsigned char)cmd[i]);
    printf("\n");

    ssize_t w = write(fd, cmd, cmd_len);
    if (w < 0) { perror("write"); close(fd); return 1; }
    if ((size_t)w != cmd_len) fprintf(stderr, "warn: short write %zd/%zu\n", w, cmd_len);

    /* Read for up to READ_MS milliseconds, or until we see "\r\nOK\r\n" or
     * "\r\nERROR\r\n" or "\r\n+CME ERROR:" tail. */
    unsigned char resp[BUF_SIZE];
    size_t off = 0;
    struct timeval deadline;
    gettimeofday(&deadline, NULL);
    long deadline_us = deadline.tv_sec * 1000000L + deadline.tv_usec + READ_MS * 1000L;

    while (off + 1 < sizeof(resp)) {
        struct timeval now; gettimeofday(&now, NULL);
        long now_us = now.tv_sec * 1000000L + now.tv_usec;
        long remain_us = deadline_us - now_us;
        if (remain_us <= 0) break;

        FD_ZERO(&rf); FD_SET(fd, &rf);
        tv.tv_sec = remain_us / 1000000L;
        tv.tv_usec = remain_us % 1000000L;
        int r = select(fd + 1, &rf, NULL, NULL, &tv);
        if (r < 0) { perror("select"); break; }
        if (r == 0) break;

        ssize_t n = read(fd, resp + off, sizeof(resp) - off - 1);
        if (n < 0) { perror("read"); break; }
        if (n == 0) break;
        off += (size_t)n;

        /* Check for terminator. Look at the tail. */
        if (off >= 6) {
            const unsigned char *tail = resp + off;
            /* Look for OK or ERROR ending */
            if ((off >= 6 && memmem(resp, off, "\r\nOK\r\n", 6)) ||
                (off >= 9 && memmem(resp, off, "\r\nERROR\r\n", 9)) ||
                (memmem(resp, off, "\r\n+CME ERROR", 12))) {
                /* Give a little more time in case tail bytes still coming */
                tv.tv_sec = 0; tv.tv_usec = 100000;
                FD_ZERO(&rf); FD_SET(fd, &rf);
                if (select(fd + 1, &rf, NULL, NULL, &tv) > 0) {
                    ssize_t n2 = read(fd, resp + off, sizeof(resp) - off - 1);
                    if (n2 > 0) off += (size_t)n2;
                }
                break;
            }
            (void)tail;
        }
    }

    resp[off] = 0;
    hexdump(resp, off);
    close(fd);
    return 0;
}
