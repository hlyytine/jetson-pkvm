#!/bin/bash
# Create kernel package (.tar.gz) with custom kernel, initrd, DTB, and modules
#
# Usage: ./scripts/create-kernel-package.sh
#
# Requires: WORKSPACE and LDK_DIR set (source env.sh first)
# Input: Kernel built with nvbuild.sh (output at kernel_out/kernel/linux/)
# Output: ${WORKSPACE}/kernel-${KVER}.tar.gz

set -e

if [ -z "${WORKSPACE}" ] || [ -z "${LDK_DIR}" ]; then
    echo "ERROR: WORKSPACE and LDK_DIR must be set. Source env.sh first." >&2
    exit 1
fi

# nvbuild.sh output paths (out-of-tree build)
KERNEL_OUT="${LDK_DIR}/source/kernel_out/kernel/linux"
CUSTOM_IMAGE="${KERNEL_OUT}/arch/arm64/boot/Image"
DTB_OUT="${LDK_DIR}/source/kernel_out/kernel-devicetree/generic-dts/dtbs"
DTB_NAME="tegra234-p3737-0000+p3701-0000-nv.dtb"
ROOTFS="${LDK_DIR}/rootfs"

if [ ! -f "${CUSTOM_IMAGE}" ]; then
    echo "ERROR: Kernel not built. Run './nvbuild.sh' in ${LDK_DIR}/source first." >&2
    exit 1
fi

if [ ! -f "${DTB_OUT}/${DTB_NAME}" ]; then
    echo "ERROR: DTB not found at ${DTB_OUT}/${DTB_NAME}" >&2
    exit 1
fi

# Cleanup handler - restore stock kernel on exit (success or failure)
cleanup() {
    if [ -f "${ROOTFS}/boot/Image.stock" ]; then
        echo "Restoring stock kernel..."
        mv "${ROOTFS}/boot/Image.stock" "${ROOTFS}/boot/Image"
    fi
}
trap cleanup EXIT

# Get kernel version from build
KVER=$(cat ${KERNEL_OUT}/include/config/kernel.release)
echo "Kernel version: ${KVER}"

# Install OOT modules to rootfs
echo "Installing OOT modules..."
cd ${LDK_DIR}/source
./nvbuild.sh -i

# Backup stock kernel
echo "Backing up stock kernel..."
cp "${ROOTFS}/boot/Image" "${ROOTFS}/boot/Image.stock"

# Install custom kernel temporarily
echo "Installing custom kernel temporarily..."
cp "${CUSTOM_IMAGE}" "${ROOTFS}/boot/Image"

# Update initrd (will detect version from custom kernel)
echo "Updating initrd..."
cd ${LDK_DIR}
sudo ./tools/l4t_update_initrd.sh

# Copy DTB to rootfs with versioned name
echo "Copying DTB..."
mkdir -p "${ROOTFS}/boot/dtb"
cp "${DTB_OUT}/${DTB_NAME}" "${ROOTFS}/boot/dtb/${DTB_NAME%.dtb}-${KVER}.dtb"

# Create package
echo "Creating package..."
cd ${ROOTFS}
sudo tar -cvzf ${WORKSPACE}/kernel-${KVER}.tar.gz \
    --transform="s|boot/Image|boot/Image-${KVER}|" \
    --transform="s|boot/initrd|boot/initrd-${KVER}|" \
    boot/Image \
    boot/initrd \
    boot/dtb/${DTB_NAME%.dtb}-${KVER}.dtb \
    lib/modules/${KVER}/

# Cleanup runs automatically via trap

echo ""
echo "Package created: ${WORKSPACE}/kernel-${KVER}.tar.gz"
echo ""
echo "To deploy to target:"
echo "  scp ${WORKSPACE}/kernel-${KVER}.tar.gz root@<target>:/tmp/"
echo "  ssh root@<target> 'tar -C / -xzf /tmp/kernel-${KVER}.tar.gz'"
