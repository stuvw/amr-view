const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const DynLib = @import("./dyn_lib.zig").DynLib;
const Allocator = std.mem.Allocator;

const enable_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

const required_layer_names = if (enable_debug) [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"} else [_][*:0]const u8{};

const required_device_extensions = [_][*:0]const u8{};

const BaseWrapper = vk.BaseWrapper;
const InstanceWrapper = vk.InstanceWrapper;
const DeviceWrapper = vk.DeviceWrapper;

const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

var global_vkGetInstanceProcAddr: vk.PfnGetInstanceProcAddr = undefined;

fn vulkan_loader(instance: ?vk.Instance, proc_name: [*:0]const u8) callconv(.c) vk.PfnVoidFunction {
    return global_vkGetInstanceProcAddr(instance, proc_name);
}

pub const Context = struct {
    allocator: Allocator,

    vkb: BaseWrapper,
    vkl: DynLib,

    instance: Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,

    /// In the far, far future, it would be awesome to be able to use multiple GPUs.
    dev: Device,

    compute_queue: Queue,

    total_vram: u64,
    max_alloc_size: u64,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8) !Context {
        var self: Context = undefined;
        self.allocator = allocator;

        const lib_name = switch (builtin.os.tag) {
            .windows => "vulkan-1.dll",
            .macos => "/usr/local/lib/libMoltenVK.dylib", // Should work for now...
            else => "libvulkan.so.1", // Linux/BSD
        };

        var vk_lib = DynLib.open(lib_name) catch |err| {
            std.log.err("Failed to load Vulkan library '{s}': {}", .{ lib_name, err });
            return err;
        };
        errdefer vk_lib.close();

        global_vkGetInstanceProcAddr = vk_lib.lookup(
            vk.PfnGetInstanceProcAddr,
            "vkGetInstanceProcAddr",
        ) orelse return error.SymbolNotFound;

        self.vkb = BaseWrapper.load(vulkan_loader);
        self.vkl = vk_lib;

        if (try checkLayerSupport(&self.vkb, self.allocator) == false) {
            return error.MissingLayer;
        }

        var extension_names: std.ArrayList([*:0]const u8) = .empty;
        defer extension_names.deinit(allocator);
        if (enable_debug) try extension_names.append(allocator, vk.instance_extensions.ext_debug_utils.name);

        const instance = try self.vkb.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = app_name,
                .application_version = vk.makeApiVersion(0, 0, 5, 1).toU32(),
                .p_engine_name = app_name,
                .engine_version = vk.makeApiVersion(0, 0, 5, 1).toU32(),
                .api_version = vk.API_VERSION_1_2.toU32(),
            },
            .enabled_layer_count = required_layer_names.len,
            .pp_enabled_layer_names = (&required_layer_names),
            .enabled_extension_count = @intCast(extension_names.items.len),
            .pp_enabled_extension_names = extension_names.items.ptr,
            .flags = .{},
        }, null);

        const vki = try allocator.create(InstanceWrapper);
        errdefer allocator.destroy(vki);
        vki.* = InstanceWrapper.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
        self.instance = Instance.init(instance, vki);
        errdefer self.instance.destroyInstance(null);

        if (enable_debug) {
            self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{
                    .verbose_ext = true,
                    .info_ext = true,
                    .warning_ext = true,
                    .error_ext = true,
                },
                .message_type = .{
                    .general_ext = true,
                    .validation_ext = true,
                    .performance_ext = true,
                },
                .pfn_user_callback = &debugUtilsMessengerCallback,
                .p_user_data = null,
            }, null);
        }

        const candidate = try pickPhysicalDevice(self.instance, allocator);
        self.pdev = candidate.pdev;
        self.props = candidate.props;

        const dev = try initializeCandidate(self.instance, candidate);

        const vkd = try allocator.create(DeviceWrapper);
        errdefer allocator.destroy(vkd);
        vkd.* = DeviceWrapper.load(dev, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
        self.dev = Device.init(dev, vkd);
        errdefer self.dev.destroyDevice(null);

        self.compute_queue = Queue.init(self.dev, candidate.queues.compute_family);

        self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

        self.queryDeviceLimits();

        std.log.info("Using device: {s}", .{deviceName(&self)});
        std.log.info("Max Alloc Size: {Bi:.2}", .{self.max_alloc_size});
        std.log.info("VRAM size: {Bi:.2}", .{self.total_vram});

        return self;
    }

    pub fn deinit(self: Context) void {
        self.dev.destroyDevice(null);
        if (enable_debug) self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
        self.instance.destroyInstance(null);

        // Don't forget to free the tables to prevent a memory leak.
        self.allocator.destroy(self.dev.wrapper);
        self.allocator.destroy(self.instance.wrapper);

        var mut_vk_lib = self.vkl;
        mut_vk_lib.close();
    }

    pub fn deviceName(self: *const Context) []const u8 {
        return std.mem.sliceTo(&self.props.device_name, 0);
    }

    pub fn findMemoryTypeIndex(self: Context, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        var best_idx: ?u32 = null;
        var max_heap_size: vk.DeviceSize = 0;

        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
            const bit = @as(u32, 1) << @truncate(i);
            if (memory_type_bits & bit != 0 and mem_type.property_flags.contains(flags)) {
                const heap_idx = mem_type.heap_index;
                const heap_size = self.mem_props.memory_heaps[heap_idx].size;

                // Track the memory type that belongs to the largest valid heap
                if (heap_size > max_heap_size) {
                    max_heap_size = heap_size;
                    best_idx = @truncate(i);
                }
            }
        }

        return best_idx orelse error.NoSuitableMemoryType;
    }

    pub fn allocate(self: Context, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        return try self.dev.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }

    pub fn allocate_bda(self: Context, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        return try self.dev.allocateMemory(&.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
            .p_next = &vk.MemoryAllocateFlagsInfo{
                .device_mask = 0,
                .flags = .{
                    .device_address = true,
                },
            },
        }, null);
    }

    pub fn queryDeviceLimits(self: *Context) void {
        self.total_vram = 0;

        for (0..self.mem_props.memory_heap_count) |i| {
            const heap = self.mem_props.memory_heaps[i];
            const is_device_local = self.mem_props.memory_heaps[i].flags.device_local;

            if (is_device_local) {
                if (heap.size > self.total_vram) {
                    self.total_vram = heap.size;
                }
            }
        }

        var m3props = vk.PhysicalDeviceMaintenance3Properties{
            .max_memory_allocation_size = 0,
            .max_per_set_descriptors = 0,
        };

        var props2 = vk.PhysicalDeviceProperties2{
            .properties = undefined,
            .p_next = &m3props,
        };

        self.instance.getPhysicalDeviceProperties2(self.pdev, &props2);

        self.max_alloc_size = m3props.max_memory_allocation_size;
    }
};

fn checkLayerSupport(vkb: *const BaseWrapper, alloc: Allocator) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(alloc);
    defer alloc.free(available_layers);
    for (required_layer_names) |required_layer| {
        for (available_layers) |layer| {
            if (std.mem.eql(u8, std.mem.span(required_layer), std.mem.sliceTo(&layer.layer_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

fn initializeCandidate(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.compute_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = 1;

    var vk_12_features = vk.PhysicalDeviceVulkan12Features{
        .buffer_device_address = .true,
    };

    var dev_features = vk.PhysicalDeviceFeatures2{
        .features = .{
            .shader_int_64 = .true,
        },
        .p_next = &vk_12_features,
    };

    return try instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
        .p_next = &dev_features,
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    compute_family: u32,
};

fn debugUtilsMessengerCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_types;
    _ = p_user_data;

    const default: [*:0]const u8 = "Unrecognized validation layer message";
    const msg = (if (p_callback_data) |cb| cb.p_message else null) orelse default;
    const log = std.log.scoped(.vulkan);
    switch (message_severity) {
        .{ .error_ext = true } => log.err("{s}", .{msg}),
        .{ .warning_ext = true } => log.warn("{s}", .{msg}),
        .{ .info_ext = true } => log.info("{s}", .{msg}),
        .{ .verbose_ext = true } => log.debug("{s}", .{msg}), // reverse order so the worst is printed
        else => log.info("{s}", .{msg}),
    }

    const data = p_callback_data orelse return .false;
    if (data.object_count == 0 or data.p_objects == null) return .false;

    const objects = data.p_objects.?[0..data.object_count];
    for (objects) |obj| {
        const name = if (obj.p_object_name) |ptr| std.mem.span(ptr) else "Unnamed";
        std.debug.print("    | {s} 0x{x} {s}\n", .{ @tagName(obj.object_type), obj.object_handle, name });
    }
    if (message_severity.error_ext == true) @panic("vulkan error");
    // panic to have the stack trace of where the error happened
    // besides that sometimes the code crashes something and you have to manually force kill it with killall, panic prevents this

    return .false;
}

fn pickPhysicalDevice(
    instance: Instance,
    allocator: Allocator,
) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);

        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var compute_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (compute_family == null and properties.queue_flags.compute) {
            compute_family = family;
        }
    }

    if (compute_family != null) {
        return QueueAllocation{
            .compute_family = compute_family.?,
        };
    }

    return null;
}

fn checkExtensionSupport(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}
