# IOMMU Domain Allocation Bug Analysis

**Date:** 2025-11-21
**Status:** ✅ FIXED (Test 20251121114757)
**Crash Location:** `arch/arm64/kvm/hyp/nvhe/iommu/iommu.c:239`

**Fix Applied:** Check `is_pkvm_initialized()` before hypercall in `kvm_iommu_alloc_domain()`

## Summary

The pKVM SMMUv2 driver crashes during boot when `kvm_iommu_map_pages()` is called because the domain's reference count (`domain->refs`) is 0, triggering `BUG_ON(!old)` in `domain_get()`.

**Root Cause**: The `alloc_domain` hypercall is NOT reaching `handle_host_hcall()` at EL2. The hypercall trap occurs but is being handled elsewhere, returning failure to EL1.

## Key Evidence

### 1. Test 20251121111051 Results

**hyp.log** (EL2 hypervisor debug output):
```
[hyp-info] SMMUv2: Starting global initialization
[hyp-info] SMMUv2: Donated SMMU array: 24576 bytes for 3 instances
[hyp-info] SMMUv2: Initializing SMMU instance 0 at PA 0x0000000008000000
[hyp-info] running smmu_v2_init()
[hyp-info] SMMU[0]: Mapped MMIO: PA 0x0000000008000000 -> VA 0000400008401000, size=0x0000000001000000
[hyp-info] SMMU[0]: Mapped secondary MMIO: PA 0x0000000007000000 -> VA 0000400009401000
[hyp-info] SMMU[0]: Allocated shadow arrays (128 entries, 1280 bytes each)
[hyp-info] SMMUv2: SMMU 0 initialization complete
...SMMU 1 and 2 similar...
[hyp-info] SMMUv2: Global initialization complete
[hyp-info] hcall entry: raw_id=0x%08lx           ← Format string not resolved (minor issue)
[hyp-info] hcall: id=65 min=19 max=70            ← ONLY map_pages (ID 65)!
[hyp-err] handler: map_pages domain=3 iova=0x0000007ffffff000
[hyp-info] hcall entry: raw_id=0x%08lx
[hyp-info] hcall: id=65 min=19 max=70
[hyp-err] handler: map_pages domain=5 iova=0x0000007ffffff000
```

**Critical Observation**: Only `map_pages` (ID 65) appears in hyp.log. No trace of:
- `alloc_domain` (ID 61)
- `attach_dev` (ID 63)

**kernel.log** (EL1 debug output):
```
[    0.110347] platform 3400000.mmc: allocating EL2 domain 2 on SMMU 0
[    0.110405] WARNING: CPU: 7 PID: 1 at arch/arm64/kvm/iommu.c:139 kvm_iommu_alloc_domain+0xac/0x120
[    0.110791] WARNING: CPU: 7 PID: 1 at arch/arm64/kvm/iommu.c:124 kvm_iommu_attach_dev+0xcc/0x140
```

The WARNINGs confirm HVC traps are returning `a0 != SMCCC_RET_SUCCESS`.

**panic.log**:
```
[   11.885417] kvm [133]: nVHE hyp BUG at: arch/arm64/kvm/hyp/nvhe/iommu/iommu.c:239!
```

### 2. Array Bounds Analysis

From hyp.log: `hcall: id=65 min=19 max=70`

- Array size is 70 elements (indices 0-69)
- `hcall_min = 19` (prot_finalize)
- ID 61 (`alloc_domain`) is within valid range [19, 70)
- ID 65 (`map_pages`) IS reaching the handler

**Conclusion**: Array bounds are NOT the issue.

### 3. Hypercall ID Reference

From `arch/arm64/include/asm/kvm_asm.h`:
```c
__KVM_HOST_SMCCC_FUNC___pkvm_prot_finalize,           // Position 19
...
__KVM_HOST_SMCCC_FUNC___pkvm_host_iommu_alloc_domain, // Position 61
__KVM_HOST_SMCCC_FUNC___pkvm_host_iommu_free_domain,  // Position 62
__KVM_HOST_SMCCC_FUNC___pkvm_host_iommu_attach_dev,   // Position 63
__KVM_HOST_SMCCC_FUNC___pkvm_host_iommu_detach_dev,   // Position 64
__KVM_HOST_SMCCC_FUNC___pkvm_host_iommu_map_pages,    // Position 65
__KVM_HOST_SMCCC_FUNC___pkvm_host_iommu_unmap_pages,  // Position 66
__KVM_HOST_SMCCC_FUNC___pkvm_host_iommu_iova_to_phys, // Position 67
```

Raw SMCCC IDs:
- `alloc_domain` = 61 = 0x3D → raw_id = 0xc600003D
- `map_pages` = 65 = 0x41 → raw_id = 0xc6000041

## Analysis: Where Are alloc_domain Hypercalls Going?

### Hypothesis 1: Different Trap Handler (MOST LIKELY)

The HVC trap for `alloc_domain` may be going to a DIFFERENT handler before reaching `handle_host_hcall()`.

ARM64 HVC trap handling flow:
1. `hyp_vector` → `el1_trap` → `__host_hcall`
2. In `__host_hcall`: Check SMCCC convention, dispatch to handler

Possible interception points:
- **`handle_host_mem_abort`**: Handles MMIO/memory faults
- **`handle_host_smc`**: May intercept some SMCCC calls
- **Early returns** in the trap path

### Hypothesis 2: SMCCC Convention Check Failure

The SMCCC ID format check may be rejecting `alloc_domain`:
```c
// In hyp-entry.S or similar
// Check that this is a valid KVM hypercall
if ((id & 0xFF000000) != 0xC6000000)
    return NOT_SUPPORTED;
```

Both `alloc_domain` (0xc600003D) and `map_pages` (0xc6000041) have same prefix, so this is unlikely.

### Hypothesis 3: Timing/Race Condition

`alloc_domain` is called very early during device probe (~0.1 seconds into boot). At this point:
- `kvm_protected_mode_initialized` may not be set correctly
- Some EL2 initialization may be incomplete

But `hcall_min = 19` in hyp.log suggests protected mode IS initialized.

### Hypothesis 4: Different Code Path in EL1

Looking at `arch/arm64/kvm/iommu.c`:
```c
int kvm_iommu_alloc_domain(pkvm_handle_t iommu_id, pkvm_handle_t domain_id, int type)
{
    struct arm_smccc_res res;
    kvm_call_hyp_nvhe_mc(__pkvm_host_iommu_alloc_domain, iommu_id, domain_id, type);
    WARN_ON(res.a0 != SMCCC_RET_SUCCESS);  // Line 139
    return res.a1;
}
```

The `kvm_call_hyp_nvhe_mc` macro differs from regular hypercalls - check if it's using a different calling convention.

## Debug Code Currently in hyp-main.c

```c
static void handle_host_hcall(struct kvm_cpu_context *host_ctxt)
{
    DECLARE_REG(unsigned long, id, host_ctxt, 0);
    unsigned long hcall_min = 0;
    hcall_t hfn;
    unsigned long raw_id = id;
    unsigned long func_id = (id & ~ARM_SMCCC_CALL_HINTS) - KVM_HOST_SMCCC_ID(0);

    /* UNCONDITIONAL DEBUG: trace if this is an IOMMU-related hypercall */
    if (func_id >= 61 && func_id <= 70) {
        HYP_ERR("HCALL ENTRY: raw=0x%lx func=%lu", raw_id, func_id);
    }

    /* Debug: trace ALL IOMMU hypercalls including alloc_domain (ID 61) */
    if ((id & ~ARM_SMCCC_CALL_HINTS) >= KVM_HOST_SMCCC_ID(...alloc_domain) &&
        (id & ~ARM_SMCCC_CALL_HINTS) <= KVM_HOST_SMCCC_ID(...iova_to_phys)) {
        HYP_INFO("hcall entry: raw_id=0x%08lx", raw_id);
    }

    // ... rest of handler with bounds check debug logging ...
}
```

## Files Involved

### EL1 (Host Kernel)
- `arch/arm64/kvm/iommu.c:137-141` - `kvm_iommu_alloc_domain()` wrapper
- `arch/arm64/include/asm/kvm_host.h:1364-1373` - `kvm_call_hyp_nvhe_smccc` macro
- `arch/arm64/include/asm/kvm_asm.h:120` - Hypercall ID enum

### EL2 (Hypervisor)
- `arch/arm64/kvm/hyp/nvhe/hyp-main.c:1864-1920` - `handle_host_hcall()` dispatcher
- `arch/arm64/kvm/hyp/nvhe/hyp-main.c:1677-1688` - `handle___pkvm_host_iommu_alloc_domain()`
- `arch/arm64/kvm/hyp/nvhe/iommu/iommu.c:248-284` - `kvm_iommu_alloc_domain()`
- `arch/arm64/kvm/hyp/nvhe/iommu/iommu.c:235-241` - `domain_get()` (crash site)

### EL2 Trap Entry
- `arch/arm64/kvm/hyp/nvhe/host.S` - `__host_hcall` entry point
- `arch/arm64/kvm/hyp/nvhe/hyp-entry.S` - Low-level trap handling

## Test Results History

| Test ID | Result | Debug Added | Observations |
|---------|--------|-------------|--------------|
| 20251121102908 | Crash | None | Initial crash at iommu.c:239 |
| 20251121103532 | Crash | EL1 pr_info | Confirmed WARN_ON firing |
| 20251121104242 | Crash | EL2 HYP_ERR in handlers | Handler traces not appearing |
| 20251121111051 | Crash | EL2 bounds/ID logging | Only map_pages (65) traced, not alloc_domain (61) |
| 20251121111753 | Crash | Unconditional HCALL ENTRY trace | **CONFIRMED**: Only func=65 enters handle_host_hcall, NOT func=61 |
| 20251121112513 | Crash | TRAP ENTRY trace at handle_trap() | **ROOT CAUSE FOUND**: Only func=65 traps, func=61 does NOT trap - pKVM not active at 0.1s |

## ROOT CAUSE IDENTIFIED (Test 20251121112513)

### Summary

The `alloc_domain` hypercall (func=61) is made at **0.116s** into boot, BEFORE pKVM EL2 handler is installed. The HVC instruction does NOT trap to EL2 - it returns `SMCCC_RET_NOT_SUPPORTED` directly.

### Evidence

**hyp.log**: Only `TRAP ENTRY: ec=22 func=65` appears, NO trace for func=61.

**kernel.log** timing:
```
[    0.116203] allocating EL2 domain 2 on SMMU 0
[    0.116259] WARNING: CPU: 4 PID: 1 at kvm_iommu_alloc_domain+0xac/0x120  ← HVC returns NOT_SUPPORTED
[    0.116619] EL2 domain 2 allocated successfully  ← But res.a1=0 looks like success!
```

### The Bug Flow

1. **T=0.116s**: Device probes, calls `kvm_iommu_alloc_domain()`
2. **HVC instruction executed** at EL1
3. **pKVM EL2 NOT ACTIVE YET** - HVC returns `SMCCC_RET_NOT_SUPPORTED` directly
4. In `kvm_call_hyp_nvhe_smccc`:
   - `res.a0 = SMCCC_RET_NOT_SUPPORTED` → WARN_ON fires
   - `res.a1 = 0` (uninitialized/undefined)
5. `kvm_call_hyp_nvhe_mc` returns `res.a1` which is 0 = "success"
6. **EL1 thinks domain is allocated, but EL2 never saw it**
7. **T=12s**: `map_pages` called (after pKVM active), HVC traps to EL2
8. EL2 finds domain doesn't exist → **BUG_ON crash**

### Root Cause

**Timing mismatch**: IOMMU device probing happens at ~0.1s, but pKVM EL2 is installed later (~10-12s?). The hypercall macro doesn't check if pKVM is active.

### Fix Options

**Option 1: Defer IOMMU probing until pKVM ready**
- Add `EPROBE_DEFER` until pKVM is initialized
- Requires kernel changes to track pKVM state

**Option 2: Check pKVM state before hypercall**
- In `kvm_iommu_alloc_domain()`, check if pKVM is active
- Return error if not ready

**Option 3: Initialize pKVM earlier**
- Move pKVM initialization before device probing
- May require significant boot order changes

**Option 4: Fix return value checking**
- The hypercall macro returns `res.a1` but should check `res.a0` first
- If `res.a0 != SUCCESS`, return error instead of assuming success

## Next Steps

### CONFIRMED: alloc_domain hypercall NOT reaching handle_host_hcall()

Test 20251121111753 **confirmed** that `alloc_domain` (func=61) does NOT enter `handle_host_hcall()`:

**hyp.log evidence:**
```
[hyp-err] HCALL ENTRY: raw=0x00000000c6000041 func=65   ← ONLY map_pages!
[hyp-info] hcall: id=65 min=0 max=70
```

No `func=61` trace appears even with unconditional debug at function entry.

### Immediate Investigation: Check if alloc_domain is being called at all

**Key Question**: Is `kvm_iommu_alloc_domain()` at EL1 even being called?

The call chain is:
1. `arm_smmu_kvm_domain_alloc_paging()` - EL1 IOMMU ops
2. `kvm_iommu_alloc_domain()` - EL1 wrapper in `arch/arm64/kvm/iommu.c`
3. `kvm_call_hyp_nvhe_mc(__pkvm_host_iommu_alloc_domain, ...)` - HVC trap
4. `handle_host_hcall()` - EL2 dispatcher (NOT REACHED!)

**Possible causes for hypercall not reaching EL2:**
1. **EL1 function not called at all** - IOMMU ops may be taking different path
2. **HVC trap going elsewhere** - assembly entry point filtering
3. **Protected mode not enabled** - hypercall fails before trap

### Next Debug: Add EL1 tracing in kvm_iommu_alloc_domain()

Add `pr_err()` BEFORE the hypercall in `arch/arm64/kvm/iommu.c`:
```c
int kvm_iommu_alloc_domain(pkvm_handle_t iommu_id, pkvm_handle_t domain_id, int type)
{
    struct arm_smccc_res res;
    pr_err("EL1: BEFORE alloc_domain hypercall iommu=%u domain=%u type=%d\n",
           iommu_id, domain_id, type);
    kvm_call_hyp_nvhe_mc(__pkvm_host_iommu_alloc_domain, iommu_id, domain_id, type);
    pr_err("EL1: AFTER alloc_domain hypercall res.a0=0x%lx res.a1=0x%lx\n",
           res.a0, res.a1);
    WARN_ON(res.a0 != SMCCC_RET_SUCCESS);
    return res.a1;
}
```

## New Findings from Code Analysis (2025-11-21 ~13:30)

### 1. EL1 Call Chain Confirmed

The kernel.log from test 20251121111051 shows:
```
[    0.110347] platform 3400000.mmc: allocating EL2 domain 2 on SMMU 0
```

This `dev_info` is at `arm-smmu-kvm.c:241`, which means:
- `arm_smmu_kvm_attach_dev()` IS being called
- `kvm_iommu_alloc_domain()` IS being called (at line 244)
- The HVC trap IS happening (WARN_ON fires at line 139)

**Conclusion**: The hypercall IS being made from EL1, but something returns failure before `handle_host_hcall()` is reached at EL2.

### 2. Hypercall Macro Analysis

From `arch/arm64/include/asm/kvm_host.h:1364-1373`:
```c
#define kvm_call_hyp_nvhe_smccc(f, ...)                    \
    ({                                                      \
        struct arm_smccc_res res;                          \
        arm_smccc_1_1_hvc(KVM_HOST_SMCCC_FUNC(f),          \
                          ##__VA_ARGS__, &res);            \
        WARN_ON(res.a0 != SMCCC_RET_SUCCESS);              \
        res;                                                \
    })
```

This just calls `arm_smccc_1_1_hvc()` directly - **NO precondition checks**. The HVC trap happens unconditionally.

### 3. EL2 Trap Handler Analysis

From `arch/arm64/kvm/hyp/nvhe/hyp-main.c:1961-1970`:
```c
void handle_trap(struct kvm_cpu_context *host_ctxt)
{
    u64 esr = read_sysreg_el2(SYS_ESR);
    __hyp_enter();
    switch (ESR_ELx_EC(esr)) {
    case ESR_ELx_EC_HVC64:
        handle_host_hcall(host_ctxt);  // ALL HVC traps go here
        break;
    ...
    }
}
```

**Key finding**: ALL HVC64 traps go to `handle_host_hcall()` - no filtering at trap entry.

### 4. Handler Array Verified

The `host_hcall[]` array in `hyp-main.c:1790-1862` includes:
- Line 1853: `HANDLE_FUNC(__pkvm_host_iommu_alloc_domain)`
- Line 1857: `HANDLE_FUNC(__pkvm_host_iommu_map_pages)`

Both handlers ARE in the array.

### 5. Protected Mode Observation

Test 20251121111753 hyp.log showed `min=0` (not `min=19`):
```
[hyp-info] hcall: id=65 min=0 max=70
```

This means `kvm_protected_mode_initialized` was NOT set when `map_pages` was called. The `hcall_min` check at line 1893 would NOT block any hypercalls.

## The Mystery

**What we know:**
1. ✅ EL1 calls `kvm_iommu_alloc_domain()` - confirmed by kernel.log
2. ✅ HVC trap happens - confirmed by WARN_ON firing
3. ❌ `handle_host_hcall()` NOT reached - no trace in hyp.log
4. ❌ `res.a0 != SMCCC_RET_SUCCESS` - something returns failure

**What could intercept HVC before handle_host_hcall?**

Looking at `handle_trap()`:
- `ESR_ELx_EC_HVC64` → `handle_host_hcall()`
- No other path for HVC

**New hypothesis**: The HVC is not reaching `handle_trap()` at all!

Possible causes:
1. **EL2 not installed** - HVC returns directly to EL1
2. **Different vector** - HVC going to wrong handler
3. **Exception during HVC** - Nested fault/abort

## Next Investigation Plan

### Step 1: Add trace at handle_trap() entry

Add unconditional HYP_ERR at the very start of `handle_trap()`:
```c
void handle_trap(struct kvm_cpu_context *host_ctxt)
{
    u64 esr = read_sysreg_el2(SYS_ESR);
    unsigned long ec = ESR_ELx_EC(esr);

    /* DEBUG: Trace ALL traps */
    HYP_ERR("TRAP: esr=0x%llx ec=%lu", esr, ec);

    __hyp_enter();
    ...
}
```

This will tell us if `handle_trap()` is even being reached for alloc_domain.

### Step 2: If handle_trap not reached

Check assembly entry points:
- `arch/arm64/kvm/hyp/nvhe/host.S`
- `arch/arm64/kvm/hyp/nvhe/hyp-entry.S`

### Step 3: If handle_trap reached but wrong EC

The ESR (Exception Syndrome Register) will show what type of exception is being raised.
- `EC_HVC64 = 0x16` (expected for HVC)
- Other values indicate different exception type

## Potential Root Causes (Ranked by Likelihood)

1. **VERY HIGH**: HVC trap not reaching `handle_trap()` - EL2 handler not installed correctly at boot
2. **HIGH**: ESR shows different exception class (not HVC64)
3. **MEDIUM**: Assembly entry returns early for certain hypercall IDs
4. **LOW**: Memory corruption of handler function pointer

## Code Changes Made

### hyp-main.c (lines ~1864-1880)

Added unconditional debug trace at function entry:
```c
unsigned long func_id = (id & ~ARM_SMCCC_CALL_HINTS) - KVM_HOST_SMCCC_ID(0);

/* UNCONDITIONAL DEBUG: trace if this is an IOMMU-related hypercall */
if (func_id >= 61 && func_id <= 70) {
    HYP_ERR("HCALL ENTRY: raw=0x%lx func=%lu", raw_id, func_id);
}
```

This uses HYP_ERR (not HYP_INFO) to ensure visibility and prints both raw ID and converted function ID.

## FIX IMPLEMENTED (2025-11-21 ~14:00)

### Solution: Check pKVM State Before Hypercall

Based on root cause analysis, implemented **Option 2: Check pKVM state before hypercall**.

### Code Changes

**File: `arch/arm64/kvm/iommu.c`**

1. Added include for pKVM state check:
```c
#include <asm/virt.h>
```

2. Modified `kvm_iommu_alloc_domain()` to check if pKVM is active:
```c
int kvm_iommu_alloc_domain(pkvm_handle_t iommu_id, pkvm_handle_t domain_id, int type)
{
	/*
	 * pKVM EL2 must be active before we can allocate domains.
	 * Return -EPROBE_DEFER if called before pKVM is initialized,
	 * which causes the IOMMU driver to defer probing until later.
	 */
	if (!is_protected_kvm_enabled())
		return -EPROBE_DEFER;

	return kvm_call_hyp_nvhe_mc(__pkvm_host_iommu_alloc_domain,
				    iommu_id, domain_id, type);
}
```

### How This Fix Works

1. **`is_protected_kvm_enabled()`** checks `static_branch_likely(&kvm_protected_mode_initialized)`
2. If pKVM EL2 is NOT active yet, returns `-EPROBE_DEFER`
3. The IOMMU driver sees `-EPROBE_DEFER` and schedules deferred probing
4. Later, when pKVM IS active, the driver reprobes successfully
5. The hypercall now traps to EL2 and allocates the domain correctly

### Expected Behavior After Fix

**Boot sequence:**
```
T=0.1s:  Device probes, calls kvm_iommu_alloc_domain()
         is_protected_kvm_enabled() returns FALSE
         Returns -EPROBE_DEFER
         Driver schedules deferred probe

T=10-12s: pKVM EL2 installed
          kvm_protected_mode_initialized static key set

T=12-15s: Deferred probe runs
          kvm_iommu_alloc_domain() called again
          is_protected_kvm_enabled() returns TRUE
          HVC traps to EL2
          EL2 allocates domain successfully
          Device attaches, map_pages works
```

### Test Plan

Build and test with autopilot. Expected results:
- No crash at `iommu.c:239`
- Devices should probe successfully after deferral
- hyp.log should show `alloc_domain` (func=61) being handled at EL2

### Potential Issues

1. **Deferred probe timeout**: Some drivers may have strict timeouts
2. **Boot delay**: Added delay for devices that defer
3. **Other hypercalls**: May need similar checks for `attach_dev`, etc.

### Test 20251121114433 Results - FIX INCORRECT

The first fix attempt used `is_protected_kvm_enabled()` which checks CPU capability `ARM64_KVM_PROTECTED_MODE`. This flag is set **early in boot** - before the EL2 handler is installed!

**Evidence**:
- Kernel log shows domains still being allocated at 0.105s
- WARN_ON still firing (hypercall returns NOT_SUPPORTED)
- No alloc_domain traces in hyp.log

**Correct function**: `is_pkvm_initialized()` which uses static key `kvm_protected_mode_initialized`. This key is set AFTER the EL2 handler installation is complete.

### Fix v2: Use is_pkvm_initialized()

```c
if (!is_pkvm_initialized())
    return -EPROBE_DEFER;
```

This checks the static key that's only set after:
1. EL2 hypervisor is installed
2. Protected mode finalization is complete
3. All hypercall handlers are ready

### Test 20251121114757 Results - FIX WORKING!

**✅ NO PANIC!** The `is_pkvm_initialized()` check is working correctly.

**Evidence from kernel.log:**
```
[    0.111801] platform 3400000.mmc: allocating EL2 domain 2 on SMMU 0
[    0.111811] platform 3400000.mmc: failed to allocate EL2 domain 2: -517
```

-517 = `-EPROBE_DEFER` - the check is returning the correct error.

**New Issue Observed**:
```
[    7.741791] sdhci-tegra 3460000.mmc: missing IOMMU stream ID
[    7.973538] tegra-mc: sdmmcrab: read @0x0000007ffffff200: EMEM address decode error
```

The crash is fixed, but now there are secondary issues with MC SID enumeration that need to be addressed separately. This is a different bug - the deferred probing is working, but the devices still fail later due to missing stream IDs.

## Summary

**ROOT CAUSE**: `kvm_iommu_alloc_domain()` was being called at ~0.1s, before pKVM EL2 handler was installed (~10s+). HVC returned `SMCCC_RET_NOT_SUPPORTED`, but the macro returned `res.a1=0` as "success".

**FIX**: Check `is_pkvm_initialized()` (static key set AFTER EL2 installation) before making hypercall. Return `-EPROBE_DEFER` if not ready.

**Code Change** (`arch/arm64/kvm/iommu.c`):
```c
#include <asm/virt.h>

int kvm_iommu_alloc_domain(pkvm_handle_t iommu_id, pkvm_handle_t domain_id, int type)
{
	if (!is_pkvm_initialized())
		return -EPROBE_DEFER;

	return kvm_call_hyp_nvhe_mc(__pkvm_host_iommu_alloc_domain,
				    iommu_id, domain_id, type);
}
```

**Status**: ✅ Crash at `iommu.c:239` FIXED
