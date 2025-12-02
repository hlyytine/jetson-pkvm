# Secure World Software Build Guide

This document covers building OP-TEE and ARM Trusted Firmware (ATF) for the Tegra234 platform.

## pKVM Requirements

**CRITICAL:** For pKVM, you **MUST** rebuild ATF before initial flashing!

The vanilla NVIDIA ATF does not preserve all CPU registers when entering sleep states. This causes pKVM hypervisor crashes during CPU suspend/resume cycles because:

1. The hypervisor runs at EL2 and maintains critical state in EL2 registers
2. When a CPU enters sleep, ATF (BL31) handles the power state transition at EL3
3. Vanilla ATF only saves/restores registers needed for normal EL1 Linux operation
4. pKVM requires additional EL2 state to be preserved across sleep cycles

The `tiiuae/atf-nvidia-jetson` fork includes the necessary register preservation patches for pKVM compatibility.

## Prerequisites

Ensure the environment is set up:
```bash
export WORKSPACE=/home/hlyytine/pkvm
. ${WORKSPACE}/env.sh
```

## Quick Build (Recommended)

Use the automated build script:

```bash
./scripts/build-atf.sh
```

This builds OP-TEE, ATF, and generates the TOS partition image.

## Manual Build Steps

### Build OP-TEE

```bash
export UEFI_STMM_PATH=${LDK_DIR}/bootloader/standalonemm_optee_t234.bin
cd ${LDK_DIR}/source/tegra/optee-src/nv-optee
./optee_src_build.sh -p t234
dtc -I dts -O dtb -o optee/tegra234-optee.dtb optee/tegra234-optee.dts
```

### Build ATF (ARM Trusted Firmware)

For pKVM, use the tiiuae fork with CPU suspend fixes:

```bash
cd ${LDK_DIR}/source/tegra/optee-src/atf
export NV_TARGET_BOARD=generic
./nvbuild.sh
```

### Generate TOS Partition Image

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

## Flashing Secure OS Partition

The Jetson uses A/B boot slots for redundancy. Both slots should have the same TOS image for consistency.

### Flash Single Slot

```bash
cd ${LDK_DIR}
# Flash A slot (primary)
sudo ./flash.sh -k A_secure-os jetson-agx-orin-devkit internal

# Flash B slot (backup)
sudo ./flash.sh -k B_secure-os jetson-agx-orin-devkit internal
```

### Flash Both Slots (Recommended)

For initial setup or major updates, flash both slots:

```bash
cd ${LDK_DIR}
sudo ./flash.sh -k A_secure-os jetson-agx-orin-devkit internal
sudo ./flash.sh -k B_secure-os jetson-agx-orin-devkit internal
```

### Full System Flash

When doing a full system flash, the TOS image is included automatically:

```bash
cd ${LDK_DIR}
sudo ./flash.sh -C kvm-arm.mode=protected jetson-agx-orin-devkit internal
```

This uses `${LDK_DIR}/bootloader/tos-optee_t234.img` which must be the rebuilt version.

## Initial pKVM Setup Checklist

Before initial flashing with pKVM enabled:

1. **Clone pKVM-compatible ATF:**
   ```bash
   cd ${LDK_DIR}/source/tegra/optee-src
   mv atf atf.orig  # backup vanilla ATF if present
   git clone -b l4t/l4t-r36.4.4-pkvm2 https://github.com/tiiuae/atf-nvidia-jetson.git atf
   ```

2. **Build ATF and OP-TEE:**
   ```bash
   ./scripts/build-atf.sh
   ```

3. **Verify TOS image is updated:**
   ```bash
   ls -la ${LDK_DIR}/bootloader/tos-optee_t234.img
   # Should show recent timestamp
   ```

4. **Flash full system:**
   ```bash
   cd ${LDK_DIR}
   sudo ./flash.sh -C kvm-arm.mode=protected jetson-agx-orin-devkit internal
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

## Troubleshooting

### CPU crashes during suspend with pKVM

**Symptom:** System crashes when CPUs enter idle/sleep states with pKVM enabled.

**Cause:** Vanilla ATF doesn't preserve EL2 hypervisor state during PSCI suspend.

**Solution:** Use the tiiuae ATF fork with proper register preservation:
```bash
cd ${LDK_DIR}/source/tegra/optee-src
rm -rf atf
git clone -b l4t/l4t-r36.4.4-pkvm2 https://github.com/tiiuae/atf-nvidia-jetson.git atf
./scripts/build-atf.sh
# Then flash both slots - see "Flashing Secure OS Partition" above
```

### TOS image not updated after rebuild

**Symptom:** Changes to ATF or OP-TEE don't take effect after flashing.

**Check:** Verify the TOS image timestamp matches your build:
```bash
ls -la ${LDK_DIR}/bootloader/tos-optee_t234.img
```

**Solution:** The `gen_tos_part_img.py` script must copy output to bootloader directory:
```bash
cp ${LDK_DIR}/nv_tegra/tos-scripts/tos.img ${LDK_DIR}/bootloader/tos-optee_t234.img
```
