# nvgpu ACR Boot Failure Investigation

## Problem Summary

After fixing the SMMU numpage bug, the system boots but **nvgpu ACR (Authenticated Code Runner) fails**:

```
nvgpu: 17000000.gpu nvgpu_acr_wait_for_completion:140 [ERR] flcn-1: HS ucode boot failed, err 1b
nvgpu: 17000000.gpu nvgpu_acr_wait_for_completion:142 [ERR] flcn-1: Mailbox-1 : 0xabcd1234
nvgpu: 17000000.gpu nvgpu_pmu_report_bar0_pri_err_status:41 [ERR] PMU falcon bar0 timeout
```

### Error Interpretation

| Error | Meaning |
|-------|---------|
| `err 1b` (0x1b = 27) | `ACR_ERROR_REG_ACCESS_FAILURE` - Falcon can't access GPU registers |
| `Mailbox-1: 0xabcd1234` | Sentinel value indicating ACR **never started** (firmware didn't run) |
| `bar0 timeout` | PMU falcon cannot access GPU MMIO via BAR0 |

### Root Cause Hypothesis

~~The GPU's DMA is blocked because the SMMU is configured to FAULT mode for unmapped streams.~~

**UPDATE (2025-12-03):** The SMMU hypothesis was **DISPROVEN**. ACR fails with pKVM enabled even when `CONFIG_ARM_SMMU_V2_PKVM=n` (no SMMU trapping). This means **pKVM itself is blocking something the GPU needs**, independent of SMMU configuration.

---

## Critical Finding: pKVM is the Root Cause

**ACR fails when `kvm-arm.mode=protected` is set, regardless of SMMU driver configuration.**

This was tested with:
- `CONFIG_ARM_SMMU_V2_PKVM=y` → ACR fails
- `CONFIG_ARM_SMMU_V2_PKVM=n` → ACR still fails

**Conclusion:** The issue is NOT caused by our pKVM SMMU driver. pKVM's core memory protection or stage-2 page tables are blocking something the GPU/falcon needs.

### Likely pKVM Causes (Updated per Expert Analysis)

**The GPU never reaches SMMU at all.** The failure happens earlier in the boot chain:

1. **BPMP IPC blocked** - GPU power sequencing relies on BPMP MRQ interface (MRQ_GPU_POWER, MRQ_CLK_SET)
2. **PMC/CAR registers blocked** - GPU clock/reset control registers may be trapped by pKVM
3. **MC firewall** - Per-SID access control separate from SMMU may block GPU fabric access
4. **Falcon never released from reset** - If BPMP can't receive power-on requests, falcon stays dark

**Key Evidence:**
- `Mailbox-1: 0xabcd1234` = Sentinel value, ACR never executed a single instruction
- `bar0 timeout` = GPU fabric is "dark" (not powered/clocked)
- No SMMU faults anywhere = Traffic never reaches SMMU

---

## Expert Analysis Summary

See `docs/nvgpu_acr_2.md` for full expert analysis.

### GPU Boot Flow (What Must Happen Before ACR)

1. **BPMP powers GPU rails** ← If blocked, everything fails
2. **BPMP ungates GPU clocks** ← If blocked, falcon stays dark
3. **BPMP releases falcon resets** ← If blocked, BAR0 timeout
4. Host writes to `gpu->ops.pmu.prepare_boot()`
5. Falcon internal ROM code runs
6. Falcon MMIO window becomes active
7. **Only now** does ACR DMA anything

If steps 1-3 are blocked by pKVM, we get exactly our symptoms.

### What to Investigate

| Register Range | Purpose | If Blocked |
|----------------|---------|------------|
| BPMP IPC mailbox | Power/clock requests | GPU never powers on |
| PMC (Power Mgmt Controller) | Reset control | Falcon stays in reset |
| CAR (Clock And Reset) | Clock gating | GPU clocks disabled |
| MC SID registers | Per-SID access control | Bus fabric drops transactions |

---

## Technical Background

### GPU SMMU Configuration on Tegra234

1. **GPU has NO `iommus` property** in device tree
   - Uses `interconnects` property for bandwidth management only
   - NOT managed by Linux IOMMU framework

2. **GPU SID (Stream ID) is set by firmware** (MB1/MB2 bootloader)
   - NOT configured by Linux MC driver
   - Stream ID is pre-assigned before Linux boots

3. **Default SMMU behavior** (with `CONFIG_ARM_SMMU_DISABLE_BYPASS_BY_DEFAULT=y`):
   - sCR0.USFCFG = 1 (unmapped streams fault)
   - All S2CRs set to TYPE=FAULT (0x00020000)

### SMMU Stream Matching Flow

When a DMA transaction arrives at the SMMU:

```
1. Stream ID arrives from device
2. SMMU checks ALL SMR (Stream Match Register) entries
3. If SMR[i].valid && SMR[i] matches SID:
   → Use S2CR[i] to determine action (TRANSLATE/BYPASS/FAULT)
4. If NO SMR matches:
   → Check sCR0.USFCFG:
     - USFCFG=1: FAULT immediately
     - USFCFG=0: BYPASS (allow without translation)
```

### Key Insight

The GPU's firmware-assigned SID doesn't match any SMR entry because:
- GPU is not registered with IOMMU framework
- No SMR is programmed for GPU's SID
- Therefore, GPU transactions are treated as "unmapped"

When USFCFG=1 or S2CR=FAULT, GPU DMA fails → ACR can't run.

---

## Fixes Applied

### Fix 1: S2CR FAULT Rejection (Implemented)

**Location:** `drivers/iommu/arm/arm-smmu/pkvm/arm-smmu-v2.c` (S2CR handler)

**Problem:** EL1 driver's `arm_smmu_device_reset()` sets ALL S2CRs to FAULT mode.

**Solution:** In EL2 S2CR handler, reject FAULT mode for streams where SMR is invalid:

```c
if (requested_type == S2CR_TYPE_FAULT && !smmu->smrs_shadow[idx].valid) {
    /* Keep BYPASS mode, ignore host's FAULT request */
    HYP_INFO("S2CR[%u]: Rejecting FAULT for unmanaged stream, keeping BYPASS\n", idx);
    return 0;  /* Pretend write succeeded */
}
```

**Status:** ✅ Working (confirmed via hyp.log showing 755+ rejection messages)

### Fix 2: USFCFG Clearing (Implemented)

**Location:** `drivers/iommu/arm/arm-smmu/pkvm/arm-smmu-v2.c` (sCR0 handler)

**Problem:** sCR0.USFCFG bit causes unmapped streams to fault BEFORE S2CR is checked.

**Solution:** In EL2 sCR0 handler, always clear USFCFG:

```c
/* Always clear USFCFG to allow unmapped streams to bypass */
val32 &= ~ARM_SMMU_sCR0_USFCFG;
```

**Status:** ✅ Working (confirmed via hyp.log showing "USFCFG SET->CLEAR" or "CLEAR->CLEAR")

---

## Test Results

### Test 20251203092805

- S2CR FAULT rejection: Working (755 rejections logged)
- USFCFG clearing: Added debug logging to verify
- ACR: Still failing with error 0x1b

### Test 20251203093327

- S2CR FAULT rejection: Working
- USFCFG clearing: Confirmed working
  ```
  [hyp-info] sCR0 write: host=0x00201807 -> modified=0x00201837 (USFCFG CLEAR->CLEAR)
  ```
- ACR: **Still failing** with same error

### Observations

Both fixes are confirmed working via hyp.log, but ACR still fails. This suggests:
1. There's another mechanism blocking GPU DMA, OR
2. The GPU uses a different SMMU instance, OR
3. The issue is not SMMU-related at all

---

## Investigation Areas (Not Yet Explored)

### 1. Different SMMU Instance?

Tegra234 has multiple SMMUs:
- ISO SMMU (for isochronous clients like display)
- NISO SMMU (for non-isochronous clients)

Question: Which SMMU does the GPU use? Are we trapping the right one?

### 2. Memory Controller (MC) SID Validation

The Tegra MC has its own SID validation separate from SMMU. If MC rejects the SID, transactions never reach SMMU.

### 3. SMMU Global Faults

No GFSR (Global Fault Status Register) messages seen in hyp.log. This could mean:
- No faults occurring (SMMU not involved)
- Fault logging not enabled
- Faults happening on different SMMU instance

### 4. Context Bank Configuration

Even with BYPASS mode, there might be context bank issues if the host driver is doing unexpected configuration.

### 5. GPU Power/Clock Gating

The `bar0 timeout` could indicate the GPU falcon is not powered or clocked properly, independent of SMMU.

### 6. ACR Firmware Loading

The `Mailbox-1: 0xabcd1234` sentinel suggests the ACR firmware didn't even start executing. This could be:
- DMA to load firmware failed
- Falcon boot sequence failed
- Power sequencing issue

---

## Key Code Locations

### EL2 SMMU Driver (pKVM)

| Location | Description |
|----------|-------------|
| `arm-smmu-v2.c:772` | S2CR initialization (sets BYPASS) |
| `arm-smmu-v2.c:442` | Reset writes BYPASS to hardware |
| `arm-smmu-v2.c:953-991` | S2CR handler (traps host writes) |
| `arm-smmu-v2.c` (sCR0 handler) | Clears USFCFG bit |

### EL1 SMMU Driver (Host)

| Location | Description |
|----------|-------------|
| `arm-smmu.c:arm_smmu_device_reset()` | Sets all S2CRs to FAULT mode |
| `arm-smmu.c` | Standard upstream ARM SMMU driver |

### nvgpu Driver

| Location | Description |
|----------|-------------|
| `nvgpu_acr_wait_for_completion()` | Reports error 0x1b |
| `nvgpu_pmu_report_bar0_pri_err_status()` | Reports bar0 timeout |
| `ga10b_bootstrap_hs_acr()` | ACR bootstrap entry point |

---

## Related Documentation

- `docs/smmuv2_pkvm.md` - pKVM SMMUv2 implementation details
- `docs/boot_problems.md` - General boot troubleshooting
- `drivers/iommu/arm/arm-smmu/CLAUDE.md` - SMMU driver internals

---

## Debug Log Analysis

### hyp.log Key Messages

```
# S2CR FAULT rejections (Fix 1 working)
[hyp-info] S2CR[0]: Rejecting FAULT for unmanaged stream
[hyp-info] S2CR[1]: Rejecting FAULT for unmanaged stream
... (128 entries, twice = 256 total for two SMMUs)

# sCR0 USFCFG clearing (Fix 2 working)
[hyp-info] sCR0 write: host=0x00201c36 -> modified=0x00201836 (USFCFG SET->CLEAR)
```

### kernel.log Key Messages

```
# ACR failure (problem persists)
nvgpu: 17000000.gpu nvgpu_acr_wait_for_completion:140 [ERR] flcn-1: HS ucode boot failed, err 1b
nvgpu: 17000000.gpu nvgpu_acr_wait_for_completion:142 [ERR] flcn-1: Mailbox-1 : 0xabcd1234
nvgpu: 17000000.gpu acr_report_error_to_sdl:53 [ERR] ACR register access failure
nvgpu: 17000000.gpu nvgpu_pmu_report_bar0_pri_err_status:41 [ERR] PMU falcon bar0 timeout
```

---

## Next Steps

### Priority 1: Investigate pKVM Memory Protection

Since ACR fails even without our SMMU driver, focus on pKVM core:

1. **Check GPU memory carveouts** - GPU uses reserved memory regions (VPR, GSP carveout)
   - Look at device tree `memory-region` and `nvidia,memory-aperture` properties
   - Check if pKVM maps these regions for host access

2. **Verify stage-2 mappings for GPU regions**
   - GPU MMIO: 0x17000000-0x18ffffff
   - Syncpoint shim: 0x60000000
   - GPU carveout memory (varies)

3. **Check pKVM hyp_memblock handling**
   - Does pKVM correctly handle `reserved-memory` nodes?
   - Are firmware-reserved regions accessible?

4. **Test with `kvm-arm.mode=nvhe`** (non-protected mode)
   - If ACR works with nvhe but not protected, confirms pKVM memory protection is the issue

### Priority 2: SMMU Fixes (Already Working)

These fixes are confirmed working but don't solve the ACR issue:
- ~~Verify which SMMU the GPU uses~~
- ~~Add GFSR monitoring~~
- ~~Check MC SID validation~~

### Priority 3: Alternative Approaches

1. **Add GPU memory regions to pKVM whitelist** - If pKVM has a mechanism to share memory with host
2. **Disable GPU during pKVM development** - Focus on other subsystems first
3. **Check nvgpu source for pKVM compatibility** - May need nvgpu driver modifications

---

---

## SSH Investigation (2025-12-03)

### Test Setup
- Kernel 6.17.0-tegra with `CONFIG_ARM_SMMU_V2_PKVM=y`
- nvgpu blacklisted via `/etc/modprobe.d/blacklist-nvgpu.conf`
- System boots successfully to shell with pKVM enabled

### Key Findings

#### 1. GPU Clocks Are Enabled
```
host1x:     state=1, rate=204MHz
gpu_pwr:    state=1, rate=204MHz
gpusysclk:  state=1, rate=1300.5MHz
gpc0clk:    state=1, rate=1300.5MHz
gpc1clk:    state=1, rate=1300.5MHz
nafll_gpusys: state=1, rate=1300.5MHz
```
Clocks are correctly enabled by BPMP.

#### 2. GPU MMIO Responds
```
GPU Boot0 (0x17000000): 0xB7B000A1 (GA10B chip ID - correct!)
```
CPU can read GPU MMIO through pKVM stage-2 mapping.

#### 3. GPU Internal Engines Return 0xBADFxxxx
**CRITICAL FINDING**: GPU engine registers return error patterns:
```
NV_PGRAPH_STATUS:     0xBADF5040
GSP_FALCON_CPUCTL:    0xBADF5620
GSP_FALCON_IDLESTATE: 0xBADF5620
PMU_FALCON_CPUCTL:    0xBADF5720
```
The `0xBADF` prefix indicates registers are **inaccessible** - engines are power-gated or clock-gated.

#### 4. PRIV_RING Error Present
```
PRIV_RING_ERROR_CODE: 0x00000001 (BAD_ADR - invalid address)
PRIV_RING_ERROR_ADR:  0x00000002
```
Internal GPU priv ring reports address error. This is the internal bus falcons use to access GPU registers.

#### 5. No SMMU Faults
```
SMMU[0] GFSR: 0x00000000
SMMU[1] GFSR: 0x00000000
SMMU[2] GFSR: 0x00000000
```
No SMMU global faults. GPU DMA isn't even reaching SMMU (blocked earlier).

#### 6. GPU SID Not Configured
```
MC_SID_STREAMID_OVERRIDE_CONFIG_GPUSRD:  0x00000000
MC_SID_STREAMID_OVERRIDE_CONFIG_GPUSWR:  0x00000000
MC_SID_STREAMID_OVERRIDE_CONFIG_GPUSRD2: 0x00000000
MC_SID_STREAMID_OVERRIDE_CONFIG_GPUSWR2: 0x00000000
```
GPU SID override not enabled - using default firmware SID.

### Root Cause Analysis

The `0xBADFxxxx` pattern reveals GPU engine registers are **inaccessible**.

**Important insight (user feedback):** Engine-level power gating (ELPG) is controlled by **BPMP**, not direct GPU register writes. The CPU sends MRQ requests to BPMP to release engine power gates.

**What we verified:**
- GPU power domain (genpd): **ON** - BPMP successfully powered GPU
- GPU clocks (gpusysclk, gpc0clk, etc.): **Enabled** via BPMP
- GPU Boot0 register: **0xB7B000A1** (valid chip ID) - basic MMIO works
- Engine registers (PMU, GSP, PGRAPH): **0xBADFxxxx** - inaccessible

**What this suggests:**
1. **Top-level GPU power**: ✓ Working (BPMP responds correctly)
2. **Engine-level power (ELPG)**: ✗ NOT released
3. **Priv ring fabric**: ✗ Not initialized (ERROR_CODE=1)

The sequence should be:
1. BPMP powers GPU domain ✓
2. BPMP enables GPU clocks ✓
3. **nvgpu requests ELPG release via BPMP MRQ** ← Fails here?
4. nvgpu initializes priv ring
5. ACR firmware loads and runs

### Key Question

Why isn't nvgpu successfully getting BPMP to release engine power gates?

Possibilities:
1. **BPMP MRQ for ELPG is blocked/failing** (but no error visible in dmesg)
2. **Prerequisite step missing** before ELPG can work
3. **Timing/ordering issue** in power sequencing
4. **pKVM blocking something** in the BPMP communication path

### Implication

This is NOT an SMMU/DMA issue (no SMMU faults). The problem is in GPU internal power sequencing:
- Top-level power: ✓ Working
- Engine power gates: ✗ NOT released (0xBADFxxxx)
- ACR never runs because engines aren't powered

### Next Investigation Steps

1. **Study nvgpu power-on sequence** - What writes to NV_PMC_ENABLE?
2. **Compare NV_PMC_ENABLE with working boot** - What value should it have?
3. **Check if pKVM traps MMIO writes** - Are NV_PMC_ENABLE writes being trapped?
4. **Investigate engine-level power gating** - How are individual engines released from power gate?

---

## Changelog

| Date | Change |
|------|--------|
| 2025-12-03 | **SSH Investigation**: Discovered GPU engines return 0xBADFxxxx (power-gated/inaccessible) |
| 2025-12-03 | Fixed build: Guard MC hypercall with CONFIG_ARM_SMMU_V2_PKVM |
| 2025-12-03 | Investigated nvhe boot issue - requires manual device testing |
| 2025-12-03 | **CRITICAL**: Discovered ACR fails even without CONFIG_ARM_SMMU_V2_PKVM - pKVM itself is the cause |
| 2025-12-03 | Added USFCFG clearing fix, confirmed both fixes working, ACR still fails |
| 2025-12-02 | Implemented S2CR FAULT rejection fix |
| 2025-12-02 | Initial investigation, identified S2CR override issue |
