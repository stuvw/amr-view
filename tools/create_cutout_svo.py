import argparse
import struct
from concurrent.futures import ProcessPoolExecutor
import numpy as np
from numba import njit
from tqdm import tqdm
import yt

# Safeguard parameters
F32_MAX = 3.4028234e38
F32_MIN = -3.4028234e38


# ==============================================================================
# Numba JIT Kernels for Morton Encoding & Tree Operations
# ==============================================================================


@njit(inline="always")
def split_by_3(a):
    """Interleave 21 bits of a 64-bit integer by inserting 2 zeros after each bit."""
    x = a & np.uint64(0x1FFFFF)
    x = (x | (x << np.uint64(32))) & np.uint64(0x1F00000000FFFF)
    x = (x | (x << np.uint64(16))) & np.uint64(0x1F0000FF0000FF)
    x = (x | (x << np.uint64(8))) & np.uint64(0x100F00F00F00F00F)
    x = (x | (x << np.uint64(4))) & np.uint64(0x10C30C30C30C30C3)
    x = (x | (x << np.uint64(2))) & np.uint64(0x1249249249249249)
    return x


@njit
def encode_morton3d(x, y, z):
    """Encode 3D 21-bit integer coordinates into a single 63-bit Morton code."""
    return (
        (split_by_3(z) << np.uint64(2))
        | (split_by_3(y) << np.uint64(1))
        | split_by_3(x)
    )


@njit
def compute_morton_keys(cx_arr, cy_arr, cz_arr, root_center, root_size):
    """Compute 64-bit Morton keys for cell coordinates relative to the root domain."""
    n = len(cx_arr)
    keys = np.empty(n, dtype=np.uint64)
    left_x = root_center[0] - root_size * 0.5
    left_y = root_center[1] - root_size * 0.5
    left_z = root_center[2] - root_size * 0.5

    scale = (1 << 21) / root_size

    for i in range(n):
        ix = np.uint64(
            max(0.0, min((1 << 21) - 1, (cx_arr[i] - left_x) * scale))
        )
        iy = np.uint64(
            max(0.0, min((1 << 21) - 1, (cy_arr[i] - left_y) * scale))
        )
        iz = np.uint64(
            max(0.0, min((1 << 21) - 1, (cz_arr[i] - left_z) * scale))
        )
        keys[i] = encode_morton3d(ix, iy, iz)

    return keys


@njit
def build_octree_numba(
    cx_arr,
    cy_arr,
    cz_arr,
    dx_arr,
    qty_arr,
    w_arr,
    root_center,
    root_size,
    max_nodes,
):
    """Build octree using pre-allocated flat arrays instead of heap-allocated objects."""
    children = np.full((max_nodes, 8), -1, dtype=np.int32)
    is_leaf = np.zeros(max_nodes, dtype=np.bool_)
    qty = np.zeros(max_nodes, dtype=np.float32)
    weight = np.zeros(max_nodes, dtype=np.float32)

    node_count = 1  # Index 0 is reserved for master root node
    rx, ry, rz = root_center[0], root_center[1], root_center[2]
    num_cells = len(cx_arr)
    max_depth = 0

    for i in range(num_cells):
        cell_x = cx_arr[i]
        cell_y = cy_arr[i]
        cell_z = cz_arr[i]
        dx = dx_arr[i]
        q = qty_arr[i]
        w = w_arr[i]

        curr_node = 0
        ccx, ccy, ccz = rx, ry, rz
        curr_size = root_size
        depth = 0

        while curr_size > (dx * 1.001):
            octant = 0
            if cell_x >= ccx:
                octant |= 1
            if cell_y >= ccy:
                octant |= 2
            if cell_z >= ccz:
                octant |= 4

            child_idx = children[curr_node, octant]
            if child_idx == -1:
                child_idx = node_count
                children[curr_node, octant] = child_idx
                node_count += 1

            curr_size *= 0.5
            depth += 1

            half_size = curr_size * 0.5
            ccx += half_size if (octant & 1) else -half_size
            ccy += half_size if (octant & 2) else -half_size
            ccz += half_size if (octant & 4) else -half_size

            curr_node = child_idx

        if depth > max_depth:
            max_depth = depth

        is_leaf[curr_node] = True
        qty[curr_node] = q
        weight[curr_node] = w

    return children, is_leaf, qty, weight, node_count, max_depth


@njit
def serialize_svo_numba(children, is_leaf, qty, weight, total_nodes):
    """Serialize the flat tree representation into contiguous 8-byte SVO nodes."""
    out_nodes = np.zeros((total_nodes, 2), dtype=np.uint32)
    out_floats = out_nodes.view(np.float32)

    queue_node = np.empty(total_nodes, dtype=np.int32)
    queue_out_idx = np.empty(total_nodes, dtype=np.int32)
    q_head = 0
    q_tail = 0

    # Push master root
    queue_node[0] = 0
    queue_out_idx[0] = 0
    q_tail = 1

    next_free_index = 1
    num_leaves = 0
    num_branches = 0

    while q_head < q_tail:
        curr = queue_node[q_head]
        out_idx = queue_out_idx[q_head]
        q_head += 1

        if is_leaf[curr]:
            num_leaves += 1
            out_floats[out_idx, 0] = qty[curr]
            out_floats[out_idx, 1] = weight[curr]
        else:
            num_branches += 1
            child_mask = np.uint32(0)
            num_present = 0

            for octant in range(8):
                child = children[curr, octant]
                if child != -1:
                    child_mask |= np.uint32(1 << octant)
                    if is_leaf[child]:
                        child_mask |= np.uint32(1 << (octant + 8))
                    num_present += 1

            if num_present > 0:
                child_start_idx = next_free_index
                next_free_index += num_present
                p_count = 0
                for octant in range(8):
                    child = children[curr, octant]
                    if child != -1:
                        queue_node[q_tail] = child
                        queue_out_idx[q_tail] = child_start_idx + p_count
                        q_tail += 1
                        p_count += 1
                child_idx = child_start_idx
            else:
                child_idx = 0

            out_nodes[out_idx, 0] = np.uint32(child_idx)
            out_nodes[out_idx, 1] = np.uint32(child_mask)

    return out_nodes, next_free_index, num_branches, num_leaves


# ==============================================================================
# Worker Extraction Task
# ==============================================================================


def extract_octant_worker(
    octant_idx,
    path,
    field,
    weight,
    field_unit,
    weight_unit,
    root_center,
    root_size,
):
    """Extract raw cell data into flat NumPy arrays (zero-object allocation)."""
    child_size = root_size * 0.5
    rx, ry, rz = root_center[0], root_center[1], root_center[2]

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

    local_ds = yt.load(path)
    box = local_ds.box(child_left_edge, child_right_edge)

    x_list, y_list, z_list, dx_list, qty_list, w_list = [], [], [], [], [], []

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
            x_list.append(cx_arr.astype(np.float64))
            y_list.append(cy_arr.astype(np.float64))
            z_list.append(cz_arr.astype(np.float64))
            dx_list.append(dx_arr.astype(np.float64))
            qty_list.append(field_data.astype(np.float32))
            w_list.append(weight_data.astype(np.float32))

    del box
    del local_ds

    if len(x_list) > 0:
        return (
            np.concatenate(x_list),
            np.concatenate(y_list),
            np.concatenate(z_list),
            np.concatenate(dx_list),
            np.concatenate(qty_list),
            np.concatenate(w_list),
        )
    return None


# ==============================================================================
# Main Orchestration Engine
# ==============================================================================

if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Extract a grid-aligned AMR cube and write to optimized SVO binary."
    )
    parser.add_argument("path", type=str, help="Path to simulation dataset.")
    parser.add_argument(
        "--center", type=float, nargs=3, required=True, help="Center (x, y, z)."
    )
    parser.add_argument(
        "--size", type=float, required=True, help="Cube edge length."
    )
    parser.add_argument(
        "--field", type=str, required=True, nargs=2, help="Field and unit."
    )
    parser.add_argument(
        "--weight", type=str, required=True, nargs=2, help="Weight and unit."
    )
    parser.add_argument(
        "--output", type=str, required=True, help="Output file path."
    )

    args = parser.parse_args()

    # Step 1: Metadata Initialization
    print("==================================================")
    print("STAGE 1: Dataset Metadata Initialization")
    print("==================================================")
    ds = yt.load(args.path)
    name = ds.filename
    max_level = ds.index.max_level

    field_name, field_unit = args.field
    weight_name, weight_unit = args.weight

    field = tuple(field_name.split(".")) if "." in field_name else field_name
    weight = (
        tuple(weight_name.split(".")) if "." in weight_name else weight_name
    )

    req_center = np.array(args.center)
    req_size = args.size

    req_level = int(np.round(np.log2(1.0 / req_size)))
    level = min(max(0, req_level), max_level)
    min_dx = 1.0 / (2**max_level)
    root_size = 1.0 / (2**level)

    root_center = (np.floor(req_center / min_dx) + 0.5) * min_dx
    left_edge = root_center - root_size / 2
    right_edge = root_center + root_size / 2

    print(f"Requested Center : {req_center}")
    print(f"Snapped Size     : {root_size} (Level {level}/{max_level})")
    print(f"Snapped Center   : {root_center}\n")

    del ds

    # Step 2: Parallel Ingestion (Returns Flat NumPy Arrays)
    print("==================================================")
    print("STAGE 2: Parallel Ingestion across 8 Workers")
    print("==================================================")
    octant_data = [None] * 8

    with ProcessPoolExecutor(max_workers=8) as executor:
        futures = {
            executor.submit(
                extract_octant_worker,
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

        for future in tqdm(
            futures, desc="Ingesting AMR octants", unit="octant"
        ):
            octant_idx = futures[future]
            octant_data[octant_idx] = future.result()

    # Combine extracted flat arrays
    valid_data = [d for d in octant_data if d is not None]
    if not valid_data:
        raise ValueError("No AMR cells found in the requested region.")

    cx_all = np.concatenate([d[0] for d in valid_data])
    cy_all = np.concatenate([d[1] for d in valid_data])
    cz_all = np.concatenate([d[2] for d in valid_data])
    dx_all = np.concatenate([d[3] for d in valid_data])
    qty_all = np.concatenate([d[4] for d in valid_data])
    w_all = np.concatenate([d[5] for d in valid_data])

    print(f"-> Total AMR cells extracted: {len(cx_all):,}")

    # Step 3: Morton Code Sorting
    print("\n==================================================")
    print("STAGE 3: Morton Key Generation & Spatial Sorting")
    print("==================================================")
    morton_keys = compute_morton_keys(
        cx_all, cy_all, cz_all, root_center, root_size
    )
    sort_idx = np.argsort(morton_keys)

    cx_all = cx_all[sort_idx]
    cy_all = cy_all[sort_idx]
    cz_all = cz_all[sort_idx]
    dx_all = dx_all[sort_idx]
    qty_all = qty_all[sort_idx]
    w_all = w_all[sort_idx]

    print("-> Data spatial locality sorted successfully.")

    # Step 4: Flat Numba Tree Construction
    print("\n==================================================")
    print("STAGE 4: JIT-Compiled Octree Construction")
    print("==================================================")
    # Estimate max nodes required (3x cell count is an ultra-safe upper bound for AMR trees)
    max_expected_nodes = max(1000, int(len(cx_all) * 3))

    children, is_leaf, qty, weight, total_nodes, max_depth = build_octree_numba(
        cx_all,
        cy_all,
        cz_all,
        dx_all,
        qty_all,
        w_all,
        root_center,
        root_size,
        max_expected_nodes,
    )

    print(f"-> Total unique internal nodes created: {total_nodes:,}")
    print(f"-> Calculated tree max depth: {max_depth}")

    # Step 5: Fast SVO Serialization
    print("\n==================================================")
    print("STAGE 5: Dense SVO Layout Serialization")
    print("==================================================")
    out_nodes, next_free_index, num_branches, num_leaves = serialize_svo_numba(
        children, is_leaf, qty, weight, total_nodes
    )

    # Step 6: Binary Export
    print("\n==================================================")
    print("STAGE 6: File Export")
    print("==================================================")
    header_field = ":".join(args.field)
    header_weight = ":".join(args.weight)

    with open(args.output, "wb") as f:
        f.write("AMR-VIEW".encode("ascii"))
        f.write(
            struct.pack(
                "<BBBQQQQffff",
                0,
                2,
                0,
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

        f.write(struct.pack("<Q", len(name)))
        f.write(name.encode("ascii"))
        f.write(struct.pack("<Q", len(header_field)))
        f.write(header_field.encode("ascii"))
        f.write(struct.pack("<Q", len(header_weight)))
        f.write(header_weight.encode("ascii"))

        # Fast contiguous write directly from NumPy memory buffer
        f.write(out_nodes[:next_free_index].tobytes())

    total_bytes = (
        96
        + len(name)
        + len(header_field)
        + len(header_weight)
        + (next_free_index * 8)
    )

    print("\n==================================================")
    print("EXPORT SUMMARY")
    print("==================================================")
    print(f"Total Nodes Processed : {next_free_index:,}")
    print(f"  └─ Branch Nodes     : {num_branches:,}")
    print(f"  └─ Leaf Nodes       : {num_leaves:,}")
    print(f"Output File Size      : {total_bytes / (1024 * 1024):.2f} MB")
    print(f"Field Value Range     : [{np.min(qty_all):.3e}, {np.max(qty_all):.3e}]")
    print(f"Weight Value Range    : [{np.min(w_all):.3e}, {np.max(w_all):.3e}]")
    print("==================================================")
    print("Done!")
