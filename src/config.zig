const std = @import("std");
const toml = @import("toml");

const crypto = std.crypto;
const testing = std.testing;

pub const SandboxMode = enum {
    read_only,
    workspace_write,
    danger_full_access,
};

pub const ApprovalPolicy = enum {
    on_request,
    never,
};

pub const defaults = struct {
    pub const base_url = "https://openrouter.ai/api";
    pub const model = "openai/gpt-5-codex";
    pub const sandbox_mode = SandboxMode.read_only;
    pub const approval_policy = ApprovalPolicy.on_request;
};

pub const Loaded = struct {
    base_url: []const u8 = defaults.base_url,
    model: []const u8 = defaults.model,
    api_key: ?[]const u8 = null,
    sandbox_mode: SandboxMode = defaults.sandbox_mode,
    approval_policy: ApprovalPolicy = defaults.approval_policy,

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
    sandbox_mode: ?[]const u8 = null,
    approval_policy: ?[]const u8 = null,
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

    if (doc.sandbox_mode) |value| {
        loaded.sandbox_mode = parseSandboxMode(value) catch return error.ConfigParseFailed;
    }

    if (doc.approval_policy) |value| {
        loaded.approval_policy = parseApprovalPolicy(value) catch return error.ConfigParseFailed;
    }

    return loaded;
}

fn parseSandboxMode(value: []const u8) !SandboxMode {
    if (std.mem.eql(u8, value, "read-only")) return .read_only;
    if (std.mem.eql(u8, value, "workspace-write")) return .workspace_write;
    if (std.mem.eql(u8, value, "danger-full-access")) return .danger_full_access;
    return error.ConfigParseFailed;
}

fn parseApprovalPolicy(value: []const u8) !ApprovalPolicy {
    if (std.mem.eql(u8, value, "on-request")) return .on_request;
    if (std.mem.eql(u8, value, "never")) return .never;
    return error.ConfigParseFailed;
}

pub fn sandboxModeLabel(mode: SandboxMode) []const u8 {
    return switch (mode) {
        .read_only => "read-only",
        .workspace_write => "workspace-write",
        .danger_full_access => "danger-full-access",
    };
}

pub fn approvalPolicyLabel(policy: ApprovalPolicy) []const u8 {
    return switch (policy) {
        .on_request => "on-request",
        .never => "never",
    };
}

test "load parses sandbox and approval policy" {
    var tmp = try testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile("twiddle.toml", "sandbox_mode = \"workspace-write\"\napproval_policy = \"never\"\n");

    const path = try tmp.dir.realpathAlloc(testing.allocator, "twiddle.toml");
    defer testing.allocator.free(path);

    var loaded = try load(testing.allocator, path);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(SandboxMode.workspace_write, loaded.sandbox_mode);
    try testing.expectEqual(ApprovalPolicy.never, loaded.approval_policy);
}
