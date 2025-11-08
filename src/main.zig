const std = @import("std");
const ChatClient = @import("chat_client.zig").ChatClient;

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

    var chat_client = ChatClient.init(gpa.allocator(), .{}) catch |err| switch (err) {
        error.ApiKeyMissing => {
            try output_stream.writeAll("\nMissing OPENAI_API_KEY environment variable (ChatClient.Config.api_key_env).\n");
            try output_stream.writeAll("Set it to your OpenAI key before running twiddle.\n");
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
