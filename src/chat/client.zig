const std = @import("std");
const model_context = @import("../model_context.zig");
const msg_mod = @import("messages.zig");
const tool_calls_mod = @import("tool_calls.zig");
const payload_mod = @import("payload.zig");
const stream_mod = @import("stream.zig");
const util = @import("util.zig");
const testing = std.testing;

pub const ChatClient = struct {
    const Allocator = std.mem.Allocator;
    const Writer = std.io.Writer;
    const crypto = std.crypto;
    const posix = std.posix;
    const Role = msg_mod.Role;
    const Message = msg_mod.Message;
    const ToolCall = msg_mod.ToolCall;
    const ToolCallAccumulator = tool_calls_mod.ToolCallAccumulator;
    const Usage = stream_mod.Usage;
    pub const ContextUsage = stream_mod.ContextUsage;

    pub const Config = struct {
        api_key_env: []const u8 = "OPENAI_API_KEY",
        api_key: ?[]const u8 = null,
        base_url: []const u8,
        path: []const u8 = "/v1/chat/completions",
        model: []const u8,
        temperature: f32 = 0.15,
        max_completion_tokens: ?u32 = null,
        unix_socket_path: []const u8 = "",
        system_prompt: []const u8 =
            "You are twiddle, an extremely efficient coding agent. " ++ "Answer with concise, accurate steps and code when needed.",
    };

    pub const Error = std.http.Client.RequestError || std.http.Client.Request.SendError || std.http.Client.Request.ReceiveHeadError || std.net.Stream.ReadError || std.mem.Allocator.Error || error{
        ApiKeyMissing,
        PayloadTooLarge,
        UpstreamRejected,
        UpstreamUnavailable,
        StreamFormat,
        UnixSocketsUnavailable,
    };

    allocator: Allocator,
    http: std.http.Client,
    uri: std.Uri,
    uri_storage: []u8,
    config: Config,
    auth_header: []u8,
    last_rtt_ns: u64 = 2 * std.time.ns_per_s,
    model_context_limit: ?u32 = null,
    messages: std.ArrayListUnmanaged(Message) = .empty,
    tool_context: []u8 = &.{},

    const min_timeout_ns: u64 = 750 * std.time.ns_per_ms;
    const max_timeout_ns: u64 = 20 * std.time.ns_per_s;

    pub fn init(allocator: Allocator, config: Config) !ChatClient {
        const uri_storage = try allocator.alloc(u8, config.base_url.len + config.path.len);
        errdefer allocator.free(uri_storage);
        @memcpy(uri_storage[0..config.base_url.len], config.base_url);
        @memcpy(uri_storage[config.base_url.len..], config.path);

        var client = ChatClient{
            .allocator = allocator,
            .http = .{ .allocator = allocator },
            // SAFETY: initialized immediately via std.Uri.parse before any use.
            .uri = undefined,
            .uri_storage = uri_storage,
            .config = config,
            .auth_header = &.{},
            .messages = .empty,
        };

        client.uri = try std.Uri.parse(client.uri_storage);

        errdefer client.http.deinit();

        client.auth_header = try buildAuthHeader(allocator, config);
        client.model_context_limit = model_context.lookup(allocator, config.model);
        return client;
    }

    pub fn deinit(self: *ChatClient) void {
        self.clearMessages();
        self.messages.deinit(self.allocator);
        self.http.deinit();
        if (self.uri_storage.len != 0) {
            self.allocator.free(self.uri_storage);
        }
        if (self.auth_header.len != 0) {
            crypto.secureZero(u8, self.auth_header);
            self.allocator.free(self.auth_header);
        }
        if (self.tool_context.len != 0) {
            self.allocator.free(self.tool_context);
        }
        self.* = undefined;
    }

    pub fn respond(self: *ChatClient, user_input: []const u8, writer: *Writer) !void {
        if (user_input.len == 0) return;

        var snapshot = MessageSnapshot.init(self);
        defer snapshot.cancel();

        try self.appendUserMessage(user_input);

        var attempts: u8 = 0;
        while (true) : (attempts += 1) {
            var assistant_buf = std.ArrayListUnmanaged(u8){};
            defer assistant_buf.deinit(self.allocator);

            var tool_accum = ToolCallAccumulator{};
            defer tool_accum.deinit(self.allocator);

            const result = self.tryRespond(writer, &assistant_buf, &tool_accum) catch |err| switch (err) {
                error.UpstreamRejected => |e| {
                    try emitErrorLine(writer, "upstream error", e);
                    return;
                },
                error.ReadFailed => RespondResult.retryable,
                else => return err,
            };

            switch (result) {
                .success => {
                    const tool_calls = try tool_accum.take(self.allocator);
                    const content_is_null = tool_calls.len != 0 and assistant_buf.items.len == 0;
                    try self.appendAssistantMessage(assistant_buf.items, tool_calls, content_is_null);
                    snapshot.commit();
                    return;
                },
                .retryable => {
                    if (attempts >= 1) {
                        try emitErrorLine(writer, "upstream temporarily unavailable, retry limit hit", null);
                        return;
                    }
                    try writer.writeAll("…retrying…\n");
                    try writer.flush();
                    continue;
                },
            }
        }
    }

    pub fn continueConversation(self: *ChatClient, writer: *Writer) !void {
        var snapshot = MessageSnapshot.init(self);
        defer snapshot.cancel();

        var attempts: u8 = 0;
        while (true) : (attempts += 1) {
            var assistant_buf = std.ArrayListUnmanaged(u8){};
            defer assistant_buf.deinit(self.allocator);

            var tool_accum = ToolCallAccumulator{};
            defer tool_accum.deinit(self.allocator);

            const result = self.tryRespond(writer, &assistant_buf, &tool_accum) catch |err| switch (err) {
                error.UpstreamRejected => |e| {
                    try emitErrorLine(writer, "upstream error", e);
                    return;
                },
                error.ReadFailed => RespondResult.retryable,
                else => return err,
            };

            switch (result) {
                .success => {
                    const tool_calls = try tool_accum.take(self.allocator);
                    const content_is_null = tool_calls.len != 0 and assistant_buf.items.len == 0;
                    try self.appendAssistantMessage(assistant_buf.items, tool_calls, content_is_null);
                    snapshot.commit();
                    return;
                },
                .retryable => {
                    if (attempts >= 1) {
                        try emitErrorLine(writer, "upstream temporarily unavailable, retry limit hit", null);
                        return;
                    }
                    try writer.writeAll("…retrying…\n");
                    try writer.flush();
                    continue;
                },
            }
        }
    }

    const RespondResult = union(enum) {
        success,
        retryable,
    };

    fn tryRespond(
        self: *ChatClient,
        writer: *Writer,
        transcript: *std.ArrayListUnmanaged(u8),
        tool_accum: *ToolCallAccumulator,
    ) !RespondResult {
        if (self.config.unix_socket_path.len != 0) {
            return error.UnixSocketsUnavailable;
        }

        var payload_buf = std.io.Writer.Allocating.init(self.allocator);
        defer payload_buf.deinit();
        const payload = try self.buildPayload(&payload_buf);

        var req = try self.http.request(.POST, self.uri, .{
            .extra_headers = &extraHeaders,
            .headers = .{
                .authorization = .{ .override = self.auth_header },
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = "twiddle/0.1" },
                .accept_encoding = .omit,
            },
        });
        defer req.deinit();

        if (req.connection) |conn| try self.configureTimeout(conn);

        const send_start = std.time.nanoTimestamp();

        try req.sendBodyComplete(@constCast(payload));

        var response = req.receiveHead(&.{}) catch |err| switch (err) {
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.TemporaryNameServerFailure,
            => return RespondResult.retryable,
            else => return err,
        };

        const now = std.time.nanoTimestamp();
        if (now > send_start) {
            const rtt: u64 = @intCast(now - send_start);
            self.last_rtt_ns = rtt;
        }

        if (response.head.status.class() != .success) {
            const should_retry = isRetryableStatus(response.head.status);
            try forwardErrorBody(&response, writer, response.head.status);
            if (should_retry) return RespondResult.retryable;
            return error.UpstreamRejected;
        }

        try writer.writeAll("assistant> ");
        try writer.flush();

        var stream_usage: Usage = .{};
        try stream_mod.streamSse(self, &response, writer, &stream_usage, transcript, tool_accum);

        if (stream_usage.valid) {
            if (self.model_context_limit) |limit| {
                if (contextUsage(limit, stream_usage.total_tokens)) |usage_info| {
                    try emitContextSummary(writer, usage_info);
                    return RespondResult.success;
                }
            }
        }

        try writer.writeAll("\n");

        return RespondResult.success;
    }

    fn forwardErrorBody(
        response: *std.http.Client.Response,
        writer: *Writer,
        status: std.http.Status,
    ) !void {
        var transfer_buf: [1024]u8 = undefined;
        var reader = response.reader(&transfer_buf);
        var scratch: [2048]u8 = undefined;
        var scratch_writer = std.io.Writer.fixed(scratch[0..]);
        const limit = std.Io.Limit.limited(scratch.len);
        _ = reader.stream(&scratch_writer, limit) catch |err| switch (err) {
            error.EndOfStream, error.WriteFailed => {},
            else => return err,
        };
        const slice = scratch_writer.buffer[0..scratch_writer.end];

        try writer.writeAll("error ");
        try writer.writeAll(@tagName(status));
        if (slice.len != 0) {
            try writer.writeAll(": ");
            try writer.writeAll(slice);
        }
        try writer.writeAll("\n");
    }

    fn configureTimeout(self: *ChatClient, connection: *std.http.Client.Connection) !void {
        if (@import("builtin").os.tag == .windows) return;
        const timeout_ns = std.math.clamp(self.last_rtt_ns * 4, min_timeout_ns, max_timeout_ns);
        const stream = connection.stream_reader.getStream();
        const fd = stream.handle;
        const seconds: posix.time_t = @intCast(timeout_ns / std.time.ns_per_s);
        const micros: c_int = @intCast((timeout_ns % std.time.ns_per_s) / 1000);
        // SAFETY: tv fields are assigned for every platform case below before use.
        var tv: posix.timeval = undefined;
        if (@hasField(@TypeOf(tv), "tv_sec")) {
            tv = .{
                .tv_sec = seconds,
                .tv_usec = micros,
            };
        } else {
            tv = .{
                .sec = seconds,
                .usec = micros,
            };
        }
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv));
    }

    fn emitContextSummary(writer: anytype, info: ContextUsage) !void {
        try writeContextSummary(writer, info, colorEnabled());
    }

    fn writeContextSummary(writer: anytype, info: ContextUsage, use_color: bool) !void {
        try writer.writeAll("\n\n");
        if (use_color) try writer.writeAll("\x1b[2m\x1b[36m");
        try writer.writeAll("[context] ");
        const whole = info.remaining_hundredths / 100;
        const fractional = info.remaining_hundredths % 100;
        var frac_buf: [2]u8 = undefined;
        frac_buf[0] = std.fmt.digitToChar(@intCast(fractional / 10), .lower);
        frac_buf[1] = std.fmt.digitToChar(@intCast(fractional % 10), .lower);
        try writer.print(
            "{d}.{s}% context left ({d}/{d} tokens used)",
            .{ whole, frac_buf[0..], info.used_tokens, info.limit_tokens },
        );
        if (use_color) try writer.writeAll("\x1b[0m");
        try writer.writeAll("\n");
    }

    fn colorEnabled() bool {
        return !std.process.hasEnvVarConstant("NO_COLOR");
    }
    pub fn captureToolCalls(
        self: *ChatClient,
        value: std.json.Value,
        tool_accum: *ToolCallAccumulator,
    ) (Allocator.Error || error{StreamFormat})!void {
        if (value != .array) return;
        for (value.array.items) |entry| {
            if (entry != .object) continue;
            const obj = entry.object;

            const index: usize = if (obj.get("index")) |index_val| blk: {
                const signed_index: i64 = switch (index_val) {
                    .integer => |i| i,
                    else => return error.StreamFormat,
                };
                if (signed_index < 0) return error.StreamFormat;
                const unsigned_index: usize = @intCast(signed_index);
                break :blk unsigned_index;
            } else if (tool_accum.calls.items.len == 0) blk: {
                break :blk 0;
            } else {
                return error.StreamFormat;
            };

            const partial = try tool_accum.acquire(self.allocator, index);

            if (obj.get("id")) |id_val| {
                if (id_val != .string) return error.StreamFormat;
                try tool_accum.setId(self.allocator, partial, id_val.string);
            }

            if (obj.get("type")) |type_val| {
                if (type_val != .string or !std.mem.eql(u8, type_val.string, "function")) return error.StreamFormat;
            }

            if (obj.get("function")) |function_val| {
                if (function_val != .object) return error.StreamFormat;
                const func_obj = function_val.object;
                if (func_obj.get("name")) |name_val| {
                    if (name_val != .string) return error.StreamFormat;
                    try tool_accum.setName(self.allocator, partial, name_val.string);
                }
                if (func_obj.get("arguments")) |args_val| {
                    if (args_val != .string) return error.StreamFormat;
                    try tool_accum.appendArguments(self.allocator, partial, args_val.string);
                }
            }
        }
    }

    fn contextUsage(limit: u32, total_tokens: i64) ?ContextUsage {
        return stream_mod.contextUsage(limit, total_tokens);
    }

    fn buildPayload(
        self: *ChatClient,
        buffer: *std.io.Writer.Allocating,
    ) ![]const u8 {
        return payload_mod.buildPayload(self, buffer);
    }

    pub fn markLastAssistantToolHandled(self: *ChatClient) void {
        var idx = self.messages.items.len;
        while (idx != 0) {
            idx -= 1;
            var message = &self.messages.items[idx];
            if (message.role != .assistant) continue;
            if (message.tool_calls.len == 0) return;
            if (message.processed_tool_calls < message.tool_calls.len) {
                message.processed_tool_calls += 1;
            }
            return;
        }
    }

    fn appendUserMessage(self: *ChatClient, content: []const u8) !void {
        var message = Message{
            .role = .user,
        };
        if (content.len != 0) {
            message.content = try util.dupSlice(self.allocator, content);
            errdefer self.allocator.free(message.content);
        }
        try self.messages.append(self.allocator, message);
    }

    fn appendAssistantMessage(
        self: *ChatClient,
        content: []const u8,
        tool_calls: []ToolCall,
        content_is_null: bool,
    ) !void {
        var message = Message{
            .role = .assistant,
            .content_is_null = content_is_null,
            .tool_calls = tool_calls,
            .processed_tool_calls = 0,
        };

        if (content.len != 0) {
            message.content = try util.dupSlice(self.allocator, content);
            errdefer self.allocator.free(message.content);
        }

        if (tool_calls.len != 0) {
            errdefer {
                msg_mod.freeToolCalls(self.allocator, tool_calls);
                self.allocator.free(tool_calls);
            }
        }

        try self.messages.append(self.allocator, message);
    }

    pub fn appendToolMessage(
        self: *ChatClient,
        call_id: []const u8,
        tool_name: []const u8,
        content: []u8,
    ) !void {
        var message = Message{
            .role = .tool,
            .content = content,
        };
        errdefer if (message.content.len != 0) self.allocator.free(message.content);

        if (call_id.len != 0) {
            message.tool_call_id = try util.dupSlice(self.allocator, call_id);
            errdefer self.allocator.free(message.tool_call_id);
        }

        if (tool_name.len != 0) {
            message.tool_name = try util.dupSlice(self.allocator, tool_name);
            errdefer self.allocator.free(message.tool_name);
        }

        try self.messages.append(self.allocator, message);
    }

    pub fn setToolContext(self: *ChatClient, context: []const u8) !void {
        if (self.tool_context.len != 0) {
            self.allocator.free(self.tool_context);
            self.tool_context = &.{};
        }
        if (context.len == 0) return;
        self.tool_context = try util.dupSlice(self.allocator, context);
    }

    fn truncateMessages(self: *ChatClient, new_len: usize) void {
        msg_mod.truncate(&self.messages, self.allocator, new_len);
    }

    fn clearMessages(self: *ChatClient) void {
        msg_mod.clear(&self.messages, self.allocator);
    }

    pub fn captureTranscript(self: *ChatClient, transcript: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
        if (text.len == 0) return;
        try transcript.appendSlice(self.allocator, text);
    }

    const MessageSnapshot = struct {
        client: *ChatClient,
        len: usize,
        committed: bool = false,

        fn init(client: *ChatClient) MessageSnapshot {
            return .{
                .client = client,
                .len = client.messages.items.len,
            };
        }

        fn commit(self: *MessageSnapshot) void {
            self.committed = true;
        }

        fn cancel(self: *MessageSnapshot) void {
            if (!self.committed) {
                self.client.truncateMessages(self.len);
            }
        }
    };

    fn buildAuthHeader(allocator: Allocator, config: Config) ![]u8 {
        if (config.api_key) |key| {
            if (key.len == 0) return error.ApiKeyMissing;
            return buildBearerHeader(allocator, key);
        }

        const key_owned = std.process.getEnvVarOwned(allocator, config.api_key_env) catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.ApiKeyMissing,
            else => return err,
        };
        defer {
            crypto.secureZero(u8, key_owned);
            allocator.free(key_owned);
        }
        if (key_owned.len == 0) return error.ApiKeyMissing;

        return buildBearerHeader(allocator, key_owned);
    }

    fn buildBearerHeader(allocator: Allocator, key: []const u8) ![]u8 {
        const prefix = "Bearer ";
        var header = try allocator.alloc(u8, prefix.len + key.len);
        @memcpy(header[0..prefix.len], prefix);
        @memcpy(header[prefix.len..], key);
        return header;
    }

    fn emitErrorLine(writer: *Writer, message: []const u8, err: ?anyerror) !void {
        try writer.writeAll("error: ");
        try writer.writeAll(message);
        if (err) |e| {
            try writer.writeAll(" (");
            try writer.writeAll(@errorName(e));
            try writer.writeAll(")");
        }
        try writer.writeAll("\n");
    }

    fn isRetryableStatus(status: std.http.Status) bool {
        return switch (status) {
            .request_timeout,
            .too_many_requests,
            .bad_gateway,
            .service_unavailable,
            .gateway_timeout,
            => true,
            else => false,
        };
    }

    const extraHeaders = [_]std.http.Header{
        .{ .name = "Accept", .value = "text/event-stream" },
        .{ .name = "Connection", .value = "keep-alive" },
    };
};

test "contextUsage reports remaining percentage and tokens" {
    const usage = ChatClient.contextUsage(4000, 1000) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 7500), usage.remaining_hundredths);
    try testing.expectEqual(@as(u64, 1000), usage.used_tokens);
    try testing.expectEqual(@as(u32, 4000), usage.limit_tokens);

    const saturated = ChatClient.contextUsage(2000, 3000) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u16, 0), saturated.remaining_hundredths);
    try testing.expectEqual(@as(u64, 3000), saturated.used_tokens);
    try testing.expectEqual(@as(u32, 2000), saturated.limit_tokens);
}

test "context summary formatting prints percentage and tokens" {
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();
    const info = ChatClient.ContextUsage{
        .remaining_hundredths = 1234,
        .used_tokens = 876,
        .limit_tokens = 7000,
    };
    try ChatClient.writeContextSummary(&writer, info, false);
    const expected =
        "\n\n[context] 12.34% context left (876/7000 tokens used)\n";
    try testing.expectEqualStrings(expected, stream.getWritten());
}
