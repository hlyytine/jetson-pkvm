Short version: yes, the MC is really the place where the *real* stream-ID wiring lives on Tegra186/194/234, and the arm-smmu “NVIDIA impl” talks to it on purpose and *late* because secure firmware leaves a bunch of clients in passthrough until Linux is ready to take over (classic example: display). Once the IOMMU domain is set up and the driver attaches, the SMMU code asks the MC to finally flip the SID override for that client.

More detailed, with the pieces lined up:

---

### 1. Who actually owns SIDs on Tegra234?

On Tegra186+ (so including Tegra234), the per-client stream ID is *not* programmed in the SMMU but in the memory controller’s client registers:

* `struct tegra_mc_client` has a `.sid` field, and for Tegra234 there’s a big `tegra234_mc_clients[]` table that maps each HW client (sdmmc, nvdec, pcie, …) to a SID and to the MC register offsets that control the override/security bits. ([gbmc.googlesource.com][1])
* The public MC header explicitly states: for <=T210 this was an SWGROUP ID for the Tegra SMMU; for T186+ it’s “the ID used to override the ARM SMMU stream ID used for IOVA translations for the given memory client”. ([GitLab][2])

So the hardware contract is:

> Device → MC “client ID” → MC override register → *stream ID* presented to the ARM MMU-500.

That’s why the SMMU driver has to talk to the MC; only the MC really knows how to poke the right client override register for a given Linux `struct device`.

---

### 2. Why is the arm-smmu NVIDIA impl coupled to the MC driver?

Look at the NVIDIA-specific arm-smmu implementation (`arm-smmu-nvidia.c`):

* It grabs a `struct tegra_mc *` in `nvidia_smmu_impl_init()` via `devm_tegra_memory_controller_get()`. ([lists.infradead.org][3])
* It wires a `probe_finalize` callback that calls `tegra_mc_probe_device(mc, dev)` after a device has been attached to the SMMU. ([lists.infradead.org][3])

The associated patch description spells out the reason in plain language:

* Secure firmware initially programs some MC SID override regs to **passthrough/bypass** so devices (notably display) can access memory *without* knowing about any SMMU mappings. That’s what lets you see a firmware framebuffer before the kernel driver comes up. ([lists.infradead.org][3])
* Once Linux attaches the device to an SMMU domain and sets up the necessary (often identity) mappings, the Tegra-specific SMMU code **then** asks the MC to program the “real” SID override for that client. ([lists.infradead.org][3])

So the coupling exists because:

1. Only MC has the per-client override registers and the giant client table.
2. The SMMU side is what knows *when* a device has a valid domain and mappings.
3. They need to coordinate that handover point.

---

### 3. Why is it done “late in boot” instead of very early?

You’re right that, in principle, the MC could slam all SID overrides into their “final” values very early, but Tegra234 is designed around a staged handoff:

1. **Boot/firmware stage**

   * Boot ROM + MB1/MB2/BPMP (and sometimes RCE, etc.) bring up DRAM and some engines (especially display) using MC SID overrides that either bypass the SMMU or route through a very simple mapping.
   * This gives you:

     * boot logo / early framebuffer,
     * firmware-driven engines (NVDEC, RCE carveouts, etc.) that still need to work before Linux reconfigures anything. ([LWN.net][4])

2. **Kernel early boot**

   * Generic arm-smmu driver probes, learns that this is a Tegra234 SoC and switches to the NVIDIA implementation (T234 has two pairs of MMU-500 instances that must be programmed in lock-step, another reason for the SoC-specific code). ([Patchew][5])
   * MC driver also probes and sets up error reporting, interconnect, etc., but it **doesn’t** yet rewrite all the SID overrides for active clients.

3. **Device attach time (what you’re seeing as “late”)**

   * When a given device’s driver binds and the IOMMU core creates/attaches its domain, the NVIDIA SMMU impl’s `probe_finalize()` calls `tegra_mc_probe_device()` for that `struct device`. That function:

     * finds the matching MC client entry,
     * programs the SID override to the correct stream ID for that SMMU instance,
     * possibly fixes up other MC bits (security, error reporting). ([lists.infradead.org][3])

The key reasons this is intentionally **late**:

* **Seamless firmware → kernel handover**, especially for display
  If Linux reprogrammed all SID overrides very early, the firmware framebuffer might suddenly start going through a not-yet-configured SMMU, and you’d lose the screen or crash the display engine. By waiting until there is an identity-mapped domain and a real DRM driver, the handover is transparent. ([lists.infradead.org][3])

* **Only touch devices that actually use the SMMU**
  Doing it at attach time means MC is only updated for devices that Linux is actually putting behind the IOMMU; firmware-only or reserved clients can keep the firmware SID setup.

* **Interaction with more complex use-cases (hypervisors, carveouts, etc.)**
  On platforms with an external HV or special carveouts, there are patches to *skip* SID override from the non-secure OS in some cases. That logic lives naturally at “attach / per-device” time, not at some monolithic “MC init” time. ([lists.yoctoproject.org][6])

---

### 4. So, is your mental model roughly correct?

> I mean, I know mc programs override SIDs to clients (right?)

Yes, that’s exactly it on Tegra186/194/234:

* MC has per-client override registers that define what **stream ID** a particular engine presents to the ARM SMMU(s). ([GitLab][2])
* The arm-smmu “nvidia” implementation defers programming those overrides (via the MC driver) until *after* a device is attached to an SMMU domain, mainly to preserve firmware-configured passthrough paths and guarantee a clean handover.

If you’re thinking about hacking this for pkvm / seL4 / bare-metal experiments, the TL;DR is:

* If you reprogram the MC SID overrides “too early”, you risk breaking any engine that firmware is still driving using a bypass SID.
* If you do it around the time you attach the device to your own translation regime (or after you’ve installed identity mappings), life is much less exciting.

[1]: https://gbmc.googlesource.com/linux/%2B/72c81bb67026a07d7cd40418520269e12f0657cb%5E%21/?utm_source=chatgpt.com "Diff - 72c81bb67026a07d7cd40418520269e12f0657cb^! - linux"
[2]: https://git.doit.wisc.edu/SWIFT/linux-ldos/-/blob/master/include/soc/tegra/mc.h?utm_source=chatgpt.com "include/soc/tegra/mc.h · master · Michael Swift / linux-ldos"
[3]: https://lists.infradead.org/pipermail/linux-arm-kernel/2021-April/653375.html " [PATCH v2 05/10] iommu/arm-smmu: tegra: Implement SID override programming
   "
[4]: https://lwn.net/Articles/907924/?utm_source=chatgpt.com "Support for NVDEC on Tegra234"
[5]: https://patchew.org/linux/20220329044436.27732-1-amhetre%40nvidia.com/?utm_source=chatgpt.com "Use arm-smmu-nvidia impl for Tegra234 - [Patch v1] iommu"
[6]: https://lists.yoctoproject.org/g/linux-yocto/topic/v5_15_standard_nvidia/106847209?utm_source=chatgpt.com "linux-yocto@lists.yoctoproject.org | [v5.15/standard] Nvidia ..."

