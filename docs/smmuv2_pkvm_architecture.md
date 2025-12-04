# pKVM SMMUv2 Architecture

This document describes architectural decisions, design rationale, and solutions to problems encountered during the pKVM SMMUv2 implementation for Tegra234.

## Overview

The pKVM SMMUv2 driver enables DMA isolation for protected guest VMs by having the EL2 hypervisor own and control the SMMU hardware. The host kernel's SMMU driver continues to operate normally, but all its register accesses trap to EL2 for validation and emulation.

## Problems & Solutions

### 1. IOMMU Driver Probe Timing with pKVM

#### Problem

When pKVM virtualizes the IOMMU, the EL2 hypervisor must "donate" IOMMU MMIO pages to itself before the EL1 driver probes. This donation:
1. Unmaps the IOMMU MMIO from the host's stage-2 page tables
2. Causes all subsequent register accesses to trap to EL2
3. Enables the hypervisor to validate and emulate SMMU operations

The kernel initialization order creates a timing conflict:
- `device_initcall` - Platform drivers probe devices (including SMMU)
- `device_initcall_sync` - `finalize_pkvm()` donates MMIO, enables trapping

Without intervention, SMMU register writes during probe go directly to hardware, bypassing the hypervisor's security enforcement.

#### Why Initcall Level Adjustments Don't Work

**Attempt 1: Register pKVM stub driver earlier**
- Problem: Even if registered earlier, pKVM isn't finalized yet
- The stub needs pKVM to be ready before it can work properly
- Early binding with non-ready pKVM = broken state

**Attempt 2: Register pKVM stub driver later**
- Problem: Standard arm-smmu driver binds first
- We lose control of SMMU hardware
- Can't intercept register accesses

**Attempt 3: Register standard arm-smmu later**
- Problem: Would break all non-pKVM platforms
- SMMU is critical infrastructure; other drivers depend on it
- Unacceptable regression for non-pKVM use cases

**Fundamental issue**: Platform driver probing is event-driven, not initcall-ordered. When you register a platform driver, Linux immediately probes any matching devices. The probe happens the moment both the driver AND device are registered, regardless of which initcall level triggered the registration.

#### Solution: Runtime Probe Deferral

The solution is to add a runtime check in the standard arm-smmu driver's probe function:

```c
#ifdef CONFIG_ARM64
if (is_protected_kvm_enabled() && !is_pkvm_initialized()) {
    dev_dbg(dev, "Deferring probe until pKVM is initialized\n");
    return -EPROBE_DEFER;
}
#endif
```

**Why this works:**

1. **Runtime check, not compile-time**: Only affects boots where pKVM is actually enabled
2. **Automatic re-probe**: Linux's driver core automatically re-probes deferred devices after other initcalls complete
3. **Zero impact on non-pKVM**: The check returns false immediately on non-pKVM systems
4. **Works with any registration order**: Doesn't depend on which driver registers first
5. **Platform-agnostic**: The arm-smmu driver serves many platforms; this doesn't break any of them

**Initialization flow with deferral:**

```
device_initcall:
  arm-smmu probes → is_pkvm_initialized() returns false → -EPROBE_DEFER

device_initcall_sync:
  finalize_pkvm() runs → donates SMMU MMIO → sets pkvm_initialized = true

deferred_probe_work:
  arm-smmu re-probes → is_pkvm_initialized() returns true → probe continues
  All register writes now trap to EL2 for validation
```

#### Historical Context

This pattern was established by commit 87727ba2bb05 ("KVM: arm64: Ensure CPU PMU probes before pKVM host de-privilege") which moved `finalize_pkvm()` to `device_initcall_sync` and noted:

> "This will also be needed in future when probing IOMMU devices"

#### Applicability to Other Architectures

The `#ifdef CONFIG_ARM64` guard is necessary because `is_protected_kvm_enabled()` and `is_pkvm_initialized()` only exist on ARM64. Future pKVM IOMMU implementations on other architectures (x86 with TDX/SEV, RISC-V with hypervisor extension) will need equivalent probe deferral mechanisms.

The key insight is universal: **hypervisor-based IOMMU virtualization requires the hypervisor to own IOMMU hardware before the host driver initializes it**. The specific mechanism (probe deferral, initcall ordering, or firmware handoff) may vary, but the requirement is fundamental.

#### Related Files

- `drivers/iommu/arm/arm-smmu/arm-smmu.c` - Probe deferral check
- `arch/arm64/kvm/pkvm.c` - `finalize_pkvm()` implementation
- `arch/arm64/include/asm/virt.h` - `is_pkvm_initialized()` declaration
