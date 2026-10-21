/*
 * fbmix - fill the framebuffer one way, then the other way, so the
 * two can be told apart on the television.
 *
 *   1. the WHOLE framebuffer is filled magenta through the USERSPACE
 *      mapping (an mmap of /dev/fb0);
 *   2. a green band is then written across the top through the
 *      KERNEL's path (a write() to /dev/fb0, which is what the
 *      fbdev's own operations - fillrect, copyarea, imageblit - and
 *      therefore the text console and the X server's software cursor
 *      all use).
 *
 * If the television shows magenta with NO green band, then the
 * kernel's writes never reach the display, and the fbdev's own
 * operations are the ones that are broken.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

int main(int argc, char **argv)
{
	int fd, seconds = argc > 1 ? atoi(argv[1]) : 30;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p, band[4096];
	size_t i, bandlen;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	memset(&fix, 0, sizeof(fix));
	memset(&var, 0, sizeof(var));
	ioctl(fd, FBIOGET_FSCREENINFO, &fix);
	ioctl(fd, FBIOGET_VSCREENINFO, &var);

	p = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED,
		 fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	/* 1. magenta everywhere, through the userspace mapping */
	for (i = 0; i < fix.smem_len; i += 4) {
		p[i + 0] = 0xff;	/* B */
		p[i + 1] = 0x00;	/* G */
		p[i + 2] = 0xff;	/* R */
		p[i + 3] = 0xff;	/* A */
	}
	msync(p, fix.smem_len, MS_SYNC);

	/* 2. a green band across the top, through the kernel's path */
	bandlen = (size_t)fix.line_length * 100;
	if (bandlen > sizeof(band))
		bandlen = sizeof(band);
	for (i = 0; i < bandlen; i += 4) {
		band[i + 0] = 0x00;	/* B */
		band[i + 1] = 0xff;	/* G */
		band[i + 2] = 0x00;	/* R */
		band[i + 3] = 0xff;	/* A */
	}
	if (write(fd, band, bandlen) < 0)
		perror("write");

	printf("the framebuffer is magenta, with a green band written\n"
	       "through the kernel's write() path across the top %d lines.\n",
	       100);
	printf("holding it for %d seconds\n", seconds);
	fflush(stdout);
	sleep(seconds);
	return 0;
}
