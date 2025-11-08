const std = @import("std");
const toml = @import("toml");

const crypto = std.crypto;

pub const defaults = struct {
    pub const base_url = "https://openrouter.ai/api";
    pub const model = "openai/gpt-5-codex";
};

pub const Loaded = struct {
    base_url: []const u8 = defaults.base_url,
    model: []const u8 = defaults.model,
    api_key: ?[]const u8 = null,

    owned_base_url: ?[]u8 = null,
    owned_model: ?[]u8 = null,
    owned_api_key: ?[]u8 = null,

    pub fn deinit(self: *Loaded, allocator: std.mem.Allocator) void {
        if (self.owned_base_url) |slice| allocator.free(slice);
        if (self.owned_model) |slice| allocator.free(slice);
        if (self.owned_api_key) |slice| {
            crypto.secureZero(u8, slice);
            allocator.free(slice);
        }
        self.* = undefined;
    }
};

pub const LoadError = error{
    ConfigParseFailed,
    ConfigTooLarge,
};

const FileSchema = struct {
    base_url: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
};

const max_config_bytes = 64 * 1024;

pub fn defaultConfigPath(allocator: std.mem.Allocator) !?[]u8 {
    const maybe_home = try discoverHome(allocator);
    const home = maybe_home orelse return null;
    defer allocator.free(home);

    const joined = try std.fs.path.join(allocator, &.{ home, ".twiddle", "twiddle.toml" });
    return joined;
}

fn discoverHome(allocator: std.mem.Allocator) !?[]u8 {
    if (try envVarOwned(allocator, "HOME")) |home| return home;
    if (try envVarOwned(allocator, "USERPROFILE")) |profile| return profile;
    return null;
}

fn envVarOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
}

pub fn load(
    allocator: std.mem.Allocator,
    config_path: ?[]const u8,
) (LoadError || std.fs.File.OpenError || std.fs.File.ReadError || std.mem.Allocator.Error)!Loaded {
    var loaded: Loaded = .{};
    if (config_path == null) return loaded;

    const path = config_path.?;

    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return loaded,
        else => return err,
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, max_config_bytes) catch |err| switch (err) {
        error.FileTooBig => return error.ConfigTooLarge,
        else => return err,
    };
    defer {
        crypto.secureZero(u8, contents);
        allocator.free(contents);
    }

    var parser = toml.Parser(FileSchema).init(allocator);
    defer parser.deinit();

    var parsed = parser.parseString(contents) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ConfigParseFailed,
    };
    defer parsed.deinit();

    const doc = parsed.value;
    if (doc.base_url) |value| {
        if (value.len == 0) return error.ConfigParseFailed;
        loaded.owned_base_url = try allocator.dupe(u8, value);
        loaded.base_url = loaded.owned_base_url.?;
    }

    if (doc.model) |value| {
        if (value.len == 0) return error.ConfigParseFailed;
        loaded.owned_model = try allocator.dupe(u8, value);
        loaded.model = loaded.owned_model.?;
    }

    if (doc.api_key) |value| {
        if (value.len == 0) return error.ConfigParseFailed;
        loaded.owned_api_key = try allocator.dupe(u8, value);
        loaded.api_key = loaded.owned_api_key.?;
    }

    return loaded;
}
