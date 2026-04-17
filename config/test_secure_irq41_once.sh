#!/bin/sh
set -eu

UART1_BASE=0x00060000

reg()
{
	printf '%u\n' $((UART1_BASE + $1))
}

wr()
{
	devmem "$1" 32 "$2" >/dev/null
}

rd()
{
	devmem "$1" 32
}

echo "[1/6] Disable UART1 interrupts"
wr "$(reg 0x04)" 0x0

echo "[2/6] Enable and clear FIFO"
wr "$(reg 0x08)" 0x7

echo "[3/6] Configure 8N1"
wr "$(reg 0x0c)" 0x3

echo "[4/6] Assert DTR/RTS/OUT2"
wr "$(reg 0x10)" 0xb

echo "[5/6] Read LSR/IIR"
echo "LSR=$(rd "$(reg 0x14)")"
echo "IIR=$(rd "$(reg 0x08)")"

echo "[6/6] Enable THRE interrupt to trigger secure IRQ41"
wr "$(reg 0x04)" 0x2
