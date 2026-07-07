import argparse
import struct
from tqdm import tqdm
from collections import deque
import yt
import numpy as np

parser = argparse.ArgumentParser(
    description="Extract a grid-aligned AMR cube from RAMSES and export as a Vulkan SVO binary."
)
parser.add_argument("path", type=str, help="Path to the simulation dataset.")
parser.add_argument(
    "--center", type=float, nargs=3, required=True, help="Requested center of the cube (x, y, z) in code units."
)
parser.add_argument(
    "--size", type=float, required=True, help="Requested edge length of the cube in code units."
)
parser.add_argument("--field", type=str, required=True, nargs=2, help="Field to extract and its unit.")
parser.add_argument("--weight", type=str, required=True, nargs=2, help="Weight field and its unit.")
parser.add_argument("--output", type=str, required=True, help="Output binary file path.")

args = parser.parse_args()

# 1. Load the dataset
ds = yt.load(args.path)
max_level = ds.index.max_level

# Unpack field pairs
field_name, field_unit = args.field
weight_name, weight_unit = args.weight

# Convert strings to tuples if they contain dots
field = tuple(field_name.split(".")) if "." in field_name else field_name
weight = tuple(weight_name.split(".")) if "." in weight_name else weight_name

req_center = np.array(args.center)
req_size = args.size

# 2. Find the closest RAMSES octree parent block
req_level = int(np.round(np.log2(1.0 / req_size)))
level = min(max(0, req_level), max_level)
min_dx = 1.0 / (2 ** max_level)
root_size = 1.0 / (2 ** level)

root_center = (np.floor(req_center / min_dx) + 0.5) * min_dx
left_edge = root_center - root_size / 2
right_edge = root_center + root_size / 2

print(f"--- Grid Alignment Info ---")
print(f"Requested Center: {req_center}, Size: {req_size}")
print(f"Snapped Box Size (Root Size): {root_size}")
print(f"Snapped Left Edge:  {left_edge}")
print(f"Snapped Right Edge: {right_edge}")
print(f"Snapped Center:     {root_center}\n")

# 3. Create the data box region
box = ds.box(left_edge, right_edge)

# Safeguard parameters
F32_MAX = 3.4028234e38
F32_MIN = -3.4028234e38

# 4. Define Optimized In-Memory Node Structure
class SVOBuilderNode:
    __slots__ = ["is_leaf", "qty", "w", "children"]

    def __init__(self):
        self.is_leaf = False
        self.qty = 0.0
        self.w = 0.0
        self.children = None  # Dynamic allocation prevents wasting RAM on leaves

# Root of our local SVO
svo_root = SVOBuilderNode()

max_depth = 0
max_qty = 0
max_w = 0

# 5. Populate SVO via streamed point insertion (Chunking)
print("Ingesting AMR cells into SVO tree structure via chunking...")

# Request 'io' chunks to stream the spatial information and data fields smoothly
for chunk in tqdm(box.chunks([field, weight], "io"), desc="Processing dataset chunks"):
    cx_arr = chunk[("index", "x")].to("unitary").d
    cy_arr = chunk[("index", "y")].to("unitary").d
    cz_arr = chunk[("index", "z")].to("unitary").d
    dx_arr = chunk[("index", "dx")].to("unitary").d

    field_data = chunk[field].to(field_unit).d
    weight_data = chunk[weight].to(weight_unit).d

    # Sanitize inputs per chunk
    field_data = np.nan_to_num(field_data, nan=0.0, posinf=F32_MAX, neginf=F32_MIN)
    weight_data = np.nan_to_num(weight_data, nan=0.0, posinf=F32_MAX, neginf=F32_MIN)

    rx, ry, rz = root_center[0], root_center[1], root_center[2]

    for i in range(len(cx_arr)):
        cx, cy, cz = cx_arr[i], cy_arr[i], cz_arr[i]
        dx = dx_arr[i]
        qty = field_data[i]
        w = weight_data[i]

        if qty > max_qty: max_qty = qty
        if w > max_w: max_w = w
 
        curr_node = svo_root
 
        ccx, ccy, ccz = rx, ry, rz 
        curr_size = root_size
        depth = 0

        while curr_size > (dx * 1.001):
            octant = 0
            if cx >= ccx: octant |= 1
            if cy >= ccy: octant |= 2
            if cz >= ccz: octant |= 4
            
            # Lazily initialize children arrays only when a node becomes a branch
            if curr_node.children is None:
                curr_node.children = [None] * 8
                
            if curr_node.children[octant] is None:
                curr_node.children[octant] = SVOBuilderNode()
                
            curr_size *= 0.5
            depth += 1

            half_size = curr_size * 0.5
            ccx += half_size  if (octant & 1) else -half_size
            ccy += half_size if (octant & 2) else -half_size
            ccz += half_size if (octant & 4) else -half_size

            curr_node = curr_node.children[octant]
            
        
        max_depth = max(depth, max_depth)

        curr_node.is_leaf = True
        curr_node.qty = qty
        curr_node.w = w

# Safely eliminate reference to yt data storage before serialization
del box
del ds

# 6. Compact Serialization via Flat Dynamic Bytearray
serialization_queue = deque([(svo_root, 0)])

# Preallocate room for the root node block (8 bytes)
flat_output_blocks = bytearray(8) 
next_free_index = 1

num_leaves = 0
num_branches = 0

print("Serializing tree into compact Sparse Voxel format...")
while len(serialization_queue) > 0:
    curr, out_idx = serialization_queue.popleft()
    
    # Dynamic expansion tracking for out_idx placement
    required_size = (out_idx + 1) * 8
    if len(flat_output_blocks) < required_size:
        flat_output_blocks.extend(bytearray(required_size - len(flat_output_blocks)))

    if curr.is_leaf:
        num_leaves += 1
        block = struct.pack("<ff", curr.qty, curr.w)
        flat_output_blocks[out_idx * 8 : (out_idx + 1) * 8] = block
    else:
        num_branches += 1
        child_mask = 0
        present_children = []
        
        if curr.children is not None:
            for octant in range(8):
                child = curr.children[octant]
                if child is not None:
                    child_mask |= (1 << octant)
                    if child.is_leaf:
                        child_mask |= (1 << (octant + 8))
                    present_children.append(child)
                
        if len(present_children) > 0:
            child_idx = next_free_index
            child_start_idx = next_free_index
            next_free_index += len(present_children)
            
            # Predict and expand buffer sizes for newly tracked structural branches
            new_required_size = next_free_index * 8
            if len(flat_output_blocks) < new_required_size:
                flat_output_blocks.extend(bytearray(new_required_size - len(flat_output_blocks)))
            
            for i, child in enumerate(present_children):
                serialization_queue.append((child, child_start_idx + i))
        else:
            child_idx = 0
            
        block = struct.pack("<II", child_idx, child_mask)
        flat_output_blocks[out_idx * 8 : (out_idx + 1) * 8] = block

# 7. Rapid High-Throughput Binary File Write
print("Writing output blocks to file...")
with open(args.output, "wb") as f:
    f.write("AMR-VIEW".encode("ascii"))
    f.write(struct.pack(
        "<BBB5xQQQQffff", 
        0, 1, 0, 
        next_free_index, 
        num_branches, 
        num_leaves, 
        max_depth, 
        root_size, 
        root_center[0], root_center[1], root_center[2]
    ))
    # Write the active structural portion of our bytearray directly to disk
    f.write(flat_output_blocks[:next_free_index * 8])

print(f"Success! Generated packed SVO containing {next_free_index} nodes ({next_free_index * 8} bytes).")
print(f"Max qty = {max_qty}\nMax w = {max_w}")
