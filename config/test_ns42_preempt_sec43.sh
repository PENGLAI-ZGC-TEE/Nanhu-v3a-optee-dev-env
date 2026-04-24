#!/bin/sh
set -eu

NS_IRQGEN_BASE=0x30000000

wr()
{
	devmem "$1" 32 "$2" >/dev/null
}

echo "[1/1] Trigger non-secure IRQ42 from REE"
wr "$NS_IRQGEN_BASE" 1

echo "Expected serial log order:"
echo "  [ree] irq42 begin ..."
echo "  plic-sec: ... irq=43 ..."
echo "  [optee] vector_fiq_entry begin/end"
echo "  [ree] irq42 end ..."
