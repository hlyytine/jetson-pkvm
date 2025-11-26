# Kernel 6.17+ Compatibility

This document tracks compatibility fixes needed for running NVIDIA's out-of-tree drivers with Linux kernel 6.17 and later.

## Overview

The Android common kernel (android15-6.6.66_r00) and mainline kernels 6.17+ introduce API changes that require modifications to NVIDIA's out-of-tree drivers.

## DRM API Changes

### drm_helper_mode_fill_fb_struct() Signature Change

In kernel 6.17+, `drm_helper_mode_fill_fb_struct()` now requires a `drm_format_info` parameter.

**Modified Files:**

| File | Change |
|------|--------|
| `nvdisplay/kernel-open/nvidia-drm/nvidia-drm-fb.h` | Added conditional `drm_format_info` parameter |
| `nvdisplay/kernel-open/nvidia-drm/nvidia-drm-fb.c` | Updated `nv_drm_framebuffer_create()` and `drm_helper_mode_fill_fb_struct()` calls |

## host1x Symbol Conflicts

### Problem

The upstream kernel's `CONFIG_TEGRA_HOST1X` driver conflicts with NVIDIA's out-of-tree host1x driver. Both export the same symbols, causing build failures.

### Solution

**Kernel Configuration:**
```
CONFIG_TEGRA_HOST1X=n
```

This is configured in the defconfig. NVIDIA's OOT host1x (from `nvidia-oot`) provides extended APIs required by nvdisplay that the upstream driver doesn't have.

### Build System Workaround

The `source/Makefile` includes logic to:
1. Filter host1x symbols from `Module.symvers` to avoid conflicts
2. Exclude `*.ko` files during header sync

## Ethernet Driver Compatibility

For non-5.15 kernels, the Ethernet driver Makefile needs adjustment:

```bash
# Fix Ethernet driver build for non-5.15 kernels
sed -i -e 's/^.*5\.15.*$/ifeq (1,1)/' ${LDK_DIR}/source/nvidia-oot/drivers/net/ethernet/Makefile
```

## Bluetooth HCI API Changes (Kernel 6.16+)

### hci_dev quirks → quirk_flags Rename

In kernel 6.16 (commit `6851a0c228fc`), `struct hci_dev` member `quirks` was renamed to `quirk_flags` and the `hci_set_quirk()` helper was introduced.

**Affected Driver:** `nvidia-oot/drivers/bluetooth/realtek/`

**Fix in `rtk_bt.h`:**
```c
/* Kernel 6.16+ renamed hci_dev->quirks to hci_dev->quirk_flags and added hci_set_quirk() */
#if HCI_VERSION_CODE >= KERNEL_VERSION(6, 16, 0)
#define rtk_set_quirk(hdev, nr) hci_set_quirk(hdev, nr)
#else
#define rtk_set_quirk(hdev, nr) set_bit((nr), &(hdev)->quirks)
#endif
```

**Fix in `rtk_bt.c`:** Replace all instances of:
```c
set_bit(HCI_QUIRK_*, &hdev->quirks);
```
with:
```c
rtk_set_quirk(hdev, HCI_QUIRK_*);
```

### hci_evt_le_big_sync_established Typo Fix

**Affected File:** `nvidia-oot/drivers/bluetooth/realtek/rtk_coex.c`

The driver had a typo `hci_evt_le_big_sync_estabilished` (note the extra 'i') which doesn't match the kernel's `hci_evt_le_big_sync_established`.

**Fix:** Correct the spelling in `rtk_coex.c:2433`:
```c
- struct hci_evt_le_big_sync_estabilished *ev = p;
+ struct hci_evt_le_big_sync_established *ev = p;
```

## Future Compatibility Notes

As kernel versions advance, additional compatibility issues may arise. Document new issues and their solutions here.

### Tracking New Issues

When encountering a new compatibility issue:

1. Identify the kernel commit that introduced the change
2. Document the API difference
3. Implement conditional compilation using kernel version macros
4. Test with both old and new kernel versions
5. Add the fix to this document
