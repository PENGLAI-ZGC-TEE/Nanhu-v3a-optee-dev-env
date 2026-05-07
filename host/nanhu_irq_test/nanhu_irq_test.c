// SPDX-License-Identifier: BSD-2-Clause
/*
 * BOSC Nanhu REE-side IRQ trigger test tool.
 *
 * This tool intentionally triggers irqgen from Linux userspace through
 * /dev/mem. It does not use TEE Client API and does not move the trigger
 * action into OP-TEE.
 */

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LOG_PREFIX "[nanhu-irq-test]"

struct irq_test_cmd {
	const char *name;
	unsigned int irq;
	uint64_t mmio;
	uint32_t value;
	const char *description;
};

static const struct irq_test_cmd commands[] = {
	{
		.name = "ns42-preempt-sec43",
		.irq = 42,
		.mmio = 0x30000000ULL,
		.value = 0x1,
		.description = "trigger non-secure IRQ42 from REE; Linux handler triggers secure IRQ43",
	},
	{
		.name = "sec45-blocks-ns44",
		.irq = 45,
		.mmio = 0x30003000ULL,
		.value = 0x1,
		.description = "trigger secure IRQ45 from REE; OpenSBI hook triggers non-secure IRQ44",
	},
};

static void usage(const char *prog)
{
	size_t i;

	fprintf(stderr, "Usage: %s <subcommand>\n", prog);
	fprintf(stderr, "\nSubcommands:\n");
	for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
		fprintf(stderr, "  %-20s IRQ%-2u mmio=0x%08" PRIx64
			" value=0x%x\n",
			commands[i].name, commands[i].irq, commands[i].mmio,
			commands[i].value);
		fprintf(stderr, "    %s\n", commands[i].description);
	}
}

static const struct irq_test_cmd *find_command(const char *name)
{
	size_t i;

	for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
		if (strcmp(commands[i].name, name) == 0)
			return &commands[i];
	}

	return NULL;
}

static int write_mmio32(uint64_t addr, uint32_t value)
{
	long page_size;
	uint64_t page_mask;
	uint64_t map_base;
	size_t page_offset;
	int fd;
	void *map;
	volatile uint32_t *reg;

	page_size = sysconf(_SC_PAGESIZE);
	if (page_size <= 0) {
		fprintf(stderr, LOG_PREFIX " sysconf(_SC_PAGESIZE) failed: %s\n",
			strerror(errno));
		return -1;
	}

	page_mask = (uint64_t)page_size - 1;
	map_base = addr & ~page_mask;
	page_offset = (size_t)(addr - map_base);

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, LOG_PREFIX " open /dev/mem failed: %s\n",
			strerror(errno));
		return -1;
	}

	map = mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE, MAP_SHARED,
		   fd, (off_t)map_base);
	if (map == MAP_FAILED) {
		fprintf(stderr, LOG_PREFIX " mmap mmio=0x%08" PRIx64
			" failed: %s\n", addr, strerror(errno));
		close(fd);
		return -1;
	}

	reg = (volatile uint32_t *)((char *)map + page_offset);
	*reg = value;
	__sync_synchronize();

	if (munmap(map, (size_t)page_size) != 0) {
		fprintf(stderr, LOG_PREFIX " munmap failed: %s\n",
			strerror(errno));
		close(fd);
		return -1;
	}

	if (close(fd) != 0) {
		fprintf(stderr, LOG_PREFIX " close /dev/mem failed: %s\n",
			strerror(errno));
		return -1;
	}

	return 0;
}

int main(int argc, char **argv)
{
	const struct irq_test_cmd *cmd;

	if (argc != 2 || strcmp(argv[1], "-h") == 0 ||
	    strcmp(argv[1], "--help") == 0) {
		usage(argv[0]);
		return argc == 2 ? EXIT_SUCCESS : EXIT_FAILURE;
	}

	cmd = find_command(argv[1]);
	if (!cmd) {
		fprintf(stderr, LOG_PREFIX " unknown subcommand: %s\n", argv[1]);
		usage(argv[0]);
		return EXIT_FAILURE;
	}

	printf(LOG_PREFIX " %s begin\n", cmd->name);
	printf(LOG_PREFIX " write mmio=0x%08" PRIx64 " value=0x%x\n",
	       cmd->mmio, cmd->value);

	if (write_mmio32(cmd->mmio, cmd->value) != 0)
		return EXIT_FAILURE;

	printf(LOG_PREFIX " %s end\n", cmd->name);

	return EXIT_SUCCESS;
}
