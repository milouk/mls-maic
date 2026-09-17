/* maic_rescue -- restore the boot partition from inside recovery.
 *
 * Runs as a oneshot init service in the recovery ramdisk:
 *
 *     service maic_rescue /sbin/maic_rescue
 *         oneshot
 *         seclabel u:r:recovery:s0
 *
 * Purpose: make p9 (boot) reversible, so a kernel can actually be tested there.
 * Without this the device has no rescue path at all -- its USB port is a USB-A
 * *receptacle*, a host port that sources VBUS (measured: 3 W into a connected
 * Mac), so the SoC can never be a USB peripheral: no fastboot, no adb over USB.
 * There is no SD slot. And the vendor's own OTA route is gated by MediaTek's
 * check_part_size(), which demands a scatter.txt and sits next to code that can
 * rewrite the GPT and format userdata -- not somewhere to go on a guess.
 *
 * WHY THIS IS A BINARY AND NOT A SHELL SCRIPT
 * Stock recovery has no shell; /sbin holds only adbd, healthd, multi_init and
 * recovery. The first attempt at this added Magisk's 1.7 MB static busybox to
 * get one, which pushed the ramdisk past the board's hard 4 MiB ceiling and
 * bootlooped the device (see mkboot.py). Freestanding with raw syscalls, this
 * costs ~5 KB against 573 KB of headroom, and mkboot.py now fails the build
 * rather than letting that recur.
 *
 * SAFETY RULES BAKED IN HERE
 *   * Does nothing unless an operator pre-armed it. Absent trigger => exit 0
 *     immediately, so an ordinary recovery boot is untouched.
 *   * Mounts /data READ-ONLY. We never write userdata ourselves. Note the one
 *     honest caveat: if the filesystem is dirty, ext4 still replays its journal
 *     ("recovery required on readonly filesystem / write access will be enabled
 *     during recovery"), so the kernel does touch the partition. That is the
 *     same replay every normal boot performs, and it is what makes the image we
 *     are about to read consistent, so it is wanted -- but "read-only" here
 *     means we issue no writes, not that the block device is untouched.
 *   * Opens the boot partition for writing only after every check has passed.
 *   * Refuses a RECOVERY image on the BOOT partition -- LK matches the MTK blob
 *     name, so that mistake yields a kernel with no initramfs, which is the
 *     exact silent failure this tool exists to undo.
 *   * Never loops, never blocks, always exits 0 so init cannot consider it
 *     failed. It is not a critical service, but a clean exit removes all doubt.
 *   * Leaves the trigger alone. /data is read-only here, so disarming happens
 *     from Android. Re-running is idempotent: it writes the same bytes again.
 */

#define AT_FDCWD        (-100)
#define O_RDONLY        0
#define O_WRONLY        1
#define O_CREAT         64
#define O_TRUNC         512
#define MS_RDONLY       1
#define SEEK_SET        0
#define SEEK_END        2

#define SYS_newfstatat  79
#define SYS_umount2     39
#define SYS_mount       40
#define SYS_openat      56
#define SYS_close       57
#define SYS_lseek       62
#define SYS_read        63
#define SYS_write       64
#define SYS_sync        81
#define SYS_fsync       82
#define SYS_exit_group  94

#define PART_SIZE       16777216L
#define CHUNK           (524288L)          /* 32 passes; PART_SIZE % CHUNK == 0 */

typedef unsigned char  u8;
typedef unsigned int   u32;
typedef unsigned short u16;

static long sys5(long n, long a, long b, long c, long d, long e)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	__asm__ volatile("svc #0"
			 : "+r"(x0)
			 : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4)
			 : "memory", "cc");
	return x0;
}
#define sys(n, a, b, c) sys5((n), (long)(a), (long)(b), (long)(c), 0, 0)

static long xopen(const char *p, long fl) { return sys(SYS_openat, AT_FDCWD, p, fl); }
static long xread(long f, void *b, long n) { return sys(SYS_read, f, b, n); }
static long xwrite(long f, const void *b, long n) { return sys(SYS_write, f, b, n); }
static long xclose(long f) { return sys(SYS_close, f, 0, 0); }
static long xseek(long f, long o, long w) { return sys(SYS_lseek, f, o, w); }
static void xexit(int c) { sys(SYS_exit_group, c, 0, 0); for (;;) {} }

static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static int smem(const void *a, const void *b, long n)
{
	const u8 *p = a, *q = b;
	while (n--) if (*p++ != *q++) return 1;
	return 0;
}
static int read_full(long f, void *b, long n)
{
	u8 *p = b;
	while (n > 0) { long r = xread(f, p, n); if (r <= 0) return -1; p += r; n -= r; }
	return 0;
}
static int write_full(long f, const void *b, long n)
{
	const u8 *p = b;
	while (n > 0) { long r = xwrite(f, p, n); if (r <= 0) return -1; p += r; n -= r; }
	return 0;
}
static u32 rd32(const u8 *p) { return p[0] | (p[1] << 8) | ((u32)p[2] << 16) | ((u32)p[3] << 24); }

static u8 buf[CHUNK];
static u8 vbuf[CHUNK];

/* ---- logging ------------------------------------------------------------
 * Two channels, because the first one alone proved useless.
 *
 * /dev/kmsg goes to pstore, but pstore's console zone is only 64 KB and a
 * recovery boot ends with init dumping a "get device"/"shutdown" line for every
 * device in the tree. That overran the ring and threw away everything before
 * ~17 s -- including this program's entire output at ~2 s. The first run of
 * this tool was therefore unobservable: nothing in the log either way.
 *
 * So the real record goes to a file on /cache. /cache is the disposable
 * partition -- recovery already writes its own logs there -- so mounting it
 * read-write briefly costs nothing even if the write is interrupted, and
 * crucially it is NOT userdata, which stays read-only throughout.
 */
static long kfd = -1;
static char logbuf[4096];
static long loglen = 0;

static void klog(const char *s)
{
	long n = slen(s);
	if (loglen + n + 1 <= (long)sizeof(logbuf)) {
		for (long i = 0; i < n; i++) logbuf[loglen++] = s[i];
		logbuf[loglen++] = '\n';
	}
	if (kfd < 0) return;
	/* <2> is KERN_CRIT: console_loglevel gates printk before it ever reaches
	 * pstore, and a default-level message can be dropped outright. */
	xwrite(kfd, "<2>maic_rescue: ", 16);
	xwrite(kfd, s, slen(s));
	xwrite(kfd, "\n", 1);
}

/* st_dev of a path; 0 on error. arm64 struct stat has st_dev first, 8 bytes. */
static unsigned long devof(const char *p)
{
	unsigned long st[16];
	if (sys5(SYS_newfstatat, AT_FDCWD, (long)p, (long)st, 0, 0) < 0) return 0;
	return st[0];
}

static const char *CACHE1 = "/dev/block/platform/bootdevice/by-name/cache";
static const char *CACHE2 = "/dev/block/mmcblk0p21";

static void flush_status(void)
{
	/* Try the open FIRST, and only mount if /cache is not already there.
	 *
	 * init starts /sbin/recovery about 2 ms after it starts us, and recovery
	 * mounts /cache almost immediately -- measured at 11.977 s against our
	 * finish at 13.346 s. Mounting /cache again on top of recovery's mount
	 * silently stacks a second filesystem over the same directory: the write
	 * lands on OUR mount, and umount2() then takes it away again, so the file
	 * is nowhere to be seen afterwards. That is exactly what happened on the
	 * first successful run -- p9 was correctly rewritten and verified, and the
	 * log simply vanished.
	 *
	 * Deciding by "did the open fail" is not good enough either: /cache is a
	 * real directory in the ramdisk, so when nothing is mounted there the open
	 * SUCCEEDS and the log is written to tmpfs, which disappears at reboot --
	 * losing the record just as silently. So ask the kernel directly: if
	 * /cache and / are the same device, nothing is mounted on it.
	 */
	int ours = 0;
	if (devof("/cache") == devof("/")) {
		if (sys5(SYS_mount, (long)CACHE1, (long)"/cache", (long)"ext4", 0, 0) < 0 &&
		    sys5(SYS_mount, (long)CACHE2, (long)"/cache", (long)"ext4", 0, 0) < 0)
			return;
		ours = 1;
	}
	/* openat(dirfd, path, flags, mode) -- four args, so the sixth slot is unused. */
	long f = sys5(SYS_openat, AT_FDCWD, (long)"/cache/maic_rescue.log",
		      O_WRONLY | O_CREAT | O_TRUNC, 0644, 0);
	if (f >= 0) {
		write_full(f, logbuf, loglen);
		sys(SYS_fsync, f, 0, 0);
		xclose(f);
	}

	/* Rescue the PREVIOUS boot's console log -- the whole reason we can debug
	 * a bad kernel on p9 at all.
	 *
	 * pstore keeps exactly ONE previous boot. If p9 boots badly, its console
	 * survives only until the next boot writes over the ring -- and the next
	 * boot is this recovery, whose own output destroys it. By the time Android
	 * is back, /proc/last_kmsg holds recovery's log and the interesting one is
	 * gone forever.
	 *
	 * Right now, though, /proc/last_kmsg IS the failed boot. This is the only
	 * moment it exists, so copy it out unconditionally -- armed or not, restore
	 * or refusal. It costs one file on the disposable partition.
	 *
	 * Do NOT trust st_size: procfs reports 0 for this file even when it has
	 * ~64 KB of content (confirmed on this device), so read until EOF instead.
	 */
	static const char *SRCS[2] = { "/proc/last_kmsg",
				       "/sys/fs/pstore/console-ramoops" };
	static const char *DSTS[2] = { "/cache/maic_lastkmsg.txt",
				       "/cache/maic_pstore_console.txt" };
	for (int i = 0; i < 2; i++) {
		long s = xopen(SRCS[i], O_RDONLY);
		if (s < 0) continue;
		long d = sys5(SYS_openat, AT_FDCWD, (long)DSTS[i],
			      O_WRONLY | O_CREAT | O_TRUNC, 0644, 0);
		if (d >= 0) {
			for (;;) {
				long n = xread(s, buf, CHUNK);
				if (n <= 0) break;
				if (write_full(d, buf, n) < 0) break;
			}
			sys(SYS_fsync, d, 0, 0);
			xclose(d);
		}
		xclose(s);
	}

	sys(SYS_sync, 0, 0, 0);
	if (ours) sys(SYS_umount2, "/cache", 0, 0);
}

static void done(const char *msg)
{
	klog(msg);
	sys(SYS_umount2, "/data", 0, 0);   /* userdata goes away before /cache is touched */
	flush_status();
	xexit(0);
}

static unsigned long sum64(const u8 *p, long n, unsigned long h)
{
	for (long i = 0; i < n; i++) h = h * 1099511628211UL ^ p[i];
	return h;
}

static const char *UD1 = "/dev/block/platform/bootdevice/by-name/userdata";
static const char *UD2 = "/dev/block/mmcblk0p22";
static const char *BP1 = "/dev/block/platform/bootdevice/by-name/boot";
static const char *BP2 = "/dev/block/mmcblk0p9";
static const char *TRIG = "/data/maic_rescue/DO_RESTORE";
static const char *IMG  = "/data/maic_rescue/boot_restore.img";

int c_start(long *sp);

int c_start(long *sp)
{
	(void)sp;
	kfd = xopen("/dev/kmsg", O_WRONLY);
	klog("start");

	/* Read-only: we only read the image, and userdata must never be at risk. */
	if (sys5(SYS_mount, (long)UD1, (long)"/data", (long)"ext4", MS_RDONLY, 0) < 0 &&
	    sys5(SYS_mount, (long)UD2, (long)"/data", (long)"ext4", MS_RDONLY, 0) < 0) {
		klog("could not mount userdata read-only; taking no action");
		flush_status();
		xexit(0);
	}
	klog("mounted /data read-only");

	long t = xopen(TRIG, O_RDONLY);
	if (t < 0) done("no trigger armed; normal recovery boot, taking no action");
	xclose(t);
	klog("TRIGGER ARMED");

	long f = xopen(IMG, O_RDONLY);
	if (f < 0) done("REFUSED: trigger set but boot_restore.img is missing");

	if (xseek(f, 0, SEEK_END) != PART_SIZE) done("REFUSED: image is not exactly 16 MiB");
	if (xseek(f, 0, SEEK_SET) != 0) done("REFUSED: cannot rewind the image");

	if (read_full(f, buf, CHUNK) < 0) done("REFUSED: cannot read the image");
	if (smem(buf, "ANDROID!", 8)) done("REFUSED: not an Android boot image");

	u32 ksz = rd32(buf + 8), page = rd32(buf + 36);
	if (page == 0 || page > CHUNK) done("REFUSED: implausible page_size");
	unsigned long roff = page + ((ksz + page - 1) / page) * (unsigned long)page;
	if (roff + 40 > (unsigned long)PART_SIZE) done("REFUSED: ramdisk offset outside image");
	u8 mtk[40];
	if (xseek(f, (long)roff, SEEK_SET) < 0) done("REFUSED: cannot seek to ramdisk header");
	if (read_full(f, mtk, 40) < 0) done("REFUSED: cannot read ramdisk header");
	if (rd32(mtk) != 0x58881688UL) done("REFUSED: ramdisk is not an MTK blob");
	if (smem(mtk + 8, "ROOTFS", 7))
		done("REFUSED: ramdisk blob is not ROOTFS -- that is a recovery image");

	unsigned long want = 1469598103934665603UL;
	if (xseek(f, 0, SEEK_SET) != 0) done("REFUSED: cannot rewind to checksum");
	for (long i = 0; i < PART_SIZE; i += CHUNK) {
		if (read_full(f, buf, CHUNK) < 0) done("REFUSED: image is short");
		want = sum64(buf, CHUNK, want);
	}
	klog("image validated; writing boot partition");

	long p = xopen(BP1, O_WRONLY);
	if (p < 0) p = xopen(BP2, O_WRONLY);
	if (p < 0) done("REFUSED: cannot open the boot partition");

	if (xseek(f, 0, SEEK_SET) != 0) done("REFUSED: cannot rewind to write");
	for (long i = 0; i < PART_SIZE; i += CHUNK) {
		if (read_full(f, buf, CHUNK) < 0) done("FAILED: image short while writing");
		if (write_full(p, buf, CHUNK) < 0) done("FAILED: write error on boot partition");
	}
	sys(SYS_fsync, p, 0, 0);
	xclose(p);
	sys(SYS_sync, 0, 0, 0);

	long v = xopen(BP1, O_RDONLY);
	if (v < 0) v = xopen(BP2, O_RDONLY);
	if (v < 0) done("FAILED: wrote but cannot reopen to verify");
	unsigned long got = 1469598103934665603UL;
	for (long i = 0; i < PART_SIZE; i += CHUNK) {
		if (read_full(v, vbuf, CHUNK) < 0) done("FAILED: short read while verifying");
		got = sum64(vbuf, CHUNK, got);
	}
	xclose(v);
	xclose(f);

	if (got != want) done("FAILED: READ-BACK MISMATCH -- boot partition may be bad");
	done("SUCCESS: boot partition restored and verified");
	return 0;
}

__asm__(
	".text\n"
	".global _start\n"
	"_start:\n"
	"	mov x0, sp\n"
	"	b   c_start\n"
);
