# Secure World Software Build Guide

This document covers building OP-TEE and ARM Trusted Firmware (ATF) for the Tegra234 platform.

## Prerequisites

Ensure the environment is set up:
```bash
export WORKSPACE=/home/hlyytine/pkvm
. ${WORKSPACE}/env.sh
```

## Build OP-TEE

```bash
export UEFI_STMM_PATH=${LDK_DIR}/bootloader/standalonemm_optee_t234.bin
cd ${LDK_DIR}/source/tegra/optee-src/nv-optee
./optee_src_build.sh -p t234
dtc -I dts -O dtb -o optee/tegra234-optee.dtb optee/tegra234-optee.dts
```

## Build ATF (ARM Trusted Firmware)

```bash
cd ${LDK_DIR}/source/tegra/optee-src/atf
export NV_TARGET_BOARD=generic
./nvbuild.sh
```

## Generate TOS Partition Image

After building both OP-TEE and ATF, generate the combined TOS (Trusted OS) image:

```bash
cd ${LDK_DIR}/nv_tegra/tos-scripts
./gen_tos_part_img.py \
    --monitor ${LDK_DIR}/source/tegra/optee-src/atf/arm-trusted-firmware/generic-t234/tegra/t234/release/bl31.bin \
    --os ${LDK_DIR}/source/tegra/optee-src/nv-optee/optee/build/t234/core/tee-raw.bin \
    --dtb ${LDK_DIR}/source/tegra/optee-src/nv-optee/optee/tegra234-optee.dtb \
    --tostype optee \
    tos.img
cp tos.img ${LDK_DIR}/bootloader/tos-optee_t234.img
```

## Flash Secure OS Partition

To flash only the secure OS partition (without full system flash):

```bash
cd ${LDK_DIR}
sudo ./flash.sh -k A_secure-os jetson-agx-orin-devkit internal
```

## Source Locations

- **OP-TEE**: `${LDK_DIR}/source/tegra/optee-src/nv-optee/`
- **ATF**: `${LDK_DIR}/source/tegra/optee-src/atf/`
- **TOS Scripts**: `${LDK_DIR}/nv_tegra/tos-scripts/`

## Output Files

| Component | Output Location |
|-----------|-----------------|
| BL31 (ATF) | `source/tegra/optee-src/atf/arm-trusted-firmware/generic-t234/tegra/t234/release/bl31.bin` |
| TEE Core | `source/tegra/optee-src/nv-optee/optee/build/t234/core/tee-raw.bin` |
| OP-TEE DTB | `source/tegra/optee-src/nv-optee/optee/tegra234-optee.dtb` |
| TOS Image | `bootloader/tos-optee_t234.img` |
