#!/bin/bash
# Build ARM Trusted Firmware (ATF) and generate TOS partition image
#
# Usage: ./scripts/build-atf.sh
#
# Requires: WORKSPACE and LDK_DIR set (source env.sh first)
#
# IMPORTANT: For pKVM, you MUST rebuild ATF before initial flashing!
# The vanilla NVIDIA ATF does not preserve all CPU registers when entering
# sleep states, which causes pKVM hypervisor crashes during CPU suspend/resume.
# The tiiuae/atf-nvidia-jetson fork includes the necessary register preservation.
#
# See docs/secure_world.md for flashing instructions.

set -e

if [ -z "${WORKSPACE}" ] || [ -z "${LDK_DIR}" ]; then
    echo "ERROR: WORKSPACE and LDK_DIR must be set. Source env.sh first." >&2
    exit 1
fi

# Paths
ATF_DIR="${LDK_DIR}/source/tegra/optee-src/atf"
OPTEE_DIR="${LDK_DIR}/source/tegra/optee-src/nv-optee"
TOS_SCRIPTS="${LDK_DIR}/nv_tegra/tos-scripts"

# Output paths
BL31_BIN="${ATF_DIR}/arm-trusted-firmware/generic-t234/tegra/t234/release/bl31.bin"
TEE_BIN="${OPTEE_DIR}/optee/build/t234/core/tee-raw.bin"
OPTEE_DTB="${OPTEE_DIR}/optee/tegra234-optee.dtb"
TOS_IMG="${LDK_DIR}/bootloader/tos-optee_t234.img"

# Verify sources exist
if [ ! -d "${ATF_DIR}" ]; then
    echo "ERROR: ATF source not found at ${ATF_DIR}" >&2
    exit 1
fi

if [ ! -d "${OPTEE_DIR}" ]; then
    echo "ERROR: OP-TEE source not found at ${OPTEE_DIR}" >&2
    exit 1
fi

# Build OP-TEE
echo "=== Building OP-TEE ==="
export UEFI_STMM_PATH=${LDK_DIR}/bootloader/standalonemm_optee_t234.bin
cd "${OPTEE_DIR}"
./optee_src_build.sh -p t234

echo "=== Building OP-TEE device tree ==="
dtc -I dts -O dtb -o optee/tegra234-optee.dtb optee/tegra234-optee.dts

# Build ATF
echo "=== Building ATF ==="
cd "${ATF_DIR}"
export NV_TARGET_BOARD=generic
./nvbuild.sh

if [ ! -f "${BL31_BIN}" ]; then
    echo "ERROR: ATF build failed - bl31.bin not found at ${BL31_BIN}" >&2
    exit 1
fi

# Generate TOS partition image
echo "=== Generating TOS partition image ==="
cd "${TOS_SCRIPTS}"
./gen_tos_part_img.py \
    --monitor "${BL31_BIN}" \
    --os "${TEE_BIN}" \
    --dtb "${OPTEE_DTB}" \
    --tostype optee \
    tos.img

cp tos.img "${TOS_IMG}"

echo ""
echo "=== Build complete ==="
echo "TOS image: ${TOS_IMG}"
echo ""
echo "See docs/secure_world.md for flashing instructions."
