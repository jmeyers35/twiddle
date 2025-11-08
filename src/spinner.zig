const std = @import("std");

pub const Spinner = struct {
    const Allocator = std.mem.Allocator;

    allocator: Allocator,
    writer: *std.Io.Writer,
    message: []const u8,
    state: ?*State = null,
    thread: ?std.Thread = null,

    const frame_delay_ns = 80 * std.time.ns_per_ms;
    const frames = [_][]const u8{ "|", "/", "-", "\\" };

    const State = struct {
        writer: *std.Io.Writer,
        message: []const u8,
        stop_flag: std.atomic.Value(bool),
        rendered_len: usize,
    };

    pub fn init(allocator: Allocator, writer: *std.Io.Writer, message: []const u8) Spinner {
        return .{
            .allocator = allocator,
            .writer = writer,
            .message = message,
        };
    }

    pub fn start(self: *Spinner) !void {
        if (self.state != null) return;

        const state = try self.allocator.create(State);
        errdefer self.allocator.destroy(state);
        state.* = .{
            .writer = self.writer,
            .message = self.message,
            .stop_flag = std.atomic.Value(bool).init(false),
            .rendered_len = 0,
        };

        const thread = try std.Thread.spawn(.{}, run, .{state});
        self.state = state;
        self.thread = thread;
    }

    pub fn stop(self: *Spinner) void {
        const state = self.state orelse return;
        state.stop_flag.store(true, .seq_cst);

        if (self.thread) |thread| {
            thread.join();
        }

        self.allocator.destroy(state);
        self.state = null;
        self.thread = null;
    }

    pub fn isActive(self: *const Spinner) bool {
        return self.state != null;
    }

    fn run(state: *State) void {
        var frame_index: usize = 0;
        while (!state.stop_flag.load(.acquire)) : (frame_index = (frame_index + 1) % frames.len) {
            render(state, frames[frame_index]) catch break;
            std.Thread.sleep(frame_delay_ns);
        }

        clear(state) catch |err| {
            std.log.warn("spinner clear failed: {s}", .{@errorName(err)});
        };
    }

    fn render(state: *State, frame: []const u8) !void {
        try state.writer.writeByte('\r');
        if (state.rendered_len != 0) {
            try writeSpaces(state.writer, state.rendered_len);
            try state.writer.writeByte('\r');
        }

        try state.writer.writeAll(frame);
        try state.writer.writeByte(' ');
        try state.writer.writeAll(state.message);
        state.rendered_len = frame.len + 1 + state.message.len;
        try state.writer.flush();
    }

    fn clear(state: *State) !void {
        if (state.rendered_len == 0) return;
        try state.writer.writeByte('\r');
        try writeSpaces(state.writer, state.rendered_len);
        try state.writer.writeByte('\r');
        try state.writer.flush();
        state.rendered_len = 0;
    }
};

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    if (count == 0) return;
    var chunk = std.mem.zeroes([32]u8);
    @memset(chunk[0..], ' ');
    var remaining = count;
    while (remaining > 0) {
        const emit = @min(remaining, chunk.len);
        try writer.writeAll(chunk[0..emit]);
        remaining -= emit;
    }
}

pub const SpinnerWriter = struct {
    spinner: *Spinner,
    inner: *std.Io.Writer,
    interface: std.Io.Writer,
    triggered: bool,
    buffer_storage: [1]u8,

    pub fn init(self: *SpinnerWriter, inner: *std.Io.Writer, spinner: *Spinner) void {
        self.spinner = spinner;
        self.inner = inner;
        self.triggered = false;
        self.buffer_storage = .{0};
        self.interface = .{
            .vtable = &.{
                .drain = drain,
                .sendFile = sendFile,
                .flush = flush,
                .rebase = rebase,
            },
            .buffer = self.buffer_storage[0..0],
        };
    }

    pub fn writer(self: *SpinnerWriter) *std.Io.Writer {
        return &self.interface;
    }

    fn ensureStopped(self: *SpinnerWriter) void {
        if (!self.triggered) {
            self.spinner.stop();
            self.triggered = true;
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *SpinnerWriter = @fieldParentPtr("interface", w);
        self.ensureStopped();
        return std.Io.Writer.writeSplat(self.inner, data, splat);
    }

    fn sendFile(
        w: *std.Io.Writer,
        reader: *std.fs.File.Reader,
        limit: std.Io.Limit,
    ) std.Io.Writer.FileError!usize {
        const self: *SpinnerWriter = @fieldParentPtr("interface", w);
        self.ensureStopped();
        return self.inner.vtable.sendFile(self.inner, reader, limit);
    }

    fn flush(w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *SpinnerWriter = @fieldParentPtr("interface", w);
        self.ensureStopped();
        return self.inner.vtable.flush(self.inner);
    }

    fn rebase(w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        const self: *SpinnerWriter = @fieldParentPtr("interface", w);
        self.ensureStopped();
        return self.inner.vtable.rebase(self.inner, preserve, capacity);
    }
};
