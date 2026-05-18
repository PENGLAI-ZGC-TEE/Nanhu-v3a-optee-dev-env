# Nanhu IRQ Test 六个测试日志讲解整理

本文整理并解释以下 6 个 `nanhu_irq_test` 测试日志：

1. `ns42-preempt-sec43`
2. `ree-trigger-ns44`
3. `ree-trigger-sec45`
4. `trigger-ns`
5. `trigger-sec`
6. `trigger-sec-with-ns`

这些测试共同验证的是：在 REE / TEE 双世界环境下，PLIC 扩展后的安全属性 `sec` 与当前世界状态 `ws` 是否能正确决定中断路由、抢占行为、上下文切换和 complete/eoi 行为。

---

## 0. 总体结论

从 6 条日志来看，整体结果都是 `result=OK`，说明当前安全中断路由机制的核心语义已经跑通：

| 当前世界 | 中断属性 | 预期行为 | 当前日志表现 |
|---|---:|---|---|
| REE | `sec=0` | 交给 REE/Linux 处理 | `ree-trigger-ns44` OK |
| REE | `sec=1` | OpenSBI/M 态接管，relay 到 TEE-FIQ | `ree-trigger-sec45` OK |
| REE 正在处理中断 | `sec=1` | Secure 中断可以抢占 REE，切到 TEE，完成后返回 REE | `ns42-preempt-sec43` OK |
| TEE | `sec=0` | 不让 Non-secure 中断干扰 TEE，drop + complete | `trigger-ns` OK |
| TEE | `sec=1` | TEE 自己 claim、handle、complete | `trigger-sec` OK |
| TEE secure handler 内触发 ns | `sec=0` followup | 先完成 secure handler，再 drop ns 中断 | `trigger-sec-with-ns` OK |

当前实现表现出的核心策略可以概括为：

```text
当前在 REE：
  sec=0 → REE/Linux 处理
  sec=1 → OpenSBI relay 到 TEE-FIQ

当前在 TEE：
  sec=1 → TEE 正常处理
  sec=0 → TEE drop + complete，不让它干扰 TEE
```

---

## 1. 术语说明

### 1.1 REE 与 TEE

- **REE**：Rich Execution Environment，也就是普通 Linux / Non-secure 世界。
- **TEE**：Trusted Execution Environment，也就是 OP-TEE / Secure 世界。

在日志中常见对应关系：

```text
untrusted-domain = REE
trusted-domain   = TEE
```

---

### 1.2 `sec`

`sec` 是中断源的安全属性：

```text
sec=0 → Non-secure interrupt
sec=1 → Secure interrupt
```

---

### 1.3 `ws`

`ws` 是当前 world state：

```text
ws=0 → 当前在 REE / Non-secure world
ws=1 → 当前在 TEE / Secure world
```

---

### 1.4 `hwirq` 与 `irq`

日志中有时会同时出现：

```text
hwirq=44
irq=15
```

这不是矛盾。

通常可以理解为：

```text
PLIC 硬件中断号 hwirq=44
    ↓ Linux irq domain 映射
Linux 内部虚拟中断号 irq=15
```

所以：

- `hwirq` 是硬件中断源编号。
- `irq` 可能是 Linux 内部映射后的虚拟中断号，也可能是 TEE/OpenSBI 路径中直接打印的中断源编号，具体要结合日志上下文判断。

---

### 1.5 `claim`、`complete`、`eoi`

PLIC 中断处理基本流程是：

```text
claim
  ↓
handler
  ↓
complete / eoi
```

含义：

- `claim`：从 PLIC 取出当前最高优先级 pending 中断。
- `handler`：软件处理中断。
- `complete/eoi`：告诉 PLIC 当前中断已经处理完。

在 REE/Linux 侧日志中常见：

```text
riscv-plic: [ree-plic] claim cpu=0 hwirq=44
riscv-plic: [ree-plic] eoi cpu=0 hwirq=44
```

在 TEE/OpenSBI 侧常见：

```text
[TEE-PLIC] CLAIM ...
[TEE-PLIC] COMPLETE ...
[SBI-PLIC] CLAIM ...
[SBI-PLIC] COMPLETE ...
```

---

## 2. 测试一：`ns42-preempt-sec43`

### 2.1 测试目标

该测试验证：

**REE 正在处理 Non-secure 中断 42 时，如果触发 Secure 中断 43，Secure 中断能否抢占 REE，由 OpenSBI/M 态 relay 到 TEE-FIQ 路径，然后再正确返回 REE。**

也就是验证：

```text
REE 正在处理中断
  ↓
Secure interrupt 到来
  ↓
OpenSBI/M 态 claim secure irq43
  ↓
OpenSBI 将 world_state 切到 TEE，并执行 REE → TEE domain context switch
  ↓
TEE-FIQ 路径被调度，随后返回 OpenSBI
  ↓
OpenSBI 恢复 REE domain context 并 complete irq43
  ↓
REE 继续原来的中断处理
```

---

### 2.2 关键流程

测试开始：

```text
[FLOW] BEGIN test=ns42-preempt-sec43 backend=REE irq=42 mmio=0x30000000 value=0x1
[nanhu-irq-test] write mmio=0x30000000 value=0x1
```

REE/Linux claim 到硬件中断 42：

```text
riscv-plic: [ree-plic] claim cpu=0 hwirq=42
```

Linux 映射后的中断号是 `irq=14`：

```text
[REE-IRQ] SAVE irq=14 ...
[ree] irq14 begin count=1: trigger secure peer
```

这里说明 REE 正在处理 `hwirq=42` 对应的 Linux 中断 `irq=14`，并在 handler 内部触发了 secure peer，也就是安全中断 43。

随后 PLIC 安全路径发现：

```text
plic-sec: hart0 mctx=0 irq=43 sec=1 ws=0 count=1
```

这行非常关键：

```text
irq=43
sec=1
ws=0
```

含义是：

```text
当前在 REE world，但来了一个 Secure interrupt 43
```

因此它不能继续交给 REE/Linux，而是由 M 态/OpenSBI 接管：

```text
[SBI-PLIC] CLAIM irq=43 sec=1 ws=0 mctx=0 hart=0
[SBI-PLIC] RELAY irq=43 entry=0x810002a8 from=REE to=TEE-FIQ
plic-sec: switch ws -> 1 before tee irq=43 mctx=0
```

这说明 OpenSBI 做了：

```text
world_state: 0 → 1
REE domain → TEE domain
返回目标切到 TEE-FIQ entry
```

随后 domain context switch 打印出 REE 侧上下文保存证据：

```text
[SBI-DOM] SAVE reason=secure-irq-relay from=untrusted-domain to=trusted-domain ...
[SBI-DOM] SAVE-REGS reason=secure-irq-relay from=untrusted-domain to=trusted-domain ...
```

并恢复 TEE 侧上下文：

```text
[SBI-DOM] RESTORE reason=secure-irq-relay target=trusted-domain ...
[SBI-DOM] CHECK reason=secure-irq-relay restore=trusted-domain result=OK ...
```

然后 OpenSBI trap 返回目标变成 TEE-FIQ entry：

```text
[SBI-TRAP] EXIT irq=43 ... mepc=0x810002a8 ...
plic-sec: tee context armed irq=43 pending=1 count=1 ws=1 sec=1
```

这两行不是“TEE 已经处理完”的标志，而是说明 OpenSBI 即将从 M 态返回到 TEE-FIQ 入口。之后 TEE-FIQ 路径返回 OpenSBI，日志中表现为再切回 REE：

```text
[SBI-DOM] SAVE reason=secure-irq-relay from=trusted-domain to=untrusted-domain ...
[SBI-DOM] RESTORE reason=secure-irq-relay target=untrusted-domain ...
[SBI-DOM] CHECK reason=secure-irq-relay restore=untrusted-domain result=OK ...
```

最后 complete secure irq 43，并切回 REE：

```text
[SBI-PLIC] COMPLETE irq=43 sec=1 ws=0 mctx=0 hart=0
plic-sec: tee return -> complete irq=43 pending=0 count=1 ws=0 sec=1
plic-sec: switch ws -> 0 after tee irq=43 mctx=0
```

REE 原本的中断继续结束：

```text
[ree] irq14 end count=1
[REE-IRQ] RESTORE-CHECK irq=14 result=OK ...
riscv-plic: [ree-plic] eoi cpu=0 hwirq=42
[FLOW] END test=ns42-preempt-sec43 result=OK
```

---

### 2.3 该测试证明了什么

该测试证明：

1. REE 正在处理 Non-secure 中断时，Secure 中断可以进入 M 态安全路由。
2. OpenSBI 能识别 `sec=1, ws=0`，并把中断 relay 到 TEE-FIQ。
3. REE 上下文能被保存。
4. TEE 上下文能被恢复。
5. TEE-FIQ 路径返回 OpenSBI 后，OpenSBI 能恢复 REE 上下文。
6. REE 能继续完成原本的中断 42。
7. `RESTORE-CHECK` 和最终 `result=OK` 都说明上下文没有被破坏。

完整路径是：

```text
REE 触发 ns42
  ↓
REE/Linux claim hwirq=42
  ↓
REE irq14 handler begin
  ↓
handler 内触发 secure irq43
  ↓
OpenSBI claim irq43 sec=1 ws=0
  ↓
切 world_state 0 → 1
  ↓
保存 REE 上下文
  ↓
恢复 TEE 上下文
  ↓
OpenSBI trap 返回目标切到 TEE-FIQ entry
  ↓
TEE-FIQ 路径返回 OpenSBI
  ↓
保存 TEE 上下文
  ↓
恢复 REE 上下文
  ↓
complete irq43
  ↓
切 world_state 1 → 0
  ↓
REE irq14 handler end
  ↓
REE eoi hwirq=42
  ↓
result=OK
```

---

## 3. 测试二：`ree-trigger-ns44`

### 3.1 测试目标

该测试验证：

**REE 侧触发一个普通 Non-secure 中断 44，是否会被 REE/Linux 正常 claim、处理、恢复上下文并 eoi。**

这是最基础的非安全中断路径。

---

### 3.2 关键流程

测试开始：

```text
[FLOW] BEGIN test=ree-trigger-ns44 backend=REE irq=44 mmio=0x30002000 value=0x1
[nanhu-irq-test] write mmio=0x30002000 value=0x1
```

REE 写 MMIO：

```text
addr = 0x30002000
value = 0x1
```

触发硬件中断 44。

Linux PLIC 驱动 claim 到这个中断：

```text
riscv-plic: [ree-plic] claim cpu=0 hwirq=44
```

这说明它走的是 REE/Linux 普通 PLIC 路径。

随后 REE 保存上下文：

```text
[REE-IRQ] SAVE irq=15 epc=0x2ab3efffde status=0x200004020 cause=0x8000000000000009 badaddr=0x0
```

这里：

```text
hwirq=44
irq=15
```

说明硬件中断 44 被 Linux irq domain 映射成了 `irq=15`。

REE handler 正常执行：

```text
[ree] irq15 begin count=1
[ree] irq15 end count=1
```

恢复检查通过：

```text
[REE-IRQ] RESTORE-CHECK irq=15 result=OK ...
```

最后 REE/Linux 对 hwirq=44 执行 eoi：

```text
riscv-plic: [ree-plic] eoi cpu=0 hwirq=44
[FLOW] END test=ree-trigger-ns44 result=OK
```

---

### 3.3 该测试证明了什么

该测试证明普通非安全中断路径正常：

```text
REE 写 MMIO 0x30002000
  ↓
触发 hwirq=44
  ↓
REE/Linux claim hwirq=44
  ↓
映射为 Linux irq=15
  ↓
REE 保存上下文
  ↓
REE handler begin/end
  ↓
REE restore check OK
  ↓
REE/Linux eoi hwirq=44
  ↓
result=OK
```

它同时说明：

1. Non-secure 中断没有被错误路由到 TEE。
2. REE/Linux PLIC 路径可用。
3. REE 中断上下文保存/恢复正常。
4. PLIC claim/eoi 顺序正常。

---

## 4. 测试三：`ree-trigger-sec45`

### 4.1 测试目标

该测试验证：

**REE 侧触发一个 Secure 中断 45 时，REE/Linux 不应该直接处理它，而应该由 OpenSBI/M 态 claim，然后 relay 到 TEE-FIQ 路径，最后再返回 REE。**

---

### 4.2 关键流程

测试开始：

```text
[FLOW] BEGIN test=ree-trigger-sec45 backend=REE irq=45 mmio=0x30003000 value=0x1
[nanhu-irq-test] write mmio=0x30003000 value=0x1
```

REE 写 MMIO：

```text
addr = 0x30003000
value = 0x1
```

触发 secure irq 45。

注意这条日志里没有：

```text
riscv-plic: [ree-plic] claim cpu=0 hwirq=45
[REE-IRQ] SAVE ...
```

这很关键，因为 secure irq 45 不应该被 REE/Linux claim 到。

随后安全路径打印：

```text
plic-sec: hart0 mctx=0 irq=45 sec=1 ws=0 count=2
```

含义：

```text
当前在 REE world，来了 secure irq45
```

OpenSBI/M 态 claim 到中断：

```text
[SBI-PLIC] CLAIM irq=45 sec=1 ws=0 mctx=0 hart=0
[SBI-TRAP] ENTER irq=45 mcause=0x800000000000000b ...
```

`mcause=0x800000000000000b` 表示 Machine external interrupt。

随后 OpenSBI relay 到 TEE-FIQ 路径：

```text
[SBI-PLIC] RELAY irq=45 entry=0x810002a8 from=REE to=TEE-FIQ
plic-sec: enter tee fiq irq=45 entry=0x810002a8
plic-sec: switch ws -> 1 before tee irq=45 mctx=0
```

domain context switch 打印出 REE 侧上下文保存证据：

```text
[SBI-DOM] SAVE reason=secure-irq-relay from=untrusted-domain to=trusted-domain ...
[SBI-DOM] SAVE-REGS reason=secure-irq-relay from=untrusted-domain to=trusted-domain ...
```

并恢复 TEE 侧上下文：

```text
[SBI-DOM] RESTORE reason=secure-irq-relay target=trusted-domain ...
[SBI-DOM] CHECK reason=secure-irq-relay restore=trusted-domain result=OK ...
```

OpenSBI trap 返回目标变成 TEE-FIQ entry：

```text
[SBI-TRAP] EXIT irq=45 ... mepc=0x810002a8 ...
plic-sec: tee context armed irq=45 pending=1 count=2 ws=1 sec=1
```

这表示 OpenSBI 即将从 M 态返回到 TEE-FIQ 入口。之后 TEE-FIQ 路径返回 OpenSBI，日志中表现为再切回 REE：

```text
[SBI-DOM] SAVE reason=secure-irq-relay from=trusted-domain to=untrusted-domain ...
[SBI-DOM] RESTORE reason=secure-irq-relay target=untrusted-domain ...
[SBI-DOM] CHECK reason=secure-irq-relay restore=untrusted-domain result=OK ...
```

complete secure irq 45：

```text
[SBI-PLIC] COMPLETE irq=45 sec=1 ws=0 mctx=0 hart=0
plic-sec: tee return -> complete irq=45 pending=0 count=2 ws=0 sec=1 mctx=0 hart=0
plic-sec: switch ws -> 0 after tee irq=45 mctx=0
```

测试结束：

```text
[FLOW] END test=ree-trigger-sec45 result=OK
```

---

### 4.3 该测试证明了什么

该测试证明：

```text
REE 触发 secure irq45
  ↓
REE/Linux 没有 claim
  ↓
OpenSBI/M-mode claim
  ↓
识别 sec=1, ws=0
  ↓
relay 到 TEE-FIQ
  ↓
切 world_state 0 → 1
  ↓
保存 REE 上下文
  ↓
恢复 TEE 上下文
  ↓
OpenSBI trap 返回目标切到 TEE-FIQ entry
  ↓
TEE-FIQ 路径返回 OpenSBI
  ↓
保存 TEE 上下文
  ↓
恢复 REE 上下文
  ↓
complete irq45
  ↓
切回 ws=0
  ↓
result=OK
```

它和 `ree-trigger-ns44` 配合起来，证明安全属性区分有效：

```text
sec=0 → REE/Linux 处理
sec=1 → OpenSBI relay 到 TEE-FIQ 路径
```

---

## 5. 测试四：`trigger-ns`

### 5.1 测试目标

该测试验证：

**TEE 运行期间触发一个 Non-secure 中断 44 时，TEE 是否会拒绝处理它，并执行 drop + complete，保证 TEE 不被 Non-secure 中断干扰。**

---

### 5.2 关键流程

测试从 TEE PTA 入口开始：

```text
[FLOW] BEGIN test=trigger-ns backend=TEE pta_cmd=1
[nanhu-irq-test] invoke PTA command=1
I/TC: [TEE-CALL] ENTER command=trigger-ns id=1
```

TEE 内部准备触发 irq 44：

```text
I/TC: [TEE-CALL] TRIGGER_IRQ test=trigger-ns irq=44 followup=0
I/TC: [optee-test] trigger trigger-ns begin
```

TEE 收到外部中断并保存上下文：

```text
I/TC: [TEE-IRQ] SAVE test=trigger-ns cause=0x8000000000000009 epc=0x81017d0a status=0x8000000200046720 ie=0x200
```

TEE PLIC claim 到 irq44：

```text
I/TC: [TEE-PLIC] CLAIM test=trigger-ns irq=44 sec=0
```

这里 `sec=0` 表示它是 Non-secure 中断。

当前处于 TEE，所以 TEE 不应该正常处理它。因此日志中出现：

```text
I/TC: [TEE-PLIC] DROP test=trigger-ns irq=44 sec=0
I/TC: [TEE-PLIC] COMPLETE test=trigger-ns irq=44 action=dropped
```

上下文恢复检查通过：

```text
I/TC: [TEE-IRQ] RESTORE-CHECK test=trigger-ns result=OK ...
```

PTA 返回成功：

```text
I/TC: [TEE-CALL] EXIT command=trigger-ns result=0x0
[FLOW] END test=trigger-ns result=OK
```

---

### 5.3 该测试证明了什么

该测试证明：

```text
REE 调用 TEE PTA command=1
  ↓
进入 TEE
  ↓
TEE 触发 ns irq44
  ↓
TEE-PLIC claim irq44
  ↓
发现 sec=0
  ↓
TEE 不进入业务 handler
  ↓
DROP irq44
  ↓
COMPLETE irq44 action=dropped
  ↓
TEE restore check OK
  ↓
PTA 返回
  ↓
result=OK
```

它验证了：

```text
TEE 中遇到 Non-secure interrupt，不让它干扰 TEE。
```

---

### 5.4 需要注意的语义

当前日志中的策略是：

```text
TEE claim ns irq44 后直接 drop + complete
```

这意味着这个 ns 中断被消费掉了。

如果设计目标是：

```text
TEE 运行期间 ns 中断不抢占 TEE，但等返回 REE 后还要交给 REE 处理
```

那么当前 `drop + complete` 语义还不够，需要设计一种 pending/defer 机制。

但如果设计目标是：

```text
TEE 中出现 ns 中断直接忽略，不影响 TEE
```

那这条日志就是正确成功路径。

---

## 6. 测试五：`trigger-sec`

### 6.1 测试目标

该测试验证：

**TEE 运行期间触发 Secure 中断 45 时，TEE 能否自己 claim、进入 secure handler、complete，并且恢复上下文。**

---

### 6.2 关键流程

测试从 TEE PTA 入口开始：

```text
[FLOW] BEGIN test=trigger-sec backend=TEE pta_cmd=2
[nanhu-irq-test] invoke PTA command=2
I/TC: [TEE-CALL] ENTER command=trigger-sec id=2
```

TEE 准备触发 irq45：

```text
I/TC: [TEE-CALL] TRIGGER_IRQ test=trigger-sec irq=45 followup=0
I/TC: [optee-test] trigger trigger-sec begin
```

TEE 保存中断上下文：

```text
I/TC: [TEE-IRQ] SAVE test=trigger-sec cause=0x8000000000000009 epc=0x81017d0a status=0x8000000200046720 ie=0x200
```

TEE claim 到 irq45，并识别为 secure：

```text
I/TC: [TEE-PLIC] CLAIM test=trigger-sec irq=45 sec=1
```

然后进入 TEE secure handler：

```text
I/TC: [TEE-HANDLER] ENTER irq=45
I/TC: [optee-test] secure irq45 handler begin
I/TC: [optee-test] secure irq45 handler end
I/TC: [TEE-HANDLER] EXIT irq=45
```

complete irq45：

```text
I/TC: [TEE-PLIC] COMPLETE test=trigger-sec irq=45 action=handled
```

恢复检查通过：

```text
I/TC: [TEE-IRQ] RESTORE-CHECK test=trigger-sec result=OK ...
```

PTA 返回：

```text
I/TC: [TEE-CALL] EXIT command=trigger-sec result=0x0
[FLOW] END test=trigger-sec result=OK
```

---

### 6.3 该测试证明了什么

该测试证明：

```text
REE 调用 TEE PTA command=2
  ↓
进入 TEE
  ↓
TEE 触发 secure irq45
  ↓
TEE-PLIC claim irq45
  ↓
识别 sec=1
  ↓
进入 TEE secure irq45 handler
  ↓
handler 正常执行
  ↓
TEE-PLIC complete irq45 action=handled
  ↓
TEE restore check OK
  ↓
PTA 正常返回
  ↓
result=OK
```

它和 `trigger-ns` 形成对照：

```text
TEE 中：
  sec=0 → drop + complete
  sec=1 → handler + complete
```

---

## 7. 测试六：`trigger-sec-with-ns`

### 7.1 测试目标

该测试验证：

**TEE 正在处理 Secure 中断 45 时，如果 handler 内部又触发一个 Non-secure 中断 44，是否能先完成 secure handler，然后再 drop 这个 ns 中断，保证 ns 中断不会抢占/破坏 TEE。**

也就是验证：

```text
TEE secure irq45 handler running
  ↓
handler 内触发 ns irq44
  ↓
ns irq44 不应打断 secure handler
  ↓
secure irq45 先 complete
  ↓
之后 TEE claim 到 ns irq44
  ↓
发现 sec=0
  ↓
drop + complete
```

---

### 7.2 关键流程

测试入口：

```text
[FLOW] BEGIN test=trigger-sec-with-ns backend=TEE pta_cmd=3
[nanhu-irq-test] invoke PTA command=3
I/TC: [TEE-CALL] ENTER command=trigger-sec-with-ns id=3
```

TEE 准备触发 irq45，并设置 followup=44：

```text
I/TC: [TEE-CALL] TRIGGER_IRQ test=trigger-sec-with-ns irq=45 followup=44
```

这说明：

```text
先触发 secure irq45
在 secure irq45 handler 内再触发 ns irq44
```

TEE 第一次进入 IRQ，claim 到 irq45：

```text
I/TC: [TEE-PLIC] CLAIM test=trigger-sec-with-ns irq=45 sec=1
```

进入 secure irq45 handler：

```text
I/TC: [TEE-HANDLER] ENTER irq=45
I/TC: [optee-test] secure irq45 handler begin
I/TC: [optee-test] secure irq45 handler trigger ns irq44
I/TC: [optee-test] secure irq45 handler end
I/TC: [TEE-HANDLER] EXIT irq=45
```

这里最关键的是：

```text
secure irq45 handler trigger ns irq44
secure irq45 handler end
```

说明 ns44 被触发了，但它没有立刻打断 secure irq45 handler。

随后 complete irq45：

```text
I/TC: [TEE-PLIC] COMPLETE test=trigger-sec-with-ns irq=45 action=handled
```

第一次恢复检查通过：

```text
I/TC: [TEE-IRQ] RESTORE-CHECK test=trigger-sec-with-ns result=OK ...
```

然后 TEE 第二次进入 IRQ，claim 到 followup irq44：

```text
I/TC: [TEE-PLIC] CLAIM test=trigger-sec-with-ns irq=44 sec=0
```

发现 `sec=0`，执行 drop：

```text
I/TC: [TEE-PLIC] DROP test=trigger-sec-with-ns irq=44 sec=0
I/TC: [TEE-PLIC] COMPLETE test=trigger-sec-with-ns irq=44 action=dropped
```

第二次恢复检查也通过：

```text
I/TC: [TEE-IRQ] RESTORE-CHECK test=trigger-sec-with-ns result=OK ...
```

最后 PTA 返回：

```text
I/TC: [TEE-CALL] EXIT command=trigger-sec-with-ns result=0x0
[FLOW] END test=trigger-sec-with-ns result=OK
```

---

### 7.3 该测试证明了什么

该测试证明：

```text
REE 调用 TEE PTA command=3
  ↓
进入 TEE
  ↓
TEE 触发 secure irq45
  ↓
TEE-PLIC claim irq45 sec=1
  ↓
进入 secure irq45 handler
  ↓
handler 内触发 ns irq44
  ↓
secure irq45 handler 没有被 ns44 中途抢占
  ↓
secure irq45 handler 正常结束
  ↓
complete irq45 action=handled
  ↓
restore check OK
  ↓
TEE 再次进入 IRQ
  ↓
claim irq44 sec=0
  ↓
drop irq44
  ↓
complete irq44 action=dropped
  ↓
restore check OK
  ↓
PTA 返回
  ↓
result=OK
```

该测试比单独的 `trigger-ns` 更强，因为它证明了：

```text
TEE secure handler 执行期间，Non-secure interrupt 不会插入执行。
```

---

## 8. 六个测试的覆盖矩阵

| 测试名 | 入口世界 | 首个中断 | 后续中断 | 预期处理者 | 实际结果 | 验证点 |
|---|---|---:|---:|---|---|---|
| `ns42-preempt-sec43` | REE | ns42 | sec43 | REE 先处理 ns42，sec43 由 OpenSBI relay 到 TEE-FIQ 路径 | OK | Secure 中断抢占 REE |
| `ree-trigger-ns44` | REE | ns44 | 无 | REE/Linux | OK | 普通 REE 非安全中断路径 |
| `ree-trigger-sec45` | REE | sec45 | 无 | OpenSBI relay 到 TEE-FIQ 路径 | OK | REE 触发 secure 中断不进 Linux |
| `trigger-ns` | TEE | ns44 | 无 | TEE drop | OK | TEE 不处理 Non-secure 中断 |
| `trigger-sec` | TEE | sec45 | 无 | TEE handler | OK | TEE 正常处理 Secure 中断 |
| `trigger-sec-with-ns` | TEE | sec45 | ns44 | 先 TEE handler，再 drop ns44 | OK | ns 中断不抢占 TEE secure handler |

---

## 9. 当前实现已经证明的设计语义

这 6 个测试综合起来，证明当前实现具备以下行为：

### 9.1 REE 中 Non-secure 中断正常走 Linux

对应 `ree-trigger-ns44`：

```text
REE + sec=0 → REE/Linux claim/handler/eoi
```

---

### 9.2 REE 中 Secure 中断被路由到 TEE

对应 `ree-trigger-sec45`：

```text
REE + sec=1 → OpenSBI claim → TEE-FIQ
```

---

### 9.3 Secure 中断可以抢占 REE

对应 `ns42-preempt-sec43`：

```text
REE 正在处理中断
  ↓
Secure interrupt 到来
  ↓
OpenSBI claim 并切 world_state
  ↓
REE → TEE domain context switch
  ↓
TEE-FIQ 路径返回后恢复 REE
```

---

### 9.4 TEE 中 Secure 中断正常处理

对应 `trigger-sec`：

```text
TEE + sec=1 → TEE handler
```

---

### 9.5 TEE 中 Non-secure 中断不会干扰 TEE

对应 `trigger-ns` 和 `trigger-sec-with-ns`：

```text
TEE + sec=0 → drop + complete
```

并且在 `trigger-sec-with-ns` 中进一步证明：

```text
Non-secure interrupt 不会中途抢占 TEE secure handler
```

---

## 10. 最终总结

这 6 个测试覆盖了 REE/TEE 下安全中断路由的核心场景：

```text
REE 触发 ns → REE 处理
REE 触发 sec → OpenSBI relay 到 TEE-FIQ 路径
REE 处理中被 sec 抢占 → OpenSBI relay 到 TEE-FIQ 路径，再恢复 REE
TEE 触发 ns → TEE drop
TEE 触发 sec → TEE handle
TEE secure handler 中触发 ns → secure handler 先完成，ns 后续 drop
```

从日志看，关键成功信号包括：

```text
result=OK
RESTORE-CHECK result=OK
[SBI-DOM] CHECK ... result=OK
action=handled
action=dropped
switch ws -> 1 before tee
switch ws -> 0 after tee
```

因此可以认为：当前版本已经初步验证了 PLIC 安全属性、OpenSBI relay、REE/TEE 上下文保存恢复、TEE 内安全/非安全中断区分处理这几条关键路径。
