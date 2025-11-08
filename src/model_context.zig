const std = @import("std");

const table = @import("model_context_data.zig");

pub fn lookup(allocator: std.mem.Allocator, model: []const u8) ?u32 {
    _ = allocator;
    if (model.len == 0) return null;

    const trimmed = std.mem.trim(u8, model, " \t\r\n");
    if (trimmed.len == 0) return null;

    if (binarySearch(trimmed)) |value| return value;
    if (caseInsensitiveScan(trimmed)) |value| return value;
    return null;
}

fn binarySearch(target: []const u8) ?u32 {
    var lo: usize = 0;
    var hi: usize = table.entries.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const entry = table.entries[mid];
        switch (std.mem.order(u8, entry.key, target)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return entry.value,
        }
    }
    return null;
}

fn caseInsensitiveScan(target: []const u8) ?u32 {
    for (table.entries) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.key, target)) return entry.value;
    }
    return null;
}
