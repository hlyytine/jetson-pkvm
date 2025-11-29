#! /bin/sh

set -e

if test "x${DLDIR}" = "x"; then
  DLDIR=${HOME}/jetson_downloads
fi

if test "x${WORKSPACE}" = "x"; then
  echo "WORKSPACE not set, exiting." 1>&2
  exit 1
fi

FILES="
  aarch64--glibc--stable-2022.08-1.tar.bz2
  Jetson_Linux_R36.4.4_aarch64.tbz2
  Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2
"

for f in ${FILES}; do
  if test ! -e "${DLDIR}/${f}"; then
    echo "${f} does not exist in ${DLDIR}." 1>&2
    exit 1
  fi
done

mkdir -p ${WORKSPACE}

# Unpack Jetson BSP
echo "Unpack Jetson BSP from Jetson_Linux_R36.4.4_aarch64.tbz2"
tar -C ${WORKSPACE} -xjf ${DLDIR}/Jetson_Linux_R36.4.4_aarch64.tbz2
export LDK_DIR=${WORKSPACE}/Linux_for_Tegra

cd  ${WORKSPACE}
patch -p1 < patches/0001-Fix-checking-of-Ubuntu-version-to-not-fail-on-Debian.patch

# Unpack sample rootfs
echo "Unpack sample rootfs from Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2"
sudo tar -C ${LDK_DIR}/rootfs --numeric-owner -xjf ${DLDIR}/Tegra_Linux_Sample-Root-Filesystem_R36.4.4_aarch64.tbz2

# Install NVIDIA binary Debian packages onto rootfs
cd ${LDK_DIR}
sudo ./tools/l4t_flash_prerequisites.sh
sudo ./apply_binaries.sh

# Skip runtime post installation step
sudo ./tools/l4t_create_default_user.sh -u ubuntu -p ubuntu -a --accept-license

# Make target filesystem faster
sudo sed -i -e 's/defaults/defaults,noatime,discard/g' ${LDK_DIR}/rootfs/etc/fstab

# Update kernel source directory to match manifest (linux instead of kernel-jammy-src)
sed -i -e 's/KERNEL_SRC_DIR="kernel-jammy-src"/KERNEL_SRC_DIR="linux"/' ${LDK_DIR}/source/kernel_src_build_env.sh

# Install our convenience scripts
sudo install -d ${LDK_DIR}/rootfs/usr/bin
sudo install ${WORKSPACE}/scripts/install-cargo-deps.sh ${LDK_DIR}/rootfs/usr/bin

# Install cross-compiler
echo "Install toolchain from aarch64--glibc--stable-2022.08-1.tar.bz2"
mkdir -p ${WORKSPACE}/toolchain
tar -C ${WORKSPACE}/toolchain -xjf ${DLDIR}/aarch64--glibc--stable-2022.08-1.tar.bz2
cd ${WORKSPACE}/toolchain/aarch64--glibc--stable-2022.08-1
./relocate-sdk.sh

# Note: Sources should already be fetched via repo manifest before running this script.
# See docs/repo.md for repo init/sync instructions.

CROSS_COMPILE_AARCH64_PATH=${WORKSPACE}/toolchain/aarch64--glibc--stable-2022.08-1

cat > ${WORKSPACE}/env.sh <<EOF
WORKSPACE=${WORKSPACE}
# for generic use
export CROSS_COMPILE=\${WORKSPACE}/toolchain/aarch64--glibc--stable-2022.08-1/bin/aarch64-buildroot-linux-gnu-
# these two are for OP-TEE and ATF
export CROSS_COMPILE_AARCH64_PATH=${WORKSPACE}/toolchain/aarch64--glibc--stable-2022.08-1
export CROSS_COMPILE_AARCH64=${CROSS_COMPILE_AARCH64_PATH}/bin/aarch64-buildroot-linux-gnu-
export LDK_DIR=\${WORKSPACE}/Linux_for_Tegra
export INSTALL_MOD_PATH=\${LDK_DIR}/rootfs
EOF
