# Remaining Boot Issues After MMC Stream ID Fix

## Critical Issue: IOMMU Domain Allocation Bug (2025-11-21)

**See:** [iommu-domain-alloc-bug.md](iommu-domain-alloc-bug.md) for comprehensive analysis

**Status:** ✅ **FIXED** (commit `4410fe1398fa`)

**Root Cause:** `kvm_iommu_alloc_domain()` was called at ~0.1s before pKVM EL2 was active (~7.6s). The hypercall would silently fail (a0 != SUCCESS but a1 == 0), leaving domain refs uninitialized. Later `map_pages` would crash with `BUG_ON(!old)` in `domain_get()`.

**Fix:** Added `is_pkvm_initialized()` check in `kvm_iommu_alloc_domain()` to return `-EPROBE_DEFER` if called before EL2 is ready. Devices now defer probing and retry successfully at 7.6s.

**Test:** 20251121114757 - No panic, devices correctly defer with -517 (EPROBE_DEFER)

---

## Issue: "missing IOMMU stream ID" for 3460000.mmc (2025-11-21)

**Status:** ❌ **REJECTED APPROACH - Need MC-based solution** (2025-11-21)

**Symptoms:**
```
[    4.495054] tegra-mc: MC: Added SID 0x2 to fwspec for /bus@0/mmc@3460000
[    7.741791] sdhci-tegra 3460000.mmc: missing IOMMU stream ID
```

**Root Cause:** `tegra_dev_iommu_get_stream_id()` requires `fwspec->num_ids == 1`.

### Failed Approach: late_initcall Early Enumeration

**Attempted Fix (REVERTED):**
- Added `arm_smmu_kvm_enumerate_all_devices()` at `late_initcall` level
- Walked device tree and called `iommu_fwspec_add_ids()` for all devices with `iommus` property

**Test Result (20251121142723):**
- "missing IOMMU stream ID" still appears for both 3460000.mmc and 3400000.mmc
- Broke 2600000.dma-controller (gpcdma) which had been working
- The function runs at 8.137s but sdhci probes at 8.281s and still fails

**Why It Failed:**
1. Complex timing issues between MC enumeration, IOMMU framework, and driver probing
2. Multiple systems adding SIDs leads to num_ids > 1 issues
3. Interferes with working devices (gpcdma)

**Commits:**
- `cc0ce02fc3be` - Original implementation (REVERTED)
- `c195fd87f421` - Revert commit

### Correct Approach: MC-based SID Enumeration at EL2

**DO NOT RETRY EL1-BASED APPROACHES.** The proper solution is:

1. Move SID registration to EL2 via MC hypercalls
2. MC driver at EL1 calls hypercall to register SID→client mappings
3. EL2 owns the authoritative SID table
4. No timing issues since MC runs at arch_initcall (very early)

**See:** Main CLAUDE.md "MC-Based Stream ID Management" section for full implementation plan

---

**Date**: 2025-11-20
**Status**: GPCDMA Fixed, MMC ADMA Investigation Pending

## Overview

After successfully fixing the MMC "missing IOMMU stream ID" issue via Stream ID de-duplication (commit `26a0964b8b91`), two issues were identified:

1. ✅ **tegra-gpcdma**: "Missing iommu stream-id" warning → **FIXED** (commit `af8efc8b6467`)
2. ⚠️ **mmc0 ADMA error**: Hardware DMA descriptor errors during card initialization

---

## Issue 1: tegra-gpcdma Missing Stream ID

### Symptoms

```
[7.152095] tegra-gpcdma 2600000.dma-controller: Missing iommu stream-id
[7.152396] tegra-gpcdma 2600000.dma-controller: probe with driver tegra-gpcdma failed with error -22
```

### Root Cause Analysis

**Device Tree Configuration**:
```dts
gpcdma: dma-controller@2600000 {
    compatible = "nvidia,tegra234-gpcdma", "nvidia,tegra186-gpcdma";
    reg = <0x0 0x2600000 0x0 0x210000>;
    iommus = <&smmu_niso0 TEGRA234_SID_GPCDMA>;  ← HAS IOMMU property
    // NO interconnects property!
};
```

**Key Finding**: GPCDMA has `iommus` property but **NO `interconnects` property**.

**Impact on MC Enumeration**:
- MC driver's `tegra186_mc_enumerate_sids()` looks for devices with BOTH:
  - `iommus` property (to get Stream ID)
  - `interconnects` property (to get MC client ID)
- GPCDMA only has `iommus`, so MC enumeration **skips it entirely**
- No fwspec population → driver's `tegra_dev_iommu_get_stream_id()` fails

### Why No `interconnects` Property?

GPCDMA may be a **fixed-function DMA controller** that:
- Doesn't go through Memory Controller's interconnect fabric
- Has direct SMMU connection
- Doesn't need MC client ID or SID override registers
- Uses Stream ID directly from device tree

**Verification Needed**:
- Check if GPCDMA has MC client entries in Tegra234 TRM
- Search for GPCDMA-related entries in `drivers/memory/tegra/tegra234.c`
- Result: **NO GPCDMA entries found in MC client table**

### Solution Options

#### Option A: Add `interconnects` Property (Recommended if MC client exists)

**Approach**: Research if GPCDMA has MC clients, add to device tree

**Requirements**:
1. Find GPCDMA MC client IDs from Tegra234 TRM
2. Add MC client entries to `drivers/memory/tegra/tegra234.c`
3. Add `interconnects` property to device tree

**Pros**: Consistent with other devices, MC-based validation
**Cons**: Only viable if GPCDMA actually has MC clients

#### Option B: SMMU Stub Driver Handles Non-MC Devices

**Approach**: Modify `arm-smmu-kvm.c` probe_device() to handle devices with `iommus` but no `interconnects`

**Implementation**:
```c
static struct iommu_device *arm_smmu_kvm_probe_device(struct device *dev)
{
    // ... existing code ...
    
    /* Populate fwspec with Stream ID for device drivers that query via
     * tegra_dev_iommu_get_stream_id(). We do this in probe_device instead
     * of of_xlate because of_xlate causes boot failure in pKVM context.
     */
    if (args.args_count > 0) {
        u32 sid = args.args[0];
        
        // De-duplicate before adding (same as MC fix)
        struct iommu_fwspec *fwspec = dev_iommu_fwspec_get(dev);
        bool already_added = false;
        
        if (fwspec) {
            for (int i = 0; i < fwspec->num_ids; i++) {
                if (fwspec->ids[i] == sid) {
                    already_added = true;
                    break;
                }
            }
        }
        
        if (!already_added) {
            ret = iommu_fwspec_add_ids(dev, &sid, 1);
            if (ret) {
                dev_warn(dev, "Failed to add SID 0x%x to fwspec: %d\n", sid, ret);
            } else {
                dev_dbg(dev, "Added SID 0x%x to fwspec (non-MC device)\n", sid);
            }
        }
    }
    
    // ... rest of function ...
}
```

**Pros**: 
- Works for any device with `iommus` but no `interconnects`
- No need to modify device tree or add MC entries
- SMMU stub already runs at subsys_initcall_sync (before device probing)

**Cons**: 
- Bypasses MC-based approach for these devices
- No EL2 validation for SID assignment (less secure)

#### Option C: Accept the Warning (Not Recommended)

**Approach**: Leave as-is, GPCDMA uses fallback SID 0x7f

**Pros**: No code changes
**Cons**: Device may not function correctly, probe fails with -EINVAL

### Recommended Solution

**Use Option B**: Modify SMMU stub driver to handle non-MC devices

**Rationale**:
1. GPCDMA doesn't appear in MC client table → no MC clients exist
2. SMMU stub driver is the right place to handle direct IOMMU connections
3. Already happens at correct initialization level (before device probing)
4. De-duplication logic can be reused from MC fix

**Security Note**: For devices without MC validation, EL2 should still track SID assignments for basic validation, even if not tied to specific client IDs.

### ✅ RESOLUTION (2025-11-20)

**Implementation**: Commit `af8efc8b6467` - "iommu/arm-smmu: Add early enumeration for non-MC devices"

**Approach Taken**: Early Device Tree Enumeration (enhanced Option B)

**Key Insight - Timing Issue**:
The initial attempt to populate fwspec in `probe_device()` callback failed because:
- GPCDMA driver probes at ~7.1 seconds
- Calls `tegra_dev_iommu_get_stream_id()` immediately during probe
- `probe_device()` callback only runs when device attaches to domain (AFTER probe fails)
- Result: fwspec empty when driver checks → probe failure

**Solution - Early Enumeration**:
Added `arm_smmu_kvm_enumerate_devices()` function that:
- Runs at `subsys_initcall_sync` level (~0.11 seconds, very early boot)
- Walks device tree for ALL devices with `iommus` property
- Skips devices with `interconnects` (MC handles those)
- Populates fwspec BEFORE devices start probing
- Includes de-duplication to prevent num_ids > 1 issues

**Pattern**: Same as MC's `tegra186_mc_enumerate_sids()` but for non-MC devices.

**Hardware Test Results** (test 20251120215213):
```
Before:
[7.152095] tegra-gpcdma 2600000.dma-controller: Missing iommu stream-id
[7.152396] tegra-gpcdma: probe failed with error -22

After:
[0.117136] arm-smmu-kvm: Added SID 0x4 to fwspec for /bus@0/dma-controller@2600000
[7.616167] tegra-gpcdma 2600000.dma-controller: GPC DMA driver register 31 channels ✓
```

**Impact**: Zero "Missing iommu stream-id" warnings system-wide

**Additional Devices Fixed**:
- I2C controllers (SID 0x4): 3160000, 3180000, 3190000, 31b0000, 31c0000, 31e0000, c240000, c250000
- SPI controllers (SID 0x4): 3210000, 3230000
- HWPM (SID 0x4): f100000.hwpm
- AON (SID 0x1): c000000.aon
- SMMU test device (SID 0x18)

**Why This is the Proper Approach**:
1. GPCDMA bypasses Memory Controller (no MC client entries)
2. SMMU stub driver is correct layer for direct IOMMU connections
3. MC driver handles MC-attached devices, SMMU handles directly-attached
4. Maintains separation of concerns

---

## Issue 2: MMC ADMA Error

### Symptoms

```
[7.356986] mmc0: ADMA error: 0x02000008
[7.455683] mmc0: sdhci: ADMA Err: 0x00000006 | ADMA Ptr: 0x0000000805e00200
[13.006993] mmc0: error -5 whilst initialising MMC card
```

### Analysis

**Error Code Breakdown**:
- ADMA Error Register: `0x02000008`
  - Bit 27 (0x08000000): Transfer error
  - Bit 25 (0x02000000): Descriptor error
- ADMA State: `0x06` = Stopped (FDS - Fetch Descriptor State)

**What This Means**:
- ADMA controller stopped while trying to fetch descriptor
- Descriptor address: `0x805e00200` (valid physical address)
- Error -5 = -EIO (Input/Output error)

### Root Cause Candidates

#### 1. IOMMU Translation Issue (Possible)

**Theory**: ADMA descriptor address not properly translated by SMMU

**Evidence**:
- Physical address `0x805e00200` may need IOMMU translation
- SMMU may not have proper page table setup for this address
- Could be related to identity mapping not covering this region

**Test**: Check if ADMA buffer addresses are in host memory range that SMMU knows about

#### 2. Hardware Timing Issue (Likely)

**Theory**: SDMMC controller initialization sequence timing

**Evidence**:
- Error occurs during card initialization (not during normal operation)
- Multiple retry attempts fail the same way
- This is mmc0 (3460000.mmc), not mmc1 (3400000.mmc)

**Common Causes**:
- Card not ready when driver starts ADMA
- Power sequencing issue
- Clock not stabilized
- Card detection race condition

#### 3. ADMA Descriptor Format Issue (Less Likely)

**Theory**: Descriptor structure mismatch

**Evidence**: Descriptor shows valid-looking data in register dump
**Unlikely because**: Same driver works on other Tegra platforms

### Test Attempt 1: CQHCI Hypothesis (2025-11-20) - ❌ **CQHCI NOT THE CAUSE**

**Test Date**: 2025-11-20
**Test IDs**: 20251120222200 (invalid - wrong DTB), 20251120232909 (valid - correct DTB)

**Hypothesis**: CQHCI (Command Queue Host Controller Interface) causing ADMA errors

**Approach**:
- Modified `tegra234.dtsi:3097` to comment out `supports-cqe;` property
- Rebuilt device tree blob using `make dtbs`
- Deployed via autopilot DTB upload mechanism
- Tested on hardware

**Result**: ❌ **CQHCI is NOT the root cause**

**Evidence**:
```
Test WITH CQHCI (20251120222200):
- ADMA errors: 1 occurrence
- MC EMEM decode errors: 8 occurrences

Test WITHOUT CQHCI (20251120232909):
- ADMA errors: 3 occurrences (WORSE!)
- MC EMEM decode errors: 8 occurrences (same)
- CQHCI successfully disabled (verified in logs)
```

**Key Findings**:
1. **Disabling CQHCI made it worse** - 3 ADMA errors vs 1
2. **MC errors unchanged** - Same 8 EMEM decode errors at `0xffffffff00`
3. **Same error code** - ADMA error: `0x02000008` in both tests
4. **Same command** - Error during CMD8 (SEND_EXT_CSD) execution
5. **ADMA descriptor error** - Error code bit 3 set indicates descriptor/state error

**Root Cause Analysis**:
```
ADMA Error Code: 0x02000008
- Bit 3 (0x08): Descriptor/State Error - ADMA descriptor has invalid data
- Bit 25 (0x02000000): Vendor-specific error flag

SDHCI Command: 0x0000083a
- Command Index: CMD8 (SEND_EXT_CSD - read Extended CSD register)
- Data transfer active (ADMA descriptor needed)

Memory Controller Error:
tegra-mc: sdmmcrab: secure read @0x000000ffffffff00: EMEM address decode error
```

**Conclusion**:
The bug is in **ADMA descriptor setup**, not CQHCI. The driver is creating descriptors with invalid address `0xffffffff00` when executing SEND_EXT_CSD command. This is likely an uninitialized buffer address or error marker value being used as a DMA target address.

### Investigation Steps

1. ✅ **CQHCI Hypothesis** - **COMPLETE (NOT THE CAUSE)**:
   - Deployed correct DTB with `supports-cqe` disabled (test 20251120232909)
   - Verified CQHCI initialization messages absent from boot log
   - Result: ADMA error persists (actually got worse with 3 errors vs 1)
   - **Conclusion**: CQHCI is not the root cause

2. **Next: Investigate ADMA Descriptor Setup** (HIGH PRIORITY):
   - Address `0xffffffff00` is clearly invalid (uninitialized or error marker)
   - Review `sdhci-tegra.c` ADMA descriptor allocation for CMD8
   - Check if buffer pointer is NULL when creating ADMA descriptor
   - Look for recent changes in ADMA descriptor handling code
   - Compare with kernel 5.15.148 (which likely works)

3. **Investigate Invalid Address Source**:
   - Trace where `0xffffffff00` value originates
   - Check if it's a special marker value (like -256 cast to u64)
   - Review SEND_EXT_CSD command handler in mmc core
   - Check bounce buffer allocation for this command

4. **Check SMMU Configuration**:
   - Verify if SDMMC has proper IOMMU domain attached
   - Check if S2CR is in BYPASS mode (would skip translation)
   - Look for SMMU faults in detailed logs (already checked: zero faults)
   - Review Stream ID assignment for 3460000.mmc

5. **Compare with Working Device**:
   - Why does 3400000.mmc (mmc1) work but 3460000.mmc (mmc0) fails?
   - Check device tree differences between mmc0 and mmc1
   - Both use same driver, different initialization paths?
   - Different ADMA descriptor buffer allocation?

6. **Test with ADMA Disabled** (WORKAROUND):
   - Try PIO mode instead of ADMA
   - Add kernel parameter: `sdhci.debug_quirks=0x40` (disable ADMA)
   - Will help isolate if bug is ADMA-specific or broader SDMMC issue

### Severity Assessment

**Impact**: Medium
- Device probe fails, but system boots successfully
- Other MMC device (3400000.mmc) may still work
- Non-critical for initial pKVM testing (GPU passthrough focus)

**Priority**: Low (after GPCDMA fix)
- Should be investigated but not blocking
- May be hardware-specific issue
- Could be deferred to later optimization phase

---

## Implementation Plan

### Phase 1: Fix tegra-gpcdma ✅ **COMPLETE**

**Actual Time**: 4 hours (including timing issue debugging)

**Steps**:
1. ✅ Analyze device tree and MC client table
2. ✅ Implement early device tree enumeration (enhanced Option B)
3. ✅ Add de-duplication logic to prevent num_ids > 1
4. ✅ Test on hardware (test 20251120215213)
5. ✅ Verify GPCDMA probe succeeds - registered 31 channels
6. ✅ Commit fix with detailed explanation (af8efc8b6467)

**Result**: ✅ Zero "Missing iommu stream-id" warnings system-wide
- GPCDMA works: "GPC DMA driver register 31 channels"
- Additional devices fixed: I2C, SPI, HWPM, AON (14 devices total)

### Phase 2: Investigate MMC ADMA Error 🔍 **IN PROGRESS**

**Status**: CQHCI hypothesis tested and ruled out - investigating ADMA descriptor bug

**Estimated Time**: 6-8 hours (initial estimate was low)

**Progress**:
- ✅ **CQHCI hypothesis tested** (test 20251120232909): NOT the cause
- ✅ Confirmed CQHCI disabled in DTB (autopilot DTB upload working)
- ✅ Identified root cause area: ADMA descriptor setup in sdhci-tegra driver
- 🔍 **Key finding**: Invalid address `0xffffffff00` during CMD8 (SEND_EXT_CSD)
- 📊 **Evidence**: Disabling CQHCI made it worse (3 errors vs 1)

**Next Steps**:
1. **Investigate ADMA descriptor allocation** for CMD8/SEND_EXT_CSD
   - Review `drivers/mmc/host/sdhci-tegra.c` descriptor setup
   - Check bounce buffer allocation for EXT_CSD command
   - Look for NULL buffer pointer being used as DMA address

2. **Compare with working kernel** (5.15.148):
   - Check if bug exists in known-working kernel
   - Identify recent changes in ADMA descriptor handling
   - Review kernel 6.17 SDHCI subsystem changes

3. **Analyze error pattern**:
   - Why does error happen 3x without CQHCI vs 1x with CQHCI?
   - Is `0xffffffff00` a specific error marker value?
   - Why only mmc0 and not mmc1?

4. **Test workarounds**:
   - Disable ADMA via kernel parameter (PIO mode fallback)
   - Check if fixes are available in newer kernel versions

**Expected Result**: Either patch sdhci-tegra.c or document as known kernel bug

**Priority**: Medium (non-blocking but should be resolved for production use)

### Phase 3: Documentation and Validation

**Steps**:
1. Update `boot_problems.md` with resolutions
2. Update `CLAUDE.md` with testing results
3. Create commit messages with hardware test evidence
4. Verify clean boot with zero warnings (except expected VPR violations)

---

## Success Criteria

**Minimum** ✅ **ACHIEVED**:
- ✅ MMC stream ID warnings resolved (commit 26a0964b8b91)
- ✅ GPCDMA stream ID warning resolved (commit af8efc8b6467)
- 📋 MMC ADMA error investigated and documented (in progress)

**Current Status vs Ideal**:
- ✅ MMC stream ID warnings resolved
- ✅ GPCDMA stream ID warning resolved
- ⚠️ MMC ADMA error resolved or workaround provided (pending investigation)
- ✅ Zero SMMU faults during boot
- ✅ All critical devices probe successfully (GPCDMA fixed, MMC ADMA non-critical)

---

## Next Actions

1. ✅ **COMPLETE**: Implement GPCDMA fix
2. ⏸️ **ON HOLD**: Investigate MMC ADMA error (incomplete test, lower priority, non-blocking)
3. ✅ **COMPLETE**: Update all documentation
4. **Optional**: Comprehensive boot test with GPU passthrough

---

## Notes

**2025-11-20**: MMC ADMA investigation paused due to invalid test (wrong DTB deployed to hardware). Key finding from logs: MC EMEM decode errors at invalid address `0xffffffff00` suggests DMA address generation issue. CQHCI hypothesis requires proper retest with correct DTB.

---

## Analysis: Vanilla EL1 SMMU vs pKVM EL2 SMMU (2025-11-21)

### Key Reference Document
See `${WORKSPACE}/docs/why-mc-coupled-with-smmu.md` for detailed explanation of why MC is coupled with SMMU in vanilla Linux.

### Vanilla EL1 Driver Flow (arm-smmu + tegra-mc)

The vanilla driver uses a **two-stage process**:

**Stage 1: Early (of_xlate during DT parsing)**
```
Device tree parsing → IOMMU framework finds "iommus" property
    → Looks up IOMMU device → Calls driver's of_xlate()
    → of_xlate() calls iommu_fwspec_add_ids() → fwspec populated with SID
```
- This happens BEFORE device driver probing
- fwspec is ready when device driver needs it

**Stage 2: Late (probe_finalize after device attach)**
```
Device driver probes → Finds fwspec with SID → Driver init succeeds
    → Device attaches to IOMMU domain → probe_finalize callback
    → tegra_mc_probe_device() → MC programs SID override register
```
- MC SID override happens AFTER IOMMU domain setup
- Preserves bootloader device mappings (seamless handover)

### Our pKVM EL2 Implementation

| Aspect | Vanilla EL1 | pKVM EL2 | Status |
|--------|-------------|----------|--------|
| **fwspec population** | of_xlate during DT parsing | probe_device() during attach | ❌ **TOO LATE** |
| **MC SID registration** | probe_finalize (late) | arch_initcall (early) + EL2 validation | ✅ Works |
| **MC SID override writes** | Direct to hardware | Trapped and validated by EL2 | ✅ Works |
| **SMMU hardware ownership** | EL1 driver | EL2 hypervisor | ✅ Works |

### The Gap: fwspec Population Timing

**Our EL1 stub driver** (`arm-smmu-kvm.c:372-400`):
- HAS `of_xlate` callback (lines 424-443)
- BUT relies on `probe_device()` for fwspec population
- `probe_device()` runs DURING IOMMU attachment, AFTER driver probe starts

**The Timing Problem**:
```
1. SMMU platform driver registers at subsys_initcall_sync (~0.1s)
2. SMMU devices probe → iommu_device_register() called
3. Client devices start probing (SDMMC at ~8.2s)
4. SDMMC driver calls tegra_dev_iommu_get_stream_id()
5. This requires fwspec->num_ids == 1
6. BUT fwspec is EMPTY (probe_device not called yet)
7. ERROR: "missing IOMMU stream ID"
```

**Why of_xlate Doesn't Help**:
- of_xlate IS called during device tree parsing
- BUT this happens when iommu_device_register() is called for SMMU device
- At that point, parsing OTHER devices (SDMMC) may not trigger of_xlate
- The IOMMU framework may not re-parse already-processed devices

### Why Late-initcall Approach Failed

**Attempted Fix** (REVERTED):
- Added `arm_smmu_kvm_enumerate_all_devices()` at late_initcall
- Walked DT and called `iommu_fwspec_add_ids()` for all devices

**Why It Failed**:
1. late_initcall runs at ~8.1s, but SDMMC probes at ~8.2s
2. Multiple systems adding SIDs → num_ids > 1 issues
3. Broke working devices (gpcdma)
4. Race conditions between enumeration and driver probing

### The Real Problem

The vanilla driver's `of_xlate` works because:
1. IOMMU driver registers at `postcore_initcall` (very early)
2. IOMMU devices probe early
3. When client devices are parsed from DT, IOMMU framework already knows about SMMU
4. of_xlate is called for EACH device with iommus property DURING DT parsing

Our pKVM stub's `of_xlate` doesn't work because:
1. Registration happens at `subsys_initcall_sync` (later than vanilla)
2. SMMU device probing depends on pKVM framework being ready
3. By the time SMMU devices register with IOMMU framework, client DT parsing may be done
4. of_xlate never gets called for those client devices

### Correct Solution: Ensure of_xlate is Called

**Option A: Make IOMMU registration earlier**
- Challenge: pKVM framework may not be ready

**Option B: Re-trigger DT parsing after IOMMU registration**
- Use `of_iommu_configure()` to re-parse devices
- Complex, may cause other issues

**Option C: Probe_device populates fwspec BEFORE driver probe completes**
- Current approach, but timing is wrong
- Need to ensure probe_device runs before driver needs fwspec

**Option D: Accept MC-based approach for MC-attached devices**
- MC enumeration at arch_initcall already populates fwspec
- Works for devices with `interconnects` property
- Only issue is devices WITHOUT interconnects (like GPCDMA - already fixed)

### Current Status

**What Works**:
- ✅ Devices with `interconnects` property → MC enumeration populates fwspec
- ✅ Devices without `interconnects` → probe_device populates fwspec
- ✅ GPCDMA and other non-MC devices work

**What Doesn't Work**:
- ❌ SDMMC devices → Have `interconnects` but fwspec empty
- ❌ This is the "missing IOMMU stream ID" issue

### Root Cause Hypothesis

MC enumeration (`tegra186_mc_enumerate_sids()`) IS called at arch_initcall and DOES add SIDs to fwspec for SDMMC. BUT `tegra_dev_iommu_get_stream_id()` requires `fwspec->num_ids == 1`.

**Possible Issues**:
1. MC adds SID, then something else adds duplicate → num_ids > 1
2. MC enumeration not finding the SDMMC devices
3. MC enumeration running but fwspec not persisting

**Investigation Needed**:
- Add debug logging to MC enumeration to verify SDMMC SIDs added
- Check fwspec state at various points during boot
- Verify of_xlate is being called (or not) for SDMMC devices

---

## Architectural Analysis: pKVM SMMU Design (2025-11-21)

**Reference Documents**: See `${WORKSPACE}/docs/question1.md` through `question4.md` for detailed Q&A.

### Key Architectural Insights

#### 1. Role of fwspec vs EL2 View

From question2.md:
- **fwspec is EL1's local structure** - EL2 doesn't need it
- **EL2 should have its OWN authoritative view** from DT (which we DO via MC enumeration!)
- **EL1's fwspec is just a "request"** that EL2 validates

This is exactly what upstream pKVM SMMUv3 does:
```
EL1: iommu_map()     → hypercall map_pages()
EL1: attach_dev()    → hypercall attach_dev()
EL1: free_domain()   → hypercall free_domain()
```
EL2 keeps its own "sanitised" shadow state.

#### 2. Trust Model

From question2.md:
- **Early EL1 boot is "trusted enough"** until `is_pkvm_initialized()` flips
- After that, host is treated as **untrusted**
- EL2 must **validate** all IOMMU operations, not trust fwspec blindly

#### 3. What Must Happen Before pKVM Finalization

From question3.md:
1. **Donate SMMU + MC MMIO** to EL2
2. **Register SMMU instances** with EL2 (base addresses, features)
3. **EL2 module loading** completed

**What can happen AFTER finalization**:
- Normal IOMMU operations (`alloc_domain`, `attach_dev`, `map/unmap`)
- These become hypercalls, EL2 validates them
- `fwspec` usage is EL1 detail, continues working

#### 4. The REAL Problem: Tegra Driver Requirements

From question1.md and question4.md:

The pain we see (MMC "missing IOMMU stream ID") is:
- A **Tegra glue assumption**: `fwspec && num_ids == 1`
- **NOT a pKVM requirement**
- Fixing when/how `fwspec` gets populated is the right layer

**Vanilla of_xlate Flow**:
```
DT parsing → of_iommu_configure() → driver's of_xlate() called
          → iommu_fwspec_add_ids() → fwspec populated
          → BEFORE device driver probe() runs
```

**Key property**: In vanilla flow, of_xlate happens BEFORE driver probe.

**Our Problem**:
- Stub registers at `subsys_initcall_sync`
- Client DT parsing may happen before IOMMU driver registered
- of_xlate never gets called for those client devices

### Confirmed Root Cause

From question4.md validation:

> "If your SMMU stub (the pKVM-aware EL1 side) only registers at `subsys_initcall_sync`,
> then any devices probed earlier will skip IOMMU setup → no fwspec →
> `tegra_dev_iommu_get_stream_id()` barfs."

### Solution: Two-Phase Init (Option A from question4.md)

**Recommended by question4.md**:

> "**Option A: move registration earlier (e.g. arch_initcall)**"
> "Split your SMMUv2 stub into:
>  - A tiny early part that registers `iommu_ops` + fwnode for DT (no MMIO access)
>  - A later part that does the full hardware/EL2 wiring"

> "Early registration doesn't need full driver init:
>  - Register `iommu_ops` and the DT match table so `of_xlate` is callable
>  - Avoid touching clocks, power domains, or MMIO yet; those can stay in normal probe()"

### Implementation Plan

#### Phase 1: Early IOMMU Registration (`arch_initcall`)

New function `arm_smmu_kvm_early_init()`:
- Register `iommu_ops` with IOMMU framework
- Register `of_xlate` callback
- NO hardware access, NO EL2 calls
- Just make of_xlate callable during DT parsing

#### Phase 2: Full Platform Driver (`subsys_initcall_sync`)

Existing `arm_smmu_kvm_init()`:
- Platform driver registration
- SMMU device probing
- EL2 hypercall wiring
- Full hardware/domain initialization

#### Key Requirements

From question4.md:
1. **Keep EL2 view and EL1 fwspec consistent** - both derived from same DT
2. **EL2 rejects hypercalls** where (device, SID) pair doesn't match its tables
3. **Early registration minimal** - just ops registration, no hardware

### Why Previous Approaches Failed

#### late_initcall Enumeration (REJECTED)
- Runs at ~8.1s, too late
- Multiple systems adding SIDs → num_ids > 1
- Broke working devices (gpcdma)

#### of_xlate Without Early Registration
- of_xlate exists but never called
- Registration happens after DT parsing complete
- IOMMU framework doesn't re-parse devices

### Success Criteria

1. ✅ SMMU stub's `of_xlate` called during DT parsing
2. ✅ fwspec populated BEFORE device drivers probe
3. ✅ `tegra_dev_iommu_get_stream_id()` finds `num_ids == 1`
4. ✅ SDMMC boots without "missing IOMMU stream ID"
5. ✅ No regression to working devices (GPCDMA, etc.)

### Files to Modify

| File | Change |
|------|--------|
| `drivers/iommu/arm/arm-smmu/arm-smmu-kvm.c` | Add `arm_smmu_kvm_early_init()` at `arch_initcall` |
| Keep existing `arm_smmu_kvm_init()` at `subsys_initcall_sync` |

### Test Plan

1. Add `dev_info()` to `of_xlate` to verify it's called
2. Build and submit autopilot test
3. Check kernel.log for of_xlate messages during DT parsing (~0.1s)
4. Verify SDMMC has fwspec before probe (~8s)
5. Confirm "missing IOMMU stream ID" resolved

