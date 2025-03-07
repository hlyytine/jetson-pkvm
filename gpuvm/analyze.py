#! /usr/bin/python

from jinja2 import Template
from collections import defaultdict

import libfdt

# Load the DTB file
dtb_path = "nv.dtb"  # Update this path if necessary

with open(dtb_path, "rb") as f:
    dtb = f.read()

# Parse the DTB
fdt = libfdt.Fdt(dtb)

#'nvidia,tegra234-host1x'

def full_nodename(offset):
    name = fdt.get_name(offset)
    try:
        parent_offset = fdt.parent_offset(offset)
        return full_nodename(parent_offset) + '/' + name

    except libfdt.FdtException as e:
        if e.err == -libfdt.FDT_ERR_NOTFOUND:
            return ''
        # TODO: add raise here


def list_matching_nodes(propname, propvalue, offset=0):
    """ Walk the device tree and return nodes that are compatible """

    # Iterate over child nodes
    nodes = {}
    subnode_offset = fdt.first_subnode(offset, libfdt.QUIET_NOTFOUND)
    while subnode_offset >= 0:
        nodes.update(list_matching_nodes(propname, propvalue, subnode_offset))
        subnode_offset = fdt.next_subnode(subnode_offset, libfdt.QUIET_NOTFOUND)

    try:
        node_matches = False
        if propname is not None:
            prop = fdt.getprop(offset, propname)
            if type(propvalue) == str:
                if any(string == propvalue for string in prop.as_stringlist()):
                    node_matches = True
            else:
                if (prop.as_uint32() == propvalue):
                    node_matches = True
        else:
            node_matches = True

        if node_matches:
            nodes[offset] = {
                'name' : full_nodename(offset),
                'phandle' : fdt.get_phandle(offset),
            }

            iommus_prop = fdt.getprop(offset, 'iommus').as_uint32_list()
            if len(iommus_prop) == 2:
                nodes[offset]['iommu_phandle'] = iommus_prop[0]
                nodes[offset]['iommu_stream'] = iommus_prop[1]
            elif len(iommus_prop) == 0:
                pass
            else:
                raise ValueError('iommus property length can be only 0 or 2')


    except libfdt.FdtException as e:
        if e == libfdt.FDT_ERR_NOTFOUND:
            pass 

    return nodes

def list_subnodes(offset=0):
    """ Recursively print all subnodes of a given node """
    return list_matching_nodes(None, None, offset)

introduction_template = """
# Requirements on moving GPU to guest VM

This Python script takes a device tree blob (DTB) and analyzes it to give
either recommendations or exact instructions on how the host and guest
systems must be modified.
"""

print(Template(introduction_template).render())

host1x_template = """
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
"""

print(Template(host1x_template).render())

# Find the host1x device we wish to move to guest; currently there should exactly one
# of them, otherwise we need to do some more thinking.
host1x_nodes = list_matching_nodes('compatible', 'nvidia,tegra234-host1x')

match len(host1x_nodes):
    case 0:
        print("No host1x devices found, quitting.")
        exit(1)
    case 1:
        host1x_offset = next(iter(host1x_nodes))
        host1x_node = host1x_nodes[host1x_offset]
        print("\nUsing " + host1x_node['name'] + "\n")
    case _:
        print("Current approach is not designed with multiple host1x devices in mind, quitting.")
        exit(1)

# at this point host1x_offset and host1x_phandle are guaranteed to be correct

nodes_to_move = { host1x_offset: host1x_node }

''' next we list all devices that use this host1x (PCIe endpoints for example) '''

#for host1x_offset, host1x_node in host1x_nodes.items():

nodes_referring_host1x = list_matching_nodes('nvidia,host1x', host1x_node['phandle'])
if len(nodes_referring_host1x) > 0:
    print('Nodes referring to this host1x device via their "nvidia,host1x" property:')

for ref_offset, ref_node in nodes_referring_host1x.items():
    print("  " + ref_node['name'])

nodes_to_move.update(nodes_referring_host1x)

for node_offset in nodes_to_move.copy().keys():
    nodes_to_move.update(list_subnodes(node_offset))

node_template = """
{%macro iommu_string(phandle, stream) -%}
{%if phandle -%}
IOMMU: (phandle: {{ '0x%0x' % phandle }}, stream: {{ '0x%0x' % stream }})
{%- else -%}
{%- endif %}
{%- endmacro -%}

## Subnodes to nodes that we must move to guest
{% for offset, details in data.items() -%}
- **{{ details.name }}** {{ iommu_string(details.iommu_phandle, details.iommu_stream) }}
{% endfor %}
"""

sorted_data = dict(sorted(nodes_to_move.items(), key=lambda item: item[1]["name"]))
md_output = Template(node_template).render(data=sorted_data)
print(md_output)

iommu_phandles = {
    props['iommu_phandle']: fdt.node_offset_by_phandle(props['iommu_phandle'])
    for props in nodes_to_move.values()
    if 'iommu_phandle' in props
}

print("IOMMU phandles referenced")
print(iommu_phandles)

iommu_streams = defaultdict(dict)

for offset, attrs in nodes_to_move.items():
    if 'iommu_phandle' in attrs and 'iommu_stream' in attrs:
        iommu_streams[attrs['iommu_phandle']][attrs['iommu_stream']] = offset

iommu_streams = dict(iommu_streams)

for phandle in iommu_phandles:
    print("IOMMU " + full_nodename(iommu_phandles[phandle]) + ':')
    for stream, offset in iommu_streams[phandle].items():
        print(f"stream {stream}: " + full_nodename(offset))

