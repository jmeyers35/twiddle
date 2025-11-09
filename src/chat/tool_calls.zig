const std = @import("std");

const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const msgs = @import("messages.zig");

pub const ToolCallAccumulator = struct {
    const Partial = struct {
        id: []u8 = &.{},
        name: []u8 = &.{},
        arguments: std.ArrayListUnmanaged(u8) = .{},
    };

    calls: std.ArrayListUnmanaged(Partial) = .{},

    pub fn deinit(self: *ToolCallAccumulator, allocator: Allocator) void {
        if (self.calls.items.len == 0) return;
        for (self.calls.items[0..self.calls.items.len]) |*partial| {
            if (partial.id.len != 0) allocator.free(partial.id);
            if (partial.name.len != 0) allocator.free(partial.name);
            partial.arguments.deinit(allocator);
            partial.* = Partial{};
        }
        self.calls.deinit(allocator);
        self.* = ToolCallAccumulator{};
    }

    pub fn acquire(self: *ToolCallAccumulator, allocator: Allocator, index: usize) (Allocator.Error || error{StreamFormat})!*Partial {
        while (self.calls.items.len <= index) {
            try self.calls.append(allocator, Partial{});
        }
        return &self.calls.items[index];
    }

    pub fn setId(_: *ToolCallAccumulator, allocator: Allocator, partial: *Partial, id: []const u8) (Allocator.Error || error{StreamFormat})!void {
        if (id.len == 0) return error.StreamFormat;
        if (partial.id.len == 0) {
            partial.id = try util.dupSlice(allocator, id);
            return;
        }
        if (!std.mem.eql(u8, partial.id, id)) return error.StreamFormat;
    }

    pub fn setName(_: *ToolCallAccumulator, allocator: Allocator, partial: *Partial, name: []const u8) (Allocator.Error || error{StreamFormat})!void {
        if (name.len == 0) return error.StreamFormat;
        if (partial.name.len == 0) {
            partial.name = try util.dupSlice(allocator, name);
            return;
        }
        if (!std.mem.eql(u8, partial.name, name)) return error.StreamFormat;
    }

    pub fn appendArguments(_: *ToolCallAccumulator, allocator: Allocator, partial: *Partial, chunk: []const u8) Allocator.Error!void {
        if (chunk.len == 0) return;
        try partial.arguments.appendSlice(allocator, chunk);
    }

    pub fn pendingToolCount(self: *const ToolCallAccumulator) usize {
        var count: usize = 0;
        for (self.calls.items) |partial| {
            if (partial.name.len == 0) continue;
            count += 1;
        }
        return count;
    }

    pub fn writePendingToolNames(self: *const ToolCallAccumulator, writer: anytype) !usize {
        var emitted: usize = 0;
        for (self.calls.items) |partial| {
            if (partial.name.len == 0) continue;
            if (emitted != 0) try writer.writeAll(", ");
            try writer.writeAll(partial.name);
            emitted += 1;
        }
        return emitted;
    }

    pub fn take(self: *ToolCallAccumulator, allocator: Allocator) (Allocator.Error || error{StreamFormat})![]msgs.ToolCall {
        const count = self.calls.items.len;
        if (count == 0) {
            self.calls.deinit(allocator);
            self.* = ToolCallAccumulator{};
            return &.{};
        }

        var idx: usize = 0;
        const out = try allocator.alloc(msgs.ToolCall, count);
        errdefer {
            msgs.freeToolCalls(allocator, out[0..idx]);
            allocator.free(out);
        }

        while (idx < count) : (idx += 1) {
            var partial = &self.calls.items[idx];
            if (partial.id.len == 0 or partial.name.len == 0) return error.StreamFormat;

            const args_len = partial.arguments.items.len;
            const args_slice = if (args_len == 0) blk: {
                partial.arguments.deinit(allocator);
                break :blk try allocator.alloc(u8, 0);
            } else try partial.arguments.toOwnedSlice(allocator);

            out[idx] = msgs.ToolCall{
                .id = partial.id,
                .name = partial.name,
                .arguments_json = args_slice,
            };

            partial.id = &.{};
            partial.name = &.{};
            partial.arguments = .{};
        }

        self.calls.deinit(allocator);
        self.* = ToolCallAccumulator{};
        return out;
    }
};
