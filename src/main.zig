const std = @import("std");
const ChatClient = @import("chat_client.zig").ChatClient;
const Config = @import("config.zig");

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

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

    const prompt = "twiddle> ";

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

        try output_stream.writeAll("\n");
        chat_client.respond(trimmed, output_stream) catch |err| {
            try output_stream.writeAll("chat error: ");
            try output_stream.writeAll(@errorName(err));
            try output_stream.writeAll("\n\n");
            try output_stream.flush();
            continue;
        };
        try output_stream.writeAll("\n");
        try output_stream.flush();
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
