/*
 * fbprobe - read the framebuffer with a given stride and pixel size.
 *
 * fbprobe <x> <y> <w> <h> <stride_bytes> <bytes_per_pixel> [out.ppm]
 *
 * The framebuffer is 32 bits per pixel with a 7680-byte stride. If
 * the data in it was written as 24-bit pixels with a 5760-byte
 * stride, reading it any other way gives a moire.
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
	int fd, j;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p;
	const char *out;
	int x, y, w, h, stride, bpp;

	if (argc < 7) {
		fprintf(stderr, "usage: %s <x> <y> <w> <h> <stride> <bpp> [out.ppm]\n",
			argv[0]);
		return 1;
	}
	x = atoi(argv[1]);
	y = atoi(argv[2]);
	w = atoi(argv[3]);
	h = atoi(argv[4]);
	stride = atoi(argv[5]);
	bpp = atoi(argv[6]);
	out = argc > 7 ? argv[7] : "/tmp/fbprobe.ppm";

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

	{
		FILE *f = fopen(out, "wb");
		if (!f) {
			perror(out);
			return 1;
		}
		fprintf(f, "P6\n%d %d\n255\n", w, h);
		for (j = 0; j < h; j++) {
			unsigned char *row = p + (size_t)(y + j) * stride + (size_t)x * bpp;
			int i;
			for (i = 0; i < w; i++) {
				unsigned char *px = row + (size_t)i * bpp;
				/* BGRX in the framebuffer; PPM wants RGB */
				fputc(bpp == 4 ? px[2] : px[0], f);
				fputc(px[1], f);
				fputc(bpp == 4 ? px[0] : px[2], f);
			}
		}
		fclose(f);
	}
	printf("wrote %s (%dx%d at %d,%d, stride %d, %d bytes per pixel)\n",
	       out, w, h, x, y, stride, bpp);
	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
