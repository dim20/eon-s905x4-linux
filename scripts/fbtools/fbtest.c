/*
 * fbtest - fill the framebuffer with a colour, for as long as asked.
 *
 * fbtest <r> <g> <b> <seconds> [half]
 *
 *   half = 0 (the default)  the WHOLE framebuffer
 *   half = 1                only the BOTTOM half - the half of the
 *                           1920x2160 buffer that is NOT the visible
 *                           1920x1080 window
 *
 * The point: if the television shows the colour, the display is
 * scanning the framebuffer live, and whatever the X server draws into
 * the framebuffer reaches the television by itself. If it does not,
 * the display is showing a COPY, and the copy has to be refreshed.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

int main(int argc, char **argv)
{
	int fd;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned int r = 0, g = 0, b = 0;
	int seconds = 20, half = 0;
	size_t off, len, i;
	unsigned char *p;

	if (argc < 5) {
		fprintf(stderr, "usage: %s <r> <g> <b> <seconds> [half]\n",
			argv[0]);
		return 1;
	}
	r = strtoul(argv[1], NULL, 0);
	g = strtoul(argv[2], NULL, 0);
	b = strtoul(argv[3], NULL, 0);
	seconds = atoi(argv[4]);
	if (argc > 5)
		half = atoi(argv[5]);

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open /dev/fb0");
		return 1;
	}
	if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
		perror("FBIOGET_FSCREENINFO");
		return 1;
	}
	if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0)
		perror("FBIOGET_VSCREENINFO");

	printf("the framebuffer is %ux%u (virtual %ux%u), %u bpp\n",
	       var.xres, var.yres, var.xres_virtual, var.yres_virtual,
	       var.bits_per_pixel);

	p = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED,
		 fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	if (half)
		off = (size_t)var.yres * fix.line_length;
	else
		off = 0;
	len = fix.smem_len - off;
	if (off + len > fix.smem_len)
		len = fix.smem_len - off;

	printf("filling %zu bytes from offset %zu with %02x%02x%02x for %ds\n",
	       len, off, r, g, b, seconds);

	/* ARGB8888 little-endian: the bytes are B, G, R, A. */
	for (i = 0; i < len; i += 4) {
		p[off + i + 0] = b;
		p[off + i + 1] = g;
		p[off + i + 2] = r;
		p[off + i + 3] = 0xff;
	}
	msync(p, fix.smem_len, MS_SYNC);

	printf("done - the framebuffer has been written\n");
	fflush(stdout);
	sleep(seconds);

	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
