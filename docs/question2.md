# Question

so can you point out what is wrong with my thinking? I would like to move SMMU driver to pKVM hypervisor (EL2) so that host could not reprogram SMMU settings for devices mapped to guest; apparently the actual SMMU programming needs to be validated at EL2 but can I construct these fwspecs in EL1 using existing code and then just pass info EL2 (so that it becomes immutable)? anything else? or is there something wrong?`

# Answer

You’re not fundamentally wrong – what you’re describing is *very* close to what the upstream pKVM SMMUv3 work actually does – but a couple of details are off / incomplete:

* **You *can* keep `fwspec` + `of_xlate` in EL1.**
* **You *must not* treat EL1’s `fwspec` as “ground truth”.** EL2 has to have its *own* authoritative view of devices + SIDs and treat EL1’s view as a *request* it validates.
* Moving the *whole* SMMU driver to EL2 is usually a non-starter: too big, too entangled with the kernel, and it would bloat the TCB. That’s why the real pKVM design uses a **split driver**: kernel part at EL1, minimal SMMU driver at EL2. ([totalcompute.docs.arm.com][1])

Let me map this onto your mental model.

---

## 1. What you’re proposing (in my words)

You’re basically saying:

1. Let Linux at EL1 keep doing all the usual DT / IOMMU plumbing:

   * `of_iommu_configure()`, `of_xlate()`, `iommu_fwspec_init()`, `iommu_fwspec_add_ids()`, …
   * Result: each device has a `dev->iommu_fwspec` that says “this device uses IOMMU X with SID(s) Y…”.

2. Then:

   * Pass the relevant info (per-device IOMMU + SIDs) to EL2 once.
   * EL2 programs the SMMU, and after that the SID mapping becomes “immutable” from EL1’s perspective.
   * EL1 can’t poke the SMMU MMIO directly any more; only EL2 does actual programming.

That’s not crazy at all; in fact, it’s *very* close to the **“private I/O page tables with paravirtual IOMMU”** design they adopted for SMMUv3 in pKVM:

* Host still speaks the normal IOMMU API (`map`, `unmap`, `attach_dev`, `detach_dev`…).
* Those calls are turned into hypercalls (`map_pages`, `alloc_domain`, `attach_dev`, …).
* EL2 owns the page tables + SMMU command queue and validates each operation before touching hardware. ([LWN.net][2])

So conceptually: ✅ you’re aligned.

The “wrong” or incomplete bits are about **trust model**, **lifetime of `fwspec`**, and **how much of the driver you actually move to EL2**.

---

## 2. The big gotcha: who does EL2 *trust*?

In pKVM’s threat model, the host is *not* trusted (for protected VMs). That has two consequences:

1. **EL2 can’t blindly trust `fwspec` from EL1.**

   A malicious host could, for example:

   * Lie about SIDs (claim a device uses SID that actually belongs to some other device).
   * Attach a device to a domain that maps memory the host doesn’t own (e.g. guest/hyp pages).
   * Try to re-use a “trusted” domain for some different device than what EL2 thinks.

   So even if `fwspec` is constructed with the normal DT plumbing, **EL2 must treat it as “untrusted metadata”** and cross-check it against its own view of the platform.

   That is exactly what the upstream pKVM SMMUv3 driver does:

   * The **host driver** probes SMMUs, parses DT, creates domains, etc.
   * It then forwards operations (`alloc_domain`, `attach_dev`, `map_pages`, `unmap_pages`) as hypercalls to EL2.
   * The **hypervisor driver** at EL2 has its own representation of:

     * Which SMMU instances exist.
     * Which SIDs are valid for which devices.
     * Which pages belong to host vs guests vs hypervisor (via refcounts etc.). ([LWN.net][2])

   So: yes, EL1 constructs `fwspec`, but EL2 doesn’t *trust* it blindly; it uses it as input to checks.

2. **EL2 must own more than just the SMMU tables.**

   Especially on Tegra-style SoCs:

   * The **MC’s SID override registers** are as security-critical as the SMMU page tables. If EL1 can twiddle MC client→SID mappings, it can bypass whatever immutable `fwspec` you thought you had.
   * Any MMIO region that can affect which SID a device uses, or whether it bypasses the SMMU entirely, has to be under EL2’s control (stage-2 traps or not mapped to EL1 at all).

   So the minimal “trusted footprint” at EL2 is something like:

   * SMMU MMIO windows.
   * MC (or equivalent) registers that control SIDs / bypass paths.
   * EL2’s own copy of the platform description (secure DT or vendor module) that says “device X → SID Y”.

---

## 3. What `fwspec` is good for in a pKVM design

Keeping `fwspec` at EL1 is still very useful:

* It keeps all the **messy, Linux-specific wiring** at EL1:

  * DT / ACPI parsing.
  * Bus notifiers, device hotplug, VFIO integration, dma-ops hooking, etc.
* It gives you a **natural interface** for hypercalls:

  The pKVM SMMUv3 design basically mirrors the Linux `iommu_ops` at EL2:

  ```text
  EL1: iommu_map()     → hypercall map_pages()
  EL1: attach_dev()    → hypercall attach_dev()
  EL1: free_domain()   → hypercall free_domain()
  ...
  ```

  and EL2 keeps its own “sanitised” shadow state. ([LWN.net][2])

So the pattern that works in practice is:

1. **EL1:**

   * Use existing `of_xlate` + `fwspec` machinery, completely unchanged.
   * Implement a *pKVM-aware SMMU driver* that:

     * Doesn’t program hardware directly.
     * Just issues hypercalls mirroring the IOMMU ops.

2. **EL2:**

   * Implement a **minimal, Linux-agnostic SMMU driver**:

     * Knows about SMMU registers, page tables, queues, TLB invalidation, etc.
     * Has its own data structures: “EL2 domain”, “EL2 device handle”, “EL2 SMMU instance”.
     * Does **not** know what `struct iommu_fwspec` or `struct device` is.

3. **Handshake / “freezing” step:**

   * Early boot: EL1 host driver enumerates SMMUs and tells EL2 (via a set of “register SMMU” hypercalls) about:

     * Which SMMUs exist.
     * Their base addresses, features, etc.
   * EL2 validates this against its own DT / vendor module, and then **locks down SMMU + MC MMIO from EL1**.
   * From then on, all IOMMU ops happen via hypercalls.

That gives you exactly what you want:

* Host can’t reprogram the SMMU for devices mapped to guests.
* You still reuse all the normal `fwspec`/`of_xlate` plumbing at EL1.
* EL2 is the only place where the real SMMU state lives.

---

## 4. Why “just move the whole SMMU driver to EL2” is frowned upon

This is the part that’s slightly “wrong” in your thinking:

> “I would like to move SMMU driver to pKVM hypervisor (EL2)…”

The upstream folks explicitly rejected that idea for SMMUv3:

* The normal SMMU driver is **large and tangled** with:

  * sysfs/debugfs,
  * PM/runtime-PM,
  * notifier chains,
  * dma-ops integration, etc. ([LWN.net][3])
* nVHE / hypervisor side is deliberately tiny; stuffing the full driver there would:

  * Blow up the TCB.
  * Make maintenance a nightmare (you’d be re-porting SMMU driver changes into hyp every kernel bump).
  * Drag in huge chunks of generic kernel infrastructure into EL2.

Hence the split design:

* **Kernel part**: probes SMMUs, handles device binding, implements `iommu_ops`, turns everything into hypercalls. ([LWN.net][4])
* **Hypervisor part**: the “bare metal” SMMU driver that just:

  * maintains I/O page tables,
  * pushes commands to the SMMU,
  * tracks which pages are used for DMA so they can’t be donated to guests, etc. ([LWN.net][2])

So the “fix” to your plan is:

* Don’t literally move `drivers/iommu/arm-smmu*.c` wholesale into EL2.
* Instead, **mirror its public API at EL2**, using your own compact types, and keep the hairy parts in EL1.

---

## 5. About “making `fwspec` immutable”

Two subtleties here:

1. **Hardware SIDs vs software `fwspec`:**

   * The *hardware* mapping “device X → stream ID Y” really should be immutable from the host’s point of view. So EL2 must own MC SID overrides, and never let EL1 poke them directly.
   * The *software* object `iommu_fwspec` is just EL1’s local cache of that wiring. EL1 can technically free/reallocate it; EL2 doesn’t care as long as hypercalls for a given device keep using the same SID set.

   So instead of trying to literally freeze `fwspec`, you:

   * Freeze **MC + SMMU MMIO** at EL2.
   * Let EL1 do whatever it wants with its internal `fwspec` structs, but **validate** that the hypercalls it makes do not contradict EL2’s own per-device SID list.

2. **Dynamic domain changes:**

   Even with a protected guest, the host may want to:

   * Re-attach devices to different *host* domains.
   * Reconfigure IOVA layouts, bounce buffers, etc.

   That all still goes via IOMMU ops → hypercalls. Your “immutable” part is just:

   * “This physical device, identified as X, is allowed to exist, and it always uses SID set S.”
   * “These devices are allowed to be attached to protected guests; others are host-only.”

   The **policy** (which devices can be given to which guests) is stored at EL2; EL1 can only request.

---

## 6. Direct answers to your questions

> can I construct these fwspecs in EL1 using existing code and then just pass info EL2 (so that it becomes immutable)?

* **Yes, you can construct them in EL1 and reuse all of that code.**
* But at EL2 you shouldn’t import `struct iommu_fwspec` wholesale. Instead:

  * At early boot, have EL1 send a *sanitised* description to EL2: `(SMMU instance, device ID, stream ID list)`.
  * EL2 compares that with its own secure DT / vendor data, then stores it in its own minimal structs.
  * EL2 then refuses any later EL1 request that tries to change those per-device SID associations.

That’s almost exactly what `CONFIG_ARM_SMMU_V3_PKVM` does for SMMUv3. ([totalcompute.docs.arm.com][1])

> anything else? or is there something wrong?

The only “wrong” assumptions I’d tweak are:

* Don’t assume `fwspec` itself needs to become immutable or live at EL2 – only the *hardware* mapping and EL2’s internal view must be immutable.
* Don’t move the full SMMU driver to EL2; follow a **split driver** model: EL1 driver looks normal and just translates IOMMU ops to hypercalls; EL2 has a small, tight SMMU driver that never sees `struct device` or `fwspec`.

If you want, next I can sketch a Tegra-specific version of this split (who owns MC, host1x, NVDEC, etc.) and how you’d feed the Tegra MC’s SID info into the EL2 part without teaching the hypervisor about `mc_client` tables.

[1]: https://totalcompute.docs.arm.com/en/tc2-2023.10.04/totalcompute/tc2/tc2_sw_stack.html "Total Compute Platform Software Components — Total Compute  documentation"
[2]: https://lwn.net/Articles/1001952/ "KVM: Arm SMMUv3 driver for pKVM [LWN.net]"
[3]: https://lwn.net/Articles/1001952/?utm_source=chatgpt.com "KVM: Arm SMMUv3 driver for pKVM"
[4]: https://lwn.net/Articles/921869/ "KVM: Arm SMMUv3 driver for pKVM [LWN.net]"


