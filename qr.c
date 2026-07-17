/*
 * qr.c v2 — READ-ONLY OEM QMI probe with slot input.
 *
 * Sends QMI OEM msg_id=4 (NV_READ) to service_id=228 at QRTR (node=0, port=56).
 * Now includes an OPTIONAL slot TLV in addition to the mandatory nv_item TLV.
 * The default slot=0 matches "GSM/UMTS/LTE main subscription" which is what
 * IMEI-slot-0 uses. If msg1 (nv_item-only) returns result=1 error=0 silently,
 * msg2 (nv_item + slot) probes whether the modem needed the slot input.
 *
 * READ-ONLY. msg_id hard-coded to 4. Never touches modem NV; only observes
 * response TLVs.
 *
 * Usage:
 *   qr <nv_item> [slot]
 *
 *   qr 127           # NV-127, slot=0, tries both with and without slot TLV
 *   qr 550 0         # NV-550 IMEI slot 0
 *   qr 88            # NV-88
 *
 * Build:
 *   aarch64-linux-gnu-gcc -O2 -Wall -static -o qr qr.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <linux/qrtr.h>

#define OEM_NODE  0u
#define OEM_PORT  56u
#define MSG_ID_NV_READ  0x0004

static void hexdump(const char *label, const unsigned char *p, size_t n) {
    printf("%s (%zu bytes):\n    ", label, n);
    for (size_t i = 0; i < n; i++) {
        printf("%02x ", p[i]);
        if ((i & 15) == 15 && i + 1 < n) printf("\n    ");
    }
    printf("\n");
}

static void parse_qmi(const unsigned char *p, size_t n) {
    if (n < 7) { printf("    [short response, <7 bytes]\n"); return; }
    unsigned flags = p[0];
    unsigned txn   = p[1] | (p[2] << 8);
    unsigned mid   = p[3] | (p[4] << 8);
    unsigned mlen  = p[5] | (p[6] << 8);
    printf("    SDU: flags=0x%02x txn=%u msg_id=0x%04x msg_len=%u\n",
           flags, txn, mid, mlen);
    size_t off = 7;
    while (off + 3 <= n) {
        unsigned t = p[off];
        unsigned l = p[off+1] | (p[off+2] << 8);
        if (off + 3 + l > n) {
            printf("    TLV type=0x%02x len=%u  [TRUNCATED]\n", t, l);
            break;
        }
        printf("    TLV type=0x%02x len=%-4u val=", t, l);
        for (unsigned i = 0; i < l && i < 32; i++) printf("%02x ", p[off + 3 + i]);
        if (l > 32) printf("... (%u more)", l - 32);
        if (t == 0x02 && l == 4) {
            unsigned r = p[off+3] | (p[off+4] << 8);
            unsigned e = p[off+5] | (p[off+6] << 8);
            printf("  <-- result=%u error=%u", r, e);
        }
        printf("\n");
        off += 3 + l;
    }
    if (off != n) printf("    [%zu trailing bytes]\n", n - off);
}

static int send_probe(int fd, const unsigned char *pkt, size_t len,
                      const char *label) {
    struct sockaddr_qrtr dst = {
        .sq_family = AF_QIPCRTR,
        .sq_node = OEM_NODE,
        .sq_port = OEM_PORT,
    };
    printf("\n=== %s ===\n", label);
    hexdump("--> send", pkt, len);
    ssize_t n = sendto(fd, pkt, len, 0, (struct sockaddr *)&dst, sizeof(dst));
    if (n < 0) { perror("    sendto"); return -1; }

    fd_set rfds; FD_ZERO(&rfds); FD_SET(fd, &rfds);
    struct timeval tv = { 2, 0 };
    int r = select(fd + 1, &rfds, NULL, NULL, &tv);
    if (r < 0) { perror("    select"); return -1; }
    if (r == 0) { printf("    (no response within 2s)\n"); return 0; }

    unsigned char resp[2048];
    struct sockaddr_qrtr src; socklen_t sl = sizeof(src);
    n = recvfrom(fd, resp, sizeof(resp), 0, (struct sockaddr *)&src, &sl);
    if (n < 0) { perror("    recvfrom"); return -1; }
    printf("<-- recv from node=%u port=%u\n", src.sq_node, src.sq_port);
    hexdump("    bytes", resp, (size_t)n);
    parse_qmi(resp, (size_t)n);
    return 1;
}

int main(int argc, char **argv) {
    unsigned nv_item = 127;
    unsigned slot = 0;
    if (argc > 1) nv_item = (unsigned)strtoul(argv[1], NULL, 0);
    if (argc > 2) slot    = (unsigned)strtoul(argv[2], NULL, 0);

    int fd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket AF_QIPCRTR"); return 1; }

    printf("QR: OEM QMI NV_READ probe -> node=%u port=%u  msg_id=0x%04x  nv_item=%u  slot=%u\n",
           OEM_NODE, OEM_PORT, MSG_ID_NV_READ, nv_item, slot);

    /* Attempt 1: nv_item only (TLV 0x01) — same as v1 */
    {
        unsigned char pkt[] = {
            0x00, 0x01, 0x00, 0x04, 0x00, 0x07, 0x00,
            0x01, 0x04, 0x00,
            (unsigned char)nv_item,
            (unsigned char)(nv_item >> 8),
            (unsigned char)(nv_item >> 16),
            (unsigned char)(nv_item >> 24),
        };
        send_probe(fd, pkt, sizeof(pkt), "A: nv_item only (TLV 0x01)");
    }

    /* Attempt 2: nv_item + slot as TLV 0x10 (u8, len=1) */
    {
        unsigned char pkt[] = {
            0x00, 0x02, 0x00, 0x04, 0x00, 0x0b, 0x00,
            0x01, 0x04, 0x00,
            (unsigned char)nv_item,
            (unsigned char)(nv_item >> 8),
            (unsigned char)(nv_item >> 16),
            (unsigned char)(nv_item >> 24),
            0x10, 0x01, 0x00, (unsigned char)slot,
        };
        send_probe(fd, pkt, sizeof(pkt), "B: nv_item + TLV 0x10(slot)");
    }

    /* Attempt 3: nv_item + slot as TLV 0x11 (u8, len=1) — TLV IDs may be
     * swapped from our guess. */
    {
        unsigned char pkt[] = {
            0x00, 0x03, 0x00, 0x04, 0x00, 0x0b, 0x00,
            0x01, 0x04, 0x00,
            (unsigned char)nv_item,
            (unsigned char)(nv_item >> 8),
            (unsigned char)(nv_item >> 16),
            (unsigned char)(nv_item >> 24),
            0x11, 0x01, 0x00, (unsigned char)slot,
        };
        send_probe(fd, pkt, sizeof(pkt), "C: nv_item + TLV 0x11(slot)");
    }

    close(fd);
    return 0;
}
