/*
 * fbhalves - dump the two halves of the framebuffer, and say what is
 * in them.
 *
 * The framebuffer is 1920x1080 visible inside a 1920x2160 buffer. The
 * display scans the top half (the DRM state says src_y=0). So:
 *
 *   - if the top half holds the desktop and the bottom half is
 *     blank, the X server draws where the display is looking, and
 *     the missing flush is something else;
 *   - if the bottom half holds the desktop, the X server is drawing
 *     into the back buffer and nobody ever pans - which is the
 *     whole bug.
 *
 * fbhalves <prefix>
 * writes <prefix>top.ppm and <prefix>bottom.ppm, downscaled, and
 * prints the statistics.
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

#define OUT_W 480
#define OUT_H 270

static void dump(const char *path, unsigned char *p, int stride,
		 int w, int h)
{
	FILE *f = fopen(path, "wb");
	int x, y;
	if (!f) {
		perror(path);
		return;
	}
	fprintf(f, "P6\n%d %d\n255\n", OUT_W, OUT_H);
	for (y = 0; y < OUT_H; y++) {
		unsigned char *row = p + (size_t)(y * h / OUT_H) * stride;
		for (x = 0; x < OUT_W; x++) {
			unsigned char *px = row + (size_t)(x * w / OUT_W) * 4;
			/* ARGB8888 little-endian: B, G, R, A */
			fputc(px[0], f);
			fputc(px[1], f);
			fputc(px[2], f);
		}
	}
	fclose(f);
}

static void stats(const char *name, unsigned char *p, int stride,
		  int w, int h)
{
	static unsigned char seen[1 << 16];
	unsigned int i, n = (unsigned int)w * h;
	unsigned long long sum = 0;
	unsigned int distinct = 0;

	memset(seen, 0, sizeof(seen));
	for (i = 0; i < n; i++) {
		unsigned char *px = p + (size_t)(i / w) * stride + (i % w) * 4;
		unsigned int v = (px[2] << 8) | px[1];
		sum += v;
		if (!seen[v]) {
			seen[v] = 1;
			distinct++;
		}
	}
	printf("  %-6s %d distinct colours, mean brightness %llu\n",
	       name, distinct, sum / (n ? n : 1));
}

int main(int argc, char **argv)
{
	int fd;
	struct fb_fix_screeninfo fix;
	struct fb_var_screeninfo var;
	unsigned char *p;
	const char *pre = argc > 1 ? argv[1] : "/tmp/fb";

	setvbuf(stdout, NULL, _IONBF, 0);
	fprintf(stderr, "step: open\n");
	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open /dev/fb0");
		return 1;
	}
	memset(&fix, 0, sizeof(fix));
	memset(&var, 0, sizeof(var));
	if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
		perror("FBIOGET_FSCREENINFO");
		return 1;
	}
	if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0) {
		perror("FBIOGET_VSCREENINFO");
		return 1;
	}
	printf("fix: smem_len=%lu line_length=%u  var: %ux%u virtual %ux%u\n",
	       fix.smem_len, fix.line_length, var.xres, var.yres,
	       var.xres_virtual, var.yres_virtual);
	if (!var.xres || !var.yres || !fix.line_length || !fix.smem_len) {
		printf("the framebuffer did not describe itself\n");
		return 1;
	}

	printf("the framebuffer: %ux%u visible, %ux%u virtual, stride %u\n",
	       var.xres, var.yres, var.xres_virtual, var.yres_virtual,
	       fix.line_length);

	fprintf(stderr, "step: mmap %lu\n", fix.smem_len);
	p = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED,
		 fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}

	fprintf(stderr, "step: stats top\n");
	stats("top", p, fix.line_length, var.xres, var.yres);
	fprintf(stderr, "step: stats bottom\n");
	if (var.yres_virtual > var.yres)
		stats("bottom", p + (size_t)var.yres * fix.line_length,
		      fix.line_length, var.xres, var.yres);
	else
		printf("  bottom  (the buffer has no second half)\n");

	fprintf(stderr, "step: dump top\n");
	dump("/tmp/fbtop.ppm", p, fix.line_length, var.xres, var.yres);
	fprintf(stderr, "step: dump bottom\n");
	if (var.yres_virtual > var.yres)
		dump("/tmp/fbbottom.ppm", p + (size_t)var.yres * fix.line_length,
		     fix.line_length, var.xres, var.yres);

	(void)pre;
	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
