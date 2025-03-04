/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Copyright 2022-2023 NXP
 *
 * Brief   Xiangshan Nanhu-v3a platform configuration.
 */

#ifndef PLATFORM_CONFIG_H
#define PLATFORM_CONFIG_H

#include <riscv.h>
#include <mm/generic_ram_layout.h>

/* The stack pointer is always kept 16-byte aligned */
#define STACK_ALIGNMENT		16

/* DRAM */
#ifndef DRAM_BASE
#define DRAM_BASE		0x80000000
#define DRAM_SIZE		0x80000000
#endif

/* CLINT */
#ifndef CLINT_BASE
#define CLINT_BASE		0x38000000
#endif

/* PLIC */
#ifndef PLIC_BASE
#define PLIC_BASE		0x3c000000
#define PLIC_REG_SIZE		0x4000000
#define PLIC_NUM_SOURCES	128
#endif

/* UART0 */
#ifndef UART0_BASE
#define UART0_BASE		0x50000
#endif
#define UART0_IRQ		68

#define PLAT_THREAD_EXCP_FOREIGN_INTR	(0)
#define PLAT_THREAD_EXCP_NATIVE_INTR	(CSR_XIE_EIE | CSR_XIE_TIE | CSR_XIE_SIE)

#endif /*PLATFORM_CONFIG_H*/
