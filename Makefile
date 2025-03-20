# Environment Variables
CURRENT_DIR := $(shell pwd)
BUILD_DIR := $(CURRENT_DIR)/build
CONFIG_DIR := $(CURRENT_DIR)/config
NPROC := $(shell nproc)
CROSS_COMPILE := riscv64-linux-gnu-
NHART := 2

# Qemu Variables
qemu_srcdir := $(CURRENT_DIR)/qemu
qemu_builddir := $(BUILD_DIR)/qemu
qemu_target := $(qemu_builddir)/qemu-system-riscv64
qemu_config_args := --target-list=riscv64-softmmu
qemu_machine := -machine bosc-nh
qemu_args := -smp $(NHART) -m 2G

# Linux Variables
linux_srcdir := $(CURRENT_DIR)/linux
linux_builddir := $(BUILD_DIR)/linux
linux_config := $(CONFIG_DIR)/xiangshan.config
linux_vmlinux := $(linux_builddir)/vmlinux
linux_image := $(linux_builddir)/arch/riscv/boot/Image

# FDT Variables
dts_file := $(CONFIG_DIR)/nanhu-v3a.dts
dtb_file := $(BUILD_DIR)/nanhu-v3a.dtb

# OP-TEE Variables
optee_os_srcdir := $(CURRENT_DIR)/optee_os
optee_os_builddir := $(BUILD_DIR)/optee_os
optee_os_platdir := $(CONFIG_DIR)/plat-nanhu
optee_os_bin := $(optee_os_builddir)/core/tee.bin
optee_os_elf := $(optee_os_builddir)/core/tee.elf
optee_os_tddram_start := 0x80200000
optee_os_tddram_size := 0x01000000

# OpenSBI Variables
opensbi_srcdir := $(CURRENT_DIR)/opensbi
opensbi_builddir := $(BUILD_DIR)/opensbi
opensbi_bindir := $(opensbi_builddir)/platform/generic/firmware
opensbi_payload_bin := $(opensbi_bindir)/fw_payload.bin
opensbi_payload_elf := $(opensbi_bindir)/fw_payload.elf

###########
# qemu
###########
.PHONY: qemu
qemu: $(qemu_builddir)/config-host.mak
	$(MAKE) -C $(qemu_builddir) O=$(qemu_builddir) -j $(NPROC)

$(qemu_builddir)/config-host.mak:
	mkdir -p $(dir $@)
	cd $(qemu_builddir) && \
	$(qemu_srcdir)/configure $(qemu_config_args)

###########
# linux
###########
.PHONY: linux
linux: $(linux_builddir)/.config
	$(MAKE) -C $(linux_srcdir) O=$(linux_builddir) -j $(NPROC) \
	ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE) \

$(linux_builddir)/.config: $(linux_config)
	mkdir -p $(dir $@)
	cp -f $(linux_config) $(linux_srcdir)/arch/riscv/configs/
	$(MAKE) -C $(linux_srcdir) O=$(linux_builddir) -j $(NPROC) \
	ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE) defconfig xiangshan.config
	rm -f $(linux_srcdir)/arch/riscv/configs/xiangshan.config

###########
# FDT
###########
.PHONY: dtb
dtb:
	dtc -I dts -O dtb -o $(dtb_file) $(dts_file)

###########
# OT-TEE
###########
.PHONY: optee_os
optee_os:
	mkdir -p $(optee_os_builddir)
	cp -rf $(optee_os_platdir) $(optee_os_srcdir)/core/arch/riscv/
	$(MAKE) -C $(optee_os_srcdir) O=$(optee_os_builddir) -j $(NPROC) \
	ARCH=riscv PLATFORM=nanhu \
	CFG_TEE_CORE_NB_CORE=$(NHART) CFG_NUM_THREADS=$(NHART)
	rm -rf $(optee_os_srcdir)/core/arch/riscv/plat-nanhu

###########
# opensbi
###########
.PHONY: opensbi
opensbi:
	mkdir -p $(opensbi_builddir)
	$(MAKE) -C $(opensbi_srcdir) O=$(opensbi_builddir) -j $(NPROC) \
	CROSS_COMPILE=$(CROSS_COMPILE) \
	PLATFORM=generic \
	FW_PAYLOAD_PATH=$(linux_image) \
	FW_TEXT_START=0x80000000 \
	FW_FDT_PATH=$(dtb_file) \
	FW_JUMP_FDT_OFFSET=0x200000 \
	FW_PAYLOAD_OFFSET=0x400000

##########
# clean
##########
.PHONY: qemu-clean qemu-distclean linux-clean linux-distclean dtb-clean optee_os-clean
qemu-clean:
	$(MAKE) -C $(qemu_builddir) clean

qemu-distclean:
	rm -rf $(qemu_builddir)

linux-clean:
	$(MAKE) -C $(linux_builddir) clean

linux-distclean:
	$(MAKE) -C $(linux_srcdir) distclean
	rm -rf $(linux_builddir)

dtb-clean:
	rm -f $(dtb_file)

optee_os-clean:
	rm -rf $(optee_os_builddir)
	rm -rf $(optee_os_srcdir)/core/arch/riscv/plat-nanhu
