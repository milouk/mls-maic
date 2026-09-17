/* camio -- read SoC registers through the ISP driver's mmap window on /dev/camera-isp.
 * usage: camio <hex_phys_base> <hex_map_len> <hex_start_off> <hex_end_off>
 * Freestanding (raw syscalls), same recipe as rescue/maic_rescue.c. */
#define AT_FDCWD (-100)
#define O_RDONLY 0
#define SYS_openat 56
#define SYS_close 57
#define SYS_write 64
#define SYS_exit_group 94
#define SYS_munmap 215
#define SYS_mmap 222
#define PROT_READ 1
#define MAP_SHARED 1
typedef unsigned int u32;
static long sys6(long n, long a, long b, long c, long d, long e, long f)
{
	register long x8 __asm__("x8") = n;
	register long x0 __asm__("x0") = a;
	register long x1 __asm__("x1") = b;
	register long x2 __asm__("x2") = c;
	register long x3 __asm__("x3") = d;
	register long x4 __asm__("x4") = e;
	register long x5 __asm__("x5") = f;
	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5) : "memory", "cc");
	return x0;
}
#define sys(n,a,b,c) sys6((n),(long)(a),(long)(b),(long)(c),0,0,0)
static void xexit(int c) { sys(SYS_exit_group, c, 0, 0); for (;;) {} }
static long slen(const char *s) { long n = 0; while (s[n]) n++; return n; }
static void puts_(const char *s) { sys(SYS_write, 1, s, slen(s)); }
static unsigned long hex(const char *s)
{
	unsigned long v = 0;
	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
	for (; *s; s++) {
		int c = *s, d;
		if (c >= '0' && c <= '9') d = c - '0';
		else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
		else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
		else break;
		v = (v << 4) | d;
	}
	return v;
}
static void put_hex(unsigned long v, int digits)
{
	char b[20]; int i = digits;
	b[i] = 0;
	while (i--) { int d = v & 15; b[i] = d < 10 ? '0' + d : 'a' + d - 10; v >>= 4; }
	puts_(b);
}
int c_start(long *sp);
int c_start(long *sp)
{
	long argc = sp[0]; char **argv = (char **)(sp + 1);
	if (argc != 5) { puts_("usage: camio <phys_base> <map_len> <start_off> <end_off> (hex)\n"); xexit(2); }
	unsigned long base = hex(argv[1]), len = hex(argv[2]), s = hex(argv[3]), e = hex(argv[4]);
	if (e > len || s >= e || (s & 3)) { puts_("bad range\n"); xexit(2); }
	long fd = sys(SYS_openat, AT_FDCWD, "/dev/camera-isp", O_RDONLY);
	if (fd < 0) { puts_("open /dev/camera-isp failed: "); put_hex((unsigned long)-fd, 4); puts_("\n"); xexit(1); }
	long m = sys6(SYS_mmap, 0, len, PROT_READ, MAP_SHARED, fd, base);
	if (m < 0 && m > -4096) { puts_("mmap failed: -"); put_hex((unsigned long)-m, 4); puts_("\n"); xexit(1); }
	volatile u32 *r = (volatile u32 *)m;
	for (unsigned long o = s; o < e; o += 4) {
		u32 v = r[o / 4];
		put_hex(base + o, 8); puts_(" "); put_hex(v, 8); puts_("\n");
	}
	sys(SYS_munmap, m, len, 0);
	sys(SYS_close, fd, 0, 0);
	xexit(0);
	return 0;
}
__asm__(".text\n.global _start\n_start:\n\tmov x0, sp\n\tb c_start\n");
