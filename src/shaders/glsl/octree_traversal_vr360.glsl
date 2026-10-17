#version 460
#include "./common.glsl"

void main() {
  // 1. Determine target pixel and guard against OOB invocations
  ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
  ivec2 img_size = imageSize(Y_plane);
  if (pixel_coords.x >= img_size.x || pixel_coords.y >= img_size.y) {
    return;
  }

  cache_chunk_ptrs();

  // 2. Calculate ray direction
  vec3 ray_dir = get_ray_dir_vr360(pixel_coords, img_size);

  // 3. Main step: traverse the SVO
  vec2 accum = traverse_SVO(ray_dir);

  // 4. Color Mapping & Image Writing
  write_pixel(pixel_coords, accum);
}
