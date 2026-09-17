/* dispwarm -- set the MTK display CCORR 3x3 color-correction matrix.
 * Usage: dispwarm <c00> <c01> <c02> <c10> <c11> <c12> <c20> <c21> <c22>
 *   9 decimal coefficients (MTK "corr10" fixed-point; identity diagonal is typically 1024).
 *   Warm/night: reduce c22 (blue) and slightly c11 (green) below identity; day: pass identity.
 * Issues DISP_IOCTL_SET_CCORR = _IOW('x', 24, DISP_CCORR_COEF_T) on /dev/mtk_disp_mgr.
 *   struct DISP_CCORR_COEF_T { int hw_id; unsigned int coef[3][3]; }  (hw_id 0 = CCORR0)
 * Freestanding (raw syscalls), same recipe as camio.c / rescue. Revert = pass identity. */
#define AT_FDCWD (-100)
#define O_RDWR 2
#define SYS_openat 56
#define SYS_close 57
#define SYS_ioctl 29
#define SYS_write 64
#define SYS_exit_group 94
#define CCORR_IOCTL 0x40287818UL   /* _IOW('x',24,40): dir1<<30 | size40<<16 | 'x'<<8 | 24 */
typedef unsigned int u32;
static long sys4(long n,long a,long b,long c,long d){
  register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a;
  register long x1 __asm__("x1")=b; register long x2 __asm__("x2")=c; register long x3 __asm__("x3")=d;
  __asm__ volatile("svc #0":"+r"(x0):"r"(x8),"r"(x1),"r"(x2),"r"(x3):"memory","cc"); return x0;
}
static void xexit(int c){ sys4(SYS_exit_group,c,0,0,0); for(;;){} }
static long slen(const char*s){long n=0;while(s[n])n++;return n;}
static void puts_(const char*s){ sys4(SYS_write,1,(long)s,slen(s),0); }
static int sdec(const char*s,long*out){ long v=0; int neg=0,any=0; if(*s=='-'){neg=1;s++;}
  for(;*s;s++){ if(*s<'0'||*s>'9') return 0; v=v*10+(*s-'0'); any=1; } *out=neg?-v:v; return any; }
struct ccorr { int hw_id; u32 coef[9]; };
int c_start(long*sp);
int c_start(long*sp){
  long argc=sp[0]; char**argv=(char**)(sp+1);
  if(argc!=10){ puts_("usage: dispwarm c00 c01 c02 c10 c11 c12 c20 c21 c22 (9 decimals)\n"); xexit(2); }
  struct ccorr cc; cc.hw_id=0;
  for(int i=0;i<9;i++){ long v; if(!sdec(argv[i+1],&v)){ puts_("bad coefficient\n"); xexit(2);} cc.coef[i]=(u32)v; }
  long fd=sys4(SYS_openat,AT_FDCWD,(long)"/dev/mtk_disp_mgr",O_RDWR,0);
  if(fd<0){ puts_("open /dev/mtk_disp_mgr failed\n"); xexit(1); }
  long r=sys4(SYS_ioctl,fd,(long)CCORR_IOCTL,(long)&cc,0);
  sys4(SYS_close,fd,0,0,0);
  if(r<0){ puts_("ioctl SET_CCORR failed\n"); xexit(1); }
  puts_("CCORR set OK\n"); xexit(0); return 0;
}
__asm__(".text\n.global _start\n_start:\n\tmov x0, sp\n\tb c_start\n");
