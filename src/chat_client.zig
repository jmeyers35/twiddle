const std = @import("std");
const model_context = @import("model_context.zig");

pub const ChatClient = struct {
    const Allocator = std.mem.Allocator;
    const Writer = std.io.Writer;
    const crypto = std.crypto;
    const posix = std.posix;

    pub const Config = struct {
        api_key_env: []const u8 = "OPENAI_API_KEY",
        api_key: ?[]const u8 = null,
        base_url: []const u8,
        path: []const u8 = "/v1/chat/completions",
        model: []const u8,
        temperature: f32 = 0.15,
        max_completion_tokens: ?u32 = 512,
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
        };

        client.uri = try std.Uri.parse(client.uri_storage);

        errdefer client.http.deinit();

        client.auth_header = try buildAuthHeader(allocator, config);
        client.model_context_limit = model_context.lookup(allocator, config.model);
        return client;
    }

    pub fn deinit(self: *ChatClient) void {
        self.http.deinit();
        if (self.uri_storage.len != 0) {
            self.allocator.free(self.uri_storage);
        }
        if (self.auth_header.len != 0) {
            crypto.secureZero(u8, self.auth_header);
            self.allocator.free(self.auth_header);
        }
        self.* = undefined;
    }

    pub fn respond(self: *ChatClient, user_input: []const u8, writer: *Writer) !void {
        if (user_input.len == 0) return;

        var attempts: u8 = 0;
        while (true) : (attempts += 1) {
            const result = self.tryRespond(user_input, writer) catch |err| switch (err) {
                error.UpstreamRejected => |e| {
                    try emitErrorLine(writer, "upstream error", e);
                    return;
                },
                else => return err,
            };

            switch (result) {
                .success => return,
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

    fn tryRespond(self: *ChatClient, user_input: []const u8, writer: *Writer) !RespondResult {
        if (self.config.unix_socket_path.len != 0) {
            return error.UnixSocketsUnavailable;
        }

        var payload_storage: [96 * 1024]u8 = undefined;
        const payload = try buildPayload(self.config, user_input, &payload_storage);

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
        try self.streamSse(&response, writer, &stream_usage);

        if (stream_usage.valid) {
            if (self.model_context_limit) |limit| {
                if (contextRemainingPercent(limit, stream_usage.total_tokens)) |percent| {
                    try emitContextSummary(writer, percent);
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

    fn contextRemainingPercent(limit: u32, total_tokens: i64) ?u8 {
        if (limit == 0 or total_tokens < 0) return null;
        const limit_u64: u64 = limit;
        const used_u64: u64 = @intCast(total_tokens);
        if (used_u64 >= limit_u64) return 0;
        const used_percent = (used_u64 * 100) / limit_u64;
        if (used_percent >= 100) return 0;
        const remaining = 100 - used_percent;
        return @intCast(remaining);
    }

    fn emitContextSummary(writer: *Writer, percent: u8) !void {
        const use_color = colorEnabled();
        try writer.writeAll("\n\n");
        if (use_color) try writer.writeAll("\x1b[2m\x1b[36m");
        try writer.writeAll("[context] ");
        try writer.print("{d}% context left", .{percent});
        if (use_color) try writer.writeAll("\x1b[0m");
        try writer.writeAll("\n");
    }

    fn colorEnabled() bool {
        return !std.process.hasEnvVarConstant("NO_COLOR");
    }
    fn streamSse(
        self: *ChatClient,
        response: *std.http.Client.Response,
        writer: *Writer,
        usage: *Usage,
    ) !void {
        var transfer_buf: [2048]u8 = undefined;
        var reader = response.reader(&transfer_buf);
        var chunk_buf: [2048]u8 = undefined;

        var line_buf = std.ArrayListUnmanaged(u8){};
        defer line_buf.deinit(self.allocator);
        var event_buf: [16 * 1024]u8 = undefined;
        var event_len: usize = 0;
        var done = false;
        var chunk_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
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
                    const trimmed = trimLine(line_buf.items);
                    line_buf.clearRetainingCapacity();
                    if (trimmed.len == 0) {
                        if (event_len > 0) {
                            done = try handleEvent(event_buf[0..event_len], writer, usage, &chunk_arena);
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

                try line_buf.append(self.allocator, byte);
            }

            if (reached_eof) break;
        }

        if (!done and event_len > 0) {
            _ = try handleEvent(event_buf[0..event_len], writer, usage, &chunk_arena);
        }
    }

    fn handleEvent(
        data: []const u8,
        writer: *Writer,
        usage: *Usage,
        chunk_arena: *std.heap.ArenaAllocator,
    ) !bool {
        if (data.len == 0) return false;
        if (std.mem.eql(u8, data, "[DONE]")) return true;

        _ = chunk_arena.reset(.retain_capacity);
        var parsed = try std.json.parseFromSlice(std.json.Value, chunk_arena.allocator(), data, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return false;
        try emitChoices(root.object, writer);
        try captureUsage(root.object, usage);

        return false;
    }

    fn emitChoices(object: std.json.ObjectMap, writer: *Writer) !void {
        const choices_val = object.get("choices") orelse return;
        if (choices_val != .array) return;
        for (choices_val.array.items) |choice| {
            if (choice != .object) continue;
            const delta_val = choice.object.get("delta") orelse continue;
            if (delta_val == .string) {
                try writer.writeAll(delta_val.string);
                try writer.flush();
                continue;
            }
            if (delta_val != .object) continue;
            const delta_obj = delta_val.object;
            if (delta_obj.get("content")) |content_val| {
                try emitContent(content_val, writer);
            } else if (delta_obj.get("output_text")) |text_val| {
                if (text_val == .string) {
                    try writer.writeAll(text_val.string);
                    try writer.flush();
                }
            }
        }
    }

    fn emitContent(value: std.json.Value, writer: *Writer) !void {
        switch (value) {
            .string => |str| {
                try writer.writeAll(str);
                try writer.flush();
            },
            .array => |arr| {
                for (arr.items) |item| {
                    if (item == .string) {
                        try writer.writeAll(item.string);
                    } else if (item == .object) {
                        if (item.object.get("text")) |text_val| {
                            if (text_val == .string) {
                                try writer.writeAll(text_val.string);
                            }
                        } else if (item.object.get("content")) |content| {
                            try emitContent(content, writer);
                        }
                    }
                }
                try writer.flush();
            },
            .object => |obj| {
                if (obj.get("text")) |text_val| {
                    if (text_val == .string) {
                        try writer.writeAll(text_val.string);
                        try writer.flush();
                    }
                }
            },
            else => {},
        }
    }

    const Usage = struct {
        prompt_tokens: i64 = 0,
        completion_tokens: i64 = 0,
        total_tokens: i64 = 0,
        valid: bool = false,
    };

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

    fn trimLine(line: []const u8) []const u8 {
        if (line.len == 0) return line;
        if (line[line.len - 1] == '\r') return line[0 .. line.len - 1];
        return line;
    }

    fn buildPayload(config: Config, user_input: []const u8, storage: []u8) ![]u8 {
        var buffer_writer = std.io.Writer.fixed(storage);
        var jw = std.json.Stringify{
            .writer = &buffer_writer,
            .options = .{ .whitespace = .minified },
        };

        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("model"));
        try stringifyStep(jw.write(config.model));

        try stringifyStep(jw.objectField("stream"));
        try stringifyStep(jw.write(true));

        try stringifyStep(jw.objectField("stream_options"));
        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("include_usage"));
        try stringifyStep(jw.write(true));
        try stringifyStep(jw.endObject());

        if (config.max_completion_tokens) |limit| {
            try stringifyStep(jw.objectField("max_completion_tokens"));
            try stringifyStep(jw.write(limit));
        }

        try stringifyStep(jw.objectField("temperature"));
        try stringifyStep(jw.write(config.temperature));

        try stringifyStep(jw.objectField("messages"));
        try stringifyStep(jw.beginArray());
        if (config.system_prompt.len != 0) {
            try stringifyStep(jw.beginObject());
            try stringifyStep(jw.objectField("role"));
            try stringifyStep(jw.write("system"));
            try stringifyStep(jw.objectField("content"));
            try stringifyStep(jw.write(config.system_prompt));
            try stringifyStep(jw.endObject());
        }

        try stringifyStep(jw.beginObject());
        try stringifyStep(jw.objectField("role"));
        try stringifyStep(jw.write("user"));
        try stringifyStep(jw.objectField("content"));
        try stringifyStep(jw.write(user_input));
        try stringifyStep(jw.endObject());

        try stringifyStep(jw.endArray());
        try stringifyStep(jw.endObject());

        return buffer_writer.buffer[0..buffer_writer.end];
    }

    inline fn stringifyStep(res: std.json.Stringify.Error!void) error{PayloadTooLarge}!void {
        return res catch |err| switch (err) {
            error.WriteFailed => return error.PayloadTooLarge,
        };
    }

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
