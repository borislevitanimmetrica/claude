/*
 * reboot_ftm.c - reboot into a given reason string by calling the reboot(2)
 * syscall DIRECTLY (LINUX_REBOOT_CMD_RESTART2), bypassing Android init's
 * powerctl switch.
 *
 * Why: on LineageOS, `adb reboot ftm` (and `setprop sys.powerctl reboot,ftm`)
 * goes through init's HandlePowerctlMessage, whose switch/table only treats
 * recovery/fastboot/bootloader as reboot targets and POWERS OFF for anything
 * else. RESTART2 from userspace never powers off - it always reboots and passes
 * the reason string to the kernel reboot-reason handler -> PMIC cookie -> abl.
 *
 * Usage (root):
 *   reboot_ftm            -> reason "ftm"
 *   reboot_ftm factory    -> reason "factory"   (try alternate trigger strings)
 *   reboot_ftm oem-XX     -> whatever abl/kernel actually maps to FTM
 *
 * Build (same toolchain as efs_write_imei):
 *   $CC --target=aarch64-linux-android31 -nostdlib -static -O2 \
 *       -ffreestanding -fno-builtin -fno-stack-protector \
 *       -o reboot_ftm reboot_ftm.c
 *
 * NOTE: have EDL/fastboot recovery ready. Worst case the reason isn't honored
 * and the device boots normally (or to an unexpected mode you can exit).
 */

typedef unsigned char  u8;
typedef long           ssize_t;
typedef unsigned long  size_t;

#define SYS_write     64
#define SYS_reboot    142
#define SYS_exit      94

/* reboot(2): reboot(int magic1, int magic2, unsigned int cmd, void *arg) */
#define LINUX_REBOOT_MAGIC1       0xfee1deadUL
#define LINUX_REBOOT_MAGIC2       0x28121969UL   /* 672274793 */
#define LINUX_REBOOT_CMD_RESTART2 0xA1B2C3D4UL

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
static long sc3(long n, long a0, long a1, long a2) { return sc4(n, a0, a1, a2, 0); }

static ssize_t xwrite(int fd, const void *b, size_t n) { return sc3(SYS_write, fd, (long)b, (long)n); }
static void    xexit (int c) { sc1(SYS_exit, c); for(;;); }

static const char g_nl = 10;
static void nl_(void){ xwrite(1,&g_nl,1); }
static void puts_(const char *s){ size_t n=0; while(s[n])n++; xwrite(1,s,n); }
static void putu(unsigned long v){ if(!v){char z='0';xwrite(1,&z,1);return;} char b[20]; int i=0; while(v){b[i++]='0'+(char)(v%10);v/=10;} while(i--)xwrite(1,&b[i],1); }

/* grab the stack pointer at entry so we can read argc/argv, then jump to C */
__attribute__((naked, noreturn)) void _start(void){
    __asm__ volatile(
        "mov x0, sp\n\t"
        "b   real_start\n\t"
    );
}

void real_start(unsigned long *sp){
    long argc = (long)sp[0];
    char **argv = (char **)&sp[1];
    const char *reason = (argc > 1) ? argv[1] : "ftm";

    puts_("reboot_ftm: RESTART2 reason=\""); puts_(reason); puts_("\" (bypassing init)\n");

    long r = sc4(SYS_reboot,
                 (long)LINUX_REBOOT_MAGIC1,
                 (long)LINUX_REBOOT_MAGIC2,
                 (long)LINUX_REBOOT_CMD_RESTART2,
                 (long)reason);

    /* only reached on failure */
    puts_("reboot syscall returned (FAILED), errno="); putu((unsigned long)(-r)); nl_();
    xexit(1);
}
