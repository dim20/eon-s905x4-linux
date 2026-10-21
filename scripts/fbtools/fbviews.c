/*
 * fbviews - are the framebuffer's two views the same memory?
 *
 * The driver has two mappings of the framebuffer:
 *
 *   - the KERNEL's, which is what info->screen_base points at, and
 *     what the fbdev's own operations (fb_imageblit and friends)
 *     write through. The X server's blit goes through this one.
 *
 *   - the USERSPACE's, which is what an mmap of /dev/fb0 gives.
 *
 * If the two are the same view, a write through one is visible
 * through the other. If they are not - because one of them is cached
 * and the other is not - then what the X server writes can sit in the
 * CPU's cache while the display, which reads the memory over DMA,
 * sees something else entirely.
 *
 * This is the test that tells us which it is.
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

int main(void)
{
	int fd;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p;
	unsigned char buf[256];
	ssize_t n;
	int i, same;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	memset(&fix, 0, sizeof(fix));
	memset(&var, 0, sizeof(var));
	if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
		perror("FBIOGET_FSCREENINFO");
		return 1;
	}
	ioctl(fd, FBIOGET_VSCREENINFO, &var);
	printf("the framebuffer is %ux%u, %lu bytes\n", var.xres, var.yres,
	       fix.smem_len);

	p = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED,
		 fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	/* 1. write a pattern through the USERSPACE mapping */
	for (i = 0; i < 256; i++)
		p[i] = 0xa0 + (i & 0x0f);

	/* 2. read it back through the KERNEL's read() path */
	memset(buf, 0, sizeof(buf));
	n = read(fd, buf, sizeof(buf));
	if (n < 0) {
		perror("read");
		return 1;
	}
	same = !memcmp(buf, p, (size_t)n);
	printf("  after an mmap write, read() sees the same bytes: %s\n",
	       same ? "YES" : "NO");
	if (!same) {
		printf("    read():  ");
		for (i = 0; i < 16; i++)
			printf("%02x ", buf[i]);
		printf("\n    mmap:   ");
		for (i = 0; i < 16; i++)
			printf("%02x ", p[i]);
		printf("\n");
	}

	/* 3. write a different pattern through the KERNEL's write() path */
	memset(buf, 0, sizeof(buf));
	for (i = 0; i < 256; i++)
		buf[i] = 0x50 + (i & 0x0f);
	if (write(fd, buf, sizeof(buf)) < 0) {
		perror("write");
		return 1;
	}

	/* 4. read it back through the USERSPACE mapping */
	same = !memcmp(buf, p, 256);
	printf("  after a write(), the mmap sees the same bytes: %s\n",
	       same ? "YES" : "NO");
	if (!same) {
		printf("    written: ");
		for (i = 0; i < 16; i++)
			printf("%02x ", buf[i]);
		printf("\n    mmap:   ");
		for (i = 0; i < 16; i++)
			printf("%02x ", p[i]);
		printf("\n");
	}

	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
