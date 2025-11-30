# Initrd Update Mechanism

This document explains how NVIDIA's `l4t_update_initrd.sh` script works and how to create kernel packages with custom kernels.

## Overview

The initrd (initial ramdisk) contains kernel modules needed for early boot. When you build a custom kernel with different modules, you need to regenerate the initrd to include those modules.

## How l4t_update_initrd.sh Works

The script `${LDK_DIR}/tools/l4t_update_initrd.sh`:

1. Copies base initrd from `bootloader/l4t_initrd.img` to `rootfs/boot/initrd`
2. Sets up QEMU chroot environment for ARM64 emulation
3. Runs `nv-update-initrd` inside the chroot
4. Updates `bootloader/l4t_initrd.img` with the result

## Kernel Version Detection

The `nv-update-initrd` script (located at `rootfs/usr/sbin/nv-update-initrd`) determines the kernel version by **inspecting the kernel Image binary**:

```bash
get_kernel_version()
{
    local _image_path=${1}
    _kernel_version="$(strings "${_image_path}" | \
        grep -oE "Linux version [0-9a-zA-Z\.\-]+[+]* " | \
        cut -d\  -f 3 | head -1)"
    echo "${_kernel_version}"
}
```

It reads `/boot/Image` (inside rootfs), runs `strings` on it to find the embedded "Linux version X.Y.Z..." string, and extracts the version number (e.g., `6.17.0-tegra`).

This version is then used to:
- Find modules in `/lib/modules/${version}/`
- Populate the initrd with the correct module set

## Module List Configuration

The list of modules to include in initrd is configured in:
```
rootfs/etc/nv-update-initrd/list.d/
```

Each file in this directory contains paths to files that should be included. The `<KERNEL_VERSION>` placeholder is substituted with the detected kernel version.

## Creating Kernel Packages

Use `scripts/create-kernel-package.sh` to create a deployable kernel package:

```bash
# Source environment
. ${WORKSPACE}/env.sh

# Build kernel and OOT modules
cd ${LDK_DIR}/source
./nvbuild.sh

# Create package
./scripts/create-kernel-package.sh
```

The script:
1. Installs OOT modules via `nvbuild.sh -i`
2. Temporarily replaces stock kernel with custom kernel
3. Runs `l4t_update_initrd.sh` (detects version from custom kernel)
4. Creates tarball with versioned kernel, initrd, DTB, and modules
5. Restores stock kernel (via trap handler for fault tolerance)

### Package Contents

The resulting `${WORKSPACE}/kernel-${KVER}.tar.gz` contains:
- `boot/Image-${KVER}` - Kernel image
- `boot/initrd-${KVER}` - Initrd with custom modules
- `boot/dtb/tegra234-p3737-0000+p3701-0000-nv-${KVER}.dtb` - Device tree
- `lib/modules/${KVER}/` - Kernel modules

### Deploying to Target

```bash
# Copy to target
scp ${WORKSPACE}/kernel-${KVER}.tar.gz root@<target>:/tmp/

# Extract on target
ssh root@<target> 'tar -C / -xzf /tmp/kernel-${KVER}.tar.gz'

# Update extlinux.conf to use new kernel (on target)
# Change LINUX and INITRD paths to use versioned files
```

## Troubleshooting

### "Module version mismatch" on boot
The initrd contains modules for a different kernel version. Re-run `l4t_update_initrd.sh` with the correct kernel in `/boot/Image`.

### initrd update fails in chroot
Ensure `qemu-user-static` is installed:
```bash
sudo apt install qemu-user-static
```

### Modules directory doesn't exist
Modules must be installed to rootfs before updating initrd:
```bash
cd ${LDK_DIR}/source
./nvbuild.sh -i
```
