# UART and Debug Output on Tegra234

## Overview

This document describes the UART infrastructure for debug output on NVIDIA Jetson AGX Orin (Tegra234) in the context of pKVM (protected KVM) development. The system uses a unified architecture where both EL1 (kernel) and EL2 (hypervisor) share the same physical UART hardware via an enhanced pKVM serial framework.

**Key Facts:**
- **Physical UART**: `0x31d0000` (UARTI on Tegra234)
- **Hardware**: ARM PL011 UART (SBSA-compatible)
- **Baud Rate**: 115200 bps
- **Clock Source**: 408 MHz (Tegra234 PLLP)
- **Usage**: Shared between EL1 kernel console and EL2 hypervisor debug output
- **Framework**: Enhanced pKVM serial framework with printf support

## Architecture: Unified Serial Framework

```
┌─────────────────────────────────────────────────┐
│          Physical UART Hardware                 │
│          Address: 0x31d0000 (UARTI)            │
└────────────┬────────────────────┬───────────────┘
             │                    │
      ┌──────▼──────┐      ┌─────▼────────┐
      │  EL2 Access │      │  EL1 Access  │
      │  (Polling)  │      │ (Interrupts) │
      └──────┬──────┘      └─────┬────────┘
             │                    │
    ┌────────▼────────┐   ┌──────▼──────────┐
    │ Enhanced pKVM   │   │ sbsa-uart       │
    │ Serial Framework│   │ Kernel Driver   │
    │ WITH printf!    │   │                 │
    │ (PRODUCTION)    │   │ (standard TTY)  │
    └─────────────────┘   └─────────────────┘
```

### Coexistence Model

**Both EL1 and EL2 can safely use the same UART because:**
1. **Different access patterns**: EL2 uses polling (busy-wait), EL1 uses interrupts
2. **Different timings**: EL2 outputs during early init or critical hypervisor operations, EL1 during normal kernel operation
3. **Shared hardware**: The PL011 TX FIFO and status registers are designed for multi-master access
4. **No need to disable device node**: The EL1 device tree node can remain enabled (status="okay")

## Enhanced pKVM Serial Framework (Production Solution)

The **official Google/Android pKVM serial infrastructure** has been enhanced with comprehensive printf support and convenience macros, making it suitable for production use.

### Major Enhancement (2025-01)

The framework was significantly enhanced to support printf-style formatting and early initialization:

**What Was Added:**
- `hyp_printf()` with comprehensive format support
- Helper functions: `hyp_dec()`, `hyp_hex()`, `hyp_hex32()`
- Convenience macros: `HYP_INFO()`, `HYP_ERR()`, `HYP_WARN()`, `HYP_DBG()`
- Early UART initialization for SMMU driver (before module loading)

**What Was Removed:**
- Custom `hyp-uart.h` implementation (350 lines, deleted)
- Direct physical address access (replaced with proper EL2 VA mapping)

### Files and Location

```
arch/arm64/kvm/hyp/nvhe/serial.c          # Enhanced core framework (279 lines)
arch/arm64/kvm/hyp/include/nvhe/serial.h  # Enhanced header (50 lines)
drivers/tty/serial/pkvm-pl011/            # PL011 UART module (optional)
├── Kconfig                               # Configuration
├── Makefile                              # Build system
├── pl011-host.c                          # EL1 loader (27 lines)
└── hyp/
    ├── Makefile
    └── pl011-hyp.c                       # EL2 driver (57 lines)
```

### History

- **Original framework**: Commit `d04c2e5b4264` (2022-09-19) by Quentin Perret (Google)
- **Printf enhancement**: 2025-01 - Added comprehensive formatting support
- **Maintenance**: Active, 40+ commits in git history
- **Status**: Production-ready with printf support

### Configuration

```bash
# In arch/arm64/configs/defconfig
CONFIG_SERIAL_PKVM_PL011=m                        # Optional module
CONFIG_SERIAL_PKVM_PL011_BASE_PHYS=0x31d0000      # Tegra234 UARTI
```

The module is **optional** - early initialization can be done directly without it.

### API Reference

#### Basic Output Functions

```c
#include <nvhe/serial.h>

// Print string with automatic newline and carriage return
void hyp_puts(const char *s);

// Print 64-bit hex value (format: "0x%016lx\n\r")
void hyp_putx64(u64 x);

// Print single character
void hyp_putc(char c);
```

#### NEW: Printf-Style Functions

```c
// Print decimal (base 10)
void hyp_dec(u64 val);

// Print 64-bit hex (with 0x prefix)
void hyp_hex(u64 val);

// Print 32-bit hex (with 0x prefix)
void hyp_hex32(u32 val);

// Printf with comprehensive format support
void hyp_printf(const char *fmt, ...) __printf(1, 2);
```

**Supported Format Specifiers:**
- `%s` - String
- `%x` - 32-bit hex
- `%lx` - 64-bit hex (long)
- `%llx` - 64-bit hex (long long, for phys_addr_t)
- `%d/%u` - Decimal (32-bit)
- `%ld/%lu` - 64-bit decimal (long)
- `%lld/%llu` - 64-bit decimal (long long)
- `%zu/%zd` - size_t/ssize_t (decimal)
- `%zx` - size_t (hex)
- `%p` - Pointer (hex with 0x prefix)
- `%c` - Character
- `%%` - Literal %

#### NEW: Convenience Macros

```c
// Categorized logging with automatic prefixes and newlines
#define HYP_DBG(fmt, ...) \
    hyp_printf("[hyp-dbg] " fmt "\n", ##__VA_ARGS__)

#define HYP_INFO(fmt, ...) \
    hyp_printf("[hyp-info] " fmt "\n", ##__VA_ARGS__)

#define HYP_ERR(fmt, ...) \
    hyp_printf("[hyp-err] " fmt "\n", ##__VA_ARGS__)

#define HYP_WARN(fmt, ...) \
    hyp_printf("[hyp-warn] " fmt "\n", ##__VA_ARGS__)
```

#### Driver Registration

```c
// For driver implementors: register UART backend
int __pkvm_register_serial_driver(void (*cb)(char));
```

### How It Works

#### Option 1: Early Direct Initialization (Recommended for SMMU)

For code that runs very early (e.g., SMMU initialization during pKVM init), create a private EL2 mapping directly:

```c
// Example from drivers/iommu/arm/arm-smmu/pkvm/arm-smmu-v2.c

#define EARLY_UART_BASE_PHYS	0x31d0000   /* Tegra234 UARTI */
#define EARLY_UARTDR		0x00
#define EARLY_UARTFR		0x18
#define EARLY_UARTFR_TXFF	(1 << 5)
#define EARLY_UARTFR_BUSY	(1 << 3)

static void __iomem *early_uart_base;

static void early_uart_putc(char c)
{
	if (!early_uart_base)
		return;

	/* Wait until TX FIFO not full */
	while (readl_relaxed(early_uart_base + EARLY_UARTFR) & EARLY_UARTFR_TXFF)
		;

	writel_relaxed(c, early_uart_base + EARLY_UARTDR);

	/* Wait until UART not busy */
	while (readl_relaxed(early_uart_base + EARLY_UARTFR) & EARLY_UARTFR_BUSY)
		;
}

static int smmu_v2_early_uart_init(void)
{
	unsigned long va = 0;
	int ret;

	/*
	 * Create EL2 private mapping for UART MMIO.
	 * __pkvm_create_private_mapping() allocates VA and creates mapping.
	 */
	ret = __pkvm_create_private_mapping(EARLY_UART_BASE_PHYS, PAGE_SIZE,
					    PAGE_HYP_DEVICE, &va);
	if (ret)
		return ret;

	early_uart_base = (void __iomem *)va;

	/* Register as serial driver for pKVM framework */
	ret = __pkvm_register_serial_driver(early_uart_putc);
	if (ret) {
		/*
		 * Someone else already registered (e.g., pkvm-pl011 module).
		 * That's fine - just clear our pointer and return error.
		 */
		early_uart_base = NULL;
		return ret;
	}

	return 0;
}

int smmu_v2_global_init(void)
{
	int ret;

	/* Initialize early UART (non-fatal if it fails) */
	ret = smmu_v2_early_uart_init();
	if (ret) {
		/* Continue without UART - debug output will be silent */
	}

	HYP_INFO("SMMUv2: Starting global initialization");
	// ... rest of initialization
}
```

**Key Points:**
- Uses `__pkvm_create_private_mapping()` for proper EL2 VA mapping
- Prevents data aborts from accessing unmapped physical addresses
- Registers driver early, before any module loading
- Works during pKVM initialization phase

#### Option 2: Module-Based Initialization (Optional)

If early initialization is not critical, the pkvm-pl011 module can be loaded from userspace:

```c
// drivers/tty/serial/pkvm-pl011/pl011-host.c
static int __init pl011_host_init(void)
{
	unsigned long token;
	int ret;

	ret = pkvm_load_el2_module(__kvm_nvhe_pl011_hyp_init, &token);
	if (ret)
		return ret;

	pr_info("pKVM pl011 UART driver loaded\n");
	return 0;
}
module_init(pl011_host_init);
```

### Usage Examples

#### Example 1: Simple Output

```c
#include <nvhe/serial.h>

void __pkvm_host_iommu_init(...)
{
	HYP_INFO("IOMMU driver initializing");

	int ret = initialize_hardware();
	if (ret) {
		HYP_ERR("Hardware initialization failed: %d", ret);
		return ret;
	}

	HYP_INFO("IOMMU initialization complete");
}
```

**Output:**
```
[hyp-info] IOMMU driver initializing
[hyp-info] IOMMU initialization complete
```

#### Example 2: Complex Debugging

```c
void __pkvm_host_iommu_map_pages(u64 domain_id, u64 iova, phys_addr_t paddr,
                                 size_t size, int prot)
{
	HYP_DBG("Map request: domain=%llu iova=0x%llx paddr=0x%llx size=%zu prot=0x%x",
	        domain_id, iova, paddr, size, prot);

	int ret = program_page_tables(domain_id, iova, paddr, size, prot);
	if (ret) {
		HYP_ERR("Failed to map IOVA 0x%llx: error %d", iova, ret);
		return ret;
	}

	HYP_INFO("Mapped IOVA 0x%llx -> PA 0x%llx (%zu bytes)",
	         iova, paddr, size);
}
```

**Output:**
```
[hyp-dbg] Map request: domain=42 iova=0x80000000 paddr=0x90000000 size=4096 prot=0x3
[hyp-info] Mapped IOVA 0x80000000 -> PA 0x90000000 (4096 bytes)
```

#### Example 3: SMMU Initialization (Real-World)

```c
// From drivers/iommu/arm/arm-smmu/pkvm/arm-smmu-v2.c

int smmu_v2_global_init(void)
{
	struct hyp_arm_smmu_v2_device *smmu;
	int i, ret;

	/* Initialize early UART */
	ret = smmu_v2_early_uart_init();
	if (ret) {
		/* Continue without UART - debug output will be silent */
	}

	HYP_INFO("SMMUv2: Starting global initialization");

	/* Initialize each SMMU instance */
	for (i = 0; i < ARM_SMMU_MAX_INSTANCES; i++) {
		smmu = kvm_hyp_arm_smmu_v2_smmus[i];
		if (!smmu)
			continue;

		HYP_INFO("SMMUv2: Initializing SMMU instance %u at PA 0x%llx",
		         i, smmu->mmio_addr);

		ret = smmu_v2_init(smmu);
		if (WARN_ON(ret)) {
			HYP_ERR("SMMUv2: Failed to init SMMU %u (ret=%d)", i, ret);
			return ret;
		}

		HYP_INFO("SMMUv2: SMMU %u initialization complete", i);
	}

	HYP_INFO("SMMUv2: Global initialization complete");
	return 0;
}
```

**Output:**
```
[hyp-info] SMMUv2: Starting global initialization
[hyp-info] SMMUv2: Initializing SMMU instance 0 at PA 0x12000000
[hyp-info] SMMUv2: SMMU 0 initialization complete
[hyp-info] SMMUv2: Initializing SMMU instance 1 at PA 0x8000000
[hyp-info] SMMUv2: SMMU 1 initialization complete
[hyp-info] SMMUv2: Global initialization complete
```

### Advantages

- ✅ **Official infrastructure**: Part of Google/Android pKVM project
- ✅ **Printf support**: Comprehensive format string support (NEW)
- ✅ **Convenience macros**: HYP_INFO, HYP_ERR, etc. (NEW)
- ✅ **Early initialization**: Works before module loading (NEW)
- ✅ **Proper VA mapping**: Uses `__pkvm_create_private_mapping()` (FIXED)
- ✅ **Maintainable**: Actively maintained by upstream developers
- ✅ **Safe**: Prevents data aborts from unmapped physical access
- ✅ **Flexible**: Optional module loading or early direct init

### Limitations

- ❌ **No interrupt support**: EL2 uses polling (inherent to pKVM)
- ❌ **Performance overhead**: Busy-wait for each character (~87 μs at 115200 bps)

### When to Use

**Always use the enhanced pKVM serial framework** for:
- All new pKVM hypervisor code
- SMMU driver (already migrated)
- Any EL2 debug output requirements
- Production and development code

The custom hyp-uart.h has been **deleted** - the framework now provides all functionality.

---

## EL1 Kernel Console

The same UART is used as a standard Linux kernel console at EL1.

### Driver

**sbsa-uart driver** (`drivers/tty/serial/amba-pl011.c`):
- Standard ARM SBSA UART implementation
- Interrupt-driven (uses GIC_SPI 285)
- Integrated with Linux TTY subsystem
- Supports full terminal features (line editing, job control, etc.)

### Device Tree Configuration

**Base Definition** (`tegra234.dtsi`):

```dts
uarti: serial@31d0000 {
	compatible = "arm,sbsa-uart";
	reg = <0x0 0x31d0000 0x0 0x10000>;
	interrupts = <GIC_SPI 285 IRQ_TYPE_LEVEL_HIGH>;
	status = "disabled";  /* Disabled by default */
};
```

**Board Enablement** (`tegra234-p3737-0000+p3701.dtsi`):

```dts
serial@31d0000 {
	current-speed = <115200>;
	status = "okay";  /* Enabled for Jetson AGX Orin */
};
```

### Bootloader Configuration

The UART is typically configured as the kernel console via bootloader (U-Boot) or kernel command line:

```
console=ttyAMA0,115200n8
```

This maps to UARTI at 0x31d0000 (ttyAMA0 is the first "arm,sbsa-uart" device).

### Usage

**Standard kernel printing**:

```c
#include <linux/printk.h>

printk(KERN_INFO "Kernel message\n");
pr_info("Another message\n");
dev_info(&pdev->dev, "Device-specific message\n");
```

All kernel messages are automatically routed to the console UART.

---

## Practical Usage Guide

### Scenario 1: Early EL2 Initialization (SMMU Style)

**Step 1: Create early UART initialization**

```c
#include <nvhe/serial.h>
#include <nvhe/mm.h>

static void __iomem *early_uart_base;

static void my_early_uart_putc(char c)
{
	if (!early_uart_base)
		return;

	while (readl_relaxed(early_uart_base + 0x18) & (1 << 5))  // TXFF
		;
	writel_relaxed(c, early_uart_base + 0x00);  // UARTDR
	while (readl_relaxed(early_uart_base + 0x18) & (1 << 3))  // BUSY
		;
}

static int my_early_uart_init(void)
{
	unsigned long va = 0;
	int ret;

	ret = __pkvm_create_private_mapping(0x31d0000, PAGE_SIZE,
	                                    PAGE_HYP_DEVICE, &va);
	if (ret)
		return ret;

	early_uart_base = (void __iomem *)va;

	ret = __pkvm_register_serial_driver(my_early_uart_putc);
	if (ret) {
		early_uart_base = NULL;
		return ret;
	}

	return 0;
}
```

**Step 2: Use in your EL2 code**

```c
int my_hyp_init(void)
{
	int ret;

	/* Initialize early UART (non-fatal) */
	ret = my_early_uart_init();
	if (ret) {
		/* Continue without UART debugging */
	}

	HYP_INFO("My hypervisor module starting");
	// ... initialization code
	HYP_INFO("Initialization complete");

	return 0;
}
```

**Step 3: Verify output**

```bash
# Connect to UART console
sudo minicom -D /dev/ttyUSB0 -b 115200

# You should see:
# [hyp-info] My hypervisor module starting
# [hyp-info] Initialization complete
```

### Scenario 2: Module-Based Initialization (Optional)

**Step 1: Ensure module is loaded**

```bash
# Check if module is loaded
lsmod | grep pkvm_pl011

# Load module if not present
modprobe pkvm_pl011

# Make it load automatically at boot
echo "pkvm_pl011" | sudo tee -a /etc/modules
```

**Step 2: Use framework in your code**

```c
#include <nvhe/serial.h>

int my_hyp_function(void)
{
	HYP_INFO("Starting hypervisor operation");

	u64 result = do_something();
	HYP_INFO("Operation result: 0x%llx", result);

	if (error) {
		HYP_ERR("Operation failed with error: %d", error);
		return -1;
	}

	HYP_INFO("Operation completed successfully");
	return 0;
}
```

### Scenario 3: Debugging Both EL1 and EL2

When both kernel (EL1) and hypervisor (EL2) output to the same UART, you'll see interleaved messages:

```
[    0.000000] Booting Linux on physical CPU 0x0000000000 [0x410fd421]
[hyp-info] SMMUv2: Starting global initialization
[    0.123456] SMMU driver: Initializing pKVM IOMMU
[hyp-info] SMMUv2: SMMU 0 initialized successfully
[    0.234567] SMMU driver: pKVM IOMMU initialized
[hyp-info] SMMUv2: All 2 SMMUs initialized
[    0.345678] GPU driver: Requesting IOMMU domain
[hyp-info] Allocating IOMMU domain 1
```

**Tips for distinguishing output:**
- EL1 messages typically have kernel timestamps: `[    0.123456]`
- EL2 messages have prefixes: `[hyp-info]`, `[hyp-err]`, `[hyp-warn]`, `[hyp-dbg]`

---

## Troubleshooting

### Problem: No EL2 UART Output

**Possible causes and solutions:**

1. **Early initialization not called**
   ```c
   // Ensure your init function calls early UART setup
   ret = my_early_uart_init();
   if (ret) {
       // Handle error - but code should still work without UART
   }
   ```

2. **VA mapping failed**
   ```c
   // Check return value from __pkvm_create_private_mapping()
   ret = __pkvm_create_private_mapping(0x31d0000, PAGE_SIZE,
                                       PAGE_HYP_DEVICE, &va);
   if (ret) {
       // Mapping failed - UART won't work
       // But don't fail initialization
   }
   ```

3. **Wrong UART base address**
   ```c
   // For Tegra234, must be: 0x31d0000 (UARTI)
   #define EARLY_UART_BASE_PHYS	0x31d0000
   ```

4. **EL2 code not executing**
   ```bash
   # Check if pKVM is enabled
   dmesg | grep -i pkvm
   # Should see: "kvm [1]: Protected nVHE mode"
   ```

### Problem: Data Abort on UART Access

**This should no longer occur** after the framework enhancement.

**Previous issue (FIXED):**
- Old hyp-uart.h used direct physical address access
- Caused data abort: `FAR:00000000031d0030 ESR:0000000096000045`

**Solution (IMPLEMENTED):**
- Use `__pkvm_create_private_mapping()` to create proper EL2 VA mapping
- All framework code now uses VA, not PA

### Problem: Garbled Output

**Possible causes:**

1. **Baud rate mismatch**
   - Check terminal baud rate: Should be 115200
   - UART clock for Tegra234: 408 MHz (PLLP)

2. **UART configuration mismatch**
   - Ensure 8N1 (8 data bits, no parity, 1 stop bit)
   - Ensure FIFOs are enabled (they are in the framework)

### Problem: Output Stops Mid-Boot

**Possible causes:**

1. **EL1 driver taking over UART**
   - This is normal behavior
   - EL2 output may pause while EL1 reconfigures UART
   - Output should resume after EL1 driver initialization

2. **Module loaded and conflicting**
   - If pkvm-pl011 module loads, it will try to register
   - Early init checks if someone already registered
   - First registration wins

---

## Hardware Details

### PL011 Register Map

Offsets from base 0x31d0000:

```c
#define UARTDR      0x00   // Data Register (R/W)
#define UARTFR      0x18   // Flag Register (RO)
  #define UARTFR_TXFF  (1 << 5)  // TX FIFO Full
  #define UARTFR_RXFE  (1 << 4)  // RX FIFO Empty
  #define UARTFR_BUSY  (1 << 3)  // UART Busy

#define UARTIBRD    0x24   // Integer Baud Rate Divisor (R/W)
#define UARTFBRD    0x28   // Fractional Baud Rate Divisor (R/W)
#define UARTLCR_H   0x2C   // Line Control Register (R/W)
  #define UARTLCR_H_WLEN_8  (3 << 5)  // 8-bit data
  #define UARTLCR_H_FEN     (1 << 4)  // Enable FIFOs

#define UARTCR      0x30   // Control Register (R/W)
  #define UARTCR_UARTEN  (1 << 0)  // UART Enable
  #define UARTCR_TXE     (1 << 8)  // TX Enable
  #define UARTCR_RXE     (1 << 9)  // RX Enable

#define UARTIMSC    0x38   // Interrupt Mask Set/Clear (R/W)
```

### Baud Rate Calculation

```
Target: 115200 bps
Clock:  408 MHz (Tegra234 PLLP)

Divisor = (UARTCLK * 64) / (16 * BaudRate)
        = (408000000 * 64) / (16 * 115200)
        = 26112000000 / 1843200
        = 14171.875

Integer part (IBRD):    14171 >> 6  = 221
Fractional part (FBRD): 14171 & 0x3F = 23

Actual baud rate: 408000000 / (16 * (221 + 23/64))
                = 115207.3 bps
Error: ~0.006% (acceptable)
```

### Performance Considerations

**Polling vs Interrupts:**
- EL2 uses polling (busy-wait) because interrupts are not available at EL2 in pKVM
- This is acceptable for debug output but would be inefficient for high-throughput data
- Keep EL2 debug messages minimal in production code

**FIFO Buffering:**
- PL011 has 16-byte TX and RX FIFOs
- Polling waits for FIFO not full (can still send up to 16 bytes)
- For long messages, multiple characters may be buffered before transmission

**Performance Impact:**
- Each character output from EL2 requires:
  - ~2 MMIO reads (check TX FIFO full, check busy)
  - ~1 MMIO write (write character)
  - Busy-wait delays (depends on baud rate)
- At 115200 bps: ~87 μs per character
- A 100-character debug message: ~8.7 ms

**Recommendation**: Use debug output sparingly in performance-critical code paths.

---

## Summary

### Quick Reference

| Operation | Code | Example |
|-----------|------|---------|
| **Include** | `#include <nvhe/serial.h>` | - |
| **Early Init** | `my_early_uart_init()` | See examples above |
| **Info message** | `HYP_INFO(fmt, ...)` | `HYP_INFO("Domain %llu allocated", id)` |
| **Error message** | `HYP_ERR(fmt, ...)` | `HYP_ERR("Failed: %d", ret)` |
| **Warning** | `HYP_WARN(fmt, ...)` | `HYP_WARN("Suspicious value: 0x%llx", val)` |
| **Debug** | `HYP_DBG(fmt, ...)` | `HYP_DBG("iova=0x%llx size=%zu", iova, size)` |
| **Printf** | `hyp_printf(fmt, ...)` | `hyp_printf("Value: %llu\n", val)` |

### Format Specifiers

| Specifier | Type | Example |
|-----------|------|---------|
| `%s` | String | `HYP_INFO("Name: %s", name)` |
| `%d`, `%u` | 32-bit int | `HYP_INFO("Count: %u", count)` |
| `%ld`, `%lu` | 64-bit long | `HYP_INFO("Domain: %lu", domain_id)` |
| `%lld`, `%llu` | 64-bit long long | `HYP_INFO("ID: %llu", id)` |
| `%x` | 32-bit hex | `HYP_INFO("Flags: 0x%x", flags)` |
| `%lx` | 64-bit hex | `HYP_INFO("IOVA: 0x%lx", iova)` |
| `%llx` | phys_addr_t | `HYP_INFO("PA: 0x%llx", paddr)` |
| `%zu`, `%zd` | size_t | `HYP_INFO("Size: %zu bytes", size)` |
| `%zx` | size_t (hex) | `HYP_INFO("Size: 0x%zx", size)` |
| `%p` | Pointer | `HYP_INFO("Pointer: %p", ptr)` |
| `%c` | Character | `HYP_INFO("Char: %c", ch)` |
| `%%` | Literal % | `HYP_INFO("Progress: 50%%")` |

### Recommendations

**For all new EL2 code:**
- Use the **enhanced pKVM serial framework** (it's production-ready now)
- Call early UART init if your code runs before module loading
- Use `HYP_INFO()`, `HYP_ERR()`, etc. for categorized logging
- Use `hyp_printf()` when you need custom formatting

**For production deployments:**
- Remove or minimize EL2 debug output (performance)
- Keep error logging only
- Consider making UART init conditional on debug build flag

### Related Documentation

- `../CLAUDE.md` - Main project documentation
- `../source/CLAUDE.md` - Source tree and build system details
- `../source/kernel/linux/drivers/iommu/arm/arm-smmu/CLAUDE.md` - SMMU driver documentation
- ARM PL011 Technical Reference Manual - Hardware details
- Linux kernel: `Documentation/admin-guide/serial-console.rst` - Kernel console setup

---

## Migration Guide

### From hyp-uart.h to pKVM Framework

**The custom hyp-uart.h has been deleted. Here's how to migrate existing code:**

#### 1. Change Includes

```c
// OLD (DELETED):
#include "hyp-uart.h"

// NEW:
#include <nvhe/serial.h>
```

#### 2. Remove Manual Initialization

```c
// OLD (DELETED):
int ret = hyp_uart_init();
if (ret) {
    /* Handle error */
}

// NEW: Call early init with proper VA mapping
static int my_early_uart_init(void)
{
	unsigned long va = 0;
	int ret;

	ret = __pkvm_create_private_mapping(0x31d0000, PAGE_SIZE,
	                                    PAGE_HYP_DEVICE, &va);
	if (ret)
		return ret;

	early_uart_base = (void __iomem *)va;
	ret = __pkvm_register_serial_driver(my_early_uart_putc);
	if (ret) {
		early_uart_base = NULL;
		return ret;
	}

	return 0;
}
```

#### 3. Update Function Calls

```c
// OLD (DELETED):
hyp_uart_puts("Message");
hyp_uart_printf("Value: %lx\n", val);

// NEW:
HYP_INFO("Message");
HYP_INFO("Value: 0x%lx", val);
```

#### 4. Update Macro Usage

```c
// OLD (DELETED):
HYP_INFO("Starting init");  // Was in hyp-uart.h
HYP_ERR("Error: %d", ret);  // Was in hyp-uart.h

// NEW: Same macros, now in framework!
HYP_INFO("Starting init");
HYP_ERR("Error: %d", ret);
```

**Note**: The convenience macros have the **same names** and **same syntax**. Only the include file changes!

#### 5. Update Format Specifiers for phys_addr_t

```c
// OLD (potentially broken):
HYP_INFO("PA: 0x%lx", physical_addr);  // Might cause warning

// NEW (correct for phys_addr_t):
HYP_INFO("PA: 0x%llx", physical_addr);  // Always safe
```

#### Complete Migration Example

**Before (using deleted hyp-uart.h):**
```c
#include "hyp-uart.h"

int __pkvm_host_iommu_init(...)
{
	int ret;

	ret = hyp_uart_init();
	if (ret)
		return ret;

	HYP_INFO("IOMMU driver starting");
	HYP_INFO("SMMU base: 0x%lx", smmu->mmio_addr);

	// ... initialization code

	return 0;
}
```

**After (using enhanced framework):**
```c
#include <nvhe/serial.h>
#include <nvhe/mm.h>

static void __iomem *early_uart_base;

static void my_early_uart_putc(char c)
{
	if (!early_uart_base)
		return;
	while (readl_relaxed(early_uart_base + 0x18) & (1 << 5))
		;
	writel_relaxed(c, early_uart_base + 0x00);
	while (readl_relaxed(early_uart_base + 0x18) & (1 << 3))
		;
}

static int my_early_uart_init(void)
{
	unsigned long va = 0;
	int ret;

	ret = __pkvm_create_private_mapping(0x31d0000, PAGE_SIZE,
	                                    PAGE_HYP_DEVICE, &va);
	if (ret)
		return ret;

	early_uart_base = (void __iomem *)va;
	ret = __pkvm_register_serial_driver(my_early_uart_putc);
	if (ret) {
		early_uart_base = NULL;
		return ret;
	}

	return 0;
}

int __pkvm_host_iommu_init(...)
{
	int ret;

	ret = my_early_uart_init();
	if (ret) {
		/* Non-fatal - continue without UART */
	}

	HYP_INFO("IOMMU driver starting");
	HYP_INFO("SMMU base: 0x%llx", smmu->mmio_addr);  // Note: %llx

	// ... initialization code

	return 0;
}
```

---

## Revision History

- **2025-01-11**: Major update - Enhanced pKVM framework with printf support, deleted hyp-uart.h
- **2025-01-XX**: Initial documentation - comprehensive UART infrastructure analysis
