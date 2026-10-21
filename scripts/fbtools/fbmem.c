/*
 * fbmem - the physical address a mapping of /dev/fb0 is on.
 *
 * fbmem [pid]
 *
 * With no argument, it maps /dev/fb0 itself and reports where that
 * landed. With a pid, it reports where THAT process's mapping of
 * /dev/fb0 landed.
 *
 * Two mappings of the same file can be of different memory, if the
 * driver gave out a new buffer in between.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>

#define PAGEMAP_PFN_MASK ((1ULL << 55) - 1)

static unsigned long long pfn_of(unsigned long addr)
{
	FILE *f = fopen("/proc/self/pagemap", "rb");
	unsigned long long v = 0, pfn = 0;
	if (!f) {
		perror("/proc/self/pagemap");
		return 0;
	}
	if (fseek(f, (long)(addr / 4096) * 8, SEEK_SET) == 0 &&
	    fread(&v, 8, 1, f) == 1) {
		pfn = (v & PAGEMAP_PFN_MASK) & ~0x1ULL;
		if (!(v & (1ULL << 63)))
			pfn = 0;
	}
	fclose(f);
	return pfn;
}

int main(int argc, char **argv)
{
	int fd;
	struct fb_fix_screeninfo fix;
	unsigned char *p;
	unsigned long long pfn;

	fd = open("/dev/fb0", O_RDWR);
	if (fd < 0) {
		perror("open /dev/fb0");
		return 1;
	}
	memset(&fix, 0, sizeof(fix));
	ioctl(fd, FBIOGET_FSCREENINFO, &fix);
	printf("the framebuffer device says smem_start = 0x%lx\n", fix.smem_start);

	p = mmap(NULL, fix.smem_len, PROT_READ, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	pfn = pfn_of((unsigned long)p);
	printf("this process's mapping is at physical 0x%llx\n", pfn << 12);

	if (argc > 1) {
		/* the other process's mapping */
		char path[128];
		FILE *f;
		char line[512];
		snprintf(path, sizeof(path), "/proc/%s/maps", argv[1]);
		f = fopen(path, "r");
		if (!f) {
			perror(path);
			return 1;
		}
		while (fgets(line, sizeof(line), f)) {
			unsigned long lo, hi;
			char perms[8], rest[400];
			if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %*s %399s",
				   &lo, &hi, perms, rest) < 4)
				continue;
			if (!strstr(rest, "fb0"))
				continue;
			pfn = pfn_of(lo);
			printf("process %s maps /dev/fb0 at %lx-%lx %s -> physical 0x%llx\n",
			       argv[1], lo, hi, perms, pfn << 12);
		}
		fclose(f);
	}
	munmap(p, fix.smem_len);
	close(fd);
	return 0;
}
