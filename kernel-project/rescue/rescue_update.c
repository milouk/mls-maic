/* update-binary for the MAIC rescue package: restore the boot partition (p9).
 *
 * Recovery extracts META-INF/com/google/android/update-binary to /tmp/update_binary
 * and execs it as:
 *
 *     update_binary <api_version> <status_fd> <package.zip>
 *
 * Stock recovery on this device has NO shell -- /sbin holds only adbd, healthd,
 * multi_init and recovery -- so a Magisk-style script package cannot work. It
 * needs a real binary. This is that binary, built freestanding (-nostdlib,
 * -static) with raw syscalls, because the kernel toolchain has no bionic
 * sysroot and because ~15 KB keeps the package honest. It is deliberately the
 * smallest amount of code that can do the job and still refuse to do it wrong.
 *
 * Why a package at all: this tablet cannot be rescued any other way. Its USB
 * port is a USB-A *receptacle* -- a host port that sources VBUS (measured: it
 * pushes 3 W into a connected Mac) -- so the SoC can never be a USB peripheral:
 * no fastboot, no adb over USB. There is no SD slot. The recovery ramdisk
 * cannot be grown either; this board has a hard 4 MiB ramdisk ceiling that
 * stock recovery already fills to within 560 KB (see mkboot.py). What remains
 * is the vendor's own install path, and it is open to us because recovery's
 * /res/keys is the AOSP test key, whose private half ships in AOSP.
 *
 * This program never decides anything on its own. It restores the image the
 * operator signed into the package, or it refuses and changes nothing. Every
 * check below is a refusal, and the partition is opened for writing only after
 * all of them have passed.
 */

#define AT_FDCWD        (-100)
#define O_RDONLY        0
#define O_WRONLY        1

#define SYS_openat      56
#define SYS_close       57
#define SYS_lseek       62
#define SYS_read        63
#define SYS_write       64
#define SYS_sync        81
#define SYS_fsync       82
#define SYS_exit_group  94

#define PART_SIZE       16777216L   /* p9/p10 are both exactly 16 MiB */
#define CHUNK           (1L << 20)

typedef unsigned char      u8;
typedef unsigned int       u32;
typedef unsigned short     u16;

static long sys(long n, long a, long b, long c)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	__asm__ volatile("svc #0"
			 : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2)
			 : "memory", "cc");
	return x0;
}

static long xopen(const char *p, long flags) { return sys(SYS_openat, AT_FDCWD, (long)p, flags); }
static long xread(long fd, void *b, long n)  { return sys(SYS_read, fd, (long)b, n); }
static long xwrite(long fd, const void *b, long n) { return sys(SYS_write, fd, (long)b, n); }
static long xclose(long fd)                  { return sys(SYS_close, fd, 0, 0); }
static long xlseek(long fd, long off)        { return sys(SYS_lseek, fd, off, 0 /*SEEK_SET*/); }
static void xexit(int c)                     { sys(SYS_exit_group, c, 0, 0); for (;;) {} }

static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }

static int smem(const void *a, const void *b, long n)
{
	const u8 *p = a, *q = b;
	while (n--) if (*p++ != *q++) return 1;
	return 0;
}

/* Read exactly n bytes, or fail. read(2) is allowed to return short. */
static int read_full(long fd, void *buf, long n)
{
	u8 *p = buf;
	while (n > 0) {
		long r = xread(fd, p, n);
		if (r <= 0) return -1;
		p += r; n -= r;
	}
	return 0;
}

static int write_full(long fd, const void *buf, long n)
{
	const u8 *p = buf;
	while (n > 0) {
		long r = xwrite(fd, p, n);
		if (r <= 0) return -1;
		p += r; n -= r;
	}
	return 0;
}

static u32 rd32(const u8 *p) { return p[0] | (p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }
static u16 rd16(const u8 *p) { return (u16)(p[0] | (p[1] << 8)); }

/* ---- recovery's status pipe --------------------------------------------- */
static long g_status_fd = -1;

static void ui_print(const char *s)
{
	if (g_status_fd < 0) return;
	xwrite(g_status_fd, "ui_print ", 9);
	xwrite(g_status_fd, s, slen(s));
	xwrite(g_status_fd, "\n", 1);
	xwrite(g_status_fd, "ui_print\n", 9);   /* flushes the line */
}

static void fail(const char *s) { ui_print("MAIC rescue: REFUSED"); ui_print(s); xexit(1); }

/* ---- buffers (.bss -- no allocator available) ---------------------------- */
static u8 buf[CHUNK];
static u8 vbuf[CHUNK];

/* Checked sum over the image, so the read-back comparison is not just length. */
static unsigned long sum64(const u8 *p, long n, unsigned long h)
{
	for (long i = 0; i < n; i++) h = h * 1099511628211UL ^ p[i];
	return h;
}

static const char *BOOT_BY_NAME = "/dev/block/platform/bootdevice/by-name/boot";
static const char *BOOT_RAW     = "/dev/block/mmcblk0p9";

int c_start(long *sp);

int c_start(long *sp)
{
	long argc = sp[0];
	char **argv = (char **)(sp + 1);

	if (argc >= 3) {
		const char *s = argv[2];
		long v = 0;
		while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
		g_status_fd = v;
	}
	if (argc < 4) fail("no package path given");

	ui_print("MAIC rescue: restoring the boot partition");

	long zf = xopen(argv[3], O_RDONLY);
	if (zf < 0) fail("cannot open the package");

	/* ---- locate boot.img via the local file header at offset 0 ----------
	 * The package is built by make_rescue_zip.py with boot.img first and
	 * STORED, so the payload can be read without an inflate implementation.
	 * Every assumption that makes that true is re-checked here rather than
	 * trusted, because a wrong offset would write garbage to p9.
	 */
	u8 lfh[30];
	if (read_full(zf, lfh, 30) < 0) fail("package is truncated");
	if (rd32(lfh) != 0x04034b50UL) fail("no local file header at offset 0");
	if (rd16(lfh + 6) & 0x0008)    fail("entry uses a data descriptor; sizes are not in the header");
	if (rd16(lfh + 8) != 0)        fail("boot.img is compressed; it must be STORED");

	u32 csize = rd32(lfh + 18);
	u32 usize = rd32(lfh + 22);
	u16 nlen  = rd16(lfh + 26);
	u16 elen  = rd16(lfh + 28);

	if (nlen != 8) fail("first entry is not boot.img");
	char nm[8];
	if (read_full(zf, nm, 8) < 0) fail("package is truncated");
	if (smem(nm, "boot.img", 8)) fail("first entry is not boot.img");

	if (csize != usize)      fail("stored entry has mismatched sizes");
	if (csize != PART_SIZE)  fail("boot.img is not exactly 16 MiB");

	long data_off = 30 + (long)nlen + (long)elen;

	/* ---- pass 1: validate the payload, write nothing -------------------- */
	if (xlseek(zf, data_off) < 0) fail("cannot seek to the image");
	if (read_full(zf, buf, CHUNK) < 0) fail("cannot read the image");

	if (smem(buf, "ANDROID!", 8)) fail("image is not an Android boot image");

	/* Refuse a RECOVERY image on the BOOT partition. LK matches the MTK blob
	 * name, so a recovery ramdisk here yields a kernel with no initramfs and
	 * an unbootable device -- the exact silent failure this tool exists to
	 * undo. The ramdisk blob sits after the page-aligned kernel.
	 */
	u32 ksz  = rd32(buf + 8);
	u32 page = rd32(buf + 36);
	if (page == 0 || page > CHUNK) fail("implausible page_size in the boot header");
	unsigned long roff = page + ((ksz + page - 1) / page) * (unsigned long)page;
	/* The ramdisk lives ~7 MB in, well past the first chunk, so seek to it. */
	if (roff + 40 > (unsigned long)PART_SIZE) fail("ramdisk offset is outside the image");
	u8 mtk[40];
	if (xlseek(zf, data_off + (long)roff) < 0) fail("cannot seek to the ramdisk header");
	if (read_full(zf, mtk, 40) < 0) fail("cannot read the ramdisk header");
	if (rd32(mtk) != 0x58881688UL) fail("ramdisk is not an MTK blob");
	if (smem(mtk + 8, "ROOTFS", 7))
		fail("ramdisk blob is not named ROOTFS -- this is a recovery image, not a boot image");

	unsigned long h = 1469598103934665603UL;
	if (xlseek(zf, data_off) < 0) fail("cannot rewind to checksum the image");
	for (long done = 0; done < PART_SIZE; done += CHUNK) {
		if (read_full(zf, buf, CHUNK) < 0) fail("image is short");
		h = sum64(buf, CHUNK, h);
	}
	unsigned long want = h;

	ui_print("MAIC rescue: image validated, writing");

	/* ---- pass 2: write -------------------------------------------------- */
	long pf = xopen(BOOT_BY_NAME, O_WRONLY);
	if (pf < 0) pf = xopen(BOOT_RAW, O_WRONLY);
	if (pf < 0) fail("cannot open the boot partition");

	if (xlseek(zf, data_off) < 0) fail("cannot rewind the image");
	for (long done = 0; done < PART_SIZE; done += CHUNK) {
		if (read_full(zf, buf, CHUNK) < 0) fail("image is short while writing");
		if (write_full(pf, buf, CHUNK) < 0) fail("write to the boot partition failed");
	}
	sys(SYS_fsync, pf, 0, 0);
	xclose(pf);
	sys(SYS_sync, 0, 0, 0);

	/* ---- pass 3: read back and compare ---------------------------------- */
	ui_print("MAIC rescue: verifying");
	long vf = xopen(BOOT_BY_NAME, O_RDONLY);
	if (vf < 0) vf = xopen(BOOT_RAW, O_RDONLY);
	if (vf < 0) fail("wrote the partition but cannot reopen it to verify");

	unsigned long g = 1469598103934665603UL;
	for (long done = 0; done < PART_SIZE; done += CHUNK) {
		if (read_full(vf, vbuf, CHUNK) < 0) fail("short read while verifying");
		g = sum64(vbuf, CHUNK, g);
	}
	xclose(vf);
	xclose(zf);

	if (g != want) fail("READ-BACK MISMATCH -- the boot partition may be bad");

	ui_print("MAIC rescue: boot partition restored and verified");
	xexit(0);
	return 0;
}

__asm__(
	".text\n"
	".global _start\n"
	"_start:\n"
	"	mov x0, sp\n"
	"	b   c_start\n"
);
