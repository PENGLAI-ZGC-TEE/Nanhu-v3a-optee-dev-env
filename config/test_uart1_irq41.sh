#!/bin/sh
set -eu

UART1_BASE=0x00060000

# ns16550a with reg-shift = 2, so each register is 4 bytes apart
UART_THR_RBR=0x00
UART_IER=0x04
UART_IIR_FCR=0x08
UART_LCR=0x0c
UART_MCR=0x10
UART_LSR=0x14

rd()
{
	devmem "$1" 32
}

wr()
{
	devmem "$1" 32 "$2" >/dev/null
}

reg()
{
	printf '%u\n' $((UART1_BASE + $1))
}

echo "[1/6] Disable all UART1 interrupts"
wr "$(reg $UART_IER)" 0x0

echo "[2/6] Enable and clear FIFO"
wr "$(reg $UART_IIR_FCR)" 0x7

echo "[3/6] Configure UART1 as 8N1"
wr "$(reg $UART_LCR)" 0x3

echo "[4/6] Assert DTR/RTS/OUT2 in MCR"
wr "$(reg $UART_MCR)" 0xb

echo "[5/6] Read current LSR/IIR for reference"
echo "LSR=$(rd "$(reg $UART_LSR)")"
echo "IIR=$(rd "$(reg $UART_IIR_FCR)")"

echo "[6/6] Enable THRE interrupt on UART1 to trigger IRQ41"
wr "$(reg $UART_IER)" 0x2

echo "UART1 IRQ41 trigger programmed."
echo "Expected secure-IRQ path:"
echo "  plic-sec -> OP-TEE vector_fiq_entry -> COMPLETE func=0xbe000006"
