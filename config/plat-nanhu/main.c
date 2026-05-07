// SPDX-License-Identifier: BSD-2-Clause
/*
 * Copyright 2022-2023 NXP
 */

#include <console.h>
#include <drivers/plic.h>
#include <io.h>
#include <kernel/boot.h>
#include <kernel/delay.h>
#include <kernel/interrupt.h>
#include <kernel/panic.h>
#include <kernel/tee_common_otp.h>
#include <mm/core_memprot.h>
#include <platform_config.h>
#include <sbi.h>
#include <trace.h>

register_ddr(DRAM_BASE, DRAM_SIZE);
register_phys_mem_pgdir(MEM_AREA_IO_SEC, NANHU_IRQGEN_NS2_BASE,
			2 * NANHU_IRQGEN_REG_SIZE);

#define NANHU_NS_TEST_IRQ 44
#define NANHU_SEC_TEST_IRQ 45

static bool trigger_ns_in_secure_handler __nex_bss;

void nanhu_irq_test_set_trigger_ns_in_secure_handler(bool enable)
{
	trigger_ns_in_secure_handler = enable;
}

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

static struct itr_handler nanhu_sec_irq_hdl =
	ITR_HANDLER(NULL, NANHU_SEC_TEST_IRQ, 0, nanhu_secure_irq_handler, NULL);

static void nanhu_secure_irq_test_init(void)
{
	struct itr_chip *chip = interrupt_get_main_chip();
	TEE_Result res = TEE_SUCCESS;

	nanhu_sec_irq_hdl.chip = chip;
	res = interrupt_add_configure_handler(&nanhu_sec_irq_hdl,
					      IRQ_TYPE_NONE, 1);
	if (res)
		panic("failed to register Nanhu secure IRQ handler");

	interrupt_enable(chip, NANHU_NS_TEST_IRQ);
	interrupt_enable(chip, NANHU_SEC_TEST_IRQ);
	IMSG("[optee-test] secure irq45 handler registered");
	IMSG("[optee-test] non-secure irq44 drop path enabled");
}

#ifdef CFG_RISCV_PLIC
void boot_primary_init_intc(void)
{
	plic_init(PLIC_BASE);
	nanhu_secure_irq_test_init();
}

void boot_secondary_init_intc(void)
{
	plic_hart_init();
}
#endif /* CFG_RISCV_PLIC */

void interrupt_main_handler(void)
{
	if (IS_ENABLED(CFG_RISCV_PLIC))
		plic_it_handle();
}
