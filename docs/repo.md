# Google Repo Manifest for Jetson BSP Sources

This document describes the Google repo manifest that replaces NVIDIA's `source_sync.sh` script for fetching BSP source code.

## Overview

NVIDIA's `Linux_for_Tegra/source/source_sync.sh` script clones 35 git repositories from `nv-tegra.nvidia.com`. We've converted this to a Google repo manifest for easier management, reproducibility, and selective syncing.

## Manifest Location

```
manifests/jetson-36.4.4.xml
```

## Usage

```bash
cd ${LDK_DIR}/source

# Initialize repo with the manifest (uses ${WORKSPACE} as manifest repo)
repo init -u ${WORKSPACE} -m manifests/jetson-36.4.4.xml

# Sync all repositories
repo sync -j4
```

This is done automatically by `scripts/jetson-bsp-setup.sh`.

## Ethernet Driver Symlink

The `nvethernetrm` repository contains Ethernet driver sources that are built as part of `nvidia-oot`, but it's maintained in a separate repository. A symlink is needed to place it in the expected location within the nvidia-oot tree.

This symlink is created automatically via `<linkfile>` in the manifest:

```xml
<project name="kernel/nvethernetrm" path="nvethernetrm">
  <linkfile src="." dest="nvidia-oot/drivers/net/ethernet/nvidia/nvethernet/nvethernetrm" />
</project>
```

After `repo sync`, the symlink exists at:
```
nvidia-oot/drivers/net/ethernet/nvidia/nvethernet/nvethernetrm -> ../../../../../../nvethernetrm
```

## Repository Summary

| Category | Count | Description |
|----------|-------|-------------|
| Kernel | 10 | Core kernel, GPU driver, device trees, display driver |
| Other | 25 | GStreamer plugins, camera, OP-TEE/ATF, CUDA samples |
| **Total** | **35** | All repos from nv-tegra.nvidia.com |

### Kernel Repositories

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
