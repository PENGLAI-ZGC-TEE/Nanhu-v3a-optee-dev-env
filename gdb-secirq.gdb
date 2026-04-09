# ============================================================
# GDB 脚本：阶段化调试 IRQ / OP-TEE 流程
# ============================================================

# ------------------- 阶段 0: 初始化 ------------------------
set pagination off
set print pretty on

# ------------------- 一键连接 QEMU / 加载符号表 ----------------
target remote :1234
file /home/zhanggy2025/Nanhu-v3a-optee-dev-env/build/opensbi/platform/generic/firmware/fw_jump.elf
add-symbol-file /home/zhanggy2025/Nanhu-v3a-optee-dev-env/build/optee_os/core/tee.elf 0x81000000
add-symbol-file /home/zhanggy2025/Nanhu-v3a-optee-dev-env/build/linux/vmlinux 0x82000000

# ------------------- PLIC 基址 ------------------------
set $PLIC_BASE = 0x3c000000
set $PLIC_PRIORITY_BASE = 0x000000
set $PLIC_PENDING_BASE  = 0x001000
set $PLIC_ENABLE_BASE   = 0x002000
set $PLIC_CTX_BASE      = 0x200000
set $PLIC_CTX_M = 0
set $PLIC_CTX_S = 1

# ------------------- 辅助打印函数 ------------------------
define p_regs
  echo "\n== M-mode CSRs ==\n"
  printf "mstatus=0x%x mepc=0x%x mcause=0x%x mtval=0x%x\n", $mstatus, $mepc, $mcause, $mtval
  printf "mtvec=0x%x mie=0x%x mip=0x%x\n", $mtvec, $mie, $mip
  echo "\n== S-mode CSRs ==\n"
  printf "sstatus=0x%x sepc=0x%x scause=0x%x stval=0x%x\n", $sstatus, $sepc, $scause, $stval
  printf "stvec=0x%x sie=0x%x sip=0x%x satp=0x%x\n", $stvec, $sie, $sip, $satp
end

define p_gpregs
  echo "\n== GPRs ==\n"
  printf "x0=0x%x ra=0x%x sp=0x%x gp=0x%x tp=0x%x\n", $x0, $x1, $x2, $x3, $x4
  printf "t0=0x%x t1=0x%x t2=0x%x s0=0x%x s1=0x%x\n", $x5, $x6, $x7, $x8, $x9
  printf "a0=0x%x a1=0x%x a2=0x%x a3=0x%x a4=0x%x a5=0x%x a6=0x%x a7=0x%x\n", $x10,$x11,$x12,$x13,$x14,$x15,$x16,$x17
  printf "s2=0x%x s3=0x%x s4=0x%x s5=0x%x s6=0x%x s7=0x%x\n", $x18,$x19,$x20,$x21,$x22,$x23
  printf "s8=0x%x s9=0x%x s10=0x%x s11=0x%x t3=0x%x t4=0x%x t5=0x%x t6=0x%x\n", $x24,$x25,$x26,$x27,$x28,$x29,$x30,$x31
end

define p_plic_basic
  echo "\n== PLIC pending/enable/priority (IRQ41) ==\n"
  x/wx $PLIC_BASE + $PLIC_PENDING_BASE + 0x000
  x/wx $PLIC_BASE + $PLIC_ENABLE_BASE + ($PLIC_CTX_M*0x80)+0x04
  x/wx $PLIC_BASE + $PLIC_ENABLE_BASE + ($PLIC_CTX_S*0x80)+0x04
  x/wx $PLIC_BASE + $PLIC_PRIORITY_BASE + (41*4)
end

define p_plic_ctx_m
  set $ctx = $PLIC_CTX_M
  echo "\n== PLIC M Context ==\n"
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx*0x1000) + 0x000
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx*0x1000) + 0x004
end

define p_plic_ctx_s
  set $ctx = $PLIC_CTX_S
  echo "\n== PLIC S Context ==\n"
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx*0x1000) + 0x000
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx*0x1000) + 0x004
end

define p_all
  p_regs
  p_gpregs
  if $mepc >= 0x81000000
    p_plic_basic
    p_plic_ctx_m
    p_plic_ctx_s
  end
end

define hook-stop
  p_all
end

# ============================================================
# 阶段化断点
# ============================================================

/*------------------- 阶段 1: M-mode trap 入口 ------------------------
reak _trap_handler
commands
  printf "== [Stage 1] _trap_handler ENTRY ==\n"
  p_all
  delete 1      # 删除本断点，防止再次触发
  continue
end

# ------------------- 阶段 2: SBI trap 分发 ------------------------
break sbi_trap_handler
commands
  printf "== [Stage 2] sbi_trap_handler ==\n"
  p_all
  delete 2      # 删除本断点
  continue
end 
*

# ------------------- 阶段 3: Domain context 切换 ------------------------
break switch_to_next_domain_context
commands
  printf "== [Stage 3] switch_to_next_domain_context ==\n"
  p_all
  continue
end

break sbi_domain_context_enter
commands
  printf "== [Stage 3.1] sbi_domain_context_enter ==\n"
  p_all
  continue
end

# ------------------- 阶段 4: OP-TEE FIQ 入口 ------------------------
break vector_fiq_entry
commands
  printf "== [Stage 4] OP-TEE FIQ ENTRY ==\n"
  p_all
  continue
end

break interrupt_main_handler
commands
  printf "== [Stage 4.1] OP-TEE interrupt_main_handler ==\n"
  p_all
  continue
end

# ------------------- 阶段 5: OP-TEE 返回 ------------------------
break thread_return_to_udomain
commands
  printf "== [Stage 5] OP-TEE RETURN ==\n"
  p_all
  continue
end

# ------------------- 阶段 6: OpenSBI 完成 IRQ ------------------------
break fdt_plic_secure_irq_complete
commands
  printf "== [Stage 6] PLIC COMPLETE ==\n"
  p_all
  continue
end

# ------------------- 阶段 7: 返回 Linux ------------------------
break sbi_trap_handler if $mepc >= 0x81000000
commands
  printf "== [Stage 7] RETURN TO LINUX ==\n"
  p_all
  continue
end

# ============================================================
echo "========================\n"
echo "GDB 阶段化 IRQ/OP-TEE 调试脚本已加载。\n"
echo "hook-stop 自动打印寄存器/PLIC状态。\n"
echo "请使用 'c' 继续执行。\n"
echo "========================\n"