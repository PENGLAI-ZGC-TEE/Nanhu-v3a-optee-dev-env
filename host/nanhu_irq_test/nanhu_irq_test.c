// SPDX-License-Identifier: BSD-2-Clause
/*
 * BOSC Nanhu IRQ trigger test tool.
 *
 * Legacy REE tests trigger irqgen from Linux userspace through /dev/mem.
 * Secure-world tests use TEE Client API only to enter the Nanhu IRQ PTA; the
 * PTA performs the secure-world irqgen MMIO trigger.
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

#include "tee_client_api.h"

#define LOG_PREFIX "[nanhu-irq-test]"

#define PTA_NANHU_IRQ_TEST_UUID \
	{ 0x6d99f02a, 0x9f6a, 0x4c30, \
		{ 0xa8, 0x4b, 0x4e, 0x21, 0x44, 0x9c, 0x10, 0x01 } }

#define PTA_NANHU_IRQ_TEST_CMD_BUSY		0
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_NS	1
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC	2
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC_WITH_NS	3

struct irq_test_cmd {
	const char *name;
	unsigned int irq;
	uint64_t mmio;
	uint32_t value;
	uint32_t pta_cmd;
	int use_tee;
	const char *description;
};

static const struct irq_test_cmd commands[] = {
	{
		.name = "ns42-preempt-sec43",
		.irq = 42,
		.mmio = 0x30000000ULL,
		.value = 0x1,
		.use_tee = 0,
		.description = "trigger non-secure IRQ42 from REE; Linux handler triggers secure IRQ43",
	},
	{
		.name = "ree-trigger-ns44",
		.irq = 44,
		.mmio = 0x30002000ULL,
		.value = 0x1,
		.use_tee = 0,
		.description = "trigger non-secure IRQ44 directly from REE",
	},
	{
		.name = "ree-trigger-sec45",
		.irq = 45,
		.mmio = 0x30003000ULL,
		.value = 0x1,
		.use_tee = 0,
		.description = "trigger secure IRQ45 directly from REE",
	},
	{
		.name = "busy",
		.pta_cmd = PTA_NANHU_IRQ_TEST_CMD_BUSY,
		.use_tee = 1,
		.description = "enter OP-TEE PTA and busy-wait without triggering IRQ",
	},
	{
		.name = "trigger-ns",
		.pta_cmd = PTA_NANHU_IRQ_TEST_CMD_TRIGGER_NS,
		.use_tee = 1,
		.description = "enter OP-TEE PTA and trigger non-secure IRQ44 inside secure world",
	},
	{
		.name = "trigger-sec",
		.pta_cmd = PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC,
		.use_tee = 1,
		.description = "enter OP-TEE PTA and trigger secure IRQ45 inside secure world",
	},
	{
		.name = "trigger-sec-with-ns",
		.pta_cmd = PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC_WITH_NS,
		.use_tee = 1,
		.description = "enter OP-TEE PTA, trigger secure IRQ45, then trigger non-secure IRQ44 inside the secure IRQ handler",
	},
};

static void usage(const char *prog)
{
	size_t i;

	fprintf(stderr, "Usage: %s <subcommand>\n", prog);
	fprintf(stderr, "\nSubcommands:\n");
	for (i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
		if (commands[i].use_tee)
			fprintf(stderr, "  %-20s PTA cmd=%u\n",
				commands[i].name, commands[i].pta_cmd);
		else
			fprintf(stderr, "  %-20s IRQ%-2u mmio=0x%08" PRIx64
				" value=0x%x\n",
				commands[i].name, commands[i].irq,
				commands[i].mmio, commands[i].value);
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

static int invoke_pta(uint32_t command_id)
{
	TEEC_UUID uuid = PTA_NANHU_IRQ_TEST_UUID;
	TEEC_Context ctx = { 0 };
	TEEC_Session sess = { 0 };
	TEEC_Operation op = { 0 };
	TEEC_Result res;
	uint32_t origin = 0;
	int rc = -1;

	res = TEEC_InitializeContext(NULL, &ctx);
	if (res != TEEC_SUCCESS) {
		fprintf(stderr, LOG_PREFIX " TEEC_InitializeContext failed: 0x%x\n",
			res);
		return -1;
	}

	res = TEEC_OpenSession(&ctx, &sess, &uuid, TEEC_LOGIN_PUBLIC, NULL,
			       NULL, &origin);
	if (res != TEEC_SUCCESS) {
		fprintf(stderr, LOG_PREFIX
			" TEEC_OpenSession failed: res=0x%x origin=0x%x\n",
			res, origin);
		goto out_finalize;
	}

	op.paramTypes = TEEC_PARAM_TYPES(TEEC_NONE, TEEC_NONE, TEEC_NONE,
					TEEC_NONE);
	res = TEEC_InvokeCommand(&sess, command_id, &op, &origin);
	if (res != TEEC_SUCCESS) {
		fprintf(stderr, LOG_PREFIX
			" TEEC_InvokeCommand failed: res=0x%x origin=0x%x\n",
			res, origin);
		goto out_close;
	}

	rc = 0;

out_close:
	TEEC_CloseSession(&sess);
out_finalize:
	TEEC_FinalizeContext(&ctx);
	return rc;
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

	printf("[FLOW] BEGIN test=%s backend=%s", cmd->name,
	       cmd->use_tee ? "TEE" : "REE");
	if (cmd->use_tee)
		printf(" pta_cmd=%u\n", cmd->pta_cmd);
	else
		printf(" irq=%u mmio=0x%08" PRIx64 " value=0x%x\n",
		       cmd->irq, cmd->mmio, cmd->value);

	if (cmd->use_tee) {
		printf(LOG_PREFIX " invoke PTA command=%u\n", cmd->pta_cmd);
		if (invoke_pta(cmd->pta_cmd) != 0)
			return EXIT_FAILURE;
	} else {
		printf(LOG_PREFIX " write mmio=0x%08" PRIx64 " value=0x%x\n",
		       cmd->mmio, cmd->value);
		if (write_mmio32(cmd->mmio, cmd->value) != 0)
			return EXIT_FAILURE;
	}

	if (fflush(stdout) != 0)
		return EXIT_FAILURE;

	printf("[FLOW] END test=%s result=OK\n", cmd->name);

	return EXIT_SUCCESS;
}
