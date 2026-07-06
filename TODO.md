# TODO list

## BUGS

- Cannot upload a dataset >4GiB -> use BDA -> remove buffer from descriptors
- Actually handle errors ? Maybe ? You know...
- colormaps cannot be more than 256. Need to update cmap size according to file size

## IMPROVEMENTS

- Say what the renderer is taking in as input, writing as output, etc.
- Write the README.md
- double buffering: rendering pipeline is being stalled by encoding.
- video codec selection
- root center / size configuration
- .armv file improvement (simulation name, etc.)
- check if data file is corrupted based on header/metadata
- RGBA -> RGB to save bandwidth
- make shader bulletproof: guard against a malformed data file, limit max loops

## LATER

- switch from restart SVO traversal to stack-based approach
- multi-GPU support ?
- make a fork that uses libavcodec to zero-copy encode on the GPU
