# ---------- config ----------
# PLIC base (from DT / dmesg)
set $PLIC_BASE = 0x3c000000

# PLIC offsets (SiFive-style)
set $PLIC_PRIORITY_BASE = 0x000000
set $PLIC_PENDING_BASE  = 0x001000
set $PLIC_ENABLE_BASE   = 0x002000
set $PLIC_CTX_BASE      = 0x200000

# Contexts (M=0, S=1 in our setup)
set $PLIC_CTX_M = 0
set $PLIC_CTX_S = 1

# Our custom CSR for world state (fill this)
# Example: set $WS_CSR_NUM = 0x7c0
#set $WS_CSR_NUM = 0x000

# ---------- helpers ----------
define p_regs
  echo \n== M-mode CSRs ==\n
  p/x $mstatus
  p/x $mepc
  p/x $mcause
  p/x $mtval
  p/x $mtvec
  p/x $mie
  p/x $mip

  echo \n== S-mode CSRs ==\n
  p/x $sstatus
  p/x $sepc
  p/x $scause
  p/x $stval
  p/x $stvec
  p/x $sie
  p/x $sip
  p/x $satp

  echo \n== Custom WS CSR ==\n
  # If your GDB supports CSR by number, try:
  # p/x $csr$WS_CSR_NUM
  # Otherwise use monitor (QEMU):
  # monitor info registers
end

define p_plic_ctx_m
  set $ctx = $PLIC_CTX_M
  echo \n== PLIC M Context ==\n
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx * 0x1000) + 0x000
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx * 0x1000) + 0x004
end

define p_plic_ctx_s
  set $ctx = $PLIC_CTX_S
  echo \n== PLIC S Context ==\n
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx * 0x1000) + 0x000
  x/wx $PLIC_BASE + $PLIC_CTX_BASE + ($ctx * 0x1000) + 0x004
end

define p_plic_basic
  echo \n== PLIC pending/enable/priority (IRQ41) ==\n
  # pending bitset (IRQ41 in pending word)
  x/wx $PLIC_BASE + $PLIC_PENDING_BASE + 0x000
  # enable set for M and S context (word 1 covers IRQ32-63)
  x/wx $PLIC_BASE + $PLIC_ENABLE_BASE + ($PLIC_CTX_M * 0x80) + 0x04
  x/wx $PLIC_BASE + $PLIC_ENABLE_BASE + ($PLIC_CTX_S * 0x80) + 0x04
  # priority for IRQ41
  x/wx $PLIC_BASE + $PLIC_PRIORITY_BASE + (41 * 4)
end

define p_all
  p_regs
  p_plic_basic
  p_plic_ctx_m
  p_plic_ctx_s
end

# Automatically print regs+plic when stopped
define hook-stop
  p_all
end

# ---------- breakpoints ----------
# OpenSBI trap entry & handler
b _trap_handler
b sbi_trap_handler

# IRQ dispatch
b sbi_irqchip_process
b plic_irqfn
b plic_secure_irqfn

# PLIC ops
b plic_claim
b plic_complete

# Domain context switch
b sbi_domain_context_set_mepc
b sbi_domain_context_enter
b switch_to_next_domain_context

# OP-TEE FIQ path
b vector_fiq_entry
b interrupt_main_handler
b thread_return_to_udomain

# OP-TEE return -> OpenSBI complete
b fdt_plic_secure_irq_complete


