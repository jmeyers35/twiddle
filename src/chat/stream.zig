const std = @import("std");

const ToolCallAccumulator = @import("tool_calls.zig").ToolCallAccumulator;

pub const Usage = struct {
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    total_tokens: i64 = 0,
    valid: bool = false,
};

pub const ContextUsage = struct {
    remaining_hundredths: u16,
    used_tokens: u64,
    limit_tokens: u32,
};

const LineBuffer = struct {
    stack: [512]u8,
    stack_len: usize = 0,
    heap: std.ArrayListUnmanaged(u8) = .{},
    using_heap: bool = false,

    fn init() LineBuffer {
        return LineBuffer{
            // SAFETY: stack contents are overwritten before being read.
            .stack = undefined,
        };
    }

    fn append(self: *LineBuffer, allocator: std.mem.Allocator, byte: u8) !void {
        if (!self.using_heap and self.stack_len < self.stack.len) {
            self.stack[self.stack_len] = byte;
            self.stack_len += 1;
            return;
        }
        if (!self.using_heap) {
            try self.heap.appendSlice(allocator, self.stack[0..self.stack_len]);
            self.using_heap = true;
        }
        try self.heap.append(allocator, byte);
    }

    fn items(self: *LineBuffer) []const u8 {
        return if (self.using_heap) self.heap.items else self.stack[0..self.stack_len];
    }

    fn clear(self: *LineBuffer) void {
        self.stack_len = 0;
        if (self.using_heap) {
            self.heap.clearRetainingCapacity();
            self.using_heap = false;
        }
    }

    fn deinit(self: *LineBuffer, allocator: std.mem.Allocator) void {
        self.heap.deinit(allocator);
    }
};

pub fn streamSse(
    client: anytype,
    response: *std.http.Client.Response,
    writer: *std.io.Writer,
    usage: *Usage,
    transcript: *std.ArrayListUnmanaged(u8),
    tool_accum: *ToolCallAccumulator,
) !void {
    var transfer_buf: [2048]u8 = undefined;
    var reader = response.reader(&transfer_buf);
    var chunk_buf: [2048]u8 = undefined;

    var line_buf = LineBuffer.init();
    defer line_buf.deinit(client.allocator);
    var event_buf: [16 * 1024]u8 = undefined;
    var event_len: usize = 0;
    var done = false;
    var chunk_arena = std.heap.ArenaAllocator.init(client.allocator);
    defer chunk_arena.deinit();

    while (!done) {
        var chunk_writer = std.io.Writer.fixed(chunk_buf[0..]);
        const limit = std.Io.Limit.limited(transfer_buf.len);
        var reached_eof = false;
        _ = reader.stream(&chunk_writer, limit) catch |err| switch (err) {
            error.EndOfStream => blk: {
                reached_eof = true;
                break :blk 0;
            },
            error.WriteFailed => 0,
            else => return err,
        };
        const n = chunk_writer.end;
        if (n == 0) {
            if (reached_eof) break else continue;
        }

        for (chunk_buf[0..n]) |byte| {
            if (byte == '\n') {
                const trimmed = trimLine(line_buf.items());
                line_buf.clear();
                if (trimmed.len == 0) {
                    if (event_len > 0) {
                        done = try handleEvent(client, event_buf[0..event_len], writer, usage, &chunk_arena, transcript, tool_accum);
                        event_len = 0;
                    }
                    continue;
                }
                if (std.mem.startsWith(u8, trimmed, "data:")) {
                    const payload = std.mem.trimLeft(u8, trimmed[5..], " ");
                    if (event_len != 0) {
                        if (event_len == event_buf.len) return error.StreamFormat;
                        event_buf[event_len] = '\n';
                        event_len += 1;
                    }
                    if (event_len + payload.len > event_buf.len) return error.StreamFormat;
                    @memcpy(event_buf[event_len..][0..payload.len], payload);
                    event_len += payload.len;
                }
                continue;
            }

            try line_buf.append(client.allocator, byte);
        }

        if (reached_eof) break;
    }

    if (!done and event_len > 0) {
        _ = try handleEvent(client, event_buf[0..event_len], writer, usage, &chunk_arena, transcript, tool_accum);
    }

    try writer.flush();
}

fn handleEvent(
    client: anytype,
    data: []const u8,
    writer: *std.io.Writer,
    usage: *Usage,
    chunk_arena: *std.heap.ArenaAllocator,
    transcript: *std.ArrayListUnmanaged(u8),
    tool_accum: *ToolCallAccumulator,
) !bool {
    if (data.len == 0) return false;
    if (std.mem.eql(u8, data, "[DONE]")) return true;

    _ = chunk_arena.reset(.retain_capacity);
    var parsed = try std.json.parseFromSlice(std.json.Value, chunk_arena.allocator(), data, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return false;
    try emitChoices(client, root.object, writer, transcript, tool_accum);
    try captureUsage(root.object, usage);

    try writer.flush();
    return false;
}

fn writeAndCapture(
    client: anytype,
    writer: *std.io.Writer,
    transcript: *std.ArrayListUnmanaged(u8),
    data: []const u8,
) !void {
    if (data.len == 0) return;
    try writer.writeAll(data);
    try client.captureTranscript(transcript, data);
    if (std.mem.indexOfScalar(u8, data, '\n')) |_| {
        try writer.flush();
    }
}

fn emitChoices(
    client: anytype,
    object: std.json.ObjectMap,
    writer: *std.io.Writer,
    transcript: *std.ArrayListUnmanaged(u8),
    tool_accum: *ToolCallAccumulator,
) !void {
    const choices_val = object.get("choices") orelse return;
    if (choices_val != .array) return;
    for (choices_val.array.items) |choice| {
        if (choice != .object) continue;
        const delta_val = choice.object.get("delta") orelse continue;
        if (delta_val == .string) {
            try writeAndCapture(client, writer, transcript, delta_val.string);
            continue;
        }
        if (delta_val != .object) continue;
        const delta_obj = delta_val.object;
        if (delta_obj.get("tool_calls")) |tool_calls_val| {
            try client.captureToolCalls(tool_calls_val, tool_accum);
        }
        if (delta_obj.get("content")) |content_val| {
            try emitContent(client, content_val, writer, transcript);
        } else if (delta_obj.get("output_text")) |text_val| {
            if (text_val == .string) {
                try writeAndCapture(client, writer, transcript, text_val.string);
            }
        }
    }
}

fn emitContent(
    client: anytype,
    value: std.json.Value,
    writer: *std.io.Writer,
    transcript: *std.ArrayListUnmanaged(u8),
) !void {
    switch (value) {
        .string => |str| {
            try writeAndCapture(client, writer, transcript, str);
        },
        .array => |arr| {
            for (arr.items) |item| {
                if (item == .string) {
                    try writeAndCapture(client, writer, transcript, item.string);
                } else if (item == .object) {
                    if (item.object.get("text")) |text_val| {
                        if (text_val == .string) {
                            try writeAndCapture(client, writer, transcript, text_val.string);
                        }
                    } else if (item.object.get("content")) |content| {
                        try emitContent(client, content, writer, transcript);
                    }
                }
            }
        },
        .object => |obj| {
            if (obj.get("text")) |text_val| {
                if (text_val == .string) {
                    try writeAndCapture(client, writer, transcript, text_val.string);
                }
            }
        },
        else => {},
    }
}

fn captureUsage(object: std.json.ObjectMap, usage: *Usage) !void {
    const usage_val = object.get("usage") orelse return;
    if (usage_val != .object) return;
    usage.prompt_tokens = getIntField(usage_val.object, "prompt_tokens") orelse usage.prompt_tokens;
    usage.completion_tokens = getIntField(usage_val.object, "completion_tokens") orelse usage.completion_tokens;
    usage.total_tokens = getIntField(usage_val.object, "total_tokens") orelse usage.total_tokens;
    usage.valid = true;
}

fn getIntField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |v| v,
        .float => |v| @intFromFloat(v),
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn contextUsage(limit: u32, total_tokens: i64) ?ContextUsage {
    if (limit == 0 or total_tokens < 0) return null;
    const limit_u64: u64 = limit;
    const used_u64: u64 = @intCast(total_tokens);
    if (used_u64 >= limit_u64) {
        return ContextUsage{
            .remaining_hundredths = 0,
            .used_tokens = used_u64,
            .limit_tokens = limit,
        };
    }

    const remaining = limit_u64 - used_u64;
    const scaled: u64 = (remaining * 10000) / limit_u64;
    const hundredths: u16 = @intCast(scaled);

    return ContextUsage{
        .remaining_hundredths = hundredths,
        .used_tokens = used_u64,
        .limit_tokens = limit,
    };
}

fn trimLine(line: []const u8) []const u8 {
    if (line.len == 0) return line;
    if (line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}
