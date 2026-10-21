/*
 * fbhash - a checksum of the framebuffer, taken through the USERSPACE
 * mapping.
 *
 * The driver has two mappings of the same memory: the kernel's
 * (info->screen_base) and the userspace's (an mmap of /dev/fb0).
 * They do not behave the same - a write through one is not visible
 * through the other - so a checksum taken with read() (which uses the
 * kernel's) does not describe what the display is actually scanning.
 * This one uses the mmap.
 *
 * fbhash [count]   - the number of samples, one per second
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

static unsigned long long sum(unsigned char *p, size_t n)
{
	unsigned long long h = 1469598103934665603ULL;
	size_t i;
	for (i = 0; i < n; i++) {
		h ^= p[i];
		h *= 1099511628211ULL;
	}
	return h;
}

int main(int argc, char **argv)
{
	int fd, count = argc > 1 ? atoi(argv[1]) : 3, i;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	memset(&fix, 0, sizeof(fix));
	memset(&var, 0, sizeof(var));
	ioctl(fd, FBIOGET_FSCREENINFO, &fix);
	ioctl(fd, FBIOGET_VSCREENINFO, &var);
	p = mmap(NULL, fix.smem_len, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	printf("the framebuffer is %ux%u (%lu bytes)\n", var.xres, var.yres,
	       fix.smem_len);
	for (i = 0; i < count; i++) {
		printf("  %016llx\n", sum(p, fix.smem_len));
		fflush(stdout);
		sleep(1);
	}
	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
