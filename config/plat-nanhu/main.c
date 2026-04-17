// SPDX-License-Identifier: BSD-2-Clause
/*
 * Copyright 2022-2023 NXP
 */

#include <console.h>
#include <drivers/plic.h>
#include <kernel/boot.h>
#include <kernel/delay.h>
#include <kernel/tee_common_otp.h>
#include <platform_config.h>
#include <sbi.h>

register_ddr(DRAM_BASE, DRAM_SIZE);

#define NANHU_SECIRQ_BUSY_MS 200

#ifdef CFG_RISCV_PLIC
void boot_primary_init_intc(void)
{
	plic_init(PLIC_BASE);
}

void boot_secondary_init_intc(void)
{
	plic_hart_init();
}
#endif /* CFG_RISCV_PLIC */

void interrupt_main_handler(void)
{
	static const char msg_begin[] =
		"[optee] vector_fiq_entry begin, secure IRQ handled\r\n";
	static const char msg_end[] =
		"[optee] vector_fiq_entry end\r\n";

	/*
	 * Minimal bring-up path:
	 * OpenSBI already claimed/completes the secure IRQ in M-context, so
	 * OP-TEE only prints markers here and returns through MPXY.
	 * Keep a short busy-wait window so we can test that non-secure IRQs
	 * do not preempt secure interrupt handling in S-mode OP-TEE.
	 */
	for (size_t n = 0; n < sizeof(msg_begin) - 1; n++)
		sbi_dbcn_write_byte(msg_begin[n]);

	if (NANHU_SECIRQ_BUSY_MS)
		mdelay(NANHU_SECIRQ_BUSY_MS);

	for (size_t n = 0; n < sizeof(msg_end) - 1; n++)
		sbi_dbcn_write_byte(msg_end[n]);
}
