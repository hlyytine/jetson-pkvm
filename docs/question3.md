# Question

you wrote "EL2 validates this against its own DT / vendor module, and then locks down SMMU + MC MMIO from EL1" -- basically on tegra234 the authorative source is the device tree and to my understanding early linux boot is trusted in a sense that at certain point pKVM initialization is finalized and after that host part (EL1) is considered untrusted? am I getting right that fwspec info from existing code must be received from EL1 before pKVM initialization is finalized? if yes, doesn't it mean that parts of SMMUv2/tegra-mc combo need to be executed earlier than in no-pKVM case?

# Answer

Short answer:

* Yes: pKVM treats **early EL1 boot as “trusted enough to set things up”**, and after pKVM is initialized the host is treated as **untrusted**.
* No: you **don’t need to “freeze” or ship all `fwspec` info to EL2 before finalization**. Only the *EL2-side SMMU/MC setup* must be done before `is_pkvm_initialized()` flips; per-device `fwspec` is an EL1 detail and can be used later as input to hypercalls.
* So you **don’t have to move the whole SMMUv2/tegra-mc combo earlier** – just the “register SMMUs/MC to EL2 and donate their MMIO” bit, which can be a small early init path, not the full drivers.

Let me break that down against your questions.

---

## 1. Trust model vs boot phases

From the SMMUv3 pKVM series:

> “The host is initially trusted during boot, but its privileges are reduced **after KVM is initialized** so that, if an adversary later gains access to the large attack surface of the host, it cannot access guest data.”

Mechanically:

* There is a static key / predicate `is_pkvm_initialized()` in the kernel.
* Before it flips:

  * EL1 kernel is allowed to do **one-shot configuration** of EL2: load EL2 modules, donate MMIO, set up page ownership, etc.
* After it flips:

  * The host is treated as **untrusted**; most “shape-changing” EL2 APIs are disabled (e.g. loading new hyp modules is forbidden once `is_pkvm_initialized()` is true).
  * EL2 still services *runtime* hypercalls (KVM, IOMMU, etc.), but every call is validated.

So your intuition is right: there’s an “early trusted EL1” phase, then “untrusted EL1 issuing requests”.

---

## 2. Where does `fwspec` fit into that?

Key point: **`iommu_fwspec` is purely an EL1 data structure.**

In the SMMUv3 pKVM design:

* EL1 has the usual flow:

  * DT/ACPI → `of_iommu_configure()` → `of_xlate()` → `iommu_fwspec_*()` → `dev->iommu_fwspec` filled.
* The *host* SMMU driver then converts normal IOMMU ops into hypercalls:

  * `map_pages()`, `unmap_pages()`, `alloc_domain()`, `attach_dev()`, etc.
* At EL2, there is a minimal SMMU driver that:

  * Has its **own view** of SMMU instances + valid SIDs (from its own DT / platform description).
  * Does **not** share `struct iommu_fwspec` with EL1.

So for pKVM:

* EL2 **doesn’t need a pre-finalization snapshot of EL1’s `fwspec`s**.
* It only needs:

  1. A description of the SMMU instances + MMIO ranges + basic features (one-time, early).
  2. At runtime, per-device operations (“attach device with SID X to domain Y”) expressed as hypercalls, which it validates against its own knowledge.

That’s exactly what the SMMUv3 pKVM series does: one patch literally says *“pass a list of SMMU devices to the hypervisor”* (host → EL2, early), and then later patches add the IOMMU ops that use hypercalls.

So:

> “am I getting right that fwspec info from existing code must be received from EL1 before pKVM initialization is finalized?”

**Not strictly.**
What EL2 really needs before finalization is **stable hardware description** (SMMU instances, MC registers, etc.), not per-device `fwspec` lists.

Your current Tegra code *happens* to use `fwspec` as the way EL1 tells EL2 “this device uses SID N”, but that’s your design choice, not a pKVM requirement.

---

## 3. What *must* happen before `is_pkvm_initialized()`?

Using the upstream SMMUv3 design as a template, the “must be early” bits are:

1. **Donating MMIO and reserving HW for EL2**

   * EL1 tells EL2:
     “Here are the SMMU MMIO regions, please own them”
     “Here are MC MMIO regions that control SIDs / bypass, please own those too”
   * EL2 maps them into hyp’s address space and ensures EL1 can’t poke them directly any more.

2. **Registering SMMU instances with the hyp IOMMU core**

   * EL1 passes a list of SMMU devices (base address, features, IRQs).
   * EL2 creates its internal `struct hyp_smmu` array, etc.

3. **Any other EL2 modules that must be present for protected guests**

   * That’s why `__pkvm_load_el2_module()` explicitly checks `!is_pkvm_initialized()` – you’re only allowed to plug new EL2 components before finalization.

All of this can (and in upstream *does*) happen with fairly small “early init” helpers – **not** by running the full host SMMU driver early. The SMMUv3 series refactors the existing driver so that the “firmware probe” part that understands DT is separable from the rest.

What can safely happen *after* `is_pkvm_initialized()`:

* Normal IOMMU operations for host devices:

  * `alloc_domain`, `attach_dev`, `map/unmap`, etc. These become hypercalls, and EL2 now validates them carefully.
* Continued use of `fwspec` in EL1:

  * drivers call `tegra_dev_iommu_get_stream_id()` → produce device/SID → host SMMU-pKVM wrapper translates that into `attach_dev(dev_handle, sid)` hypercall.

So **your fix using `is_pkvm_initialized()` as a gate in `kvm_iommu_alloc_domain()` is exactly in the spirit of upstream**: prevent domain creation until the EL2 IOMMU infrastructure is ready, but you don’t need all device-level wiring pre-finalization.

---

## 4. Does this force SMMUv2 / tegra-mc to run earlier?

> “if yes, doesn't it mean that parts of SMMUv2/tegra-mc combo need to be executed earlier than in no-pKVM case?”

Nuanced answer:

* **You do not need to drag the entire drivers earlier.**
* You *do* need **some** code to run early to:

  * Donate SMMU + MC MMIO to EL2.
  * Tell EL2 “this SoC has SMMU instances A/B/C with these base addresses, and MC at base M”.

On Tegra234, where DT is the authoritative SoC description, you’ve got two basic options for that early piece:

1. **EL2 parses DT directly**

   * Bootloader hands the DT to both EL1 and EL2 (or EL1 passes a copy before finalization).
   * Tiny EL2 code parses the SMMUv2 + tegra-mc nodes and builds internal tables:
     “MC client X → SID Y → SMMU Z”.
   * No dependency on EL1 `fwspec` at all; you only need to ensure that MMIO donation happens early.

2. **EL1 parses DT, then passes a summarised description to EL2 before finalization**

   * Early initcall in the Tegra MC / SMMU glue walks the DT (same logic you already have), but instead of building full Linux driver state it just builds a compact table and sends it in one or a few hypercalls:

     * For each MC client: `(client_id, sid, smmu_index)`
   * EL2 stores that, and from that point on ignores any conflicting info coming from EL1.
   * Full tegra-mc and SMMUv2 drivers can still probe later (at the usual time) for host’s own purposes; EL2 doesn’t care.

In both cases:

* The **only** part that has to move earlier than in a non-pKVM system is this small “describe hardware to EL2 + donate MMIO” chunk.
* All the **per-device `fwspec` logic, `of_xlate`, MC enumeration for host debug, etc.** can stay where they are in the normal probe path – because EL2 will treat those as *untrusted runtime requests* via your KVM-IOMMU hypercalls, not as trusted configuration.

Right now in your tree you *are* using `fwspec` as the way to feed SIDs into the `kvm_iommu_*` code, so you see:

* `kvm_iommu_alloc_domain()` getting called very early and needing `is_pkvm_initialized()` gating (which you fixed).
* Worry that you need all those `fwspec`s available “before finalization”.

But strictly speaking, that’s a consequence of your current plumbing, not a fundamental requirement of pKVM.

---

## 5. TL;DR relative to your mental model

* **Yes**, early EL1 boot is “trusted enough” until pKVM flips `is_pkvm_initialized()`. After that, the host is a large untrusted VMM front-end.
* **No**, EL2 doesn’t need a frozen copy of EL1’s `fwspec` tables. EL2 should have its own SoC description (from DT or early summary hypercalls) and treat any `fwspec` info as *hints* to validate, not as the ground truth.
* Therefore, you **only need a small Tegra-specific early init path** that:

  * donates SMMU + MC MMIO and
  * registers the SMMU/MC topology with EL2
    before `is_pkvm_initialized()`.

Everything else – including constructing `fwspec` in EL1 using the existing DT code – can stay at normal driver probe time and will still work, as long as your KVM-IOMMU host wrapper turns those into well-checked hypercalls instead of trying to program SMMU/MC directly.

If you want, next step we can sketch a concrete split for Tegra234: which bits of tegra-mc + SMMUv2 code become “early EL1 helper for EL2” vs “normal host driver”, and where to hang the `is_pkvm_initialized()` checks so you don’t hit the 0.1s domain-alloc bug again.

