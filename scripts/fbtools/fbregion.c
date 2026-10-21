/*
 * fbregion - dump a rectangle of the framebuffer, at full resolution.
 *
 * fbregion <x> <y> <w> <h> [out.ppm]
 *
 * Reads through the mmap, which is the view the display is scanning.
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
	int fd;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p;
	const char *out;
	int x, y, w, h, j;

	if (argc < 5) {
		fprintf(stderr, "usage: %s <x> <y> <w> <h> [out.ppm]\n", argv[0]);
		return 1;
	}
	x = atoi(argv[1]);
	y = atoi(argv[2]);
	w = atoi(argv[3]);
	h = atoi(argv[4]);
	out = argc > 5 ? argv[5] : "/tmp/fbregion.ppm";

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
	if (x + w > var.xres)
		w = var.xres - x;
	if (y + h > var.yres)
		h = var.yres - y;
	if (w <= 0 || h <= 0) {
		printf("that region is outside the framebuffer\n");
		return 1;
	}

	{
		FILE *f = fopen(out, "wb");
		if (!f) {
			perror(out);
			return 1;
		}
		fprintf(f, "P6\n%d %d\n255\n", w, h);
		for (j = 0; j < h; j++) {
			unsigned char *row = p + (size_t)(y + j) * fix.line_length + (size_t)x * 4;
			fwrite(row, 1, (size_t)w * 4, f);
		}
		fclose(f);
	}
	printf("wrote %s (%dx%d at %d,%d)\n", out, w, h, x, y);
	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
