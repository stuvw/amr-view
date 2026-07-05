import argparse
import yt
import numpy as np

parser = argparse.ArgumentParser(
    description="Extract data from a sphere in a simulation dataset."
)
parser.add_argument("path", type=str, help="Path to the simulation dataset.")
parser.add_argument(
    "--center", type=float, nargs=3, required=True, help="Center of the sphere (x, y, z)."
)
parser.add_argument("--radius", type=float, required=True, help="Radius of the sphere.")
parser.add_argument("--field", type=str, required=True, nargs=2, help="Field to extract and its unit.")
parser.add_argument("--weight", type=str, required=True, nargs=2, help="Weight field and its unit.")
parser.add_argument("--output", type=str, required=True, help="Output file path.")
parser.add_argument("--scale", type=float, default=1.0, help="Scale factor applied to coordinates in unit space (ignored if --no-unit-space is set).")
parser.add_argument("--no-unit-space", action="store_true", help="Keep coordinates in their original units instead of converting to unit space.")

args = parser.parse_args()

## Load the dataset
ds = yt.load(args.path)
center = args.center
radius = args.radius
field, field_unit = args.field
weight, weight_unit = args.weight

field = tuple(field.split("."))
weight = tuple(weight.split("."))

output = args.output

sp = ds.sphere(center, radius)
sp.get_data([("index", k) for k in ("x", "y", "z", "dx")] + [field, weight])

# Write files
with open(args.output, "bw") as f:

    for i, k in enumerate("x y z dx".split()):
        if args.no_unit_space:
            v = sp[k].d
            if k != "dx":
                v = v - sp.center[i].d
        else:
            v = sp[k].to("unitary").d
            if k != "dx":
                v = v - sp.center[i].to("unitary").d
            v = v / sp.radius.to("unitary").d / 2
            v = v * args.scale

        print(f"key={k}: [{v.min()}, {v.max()}]")
        v.astype(np.float32).tofile(f)

    sp[field].to(field_unit).astype(np.float32).d.tofile(f)
    sp[weight].to(weight_unit).astype(np.float32).d.tofile(f)
