# Google Repo Manifest for Jetson BSP Sources

This document describes the Google repo manifest that replaces NVIDIA's `source_sync.sh` script for fetching BSP source code.

## Overview

NVIDIA's `Linux_for_Tegra/source/source_sync.sh` script clones 35 git repositories from `nv-tegra.nvidia.com`. We've converted this to a Google repo manifest for easier management, reproducibility, and selective syncing.

The manifest also includes our custom/modified repositories from GitHub for pKVM GPU virtualization work.

## Manifest Repository

Manifests are maintained in a separate repository:

```
https://github.com/hlyytine/tiiuae-pkvm-manifest.git
```

## Usage

```bash
# Create workspace (can be any directory)
mkdir -p ~/pkvm
cd ~/pkvm
export WORKSPACE=$(pwd)

# Initialize repo with the manifest
repo init -u https://github.com/hlyytine/tiiuae-pkvm-manifest.git -b main -m jetson-36.4.4.xml

# Sync all repositories
repo sync -j4

# Set LDK_DIR
export LDK_DIR=${WORKSPACE}/Linux_for_Tegra
```

**Note:** `env.sh` is not provided by the repo - create it yourself or use `scripts/jetson-bsp-setup.sh` which generates it.

### Directory Structure

After sync, the structure is:
```
~/pkvm/                              # workspace root (${WORKSPACE})
├── jetson-pkvm/                     # pKVM workspace repo (actual files)
├── Linux_for_Tegra/
│   └── source/                      # BSP sources (${LDK_DIR}/source)
│       ├── kernel/linux/            # pKVM kernel
│       ├── nvgpu/
│       ├── nvidia-oot/
│       └── ...
│
│ (symlinks to jetson-pkvm/)
├── scripts -> jetson-pkvm/scripts
├── docs -> jetson-pkvm/docs
├── patches -> jetson-pkvm/patches
├── autopilot -> jetson-pkvm/autopilot
├── README.md -> jetson-pkvm/README.md
└── CLAUDE.md -> jetson-pkvm/CLAUDE.md
```

## Symlinks

The manifest uses `<linkfile>` elements to create symlinks from `jetson-pkvm/` to the workspace root:

```xml
<project name="hlyytine/jetson-pkvm" path="jetson-pkvm" ...>
  <linkfile src="scripts" dest="scripts" />
  <linkfile src="docs" dest="docs" />
  <linkfile src="patches" dest="patches" />
  <linkfile src="autopilot" dest="autopilot" />
  <linkfile src="README.md" dest="README.md" />
  <linkfile src="CLAUDE.md" dest="CLAUDE.md" />
</project>
```

## Ethernet Driver Symlink

The `nvethernetrm` repository contains Ethernet driver sources that are built as part of `nvidia-oot`, but it's maintained in a separate repository. This symlink is created automatically via `<linkfile>` in the manifest:

```
Linux_for_Tegra/source/nvidia-oot/drivers/net/ethernet/nvidia/nvethernet/nvethernetrm
  -> ../../../../../../nvethernetrm
```

## Custom/Modified Repositories

These repositories contain our modifications for pKVM GPU virtualization on Tegra234.

| Path | Repository | Branch | Description |
|------|------------|--------|-------------|
| `jetson-pkvm` | `github:hlyytine/jetson-pkvm` | `claude` | Workspace: scripts, docs, patches |
| `Linux_for_Tegra/source/kernel/linux` | `github:hlyytine/linux` | `tegra/pkvm-mainline-6.17-smmu-backup` | pKVM kernel with SMMUv2 support |

## Repository Summary

| Category | Count | Description |
|----------|-------|-------------|
| Custom | 2 | Modified repositories for pKVM support |
| Kernel | 10 | Core kernel, GPU driver, device trees, display driver |
| Other | 25 | GStreamer plugins, camera, OP-TEE/ATF, CUDA samples |
| **Total** | **37** | All repos |

### Kernel Repositories (NVIDIA stock)

| Path | Repository | Description |
|------|------------|-------------|
| `kernel/kernel-jammy-src` | `3rdparty/canonical/linux-jammy` | Ubuntu 22.04 kernel (5.15.x) |
| `nvgpu` | `linux-nvgpu` | NVIDIA GPU driver (out-of-tree) |
| `nvidia-oot` | `linux-nv-oot` | Platform drivers, misc drivers |
| `hwpm` | `linux-hwpm` | Hardware Performance Monitor |
| `nvethernetrm` | `kernel/nvethernetrm` | Ethernet driver sources |
| `kernel-devicetree` | `linux/kernel-devicetree` | Kernel device tree sources |
| `hardware/nvidia/t23x/nv-public` | `device/hardware/nvidia/t23x-public-dts` | T23x (Orin) device trees |
| `hardware/nvidia/tegra/nv-public` | `device/hardware/nvidia/tegra-public-dts` | Common Tegra device trees |
| `nvdisplay` | `tegra/kernel-src/nv-kernel-display-driver` | Display driver (out-of-tree) |
| `dtc-src/1.4.5` | `3rdparty/dtc-src/1.4.5` | Device tree compiler |

### Other Repositories

| Path | Description |
|------|-------------|
| `tegra/optee-src/atf` | ARM Trusted Firmware |
| `tegra/optee-src/nv-optee` | OP-TEE OS |
| `tegra/gst-src/*` | GStreamer plugins (13 repos) |
| `tegra/cuda-src/*` | CUDA samples |
| `tegra/v4l2-src/*` | V4L2 libraries |
| `tegra/nv-sci-src/*` | NvSci headers and samples |
| `tegra/spe-src/*` | SPE FreeRTOS BSP |

## Comparison with source_sync.sh

| Feature | source_sync.sh | repo manifest |
|---------|----------------|---------------|
| Selective sync | `-k` for kernel only | Groups support (not yet enabled) |
| Tag selection | `-t jetson_36.4.4` | `revision` attribute in manifest |
| Parallel clone | No | Yes (`-j4`) |
| Status tracking | No | `repo status` |
| Reproducibility | Tag-based | Manifest + tag |
| Symlink creation | Automatic | Automatic via `<linkfile>` |

## Creating Manifests for Other Versions

To create a manifest for a different BSP version:

1. Extract `SOURCE_INFO` from that version's `source_sync.sh`
2. Update the `revision` attribute in `<default>` to the new tag
3. Add/remove projects as needed

The format in `source_sync.sh` is:
```
type:path:repo_url:
```

Where:
- `type`: `k` (kernel) or `o` (other)
- `path`: Local checkout path
- `repo_url`: Repository path on `nv-tegra.nvidia.com`

## References

- [Google Repo Tool](https://gerrit.googlesource.com/git-repo/)
- [Repo Manifest Format](https://gerrit.googlesource.com/git-repo/+/master/docs/manifest-format.md)
- Original script: `Linux_for_Tegra/source/source_sync.sh`
