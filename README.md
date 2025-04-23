# Development environment for building and testing OP-TEE OS on the Nanhu-v3a board

## Download
```
git clone https://github.com/PENGLAI-ZGC-TEE/Nanhu-v3a-optee-dev-env.git
cd Nanhu-v3a-optee-dev-env

git submodule update --init --recursive --progress
```
## Pre-requisites
Please install the packages from the following link: https://wiki.qemu.org/Hosts/Linux

You also need to install cross-compilation tools for RISC-V.
```
sudo apt install g++-riscv64-linux-gnu binutils-riscv64-linux-gnu
```

## Extract RootFS
The rootfs is compressed in a cpio.gz format. You need to extract it before running the build.
```
gunzip ./config/rootfs_nopasswd.cpio.gz
```

## Show help messages
If you want to see the help messages for each command, you can run:
```
make help
```

## Build
Build the QEMU, OP-TEE OS, device tree blob (dtb), Linux kernel, and OpenSBI.
```
make qemu
make optee_os
make dtb
make linux
make opensbi
```

## Run
You can run the QEMU with the following command:
```
make run
```

## Debug
```
make debug

# Then open another terminal
gdb-multiarch --tui /path/to/Nanhu-v3a-optee-dev-env/build/optee_os/core/tee.elf
```
