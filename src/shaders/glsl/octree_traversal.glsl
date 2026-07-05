#version 460

// Define the execution workgroup size
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// --- Buffers and Images ---
layout(std430, set = 0, binding = 0) buffer Octree {
    uvec2 nodes[];
};

layout(rgba8, set = 0, binding = 1) writeonly uniform image2D out_image;
layout(set = 0, binding = 2) uniform sampler2D colormap_tex;

// --- Uniform Buffers ---
layout(set = 0, binding = 3) uniform ColorInfo {
    vec4 under_color;
    vec4 over_color;
    vec4 bad_color;
    float min_val;
    float max_val;
};

layout(set = 0, binding = 4) uniform CameraInfo {
    vec4 camera_pos;
    vec4 camera_dir;
    vec4 camera_right;
    vec4 camera_up;
    float camera_fov;
};

layout(set = 0, binding = 5) uniform OctreeInfo {
    vec4 root_pos; // pos + size
};

// --- Helper Functions ---
bool intersect_box(vec3 ray_origin, vec3 ray_inv_dir, vec3 box_min, vec3 box_max, out float t_near, out float t_far) {
    vec3 t0 = (box_min - ray_origin) * ray_inv_dir;
    vec3 t1 = (box_max - ray_origin) * ray_inv_dir;

    vec3 tmin = min(t0, t1);
    vec3 tmax = max(t0, t1);

    float t_enter = max(max(tmin.x, tmin.y), tmin.z);
    float t_exit  = min(min(tmax.x, tmax.y), tmax.z);

    t_near = t_enter;
    t_far  = t_exit;

    return t_enter <= t_exit && t_exit > 0.0;
}

float get_exit_t(vec3 ray_origin, vec3 ray_inv_dir, vec3 box_min, vec3 box_max) {
    vec3 t0 = (box_min - ray_origin) * ray_inv_dir;
    vec3 t1 = (box_max - ray_origin) * ray_inv_dir;
    vec3 tmax = max(t0, t1);
    return min(min(tmax.x, tmax.y), tmax.z);
}

uint find_octant_containing(vec3 ray_pos, vec3 node_pos) {	
    uvec3 b = uvec3(greaterThanEqual(ray_pos, node_pos));
    return b.x | (b.y << 1u) | (b.z << 2u);
}

void main() {
    // 1. Determine target pixel and guard against out-of-bounds invocations
    ivec2 pixel_coords = ivec2(gl_GlobalInvocationID.xy);
    ivec2 img_size = imageSize(out_image);
    if (pixel_coords.x >= img_size.x || pixel_coords.y >= img_size.y) {
        return;
    }

    vec2 uv = vec2(pixel_coords) / vec2(img_size);
    vec2 ndc = uv * 2.0 - 1.0;
    
    float aspect = float(img_size.x + 0.5) / float(img_size.y);
    
    ndc.x *= aspect * camera_fov;
    ndc.y *= camera_fov;
    
    vec3 ray_dir = normalize(camera_dir.xyz + (ndc.x * camera_right.xyz) + (ndc.y * camera_up.xyz));
    vec3 ray_inv_dir = vec3(1.0) /  mix(ray_dir, vec3(1e-6), vec3(equal(ray_dir, vec3(0.0))));
    vec3 ray_origin = camera_pos.xyz;

    // 2. Initialize SVO Ray Tracing
    vec3 root_min = root_pos.xyz - vec3(root_pos.w * 0.5);
    vec3 root_max = root_pos.xyz + vec3(root_pos.w * 0.5);

    float accum_qw = 0.0;
    float accum_w = 0.0;

    float t;
    float t_max;
    bool hit = intersect_box(ray_origin, ray_inv_dir, root_min, root_max, t, t_max);

    t = max(0.0, t);

    // 3. SVO Traversal Loop
    while (hit && t < t_max) {
        float old_t = t;
        
        vec3 ray_pos = ray_origin + (ray_dir * t);
        uint node_idx = 0; 
        vec3 node_pos = root_pos.xyz;
        float node_size = root_pos.w;

        while (true) {
            
            uint octant = find_octant_containing(ray_pos, node_pos);
            vec3 offset;
            offset.x = ((octant & 1u) != 0u) ? 0.5 : -0.5;
            offset.y = ((octant & 2u) != 0u) ? 0.5 : -0.5;
            offset.z = ((octant & 4u) != 0u) ? 0.5 : -0.5;

            node_size /= 2.0;
            node_pos += offset * node_size;

            vec3 sub_min = node_pos - vec3(node_size * 0.5);
            vec3 sub_max = node_pos + vec3(node_size * 0.5);

            uvec2 raw = nodes[node_idx];
            uint child_idx = raw.x;
            uint child_mask = raw.y;

            uint mask_before = child_mask & ((1u << octant) - 1u);
            uint target_idx = child_idx + uint(bitCount(mask_before));

            uint presence_bit = (child_mask >> octant) & 1u;

            if (presence_bit == 0u) {
                float t_exit = get_exit_t(ray_origin, ray_inv_dir, sub_min, sub_max);
                t = max(t_exit + (node_size * 0.01), old_t + 1e-5);
                break;
            }

            uint type_bit = (child_mask >> (octant + 8u)) & 1u;

            if (type_bit == 1u) {
                uvec2 leaf_raw = nodes[target_idx];

                float t_exit = get_exit_t(ray_origin, ray_inv_dir, sub_min, sub_max);
                float dt = t_exit - t;

                // INFO: as dx^2 goes to 0, w/qty go to +inf.
                // While this makes sense from a physical standpoint,
                // it might introduce visual artifacts, so we must be
                // wary of that.
                float dx = node_size * node_size;

                accum_qw += uintBitsToFloat(leaf_raw.x) * uintBitsToFloat(leaf_raw.y) / dx * dt ;
                accum_w += uintBitsToFloat(leaf_raw.y) / dx * dt ;

                t = max(t_exit + (node_size * 0.01), old_t + 1e-5);
                break;
            }

            node_idx = target_idx;
        }
    }

    // 4. Color Mapping & Image Writing
    vec4 final_color;

    if (accum_w == 0.0) {
        final_color = bad_color;
    } else {
        const float INV_LOG10 = 0.4342944819;
        float depth = log(accum_qw / accum_w) * INV_LOG10;

        float color_t = (depth - min_val) / (max_val - min_val);

        // Sample colormap texture
        vec4 color = texture(colormap_tex, vec2(clamp(color_t, 0.0, 1.0), 0.5));

        // Apply underflow and overflow colors
        color = mix(under_color, color, step(0.0, color_t));
        final_color = mix(color, over_color, step(1.0, color_t));
    }

    // Write the calculated color directly to the output storage image
    imageStore(out_image, pixel_coords, final_color);
}
