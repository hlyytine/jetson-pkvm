# Install build dependencies

These are for Ubuntu 24.04.1 LTS.

```
sudo apt update
sudo apt dist-upgrade
```

# Set up Jetson 36.4.3

```
git clone https://github.com/hlyytine/jetson-pkvm.git
cd jetson-pkvm
export WORKSPACE=`pwd`
scripts/jetson-bsp-setup.sh
. env.sh

# optional
echo '. '${WORKSPACE}'/env.sh' >> ${HOME}/.bashrc
```

# Create separate root filesystems for host and guest

    sudo tar -C ${LDK_DIR} -cpf ${WORKSPACE}/rootfs-l4t.tar rootfs
    sudo mv rootfs rootfs-host

    sudo tar -C ${LDK_DIR} -xpf ${WORKSPACE}/rootfs-l4t.tar
    sudo mv rootfs rootfs-gpuvm

---

# Check out project specific sources

## Kernel 5.15.148 with BPMP drivers and defconfig


    cd ${LDK_DIR}/source/kernel/kernel-jammy-src
    git remote add gpuvm https://github.com/hlyytine/linux-jammy.git
    git fetch gpuvm
    git checkout gpuvm

    cd ${LDK_DIR}/source/hardware/nvidia/t23x/nv-public
    git remote add gpuvm https://github.com/hlyytine/t23x-public-dts.git
    git fetch gpuvm
    git checkout gpuvm

    cd ${LDK_DIR}/source/nvgpu
    git remote add gpuvm https://github.com/hlyytine/linux-nvgpu.git
    git fetch gpuvm
    git checkout gpuvm

    cd ${LDK_DIR}/source/nvidia-oot
    git remote add gpuvm https://github.com/hlyytine/linux-nv-oot.git
    git fetch gpuvm
    git checkout gpuvm

    cd ${LDK_DIR}/source/nvdisplay
    git remote add gpuvm https://github.com/hlyytine/nv-kernel-display-driver.git
    git fetch gpuvm
    git checkout gpuvm

---

## Build and install new kernel

    cd ${LDK_DIR}/source
    ./nvbuild.sh

## Install kernel modules to gpuvm rootfs

    rm -f ${LDK_DIR}/rootfs
    ln -sf rootfs-gpuvm ${LDK_DIR}/rootfs
    ./nvbuild.sh -i

## Install kernel image and modules to host rootfs

    rm -f ${LDK_DIR}/rootfs
    ln -sf rootfs-host ${LDK_DIR}/rootfs
    ./nvbuild.sh -i

## Use new kernel for recovery image as well

    cp ${LDK_DIR}/rootfs/boot/Image ${LDK_DIR}/kernel


## Prevent loading GPU related kernel modules in the host

    sudo sed -i -e 's/^nvgpu$/# nvgpu/g' ${LDK_DIR}/rootfs-host/etc/modules-load.d/nv.conf
    sudo sed -i -e 's/^nvmap$/# nvmap/g' ${LDK_DIR}/rootfs-host/etc/modules-load.d/nv.conf

## Do not try to start GUI on host

    sudo ln -sf multi-user.target ${LDK_DIR}/rootfs-host/lib/systemd/system/default.target
    sudo rm -f ${LDK_DIR}/rootfs-host/etc/systemd/system/nv.service

## Update initramfs

    cd ${LDK_DIR}
    sudo ./tools/l4t_update_initrd.sh

## Flash it

    cd ${LDK_DIR}
    sudo ./flash.sh jetson-agx-orin-devkit internal

# Build QEMU on NVIDIA Orin AGX

## Install build dependencies

    sudo apt update
    sudo apt dist-upgrade
    sudo apt install -y \
        python3-tomli \
        python3-venv

    sudo apt-get install -y \
        debhelper-compat \
        python3 \
        ninja-build \
        meson \
        texinfo \
        python3-sphinx \
        python3-sphinx-rtd-theme \
        libaio-dev \
        libjack-dev \
        libpulse-dev \
        libasound2-dev \
        libbrlapi-dev \
        libcap-ng-dev \
        libcurl4-gnutls-dev \
        libfdt-dev \
        libfuse3-dev \
        gnutls-dev \
        libgtk-3-dev \
        libvte-2.91-dev \
        libiscsi-dev \
        libncurses-dev \
        libvirglrenderer-dev \
        libepoxy-dev \
        libdrm-dev \
        libgbm-dev \
        libnuma-dev \
        libcacard-dev \
        libpixman-1-dev \
        librbd-dev \
        libglusterfs-dev \
        libsasl2-dev \
        libsdl2-dev \
        libseccomp-dev \
        libslirp-dev \
        libspice-server-dev \
        librdmacm-dev \
        libibverbs-dev \
        libibumad-dev \
        liburing-dev \
        libusb-1.0-0-dev \
        libusbredirparser-dev \
        libssh-dev \
        libzstd-dev \
        nettle-dev \
        uuid-dev \
        xfslibs-dev \
        zlib1g-dev \
        libudev-dev \
        libjpeg-dev \
        libpng-dev \
        libpmem-dev

## Check out sources

    git clone https://github.com/hlyytine/qemu.git
    cd qemu
    git checkout gpuvm
    git submodule update --init --recursive

## Build QEMU

    ./configure --target-list=aarch64-softmmu
    make -j`nproc`
