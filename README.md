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

## Build
```
make qemu
make optee_os
make dtb
make linux
make opensbi
```

## Run
```
make run
```

## Debug
```
make debug

# Then open another terminal
gdb-multiarch --tui /path/to/Nanhu-v3a-optee-dev-env/build/optee_os/core/tee.elf
```
