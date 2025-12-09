# nvgpu ACR Boot Failure Investigation

## Problem Statement

nvgpu ACR (Authenticated Code Runner) fails to boot on Tegra234 with pKVM enabled:

```
nvgpu: 17000000.gpu flcn-1: HS ucode boot failed, err 1b
nvgpu: 17000000.gpu Mailbox-1 : 0xabcd1234
nvgpu: 17000000.gpu PMU falcon bar0 timeout
```

**SMMU is confirmed NOT the cause** - fixes verified working but ACR still fails.

---

## Root Cause Analysis

### Error Decoding

| Value | Meaning |
|-------|---------|
| `err 1b` | `ACR_ERROR_REG_ACCESS_FAILURE` (0x1B) - GSP BROM detected register access failure |
| `Mailbox-1: 0xabcd1234` | Sentinel value unchanged - ACR code never executed |
| `bar0 timeout` | GPU engine registers not responding |

### Key Insight

The sentinel value in Mailbox-1 indicates ACR code **never ran**, BUT GSP BROM **did execute** (it wrote error 0x1B to Mailbox-0). This means:

1. GSP falcon was reset and started
2. GSP BROM executed successfully
3. BROM tried to access GPU registers but they returned 0xBADFxxxx (powergated)
4. BROM wrote error code and halted before loading ACR

### Evidence

**From SSH investigation on live system:**
- GPU Boot0 register (0x17000000): Reads `0xB7B000A1` (valid chip ID) - fabric alive
- GPU engine registers: Return `0xBADFxxxx` (powergated)
- genpd summary: GPU domain "on" but device stuck in "resuming"

**From kernel log:**
- 28.533s: `nvgpu_nvhost_syncpt_init` - syncpt setup OK
- 28.533s-32.326s: 4-second gap (matches `ACR_BOOT_TIMEOUT_MS`)
- 32.326s: ACR fails with err 0x1B

### Conclusion

**GPU power domain is ON at the genpd level, but GPU engines remain power-gated.**

The pm_runtime resume callback doesn't complete properly before ACR boot attempts.

---

## Power-On Sequence Analysis

### Expected Flow

```
pm_runtime_get_sync()
  └── genpd powers GPU domain via BPMP (TEGRA234_POWER_DOMAIN_GPU)
  └── gk20a_pm_runtime_resume()
        └── gk20a_pm_unrailgate()
              └── ga10b_tegra_unrailgate()
                    ├── ga10b_tegra_bpmp_mrq_set() - static PG masks
                    └── gp10b_tegra_clks_control() - enable clocks
        └── gk20a_pm_finalize_poweron()
              └── nvgpu_early_poweron()
                    └── priv_ring.enable_priv_ring()
              └── nvgpu_finalize_poweron()
                    └── acr.acr_construct_execute() <-- FAILS HERE
```

### Where It Fails

1. `genpd` reports power domain ON
2. `ga10b_tegra_unrailgate()` enables clocks (succeeds)
3. `priv_ring` enumeration succeeds (no errors in log)
4. ACR boot attempts but GSP BROM can't access engine registers

**The problem is between genpd power-on and engine registers becoming accessible.**

---

## Why SMMU is Irrelevant

- `bar0 timeout` = GPU fabric returns 0xBADF, traffic never leaves GPU
- **No SMMU faults** = Traffic never reaches SMMU
- SMMU fixes confirmed working, ACR still fails

---

## Key Code Locations

### nvgpu Power-On

| File | Function | Purpose |
|------|----------|---------|
| `os/linux/module.c:1377` | `gk20a_pm_runtime_resume()` | pm_runtime resume entry |
| `os/linux/module.c:1235` | `gk20a_pm_unrailgate()` | Calls platform unrailgate |
| `os/linux/module.c:453` | `gk20a_pm_finalize_poweron()` | Main power-on sequence |
| `os/linux/platform_ga10b_tegra.c:472` | `ga10b_tegra_unrailgate()` | GA10B-specific unrailgate |
| `common/init/nvgpu_init.c:933` | `nvgpu_finalize_poweron()` | Init table execution |
| `common/acr/acr_bootstrap.c:234` | `nvgpu_acr_wait_for_completion()` | ACR boot wait |

### ACR Error Codes

From `common/acr/acr_bootstrap.c`:
```c
#define ACR_ERROR_REG_ACCESS_FAILURE 0x1B
```

---

## Device Tree Notes

**DT Warning observed:**
```
OF: /bus@0/gpu@17000000: Read of boolean property 'power-domains' with a value.
```

This is caused by `driver_common.c:354`:
```c
if (!of_property_read_bool(dev->of_node, "power-domains")) {
    platform->can_railgate_init = false;
}
```

Using `of_property_read_bool()` on a phandle property triggers this warning. However, this is just a warning - the function still returns true when the property exists, so it shouldn't cause functional issues.

---

## Hypotheses

### H1: GPU Engine Power Gating Not Released (Most Likely)

The GPU power domain (genpd) is powered, but individual GPU engines remain power-gated. This requires:
- BPMP to release engine-level power gates
- Possibly via a different MRQ than the domain power

**Evidence:**
- genpd shows "on"
- Device stuck in "resuming"
- Engine registers return 0xBADFxxxx

### H2: BPMP MRQ Communication Failure

The `ga10b_tegra_bpmp_mrq_set()` call may be failing silently or BPMP may not be processing it correctly under pKVM.

**Note:** The code handles `-ENODEV` and `-EPERM` as non-fatal:
```c
} else if (ret == -ENODEV) {
    nvgpu_log_info(g, "MRQ is not supported by BPMP-FW");
    ret = 0;  // continues anyway!
}
```

### H3: pKVM Blocking Critical MMIO

pKVM stage-2 may be blocking some MMIO access needed for GPU engine power-up.

**Against this:** No hyp.log faults for GPU range observed.

---

## Next Steps

1. **Add debug logging to power-on path**
   - Log return values from all BPMP MRQ calls
   - Log pm_runtime state transitions
   - Log GPU register reads during unrailgate

2. **Compare with non-pKVM boot**
   - Boot with `kvm-arm.mode=nvhe` if possible
   - Capture GPU init sequence for comparison

3. **Investigate engine-level power gating**
   - Study how individual GPU engines are power-gated
   - Determine if BPMP needs additional MRQ calls
   - Check NVIDIA documentation for engine power sequencing

4. **Check for clock issues**
   - Verify GPU clocks are actually enabled after unrailgate
   - Check clock tree in debugfs if available

---

## Related Failures

### DCE (Display Control Engine) Firmware Abort (2025-12-03)

**Critical Finding:** DCE firmware ABORTS before GPU ACR fails!

**DCE Failure Log:**
```
[25.469s] tegra-dce d800000.dce: WatchdogTaskStartItem failed: 0x07000008
         BUG: /dvs/git/dirty/git-master_linux/display/dce/tasks/AdminCommands.c:438
[25.470s] dce: dce_ipc_channel_init_unlocked:248  Invalid Channel State [0x0] for ch_type [2]
[25.474s] dce: dce_handle_irq_status:253  DCE ucode abort occurred
```

**Admin IPC Timeout (later):**
```
[35.570s] dce: dce_admin_ipc_wait:48   Admin IPC wait, interrupted or timedout:-110
[35.572s] dce: dce_start_boot_flow:185  DCE_BOOT_FAILED: Admin flow didn't complete
```

### Detailed Timeline (2025-12-03)

| Time | Event | Notes |
|------|-------|-------|
| 17.954s | DCE added to IOMMU group 16 | SMMU setup begins |
| 18.094s | DCE attached to SMMU | domain cbndx=7 |
| 18.125s | BPMP firmware initialized | BPMP seems OK |
| **19.806s** | **genpd: Disabling unused power domains** | **POTENTIAL ISSUE** |
| 25.469s | DCE firmware ABORTS | WatchdogTaskStartItem failed |
| 28.533s | nvgpu syncpt_unit_base set | GPU probe starts |
| 32.326s | GPU ACR fails err 0x1B | 4s timeout |
| 35.570s | DCE admin IPC timeout | -110 ETIMEDOUT |

### Key Insight: DCE Firmware Aborts AT PROBE TIME

The DCE firmware error `WatchdogTaskStartItem failed: 0x07000008` is from **DCE firmware source code itself**, not Linux. The error output is **interleaved** with Linux driver probe messages:

```
[   25.469559] tegra-dce d8WatchdogTaskStartItem failed: 0x07000008BUG: /dvs/git/dirty/git-master_linux/display/dce/tasks/AdminCommands.c:438  "
00000.dce: Setting DCE HSP functions for tegra234-dce
```

This shows the firmware error happens at the **exact moment** Linux probes DCE. Sequence:

1. DCE firmware was pre-loaded by bootloader/TOS
2. DCE firmware was running (presumably OK until now)
3. Linux tegra-dce driver probes at 25.469s
4. DCE firmware immediately outputs watchdog task error
5. "Invalid Channel State [0x0]" - IPC channel not initialized
6. DCE firmware aborts
7. GPU ACR fails at 32.3s (7 seconds later)

### Common Pattern: Co-processor Firmware Failures

Both DCE and GPU have embedded microcontrollers running firmware:

| Engine | Firmware | Error | Meaning |
|--------|----------|-------|---------|
| DCE | DCE ucode | WatchdogTaskStartItem failed 0x07000008 | Internal task start failed |
| GPU | GSP BROM | err 0x1B (REG_ACCESS_FAILURE) | Can't access GPU engine registers |

**Both firmwares are running but fail when accessing something.**

### Hypothesis H4: genpd Power Domain Disabled (Less Likely)

The kernel logs `PM: genpd: Disabling unused power domains` at 19.806s, which is:
- AFTER BPMP init (18.125s)
- BEFORE DCE firmware abort (25.469s) - **5.6 second gap**
- BEFORE GPU ACR failure (32.326s)

Originally suspected that DCE/GPU power domains were disabled as "unused". However:
- If power was cut at 19.8s, firmware would have crashed immediately
- DCE firmware crashes at 25.4s when Linux probes it, not at 19.8s
- The 5.6s gap suggests firmware was running fine during that time

**More likely:** Something in the Linux probe sequence triggers the failure.

### Hypothesis H5: Probe Sequence Triggers IPC Failure (Most Likely)

The "Invalid Channel State [0x0] for ch_type [2]" error indicates the IVC/IPC channel isn't initialized properly. This could happen if:

1. **Bootloader didn't set up IPC correctly for Linux** - Different configuration expected
2. **pKVM affects IPC channel setup** - EL2 may interfere with HSP/mailbox access
3. **Driver probe order problem** - DCE expects some other driver to be ready first
4. **Memory carveout issue** - Shared memory region not accessible

**Key detail:** ch_type [2] = admin IPC channel. The firmware expects this channel to be in a ready state, but Linux sees state [0x0] (uninitialized).

### Hypothesis H6: Missing HSP Doorbell/Mailbox Setup

DCE uses HSP (Hardware Synchronization Primitives) for IPC:
- Mailboxes at offsets 0x160000-0x198000 from DCE base
- Semaphores at offsets 0x1a0000-0x1d0000 from DCE base

If HSP isn't set up before DCE firmware expects it, the watchdog task can't start.

**Note:** DCE base is 0xd800000, so HSP mailboxes are at 0xd960000-0xd998000.

### hyp.log Analysis

**No runtime SMMU faults observed!** Only S2CR configuration messages during setup:
```
[hyp-info] S2CR[N]: Rejecting FAULT for unmanaged stream
```

This confirms pKVM is NOT blocking DMA transactions through SMMU. The failures are happening INSIDE the co-processors, not at the SMMU level.

---

## BPMP Driver Comparison (2025-12-03)

### Comparison: NVIDIA 5.15.148 vs Upstream 6.17

**bpmp-abi.h:** Identical (3973 lines) - only typo fixes, no ABI incompatibility.

**bpmp.c differences:**

| Feature | NVIDIA 5.15.148 | Upstream 6.17 |
|---------|-----------------|---------------|
| bpmp-virt hooks | ✓ (`tegra_bpmp_transfer_redirect`) | ✗ Removed |
| Suspend tracking | ✗ No `bpmp->suspended` | ✓ Returns `-EAGAIN` if suspended |
| Mailbox access | Direct `memcpy_fromio/toio` | `iosys_map` abstraction |
| Probe order | `platform_set_drvdata` after init | `platform_set_drvdata` earlier |

**bpmp-tegra186.c differences:**
- Upstream uses `iosys_map` for IVC channel access
- Added DRAM path for reserved memory regions
- Removed BPMP guest proxy hooks

**powergate-bpmp.c:** Nearly identical, only cosmetic API changes.

### Conclusion

The BPMP driver changes are **NOT causing the ACR failure**:
1. ABI is fully compatible
2. Core MRQ protocol unchanged
3. Power domain driver nearly identical
4. BPMP probes successfully at 18.125s
5. genpd message at 19.806s shows power domain management working

The issue is downstream in GPU-internal power gating, not BPMP communication.

---

## Latest Test Results (2025-12-03 17:03)

### Test 20251203170351 - linux617 with pKVM

**Configuration:**
- Kernel: 6.17.0-tegra
- pKVM: Enabled (`kvm-arm.mode=protected`)
- Boot option: 2 (linux617)

**Timeline:**

| Time | Event | Notes |
|------|-------|-------|
| 5.608s | `kvm [1]: pKVM enabled without an IOMMU driver` | pKVM active |
| 5.886s | `PM: genpd: Disabling unused power domains` | Normal |
| **11.585s** | **DCE firmware abort** | `WatchdogTaskStartItem failed: 0x07000008` |
| 21.745s | DCE admin IPC timeout | Error -110 |
| 21.747s | `DCE_BOOT_FAILED: Admin flow didn't complete` | |
| 25.841s | `sync_state() pending due to 17000000.gpu` | **nvgpu NOT loading** |
| ~33s | System reboots | Reboot loop |

**Key Observations:**

1. **nvgpu.ko never loaded** - No ACR errors because module isn't loading
   - `sync_state() pending due to 17000000.gpu` indicates device exists but no driver claimed it
   - OOT modules may not be installed for this boot option

2. **DCE failure is EARLIER** than previous tests (11.5s vs 25.4s)
   - Same `WatchdogTaskStartItem failed: 0x07000008` error
   - Same `Invalid Channel State [0x0] for ch_type [2]` pattern

3. **Reboot loop** - System reboots ~33s after boot
   - No kernel panic visible
   - Clean `reboot: Restarting system` message
   - Possibly watchdog or systemd service triggered

4. **No hyp.log output** - pKVM UART debug not showing output
   - Need to verify hyp serial is configured

**Implications:**

- DCE failure is **independent of nvgpu** - occurs even when nvgpu not loaded
- DCE firmware abort is the **first co-processor failure**
- The issue is in DCE firmware/IPC initialization, not GPU-specific

### Comparison: Previous Test vs Current Test

| Aspect | Previous (20251203093327) | Current (20251203170351) |
|--------|---------------------------|--------------------------|
| DCE abort time | 25.469s | 11.585s |
| nvgpu loads | Yes | No |
| nvgpu ACR error | Yes (err 0x1B) | No (module missing) |
| Reboot loop | No | Yes |
| Boot option | 0 (update) | 2 (linux617) |

The earlier DCE abort (11.5s vs 25.4s) in the current test may be due to different boot timing or module loading sequence.

---

## Test Commands

**Check genpd status:**
```bash
cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
```

**Read GPU Boot0 register:**
```bash
devmem2 0x17000000 w
```

**Check BPMP clock status:**
```bash
cat /sys/kernel/debug/bpmp/debug/clk/gpu/state
```
