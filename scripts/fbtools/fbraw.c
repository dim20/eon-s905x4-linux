/*
 * fbraw - the same bytes of the framebuffer, through both paths.
 *
 * fbraw <offset> <count>
 *
 * "offset" is a byte offset into the framebuffer.
 *
 * The kernel's path is read(), which goes through info->screen_base.
 * The userspace's path is an mmap of /dev/fb0. They are two mappings
 * of the same memory with different cache behaviour, and they do not
 * always agree.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

static void hex(const char *tag, unsigned char *p, int n)
{
	int i;
	printf("%s", tag);
	for (i = 0; i < n; i++) {
		if (i % 16 == 0)
			printf("\n  %04x:", i);
		printf(" %02x", p[i]);
	}
	printf("\n");
}

int main(int argc, char **argv)
{
	int fd;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p, buf[256];
	long off;
	int count, i, same = 1;

	if (argc < 3) {
		fprintf(stderr, "usage: %s <offset> [count]\n", argv[0]);
		return 1;
	}
	off = atol(argv[1]);
	count = argc > 2 ? atoi(argv[2]) : 64;
	if (count > (int)sizeof(buf))
		count = sizeof(buf);

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

	/* the kernel's path */
	if (lseek(fd, off, SEEK_SET) < 0)
		perror("lseek");
	memset(buf, 0, sizeof(buf));
	if (read(fd, buf, count) < 0)
		perror("read");

	hex("the kernel's view (read()):", buf, count);
	hex("the userspace's view (mmap): ", p + off, count);

	for (i = 0; i < count; i++)
		if (buf[i] != p[off + i])
			same = 0;
	printf("\n  they agree: %s\n", same ? "YES" : "NO");
	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
