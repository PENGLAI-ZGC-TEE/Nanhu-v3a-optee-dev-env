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

# Linux Variables
linux_srcdir := $(CURRENT_DIR)/linux
linux_builddir := $(BUILD_DIR)/linux
linux_config := $(CONFIG_DIR)/xiangshan.config
linux_vmlinux := $(linux_builddir)/vmlinux
linux_image := $(linux_builddir)/arch/riscv/boot/Image

# Rootfs Variables
rootfs_srcdir := $(CURRENT_DIR)/rootfs
rootfs_target := $(CONFIG_DIR)/rootfs_nopasswd.cpio

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
# clean
###########
.PHONY: qemu-clean qemu-distclean linux-clean linux-distclean
qemu-clean:
	$(MAKE) -C $(qemu_builddir) clean

qemu-distclean:
	rm -rf $(qemu_builddir)

linux-clean:
	$(MAKE) -C $(linux_builddir) clean

linux-distclean:
	rm -rf $(linux_builddir)
