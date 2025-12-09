# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GPU virtualization research project for NVIDIA Jetson AGX Orin (Tegra 234) using pKVM (protected KVM). The goal is to enable GPU pass-through to guest VMs by moving the entire host1x subsystem and GPU hardware to a protected guest VM while keeping the host minimal.

**Working Directory:** `${WORKSPACE}` (set via `env.sh`)

**Branch:** `tegra/pkvm-mainline-6.18-smmu-claude` - pKVM SMMUv2 development branch (kernel 6.18)

**Platform:**
- Device: NVIDIA Jetson AGX Orin (Tegra 234 SoC)
- Architecture: ARM64 (aarch64)
- Base: NVIDIA Jetson Linux (L4T) BSP 36.4.3
- Target Kernel: Linux 6.18 (pKVM mainline with SMMUv2 support)

**Important:** Kernel 6.18 requires upstream `CONFIG_TEGRA_HOST1X` to be disabled in favor of NVIDIA's OOT host1x driver due to extended APIs needed by nvdisplay. This is configured in the defconfig.

## Known Issues and Troubleshooting

**IMPORTANT**: If working on boot problems or "missing IOMMU stream ID" issues, see:
- **[`docs/boot_problems.md`](docs/boot_problems.md)** - Detailed investigation log of attempted solutions and failures

This document tracks all attempted fixes, why they failed, and outstanding questions. Read it FIRST before attempting new solutions to avoid repeating failed approaches.

## Environment Setup

### Required Environment Variables

All build commands require these environment variables (provided by `env.sh`):
- `LDK_DIR`: Points to `${WORKSPACE}/Linux_for_Tegra`
- `WORKSPACE`: Root directory for the project (set in `env.sh`)
- `CROSS_COMPILE`: Cross-compiler for kernel builds
- `CROSS_COMPILE_AARCH64_PATH`: Path for OP-TEE/ATF builds
- `ARCH=arm64`: Target architecture
- `LOCALVERSION=-tegra`: Kernel version suffix (gives `6.18.0-tegra`, suppresses dirty `+`)

### For Claude Code (Automatic)

**All environment variables are automatically set** via a SessionStart hook in `.claude/settings.local.json`. No manual sourcing required - just run build commands directly.

To set up a fresh clone for Claude Code, run:
```bash
./scripts/claude-setup.sh
```

### For Users (Manual)

Source the environment before working:
```bash
. /path/to/pkvm/env.sh
```

## Build Commands

### Primary Kernel Build

**IMPORTANT: New In-Tree Build System**

Kernel sources are now built in-tree at `${LDK_DIR}/source/kernel/linux`. **Do NOT use nvbuild.sh for kernel builds.**

```bash
cd ${LDK_DIR}/source/kernel/linux

# Build kernel (ARCH and LOCALVERSION are set by env.sh)
make -j$(nproc)

# Build specific targets
make defconfig          # Generate .config from defconfig
make Image              # Build kernel image
make dtbs               # Build device tree blobs
make modules            # Build modules

# Clean
make clean
```

**Note:** The kernel version will be `6.18.0-tegra` (no dirty `+` suffix).

**Out-of-tree modules** (nvgpu, nvidia-oot, etc.) still use nvbuild.sh:
```bash
cd ${LDK_DIR}/source
./nvbuild.sh -m           # Build only OOT modules (skip kernel)
./nvbuild.sh -i           # Install modules to rootfs
```

### Automated Testing Workflow

**NEW: Autopilot System** - Automated kernel upload and boot testing on NVIDIA Orin AGX

The autopilot system uses a directory-based request queue for reliable, non-blocking operation.

After building a new kernel:

```bash
# 1. Build kernel
cd ${LDK_DIR}/source/kernel/linux
make -j$(nproc)

# 2. Submit test request (creates a timestamped request file)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
touch ${WORKSPACE}/autopilot/requests/pending/${TIMESTAMP}.request

# 3. Wait for completion (~5 minutes)
# The autopilot service watches for .request files and processes them automatically
# System uploads arch/arm64/boot/Image to device and boots it

# 4. Optional: Wait for completion programmatically
while [ ! -f ${WORKSPACE}/autopilot/requests/completed/${TIMESTAMP}.request ]; do
  sleep 5
done
echo "Test completed!"
```

**Request Status Tracking:**
- **requests/pending/**: Submitted requests waiting to be processed
- **requests/processing/**: Request currently being tested (only one at a time)
- **requests/completed/**: Successfully completed requests
- **requests/failed/**: Failed requests (check autopilot logs for errors)

**Results appear in** `${WORKSPACE}/autopilot/results/$TIMESTAMP/`:
- **panic.log**: Kernel panic details (if crash occurred)
- **hyp.log**: EL2 hypervisor debug output (HYP_INFO/HYP_ERR/etc.)
- **disassembly.log**: Disassembly of function where crash occurred
- **kernel.log**: Complete kernel boot log
- **kernel-update.log**: Log from kernel upload phase
- **uarti.log**: Raw UART output from hypervisor

**Example workflow:**
```bash
# Make a fix to SMMUv2 driver
cd ${LDK_DIR}/source/kernel/linux
vim drivers/iommu/arm/arm-smmu/pkvm/arm-smmu-v2.c

# Build and test
make -j$(nproc)
TIMESTAMP=$(date +%Y%m%d%H%M%S)
touch ${WORKSPACE}/autopilot/requests/pending/${TIMESTAMP}.request

# Check status
ls -la ${WORKSPACE}/autopilot/requests/*/

# View results (after ~5 minutes when file appears in completed/)
cat ${WORKSPACE}/autopilot/results/${TIMESTAMP}/panic.log
cat ${WORKSPACE}/autopilot/results/${TIMESTAMP}/hyp.log
```

**Advantages of directory-based queue:**
- ✅ No blocking or hanging issues
- ✅ Can queue multiple requests
- ✅ Easy to check status with `ls`
- ✅ Atomic file operations (no race conditions)
- ✅ Failed requests preserved for debugging

**Comprehensive Autopilot Documentation:**

For detailed information about how the autopilot system works, see:
- **[Autopilot Overview](autopilot/docs/overview.md)** - Quick start and system overview
- **[Boot Sequence](autopilot/docs/boot-sequence.md)** - How boot menu and update cycle works
- **[Architecture](autopilot/docs/architecture.md)** - Technical implementation details
- **[Extending DTB Support](autopilot/docs/extending-dtb-support.md)** - How to add device tree upload capability

### Manual Flashing (Not Recommended - Use Autopilot Instead)

Flash complete system:
```bash
cd ${LDK_DIR}
sudo ./flash.sh jetson-agx-orin-devkit internal
```

Flash specific partition (e.g., after OP-TEE/ATF rebuild):
```bash
sudo ./flash.sh -k A_secure-os jetson-agx-orin-devkit internal
```

### Update Initramfs (required after kernel changes)

```bash
cd ${LDK_DIR}
sudo ./tools/l4t_update_initrd.sh
cp ${LDK_DIR}/rootfs/boot/Image ${LDK_DIR}/kernel  # Use for recovery image
```

### Secure World Software

**See**: [`docs/secure_world.md`](docs/secure_world.md) for complete OP-TEE and ATF build instructions.

**Quick reference** - Flash secure OS partition after rebuild:
```bash
cd ${LDK_DIR}
sudo ./flash.sh -k A_secure-os jetson-agx-orin-devkit internal
```

## Architecture

**See**: [`docs/design.md`](docs/design.md) for GPU virtualization strategy and dual rootfs architecture.

**Quick reference** - Install modules to specific rootfs:
```bash
# Install to guest VM rootfs
rm -f ${LDK_DIR}/rootfs && ln -sf rootfs-gpuvm ${LDK_DIR}/rootfs
cd ${LDK_DIR}/source && ./nvbuild.sh -i

# Install to host rootfs
rm -f ${LDK_DIR}/rootfs && ln -sf rootfs-host ${LDK_DIR}/rootfs
cd ${LDK_DIR}/source && ./nvbuild.sh -i
```

### Directory Structure

Key directories in this repository:
- **Linux_for_Tegra/**: NVIDIA L4T BSP root
  - **source/**: Kernel and module sources (see `Linux_for_Tegra/source/CLAUDE.md` for details)
    - `kernel/linux/`: **Primary kernel source** (android15-6.6.66_r00) - **IN-TREE BUILD**
    - `kernel/kernel-jammy-src/`: NVIDIA's Ubuntu 5.15.148 kernel
    - `kernel/linux2/`: Alternative vanilla kernel tree
    - `nvgpu/`: NVIDIA GPU driver (out-of-tree)
    - `nvidia-oot/`: Platform drivers, network drivers
    - `nvdisplay/`: Display driver
    - `hwpm/`: Hardware Performance Monitor
    - `tegra/optee-src/`: OP-TEE and ATF sources
  - **bootloader/**: UEFI firmware and bootloader binaries
  - **tools/**: L4T utilities including `l4t_update_initrd.sh`
  - **rootfs-host/**: Host OS root filesystem
  - **rootfs-gpuvm/**: Guest VM root filesystem
  - **nv_tegra/**: TOS (Trusted OS) scripts
- **autopilot/**: Automated testing infrastructure
  - `requests/pending/`: Submit test requests here (create `$TIMESTAMP.request` files)
  - `requests/processing/`: Currently running test
  - `requests/completed/`: Successfully completed tests
  - `requests/failed/`: Failed test requests
  - `results/$TIMESTAMP/`: Results directory for each test run
- **docs/**: Project documentation
- **toolchain/**: Cross-compilation toolchain

### Key Configuration Files

- `Linux_for_Tegra/source/kernel_src_build_env.sh`: Controls which kernel source and defconfig to use
  - `KERNEL_SRC_DIR`: "linux" (android15-6.6.66_r00) or "kernel-jammy-src" (5.15.148)
  - `KERNEL_DEF_CONFIG`: "defconfig" or custom config
  - `OOT_SOURCE_LIST`: Order-dependent list of out-of-tree modules

### Module Build Order

Critical dependency chain:
1. **hwpm** (Hardware Performance Monitor)
2. **nvidia-oot** (depends on hwpm)
3. **nvgpu** (depends on nvidia-oot)
4. **nvdisplay** (depends on nvidia-oot)

Each module exports symbols via `Module.symvers` consumed by subsequent modules.

## Analysis Tools

Python tools in `${WORKSPACE}/gpuvm/`:
- **analyze.py**: IOMMU stream analyzer that processes device tree blobs (DTB) to identify which devices must move to guest VM based on host1x dependencies

Usage:
```bash
cd ${WORKSPACE}/gpuvm
python analyze.py  # Analyzes nv.dtb for host1x device relationships
```

## Switching Kernel Sources

**Current Setup:** In-tree builds at `Linux_for_Tegra/source/kernel/linux` (android15-6.6.66_r00)

To use a different kernel source tree:

1. Check out new kernel in `${LDK_DIR}/source/kernel/<new_dir>`
2. Update symlink or change directory in build commands
3. Ensure defconfig exists in `arch/arm64/configs/`

**For Android common kernel**, you may need to fix out-of-tree driver compatibility:
```bash
# Fix Ethernet driver build for non-5.15 kernels
sed -i -e 's/^.*5\.15.*$/ifeq (1,1)/' ${LDK_DIR}/source/nvidia-oot/drivers/net/ethernet/Makefile
```

**Rebuild:**
```bash
cd ${LDK_DIR}/source/kernel/linux  # or your kernel directory
make -j$(nproc)
```

## Device Tree Modifications

Device tree sources are in `Linux_for_Tegra/source/hardware/nvidia/t23x/nv-public/` and compiled as part of `./nvbuild.sh`. For manual compilation:
```bash
cd ${LDK_DIR}/source
make dtbs
```

**CRITICAL: You MUST use the DTB from nvbuild.sh (or equivalent `make dtbs` from the source tree).**

The NVIDIA OOT `host1x.ko` driver requires device tree properties that are **only present** in DTBs built from the NVIDIA hardware sources:

| Property | Purpose | Location in DT sources |
|----------|---------|------------------------|
| `nvidia,syncpoint-shim` | Reference to syncpoint shim memory region | `tegra234-soc-overlay.dtsi` |
| `syncpoint_shim` node at `0x60000000` | Syncpoint shim base address for DMA synchronization | `tegra234-soc-overlay.dtsi` |

**Without these properties**, `host1x_syncpt_get_shim_info()` returns `-ENODEV`, causing nvdla, pva, vi5, and nvgpu ACR to fail with errors like:
```
nvdla_sync_device_create_syncpoint: failed to get syncpt shim info. err=-19
```

**DTB location after build:**
```
${LDK_DIR}/source/kernel_out/kernel-devicetree/generic-dts/dtbs/tegra234-p3737-0000+p3701-0000-nv.dtb
```

**Note:** DTBs from upstream/mainline kernel trees (e.g., `arch/arm64/boot/dts/nvidia/`) do NOT include these NVIDIA-specific properties and will cause host1x client driver failures.

## Common Workflows

### After Kernel Code Changes (Use Autopilot!)

**Recommended workflow:**
```bash
# 1. Build kernel
cd ${LDK_DIR}/source/kernel/linux
make -j$(nproc)

# 2. Submit test request to autopilot
TIMESTAMP=$(date +%Y%m%d%H%M%S)
touch ${WORKSPACE}/autopilot/requests/pending/${TIMESTAMP}.request

# 3. Wait for completion (~5 minutes), then check results
cat ${WORKSPACE}/autopilot/results/${TIMESTAMP}/panic.log
cat ${WORKSPACE}/autopilot/results/${TIMESTAMP}/hyp.log
```

**Legacy manual workflow (not recommended):**
```bash
cd ${LDK_DIR}/source/kernel/linux
make -j$(nproc)             # Build kernel
cd ${LDK_DIR}/source
./nvbuild.sh -m                        # Build OOT modules
rm -f rootfs && ln -sf rootfs-host rootfs
./nvbuild.sh -i                        # Install to host
rm -f rootfs && ln -sf rootfs-gpuvm rootfs
./nvbuild.sh -i                        # Install to guest
cd ${LDK_DIR}
sudo ./tools/l4t_update_initrd.sh      # Update initramfs
cp rootfs/boot/Image kernel/           # Update recovery kernel
sudo ./flash.sh jetson-agx-orin-devkit internal
```

### After OP-TEE or ATF Changes
```bash
# Rebuild as shown above, generate tos.img, then:
cd ${LDK_DIR}
sudo ./flash.sh -k A_secure-os jetson-agx-orin-devkit internal
```

### Test Single Out-of-Tree Module
```bash
cd ${LDK_DIR}/source
make nvgpu                             # Build just nvgpu
./nvbuild.sh -i                        # Install all modules
```

### Full Kernel Update with SSH Deployment

**When to use this workflow:**
- Switching to a different kernel version
- Major kernel config changes requiring module rebuild
- When OOT modules (nvgpu, nvidia-oot) need rebuilding against new kernel
- Deploying to a target running a working Linux (no recovery mode needed)

This workflow uses `nvbuild.sh` to build everything (kernel + modules), creates a tarball with all required files, and deploys via SSH to a running target.

#### Step 1: Build Complete Kernel and Modules

```bash
# Build kernel + OOT modules using nvbuild.sh
cd ${LDK_DIR}/source
./nvbuild.sh                # Build kernel and all OOT modules

# Install modules to rootfs (choose appropriate rootfs)
rm -f ${LDK_DIR}/rootfs && ln -sf rootfs-host ${LDK_DIR}/rootfs
./nvbuild.sh -i             # Install to rootfs
```

**Note:** `nvbuild.sh` (without `-m`) builds the kernel from `source/kernel/${KERNEL_SRC_DIR}/` and all OOT modules. The `-m` flag skips kernel build and only builds OOT modules.

#### Step 2: Update Initramfs

The initramfs must be regenerated whenever kernel modules change:

```bash
cd ${LDK_DIR}
sudo ./tools/l4t_update_initrd.sh
```

This runs inside a QEMU chroot to regenerate `/boot/initrd` with the new modules.

#### Step 3: Detect Kernel Version and Create Deployment Tarball

The kernel version (including localversion suffix) is stored in the build output:

```bash
cd ${LDK_DIR}

# Get exact kernel version from build output
KVER=$(cat source/kernel_out/kernel/linux/include/config/kernel.release)
echo "Kernel version: ${KVER}"

# Verify modules exist in rootfs
ls -la rootfs/lib/modules/${KVER}/
```

Create the deployment tarball:

```bash
cd ${LDK_DIR}/rootfs

# Create tarball with versioned kernel and initrd names
# --transform renames boot/Image -> boot/Image-${KVER}, etc.
sudo tar -cvf /tmp/kernel-update.tar \
    --transform="s|boot/Image|boot/Image-${KVER}|" \
    --transform="s|boot/initrd|boot/initrd-${KVER}|" \
    boot/Image \
    boot/initrd \
    lib/modules/${KVER}/

# Optional: Include device trees if they changed
sudo tar -rvf /tmp/kernel-update.tar \
    boot/*.dtb \
    boot/*.dtbo

# Compress (recommended - reduces ~60MB to ~20MB)
gzip -f /tmp/kernel-update.tar
ls -lh /tmp/kernel-update.tar.gz
```

**Tarball contents:**
- `boot/Image-${KVER}` - Kernel image (~40MB)
- `boot/initrd-${KVER}` - Initramfs with modules (~17MB)
- `lib/modules/${KVER}/` - Kernel modules
- `boot/*.dtb` (optional) - Device tree blobs

**Note:** After deployment, update `/boot/extlinux/extlinux.conf` on the target to point to the new versioned kernel.

#### Step 4: Deploy to Target via SSH

With the target running a working Linux and accessible via SSH:

```bash
# Set target IP
TARGET_IP=192.168.101.112
TARGET_USER=root

# Method 1: Stream tarball directly (no intermediate file on target)
cat /tmp/kernel-update.tar.gz | ssh ${TARGET_USER}@${TARGET_IP} \
    "gunzip | tar -C / -xpf - && sync"

# Method 2: Copy then extract (safer, allows verification)
scp /tmp/kernel-update.tar.gz ${TARGET_USER}@${TARGET_IP}:/tmp/
ssh ${TARGET_USER}@${TARGET_IP} "tar -C / -xzpf /tmp/kernel-update.tar.gz && sync && rm /tmp/kernel-update.tar.gz"

# Reboot target to use new kernel
ssh ${TARGET_USER}@${TARGET_IP} "reboot"
```

**Alternative: Use rsync for incremental updates:**
```bash
# Sync only changed files (faster for small changes)
rsync -avz --progress ${LDK_DIR}/rootfs/boot/Image ${TARGET_USER}@${TARGET_IP}:/boot/
rsync -avz --progress ${LDK_DIR}/rootfs/boot/initrd ${TARGET_USER}@${TARGET_IP}:/boot/
rsync -avz --progress ${LDK_DIR}/rootfs/lib/modules/${KVER}/ \
    ${TARGET_USER}@${TARGET_IP}:/lib/modules/${KVER}/
ssh ${TARGET_USER}@${TARGET_IP} "sync && reboot"
```

#### Complete Script

```bash
#!/bin/bash
# full-kernel-deploy.sh - Build and deploy complete kernel update
# Usage: ./full-kernel-deploy.sh [TARGET_IP] [TARGET_USER]
set -e

TARGET_IP=${1:-192.168.1.100}
TARGET_USER=${2:-root}

export WORKSPACE=/home/hlyytine/pkvm
. ${WORKSPACE}/env.sh
cd ${LDK_DIR}

echo "=== Building kernel and modules ==="
cd source && ./nvbuild.sh

echo "=== Installing to rootfs ==="
rm -f ${LDK_DIR}/rootfs && ln -sf rootfs-host ${LDK_DIR}/rootfs
./nvbuild.sh -i

echo "=== Updating initramfs ==="
cd ${LDK_DIR}
sudo ./tools/l4t_update_initrd.sh

echo "=== Creating tarball ==="
KVER=$(cat source/kernel_out/kernel/linux/include/config/kernel.release)
echo "Kernel version: ${KVER}"

cd ${LDK_DIR}/rootfs
sudo tar -cvpzf /tmp/kernel-update.tar.gz \
    --transform="s|boot/Image|boot/Image-${KVER}|" \
    --transform="s|boot/initrd|boot/initrd-${KVER}|" \
    boot/Image boot/initrd lib/modules/${KVER}/
ls -lh /tmp/kernel-update.tar.gz

echo "=== Deploying to ${TARGET_IP} ==="
cat /tmp/kernel-update.tar.gz | ssh ${TARGET_USER}@${TARGET_IP} \
    "gunzip | tar -C / -xpf - && sync"

echo "=== Done! Update extlinux.conf on target to boot Image-${KVER} ==="
```

#### Troubleshooting

**"Module version mismatch" on boot:**
- Initramfs contains old modules. Re-run `l4t_update_initrd.sh`.

**Modules directory doesn't exist in rootfs:**
- Check `KVER` matches what's installed: `ls ${LDK_DIR}/rootfs/lib/modules/`
- Re-run `./nvbuild.sh -i` to install modules.

**Target won't boot after update:**
- Boot into recovery/alternate kernel if available
- Or re-flash via USB recovery mode: `sudo ./flash.sh jetson-agx-orin-devkit internal`

**SSH connection refused after reboot:**
- Target may have network issues with new kernel
- Use serial console or recovery mode

**Tarball too large:**
- Exclude debug symbols: add `--exclude='*.debug'` to tar command
- Build with `CONFIG_DEBUG_INFO=n` in kernel config

## Git Workflow

Current branch: `gpuvm`

Recent development focus:
- IOMMU stream analysis tooling
- Build system refinement for Android common kernel
- Secure world software integration (OP-TEE + ATF)
- Dual rootfs management

## Dependencies

Build dependencies (Ubuntu 24.04.1 LTS):
```bash
sudo apt update
sudo apt install python3-pycryptodome python3-pyelftools device-tree-compiler
```

For analysis tools:
```bash
pip install jinja2 libfdt
```

## Important Notes

- **Always source env.sh** before building or flashing
- **Symlink management** for rootfs is critical - wrong symlink installs to wrong filesystem
- **Build order matters** - out-of-tree modules have strict dependency chain
- **Recovery kernel** must be copied to `kernel/Image` after rootfs installation
- Flashing requires **sudo** and direct connection to Jetson device in recovery mode

### Kernel 6.18 Compatibility

**See**: [`docs/kernel_617_compat.md`](docs/kernel_617_compat.md) for detailed compatibility notes (applies to 6.17+).

**Key points:**
- `CONFIG_TEGRA_HOST1X=n` (prevents symbol conflicts with NVIDIA's OOT host1x)
- DRM API changes require conditional compilation in nvdisplay
- Ethernet driver Makefile needs adjustment for non-5.15 kernels

## pKVM SMMUv2 Support for Tegra234

**Comprehensive documentation has been moved to a dedicated file.**

**See**: [`docs/smmuv2_pkvm.md`](docs/smmuv2_pkvm.md)

This document contains:
- Implementation status and hardware testing results
- Known issues and solutions (Issues 1-5)
- MC-based Stream ID management architecture
- Crosvm VMM integration details
- Testing procedures and validation criteria

**Quick Summary**:
- **Goal**: Enable GPU passthrough to protected guest VMs with DMA isolation
- **Implementation**: 3,222 lines total (2,699 EL2 + 523 EL1) - **COMPLETE**
- **Status**: ✅ **HARDWARE VALIDATED** (2025-12-04) - DMA isolation working with GPU workloads (Ollama/TinyLlama), USFCFG=1 enforced

**Milestone Achievement (2025-12-04)**:
- GPU actively used for LLM inference while pKVM SMMUv2 driver controls all SMMU instances
- USFCFG=1 enabled - unknown/unconfigured Stream IDs fault on DMA (security enforced)
- All DMA operations correctly translated through hypervisor-controlled SMMU
- Guest VMs now protected from host CPU and DMA-capable devices

**Also See**:
- `Linux_for_Tegra/source/kernel/linux/drivers/iommu/arm/arm-smmu/CLAUDE.md` - Driver implementation details

## UART and Debug Output

This project uses UART at physical address `0x31d0000` (UARTI) for debug output from both EL1 (kernel) and EL2 (hypervisor). The **enhanced pKVM serial framework** provides comprehensive printf-style debugging for all EL2 code.

**Quick Facts**:
- **Hardware**: ARM PL011 UART at 0x31d0000 (UARTI)
- **Baud Rate**: 115200 bps
- **Framework**: Enhanced pKVM serial framework with printf support (production-ready)
- **Coexistence**: Both EL1 and EL2 can safely use the same UART

**Major Enhancement (2025-01)**:
- ✅ Added `hyp_printf()` with comprehensive format support (%s, %x, %lx, %llx, %d, %zu, %p, etc.)
- ✅ Added convenience macros: `HYP_INFO()`, `HYP_ERR()`, `HYP_WARN()`, `HYP_DBG()`
- ✅ Early UART initialization support (before module loading)
- ✅ Proper EL2 VA mapping via `__pkvm_create_private_mapping()` (fixes data aborts)
- ❌ Deleted custom `hyp-uart.h` (350 lines removed - framework provides all functionality)

**See**: [`docs/uart.md`](docs/uart.md) for comprehensive documentation on:
- Enhanced pKVM serial framework API and usage
- Early initialization examples (SMMU driver style)
- Format specifier reference and convenience macros
- Migration guide from hyp-uart.h (now deleted)
- Device tree configuration and hardware details
- Usage examples, troubleshooting, and performance considerations

**Quick Usage Examples**:

```c
// Enhanced pKVM serial framework (production-ready with printf!)
#include <nvhe/serial.h>

// Basic output
hyp_puts("Message from EL2");
hyp_putx64(value);

// NEW: Printf-style output with convenience macros
HYP_INFO("SMMU initialized at PA 0x%llx", base_addr);
HYP_ERR("Error code: %d", ret);
HYP_DBG("Mapping IOVA 0x%llx -> PA 0x%llx (size=%zu)", iova, paddr, size);

// NEW: Custom formatting
hyp_printf("Custom message: %s value=0x%llx\n", str, val);
```

## Related Documentation

- [`docs/design.md`](docs/design.md): GPU virtualization architecture and dual rootfs setup
- [`docs/secure_world.md`](docs/secure_world.md): OP-TEE and ATF build instructions
- [`docs/kernel_617_compat.md`](docs/kernel_617_compat.md): Kernel 6.17+ compatibility notes
- [`docs/smmuv2_pkvm.md`](docs/smmuv2_pkvm.md): pKVM SMMUv2 implementation details
- [`docs/uart.md`](docs/uart.md): UART debug output configuration
- [`docs/boot_problems.md`](docs/boot_problems.md): Boot troubleshooting guide
- [`README.md`](README.md): Original setup and build instructions for 5.15.148 kernel
- `Linux_for_Tegra/source/CLAUDE.md`: Detailed source tree documentation, build system internals
- `Linux_for_Tegra/source/crosvm/README.md`: Crosvm build and development instructions
- `Linux_for_Tegra/source/kernel/linux/drivers/iommu/arm/arm-smmu/CLAUDE.md`: Comprehensive pKVM SMMUv2 documentation

## Quick Reference

**Build kernel:**
```bash
cd ${LDK_DIR}/source/kernel/linux
make -j$(nproc)
```

**Test on hardware:**
```bash
TIMESTAMP=$(date +%Y%m%d%H%M%S)
touch ${WORKSPACE}/autopilot/requests/pending/${TIMESTAMP}.request
# Wait ~5 minutes
cat ${WORKSPACE}/autopilot/results/${TIMESTAMP}/panic.log
cat ${WORKSPACE}/autopilot/results/${TIMESTAMP}/hyp.log
```

**Build OOT modules:**
```bash
cd ${LDK_DIR}/source
./nvbuild.sh -m  # Build only modules
./nvbuild.sh -i  # Install to rootfs
```

## Notes

- Every time you make a new hypothesis, a fix attempt or get a test result, make sure they are documented!
