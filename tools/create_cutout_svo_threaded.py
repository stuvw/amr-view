import argparse
import struct
from collections import deque
from concurrent.futures import ProcessPoolExecutor
import numpy as np
from tqdm import tqdm
import yt

# Safeguard parameters
F32_MAX = 3.4028234e38
F32_MIN = -3.4028234e38


# 1. Define Optimized In-Memory Node Structure (Must be top-level for pickling)
class SVOBuilderNode:
    __slots__ = ["is_leaf", "qty", "w", "children"]

    def __init__(self):
        self.is_leaf = False
        self.qty = 0.0
        self.w = 0.0
        self.children = None


# 2. Worker Task for Independent Process Octant Tree Generation
def build_octant_worker(
    octant_idx,
    path,
    field,
    weight,
    field_unit,
    weight_unit,
    root_center,
    root_size,
):
    child_size = root_size * 0.5
    quarter_size = root_size * 0.25

    rx, ry, rz = root_center[0], root_center[1], root_center[2]

    # Mathematically compute the exact bounding box and center for this specific octant
    cx = rx + (quarter_size if (octant_idx & 1) else -quarter_size)
    cy = ry + (quarter_size if (octant_idx & 2) else -quarter_size)
    cz = rz + (quarter_size if (octant_idx & 4) else -quarter_size)

    child_left_edge = [
        rx if (octant_idx & 1) else rx - child_size,
        ry if (octant_idx & 2) else ry - child_size,
        rz if (octant_idx & 4) else rz - child_size,
    ]
    child_right_edge = [
        rx + child_size if (octant_idx & 1) else rx,
        ry + child_size if (octant_idx & 2) else ry,
        rz + child_size if (octant_idx & 4) else rz,
    ]

    # Load completely separate dataset instances per-process to avoid race conditions
    local_ds = yt.load(path)
    box = local_ds.box(child_left_edge, child_right_edge)

    child_root = SVOBuilderNode()

    local_max_depth = 0
    local_max_qty = float("-inf")
    local_max_w = float("-inf")
    has_cells = False

    # Process chunks inside the isolated process core
    for chunk in box.chunks([field, weight], "io"):
        cx_arr = chunk[("index", "x")].to("unitary").d
        cy_arr = chunk[("index", "y")].to("unitary").d
        cz_arr = chunk[("index", "z")].to("unitary").d
        dx_arr = chunk[("index", "dx")].to("unitary").d

        field_data = chunk[field].to(field_unit).d
        weight_data = chunk[weight].to(weight_unit).d

        field_data = np.nan_to_num(
            field_data, nan=0.0, posinf=F32_MAX, neginf=F32_MIN
        )
        weight_data = np.nan_to_num(
            weight_data, nan=0.0, posinf=F32_MAX, neginf=F32_MIN
        )

        if len(cx_arr) > 0:
            has_cells = True

        for i in range(len(cx_arr)):
            cell_x, cell_y, cell_z = cx_arr[i], cy_arr[i], cz_arr[i]
            dx = dx_arr[i]
            qty = field_data[i]
            w = weight_data[i]

            if qty > local_max_qty:
                local_max_qty = qty
            if w > local_max_w:
                local_max_w = w

            curr_node = child_root
            ccx, ccy, ccz = cx, cy, cz
            curr_size = child_size
            depth = 1  # Base depth of 1 relative to the master root node

            while curr_size > (dx * 1.001):
                octant = 0
                if cell_x >= ccx:
                    octant |= 1
                if cell_y >= ccy:
                    octant |= 2
                if cell_z >= ccz:
                    octant |= 4

                if curr_node.children is None:
                    curr_node.children = [None] * 8

                if curr_node.children[octant] is None:
                    curr_node.children[octant] = SVOBuilderNode()

                curr_size *= 0.5
                depth += 1

                half_size = curr_size * 0.5
                ccx += half_size if (octant & 1) else -half_size
                ccy += half_size if (octant & 2) else -half_size
                ccz += half_size if (octant & 4) else -half_size

                curr_node = curr_node.children[octant]

            if depth > local_max_depth:
                local_max_depth = depth

            curr_node.is_leaf = True
            curr_node.qty = qty
            curr_node.w = w

    del box
    del local_ds

    if has_cells:
        return (child_root, local_max_depth, local_max_qty, local_max_w)
    return (None, 0, 0, 0)


# 3. Main Execution Engine Guard
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Extract a grid-aligned AMR cube from RAMSES and export as an AMR-view binary."
    )
    parser.add_argument(
        "path", type=str, help="Path to the simulation dataset."
    )
    parser.add_argument(
        "--center",
        type=float,
        nargs=3,
        required=True,
        help="Requested center of the cube (x, y, z) in code units.",
    )
    parser.add_argument(
        "--size",
        type=float,
        required=True,
        help="Requested edge length of the cube in code units.",
    )
    parser.add_argument(
        "--field",
        type=str,
        required=True,
        nargs=2,
        help="Field to extract and its unit.",
    )
    parser.add_argument(
        "--weight",
        type=str,
        required=True,
        nargs=2,
        help="Weight field and its unit.",
    )
    parser.add_argument(
        "--output", type=str, required=True, help="Output binary file path."
    )

    args = parser.parse_args()

    # Step 1: Initialize metadata
    print("==================================================")
    print("STAGE 1: Dataset Metadata Initialization")
    print("==================================================")
    print(f"-> Loading dataset structure from: {args.path}")
    ds = yt.load(args.path)

    name = ds.filename

    max_level = ds.index.max_level

    field_name, field_unit = args.field
    weight_name, weight_unit = args.weight

    field = tuple(field_name.split(".")) if "." in field_name else field_name
    weight = tuple(weight_name.split(".")) if "." in weight_name else weight_name

    req_center = np.array(args.center)
    req_size = args.size

    req_level = int(np.round(np.log2(1.0 / req_size)))
    level = min(max(0, req_level), max_level)
    min_dx = 1.0 / (2**max_level)
    root_size = 1.0 / (2**level)

    root_center = (np.floor(req_center / min_dx) + 0.5) * min_dx
    left_edge = root_center - root_size / 2
    right_edge = root_center + root_size / 2

    print("\n--- Grid Alignment Info ---")
    print(f"Requested Center : {req_center}")
    print(f"Requested Size   : {req_size}")
    print(f"Snapped Size     : {root_size} (Level {level}/{max_level})")
    print(f"Snapped Center   : {root_center}")
    print(f"Snapped Bounds   : Min={left_edge}, Max={right_edge}\n")

    # Clean up global metadata reference before spawning processes
    del ds

    # Step 2: Parallel Ingestion
    print("==================================================")
    print("STAGE 2: Parallel Ingestion across 8 Workers")
    print("==================================================")
    process_results = [None] * 8

    with ProcessPoolExecutor(max_workers=8) as executor:
        futures = {
            executor.submit(
                build_octant_worker,
                o,
                args.path,
                field,
                weight,
                field_unit,
                weight_unit,
                root_center.tolist(),
                root_size,
            ): o
            for o in range(8)
        }

        # Track completion safely
        for future in tqdm(
            futures, desc="Ingesting parallel AMR octants", unit="octant"
        ):
            octant_idx = futures[future]
            process_results[octant_idx] = future.result()

    # Step 3: Master Root Tree Stitching
    print("\n==================================================")
    print("STAGE 3: Stitching Octree Master Root")
    print("==================================================")
    svo_root = SVOBuilderNode()
    svo_root.children = [None] * 8

    max_depth = 0
    max_qty = float("-inf")
    max_w = float("-inf")
    min_qty = float("+inf")
    min_w = float("+inf")

    active_octants = 0
    for o in range(8):
        res = process_results[o]
        if res is not None and res[0] is not None:
            active_octants += 1
            child_root, l_depth, l_qty, l_w = res
            svo_root.children[o] = child_root
            if l_depth > max_depth:
                max_depth = l_depth

            max_qty = max(max_qty, l_qty)
            max_w = max(max_w, l_w)
            min_qty = min(min_qty, l_qty)
            min_w = min(min_w, l_w)

    print(f"-> Successfully stitched {active_octants}/8 active sub-octants.")
    print(f"-> Maximum tree depth determined: {max_depth}")

    # Step 4: Compact Serialization
    print("\n==================================================")
    print("STAGE 4: Serializing Tree to Sparse Voxel Layout")
    print("==================================================")

    serialization_queue = deque([(svo_root, 0)])
    flat_output_blocks = bytearray(8)
    next_free_index = 1

    num_leaves = 0
    num_branches = 0

    # Wrap BFS serialization loop with tqdm
    pbar = tqdm(desc="Serializing Nodes", unit="node")

    while len(serialization_queue) > 0:
        curr, out_idx = serialization_queue.popleft()
        pbar.update(1)

        required_size = (out_idx + 1) * 8
        if len(flat_output_blocks) < required_size:
            flat_output_blocks.extend(
                bytearray(required_size - len(flat_output_blocks))
            )

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
                        child_mask |= 1 << octant
                        if child.is_leaf:
                            child_mask |= 1 << (octant + 8)
                        present_children.append(child)

            if len(present_children) > 0:
                child_idx = next_free_index
                child_start_idx = next_free_index
                next_free_index += len(present_children)

                new_required_size = next_free_index * 8
                if len(flat_output_blocks) < new_required_size:
                    flat_output_blocks.extend(
                        bytearray(new_required_size - len(flat_output_blocks))
                    )

                for i, child in enumerate(present_children):
                    serialization_queue.append((child, child_start_idx + i))
            else:
                child_idx = 0

            block = struct.pack("<II", child_idx, child_mask)
            flat_output_blocks[out_idx * 8 : (out_idx + 1) * 8] = block

    pbar.close()

    # Step 5: Binary Disk Export
    print("\n==================================================")
    print("STAGE 5: Binary File Export")
    print("==================================================")
    print(f"-> Writing binary output file to: {args.output}")

    with open(args.output, "wb") as f:
        f.write("AMR-VIEW".encode("ascii"))
        f.write(
            struct.pack(
                "<BBBQQQQffff",
                0, 2, 0,
                next_free_index,
                num_branches,
                num_leaves,
                max_depth,
                root_size,
                root_center[0],
                root_center[1],
                root_center[2],
            )
        )

        header_field = ':'.join((args.field))
        header_weight = ':'.join((args.weight))

        f.write(struct.pack("<Q", len(name)))
        f.write(name.encode("ascii"))
        f.write(struct.pack("<Q", len(header_field)))
        f.write(header_field.encode("ascii"))
        f.write(struct.pack("<Q", len(header_weight)))
        f.write(header_weight.encode("ascii"))


        f.write(flat_output_blocks[: next_free_index * 8])

    total_bytes = 96 + len(name) + len(header_field) + len(header_weight) + (next_free_index * 8)

    print("\n==================================================")
    print("EXPORT SUMMARY")
    print("==================================================")
    print(f"Total Nodes Processed : {next_free_index:,}")
    print(f"  └─ Branch Nodes     : {num_branches:,}")
    print(f"  └─ Leaf Nodes       : {num_leaves:,}")
    print(
        f"Total Output Size     : {total_bytes / (1024 * 1024):.2f} MB ({total_bytes:,} bytes)"
    )
    print(f"Field Value Range     : [{min_qty:.3e}, {max_qty:.3e}]")
    print(f"Weight Value Range    : [{min_w:.3e}, {max_w:.3e}]")
    print("==================================================")
    print("Done!")
