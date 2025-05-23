# Development environment for building and testing OP-TEE OS on the Nanhu-v3a board

## Download
```
git clone https://github.com/PENGLAI-ZGC-TEE/Nanhu-v3a-optee-dev-env.git
cd Nanhu-v3a-optee-dev-env

git submodule update --init --recursive --progress
```

## Extract RootFS
```
gunzip ./config/rootfs_nopasswd.cpio.gz
```

## Show help messages
```
make help
```

## Build for jump pattern (jump to optee)
```
make qemu
make optee_os
make dtb
make linux
make opensbi-jump # jump to optee or linux
```

## Build for payload pattern (add just linux for payload)
```
make qemu
make optee_os
make dtb
make linux
make opensbi-payload # just opensbi + linux
```

## Build for fpga pattern (merge opensbi + optee + linux as a bin)
```
make qemu
make optee_os
make dtb
make linux
make opensbi-jump
make merge
```

## Run
```
make run-jump # run qemu for jump pattern
make run-payload # run qemu for payload pattern
make run-fpga # run qemu for fpga pattern
```

## Debug
```
make debug

# Then open another terminal
gdb-multiarch --tui /path/to/Nanhu-v3a-optee-dev-env/build/optee_os/core/tee.elf
```
