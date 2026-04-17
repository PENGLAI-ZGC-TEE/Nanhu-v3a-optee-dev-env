#!/bin/sh
set -eu

UART1_BASE=0x00060000
ROUNDS="${1:-5}"

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

trigger_once()
{
	wr "$(reg 0x04)" 0x0
	wr "$(reg 0x08)" 0x7
	wr "$(reg 0x0c)" 0x3
	wr "$(reg 0x10)" 0xb
	rd "$(reg 0x14)" >/dev/null
	rd "$(reg 0x08)" >/dev/null
	wr "$(reg 0x04)" 0x2
}

i=1
while [ "$i" -le "$ROUNDS" ]; do
	echo "round=$i"
	trigger_once
	sleep 1
	i=$((i + 1))
done
