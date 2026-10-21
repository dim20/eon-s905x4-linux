/*
 * fbaddr - print the physical addresses involved in the framebuffer.
 *
 * The question this answers: is the buffer the display scans the same
 * buffer that userspace writes into?
 *
 *   - fix.smem_start     the physical address the driver says the
 *                         framebuffer is at
 *   - the mmap's offset  the physical address userspace actually
 *                         writes into (from /proc/self/maps)
 *   - the plane's phy_addr (printed separately from the DRM debugfs)
 *                         the physical address the display scans
 *
 * If the first two agree and the third does not, the display is
 * scanning a buffer that nobody is drawing into.
 *
 * Build:
 *   aarch64-buildroot-linux-gnu-gcc -static -O2 -o fbaddr fbaddr.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

static void show_maps(int fd, unsigned long len)
{
	FILE *f = fopen("/proc/self/maps", "r");
	char line[512];
	unsigned long lo = 0, hi = 0;
	int found = 0;

	if (!f) {
		perror("maps");
		return;
	}
	while (fgets(line, sizeof(line), f)) {
		unsigned long a, b;
		char perms[8];
		unsigned long off;
		unsigned int devmaj, devmin;
		unsigned long inode;
		char path[256];

		path[0] = 0;
		if (sscanf(line, "%lx-%lx %7s %lx %x:%x %lu %255s",
			   &a, &b, perms, &off, &devmaj, &devmin,
			   &inode, path) < 7)
			continue;
		if (strstr(path, "/dev/fb0")) {
			lo = a;
			hi = b;
			found = 1;
			printf("  the mapping:     %lx-%lx %s offset=0x%lx\n",
			       a, b, perms, off);
			printf("  so userspace writes at physical 0x%lx\n",
			       off);
		}
	}
	fclose(f);
	if (!found)
		printf("  no /dev/fb0 mapping found\n");
	(void)fd;
	(void)len;
}

int main(void)
{
	int fd;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open /dev/fb0");
		return 1;
	}

	memset(&fix, 0, sizeof(fix));
	if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
		perror("FBIOGET_FSCREENINFO");
		return 1;
	}
	memset(&var, 0, sizeof(var));
	if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0)
		perror("FBIOGET_VSCREENINFO");

	printf("=== the framebuffer ===\n");
	printf("  smem_start:      0x%lx\n", fix.smem_start);
	printf("  smem_len:        %lu\n", fix.smem_len);
	printf("  line_length:     %u\n", fix.line_length);
	printf("  xres/yres:       %ux%u\n", var.xres, var.yres);
	printf("  virtual:         %ux%u\n", var.xres_virtual, var.yres_virtual);
	printf("  bits per pixel:  %u\n", var.bits_per_pixel);

	p = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED,
		 fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	printf("=== the mapping ===\n");
	show_maps(fd, fix.smem_len);

	/* Write a pattern and read it back, to prove the mapping works. */
	memset(p, 0x5a, 4096);
	if (memcmp(p, "\x5a\x5a\x5a\x5a", 4) != 0)
		printf("  the mapping does NOT read back what was written\n");
	else
		printf("  the mapping reads back what was written\n");

	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
