# AMR-view

GPU-accelerated volume renderer for large particle/AMR (Adaptive Mesh Refinement) datasets. Renders fly-through videos along a camera path using Vulkan compute ray tracing through a Sparse Voxel Octree (SVO).

Since `amr-view` relies entirely on compute shaders rather than a traditional rasterization pipeline, it can run headlessly on server-grade hardware (e.g., NVIDIA H100) without a display attached.

## How It Works

The renderer processes datasets by representing each data point as a leaf node in a custom SVO. Frame generation happens in a two-stage pipeline:

### Stage 1: Depth Accumulation
For each pixel, a ray is cast from the camera origin. As the ray traverses the SVO, it accumulates column density and weight across every intersected leaf node using the following formulas:

$$ray\_{qty} += \frac{qty \cdot w}{dx^2} \cdot dt$$

$$ray\_w += \frac{w}{dx^2} \cdot dt$$

Where:
* $qty$: The cell's quantity field
* $w$: The cell's weight
* $dx$: The cell's edge length
* $dt$: The distance the ray travels through the voxel

### Stage 2: Tone Mapping
Once the ray exits the root node, the depth-weighted mean of the quantity field is calculated using a base-10 logarithm:

$$\log_{10}\left(\frac{ray\_{qty}}{ray\_w}\right)$$

This value is mapped through a user-specified 256-color RGBA colormap (supporting custom underflow, overflow, and error colors) and written to the final frame.

*Note: Frames are streamed directly to FFmpeg in real time. Double buffering is planned to decouple GPU rendering from video encoding.*

## Data format

### Dataset format (`.amrv`)

The renderer expects a binary file composed of a version-specific metadata header followed by a compact SVO ([Sparse Voxel Octree](https://eisenwave.github.io/voxel-compression-docs/svo/svo.html)). You can generate this using the [create_cutout_svo.py](./tools/create_cutout_svo.py) script.

Each SVO node is exactly **8 bytes** and can be one of two types:
* **Branch Node:** Two 32-bit integers. The first is the index of the first child node; the second is a bit-mask indicating child presence and whether they are leaves.
* **Leaf Node:** Two 32-bit single-precision floats. The first is the quantity field; the second is the weight.

### Camera path format

A plain text file where each line defines a camera state using 9 space-separated floats: `px py pz cx cy cz nx ny nz` (Position, Direction vector, and Up vector).

### Colormap format

A binary file containing 256 structural RGBA byte-quartets (1024 bytes total). You can generate compatible colormaps from matplotlib profiles using the following [python script](./tools/create_colormap.py). You can also make your own, whacky one, with rainbows and everything :) .

## Dependencies / Requirements

### Build dependencies

- [Zig Compiler](https://ziglang.org/) (v0.16.0 or compatible) 

### Runtime dependencies

- A working [Vulkan](https://www.vulkan.org/) driver (v1.2 or later)
- [FFmpeg](https://www.ffmpeg.org/) installed and on PATH.

## Installation

### Download binaries

Pre-compiled executables for major platforms are available on the [releases](https://github.com/stuvw/amr-view/releases) page.

### Build from source
```bash

git clone https://github.com/stuvw/amr-view.git
cd amr-view
zig build -Doptimize=ReleaseFast
```

The binary will be generated at `./zig-out/bin/amr-view` .

## Usage

### Command example

```bash
./amr-view --data-file simulation.amrv \
           --path-file path.txt \
           --colormap-file inferno.bin \
           --video-file export.mkv \
           --width 3840 \
           --height 2160 \
           --framerate 60 \
```


### Full argument reference

| Argument | Default | Description |
| -------- | ------- | ----------- |
| --data-file | *required* | Input SVO file |
| --path-file | *required* | Input camera path file |
| --colormap-file | *required* | Input colormap file |
| --video-file | video.mp4 | Output video file |
| --width | 1920 | Output video width |
| --height | 1080 | Ouput video height |
| --fov | 60 | Ouput video FOV |
| --framerate | 60 | Output video frame rate |
| --min-val | -3.0 | Underflow value |
| --max-val | 3.0 | Overflow value |
| --under-color | 0,0,0,1 | RGBA color used when the value underflows --min-val |
| --over-color | 1,1,1,1 | RGBA color used when the value overflows --max-val |
| --bad-color | 0,0,0,0 | RGBA color used when a rendering error occurs |
| --root-size | 1.0 | Edge size of the root node of the SVO |
| --root-pos | 0,0,0 | Center position of the root of the SVO |
| --encoder | x264 | Video codec used to encode the output video. Choices: x264, x265, av1 |
| --hwaccel | none | Use GPU hardware video acceleration. GPU must support requested encoder. Choices: none, nvenc, amf, qsv |

## Roadmap (Coming soon™)

 - [] Double-buffered frame streaming to eliminate FFmpeg encoding stalls
 - [] Support for arbitrary colormap sizes for increased visual depth
 - [] VR 180/360 rendering support

## Performance



## Credits / Thanks
