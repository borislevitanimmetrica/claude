/*
 * efs_write_imei.c - write IMEI to the modem EFS item file via /dev/diag using
 * the EFS2 PUT (opcode 38) verb, since legacy NV_WRITE_F (0x27) is rejected
 * (BAD_CMD 0x13) by this modem.
 *
 * Transport is the proven /dev/diag path from nv_write_imei.c v5:
 *   open(/dev/diag) -> ioctl(SWITCH_LOGGING, MEMORY_DEVICE_MODE, APSS|MPSS)
 *   -> write [u32 USER_SPACE_DATA_TYPE][HDLC(req)] -> read [12B MD envelope][HDLC(resp)]
 *
 * EFS2 PUT layout (from qfenix diag.c, verified vs QPST):
 *   [4B][method][38][00][data_len u16][pad u16][flags i32][mode i16][data][path\0]
 *   data starts at offset 14. Response: errno (i16) at offset 6, 0 = success.
 *
 * Freestanding aarch64, no libc (matches nv_write_imei build):
 *   aarch64-linux-android<API>-clang -nostdlib -static -O2 -o efs_write_imei efs_write_imei.c
 *   (or the exact compiler/flags used for nv_write_imei)
 *
 * Run as root with SELinux permissive and diagchar.ko loaded (/dev/diag present).
 */

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef long           ssize_t;
typedef unsigned long  size_t;

#define SYS_openat    56
#define SYS_close     57
#define SYS_read      63
#define SYS_write     64
#define SYS_ioctl     29
#define SYS_exit      94
#define SYS_nanosleep 101
#define AT_FDCWD (-100)
#define O_RDWR    2

static long sc3(long n, long a0, long a1, long a2) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory", "cc");
    return x0;
}
static long sc4(long n, long a0, long a1, long a2, long a3) {
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory", "cc");
    return x0;
}
static long sc1(long n, long a0) { return sc4(n, a0, 0, 0, 0); }
static long sc2(long n, long a0, long a1) { return sc4(n, a0, a1, 0, 0); }

static int     xopen (const char *p)                   { return (int)sc4(SYS_openat, AT_FDCWD, (long)p, O_RDWR, 0); }
static void    xclose(int fd)                          { sc1(SYS_close, fd); }
static ssize_t xread (int fd, void *b, size_t n)       { return sc3(SYS_read,  fd, (long)b, (long)n); }
static ssize_t xwrite(int fd, const void *b, size_t n) { return sc3(SYS_write, fd, (long)b, (long)n); }
static long    xioctl(int fd, unsigned long r, void *a){ return sc3(SYS_ioctl, fd, (long)r, (long)a); }
static void    xexit (int c)                           { sc1(SYS_exit, c); for(;;); }
static void    xsleep_ms(long ms) { long ts[2]; ts[0]=ms/1000; ts[1]=(ms%1000)*1000000L; sc2(SYS_nanosleep,(long)ts,0); }

static const char g_nl = 10;
static void nl_(void){ xwrite(1,&g_nl,1); }
static void puts_(const char *s){ size_t n=0; while(s[n])n++; xwrite(1,s,n); }
static void putc_(char c){ xwrite(1,&c,1); }
static void putln_(const char *s){ puts_(s); nl_(); }
static void puthex8(u8 v){ const char h[]="0123456789abcdef"; putc_(h[v>>4]); putc_(h[v&0xf]); }
static void putu(unsigned long v){ if(!v){putc_('0');return;} char b[20]; int i=0; while(v){b[i++]='0'+(char)(v%10);v/=10;} while(i--)putc_(b[i]); }
static void hex_dump(const char *lbl, const u8 *p, int n){
    puts_(lbl); puts_(" ("); putu((unsigned long)n); puts_(" bytes):"); nl_();
    for(int i=0;i<n;i++){ if(!(i%16))puts_("  "); puthex8(p[i]); putc_(' '); if((i+1)%16==0)nl_(); }
    if(n%16)nl_();
}
/* libc-named mem* so -O2 compiler-emitted calls link under -nostdlib.
   MUST be built with -fno-builtin so these bodies don't self-recurse. */
void *memset(void *s, int c, size_t n){ u8 *p=s; while(n--)*p++=(u8)c; return s; }
void *memcpy(void *d, const void *s, size_t n){ u8 *dp=d; const u8 *sp=s; while(n--)*dp++=*sp++; return d; }
void *memmove(void *d, const void *s, size_t n){ u8 *dp=d; const u8 *sp=s;
    if(dp<sp){ while(n--)*dp++=*sp++; } else { dp+=n; sp+=n; while(n--)*--dp=*--sp; } return d; }

static void xmemset(void *s,u8 c,size_t n){ u8 *p=s; while(n--)*p++=c; }
static void xmemcpy(void *d,const void *s,size_t n){ u8 *dp=d; const u8 *sp=s; while(n--)*dp++=*sp++; }
static size_t xstrlen(const char *s){ size_t n=0; while(s[n])n++; return n; }

/* CRC-16/IBM-SDLC */
static u16 diag_crc16(const u8 *buf, size_t n){
    u16 c=0xFFFF;
    while(n--){ u8 b=*buf++; for(int i=0;i<8;i++){ if((c^b)&1)c=(c>>1)^0x8408; else c>>=1; b>>=1; } }
    return ~c;
}
static size_t hdlc_enc(const u8 *in, size_t ilen, u8 *out){
    u16 crc=diag_crc16(in,ilen);
    u8 tmp[4200]; xmemcpy(tmp,in,ilen);
    tmp[ilen]=(u8)(crc&0xff); tmp[ilen+1]=(u8)(crc>>8);
    size_t total=ilen+2, pos=0;
    for(size_t i=0;i<total;i++){
        u8 b=tmp[i];
        if(b==0x7e){out[pos++]=0x7d;out[pos++]=0x5e;}
        else if(b==0x7d){out[pos++]=0x7d;out[pos++]=0x5d;}
        else out[pos++]=b;
    }
    out[pos++]=0x7e;
    return pos;
}
/* decode in place; returns payload length (excludes 2-byte CRC + trailing 7e) */
static int hdlc_dec(u8 *buf, int len){
    int s=0; while(s<len && buf[s]==0x7e) s++;
    int pos=0, esc=0;
    for(int i=s;i<len;i++){
        if(buf[i]==0x7e) break;
        if(esc){ buf[pos++]=buf[i]^0x20; esc=0; }
        else if(buf[i]==0x7d) esc=1;
        else buf[pos++]=buf[i];
    }
    if(pos<3) return -1;
    return pos-2; /* strip CRC */
}

#define DIAG_IOCTL_SWITCH_LOGGING 7
#define MEMORY_DEVICE_MODE 1
#define DIAG_CON_APSS 0x0001
#define DIAG_CON_MPSS 0x0002
#define USER_SPACE_DATA_TYPE 0x20

struct logmode { u32 req_mode; u32 peripheral_mask; u32 pd_mask; u8 mode_param; u8 diag_id; u8 pd_val; u8 reserved; int peripheral; int device_mask; } __attribute__((packed));

static int switch_md(int fd){
    struct logmode p; xmemset(&p,0,sizeof(p));
    p.req_mode=MEMORY_DEVICE_MODE; p.peripheral_mask=DIAG_CON_APSS|DIAG_CON_MPSS;
    p.peripheral=-1; p.device_mask=1;
    long r=xioctl(fd,DIAG_IOCTL_SWITCH_LOGGING,&p);
    puts_("SWITCH_LOGGING -> "); if(r<0){puts_("ERR ");putu((unsigned long)-r);nl_();return -1;} putln_("OK"); return 0;
}

/* one diag transaction: send req, return decoded response length into out (or -1) */
static int diag_txn(int fd, const u8 *req, size_t reqlen, u8 *out, int outcap){
    u8 w[4+4200];
    w[0]=USER_SPACE_DATA_TYPE; w[1]=0; w[2]=0; w[3]=0;
    size_t flen=hdlc_enc(req,reqlen,w+4);
    hex_dump("TX req(raw)", req, (int)reqlen);
    if(xwrite(fd,w,4+flen) < 0){ putln_("write err"); return -1; }
    for(int it=0; it<15; it++){
        xsleep_ms(80);
        u8 rb[2048];
        ssize_t r=xread(fd,rb,sizeof(rb));
        if(r<=4) continue;                 /* sentinel/empty */
        u8 *p=rb; int plen=(int)r;
        if(r>=12 && rb[0]==USER_SPACE_DATA_TYPE){ p=rb+12; plen=(int)r-12; }   /* MD envelope */
        else if(r>4 && rb[4]==0x7e){ p=rb+4; plen=(int)r-4; }
        u8 dec[2048]; if(plen>2048)plen=2048; xmemcpy(dec,p,(size_t)plen);
        int dl=hdlc_dec(dec,plen);
        if(dl<1) continue;
        hex_dump("RX resp(decoded)", dec, dl);
        int n=dl<outcap?dl:outcap; xmemcpy(out,dec,(size_t)n);
        return n;
    }
    putln_("no response (15 reads)");
    return -1;
}

#define DIAG_SUBSYS_CMD_F 0x4B
#define EFS_STD 0x13
#define EFS_ALT 0x3E
#define EFS2_DIAG_HELLO 0
#define EFS2_DIAG_PUT   38
#define EFS_O_WRONLY   0x0001
#define EFS_O_CREAT    0x0040
#define EFS_O_TRUNC    0x0200
#define EFS_O_ITEMFILE 0x40000
#define EFS_O_AUTODIR  0x80000

static const u8 imei_bcd[9] = {0x08,0x8a,0x86,0x59,0x07,0x06,0x92,0x98,0x38};
static const char EFS_PATH[] = "/nv/item_files/modem/mmode/ue_imei_i";

static int efs_hello(int fd, u8 method){
    u8 cmd[4+0x28]; xmemset(cmd,0,sizeof(cmd));
    cmd[0]=DIAG_SUBSYS_CMD_F; cmd[1]=method; cmd[2]=EFS2_DIAG_HELLO; cmd[3]=0;
    u32 win=0x100000, ver=1, feat=0xFFFFFFFF;
    xmemcpy(&cmd[4],&win,4); xmemcpy(&cmd[8],&win,4); xmemcpy(&cmd[12],&win,4);
    xmemcpy(&cmd[16],&win,4); xmemcpy(&cmd[20],&win,4); xmemcpy(&cmd[24],&win,4);
    xmemcpy(&cmd[28],&ver,4); xmemcpy(&cmd[32],&ver,4); xmemcpy(&cmd[36],&ver,4);
    xmemcpy(&cmd[40],&feat,4);
    u8 rsp[128]; int n=diag_txn(fd,cmd,sizeof(cmd),rsp,sizeof(rsp));
    if(n>=4 && rsp[0]==DIAG_SUBSYS_CMD_F && rsp[1]==method) return 0;
    return -1;
}

static int efs_put(int fd, u8 method){
    u8 cmd[256]; xmemset(cmd,0,sizeof(cmd));
    size_t pl=xstrlen(EFS_PATH)+1;
    u16 dl=9; int flags=EFS_O_CREAT|EFS_O_WRONLY|EFS_O_TRUNC|EFS_O_ITEMFILE|EFS_O_AUTODIR;
    short mode=0644;
    cmd[0]=DIAG_SUBSYS_CMD_F; cmd[1]=method; cmd[2]=EFS2_DIAG_PUT; cmd[3]=0;
    xmemcpy(&cmd[4],&dl,2);          /* data_len u16 */
    /* cmd[6..7] pad = 0 */
    xmemcpy(&cmd[8],&flags,4);       /* flags i32 */
    xmemcpy(&cmd[12],&mode,2);       /* mode i16 */
    xmemcpy(&cmd[14],imei_bcd,9);    /* data */
    xmemcpy(&cmd[23],EFS_PATH,pl);   /* path + nul */
    size_t reqlen=14+9+pl;
    u8 rsp[128]; int n=diag_txn(fd,cmd,reqlen,rsp,sizeof(rsp));
    if(n<8){ putln_("PUT: short/no response"); return 1; }
    /* tolerate a stray leading byte before 0x4B */
    int off=0; if(rsp[0]!=DIAG_SUBSYS_CMD_F && n>1 && rsp[1]==DIAG_SUBSYS_CMD_F) off=1;
    if(rsp[off]!=DIAG_SUBSYS_CMD_F){ puts_("PUT: unexpected cmd=0x"); puthex8(rsp[off]); nl_(); return 1; }
    short errno_; xmemcpy(&errno_,&rsp[off+6],2);
    puts_("PUT errno="); putu((unsigned long)(errno_<0?-errno_:errno_)); if(errno_<0)puts_(" (neg)"); nl_();
    if(errno_==0){ putln_("*** SUCCESS: ue_imei_i written. adb reboot, then *#06# ***"); return 0; }
    return 1;
}

static int run(void){
    putln_("efs_write_imei: EFS2 PUT of IMEI 868957060298983 to ue_imei_i");
    int fd=xopen("/dev/diag");
    if(fd<0){ puts_("open /dev/diag failed errno="); putu((unsigned long)-fd); nl_(); return 1; }
    switch_md(fd);

    u8 method=EFS_STD;
    putln_("HELLO(ALT 0x3E)...");
    if(efs_hello(fd,EFS_ALT)==0){ method=EFS_ALT; putln_("  -> ALT ok"); }
    else { putln_("HELLO(STD 0x13)..."); if(efs_hello(fd,EFS_STD)==0){ method=EFS_STD; putln_("  -> STD ok"); }
           else putln_("  -> no HELLO ack; trying PUT with STD anyway"); }

    puts_("PUT with method=0x"); puthex8(method); nl_();
    int rc=efs_put(fd,method);
    if(rc && method==EFS_STD){ putln_("retry PUT with method=ALT 0x3E"); rc=efs_put(fd,EFS_ALT); }
    xclose(fd);
    return rc;
}

void _start(void){ xexit(run()); }
