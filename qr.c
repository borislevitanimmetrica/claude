/*
 * qr.c — READ-ONLY OEM QMI probe. Sends QMI OEM msg_id=4 (NV_READ) to
 *         (node=0, port=56)  which we enumerated as service_id=228
 *         (oem_qmi_idl_service_object_v01).
 *
 * READ SAFETY:
 *   - No write opcode is present. msg_id is hard-coded to 4.
 *   - NV item to probe is passed via argv[1] as decimal; defaults to 127.
 *   - Nothing is modified on the modem. This is analogous to qd.c but
 *     targeted at the OEM service rather than DMS.
 *
 * WHY 127:
 *   Per HANDOFF_imei_session.md, HIDL HOOK_NV_READ for NV-127 was already
 *   observed to return error=6 (REQUEST_NOT_SUPPORTED). That means the
 *   modem's OEM handler routes msg_id=4 with our TLV framing to the
 *   dispatcher and *does* reply. So error=6 is the expected "well-formed
 *   request rejected at the policy layer" signal that validates our wire
 *   format.
 *
 * WHAT THIS CONFIRMS (in order):
 *   1. AF_QIPCRTR routes to service_id=228 correctly.
 *   2. Our SDU header layout (ctrl_flag, txn, msg_id, msg_len) is accepted.
 *   3. Our TLV framing (type=0x01, len=4, u32 nv_item) matches the IDL.
 *   4. Response TLV layout reveals the exact wire schema for msg_id=4,
 *      which by symmetry tells us what msg_id=5 will need.
 *
 * WHAT WE DO NOT KNOW YET:
 *   - Whether ctrl_flag should be 0x00 (request) or 0x02 (which qd.c uses
 *     for DMS_GET_IDS and evidently works). This tool tries 0x00 first,
 *     and if no response in 2s, retries with 0x02. Whichever gets a reply
 *     is the one we'll use for the write path.
 *   - Exact TLV type IDs the OEM service uses for the response fields.
 *     The response bytes will show us.
 *
 * Build:
 *   aarch64-linux-gnu-gcc -O2 -Wall -static -o qr qr.c
 * Push+run:
 *   adb -s 9385711f push qr /data/local/tmp/qr && \
 *   adb -s 9385711f shell 'su -c "/data/local/tmp/qr 127"'
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

/* Parse and print a QMI SDU: 7-byte header then TLVs. Returns result/error
 * from a "TLV type 0x02" (standard qmi_result_type_v01) if found. */
static void parse_qmi(const unsigned char *p, size_t n) {
    if (n < 7) { printf("    [short response, <7 bytes]\n"); return; }
    unsigned flags = p[0];
    unsigned txn   = p[1] | (p[2] << 8);
    unsigned mid   = p[3] | (p[4] << 8);
    unsigned mlen  = p[5] | (p[6] << 8);
    printf("    SDU: flags=0x%02x txn=%u msg_id=0x%04x msg_len=%u\n",
           flags, txn, mid, mlen);
    if (7 + mlen > n) {
        printf("    [SDU msg_len exceeds packet, %zu bytes available]\n", n - 7);
    }
    size_t off = 7;
    while (off + 3 <= n) {
        unsigned t = p[off];
        unsigned l = p[off+1] | (p[off+2] << 8);
        if (off + 3 + l > n) {
            printf("    TLV type=0x%02x len=%u  [TRUNCATED, want %zu bytes]\n",
                   t, l, (size_t)(off + 3 + l - n));
            break;
        }
        printf("    TLV type=0x%02x len=%-4u val=", t, l);
        for (unsigned i = 0; i < l; i++) printf("%02x ", p[off + 3 + i]);
        /* If type 0x02 and len 4, decode as qmi_result_type_v01 */
        if (t == 0x02 && l == 4) {
            unsigned r = p[off+3] | (p[off+4] << 8);
            unsigned e = p[off+5] | (p[off+6] << 8);
            printf("  <-- result=%u error=%u", r, e);
        }
        printf("\n");
        off += 3 + l;
    }
    if (off != n) {
        printf("    [%zu trailing bytes after last TLV]\n", n - off);
    }
}

static int try_probe(int fd, unsigned nv_item, unsigned char flag_byte) {
    unsigned char pkt[14] = {
        flag_byte,                    /* ctrl_flag */
        0x01, 0x00,                    /* txn = 1 */
        0x04, 0x00,                    /* msg_id = 4 (NV_READ) */
        0x07, 0x00,                    /* msg_len = 7 (one TLV) */
        0x01,                          /* TLV type = 0x01 (mandatory input) */
        0x04, 0x00,                    /* TLV len = 4 */
        (unsigned char)(nv_item      & 0xff),
        (unsigned char)((nv_item>>8) & 0xff),
        (unsigned char)((nv_item>>16)& 0xff),
        (unsigned char)((nv_item>>24)& 0xff),
    };
    struct sockaddr_qrtr dst = {
        .sq_family = AF_QIPCRTR,
        .sq_node = OEM_NODE,
        .sq_port = OEM_PORT,
    };

    printf("\n=== probe: ctrl_flag=0x%02x  nv_item=%u ===\n", flag_byte, nv_item);
    hexdump("--> send", pkt, sizeof(pkt));

    ssize_t n = sendto(fd, pkt, sizeof(pkt), 0,
                       (struct sockaddr *)&dst, sizeof(dst));
    if (n < 0) { perror("    sendto"); return -1; }

    /* Wait up to 2s for a response */
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
    if (argc > 1) nv_item = (unsigned)strtoul(argv[1], NULL, 0);

    int fd = socket(AF_QIPCRTR, SOCK_DGRAM, 0);
    if (fd < 0) { perror("socket AF_QIPCRTR"); return 1; }

    printf("QR: OEM QMI NV_READ probe -> node=%u port=%u  msg_id=0x%04x  nv_item=%u\n",
           OEM_NODE, OEM_PORT, MSG_ID_NV_READ, nv_item);

    /* Try client-request flag (0x00) first */
    int got = try_probe(fd, nv_item, 0x00);
    if (got <= 0) {
        printf("\n[no reply with ctrl_flag=0x00, retrying with 0x02 (matches qd.c)]\n");
        try_probe(fd, nv_item, 0x02);
    }

    close(fd);
    return 0;
}
