# GPU Virtualization Architecture Design

This document describes the architecture for GPU passthrough to protected guest VMs on NVIDIA Jetson AGX Orin (Tegra234) using pKVM.

## Project Goal

Enable GPU pass-through to guest VMs by moving the entire host1x subsystem and GPU hardware to a protected guest VM while keeping the host minimal.

## GPU Virtualization Strategy

The approach moves NVIDIA's host1x subsystem to the guest VM:

1. **host1x**: Hardware DMA controller managing GPU/DMA engines and IOMMUs
2. **IOMMU Streams**: Device tree modifications redirect IOMMU contexts to guest
3. **Module Blacklisting**: Host blacklists nvgpu, nvmap in `/etc/modules-load.d/nv.conf`
4. **Host Minimization**: Multi-user target (no GUI), disabled services

### Why host1x?

The host1x controller is the central hub for all GPU-related DMA operations on Tegra. By moving it entirely to the guest VM, we achieve:

- Clean separation of GPU resources
- Direct hardware access for the guest
- Simplified host (no GPU driver complexity)

## Dual Root Filesystem Setup

This project uses separate root filesystems for host and guest:

| Filesystem | Purpose | GPU Access |
|------------|---------|------------|
| `rootfs-host` | Minimal host OS | No (modules blacklisted) |
| `rootfs-gpuvm` | Full guest OS | Yes (full GPU stack) |

The `rootfs` symlink determines which filesystem receives module installations:

```bash
# Install to guest VM rootfs
rm -f ${LDK_DIR}/rootfs && ln -sf rootfs-gpuvm ${LDK_DIR}/rootfs
cd ${LDK_DIR}/source && ./nvbuild.sh -i

# Install to host rootfs
rm -f ${LDK_DIR}/rootfs && ln -sf rootfs-host ${LDK_DIR}/rootfs
cd ${LDK_DIR}/source && ./nvbuild.sh -i
```

## SMMUv2 Architecture for pKVM

See QAs [Question 1](question1.md), [Question 2](question2.md),
[Question 3](question3.md) and [Question 4](question4.md).

For comprehensive SMMUv2 implementation details, see [smmuv2_pkvm.md](smmuv2_pkvm.md).

## IOMMU Stream Management

The Tegra234 uses Memory Controller (MC) based stream ID management rather than traditional SMMU stream matching.

Key considerations:
- Stream IDs are configured via MC registers, not SMMU
- Device tree modifications redirect IOMMU contexts
- See [why-mc-coupled-with-smmu.md](why-mc-coupled-with-smmu.md) for technical details

## Related Documentation

- [smmuv2_pkvm.md](smmuv2_pkvm.md) - pKVM SMMUv2 implementation
- [uart.md](uart.md) - Debug output configuration
- [boot_problems.md](boot_problems.md) - Troubleshooting guide
- [secure_world.md](secure_world.md) - OP-TEE and ATF build instructions
- [kernel_617_compat.md](kernel_617_compat.md) - Kernel compatibility notes
