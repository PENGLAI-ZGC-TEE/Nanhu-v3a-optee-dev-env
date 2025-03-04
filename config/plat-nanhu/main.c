// SPDX-License-Identifier: BSD-2-Clause
/*
 * Copyright 2022-2023 NXP
 */

#include <console.h>
#include <drivers/ns16550.h>
#include <drivers/plic.h>
#include <kernel/boot.h>
#include <platform_config.h>

static struct ns16550_data console_data __nex_bss;

register_ddr(DRAM_BASE, DRAM_SIZE);

register_phys_mem(MEM_AREA_IO_NSEC, UART0_BASE, NS16550_UART_REG_SIZE);

void boot_primary_init_intc(void)
{
	plic_init(PLIC_BASE);
}

void boot_secondary_init_intc(void)
{
	plic_hart_init();
}

void plat_console_init(void)
{
	ns16550_init(&console_data, UART0_BASE, IO_WIDTH_U32, 2);
	register_serial_console(&console_data.chip);
}

void interrupt_main_handler(void)
{
	plic_it_handle();
}
