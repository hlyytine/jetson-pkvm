
# Requirements on moving GPU to guest VM

This Python script takes a device tree blob (DTB) and analyzes it to give
either recommendations or exact instructions on how the host and guest
systems must be modified.

## host1x on NVIDIA Orin AGX

NVIDIA's platforms have `host1x` which can be described as a hardware higher-level
DMA controller. It manages the interplay between DMA engines and the IOMMUs and
whereas traditionally software based solutions are used to control executions flows
between two VMs, NVIDIA supports doing it in hardware via so called _syncpoints_.

The `host1x` hardware naturally supports GPU virtualization but the software support
exists only on the closed source NVIDIA Drive OS. While in seL4-microkernel based
virtualization it would be straightforward to implement `host1x` support as a secure
system service, limiting guest accesses with seL4's mathematically proven capability
system, in Linux we have either to write the software completely, or like in this
case, move access to `host1x` to guest VM.

NVIDIA's platforms keep evolving and `host1x` capabilities seem to be extending
on each step, so it might be at some point in the future there might be multiple
`host1x` devices and we need to rethink our strategy. Meanwhile, let's just find
out if there's one and only one `host1x` and dig out the details on this. For this
analysis, we assume we are working on NVIDIA Orin AGX or any other Tegra 234
derivative.

Using /bus@0/host1x@13e00000

Nodes referring to this host1x device via their "nvidia,host1x" property:
  /bus@0/pcie-ep@140e0000
  /bus@0/pcie-ep@141a0000
  /bus@0/pcie-ep@141c0000
  /bus@0/pcie-ep@141e0000
  /bus@0/pcie-ep@14160000

## Subnodes to nodes that we must move to guest
- **/bus@0/host1x@13e00000** IOMMU: (phandle: 0xf3, stream: 0x27)
- **/bus@0/host1x@13e00000/crypto@15810000** 
- **/bus@0/host1x@13e00000/crypto@15820000** IOMMU: (phandle: 0xf3, stream: 0x2e)
- **/bus@0/host1x@13e00000/crypto@15840000** IOMMU: (phandle: 0xf3, stream: 0x2f)
- **/bus@0/host1x@13e00000/isp-thi@14b00000** IOMMU: (phandle: 0xf3, stream: 0x28)
- **/bus@0/host1x@13e00000/isp@14800000** IOMMU: (phandle: 0xf3, stream: 0x28)
- **/bus@0/host1x@13e00000/nvcsi@15a00000** 
- **/bus@0/host1x@13e00000/nvdec@15480000** IOMMU: (phandle: 0xf3, stream: 0x29)
- **/bus@0/host1x@13e00000/nvdla0@15880000** IOMMU: (phandle: 0xf3, stream: 0x2b)
- **/bus@0/host1x@13e00000/nvdla1@158c0000** IOMMU: (phandle: 0x4, stream: 0x23)
- **/bus@0/host1x@13e00000/nvenc@154c0000** IOMMU: (phandle: 0x4, stream: 0x24)
- **/bus@0/host1x@13e00000/nvjpg@15380000** IOMMU: (phandle: 0xf3, stream: 0x2a)
- **/bus@0/host1x@13e00000/nvjpg@15540000** IOMMU: (phandle: 0x4, stream: 0x25)
- **/bus@0/host1x@13e00000/ofa@15a50000** IOMMU: (phandle: 0x4, stream: 0x26)
- **/bus@0/host1x@13e00000/pva0@16000000** IOMMU: (phandle: 0xf3, stream: 0x2c)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx0** IOMMU: (phandle: 0xf3, stream: 0x12)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx1** IOMMU: (phandle: 0xf3, stream: 0x13)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx2** IOMMU: (phandle: 0xf3, stream: 0x14)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx3** IOMMU: (phandle: 0xf3, stream: 0x15)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx4** IOMMU: (phandle: 0xf3, stream: 0x16)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx5** IOMMU: (phandle: 0xf3, stream: 0x17)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx6** IOMMU: (phandle: 0xf3, stream: 0x18)
- **/bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx7** IOMMU: (phandle: 0xf3, stream: 0x19)
- **/bus@0/host1x@13e00000/tsec@15500000** IOMMU: (phandle: 0xf3, stream: 0x33)
- **/bus@0/host1x@13e00000/vi0-thi@15f00000** IOMMU: (phandle: 0x113, stream: 0x2)
- **/bus@0/host1x@13e00000/vi0@15c00000** IOMMU: (phandle: 0x113, stream: 0x2)
- **/bus@0/host1x@13e00000/vi1-thi@14f00000** IOMMU: (phandle: 0x113, stream: 0x4)
- **/bus@0/host1x@13e00000/vi1@14c00000** IOMMU: (phandle: 0x113, stream: 0x4)
- **/bus@0/host1x@13e00000/vic@15340000** IOMMU: (phandle: 0xf3, stream: 0x34)
- **/bus@0/pcie-ep@140e0000** IOMMU: (phandle: 0xf3, stream: 0xb)
- **/bus@0/pcie-ep@14160000** IOMMU: (phandle: 0x4, stream: 0x13)
- **/bus@0/pcie-ep@141a0000** IOMMU: (phandle: 0x4, stream: 0x14)
- **/bus@0/pcie-ep@141c0000** IOMMU: (phandle: 0x4, stream: 0x15)
- **/bus@0/pcie-ep@141e0000** IOMMU: (phandle: 0xf3, stream: 0x8)

IOMMU phandles referenced
{243: 65060, 4: 75360, 275: 73596}
IOMMU /bus@0/iommu@8000000:
stream 39: /bus@0/host1x@13e00000
stream 11: /bus@0/pcie-ep@140e0000
stream 8: /bus@0/pcie-ep@141e0000
stream 52: /bus@0/host1x@13e00000/vic@15340000
stream 41: /bus@0/host1x@13e00000/nvdec@15480000
stream 46: /bus@0/host1x@13e00000/crypto@15820000
stream 47: /bus@0/host1x@13e00000/crypto@15840000
stream 42: /bus@0/host1x@13e00000/nvjpg@15380000
stream 51: /bus@0/host1x@13e00000/tsec@15500000
stream 43: /bus@0/host1x@13e00000/nvdla0@15880000
stream 18: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx0
stream 19: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx1
stream 20: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx2
stream 21: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx3
stream 22: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx4
stream 23: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx5
stream 24: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx6
stream 25: /bus@0/host1x@13e00000/pva0@16000000/pva0_niso1_ctx7
stream 44: /bus@0/host1x@13e00000/pva0@16000000
stream 40: /bus@0/host1x@13e00000/isp-thi@14b00000
IOMMU /bus@0/iommu@12000000:
stream 20: /bus@0/pcie-ep@141a0000
stream 21: /bus@0/pcie-ep@141c0000
stream 19: /bus@0/pcie-ep@14160000
stream 36: /bus@0/host1x@13e00000/nvenc@154c0000
stream 37: /bus@0/host1x@13e00000/nvjpg@15540000
stream 38: /bus@0/host1x@13e00000/ofa@15a50000
stream 35: /bus@0/host1x@13e00000/nvdla1@158c0000
IOMMU /bus@0/iommu@10000000:
stream 2: /bus@0/host1x@13e00000/vi0-thi@15f00000
stream 4: /bus@0/host1x@13e00000/vi1-thi@14f00000
