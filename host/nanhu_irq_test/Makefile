# SPDX-License-Identifier: BSD-2-Clause

CROSS_COMPILE ?= riscv64-linux-gnu-
CC := $(CROSS_COMPILE)gcc
O ?= ../../build/host/nanhu_irq_test
TARGET := $(O)/nanhu_irq_test
ROOTFS ?= ../../rootfs

CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra -Werror
LDFLAGS ?= -L$(ROOTFS)/usr/lib -Wl,-rpath-link,$(ROOTFS)/usr/lib -lteec

.PHONY: all install clean

all: $(TARGET)

$(O):
	mkdir -p $@

$(TARGET): nanhu_irq_test.c tee_client_api.h | $(O)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: $(TARGET)
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(TARGET) $(DESTDIR)/usr/bin/nanhu_irq_test

clean:
	rm -f $(TARGET)
