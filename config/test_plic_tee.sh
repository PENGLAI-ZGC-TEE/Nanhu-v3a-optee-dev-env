#!/bin/sh
set -eu

# PLIC base
PLIC_BASE=0x3c000000

# Offsets from PLIC base
SEC_SRC_OFF=0x00010000
WS_OFF=0x00011000

# IRQ40 is in word1 (IRQs 32-63), bit (40-32)=8
SEC_SRC_WORD1=$((PLIC_BASE + SEC_SRC_OFF + 4))
WS_CTX0=$((PLIC_BASE + WS_OFF + 0))
WS_CTX1=$((PLIC_BASE + WS_OFF + 4))

echo "[1/4] Mark IRQ40 as secure (sec_src bit8 in word1)"
devmem $SEC_SRC_WORD1 32 0x00000100
echo "sec_src[1] = $(devmem $SEC_SRC_WORD1 32)"

echo "[2/4] Set world_state ctx0/ctx1 to 0 (non-secure world)"
devmem $WS_CTX0 32 0x0
devmem $WS_CTX1 32 0x0
echo "ws[ctx0] = $(devmem $WS_CTX0 32), ws[ctx1] = $(devmem $WS_CTX1 32)"
echo "Expect plic-tee claim/complete with mode=M, sec=1, ws=0 in guest_log.txt"

sleep 1

echo "[3/4] Set world_state ctx0/ctx1 to 1 (secure world)"
devmem $WS_CTX0 32 0x1
devmem $WS_CTX1 32 0x1
echo "ws[ctx0] = $(devmem $WS_CTX0 32), ws[ctx1] = $(devmem $WS_CTX1 32)"
echo "Expect plic-tee claim/complete with mode=S, sec=1, ws=1 in guest_log.txt"

sleep 1

echo "[4/4] Restore sec_src to non-secure and world_state to 0"
devmem $SEC_SRC_WORD1 32 0x00000000
devmem $WS_CTX0 32 0x0
devmem $WS_CTX1 32 0x0
echo "Done."
