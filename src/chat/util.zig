const std = @import("std");

pub fn dupSlice(allocator: std.mem.Allocator, src: []const u8) std.mem.Allocator.Error![]u8 {
    const copy = try allocator.alloc(u8, src.len);
    if (src.len != 0) @memcpy(copy, src);
    return copy;
}

pub fn freeSlice(allocator: std.mem.Allocator, buffer: []u8) void {
    if (buffer.len == 0) return;
    allocator.free(buffer);
}
