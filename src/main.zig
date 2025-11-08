const std = @import("std");

pub fn main() !void {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdout_buffer: [4 * 1024]u8 = undefined;

    var stdin_reader = std.fs.File.reader(stdin, stdin_buffer[0..]);
    var stdout_writer = std.fs.File.writer(stdout, stdout_buffer[0..]);

    const input_stream = &stdin_reader.interface;
    const output_stream = &stdout_writer.interface;

    const prompt = "twiddle> ";
    const simulated_response =
        \\Simulated agent response:
        \\- I understood your input.
        \\- No real LLM call happened (yet).
        \\- We're just exercising the IO loop.
    ;

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

        try output_stream.writeAll("\nSimulating agent output for: \"");
        try output_stream.writeAll(trimmed);
        try output_stream.writeAll("\"\n");
        try output_stream.writeAll(simulated_response);
        try output_stream.writeAll("\n\n");
        try output_stream.flush();
    }
}
