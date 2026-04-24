#!/bin/sh

set -eu

echo "[test] trigger secure IRQ45 and expect NS IRQ44 only after secure complete"
devmem 0x30003000 32 1
