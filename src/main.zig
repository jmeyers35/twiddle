const std = @import("std");
const ChatClient = @import("chat_client.zig").ChatClient;
const Config = @import("config.zig");
const spinner_mod = @import("spinner.zig");
const Spinner = spinner_mod.Spinner;
const SpinnerWriter = spinner_mod.SpinnerWriter;
const Tools = @import("tools.zig");
const ToolExecutor = @import("tool_executor.zig").ToolExecutor;

comptime {
    std.debug.assert(Tools.registry.len != 0);
}

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();
    const stdout_is_tty = stdout.isTty();

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdout_buffer: [4 * 1024]u8 = undefined;

    var stdin_reader = std.fs.File.reader(stdin, stdin_buffer[0..]);
    var stdout_writer = std.fs.File.writer(stdout, stdout_buffer[0..]);

    const input_stream = &stdin_reader.interface;
    const output_stream = &stdout_writer.interface;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const config_path = try Config.defaultConfigPath(gpa.allocator());
    defer if (config_path) |p| gpa.allocator().free(p);

    var runtime_config = Config.load(gpa.allocator(), config_path) catch |err| switch (err) {
        error.ConfigParseFailed => {
            try emitConfigError(output_stream, "Failed to parse twiddle config", config_path);
            try output_stream.flush();
            return err;
        },
        error.ConfigTooLarge => {
            try emitConfigError(output_stream, "Config file exceeds 64KiB limit", config_path);
            try output_stream.flush();
            return err;
        },
        else => return err,
    };
    defer runtime_config.deinit(gpa.allocator());

    var chat_client = ChatClient.init(gpa.allocator(), .{
        .base_url = runtime_config.base_url,
        .model = runtime_config.model,
        .api_key = runtime_config.api_key,
    }) catch |err| switch (err) {
        error.ApiKeyMissing => {
            try output_stream.writeAll("\nMissing API key. Set OPENAI_API_KEY or add api_key to ");
            if (config_path) |p| {
                try output_stream.writeAll(p);
            } else {
                try output_stream.writeAll("~/.twiddle/twiddle.toml");
            }
            try output_stream.writeAll(".\n");
            try output_stream.flush();
            return err;
        },
        else => return err,
    };
    defer chat_client.deinit();

    var tool_executor = ToolExecutor.init(gpa.allocator(), ".") catch |err| {
        try output_stream.writeAll("failed to initialize tool executor: ");
        try output_stream.writeAll(@errorName(err));
        try output_stream.writeAll("\n");
        return err;
    };
    defer tool_executor.deinit();

    const tool_context_message = try std.fmt.allocPrint(
        gpa.allocator(),
        "Workspace root: {s}. Provide absolute paths within this root when using tools.",
        .{tool_executor.sandbox_root},
    );
    defer gpa.allocator().free(tool_context_message);
    try chat_client.setToolContext(tool_context_message);

    const prompt = "twiddle> ";
    const wait_message = "twiddling...";

    while (true) {
        try output_stream.writeAll(prompt);
        try output_stream.flush();

        const maybe_line = input_stream.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                try output_stream.writeAll(
                    "\nInput line exceeded internal buffer capacity (64KiB). Please shorten the request.\n",
                );
                try output_stream.flush();
                return err;
            },
            else => return err,
        };
        const raw_line = maybe_line orelse break;

        const without_cr = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, without_cr, " \t");

        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, "exit")) break;

        processUserRequest(
            gpa.allocator(),
            &chat_client,
            &tool_executor,
            stdout_is_tty,
            wait_message,
            output_stream,
            trimmed,
        ) catch |err| switch (err) {
            error.ToolEnvelopeInvalid => {},
            else => return err,
        };
    }
}

fn emitConfigError(writer: anytype, message: []const u8, config_path: ?[]const u8) !void {
    try writer.writeAll("\n");
    try writer.writeAll(message);
    try writer.writeAll(" (");
    if (config_path) |p| {
        try writer.writeAll(p);
    } else {
        try writer.writeAll("~/.twiddle/twiddle.toml");
    }
    try writer.writeAll(").\n");
}

fn processUserRequest(
    allocator: std.mem.Allocator,
    chat_client: *ChatClient,
    tool_executor: *ToolExecutor,
    stdout_is_tty: bool,
    wait_message: []const u8,
    output_stream: *std.Io.Writer,
    initial_input: []const u8,
) !void {
    var need_user_prompt = true;
    var pending_follow_up = false;

    while (true) {
        try output_stream.writeAll("\n");

        var spinner = Spinner.init(allocator, output_stream, wait_message);
        if (stdout_is_tty) {
            spinner.start() catch |err| {
                std.log.warn("spinner start failed: {s}", .{@errorName(err)});
            };
        }

        var response_writer: *std.Io.Writer = output_stream;
        // SAFETY: spinner_writer is conditionally initialized before any use.
        var spinner_writer: SpinnerWriter = undefined;
        if (spinner.isActive()) {
            spinner_writer.init(output_stream, &spinner);
            response_writer = spinner_writer.writer();
        }

        if (pending_follow_up) {
            chat_client.continueConversation(response_writer) catch |err| {
                spinner.stop();
                try output_stream.writeAll("chat error: ");
                try output_stream.writeAll(@errorName(err));
                try output_stream.writeAll("\n\n");
                try output_stream.flush();
                return;
            };
        } else {
            if (!need_user_prompt) {
                spinner.stop();
                break;
            }
            chat_client.respond(initial_input, response_writer) catch |err| {
                spinner.stop();
                try output_stream.writeAll("chat error: ");
                try output_stream.writeAll(@errorName(err));
                try output_stream.writeAll("\n\n");
                try output_stream.flush();
                return;
            };
            need_user_prompt = false;
        }
        spinner.stop();

        try output_stream.writeAll("\n");
        try output_stream.flush();

        pending_follow_up = false;

        var executed_tool_call = false;
        while (true) {
            const maybe_request = detectToolRequest(chat_client) catch |err| switch (err) {
                error.InvalidToolEnvelope => {
                    try output_stream.writeAll("tool request rejected: invalid envelope\n");
                    try output_stream.flush();
                    return error.ToolEnvelopeInvalid;
                },
                else => return err,
            };

            if (maybe_request) |request| {
                const tool_payload = handleToolRequest(allocator, tool_executor, request, output_stream) catch |err| {
                    try output_stream.writeAll("tool execution failed: ");
                    try output_stream.writeAll(@errorName(err));
                    try output_stream.writeAll("\n");
                    try output_stream.flush();
                    return err;
                };

                chat_client.appendToolMessage(request.call_id, request.tool_id, tool_payload) catch |err| {
                    if (tool_payload.len != 0) allocator.free(tool_payload);
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

const ToolRequest = struct {
    call_id: []const u8,
    tool_id: []const u8,
    arguments_json: []const u8,
};

fn detectToolRequest(
    chat_client: *ChatClient,
) error{InvalidToolEnvelope}!?ToolRequest {
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

fn handleToolRequest(
    allocator: std.mem.Allocator,
    tool_executor: *ToolExecutor,
    request: ToolRequest,
    output_stream: *std.Io.Writer,
) (std.mem.Allocator.Error || ToolExecutor.Error)![]u8 {
    const invocation = Tools.ToolInvocation{
        .tool_id = request.tool_id,
        .input_payload = request.arguments_json,
    };

    var result = tool_executor.execute(invocation) catch |err| {
        const message = toolErrorMessage(err);
        emitToolFailureSummary(output_stream, request.tool_id, message);
        return try formatToolFailureContent(allocator, request.tool_id, message);
    };
    defer tool_executor.deinitResult(&result);

    return switch (result) {
        .success => |payload| blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), payload, .{}) catch {
                const message = "tool returned malformed JSON";
                emitToolFailureSummary(output_stream, request.tool_id, message);
                break :blk try formatToolFailureContent(allocator, request.tool_id, message);
            };
            defer parsed.deinit();
            emitToolSuccessSummary(output_stream, request.tool_id, payload, parsed.value);
            const copy = try allocator.alloc(u8, payload.len);
            if (payload.len != 0) @memcpy(copy, payload);
            break :blk copy;
        },
        .failure => |message| blk: {
            emitToolFailureSummary(output_stream, request.tool_id, message);
            break :blk try formatToolFailureContent(allocator, request.tool_id, message);
        },
    };
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
