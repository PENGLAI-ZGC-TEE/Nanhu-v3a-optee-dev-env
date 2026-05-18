# Nanhu IRQ Context Trace Framework

本文记录本次为 `nanhu_irq_test` 增加的跨层上下文 trace 框架。原有测试框架仍见 `docs/nanhu_irq_test_framework.md`；6 个 case 的逐条日志解析见：

```text
docs/nanhu_irq_test_6cases_explanation.md
```

两份文档的分工：

- `nanhu_irq_context_trace_framework.md`：说明这次 trace 怎么设计、改了哪些层、如何判断上下文是否恢复正确。
- `nanhu_irq_test_6cases_explanation.md`：基于实际 console log，逐条解释 6 个 case 为什么成立。

## 1. 目标

这次 trace 的目标不是增加普通调试日志，而是为 6 个 Nanhu IRQ 测试提供跨层证据链：

1. 触发点在哪个 world。
2. IRQ 最终由哪一层 claim。
3. 进入了哪层 trap/IRQ handler。
4. 保存了哪些寄存器和 CSR。
5. handler/relay 返回后，上下文是否恢复一致。

核心验证点：

```text
REE/Linux pt_regs 保存/恢复 OK
OpenSBI trap/domain context 保存/恢复 OK
OP-TEE thread_ctx_regs 保存/恢复 OK
PLIC claim/drop/complete owner 符合 sec/ws 路由策略
```

## 2. 日志前缀

统一前缀用于从同一串 console log 中快速判断层级：

| 前缀 | 所在层 | 作用 |
|---|---|---|
| `[FLOW]` | Linux userspace | 标记 `nanhu_irq_test` 命令开始/结束。 |
| `[REE-IRQ]` | Linux kernel | 打印 REE IRQ handler 的 `pt_regs` 保存和恢复检查。 |
| `[SBI-TRAP]` | OpenSBI | 打印 secure IRQ relay 进入/退出 M-mode trap 的关键寄存器。 |
| `[SBI-PLIC]` | OpenSBI | 打印 REE-origin secure IRQ 的 claim/relay/complete。 |
| `[SBI-DOM]` | OpenSBI | 打印 REE/TEE domain context save/restore/check。 |
| `[TEE-CALL]` | OP-TEE PTA | 打印 PTA command 进入、触发 IRQ、退出。 |
| `[TEE-IRQ]` | OP-TEE core | 打印 OP-TEE native IRQ 的 `thread_ctx_regs` 保存和恢复检查。 |
| `[TEE-PLIC]` | OP-TEE PLIC | 打印 TEE S-context PLIC claim/drop/complete。 |
| `[TEE-HANDLER]` | OP-TEE platform | 打印 secure IRQ45 handler 进入/退出。 |

## 3. 过滤策略

trace 必须过滤，否则启动期普通 MPXY、OP-TEE driver 初始化、timer/IPI 会刷屏。

当前过滤策略：

- Linux 侧只在 Nanhu IRQ test driver handler 中打印，因此只覆盖 IRQ42/IRQ44 对应的 Linux virtual IRQ。
- OpenSBI 侧只在 secure IRQ relay 路径打开 domain trace，因此只覆盖 REE-origin secure IRQ43/45。
- OP-TEE 侧只在 Nanhu PTA command 触发测试期间打开 `plic_nanhu_trace`。
- OP-TEE PLIC 对 IRQ44/45 打印 claim/drop/complete。
- 普通 MPXY call/return 不打印 `[SBI-DOM]`，避免启动期和 tee-supplicant 流量淹没日志。

两个 secure IRQ 路径必须区分：

| 触发点 | 例子 | owner | 主要 trace |
|---|---|---|---|
| REE/Linux | `ree-trigger-sec45`, `ns42-preempt-sec43` 中的 IRQ43 | OpenSBI M-context relay | `[SBI-TRAP]`, `[SBI-PLIC]`, `[SBI-DOM]` |
| OP-TEE/PTA | `trigger-sec`, `trigger-sec-with-ns` 中的 IRQ45 | OP-TEE S-context PLIC | `[TEE-IRQ]`, `[TEE-PLIC]`, `[TEE-HANDLER]` |

## 4. 代码实现说明

本节按文件说明这次 context trace 的实现方式。原来的 `nanhu_irq_test_framework.md` 已经说明 6 个 case 的触发框架，这里只讲本次新增的“上下文证据打印”代码。

### `host/nanhu_irq_test/nanhu_irq_test.c`

host 工具负责给每个 case 打统一的生命周期标记。它不判断寄存器是否正确，只告诉读日志的人“哪个测试开始了、从 REE 还是 TEE backend 触发、最后是否正常返回”。

核心打印：

```c
printf("[FLOW] BEGIN test=%s backend=%s", cmd->name,
       cmd->use_tee ? "TEE" : "REE");
if (cmd->use_tee)
	printf(" pta_cmd=%u\n", cmd->pta_cmd);
else
	printf(" irq=%u mmio=0x%08" PRIx64 " value=0x%x\n",
	       cmd->irq, cmd->mmio, cmd->value);

...

printf("[FLOW] END test=%s result=OK\n", cmd->name);
```

这样 6 个测试都能用同一个边界包住：

```text
[FLOW] BEGIN test=trigger-sec backend=TEE pta_cmd=2
...
[FLOW] END test=trigger-sec result=OK
```

### `linux/drivers/misc/nanhu_irq_preempt_test.c`

Linux 侧只在 Nanhu IRQ test driver 的 handler 中打印。这样天然过滤掉普通 timer/IPI 和其他 Linux IRQ。

核心数据结构是 `nanhu_irq_regs_snapshot`，保存 `struct pt_regs` 中需要对比的字段：

```c
struct nanhu_irq_regs_snapshot {
	unsigned long epc;
	unsigned long status;
	unsigned long badaddr;
	unsigned long cause;
	unsigned long ra;
	unsigned long sp;
	unsigned long t0;
	unsigned long t1;
	unsigned long t2;
	unsigned long a0;
	...
	unsigned long s11;
	unsigned long t3;
	unsigned long t4;
	unsigned long t5;
	unsigned long t6;
};
```

handler entry 读取当前 IRQ 保存现场：

```c
struct pt_regs *regs = get_irq_regs();

nanhu_irq_snapshot(&entry, regs);
nanhu_irq_trace_regs("SAVE", priv->irq, regs);
```

handler exit 再读取同一份 `pt_regs` 并比较：

```c
nanhu_irq_snapshot(&exit, regs);
pr_info("[REE-IRQ] RESTORE-CHECK irq=%d result=%s epc=0x%lx status=0x%lx cause=0x%lx\n",
	priv->irq,
	nanhu_irq_snapshot_equal(&entry, &exit) ? "OK" : "CHANGED",
	regs ? regs->epc : 0, regs ? regs->status : 0,
	regs ? regs->cause : 0);
```

这个实现证明的是：Linux IRQ handler 内部执行完后，硬件中断入口保存的 `pt_regs` 没被破坏。`ns42-preempt-sec43` 中间即使插入 OpenSBI/TEE relay，最后仍然要看到：

```text
[REE-IRQ] RESTORE-CHECK irq=14 result=OK
```

### `opensbi/include/sbi/sbi_domain_context.h`

OpenSBI 侧新增一个很小的 trace 开关接口，供 PLIC secure IRQ relay 路径打开/关闭 domain context 打印：

```c
void sbi_domain_context_trace_set(bool active, const char *reason);
bool sbi_domain_context_trace_active(void);
const char *sbi_domain_context_trace_reason(void);
```

这个接口刻意放在 domain context 层，而不是直接在 PLIC 里打印所有 domain 字段。PLIC 只负责决定什么时候打开 trace，真正的保存/恢复证据由 domain context 代码打印。

### `opensbi/lib/sbi/sbi_domain_context.c`

这里是 `[SBI-DOM]` 的核心实现。

每个 hart 有独立的 trace 状态：

```c
static bool trace_active[SBI_HARTMASK_MAX_BITS];
static const char *trace_reason[SBI_HARTMASK_MAX_BITS];
```

`switch_to_next_domain_context()` 中，如果 trace 打开，就在 CSR/trap context swap 前打印 SAVE：

```c
if (trace) {
	trap_ctx = sbi_trap_get_context(scratch);
	sbi_printf("[SBI-DOM] SAVE reason=%s from=%s to=%s sstatus=0x%lx ... trap_mepc=0x%lx\n",
		   reason, current_dom->name, target_dom->name,
		   csr_read(CSR_SSTATUS), ..., trap_ctx ? trap_ctx->regs.mepc : 0);
	trace_regs("SAVE-REGS", reason, current_dom->name,
		   target_dom->name, trap_ctx ? &trap_ctx->regs : NULL);
}
```

完成 CSR/trap context swap 后打印 RESTORE，并用预期值做 CHECK：

```c
if (trace) {
	bool ok = csr_read(CSR_SSTATUS) == exp_sstatus &&
		  csr_read(CSR_SEPC) == exp_sepc &&
		  csr_read(CSR_SATP) == exp_satp &&
		  trap_ctx->regs.mepc == exp_mepc;

	sbi_printf("[SBI-DOM] RESTORE reason=%s target=%s sstatus=0x%lx ... trap_mepc=0x%lx\n",
		   reason, target_dom->name, csr_read(CSR_SSTATUS), ...,
		   trap_ctx->regs.mepc);
	trace_regs("RESTORE-REGS", reason, current_dom->name,
		   target_dom->name, &trap_ctx->regs);
	sbi_printf("[SBI-DOM] CHECK reason=%s restore=%s result=%s sepc=0x%lx sstatus=0x%lx satp=0x%lx trap_mepc=0x%lx\n",
		   reason, target_dom->name, ok ? "OK" : "CHANGED",
		   csr_read(CSR_SEPC), csr_read(CSR_SSTATUS),
		   csr_read(CSR_SATP), trap_ctx->regs.mepc);
}
```

这里的重点不是“打印了很多寄存器”，而是 `CHECK result=OK` 的含义：恢复出来的 `sstatus/sepc/satp/trap_mepc` 和目标 domain context 中原本保存的值一致。

### `opensbi/lib/utils/irqchip/fdt_irqchip_plic.c`

这里负责 REE-origin secure IRQ 的 trace 入口。只有 secure IRQ relay 会打开 `[SBI-DOM]`。

secure IRQ 被 M-context claim 后，先打印 PLIC 和 M-mode trap 信息：

```c
sbi_printf("[SBI-PLIC] CLAIM irq=%u sec=%u ws=%u mctx=%ld hart=%u\n",
	   irq, sec, ws, mctx, hartid);
plic_sec_trace_trap("ENTER", irq);
```

`plic_sec_trace_trap()` 从当前 `sbi_trap_context` 中取 M-mode trap frame：

```c
static void plic_sec_trace_trap(const char *tag, u32 irq)
{
	struct sbi_trap_context *tcntx =
		sbi_trap_get_context(sbi_scratch_thishart_ptr());

	if (!tcntx)
		return;

	sbi_printf("[SBI-TRAP] %s irq=%u mcause=0x%lx mtval=0x%lx mepc=0x%lx mstatus=0x%lx ra=0x%lx sp=0x%lx\n",
		   tag, irq, tcntx->trap.cause, tcntx->trap.tval,
		   tcntx->regs.mepc, tcntx->regs.mstatus,
		   tcntx->regs.ra, tcntx->regs.sp);
}
```

relay 到 TEE-FIQ 前打开 domain trace：

```c
sbi_printf("[SBI-PLIC] RELAY irq=%u entry=0x%lx from=REE to=TEE-FIQ\n",
	   irq, fiq_entry);

sbi_domain_context_trace_set(true, "secure-irq-relay");
sbi_domain_context_set_mepc(tdomain, fiq_entry + 4);
sbi_domain_context_enter(tdomain);
plic_sec_trace_trap("EXIT", irq);
```

TEE-FIQ 返回后，OpenSBI complete secure IRQ，并关闭 trace：

```c
sbi_printf("[SBI-PLIC] COMPLETE irq=%u sec=%u ws=%u mctx=%ld hart=%u\n",
	   rec->irq, rec->sec, rec->ws, mctx, hartid);
sbi_domain_context_trace_set(false, NULL);
```

这里有一个重要边界：`fdt_mpxy_opteed.c` 的普通 MPXY enter/exit 不打开 `[SBI-DOM]`。原因是 OP-TEE driver 初始化、tee-supplicant 和普通 CA 调用都会走 MPXY，如果在那里全量打印，启动期会刷屏，反而看不清 Nanhu IRQ 测试。

### `optee_os/core/include/drivers/plic.h`

OP-TEE PLIC 对外暴露 Nanhu trace helper：

```c
void plic_nanhu_trace_set(bool active, const char *test);
bool plic_nanhu_trace_active(void);
const char *plic_nanhu_trace_test(void);
```

PTA 用它打开/关闭 trace，OP-TEE IRQ handler 和 PLIC driver 用它判断是否打印当前测试名。

### `optee_os/core/drivers/plic.c`

这里实现 `[TEE-PLIC]` 和 OP-TEE 侧 trace 状态。

trace 状态：

```c
static bool plic_nanhu_trace_enabled __nex_bss;
static const char *plic_nanhu_trace_name __nex_bss;
```

`plic_it_handle()` 中 claim 后打印 IRQ 和 secure 属性：

```c
if (plic_nanhu_should_trace(id))
	IMSG("[TEE-PLIC] CLAIM test=%s irq=%" PRIu32 " sec=%u",
	     plic_nanhu_trace_test(), id, sec);
```

non-secure IRQ 在 TEE 中被 drop + complete：

```c
if (!sec) {
	IMSG("[TEE-PLIC] DROP test=%s irq=%" PRIu32 " sec=0",
	     plic_nanhu_trace_test(), id);
	plic_complete_interrupt(pd, id);
	IMSG("[TEE-PLIC] COMPLETE test=%s irq=%" PRIu32 " action=dropped",
	     plic_nanhu_trace_test(), id);
	return id;
}
```

secure IRQ 调 OP-TEE handler 后 complete：

```c
interrupt_call_handlers(&pd->chip, id);
plic_complete_interrupt(pd, id);
IMSG("[TEE-PLIC] COMPLETE test=%s irq=%" PRIu32 " action=handled",
     plic_nanhu_trace_test(), id);
```

### `optee_os/core/arch/riscv/kernel/thread_arch.c`

这里实现 `[TEE-IRQ]`，也就是 OP-TEE native external interrupt 的上下文保存/恢复检查。

外部中断进入时，如果 Nanhu trace 打开，就 snapshot `thread_ctx_regs`：

```c
bool trace = plic_nanhu_trace_active() && (cause & LONG_MAX) == IRQ_XEXT;
struct nanhu_thread_regs_snapshot entry = { };
struct nanhu_thread_regs_snapshot exit = { };

if (trace) {
	nanhu_thread_snapshot(&entry, regs);
	nanhu_thread_trace_regs("SAVE", regs, cause);
}
```

正常走 OP-TEE interrupt handler：

```c
case IRQ_XEXT:
	thread_irq_handler();
	break;
```

handler 返回后再次 snapshot 并比较：

```c
if (trace) {
	nanhu_thread_snapshot(&exit, regs);
	IMSG("[TEE-IRQ] RESTORE-CHECK test=%s result=%s epc=0x%lx status=0x%lx ie=0x%lx",
	     plic_nanhu_trace_test(),
	     nanhu_thread_snapshot_equal(&entry, &exit) ? "OK" : "CHANGED",
	     regs->epc, regs->status, regs->ie);
}
```

这个逻辑证明 OP-TEE IRQ handler 没有破坏被中断 PTA 的 `thread_ctx_regs`。

### `optee_os/core/pta/nanhu_irq_test.c`

PTA 是 TEE-origin IRQ 测试的入口，因此它负责打印 `[TEE-CALL]` 并控制 OP-TEE trace 开关。

command 入口：

```c
IMSG("[TEE-CALL] ENTER command=%s id=%" PRIu32, name, cmd);
res = trigger_irq(...);
IMSG("[TEE-CALL] EXIT command=%s result=0x%x", name, res);
```

真正触发 IRQ 前打印测试名、目标 IRQ 和 followup IRQ：

```c
IMSG("[TEE-CALL] TRIGGER_IRQ test=%s irq=%" PRIu32 " followup=%" PRIu32,
     name, irq, followup_irq);
```

只在 PTA 触发 IRQ 的窗口内打开 OP-TEE trace：

```c
plic_clear_last_handled_irq();
plic_nanhu_trace_set(true, name);
plic_set_current_world_state(1);
io_write32(va + NANHU_IRQGEN_TRIGGER, 1);

res = wait_for_irq(irq);
if (!res && followup_irq)
	res = wait_for_irq(followup_irq);

plic_set_current_world_state(0);
plic_nanhu_trace_set(false, NULL);
```

这样 `trigger-ns`、`trigger-sec`、`trigger-sec-with-ns` 只打印本次测试相关的 TEE IRQ，不污染其他 OP-TEE 运行日志。

### `config/plat-nanhu/main.c`

Nanhu 平台的 secure IRQ45 handler 增加 `[TEE-HANDLER]`：

```c
IMSG("[TEE-HANDLER] ENTER irq=%u", NANHU_SEC_TEST_IRQ);
...
IMSG("[TEE-HANDLER] EXIT irq=%u", NANHU_SEC_TEST_IRQ);
```

`trigger-sec-with-ns` 中，如果测试开关打开，IRQ45 handler 会触发 IRQ44：

```c
if (trigger_ns_in_secure_handler) {
	IMSG("[optee-test] secure irq45 handler trigger ns irq44");
	io_write32(ns_irqgen + NANHU_IRQGEN_TRIGGER, 1);
}
```

这部分日志和 `[TEE-PLIC] CLAIM irq=44 sec=0` 连起来，证明 secure handler 内触发的 non-secure IRQ44 没有中途打断 IRQ45 handler，而是在 IRQ45 complete 后被 OP-TEE claim/drop/complete。

## 5. Linux REE Trace

修改文件：

```text
linux/drivers/misc/nanhu_irq_preempt_test.c
```

实现方式：

- 在 Nanhu Linux IRQ handler 中调用 `get_irq_regs()`。
- handler entry 打印 `[REE-IRQ] SAVE` 和 GPR。
- handler exit 再读取同一份 `pt_regs`，打印 `[REE-IRQ] RESTORE-CHECK`。

关键字段：

```text
epc/status/cause/badaddr
ra/sp/gp/tp
a0-a7
s0-s11
t0-t6
```

典型日志：

```text
[REE-IRQ] SAVE irq=14 epc=... status=... cause=...
[REE-IRQ] GPR irq=14 ra=... sp=... a0=... s11=...
[REE-IRQ] GPR irq=14 t0=... t6=...
[REE-IRQ] RESTORE-CHECK irq=14 result=OK epc=... status=... cause=...
```

判断：

- `result=OK` 表示 Linux IRQ handler 前后关键寄存器一致。
- 在 `ns42-preempt-sec43` 中，`SAVE irq=14` 与 `RESTORE-CHECK irq=14 result=OK` 中间插入 `[SBI-*]`，说明 secure IRQ43 抢占了 Linux IRQ42 handler，但没有破坏 REE IRQ42 上下文。

## 6. OpenSBI Trace

修改文件：

```text
opensbi/include/sbi/sbi_domain_context.h
opensbi/lib/sbi/sbi_domain_context.c
opensbi/lib/utils/irqchip/fdt_irqchip_plic.c
```

实现方式：

- `fdt_irqchip_plic.c` 在 secure IRQ relay 处打印 `[SBI-PLIC]` 和 `[SBI-TRAP]`。
- relay 前调用 `sbi_domain_context_trace_set(true, "secure-irq-relay")`。
- `sbi_domain_context.c` 只在 trace 开关打开时打印 `[SBI-DOM] SAVE/RESTORE/CHECK`。
- secure IRQ complete 后关闭 trace 开关。

典型日志：

```text
[SBI-PLIC] CLAIM irq=43 sec=1 ws=0 ...
[SBI-TRAP] ENTER irq=43 mcause=0x800000000000000b ...
[SBI-PLIC] RELAY irq=43 entry=... from=REE to=TEE-FIQ
[SBI-DOM] SAVE reason=secure-irq-relay from=untrusted-domain to=trusted-domain ...
[SBI-DOM] RESTORE reason=secure-irq-relay target=trusted-domain ...
[SBI-DOM] CHECK reason=secure-irq-relay restore=trusted-domain result=OK ...
[SBI-TRAP] EXIT irq=43 ... mepc=0x810002a8 ...
[SBI-DOM] SAVE reason=secure-irq-relay from=trusted-domain to=untrusted-domain ...
[SBI-DOM] RESTORE reason=secure-irq-relay target=untrusted-domain ...
[SBI-DOM] CHECK reason=secure-irq-relay restore=untrusted-domain result=OK ...
[SBI-PLIC] COMPLETE irq=43 ...
```

判断：

- `[SBI-TRAP] ENTER` 中 `mcause=...0xb` 表示 M-mode external interrupt。
- `sec=1 ws=0` 表示 secure IRQ 在 REE world 到达，不能交给 Linux。
- 第一组 `[SBI-DOM]` 是 REE -> TEE domain switch。
- `[SBI-TRAP] EXIT ... mepc=0x810002a8` 表示 OpenSBI 即将返回到 TEE-FIQ entry，不表示 TEE 已经处理完。
- 第二组 `[SBI-DOM]` 是 TEE-FIQ 路径返回后，TEE -> REE domain switch。
- `restore=untrusted-domain result=OK` 是 REE context 恢复正确的核心证据。

## 7. OP-TEE Trace

修改文件：

```text
optee_os/core/arch/riscv/kernel/thread_arch.c
optee_os/core/drivers/plic.c
optee_os/core/include/drivers/plic.h
optee_os/core/pta/nanhu_irq_test.c
config/plat-nanhu/main.c
```

实现方式：

- PTA command 入口/出口打印 `[TEE-CALL]`。
- PTA 触发 IRQ 前打开 `plic_nanhu_trace`。
- `thread_native_interrupt_handler()` 在 external interrupt entry/exit 比较 `thread_ctx_regs`。
- `plic_it_handle()` 打印 `[TEE-PLIC] CLAIM/DROP/COMPLETE`。
- Nanhu secure IRQ45 handler 打印 `[TEE-HANDLER] ENTER/EXIT`。

典型 secure IRQ45：

```text
[TEE-CALL] ENTER command=trigger-sec id=2
[TEE-CALL] TRIGGER_IRQ test=trigger-sec irq=45 followup=0
[TEE-IRQ] SAVE test=trigger-sec ...
[TEE-PLIC] CLAIM test=trigger-sec irq=45 sec=1
[TEE-HANDLER] ENTER irq=45
[TEE-HANDLER] EXIT irq=45
[TEE-PLIC] COMPLETE test=trigger-sec irq=45 action=handled
[TEE-IRQ] RESTORE-CHECK test=trigger-sec result=OK ...
[TEE-CALL] EXIT command=trigger-sec result=0x0
```

典型 non-secure IRQ44 drop：

```text
[TEE-CALL] ENTER command=trigger-ns id=1
[TEE-IRQ] SAVE test=trigger-ns ...
[TEE-PLIC] CLAIM test=trigger-ns irq=44 sec=0
[TEE-PLIC] DROP test=trigger-ns irq=44 sec=0
[TEE-PLIC] COMPLETE test=trigger-ns irq=44 action=dropped
[TEE-IRQ] RESTORE-CHECK test=trigger-ns result=OK ...
```

判断：

- `sec=1` 必须进入 `[TEE-HANDLER]` 并 `action=handled`。
- `sec=0` 不进入业务 handler，必须 `DROP` 并 `action=dropped`。
- `[TEE-IRQ] RESTORE-CHECK result=OK` 表示 IRQ handler 前后 PTA 被中断现场一致。

## 8. 六个 Case 的 Trace 预期

| Command | 关键 trace |
|---|---|
| `ree-trigger-ns44` | `[FLOW]`，`[REE-IRQ] SAVE/RESTORE-CHECK result=OK`。 |
| `ree-trigger-sec45` | `[SBI-TRAP]`，`[SBI-PLIC] CLAIM/RELAY/COMPLETE`，`[SBI-DOM] ... result=OK`，不应有 Linux `[REE-IRQ]` 处理 IRQ45。 |
| `ns42-preempt-sec43` | `[REE-IRQ] SAVE irq=14` 后插入 OpenSBI relay IRQ43，最后 `[REE-IRQ] RESTORE-CHECK irq=14 result=OK`。 |
| `trigger-ns` | `[TEE-IRQ] SAVE`，`[TEE-PLIC] CLAIM irq=44 sec=0`，`DROP`，`COMPLETE action=dropped`，`RESTORE-CHECK result=OK`。 |
| `trigger-sec` | `[TEE-PLIC] CLAIM irq=45 sec=1`，`[TEE-HANDLER] ENTER/EXIT`，`COMPLETE action=handled`，`RESTORE-CHECK result=OK`。 |
| `trigger-sec-with-ns` | 先 IRQ45 handled，再 IRQ44 dropped；两次 `[TEE-IRQ] RESTORE-CHECK` 都为 `result=OK`。 |

更详细的日志顺序和解释见：

```text
docs/nanhu_irq_test_6cases_explanation.md
```

## 9. 维护边界

- 不要把 REE-origin secure IRQ 写成 OP-TEE PLIC claim 路径；它是 OpenSBI relay 到 TEE-FIQ 路径。
- 不要对普通 MPXY call/return 全量打开 `[SBI-DOM]`，否则启动期会刷屏。
- 不要在汇编入口里堆大量打印；当前策略是在 C 层读取已经保存好的上下文。
- `trigger-ns` 中 TEE 对 non-secure IRQ44 的语义是 drop + complete，不是 defer 给 REE。
- `trigger-sec` 和 `ree-trigger-sec45` 都涉及 secure IRQ45，但前者是 OP-TEE-origin，后者是 REE-origin，claim owner 不同。
