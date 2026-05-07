# Nanhu IRQ Test Framework

## 1. 背景和目标

Nanhu IRQ test framework 用来验证 REE/Linux、OpenSBI、OP-TEE 和 QEMU PLIC 在安全/非安全外部中断上的协作关系。当前阶段的测试目标不是单纯触发某个 IRQ，而是区分 IRQ 触发时 hart 正在哪个 world 中运行，并验证对应 owner 是否完成 claim、handler/drop、complete。

当前计划中共有 6 类 IRQ 测试入口：

1. REE/Linux 正在处理 non-secure IRQ 时，secure IRQ 抢占 REE。
2. REE/Linux 直接触发并处理 non-secure IRQ。
3. REE/Linux 直接触发 secure IRQ，经 OpenSBI secure IRQ relay 进入 OP-TEE。
4. OP-TEE/PTA 正在运行时触发 non-secure IRQ，由 OP-TEE claim 后 drop/complete。
5. OP-TEE/PTA 正在运行时触发 secure IRQ，由 OP-TEE claim、handler、complete。
6. OP-TEE secure IRQ handler 正在运行时触发 non-secure IRQ，由 OP-TEE drop/complete。

本阶段完成的任务：

- 将原先分散的 Linux `devmem` 触发方式收敛到 `/usr/bin/nanhu_irq_test`。
- 保留 REE 触发语义：REE 测试仍由 Linux userspace 通过 `/dev/mem` 写 irqgen MMIO。
- 新增 OP-TEE PTA 触发路径：TEE 侧测试由 Linux CA 进入 PTA 后，在 OP-TEE 内写 irqgen MMIO。
- 在 OP-TEE PLIC driver 中支持 secure source 判断：secure IRQ 调 handler，non-secure IRQ drop。
- 在 OpenSBI MPXY 普通 OP-TEE 调用路径维护 PLIC `world_state`，使 PTA 运行期间 IRQ 可递交给 OP-TEE S-context。
- 删除旧 “OpenSBI hook 在 IRQ45 relay 中触发 IRQ44” 测试语义；该路径过于特殊，不再作为当前 6 类测试的一部分。

## 2. 当前测试命令

当前代码没有 `nanhu_irq_test list` 子命令。
查看支持的命令使用：

```sh
nanhu_irq_test --help
```

### 2.1 命令总表

| 命令 | 后端 | 触发所在 world | IRQ | MMIO | 状态 | 测试目的 |
|------|------|----------------|-----|------|------|----------|
| `ns42-preempt-sec43` | REE MMIO | REE/Linux | IRQ42，Linux IRQ42 handler 内再触发 IRQ43 | IRQ42: `0x30000000`; IRQ43: `0x30001000` | 有效 | 验证 Linux 正在处理 non-secure IRQ42 时，secure IRQ43 能抢占 REE，并经 OpenSBI secure IRQ relay 进入 OP-TEE。 |
| `ree-trigger-ns44` | REE MMIO | REE/Linux | IRQ44 | `0x30002000` | 有效 | 验证普通 non-secure IRQ44 在 REE/Linux 中按 Linux IRQ handler 路径处理。 |
| `ree-trigger-sec45` | REE MMIO | REE/Linux | IRQ45 | `0x30003000` | 有效 | 验证 REE 中触发 secure IRQ45 时，IRQ 不交给 Linux，而由 OpenSBI claim/relay/complete。 |
| `busy` | TEE PTA | OP-TEE | 无 | 无 | 辅助命令 | 只验证 CA -> TEE Client API -> OpenSBI MPXY -> OP-TEE PTA 的进入/返回链路，不属于 6 类 IRQ 行为测试。 |
| `trigger-ns` | TEE PTA | OP-TEE | IRQ44 | `0x30002000` | 有效 | 验证 OP-TEE 正在运行时触发 non-secure IRQ44，IRQ44 递交给 OP-TEE 后被 claim/drop/complete，不返回 Linux。 |
| `trigger-sec` | TEE PTA | OP-TEE | IRQ45 | `0x30003000` | 有效 | 验证 OP-TEE 正在运行时触发 secure IRQ45，IRQ45 由 OP-TEE 自己 claim、调用 handler、complete。 |
| `trigger-sec-with-ns` | TEE PTA | OP-TEE | IRQ45 后 IRQ44 | IRQ45: `0x30003000`; IRQ44: `0x30002000` | 有效 | 验证 OP-TEE secure IRQ45 handler 执行期间出现 non-secure IRQ44 时，IRQ44 被 OP-TEE drop/complete。 |

### 2.2 每个测试的目的和预期效果

#### 测试 1：`ns42-preempt-sec43`

目的：验证 REE/Linux 正在处理 non-secure IRQ42 时，secure IRQ43 可以抢占 REE。这个测试覆盖的是 REE-origin secure IRQ relay 路径，不是 OP-TEE native PLIC claim 路径。

预期效果：

```text
nanhu_irq_test ns42-preempt-sec43
[nanhu-irq-test] write mmio=0x30000000 value=0x1
[ree] irq14 begin count=...
plic-sec: ... irq=43 sec=1 ws=0 ...
plic-sec: enter tee fiq irq=43 ...
plic-sec: tee return -> complete irq=43 ...
[ree] irq14 end count=...
```

解释：IRQ42 是 non-secure source，触发后进入 Linux IRQ handler，因此先看到 `[ree] irq14 begin`。Linux handler 内写 IRQ43 irqgen，当前 hart 仍在 REE 且 `ws=0`，所以 secure IRQ43 被 QEMU PLIC 递交给 M-context，由 OpenSBI claim 并 relay 到 OP-TEE。OpenSBI complete IRQ43 后回到 Linux handler，最后出现 `[ree] irq14 end`。这个顺序证明 secure IRQ43 确实抢占了正在执行的 REE IRQ42 handler。

#### 测试 2：`ree-trigger-ns44`

目的：验证 REE/Linux 直接触发 non-secure IRQ44 时，IRQ44 仍由 Linux handler 处理，不进入 secure IRQ relay，也不进入 OP-TEE drop 路径。

预期效果：

```text
nanhu_irq_test ree-trigger-ns44
[nanhu-irq-test] write mmio=0x30002000 value=0x1
riscv-plic: [ree-plic] claim cpu=0 hwirq=44
[ree] irq15 begin count=...
[ree] irq15 end count=...
riscv-plic: [ree-plic] eoi cpu=0 hwirq=44
```

解释：IRQ44 是 non-secure source，且触发发生在 REE/Linux userspace。当前 `ws=0` 时，QEMU PLIC 应把 non-secure IRQ 递交给 Linux S-context。Linux 日志中的 hwirq=44 和 `[ree] irq15 begin/end` 证明该 IRQ 被 Linux claim/handler/eoi，OP-TEE 不参与。

#### 测试 3：`ree-trigger-sec45`

目的：验证 REE/Linux 直接触发 secure IRQ45 时，IRQ45 走 OpenSBI secure IRQ relay，而不是 Linux IRQ handler。

预期效果：

```text
nanhu_irq_test ree-trigger-sec45
[nanhu-irq-test] write mmio=0x30003000 value=0x1
plic-sec: hart0 mctx=0 irq=45 sec=1 ws=0 ...
plic-sec: enter tee fiq irq=45 ...
plic-sec: switch ws -> 1 before tee irq=45 ...
plic-sec: tee return -> complete irq=45 ...
plic-sec: switch ws -> 0 after tee irq=45 ...
```

解释：IRQ45 是 secure source，触发时 hart 在 REE/Linux，`ws=0`。因此 QEMU PLIC 应把 IRQ45 递交给 M-context，OpenSBI claim 后切入 OP-TEE FIQ entry。日志中没有 Linux `[ree] irq...` handler，而是 `plic-sec` claim/relay/complete，证明 REE-origin secure IRQ 的 owner 是 OpenSBI relay 路径。

#### 测试 4：`trigger-ns`

目的：验证 hart 已经在 OP-TEE/PTA 中运行时触发 non-secure IRQ44，IRQ44 会递交给 OP-TEE，并由 OP-TEE PLIC driver 明确 drop/complete。

```text
nanhu_irq_test trigger-ns
[nanhu-irq-test] invoke PTA command=1
I/TC: [optee-test] trigger ns irq44 begin
I/TC: [optee-plic] claim irq=44 sec=0
I/TC: [optee-plic] drop non-secure irq=44
I/TC: [optee-plic] complete dropped irq=44
I/TC: [optee-test] trigger ns irq44 end
```

解释：该命令先通过 TEE Client API 进入 PTA，PTA 内写 `0x30002000` 触发 IRQ44。因为 PTA 正在 OP-TEE 中运行，`world_state=1`，QEMU PLIC 将 IRQ44 递交给 OP-TEE S-context。OP-TEE PLIC claim 后读取 secure source，发现 `sec=0`，所以不调用 Linux、不调用 OP-TEE secure handler，而是直接 drop 并 complete。日志证明“非安全中断到达了安全世界策略层，并被安全世界丢弃”。

#### 测试 5：`trigger-sec`

目的：验证 hart 已经在 OP-TEE/PTA 中运行时触发 secure IRQ45，IRQ45 由 OP-TEE 自己完成 claim、handler、complete。

```text
nanhu_irq_test trigger-sec
[nanhu-irq-test] invoke PTA command=2
I/TC: [optee-test] trigger secure irq45 begin
I/TC: [optee-plic] claim irq=45 sec=1
I/TC: [optee-test] secure irq45 handler begin
I/TC: [optee-test] secure irq45 handler end
I/TC: [optee-plic] complete secure irq=45
I/TC: [optee-test] trigger secure irq45 end
```

解释：IRQ45 是 secure source，且触发点在 OP-TEE PTA 内。此时不应再走 OpenSBI secure IRQ relay；正确 owner 是 OP-TEE S-context PLIC。`claim irq=45 sec=1`、IRQ45 handler begin/end、`complete secure irq=45` 连续出现，证明 secure IRQ45 的 claim、handler 和 complete 都在 OP-TEE 内完成。

#### 测试 6：`trigger-sec-with-ns`

目的：验证 OP-TEE 正在处理 secure IRQ45 handler 时，如果出现 non-secure IRQ44，IRQ44 不会回到 Linux，也不会打断为 REE handler，而是由 OP-TEE claim/drop/complete。

```text
nanhu_irq_test trigger-sec-with-ns
I/TC: [optee-test] trigger secure irq45 with ns irq44 begin
I/TC: [optee-plic] claim irq=45 sec=1
I/TC: [optee-test] secure irq45 handler begin
I/TC: [optee-test] secure irq45 handler trigger ns irq44
I/TC: [optee-test] secure irq45 handler end
I/TC: [optee-plic] complete secure irq=45
I/TC: [optee-plic] claim irq=44 sec=0
I/TC: [optee-plic] drop non-secure irq=44
I/TC: [optee-plic] complete dropped irq=44
I/TC: [optee-test] trigger secure irq45 with ns irq44 end
```

解释：PTA 先触发 secure IRQ45，OP-TEE claim 后进入 IRQ45 handler。handler 中根据测试开关写 `0x30002000` 触发 IRQ44。IRQ45 complete 后，OP-TEE PLIC 继续 claim 到 IRQ44 并识别 `sec=0`，随后 drop/complete。该顺序证明“安全中断处理期间出现非安全中断”的场景没有回退到 OpenSBI hook，也没有交给 Linux，而是在 OP-TEE 安全世界内被清理。

## 3. 修改文件列表

### `host/nanhu_irq_test/nanhu_irq_test.c`

这是 Linux/REE 中的统一 CLI 工具。核心设计是：同一个 `commands[]` 表描述所有测试；`use_tee=0` 走 REE `/dev/mem` backend，`use_tee=1` 走 TEE Client API backend。

```c
/*
 * Legacy REE tests trigger irqgen from Linux userspace through /dev/mem.
 * Secure-world tests use TEE Client API only to enter the Nanhu IRQ PTA; the
 * PTA performs the secure-world irqgen MMIO trigger.
 */

#define PTA_NANHU_IRQ_TEST_UUID \
	{ 0x6d99f02a, 0x9f6a, 0x4c30, \
		{ 0xa8, 0x4b, 0x4e, 0x21, 0x44, 0x9c, 0x10, 0x01 } }

#define PTA_NANHU_IRQ_TEST_CMD_BUSY		0
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_NS	1
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC	2
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC_WITH_NS	3

struct irq_test_cmd {
	const char *name;       /* CLI 子命令名 */
	unsigned int irq;       /* REE MMIO backend 使用的 IRQ 号 */
	uint64_t mmio;          /* REE MMIO backend 写入的 irqgen 地址 */
	uint32_t value;         /* 写入 irqgen trigger register 的值 */
	uint32_t pta_cmd;       /* TEE PTA backend 调用的 command id */
	int use_tee;            /* 0: /dev/mem; 1: TEEC_InvokeCommand */
	const char *description;
};
```

`commands[]` 是命令和测试语义的唯一入口表。维护者新增测试时应先判断触发语义属于 REE 还是 OP-TEE，再选择 `use_tee`。

```c
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
```

REE backend 保留原 devmem 语义，只是把 shell 命令封装成 C 代码。它仍然发生在 Linux userspace。

```c
static int write_mmio32(uint64_t addr, uint32_t value)
{
	page_size = sysconf(_SC_PAGESIZE);
	page_mask = (uint64_t)page_size - 1;
	map_base = addr & ~page_mask;
	page_offset = (size_t)(addr - map_base);

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	map = mmap(NULL, (size_t)page_size, PROT_READ | PROT_WRITE,
		   MAP_SHARED, fd, (off_t)map_base);

	/* 写 irqgen offset 0x0，语义等价于旧 devmem trigger */
	reg = (volatile uint32_t *)((char *)map + page_offset);
	*reg = value;
	__sync_synchronize();

	munmap(map, (size_t)page_size);
	close(fd);
	return 0;
}
```

TEE backend 只负责进入 PTA。注意：对 `trigger-ns`、`trigger-sec`、`trigger-sec-with-ns` 来说，真正写 irqgen MMIO 的动作发生在 OP-TEE PTA 内，不在 CA 中。

```c
static int invoke_pta(uint32_t command_id)
{
	TEEC_UUID uuid = PTA_NANHU_IRQ_TEST_UUID;

	TEEC_InitializeContext(NULL, &ctx);
	TEEC_OpenSession(&ctx, &sess, &uuid, TEEC_LOGIN_PUBLIC, NULL,
			 NULL, &origin);

	op.paramTypes = TEEC_PARAM_TYPES(TEEC_NONE, TEEC_NONE,
					 TEEC_NONE, TEEC_NONE);
	TEEC_InvokeCommand(&sess, command_id, &op, &origin);

	TEEC_CloseSession(&sess);
	TEEC_FinalizeContext(&ctx);
	return 0;
}
```

主函数只做分发，不在这里混入测试策略。

```c
printf(LOG_PREFIX " %s begin\n", cmd->name);

if (cmd->use_tee) {
	printf(LOG_PREFIX " invoke PTA command=%u\n", cmd->pta_cmd);
	invoke_pta(cmd->pta_cmd);
} else {
	printf(LOG_PREFIX " write mmio=0x%08" PRIx64 " value=0x%x\n",
	       cmd->mmio, cmd->value);
	write_mmio32(cmd->mmio, cmd->value);
}

printf(LOG_PREFIX " %s end\n", cmd->name);
```

### `host/nanhu_irq_test/Makefile`

该文件负责单独构建 host tool。

```make
CROSS_COMPILE ?= riscv64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
O ?= ../../build/host/nanhu_irq_test
TARGET := $(O)/nanhu_irq_test
ROOTFS ?= ../../rootfs

CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra -Werror

# 链接 rootfs 中的 libteec，供 TEE backend 使用。
LDFLAGS ?= -L$(ROOTFS)/usr/lib -Wl,-rpath-link,$(ROOTFS)/usr/lib -lteec

$(TARGET): nanhu_irq_test.c tee_client_api.h | $(O)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: $(TARGET)
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(TARGET) $(DESTDIR)/usr/bin/nanhu_irq_test
```

### `host/nanhu_irq_test/tee_client_api.h`

这是给 `nanhu_irq_test.c` 使用的最小 TEE Client API 头文件。

```c
typedef struct {
	uint32_t timeLow;
	uint16_t timeMid;
	uint16_t timeHiAndVersion;
	uint8_t clockSeqAndNode[8];
} TEEC_UUID;

typedef struct { void *imp; } TEEC_Context;
typedef struct { void *imp; } TEEC_Session;

#define TEEC_SUCCESS 0x00000000
#define TEEC_LOGIN_PUBLIC 0x00000000
#define TEEC_NONE 0x0

#define TEEC_PARAM_TYPES(t0, t1, t2, t3) \
	((t0) | ((t1) << 4) | ((t2) << 8) | ((t3) << 12))

TEEC_Result TEEC_InitializeContext(const char *name, TEEC_Context *context);
void TEEC_FinalizeContext(TEEC_Context *context);
TEEC_Result TEEC_OpenSession(TEEC_Context *context, TEEC_Session *session,
			     const TEEC_UUID *destination, uint32_t connectionMethod,
			     const void *connectionData, TEEC_Operation *operation,
			     uint32_t *returnOrigin);
void TEEC_CloseSession(TEEC_Session *session);
TEEC_Result TEEC_InvokeCommand(TEEC_Session *session, uint32_t commandID,
			       TEEC_Operation *operation, uint32_t *returnOrigin);
```

这个 header 只提供编译声明，函数实现来自 `libteec`。

### `Makefile`

顶层 Makefile 将 `nanhu_irq_test` 纳入现有构建和 rootfs 打包路径。

```make
# Host Tool Variables
nanhu_irq_test_srcdir := $(CURRENT_DIR)/host/nanhu_irq_test
nanhu_irq_test_builddir := $(BUILD_DIR)/host/nanhu_irq_test
nanhu_irq_test_bin := $(nanhu_irq_test_builddir)/nanhu_irq_test
nanhu_irq_test_rootfs := $(rootfs_srcdir)/usr/bin/nanhu_irq_test

.PHONY: rootfs-extract rootfs-pack nanhu_irq_test nanhu_irq_test-install host-tools

# rootfs 打包前确保工具已经安装进 rootfs/usr/bin。
rootfs-pack: $(rootfs_srcdir) $(nanhu_irq_test_rootfs)
	rm -rf $(rootfs_target)
	fakeroot sh -c 'cd $(rootfs_srcdir) && find . | cpio -o -H newc > $(rootfs_target)'

nanhu_irq_test: $(nanhu_irq_test_bin)

$(nanhu_irq_test_bin): $(nanhu_irq_test_srcdir)/nanhu_irq_test.c \
		       $(nanhu_irq_test_srcdir)/tee_client_api.h \
		       $(nanhu_irq_test_srcdir)/Makefile
	$(MAKE) -C $(nanhu_irq_test_srcdir) O=$(nanhu_irq_test_builddir) \
		CROSS_COMPILE=$(CROSS_COMPILE) ROOTFS=$(rootfs_srcdir)

$(nanhu_irq_test_rootfs): $(nanhu_irq_test_bin)
	$(MAKE) -C $(nanhu_irq_test_srcdir) O=$(nanhu_irq_test_builddir) \
		CROSS_COMPILE=$(CROSS_COMPILE) ROOTFS=$(rootfs_srcdir) \
		DESTDIR=$(rootfs_srcdir) install

nanhu_irq_test-install: $(nanhu_irq_test_rootfs)
```

### `config/plat-nanhu/conf.mk`

启用 Nanhu IRQ test PTA。

```make
# 强制启用 Nanhu IRQ 测试 PTA。
$(call force,CFG_NANHU_IRQ_TEST_PTA,y)
```

### `config/plat-nanhu/platform_config.h`

该文件把测试用平台常量集中到 Nanhu platform config。

```c
/* IRQ generator: 当前 OP-TEE 侧测试使用 IRQ44/IRQ45。 */
#define NANHU_IRQGEN_NS2_BASE		0x30002000
#define NANHU_IRQGEN_SEC2_BASE		0x30003000
#define NANHU_IRQGEN_REG_SIZE		0x1000
#define NANHU_IRQGEN_TRIGGER		0x0

#ifndef __ASSEMBLER__
#include <stdbool.h>

/* PTA 控制 IRQ45 handler 是否在 handler 内触发 IRQ44。 */
void nanhu_irq_test_set_trigger_ns_in_secure_handler(bool enable);
#endif

/*
 * External interrupt 归为 native，才能让 OP-TEE 运行期间的 S external
 * interrupt 进入 interrupt_main_handler() -> plic_it_handle()。
 */
#define PLAT_THREAD_EXCP_FOREIGN_INTR	\
	(CSR_XIE_TIE | CSR_XIE_SIE)
#define PLAT_THREAD_EXCP_NATIVE_INTR	\
	(CSR_XIE_EIE)
```

### `config/plat-nanhu/main.c`

该文件实现 Nanhu 平台侧 OP-TEE IRQ 测试逻辑。

```c
/* 映射 IRQ44/IRQ45 的 irqgen page。 */
register_phys_mem_pgdir(MEM_AREA_IO_SEC, NANHU_IRQGEN_NS2_BASE,
			2 * NANHU_IRQGEN_REG_SIZE);

#define NANHU_NS_TEST_IRQ 44
#define NANHU_SEC_TEST_IRQ 45

static bool trigger_ns_in_secure_handler __nex_bss;

void nanhu_irq_test_set_trigger_ns_in_secure_handler(bool enable)
{
	trigger_ns_in_secure_handler = enable;
}
```

IRQ45 handler 是 `trigger-sec` 和 `trigger-sec-with-ns` 的 secure handler。打开测试开关时，它会在 handler 内再触发 IRQ44。

```c
static enum itr_return nanhu_secure_irq_handler(struct itr_handler *h __unused)
{
	vaddr_t ns_irqgen = 0;

	IMSG("[optee-test] secure irq45 handler begin");

	if (trigger_ns_in_secure_handler) {
		ns_irqgen = core_mmu_get_va(NANHU_IRQGEN_NS2_BASE,
					    MEM_AREA_IO_SEC,
					    NANHU_IRQGEN_REG_SIZE);
		if (!ns_irqgen)
			panic("failed to map Nanhu IRQ44 generator");

		IMSG("[optee-test] secure irq45 handler trigger ns irq44");
		io_write32(ns_irqgen + NANHU_IRQGEN_TRIGGER, 1);
	}

	IMSG("[optee-test] secure irq45 handler end");
	return ITRR_HANDLED;
}
```

平台初始化时注册 IRQ45 handler，并启用 IRQ44/IRQ45。IRQ44 启用是为了让 OP-TEE 能 claim 到 non-secure IRQ44 后 drop。

```c
static struct itr_handler nanhu_sec_irq_hdl =
	ITR_HANDLER(NULL, NANHU_SEC_TEST_IRQ, 0, nanhu_secure_irq_handler, NULL);

static void nanhu_secure_irq_test_init(void)
{
	struct itr_chip *chip = interrupt_get_main_chip();

	nanhu_sec_irq_hdl.chip = chip;
	interrupt_add_configure_handler(&nanhu_sec_irq_hdl, IRQ_TYPE_NONE, 1);

	interrupt_enable(chip, NANHU_NS_TEST_IRQ);
	interrupt_enable(chip, NANHU_SEC_TEST_IRQ);
}

void boot_primary_init_intc(void)
{
	plic_init(PLIC_BASE);
	nanhu_secure_irq_test_init();
}

void interrupt_main_handler(void)
{
	if (IS_ENABLED(CFG_RISCV_PLIC))
		plic_it_handle();
}
```

### `optee_os/lib/libutee/include/pta_nanhu_irq_test.h`

定义 Nanhu IRQ test PTA 的 UUID 和 command ID。

```c
#define PTA_NANHU_IRQ_TEST_UUID \
	{ 0x6d99f02a, 0x9f6a, 0x4c30, \
		{ 0xa8, 0x4b, 0x4e, 0x21, 0x44, 0x9c, 0x10, 0x01 } }

#define PTA_NANHU_IRQ_TEST_CMD_BUSY		0
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_NS	1
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC	2
#define PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC_WITH_NS	3
```

### `optee_os/core/pta/nanhu_irq_test.c`

该文件实现安全世界侧触发测试。

`wait_for_irq()` 用于等待 OP-TEE PLIC 真正处理到目标 IRQ。`plic_was_irq_handled()` 用 bitmask 记录历史，避免连续 IRQ 场景中“最后一个 IRQ”覆盖前一个 IRQ。

```c
static TEE_Result wait_for_irq(uint32_t expected_irq)
{
	size_t tries = NANHU_IRQ_TEST_TIMEOUT_US / NANHU_IRQ_TEST_POLL_US;
	uint32_t irq = 0;

	while (tries--) {
		if (plic_was_irq_handled(expected_irq))
			return TEE_SUCCESS;

		irq = plic_it_handle();
		if (irq == expected_irq)
			return TEE_SUCCESS;

		udelay(NANHU_IRQ_TEST_POLL_US);
	}

	EMSG("[optee-test] timeout waiting for irq%" PRIu32, expected_irq);
	return TEE_ERROR_BUSY;
}
```

`trigger_irq()` 是 PTA 内触发 IRQ44/IRQ45 的共用实现。

```c
static TEE_Result trigger_irq(uint32_t param_types, paddr_t base,
			      uint32_t irq, const char *name,
			      uint32_t followup_irq)
{
	va = core_mmu_get_va(base, MEM_AREA_IO_SEC, NANHU_IRQGEN_REG_SIZE);

	IMSG("[optee-test] trigger %s begin", name);

	/* 本测试只允许 native external interrupt 在 OP-TEE 内处理。 */
	exceptions = thread_mask_exceptions(THREAD_EXCP_FOREIGN_INTR);

	/* Linux 可能覆盖共享 S-context enable bits，PTA 触发前重新启用。 */
	plic_enable_current_irq(irq);
	if (followup_irq)
		plic_enable_current_irq(followup_irq);

	plic_clear_last_handled_irq();
	plic_set_current_world_state(1);

	/* 真正的 secure-world MMIO 触发点。 */
	io_write32(va + NANHU_IRQGEN_TRIGGER, 1);

	res = wait_for_irq(irq);
	if (!res && followup_irq)
		res = wait_for_irq(followup_irq);

	plic_set_current_world_state(0);
	thread_unmask_exceptions(exceptions);

	IMSG("[optee-test] trigger %s end", name);
	return TEE_SUCCESS;
}
```

PTA command 到测试语义的映射如下。

```c
static TEE_Result invoke_command(void *session __unused, uint32_t cmd,
				 uint32_t param_types,
				 TEE_Param params[TEE_NUM_PARAMS] __unused)
{
	switch (cmd) {
	case PTA_NANHU_IRQ_TEST_CMD_BUSY:
		return busy(param_types);
	case PTA_NANHU_IRQ_TEST_CMD_TRIGGER_NS:
		return trigger_irq(param_types, NANHU_IRQGEN_NS2_BASE,
				   44, "ns irq44", 0);
	case PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC:
		return trigger_irq(param_types, NANHU_IRQGEN_SEC2_BASE,
				   45, "secure irq45", 0);
	case PTA_NANHU_IRQ_TEST_CMD_TRIGGER_SEC_WITH_NS:
		nanhu_irq_test_set_trigger_ns_in_secure_handler(true);
		res = trigger_irq(param_types, NANHU_IRQGEN_SEC2_BASE,
				  45, "secure irq45 with ns irq44", 44);
		nanhu_irq_test_set_trigger_ns_in_secure_handler(false);
		return res;
	default:
		return TEE_ERROR_BAD_PARAMETERS;
	}
}
```

### `optee_os/core/pta/sub.mk`

将 `nanhu_irq_test.c` 纳入 OP-TEE PTA 编译。

```make
srcs-$(CFG_NANHU_IRQ_TEST_PTA) += nanhu_irq_test.c
```

### `optee_os/core/drivers/plic.c`

该文件实现 OP-TEE PLIC claim/drop/complete 语义。

新增 QEMU PLIC 扩展寄存器定义。

```c
#define PLIC_SEC_SRC_OFFSET		0x10000
#define PLIC_WORLD_STATE_OFFSET		0x11000

#define PLIC_WORLD_STATE(base, context) \
		((base) + PLIC_WORLD_STATE_OFFSET + (4 * (context)))

static uint32_t plic_last_handled_irq __nex_bss;
static uint64_t plic_handled_irq_mask __nex_bss;
```

PTA 用这些 helper 控制测试期间的 PLIC 状态和观测结果。

```c
void plic_enable_current_irq(uint32_t source)
{
	plic_enable_interrupt(&plic_data, source);
}

void plic_clear_last_handled_irq(void)
{
	plic_last_handled_irq = 0;
	plic_handled_irq_mask = 0;
}

bool plic_was_irq_handled(uint32_t source)
{
	if (source >= 64)
		return false;

	return plic_handled_irq_mask & (UINT64_C(1) << source);
}

void plic_set_current_world_state(uint32_t ws)
{
	uint32_t context = plic_get_context();
	uint32_t peer_context = context ^ 1;

	io_write32(PLIC_WORLD_STATE(plic_data.plic_base, context), ws);
	io_write32(PLIC_WORLD_STATE(plic_data.plic_base, peer_context), ws);
}
```

`plic_it_handle()` 是 OP-TEE 侧 claim/drop/handler/complete 的核心。

```c
uint32_t plic_it_handle(void)
{
	uint32_t id = plic_claim_interrupt(pd);
	bool sec = false;

	if (!id || id > pd->max_it)
		return 0;

	sec = plic_is_secure_source(pd, id);
	plic_last_handled_irq = id;
	if (id < 64)
		plic_handled_irq_mask |= UINT64_C(1) << id;

	IMSG("[optee-plic] claim irq=%" PRIu32 " sec=%u", id, sec);

	if (!sec) {
		IMSG("[optee-plic] drop non-secure irq=%" PRIu32, id);
		plic_complete_interrupt(pd, id);
		IMSG("[optee-plic] complete dropped irq=%" PRIu32, id);
		return id;
	}

	interrupt_call_handlers(&pd->chip, id);
	plic_complete_interrupt(pd, id);
	IMSG("[optee-plic] complete secure irq=%" PRIu32, id);
	return id;
}
```

### `optee_os/core/include/drivers/plic.h`

该文件声明 OP-TEE PLIC driver 对平台和 PTA 暴露的 helper。

```c
uint32_t plic_it_handle(void);
void plic_enable_current_irq(uint32_t source);
void plic_clear_last_handled_irq(void);
uint32_t plic_get_last_handled_irq(void);
bool plic_was_irq_handled(uint32_t source);
void plic_set_current_world_state(uint32_t ws);
```

### `opensbi/include/sbi_utils/irqchip/fdt_irqchip_plic.h`

该文件声明 OpenSBI PLIC world_state helper。

```c
/* Set current hart PLIC world_state for the M-mode context */
void fdt_plic_set_current_world_state(u32 ws);
```

### `opensbi/lib/utils/irqchip/fdt_irqchip_plic.c`

该文件维护 OpenSBI secure IRQ relay，并清理不再需要的测试 hook。

REE-origin secure IRQ 仍由 OpenSBI relay。注意这个路径的 claim/complete owner 是 OpenSBI，不是 OP-TEE PLIC。

```c
static int plic_secure_irqfn(void)
{
	irq = plic_claim(plic, mctx);
	sec = plic_get_sec_src(plic, irq);
	ws = plic_get_world_state(plic, mctx);

	if (!sec) {
		plic_complete(plic, mctx, irq);
		return SBI_ENOENT;
	}

	tdomain = opteed_get_tdomain();
	fiq_entry = opteed_get_fiq_entry();

	sbi_printf("plic-sec: enter tee fiq irq=%u entry=0x%lx\n",
		   irq, fiq_entry);

	plic_set_world_state(plic, mctx, 1);
	sbi_domain_context_set_mepc(tdomain, fiq_entry + 4);
	sbi_domain_context_enter(tdomain);
	return 0;
}
```

OP-TEE FIQ 返回后，OpenSBI complete 之前 claim 的 secure IRQ。

```c
void fdt_plic_secure_irq_complete(void)
{
	rec = &sec_irq_records[hartindex];
	if (!rec->pending)
		return;

	plic_complete(plic, mctx, rec->irq);
	rec->pending = 0;
	plic_set_world_state(plic, mctx, 0);
}
```

普通 CA/PTA 调用路径需要同步 world_state，但不负责 secure IRQ complete。

```c
void fdt_plic_set_current_world_state(u32 ws)
{
	struct sbi_scratch *scratch = sbi_scratch_thishart_ptr();
	struct plic_data *plic = plic_get_hart_data_ptr(scratch);
	long mctx = plic_get_hart_mcontext(scratch);

	if (!plic || mctx < 0)
		return;

	plic_set_world_state(plic, mctx, ws);
}
```

本阶段删除了旧 `plic_maybe_trigger_ns44_test()` hook，不再由 OpenSBI 在 IRQ45 relay 中触发 IRQ44。

### `opensbi/lib/utils/mpxy/fdt_mpxy_opteed.c`

该文件维护普通 CA/PTA 调用路径的 world_state。

```c
static int sbi_ecall_tee_domain_enter(unsigned long entry_point)
{
	/* CA/PTA 普通调用进入 OP-TEE 前，标记当前 hart 进入 secure world。 */
	fdt_plic_set_current_world_state(1);
	sbi_domain_context_set_mepc(tdomain, entry_point);
	sbi_domain_context_enter(tdomain);
	return 0;
}

static int sbi_ecall_tee_domain_exit(void)
{
	sbi_domain_context_exit();
	/* PTA 返回 REE 后恢复 world_state=0。 */
	fdt_plic_set_current_world_state(0);
	return 0;
}
```

FIQ return 的 secure IRQ complete 路径仍通过 `fdt_plic_secure_irq_complete()` 处理，普通 OP-TEE call/return 不会误 complete secure IRQ。

### `qemu/hw/intc/sifive_plic.c`

该文件实现测试所需的 PLIC world_state route 策略。

```c
static bool plic_irq_allowed(SiFivePLICState *plic, uint32_t addrid,
                             uint32_t irq)
{
    PLICMode mode = plic->addr_config[addrid].mode;
    uint32_t sec = plic_sec_src(plic, irq);
    uint32_t ws = plic_world_state(plic, addrid);

    if (mode == PLICMode_S) {
        if (ws) {
            /*
             * OP-TEE 正在运行：secure 和 non-secure IRQ 都先递交给
             * OP-TEE S-context，由 OP-TEE 判断 handler/drop。
             */
            return true;
        }

        /* Linux 正在运行：S-context 只接收 non-secure IRQ。 */
        return !sec;
    }

    if (mode == PLICMode_M) {
        if (ws) {
            /* OP-TEE 自治处理期间，M-context 不抢 claim。 */
            return false;
        }

        /* REE 正在运行：secure IRQ 交给 OpenSBI relay。 */
        return sec;
    }

    return false;
}
```

`sifive_plic_claimed()` 中继续用 `allowed` 参与 pending/enabled/priority 过滤。

```c
bool allowed = plic_irq_allowed(plic, addrid, irq);

if (enabled && allowed && prio > max_prio) {
	max_irq = irq;
	max_prio = prio;
}
```

注意：当前文档整理阶段没有继续修改该文件；本节只是记录前面实现阶段已经完成的变更。

## 4. 设计说明

### 4.1 为什么需要 `nanhu_irq_test` 统一工具

旧的 `devmem` 触发方式可以工作，但存在几个维护问题：

- 触发命令分散在 shell 脚本或手工命令里。
- IRQ、MMIO、写入值和测试语义没有集中记录。
- 后续 REE 测试和 TEE/PTA 测试难以用同一套入口管理。
- 日志格式不统一，不利于自动化或回归比对。

`nanhu_irq_test` 的收益：

- 使用同一个 CLI 管理 6 类测试入口。
- 在 test case table 中集中维护命令名、backend、IRQ、MMIO 和描述。
- REE MMIO backend 和 TEE PTA backend 共用一套日志与命令分发。
- 后续扩展时优先添加 table entry 和对应 backend，而不是散落新增脚本。

### 4.2 为什么 REE 测试不用 PTA

REE 测试的语义要求触发动作发生在 Linux/REE 中。

例如 `ns42-preempt-sec43` 验证的是 Linux 正在处理 non-secure IRQ42 时，secure IRQ43 能否抢占 REE。如果把 IRQ42 或 IRQ43 的触发动作改成 PTA 内触发，hart 当前 world、PLIC route、claim owner 都会变化，测试就不再验证原来的 REE 抢占语义。

因此：

- REE 测试使用 REE MMIO backend，即 Linux userspace 通过 `/dev/mem` 写 irqgen。
- TEE/PTA 测试才使用 TEE Client API 进入 OP-TEE，并在 PTA 内写 irqgen。
- `TEEC_InvokeCommand()` 只是进入 OP-TEE 的入口，不用于 REE 触发测试。

### 4.3 为什么 REE-origin secure IRQ 由 OpenSBI claim

当 Linux/REE 正在运行时，hart 当前 S-context 属于 Linux，`world_state=0`。此时 secure IRQ 不能交给 Linux S-context claim；它应由 M-mode OpenSBI claim，然后通过 secure IRQ relay 切入 OP-TEE，OP-TEE 返回后由 OpenSBI complete。

这类路径验证的是“secure IRQ 抢占 REE”，不是“OP-TEE 自治 claim/complete”。

### 4.4 为什么 TEE-origin IRQ 由 OP-TEE claim/drop/complete

当 PTA 正在运行时，hart 已经在 OP-TEE S-context 中，`world_state=1`。此时 IRQ owner 是 OP-TEE。

当前策略是：

- secure IRQ：OP-TEE claim，调用 handler，complete。
- non-secure IRQ：OP-TEE claim，判断 `sec=0`，drop，complete。

non-secure IRQ 选择“递交给 OP-TEE 后 drop”，而不是直接在 PLIC 里屏蔽，是为了让测试可观测：日志中必须能看到 OP-TEE claim 到 IRQ44，并明确 drop/complete。

### 4.5 为什么废弃旧 OpenSBI hook 测试

旧测试 2 的语义是：REE 触发 secure IRQ45，OpenSBI 在 relay IRQ45 时通过测试 hook 触发 non-secure IRQ44。这个 hook 太特殊：

- IRQ44 的触发点在 OpenSBI，不属于 REE，也不属于 OP-TEE。
- 它会和当前 “OP-TEE 运行期间 non-secure IRQ 被 drop” 的语义冲突。
- 它不能证明 OP-TEE 自己 claim/drop non-secure IRQ。

因此当前 6 类测试不再保留该 hook 测试。REE 侧仍保留 clean 的 `ree-trigger-sec45` 和 `ree-trigger-ns44`，安全世界侧使用 `trigger-sec-with-ns` 验证 secure handler 期间出现 non-secure IRQ 的行为。

## 5. 构建方法

### 5.1 构建 QEMU

如果 QEMU 还没有构建：

```sh
make qemu
```

### 5.2 构建 OP-TEE、OpenSBI 和 DTB

```sh
make optee_os
make opensbi-jump
make dtb
```

也可以使用：

```sh
make secirq
```

`secirq` 会构建 OpenSBI jump firmware、DTB 和 OP-TEE。

### 5.3 构建并安装 `nanhu_irq_test` 到 rootfs

```sh
make nanhu_irq_test-install
```

安装位置：

```text
rootfs/usr/bin/nanhu_irq_test
```

进入 QEMU 后路径为：

```text
/usr/bin/nanhu_irq_test
```

### 5.4 重新打包 rootfs 并构建 Linux

`nanhu_irq_test` 安装进 rootfs 后，需要重新打包 rootfs 并重建 Linux image：

```sh
make rootfs-pack
make linux
```

常用合并命令：

```sh
make nanhu_irq_test-install rootfs-pack linux
```

### 5.5 启动 QEMU

```sh
make run-secirq
```

如果 `build/qemu/qemu-system-riscv64` 不存在，先执行 `make qemu`。

## 6. 测试方法

启动后登录 Buildroot：

```text
buildroot login: root
```

查看命令：

```sh
nanhu_irq_test --help
```

建议按下面顺序测试：

```sh
nanhu_irq_test busy
nanhu_irq_test ree-trigger-ns44
nanhu_irq_test ree-trigger-sec45
nanhu_irq_test ns42-preempt-sec43
nanhu_irq_test trigger-ns
nanhu_irq_test trigger-sec
nanhu_irq_test trigger-sec-with-ns
```

各命令的判定标准：

| Command | Pass condition |
|---------|----------------|
| `busy` | 看到 `[optee-test] busy begin/end`，命令正常返回。 |
| `ree-trigger-ns44` | Linux 日志出现 `[ree] irq15 begin/end`，PLIC hwirq 为 44。 |
| `ree-trigger-sec45` | OpenSBI 日志出现 `plic-sec: ... irq=45 sec=1`，并在 TEE 返回后 complete。 |
| `ns42-preempt-sec43` | Linux `[ree] irq14 begin` 后出现 OpenSBI relay IRQ43，再出现 `[ree] irq14 end`。 |
| `trigger-ns` | OP-TEE 日志出现 claim IRQ44 `sec=0`，drop，complete dropped；Linux 不应处理该 IRQ。 |
| `trigger-sec` | OP-TEE 日志出现 claim IRQ45 `sec=1`，secure handler begin/end，complete secure。 |
| `trigger-sec-with-ns` | OP-TEE IRQ45 handler 中触发 IRQ44；随后 OP-TEE claim IRQ44 `sec=0`，drop，complete dropped。 |

已验证过的关键日志形态：

```text
nanhu_irq_test trigger-sec-with-ns
[nanhu-irq-test] trigger-sec-with-ns begin
[nanhu-irq-test] invoke PTA command=3
I/TC: [optee-test] trigger secure irq45 with ns irq44 begin
I/TC: [optee-plic] claim irq=45 sec=1
I/TC: [optee-test] secure irq45 handler begin
I/TC: [optee-test] secure irq45 handler trigger ns irq44
I/TC: [optee-test] secure irq45 handler end
I/TC: [optee-plic] complete secure irq=45
I/TC: [optee-plic] claim irq=44 sec=0
I/TC: [optee-plic] drop non-secure irq=44
I/TC: [optee-plic] complete dropped irq=44
I/TC: [optee-test] trigger secure irq45 with ns irq44 end
[nanhu-irq-test] trigger-sec-with-ns end
```

## 7. 当前阶段边界

当前阶段已经完成 6 类测试入口和验证。后续维护时需要保持以下边界：

- 不要把 REE 测试改成 PTA 触发；REE 测试必须保留 Linux userspace MMIO 触发语义。
- 不要恢复旧 OpenSBI hook 触发 IRQ44 的测试路径。
- 不要让 TEE/PTA 测试依赖 OpenSBI secure IRQ relay 完成 claim/complete。
- 不要让 OP-TEE drop 的 non-secure IRQ 回到 Linux 处理。
- 不要在普通文档整理中修改 QEMU PLIC route、OpenSBI relay/world_state、OP-TEE native/foreign interrupt 分类或 OP-TEE PLIC claim/drop 语义。
- `busy` 是链路辅助命令，不计入 6 类 IRQ 行为测试。

维护者需要特别注意两个不同的 secure IRQ 路径：

| IRQ arrival context | `world_state` | Claim owner | Example |
|---------------------|---------------|-------------|---------|
| REE/Linux 正在运行 | `0` | OpenSBI M-context | `ree-trigger-sec45`, `ns42-preempt-sec43` 中的 IRQ43 |
| OP-TEE/PTA 正在运行 | `1` | OP-TEE S-context PLIC | `trigger-sec`, `trigger-sec-with-ns` 中的 IRQ45 |

这两个路径都进入 OP-TEE，但验证的不是同一个语义。前者验证 secure IRQ relay 抢占 REE，后者验证 OP-TEE 自治 IRQ 处理。

## 8. 当前 git 状态摘要

文档整理前检查到的顶层状态包括：

- Modified: `Makefile`
- Modified: `config/plat-nanhu/conf.mk`
- Modified: `config/plat-nanhu/main.c`
- Modified: `config/plat-nanhu/platform_config.h`
- Modified: `host/nanhu_irq_test/Makefile`
- Modified: `host/nanhu_irq_test/nanhu_irq_test.c`
- Untracked: `host/nanhu_irq_test/tee_client_api.h`
- Modified submodules: `opensbi`, `optee_os`, `qemu`

子模块内状态：

- `optee_os`: modified `core/drivers/plic.c`, `core/include/drivers/plic.h`, `core/pta/sub.mk`; untracked `core/pta/nanhu_irq_test.c`, `lib/libutee/include/pta_nanhu_irq_test.h`
- `opensbi`: modified `include/sbi_utils/irqchip/fdt_irqchip_plic.h`, `lib/utils/irqchip/fdt_irqchip_plic.c`, `lib/utils/mpxy/fdt_mpxy_opteed.c`
- `qemu`: modified `hw/intc/sifive_plic.c`; `roms/edk2` also dirty but不属于本阶段 IRQ 测试框架改造
