const std = @import("std");

const ChatClient = @import("../chat_client.zig").ChatClient;
const Spinner = @import("../spinner.zig").Spinner;
const SpinnerWriter = @import("../spinner.zig").SpinnerWriter;
const Tools = @import("../tools.zig");
const ToolExecutor = @import("../tool_executor.zig").ToolExecutor;

pub const Session = struct {
    allocator: std.mem.Allocator,
    chat_client: *ChatClient,
    tool_executor: *ToolExecutor,
    stdout_is_tty: bool,
    wait_message: []const u8,
    output_stream: *std.io.Writer,

    pub fn init(
        allocator: std.mem.Allocator,
        chat_client: *ChatClient,
        tool_executor: *ToolExecutor,
        stdout_is_tty: bool,
        wait_message: []const u8,
        output_stream: *std.io.Writer,
    ) Session {
        return .{
            .allocator = allocator,
            .chat_client = chat_client,
            .tool_executor = tool_executor,
            .stdout_is_tty = stdout_is_tty,
            .wait_message = wait_message,
            .output_stream = output_stream,
        };
    }

    pub fn run(self: *Session, initial_input: []const u8) !void {
        var need_user_prompt = true;
        var pending_follow_up = false;

        while (true) {
            try self.output_stream.writeAll("\n");

            var spinner = Spinner.init(self.allocator, self.output_stream, self.wait_message);
            if (self.stdout_is_tty) {
                spinner.start() catch |err| {
                    std.log.warn("spinner start failed: {s}", .{@errorName(err)});
                };
            }

            var response_writer: *std.io.Writer = self.output_stream;
            // SAFETY: spinner_writer is initialized before use when the spinner is active.
            var spinner_writer: SpinnerWriter = undefined;
            if (spinner.isActive()) {
                spinner_writer.init(self.output_stream, &spinner);
                response_writer = spinner_writer.writer();
            }

            if (pending_follow_up) {
                self.chat_client.continueConversation(response_writer) catch |err| {
                    spinner.stop();
                    try self.output_stream.writeAll("chat error: ");
                    try self.output_stream.writeAll(@errorName(err));
                    try self.output_stream.writeAll("\n\n");
                    try self.output_stream.flush();
                    return;
                };
            } else {
                if (!need_user_prompt) {
                    spinner.stop();
                    break;
                }
                self.chat_client.respond(initial_input, response_writer) catch |err| {
                    spinner.stop();
                    try self.output_stream.writeAll("chat error: ");
                    try self.output_stream.writeAll(@errorName(err));
                    try self.output_stream.writeAll("\n\n");
                    try self.output_stream.flush();
                    return;
                };
                need_user_prompt = false;
            }
            spinner.stop();

            try self.output_stream.writeAll("\n");
            try self.output_stream.flush();

            pending_follow_up = false;

            var executed_tool_call = false;
            while (true) {
                const maybe_request = detectToolRequest(self.chat_client) catch |err| switch (err) {
                    error.InvalidToolEnvelope => {
                        try self.output_stream.writeAll("tool request rejected: invalid envelope\n");
                        try self.output_stream.flush();
                        return error.ToolEnvelopeInvalid;
                    },
                    else => return err,
                };

                if (maybe_request) |request| {
                    const tool_payload = self.handleToolRequest(request) catch |err| {
                        try self.output_stream.writeAll("tool execution failed: ");
                        try self.output_stream.writeAll(@errorName(err));
                        try self.output_stream.writeAll("\n");
                        try self.output_stream.flush();
                        return err;
                    };

                    self.chat_client.appendToolMessage(request.call_id, request.tool_id, tool_payload) catch |err| {
                        if (tool_payload.len != 0) self.allocator.free(tool_payload);
                        return err;
                    };

                    pending_follow_up = true;
                    executed_tool_call = true;
                    continue;
                }

                break;
            }

            if (executed_tool_call) {
                continue;
            }

            break;
        }
    }

    fn handleToolRequest(self: *Session, request: ToolRequest) (std.mem.Allocator.Error || ToolExecutor.Error)![]u8 {
        const invocation = Tools.ToolInvocation{
            .tool_id = request.tool_id,
            .input_payload = request.arguments_json,
        };

        var result = self.tool_executor.execute(invocation) catch |err| {
            const message = toolErrorMessage(err);
            emitToolFailureSummary(self.output_stream, request.tool_id, message);
            return formatToolFailureContent(self.allocator, request.tool_id, message);
        };
        defer self.tool_executor.deinitResult(&result);

        return switch (result) {
            .success => |payload| blk: {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch {
                    const message = "tool returned malformed JSON";
                    emitToolFailureSummary(self.output_stream, request.tool_id, message);
                    break :blk try formatToolFailureContent(self.allocator, request.tool_id, message);
                };
                defer parsed.deinit();
                emitToolSuccessSummary(self.output_stream, request.tool_id, payload, parsed.value);
                const copy = try self.allocator.alloc(u8, payload.len);
                if (payload.len != 0) @memcpy(copy, payload);
                break :blk copy;
            },
            .failure => |message| blk: {
                emitToolFailureSummary(self.output_stream, request.tool_id, message);
                break :blk try formatToolFailureContent(self.allocator, request.tool_id, message);
            },
        };
    }
};

pub const ToolRequest = struct {
    call_id: []const u8,
    tool_id: []const u8,
    arguments_json: []const u8,
};

fn detectToolRequest(chat_client: *ChatClient) error{InvalidToolEnvelope}!?ToolRequest {
    var idx = chat_client.messages.items.len;
    while (idx != 0) {
        idx -= 1;
        var message = &chat_client.messages.items[idx];
        if (message.role != .assistant) continue;
        if (message.tool_calls.len == 0) continue;
        if (message.processed_tool_calls >= message.tool_calls.len) continue;
        const call = message.tool_calls[message.processed_tool_calls];
        message.processed_tool_calls += 1;
        if (call.id.len == 0 or call.name.len == 0) return error.InvalidToolEnvelope;
        if (call.arguments_json.len == 0) return error.InvalidToolEnvelope;
        return ToolRequest{
            .call_id = call.id,
            .tool_id = call.name,
            .arguments_json = call.arguments_json,
        };
    }
    return null;
}

fn formatToolFailureContent(
    allocator: std.mem.Allocator,
    tool_id: []const u8,
    message: []const u8,
) std.mem.Allocator.Error![]u8 {
    var sink = std.io.Writer.Allocating.init(allocator);
    errdefer sink.deinit();
    var jw = std.json.Stringify{
        .writer = &sink.writer,
        .options = .{ .whitespace = .minified },
    };

    try jsonStep(jw.beginObject());
    try jsonStep(jw.objectField("status"));
    try jsonStep(jw.write("failure"));
    try jsonStep(jw.objectField("tool_id"));
    try jsonStep(jw.write(tool_id));
    try jsonStep(jw.objectField("error"));
    try jsonStep(jw.write(message));
    try jsonStep(jw.endObject());
    return sink.toOwnedSlice();
}

fn emitToolSuccessSummary(
    writer: *std.Io.Writer,
    tool_id: []const u8,
    raw_payload: []const u8,
    value: ?std.json.Value,
) void {
    if (!safeWrite(writer, "tool:")) return;
    if (!safeWrite(writer, tool_id)) return;
    if (std.mem.eql(u8, tool_id, Tools.ListDirectory.id)) {
        if (value) |v| {
            if (listDirectoryStats(v)) |stats| {
                if (!safePrint(writer, " success ({d} entries, truncated={})\n", .{ stats.entry_count, stats.truncated })) return;
            } else {
                if (!safeWrite(writer, " success\n")) return;
            }
        } else {
            if (!safeWrite(writer, " success\n")) return;
        }
    } else {
        if (!safeWrite(writer, " success\n")) return;
    }
    if (!safeWrite(writer, raw_payload)) return;
    if (!safeWrite(writer, "\n")) return;
    safeFlush(writer);
}

fn emitToolFailureSummary(writer: *std.Io.Writer, tool_id: []const u8, message: []const u8) void {
    if (!safeWrite(writer, "tool:")) return;
    if (!safeWrite(writer, tool_id)) return;
    if (!safeWrite(writer, " failure: ")) return;
    if (!safeWrite(writer, message)) return;
    if (!safeWrite(writer, "\n")) return;
    safeFlush(writer);
}

const ListDirStats = struct {
    entry_count: usize,
    truncated: bool,
};

fn safeWrite(writer: *std.Io.Writer, data: []const u8) bool {
    writer.writeAll(data) catch return false;
    return true;
}

fn safePrint(writer: *std.Io.Writer, comptime fmt: []const u8, args: anytype) bool {
    writer.print(fmt, args) catch return false;
    return true;
}

fn safeFlush(writer: *std.Io.Writer) void {
    writer.flush() catch |err| {
        std.log.warn("flush failed: {s}", .{@errorName(err)});
    };
}

inline fn jsonStep(res: std.json.Stringify.Error!void) std.mem.Allocator.Error!void {
    return res catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
    };
}

fn listDirectoryStats(value: std.json.Value) ?ListDirStats {
    if (value != .object) return null;
    const entries_val = value.object.get("entries") orelse return null;
    if (entries_val != .array) return null;
    const truncated_val = value.object.get("truncated") orelse return null;
    if (truncated_val != .bool) return null;
    return ListDirStats{
        .entry_count = entries_val.array.items.len,
        .truncated = truncated_val.bool,
    };
}

fn toolErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ToolNotFound => "tool not registered",
        error.PermissionDenied => "tool permission denied",
        error.ToolUnavailable => "tool unavailable",
        else => "tool executor error",
    };
}
