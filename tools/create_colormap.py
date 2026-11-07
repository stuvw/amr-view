import numpy as np
import matplotlib.pyplot as plt
import argparse

def main():
    parser = argparse.ArgumentParser("Colormap generator")

    parser.add_argument("--colormap", type=str, required=True, help="Matplotlib colormap to generate")
    parser.add_argument("--output", type=str, required=True, help="Output colormap file")
    parser.add_argument("--size", type=int, default=256, help="Output colormap file")

    args = parser.parse_args()

    size = args.size

    # cmap = plt.get_cmap(args.colormap, size)
    # data = (cmap(np.linspace(0, 1, size)) * 255).astype(np.uint8)
    # data.reshape(-1).tofile(args.output)

    # I hope you like one-liners
    ((plt.get_cmap(args.colormap, size)(np.linspace(0, 1, size)) * 255).astype(np.uint8)).reshape(-1).tofile(args.output)

if __name__ == "__main__":
    main()
