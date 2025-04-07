# Environment Variables
CURRENT_DIR := $(shell pwd)
BUILD_DIR := $(CURRENT_DIR)/build
CONFIG_DIR := $(CURRENT_DIR)/config
NPROC := $(shell nproc)
CROSS_COMPILE ?= riscv64-linux-gnu-

# Qemu Variables
qemu_srcdir := $(CURRENT_DIR)/qemu
qemu_builddir := $(BUILD_DIR)/qemu
qemu_target := $(qemu_builddir)/qemu-system-riscv64
qemu_config_args := --target-list=riscv64-softmmu
qemu_machine := -machine bosc-nanhu
qemu_args := -cpu bosc-nanhu -smp 2 -m 8G

# Linux Variables
linux_srcdir := $(CURRENT_DIR)/linux
linux_builddir := $(BUILD_DIR)/linux
linux_config := $(CONFIG_DIR)/xiangshan.config
linux_vmlinux := $(linux_builddir)/vmlinux
linux_image := $(linux_builddir)/arch/riscv/boot/Image
linux_start := 0x82000000

# Rootfs Variables
rootfs_srcdir := $(CURRENT_DIR)/rootfs
rootfs_target := $(CONFIG_DIR)/rootfs_nopasswd.cpio

# Device Tree Variables
dts_file := $(CONFIG_DIR)/nanhu-v3a.dts
dtb_file := $(BUILD_DIR)/nanhu-v3a.dtb

# OP-TEE Variables
optee_os_srcdir := $(CURRENT_DIR)/optee_os
optee_os_builddir := $(BUILD_DIR)/optee_os
optee_os_platdir := $(CONFIG_DIR)/plat-nanhu/
optee_os_bin := $(optee_os_builddir)/core/tee.bin
optee_os_elf := $(optee_os_builddir)/core/tee.elf
optee_os_tddram_start := 0x81000000
optee_os_tddram_size := 0x1000000

# OpenSBI Variables
opensbi_srcdir := $(CURRENT_DIR)/opensbi
opensbi_builddir := $(BUILD_DIR)/opensbi
opensbi_bindir := $(opensbi_builddir)/platform/generic/firmware
opensbi_jump_bin := $(opensbi_bindir)/fw_jump.bin
opensbi_jump_elf := $(opensbi_bindir)/fw_jump.elf
opensbi_start := 0x80000000

###########
# help
###########
.PHONY: all help
all: help

help:
	@echo "Makefile for developing and testing the OP-TEE OS on BOSC Xiangshan Nanhu-v3a platform"
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  help             Display help messages"
	@echo "  qemu             Build QEMU"
	@echo "  linux            Build Linux kernel"
	@echo "  optee_os         Build OP-TEE OS"
	@echo "  opensbi          Build OpenSBI"
	@echo "  dtb              Generate Device Tree Blob (DTB)"
	@echo "  rootfs-extract   Extract root filesystem from cpio archive"
	@echo "  rootfs-pack      Pack root filesystem into cpio archive"
	@echo "  run              Run QEMU with the built images"
	@echo "  debug            Run QEMU with debugging enabled"
	@echo "  qemu-clean       Clean QEMU build directory"
	@echo "  qemu-distclean   Clean QEMU build directory and remove all generated files"
	@echo "  linux-clean      Clean Linux kernel build directory"
	@echo "  linux-distclean  Clean Linux kernel build directory and remove all generated files"
	@echo "  optee_os-clean   Clean OP-TEE OS build directory"
	@echo "  dtb-clean        Clean generated Device Tree Blob (DTB)"
	@echo "  opensbi-clean    Clean OpenSBI build directory"

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
# rootfs
###########
.PHONY: rootfs-extract rootfs-pack
rootfs-extract: $(rootfs_target)
	rm -rf $(rootfs_srcdir)
	mkdir -p $(rootfs_srcdir)
	fakeroot sh -c 'cd $(rootfs_srcdir) && cpio -imdv < $(rootfs_target)'

rootfs-pack: $(rootfs_srcdir)
	rm -rf $(rootfs_target)
	fakeroot sh -c 'cd $(rootfs_srcdir) && find . | cpio -o -H newc > $(rootfs_target)'

###########
# linux
###########
.PHONY: linux
linux: $(linux_builddir)/.config $(rootfs_target)
	cp -f $(rootfs_target) $(linux_srcdir)/
	$(MAKE) -C $(linux_srcdir) O=$(linux_builddir) -j $(NPROC) \
	ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE)
	rm -f $(linux_srcdir)/rootfs_nopasswd.cpio

$(linux_builddir)/.config:
	mkdir -p $(dir $@)
	cp -f $(linux_config) $(linux_srcdir)/arch/riscv/configs/
	$(MAKE) -C $(linux_srcdir) O=$(linux_builddir) -j $(NPROC) \
	ARCH=riscv CROSS_COMPILE=$(CROSS_COMPILE) defconfig xiangshan.config
	rm -f $(linux_srcdir)/arch/riscv/configs/xiangshan.config

###########
# DTB
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
	ARCH=riscv PLATFORM=nanhu
	rm -rf $(optee_os_srcdir)/core/arch/riscv/plat-nanhu

###########
# opensbi
###########
.PHONY: opensbi
opensbi: $(dtb_file)
	mkdir -p $(opensbi_builddir)
	$(MAKE) -C $(opensbi_srcdir) O=$(opensbi_builddir) -j $(NPROC) \
	CROSS_COMPILE=$(CROSS_COMPILE) \
	PLATFORM=generic \
	FW_TEXT_START=$(opensbi_start) \
	FW_FDT_PATH=$(dtb_file) \
	FW_JUMP_ADDR=$(linux_start)

##########
# run
##########
.PHONY: run
run: $(opensbi_jump_bin) $(optee_os_bin) $(linux_image)
	$(qemu_target) $(qemu_machine) $(qemu_args) \
	-d guest_errors -D guest_log.txt \
	-bios $(opensbi_jump_bin) \
	-device loader,file=$(optee_os_bin),addr=$(optee_os_tddram_start) \
	-device loader,file=$(linux_image),addr=$(linux_start) \
	-nographic

##########
# debug
##########
.PHONY: debug
debug: $(opensbi_jump_bin) $(optee_os_bin) $(linux_image)
	$(qemu_target) $(qemu_machine) $(qemu_args) \
	-d guest_errors -D guest_log.txt \
	-bios $(opensbi_jump_elf) \
	-device loader,file=$(optee_os_bin),addr=$(optee_os_tddram_start) \
	-device loader,file=$(linux_image),addr=$(linux_start) \
	-nographic \
	-s -S

###########
# clean
###########
.PHONY: qemu-clean qemu-distclean linux-clean linux-distclean optee_os-clean dtb-clean opensbi-clean
qemu-clean:
	$(MAKE) -C $(qemu_builddir) clean

qemu-distclean:
	rm -rf $(qemu_builddir)

linux-clean:
	$(MAKE) -C $(linux_builddir) clean

linux-distclean:
	rm -rf $(linux_builddir)

optee_os-clean:
	rm -rf $(optee_os_builddir)
	rm -rf $(optee_os_srcdir)/core/arch/riscv/plat-nanhu

dtb-clean:
	rm -f $(dtb_file)

opensbi-clean:
	rm -rf $(opensbi_builddir)
