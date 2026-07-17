/*
 * qp_wildcard.c — enumerate ALL QRTR services on the modem endpoint
 *
 * Session 73 Step B (per HANDOFF_session72). Sends a wildcard NEW_LOOKUP
 * (service=0, instance=0) to the AP-local qrtr-ns control endpoint at
 * (node=1, port=0xfffffffe), then reads NEW_SERVER (cmd=4) responses for
 * ~2 seconds. Prints (service_id, instance, node, port) for every registered
 * service the kernel knows about — including the OEM service we're hunting.
 *
 * Build (on-device):
 *   aarch64-linux-android31-clang qp_wildcard.c -o qp && chmod +x qp
 * Or cross-compile in Termux/prebuilt NDK. Simplest: adb push, then compile
 * with the on-device clang under Magisk shell if available; otherwise cross.
 *
 * Run:
 *   adb -s 9385711f shell 'su -c /data/local/tmp/qp'
 *
 * On this kernel (Android 12, kernel 5.4.254), QRTR ctrl cmd IDs are the
 * NEWER numbering (confirmed by qd.c work):
 *   NEW_LOOKUP  = 10
 *   NEW_SERVER  = 4
 * If you see zero NEW_SERVER replies, sanity-check by first sending
 * NEW_LOOKUP for service=2 (DMS) — you SHOULD get back at least one row for
 * node=0 port=87 (the DMS the modem exposes).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <linux/qrtr.h>

/* Some kernels don't export QRTR ctrl codes in headers — define locally. */
#ifndef QRTR_TYPE_NEW_LOOKUP
#define QRTR_TYPE_NEW_LOOKUP  10
#endif
#ifndef QRTR_TYPE_NEW_SERVER
#define QRTR_TYPE_NEW_SERVER   4
#endif

/* qrtr control packet layout: 4 u32 fields for NEW_LOOKUP / NEW_SERVER */
struct qrtr_ctrl_pkt_local {
    unsigned int  cmd;      /* NEW_LOOKUP=10 (req) or NEW_SERVER=4 (resp) */
    unsigned int  service;  /* QMI service_id, or 0 for wildcard */
    unsigned int  instance; /* upper 16b = version, lower 16b = instance */
    unsigned int  node;     /* NEW_SERVER only: QRTR node hosting service */
    unsigned int  port;     /* NEW_SERVER only: QRTR port for that service */
};

int main(void) {
    int fd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket AF_QIPCRTR"); return 1; }

    /* Send NEW_LOOKUP for service=0, instance=0 → wildcard, match every
     * service registered anywhere on the QRTR bus. */
    struct qrtr_ctrl_pkt_local req = {
        .cmd      = QRTR_TYPE_NEW_LOOKUP,
        .service  = 0,
        .instance = 0,
        .node     = 0,
        .port     = 0,
    };

    struct sockaddr_qrtr dst = {
        .sq_family = AF_QIPCRTR,
        .sq_node   = 1,               /* AP-local */
        .sq_port   = 0xfffffffe,      /* qrtr-ns control port */
    };

    /* Only cmd + service + instance are meaningful on request. Send full
     * struct anyway — extras are ignored. */
    ssize_t n = sendto(fd, &req, sizeof(req), 0,
                       (struct sockaddr *)&dst, sizeof(dst));
    if (n < 0) { perror("sendto NEW_LOOKUP wildcard"); close(fd); return 1; }
    fprintf(stderr, "sent NEW_LOOKUP wildcard (%zd bytes)\n", n);

    /* Poll for NEW_SERVER replies for 2s. */
    fd_set rfds;
    struct timeval tv;
    int rows = 0;
    printf("%-10s %-10s %-6s %-10s\n", "service", "instance", "node", "port");
    printf("%-10s %-10s %-6s %-10s\n", "-------", "--------", "----", "----");

    for (;;) {
        FD_ZERO(&rfds); FD_SET(fd, &rfds);
        tv.tv_sec = 2; tv.tv_usec = 0;
        int r = select(fd + 1, &rfds, NULL, NULL, &tv);
        if (r < 0) { perror("select"); break; }
        if (r == 0) break;  /* 2s of silence — done */

        struct qrtr_ctrl_pkt_local resp;
        struct sockaddr_qrtr src;
        socklen_t sl = sizeof(src);
        n = recvfrom(fd, &resp, sizeof(resp), 0,
                     (struct sockaddr *)&src, &sl);
        if (n < 0) { perror("recvfrom"); break; }
        if (n < (ssize_t)(sizeof(unsigned int) * 5)) {
            fprintf(stderr, "short reply (%zd bytes) — skipping\n", n);
            continue;
        }
        if (resp.cmd != QRTR_TYPE_NEW_SERVER) {
            fprintf(stderr, "non-NEW_SERVER cmd=%u — skipping\n", resp.cmd);
            continue;
        }
        printf("%-10u %-10u %-6u %-10u\n",
               resp.service, resp.instance, resp.node, resp.port);
        rows++;
    }

    fprintf(stderr, "\ntotal services enumerated: %d\n", rows);
    close(fd);
    return 0;
}
