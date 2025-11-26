# DCE Firmware Crash Issue

## Problem Description

During boot, the DCE (Display Controller Engine) firmware crashes with the following error:

```
[    7.717306] dce: dce_ipc_channel_init_unlocked:248  Invalid Channel State [0x0] for ch_type [2]
[    7.717475] dce: dce_handle_irq_status:253  DCE ucode abort occurred
```

This crash occurs because UEFI initializes display hardware during boot, and DCE expects clean/uninitialized hardware. Simply deleting the framebuffer node (commit `eddfded`) is insufficient.

**Reference:** NVIDIA Bug 5411101

**Solution:** Build custom UEFI from source with display initialization disabled. See instructions below.

## Root Cause

The DCE crash is caused by an **improper display hardware handoff** from UEFI to the kernel:

1. **UEFI initializes display hardware** during boot using GOP (Graphics Output Protocol)
2. **DCE firmware expects clean/uninitialized hardware** when it starts
3. **Device tree framebuffer deletion** (commit `eddfded` in `source/hardware/nvidia/t23x/nv-public`) only prevents the *kernel driver* from using the framebuffer
4. **Hardware state remains initialized** by UEFI, causing DCE to crash when it encounters unexpected register values

### Technical Details

- **DCE** is NVIDIA's display microcontroller firmware that manages display power, clocking, and coordination with nvdisplay driver
- **UEFI** (`bootloader/uefi_jetson.bin`) includes GOP driver that initializes display hardware for boot splash
- **Boot flow:** UEFI GOP init → DCE firmware load → DCE crash (unexpected hardware state)
- **Error location:** `source/nvidia-oot/drivers/platform/tegra/dce/dce-bootstrap.c:253`
- **IRQ status:** `DCE_IRQ_ABORT` bit set, indicating microcontroller firmware abort

### Device Tree Changes Attempted

The following change was made to prevent the kernel from using UEFI's framebuffer (commit `eddfded`):

**File:** `source/hardware/nvidia/t23x/nv-public/nv-soc/tegra234-soc-display-overlay.dtsi`
```diff
+/* Bug 5411101 */
+/delete-node/ &{/chosen/framebuffer};
```

This prevents the kernel `simplefb` driver from taking over UEFI's framebuffer, but **does not reset the display hardware**, leaving DCE in a bad state.

## Solution: Build Custom UEFI with Display Disabled

The proper fix is to build UEFI from source using the `t23x_general` configuration (full features) but with display initialization disabled. This gives you all UEFI features while preventing DCE crashes.

### Prerequisites

**Install Build Dependencies:**

```bash
# Install most dependencies from Ubuntu repos
sudo apt update
sudo apt install python3 python3-pip python3-venv git build-essential uuid-dev \
  iasl nasm python-is-python3 gcc-12 g++-12 gcc-12-aarch64-linux-gnu \
  g++-12-aarch64-linux-gnu device-tree-compiler lcov

# Configure GCC 12 as default (EDK2 expects tools without version suffix)
sudo update-alternatives --install /usr/bin/aarch64-linux-gnu-gcc aarch64-linux-gnu-gcc /usr/bin/aarch64-linux-gnu-gcc-12 100 \
  --slave /usr/bin/aarch64-linux-gnu-g++ aarch64-linux-gnu-g++ /usr/bin/aarch64-linux-gnu-g++-12 \
  --slave /usr/bin/aarch64-linux-gnu-gcc-ar aarch64-linux-gnu-gcc-ar /usr/bin/aarch64-linux-gnu-gcc-ar-12 \
  --slave /usr/bin/aarch64-linux-gnu-gcc-nm aarch64-linux-gnu-gcc-nm /usr/bin/aarch64-linux-gnu-gcc-nm-12 \
  --slave /usr/bin/aarch64-linux-gnu-gcc-ranlib aarch64-linux-gnu-gcc-ranlib /usr/bin/aarch64-linux-gnu-gcc-ranlib-12 \
  --slave /usr/bin/aarch64-linux-gnu-gcov aarch64-linux-gnu-gcov /usr/bin/aarch64-linux-gnu-gcov-12 \
  --slave /usr/bin/aarch64-linux-gnu-cpp aarch64-linux-gnu-cpp /usr/bin/aarch64-linux-gnu-cpp-12

sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-12 100 \
  --slave /usr/bin/g++ g++ /usr/bin/g++-12 \
  --slave /usr/bin/gcc-ar gcc-ar /usr/bin/gcc-ar-12 \
  --slave /usr/bin/gcc-nm gcc-nm /usr/bin/gcc-nm-12 \
  --slave /usr/bin/gcc-ranlib gcc-ranlib /usr/bin/gcc-ranlib-12 \
  --slave /usr/bin/gcov gcov /usr/bin/gcov-12 \
  --slave /usr/bin/cpp cpp /usr/bin/cpp-12

# Verify installation
gcc --version
aarch64-linux-gnu-gcc --version
aarch64-linux-gnu-gcc-ar --version
```

**Install Mono (.NET Framework for Linux):**

Ubuntu 24.04's default Mono package may be too old. Install from Mono's official repository:

```bash
# Add Mono repository GPG key
sudo mkdir -p /etc/apt/keyrings
sudo gpg --homedir /tmp --no-default-keyring --keyring /etc/apt/keyrings/mono-official-archive-keyring.gpg \
  --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF

# Add Mono repository (use Ubuntu 22.04 repo for Ubuntu 24.04)
echo "deb [signed-by=/etc/apt/keyrings/mono-official-archive-keyring.gpg] https://download.mono-project.com/repo/ubuntu stable-jammy main" \
  | sudo tee /etc/apt/sources.list.d/mono-official-stable.list

# Install Mono
sudo apt update
sudo apt install mono-devel

# Verify installation
mono --version
```

**Alternative (if above fails):** Use Ubuntu's Mono package (may be older):
```bash
sudo apt install mono-devel mono-complete
```

### Setup EDK2 Workspace with edkrepo

NVIDIA's edk2-nvidia requires the base EDK2 repository and dependencies. Use edkrepo to set up a complete workspace:

```bash
# Install edkrepo
cd /tmp
wget https://github.com/tianocore/edk2-edkrepo/releases/download/edkrepo-v4.0.0/edkrepo-4.0.0.tar.gz
tar xf edkrepo-4.0.0.tar.gz
cd edkrepo-4.0.0
./install.py --user

# Add to PATH
echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
source ~/.bashrc

# Configure NVIDIA manifest repository
edkrepo manifest-repos add nvidia https://github.com/NVIDIA/edk2-edkrepo-manifest.git main nvidia

# Clone complete workspace (creates nvidia-uefi directory with all dependencies)
cd ~
edkrepo clone nvidia-uefi NVIDIA-Platforms main
```

### Build Custom UEFI

**UPDATE**: There are two approaches now available:

#### Option 1: Use JetsonMinimal (Simple, Works Out-of-Box)

The edk2-nvidia repository has a minimal target that excludes display by design:

```bash
cd ~/nvidia-uefi

# Build JetsonMinimal target (display already disabled by default)
edk2-nvidia/Platform/NVIDIA/JetsonMinimal/build.sh

# Verify no display drivers are included
! ls Build/Jetson/RELEASE_GCC5/FV/Ffs/ | grep -i display && echo "✓ No display drivers found"

# Copy to BSP bootloader directory
cp Build/Jetson/RELEASE_GCC5/FV/UEFI_NS.Fv ${LDK_DIR}/bootloader/uefi_jetson_minimal_custom.bin
```

**Trade-off**: JetsonMinimal lacks USB, PCIe, networking, ACPI, UEFI shell, etc. But it's sufficient for booting Linux from eMMC.

#### Option 2: Fix the Jetson Target Build System (Full Features)

The full "Jetson" target has a **build system bug** where `CONFIG_NVIDIA_DISPLAY` Kconfig options are not passed as EDK2 preprocessor defines, causing `!ifdef CONFIG_NVIDIA_DISPLAY` checks in DSC/FDF files to be ignored.

**Fix the bug** by patching the Stuart build system:

```bash
cd ~/nvidia-uefi

# Apply the fix to edk2-nvidia/Silicon/NVIDIA/edk2nv/stuart/builder.py
cat > /tmp/fix-kconfig-defines.patch << 'EOF'
--- a/Silicon/NVIDIA/edk2nv/stuart/builder.py
+++ b/Silicon/NVIDIA/edk2nv/stuart/builder.py
@@ -229,6 +229,20 @@ class NVIDIAPlatformBuilder(UefiBuilder):
         # Create version of config that edk2 can consume, strip the file of "
         with open(config_out, "r") as f, open(config_out_dsc, "w") as fo:
             for line in f:
                 fo.write(line.replace('"', "").replace("'", ""))

+        # Store enabled Kconfig options to pass as EDK2 preprocessor defines
+        self._kconfig_defines = []
+        with open(config_out, "r") as f:
+            for line in f:
+                line = line.strip()
+                # Skip comments and empty lines
+                if not line or line.startswith('#'):
+                    continue
+                # Parse CONFIG_FOO=y or CONFIG_FOO=n
+                if '=' in line:
+                    key, value = line.split('=', 1)
+                    key = key.strip()
+                    value = value.strip().strip('"').strip("'")
+                    # Only define symbols that are enabled (=y)
+                    if value == 'y':
+                        self._kconfig_defines.append(key)
+
         return 0

     def SetPlatformEnv(self):
@@ -353,6 +367,14 @@ class NVIDIAPlatformBuilder(UefiBuilder):
         defconf = self.settings.GetConfigFiles()
         if defconf:
             self.BuildConfigFile ()

+        # Pass Kconfig options as EDK2 preprocessor defines
+        # This allows !ifdef CONFIG_FOO to work in DSC/FDF files
+        # EDK2 build.py needs these as -D command-line arguments
+        if hasattr(self, '_kconfig_defines'):
+            shell_env = shell_environment.GetEnvironment()
+            for define in self._kconfig_defines:
+                # Set as build variable so it gets passed to build.py as -D define
+                shell_env.set_build_var(define, "TRUE")
+                logging.info(f"Kconfig preprocessor define: {define}=TRUE")
+
         # Must return 0 to indicate success.
         return 0
EOF

cd edk2-nvidia
patch -p1 < /tmp/fix-kconfig-defines.patch

# Now build with display disabled
cd ~/nvidia-uefi
edk2-nvidia/Platform/NVIDIA/Jetson/build.sh --init
sed -i 's/CONFIG_NVIDIA_DISPLAY=y/# CONFIG_NVIDIA_DISPLAY is not set/' nvidia-config/Jetson/.config
sed -i 's/CONFIG_LOGO=y/# CONFIG_LOGO is not set/' nvidia-config/Jetson/.config
edk2-nvidia/Platform/NVIDIA/Jetson/build.sh

# Verify the fix worked
! ls Build/Jetson/RELEASE_GCC5/FV/Ffs/ | grep -i NvDisplayController && echo "✓ Fix worked! No display controller driver"

# Copy to BSP bootloader directory
cp Build/Jetson/RELEASE_GCC5/FV/UEFI_NS.Fv ${LDK_DIR}/bootloader/uefi_jetson_custom.bin
```

**Result**: Full-featured Jetson UEFI with working Kconfig → now you can disable display while keeping USB, PCIe, networking, ACPI, UEFI shell, etc.

### Update Boot Configuration

Edit `${LDK_DIR}/p3701.conf.common` to use the custom UEFI:

```diff
-TBCFILE="bootloader/uefi_jetson.bin";
+TBCFILE="bootloader/uefi_jetson_custom.bin";  # Custom UEFI build
```

### What You Get with JetsonMinimal

The JetsonMinimal target provides essential boot functionality without display initialization:

**Features Included:**
- ✅ eMMC boot support
- ✅ SD card support (via eMMC controller)
- ✅ Device Tree (required for Linux boot)
- ✅ L4T Launcher (NVIDIA's boot manager)
- ✅ EXT4 filesystem support
- ✅ TPM firmware support
- ✅ Secure boot support
- ✅ Physical presence support

**Features Excluded (compared to full Jetson target):**
- ❌ UEFI display initialization (prevents DCE crash)
- ❌ Boot splash logo
- ❌ Graphics Output Protocol (GOP)
- ❌ ACPI support (uses Device Tree only)
- ❌ PCI/PCIe drivers
- ❌ USB support
- ❌ Network boot (PXE)
- ❌ NVMe, SATA support
- ❌ UEFI Shell
- ❌ FAT filesystem

**Result:** Clean DCE boot, fast minimal UEFI, kernel display driver works normally.

**Trade-off:** This is a minimal boot environment. You cannot boot from USB/NVMe, and there's no UEFI shell for debugging. But it's sufficient for booting Linux from eMMC with working display.

**Build Artifacts:**
- UEFI binary: `~/nvidia-uefi/Build/Jetson/RELEASE_GCC5/FV/UEFI_NS.Fv`
- Build log: `~/nvidia-uefi/Build/BUILDLOG_Jetson.txt`
- Configuration: `~/nvidia-uefi/nvidia-config/Jetson/.config`

## Verification

After building, flashing, and rebooting, check the boot logs:

```bash
# On the Jetson device after boot
dmesg | grep -i dce
```

Expected output:
```
✅ tegra-dce d800000.dce: Setting DCE HSP functions for tegra234-dce
✅ dce: tegra_dce_probe:322  Found display consumer device
❌ (no "DCE ucode abort occurred" error)
```

## Why Other Approaches Don't Work

### Using Pre-built Minimal UEFI
The BSP includes `uefi_jetson_minimal.bin` which also doesn't initialize display, but lacks many features (ACPI, USB storage, network boot, etc.). This is the equivalent of the JetsonMinimal target we're building - minimal but functional.

### Deleting Framebuffer Node Only
The device tree change `/delete-node/ &{/chosen/framebuffer}` (commit `eddfded`) only prevents the kernel `simplefb` driver from using UEFI's framebuffer. It does **not** reset the display hardware that UEFI already initialized, so DCE still crashes.

### Disabling DCE in Device Tree
Setting `dce@d800000 { status = "disabled"; }` prevents the crash but may break the nvdisplay driver since DCE handles display power management and firmware coordination.

### Technical Details: The Kconfig → EDK2 Preprocessor Bug

**Critical Finding**: The "Jetson" build target had a bug where disabling `CONFIG_NVIDIA_DISPLAY` via Kconfig did NOT prevent the display driver from being built.

**Root Cause** (found in `edk2-nvidia/Silicon/NVIDIA/edk2nv/stuart/builder.py:229-232`):

The `BuildConfigFile()` function only copied Kconfig values to `config.dsc.inc` but never passed them as EDK2 preprocessor defines:

```python
# Old code - only strips quotes, doesn't create defines!
with open(config_out, "r") as f, open(config_out_dsc, "w") as fo:
    for line in f:
        fo.write(line.replace('"', "").replace("'", ""))
```

This caused `!ifdef CONFIG_NVIDIA_DISPLAY` checks in DSC/FDF files to always evaluate as "undefined" (false), so display drivers were always included regardless of Kconfig settings.

**Evidence of the Bug**:
```bash
$ grep NVIDIA_DISPLAY nvidia-config/Jetson/.config
# CONFIG_NVIDIA_DISPLAY is not set  ← Kconfig is disabled

$ ls Build/Jetson/RELEASE_GCC5/FV/Ffs/ | grep -i display
7bbc8ce6-bf62-4093-9ce9-71126eb54735NvDisplayControllerDxe  ← But driver is built!
E660EA85-058E-4b55-A54B-F02F83A24707DisplayEngine
```

**Fix**: The patch above (Option 2) parses enabled Kconfig options and passes them as `-D` defines to EDK2 build.py, making `!ifdef` preprocessor checks work correctly.

## References

### Device Tree
- **Device Tree Repo:** `source/hardware/nvidia/t23x/nv-public`
- **Framebuffer Deletion Commit:** `eddfded` - "t23x: dts: temporarily remove framebuffer"
- **Display Overlay:** `source/hardware/nvidia/t23x/nv-public/nv-soc/tegra234-soc-display-overlay.dtsi`

### DCE Driver
- **DCE Driver Source:** `source/nvidia-oot/drivers/platform/tegra/dce/`
- **Bootstrap Code:** `source/nvidia-oot/drivers/platform/tegra/dce/dce-bootstrap.c:253` (abort handler)
- **Boot Command Interface:** `source/nvidia-oot/drivers/platform/tegra/dce/include/interface/dce-boot-cmds.h`
- **IRQ Definitions:** `source/nvidia-oot/drivers/platform/tegra/dce/include/interface/dce-interface.h`

### UEFI Source
- **UEFI Source:** `source/edk2-nvidia/`
- **Tegra Platform:** `source/edk2-nvidia/Platform/NVIDIA/Tegra/`
- **Build Configurations:** `source/edk2-nvidia/Platform/NVIDIA/KconfigIncludes/Build*.conf`
- **Embedded Config:** `source/edk2-nvidia/Platform/NVIDIA/KconfigIncludes/BuildEmbedded.conf` (no display)
- **General Config:** `source/edk2-nvidia/Platform/NVIDIA/KconfigIncludes/BuildGeneral.conf` (with display)
- **Defconfigs:** `source/edk2-nvidia/Platform/NVIDIA/Tegra/DefConfigs/`
- **UEFI Wiki:** https://github.com/NVIDIA/edk2-nvidia/wiki

### Other
- **UEFI Documentation:** `bootloader/nvdisp-init-README.txt` (Tegra194 only, but explains concept)
- **Bug Tracker:** NVIDIA Bug 5411101

## Boot Command Line

The kernel is booted with `video=efifb:off` to disable EFI framebuffer driver:

**File:** `p3701.conf.common:160`
```bash
CMDLINE_ADD="... video=efifb:off console=tty0"
```

This prevents conflicts between UEFI GOP and kernel drivers, but is insufficient alone without using minimal UEFI.
