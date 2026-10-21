/*
 * fblife - does the framebuffer's buffer survive a close?
 *
 *   1. open /dev/fb0, note the physical address, write a pattern
 *   2. close it - the driver's release path runs
 *   3. open it again, note the physical address, read the pattern back
 *
 * If the pattern is still there, the buffer survived and the display
 * never stopped reading it. If it is gone, the buffer was freed and
 * the display was left reading memory that had been handed back to
 * the allocator.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

int main(void)
{
	int fd;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p;
	unsigned long first = 0, second = 0;
	int i, survived;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open /dev/fb0");
		return 1;
	}
	memset(&fix, 0, sizeof(fix));
	memset(&var, 0, sizeof(var));
	ioctl(fd, FBIOGET_FSCREENINFO, &fix);
	ioctl(fd, FBIOGET_VSCREENINFO, &var);
	first = fix.smem_start;
	printf("the first open:  smem_start = 0x%lx\n", first);

	p = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED,
		 fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	for (i = 0; i < 256; i++)
		p[i] = 0x5a;
	msync(p, fix.smem_len, MS_SYNC);
	munmap(p, fix.smem_len);
	close(fd);
	printf("closed\n");

	usleep(300000);

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open /dev/fb0 again");
		return 1;
	}
	memset(&fix, 0, sizeof(fix));
	ioctl(fd, FBIOGET_FSCREENINFO, &fix);
	second = fix.smem_start;
	printf("the second open: smem_start = 0x%lx\n", second);

	p = mmap(NULL, fix.smem_len, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	survived = (p[0] == 0x5a && p[1] == 0x5a && p[2] == 0x5a && p[3] == 0x5a);
	printf("the pattern is still there: %s\n", survived ? "YES" : "NO");
	printf("  first bytes now: %02x %02x %02x %02x\n",
	       p[0], p[1], p[2], p[3]);
	printf("the address is the same: %s\n",
	       first == second ? "YES" : "NO");
	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
