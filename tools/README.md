## Install dependencies

### Linux / MacOS

```bash
# Create Python virtual environment
python3 -m venv .venv
# Enter the virtual environment
source .venv/bin/activate
# Install dependencies using pip
pip install numpy matplotlib numba tqdm yt
# Exit virtual environment
deactivate
```

### Windows

```bash
# Create Python virtual environment
python3 -m venv .venv
# Enter the virtual environment
.venv\bin\activate.bat
# Install dependencies using pip
pip install numpy matplotlib numba tqdm yt
# Exit virtual environment
deactivate
```

**You must be inside the virtual environment to run both tools**


## `create_colormap.py`

### Command example

```bash
python3 create_colormap.py --colormap inferno --output inferno.cmap
```


### Full argument reference

| Argument | Default | Description |
| -------- | ------- | ----------- |
| --colormap | *required* | Matplotlib colormap that will be sampled |
| --output | *required* | Output colormap file |
| --size | 256 | Size of the output colormap |

## `create_cutout_svo.py`

### Usage

```bash
python3 create_cutout_svo.py my_simulation_dir --center 0.5 0.5 0.5 --size 0.0625 --field -field "gas.density" "mp/cm**3" --weight "gas.cell_mass" "Msun" --output my_simulation.amrv
```

### Full argument reference

| Argument | Default | Description |
| -------- | ------- | ----------- |
| positional argument: path | *required* | Input simulation path |
| --center | *required* | Center of the cutout |
| --size | *required* | Size (cube edge width) of the cutout |
| --field | *required* | Select field to be extracted (name + unit) |
| --weight | *required* | Select weight to be extracted (name + unit) |
| --output | *required* | Output SVO file |
| --max-depth | 21 | Octree depth limit |
