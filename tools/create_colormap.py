import numpy as np
import matplotlib.pyplot as plt
import argparse

def main():
    parser = argparse.ArgumentParser("Colormap generator")

    parser.add_argument("--colormap", type=str, required=True, help="Matplotlib colormap to generate")
    parser.add_argument("--output", type=str, required=True, help="Output colormap file")

    args = parser.parse_args()

    # cmap = plt.get_cmap(args.colormap, 256)
    # data = (cmap(np.linspace(0, 1, 256)) * 255).astype(np.uint8)
    # data.reshape(-1).tofile(args.output)

    # I hope you like one-liners
    ((plt.get_cmap(args.colormap, 256)(np.linspace(0, 1, 256)) * 255).astype(np.uint8)).reshape(-1).tofile(args.output)

if __name__ == "__main__":
    main()
