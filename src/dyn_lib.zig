//! For some reason, std.DynLib does not include Windows library loading.
//!
//! Taken from zig stdlib at https://codeberg.org/ziglang/zig/src/commit/4d6d2922b814d9f6885cfeec7603e73e9a852417/lib/std/dynamic_library.zig

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

/// An extension to `std.DynLib` with windows support
pub const DynLib = struct {
    const InnerType = switch (builtin.os.tag) {
        .windows => WindowsDynLib,
        else => std.DynLib,
    };

    inner: InnerType,

    pub const Error = InnerType.Error;

    /// Trusts the file. Malicious file will be able to execute arbitrary code.
    pub fn open(path: []const u8) Error!DynLib {
        return .{ .inner = try InnerType.open(path) };
    }

    /// Trusts the file. Malicious file will be able to execute arbitrary code.
    ///
    /// Z means it supports a C-style null terminated string.
    pub fn openZ(path_c: [*:0]const u8) Error!DynLib {
        return .{ .inner = try InnerType.openZ(path_c) };
    }

    /// Trusts the file.
    pub fn close(self: *DynLib) void {
        return self.inner.close();
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
};

/// Separated to avoid referencing `WindowsDynLib`, because its field types may not
/// be valid on other targets.
const WindowsDynLibError = error{
    FileNotFound,
    InvalidPath,
    NameTooLong,
    Unexpected,
};

const LoadLibraryFlags = packed struct(windows.DWORD) {
    DONT_RESOLVE_DLL_REFERENCES: bool = false,
    LOAD_LIBRARY_AS_DATAFILE: bool = false,
    _2: u1 = 0,
    LOAD_WITH_ALTERED_SEARCH_PATH: bool = false,
    _4: u1 = 0,
    LOAD_IGNORE_CODE_AUTHZ_LEVEL: bool = false,
    LOAD_LIBRARY_AS_IMAGE_RESOURCE: bool = false,
    LOAD_LIBRARY_AS_DATAFILE_EXCLUSIVE: bool = false,
    _8: u3 = 0,
    LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR: bool = false,
    LOAD_LIBRARY_SEARCH_APPLICATION_DIR: bool = false,
    LOAD_LIBRARY_SEARCH_USER_DIRS: bool = false,
    LOAD_LIBRARY_SEARCH_SYSTEM32: bool = false,
    LOAD_LIBRARY_SEARCH_DEFAULT_DIRS: bool = false,
    _16: u16 = 0,
};

extern "kernel32" fn LoadLibraryExW(
    lpLibFileName: windows.LPCWSTR,
    hFile: ?windows.HANDLE,
    dwFlags: LoadLibraryFlags,
) callconv(.winapi) ?windows.HMODULE;

extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;

extern "kernel32" fn GetProcAddress(
    hModule: windows.HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?windows.FARPROC;

pub const WindowsDynLib = struct {
    pub const Error = WindowsDynLibError;

    dll: windows.HMODULE,

    pub fn open(path: []const u8) Error!WindowsDynLib {
        return openEx(path, .{});
    }

    /// WindowsDynLib specific
    /// Opens dynamic library with specified library loading flags.
    pub fn openEx(path: []const u8, flags: LoadLibraryFlags) Error!WindowsDynLib {
        var path_w: [windows.PATH_MAX_WIDE:0]u16 = undefined;
        const path_w_len = windows.wtf8ToWtf16Le(&path_w, path) catch |err| switch (err) {
            error.BadPathName => return error.InvalidPath,
            error.NameTooLong => return error.NameTooLong,
        };
        path_w[path_w_len] = 0;
        return openExW(path_w[0..path_w_len :0].ptr, flags);
    }

    pub fn openZ(path_c: [*:0]const u8) Error!WindowsDynLib {
        return openExZ(path_c, .{});
    }

    /// WindowsDynLib specific
    /// Opens dynamic library with specified library loading flags.
    pub fn openExZ(path_c: [*:0]const u8, flags: LoadLibraryFlags) Error!WindowsDynLib {
        return openEx(std.mem.span(path_c), flags);
    }

    /// WindowsDynLib specific
    pub fn openW(path_w: [*:0]const u16) Error!WindowsDynLib {
        return openExW(path_w, .{});
    }

    /// WindowsDynLib specific
    /// Opens dynamic library with specified library loading flags.
    pub fn openExW(path_w: [*:0]const u16, flags: LoadLibraryFlags) Error!WindowsDynLib {
        var offset: usize = 0;
        if (path_w[0] == '\\' and path_w[1] == '?' and path_w[2] == '?' and path_w[3] == '\\') {
            // + 4 to skip over the \??\
            offset = 4;
        }

        const dll = LoadLibraryExW(path_w + offset, null, flags) orelse {
            return switch (windows.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND, .MOD_NOT_FOUND => error.FileNotFound,
                .INVALID_NAME, .BAD_PATHNAME => error.InvalidPath,
                else => error.Unexpected,
            };
        };

        return .{
            .dll = dll,
        };
    }

    pub fn close(self: *WindowsDynLib) void {
        std.debug.assert(FreeLibrary(self.dll) != .FALSE);
        self.* = undefined;
    }

    pub fn lookup(self: *WindowsDynLib, comptime T: type, name: [:0]const u8) ?T {
        if (GetProcAddress(self.dll, name.ptr)) |addr| {
            return @as(T, @ptrCast(@alignCast(addr)));
        } else {
            return null;
        }
    }
};
