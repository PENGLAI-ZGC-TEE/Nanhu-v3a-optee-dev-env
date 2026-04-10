// SPDX-License-Identifier: BSD-2-Clause
/*
 * Copyright 2022-2023 NXP
 */

#include <console.h>
#include <drivers/plic.h>
#include <kernel/boot.h>
#include <kernel/tee_common_otp.h>
#include <platform_config.h>
#include <sbi.h>

register_ddr(DRAM_BASE, DRAM_SIZE);

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
	static const char msg[] =
		"[optee] vector_fiq_entry reached, secure IRQ handled\r\n";

	/*
	 * Minimal bring-up path:
	 * OpenSBI already claimed/completes the secure IRQ in M-context, so
	 * OP-TEE only prints a marker here and returns through MPXY.
	 */
	for (size_t n = 0; n < sizeof(msg) - 1; n++)
		sbi_dbcn_write_byte(msg[n]);
}
