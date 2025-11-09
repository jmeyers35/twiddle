const std = @import("std");

const ChatClient = @import("../chat_client.zig").ChatClient;
const Config = @import("../config.zig");
const Spinner = @import("../spinner.zig").Spinner;
const SpinnerWriter = @import("../spinner.zig").SpinnerWriter;
const ToolExecutor = @import("../tool_executor.zig").ToolExecutor;
const Tools = @import("../tools.zig");
const ascii = std.ascii;
const testing = std.testing;

/// Represents a single CLI session lifetime (the period between launching and exiting twiddle).
/// Multiple prompt turns may be handled by the same Session, and approvals persist until the process exits.
pub const Session = struct {
    allocator: std.mem.Allocator,
    chat_client: *ChatClient,
    tool_executor: *ToolExecutor,
    input_stream: *std.io.Reader,
    stdout_is_tty: bool,
    wait_message: []const u8,
    approval_policy: Config.ApprovalPolicy,
    output_stream: *std.io.Writer,
    workspace_write_denied: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        chat_client: *ChatClient,
        tool_executor: *ToolExecutor,
        input_stream: *std.io.Reader,
        stdout_is_tty: bool,
        wait_message: []const u8,
        approval_policy: Config.ApprovalPolicy,
        output_stream: *std.io.Writer,
    ) Session {
        return .{
            .allocator = allocator,
            .chat_client = chat_client,
            .tool_executor = tool_executor,
            .input_stream = input_stream,
            .stdout_is_tty = stdout_is_tty,
            .wait_message = wait_message,
            .approval_policy = approval_policy,
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

        retry: while (true) {
            var result = self.tool_executor.execute(invocation) catch |err| {
                switch (err) {
                    error.WorkspaceWriteRequired => {
                        if (self.handleWorkspaceWriteEscalation(request.tool_id)) continue :retry;
                        const message = "workspace write access denied";
                        emitToolFailureSummary(self.output_stream, request.tool_id, message);
                        return try formatToolFailureContent(self.allocator, request.tool_id, message);
                    },
                    else => {
                        const message = toolErrorMessage(err);
                        emitToolFailureSummary(self.output_stream, request.tool_id, message);
                        return try formatToolFailureContent(self.allocator, request.tool_id, message);
                    },
                }
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
    }

    fn handleWorkspaceWriteEscalation(self: *Session, tool_id: []const u8) bool {
        if (self.tool_executor.hasWorkspaceWrite()) return true;
        if (self.workspace_write_denied) return false;

        return switch (self.approval_policy) {
            .never => blk: {
                _ = safeWrite(self.output_stream, "workspace write request denied (approval_policy=never)\n");
                safeFlush(self.output_stream);
                self.workspace_write_denied = true;
                break :blk false;
            },
            .on_request => self.promptWorkspaceWriteApproval(tool_id),
        };
    }

    fn promptWorkspaceWriteApproval(self: *Session, tool_id: []const u8) bool {
        _ = safeWrite(self.output_stream, "Tool \"");
        _ = safeWrite(self.output_stream, tool_id);
        _ = safeWrite(
            self.output_stream,
            "\" requests permission to write within the workspace.\nAllow write access for this twiddle session (until you exit)? [y/N]: ",
        );
        safeFlush(self.output_stream);

        const maybe_line = self.input_stream.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                std.log.warn("approval response exceeded buffer limit", .{});
                return false;
            },
            else => {
                std.log.warn("approval response read failed: {s}", .{@errorName(err)});
                return false;
            },
        };
        const raw_line = maybe_line orelse {
            self.workspace_write_denied = true;
            _ = safeWrite(self.output_stream, "\nworkspace write request skipped (no response)\n");
            safeFlush(self.output_stream);
            return false;
        };

        const without_cr = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, without_cr, " \t");
        const approved = isAffirmativeResponse(trimmed);
        _ = safeWrite(self.output_stream, "\n");

        if (approved) {
            self.tool_executor.enableWorkspaceWrite();
            self.workspace_write_denied = false;
            _ = safeWrite(self.output_stream, "workspace write access granted for this twiddle session\n");
            safeFlush(self.output_stream);
            return true;
        }

        self.workspace_write_denied = true;
        _ = safeWrite(self.output_stream, "workspace write access denied\n");
        safeFlush(self.output_stream);
        return false;
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

fn isAffirmativeResponse(response: []const u8) bool {
    if (response.len == 0) return false;
    if (response.len == 1) return ascii.toLower(response[0]) == 'y';
    return ascii.eqlIgnoreCase(response, "y") or ascii.eqlIgnoreCase(response, "yes");
}

test "isAffirmativeResponse handles variants" {
    try testing.expect(isAffirmativeResponse("y"));
    try testing.expect(isAffirmativeResponse("Y"));
    try testing.expect(isAffirmativeResponse("yes"));
    try testing.expect(isAffirmativeResponse("YES"));
    try testing.expect(!isAffirmativeResponse("n"));
    try testing.expect(!isAffirmativeResponse(""));
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
    const debug_enabled = debugOutputEnabled();
    if (!safeWrite(writer, "tool:")) return;
    if (!safeWrite(writer, tool_id)) return;
    if (!safeWrite(writer, " success")) return;
    if (value) |parsed| {
        _ = emitFriendlyToolSummary(writer, tool_id, parsed);
    }
    if (!safeWrite(writer, "\n")) return;

    if (debug_enabled) {
        if (!safeWrite(writer, raw_payload)) return;
        if (!safeWrite(writer, "\n")) return;
    }

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

fn emitFriendlyToolSummary(writer: *std.Io.Writer, tool_id: []const u8, value: std.json.Value) bool {
    if (std.mem.eql(u8, tool_id, Tools.ListDirectory.id)) {
        return Tools.ListDirectory.emitSummary(writer, value);
    }
    if (std.mem.eql(u8, tool_id, Tools.ReadFile.id)) {
        return Tools.ReadFile.emitSummary(writer, value);
    }
    if (std.mem.eql(u8, tool_id, Tools.Search.id)) {
        return Tools.Search.emitSummary(writer, value);
    }
    return false;
}

fn safeWrite(writer: *std.Io.Writer, data: []const u8) bool {
    writer.writeAll(data) catch return false;
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

fn debugOutputEnabled() bool {
    return std.process.hasEnvVarConstant("TWIDDLE_DEBUG");
}

fn toolErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.ToolNotFound => "tool not registered",
        error.PermissionDenied => "tool permission denied",
        error.ToolUnavailable => "tool unavailable",
        else => "tool executor error",
    };
}
