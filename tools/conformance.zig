//! Conformance runner: loads `.spec/conformance/manifest.json`, runs every case,
//! and compares results the way the case says to (`exact` or `float_tol`).
//!
//! Usage: `zig build conformance` (or `conformance <manifest.json>`).
//! Exit code 0 only if every case passes.

const std = @import("std");
const Io = std.Io;
const json = std.json;
const polyline = @import("polyline");

const Outcome = enum { pass, fail };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: {s} <manifest.json>\n", .{args[0]});
        std.process.exit(2);
    }
    const bytes = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(64 * 1024 * 1024));
    const parsed = try json.parseFromSliceLeaky(json.Value, arena, bytes, .{});
    const manifest = parsed.object;
    const spec_version = manifest.get("spec_version").?.string;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_writer.interface;

    var passed: usize = 0;
    var total: usize = 0;
    for (manifest.get("cases").?.array.items) |case_value| {
        const case = case_value.object;
        total += 1;
        var why: std.ArrayList(u8) = .empty;
        const outcome = runCase(init.gpa, arena, case, &why) catch |err| blk: {
            try why.print(arena, "runner error: {s}", .{@errorName(err)});
            break :blk .fail;
        };
        switch (outcome) {
            .pass => passed += 1,
            .fail => try out.print("FAIL {s}: {s}\n", .{ case.get("id").?.string, why.items }),
        }
    }
    // No io-level cases exist; every case is core, so full == core.
    try out.print("polyline zig (spec {s}): core {d}/{d}, full {d}/{d}\n", .{ spec_version, passed, total, passed, total });
    try out.flush();
    if (passed != total) std.process.exit(1);
}

fn runCase(gpa: std.mem.Allocator, arena: std.mem.Allocator, case: json.ObjectMap, why: *std.ArrayList(u8)) !Outcome {
    const op = case.get("op").?.string;
    const input = case.get("input").?.object.get("value").?;
    const expect = case.get("expect").?.object;
    const opts = try options(case.get("options"));

    var diag: polyline.Diagnostics = .{};
    if (std.mem.eql(u8, op, "encode")) {
        const points = try toPoints(arena, input);
        const result = polyline.encode(gpa, points, opts, &diag);
        if (result) |text| {
            defer gpa.free(text);
            return compareEncoded(arena, text, expect, why);
        } else |err| return compareError(arena, err, diag, expect, why);
    } else if (std.mem.eql(u8, op, "decode")) {
        const result = polyline.decode(gpa, input.string, opts, &diag);
        if (result) |points| {
            defer gpa.free(points);
            return comparePoints(arena, points, expect, case.get("tolerance"), why);
        } else |err| return compareError(arena, err, diag, expect, why);
    }
    try why.print(arena, "unknown op {s}", .{op});
    return .fail;
}

fn options(value: ?json.Value) !polyline.Options {
    var opts: polyline.Options = .{};
    const obj = (value orelse return opts).object;
    if (obj.get("precision")) |v| opts.precision = std.math.cast(u8, v.integer) orelse 255;
    if (obj.get("max_points")) |v| opts.max_points = @intCast(v.integer);
    if (obj.get("max_text_length")) |v| opts.max_text_length = @intCast(v.integer);
    return opts;
}

/// Canonical JSON floats: numbers, or "NaN" / "Infinity" / "-Infinity" strings.
fn toFloat(v: json.Value) !f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        .string => |s| if (std.mem.eql(u8, s, "NaN"))
            std.math.nan(f64)
        else if (std.mem.eql(u8, s, "Infinity"))
            std.math.inf(f64)
        else if (std.mem.eql(u8, s, "-Infinity"))
            -std.math.inf(f64)
        else
            error.BadFloat,
        else => error.BadFloat,
    };
}

fn toPoints(arena: std.mem.Allocator, v: json.Value) ![]polyline.LonLat {
    const items = v.array.items;
    const points = try arena.alloc(polyline.LonLat, items.len);
    for (items, points) |item, *p| {
        p.* = .{ .lon = try toFloat(item.object.get("lon").?), .lat = try toFloat(item.object.get("lat").?) };
    }
    return points;
}

fn compareEncoded(arena: std.mem.Allocator, text: []const u8, expect: json.ObjectMap, why: *std.ArrayList(u8)) !Outcome {
    const want = (expect.get("value") orelse {
        try why.print(arena, "expected an error, got \"{s}\"", .{text});
        return .fail;
    }).string;
    if (std.mem.eql(u8, text, want)) return .pass;
    try why.print(arena, "expected \"{s}\", got \"{s}\"", .{ want, text });
    return .fail;
}

fn comparePoints(arena: std.mem.Allocator, got: []const polyline.LonLat, expect: json.ObjectMap, tol_value: ?json.Value, why: *std.ArrayList(u8)) !Outcome {
    const want = try toPoints(arena, (expect.get("value") orelse {
        try why.print(arena, "expected an error, got {d} points", .{got.len});
        return .fail;
    }));
    const tol = if (tol_value) |t| try toFloat(t) else 0;
    if (got.len != want.len) {
        try why.print(arena, "expected {d} points, got {d}", .{ want.len, got.len });
        return .fail;
    }
    for (got, want, 0..) |g, w, idx| {
        if (@abs(g.lon - w.lon) > tol or @abs(g.lat - w.lat) > tol) {
            try why.print(arena, "point {d}: expected ({d}, {d}), got ({d}, {d})", .{ idx, w.lon, w.lat, g.lon, g.lat });
            return .fail;
        }
    }
    return .pass;
}

fn kindOf(err: polyline.Error) []const u8 {
    return switch (err) {
        error.InvalidInput => "invalid_input",
        error.LimitExceeded => "limit_exceeded",
        error.OutOfMemory => "out_of_memory",
    };
}

fn compareError(arena: std.mem.Allocator, err: polyline.Error, diag: polyline.Diagnostics, expect: json.ObjectMap, why: *std.ArrayList(u8)) !Outcome {
    const want = (expect.get("error") orelse {
        try why.print(arena, "unexpected error {s} ({s})", .{ diag.code, kindOf(err) });
        return .fail;
    }).object;
    const want_kind = want.get("kind").?.string;
    const want_code = want.get("code").?.string;
    if (!std.mem.eql(u8, kindOf(err), want_kind) or !std.mem.eql(u8, diag.code, want_code)) {
        try why.print(arena, "expected {s}/{s}, got {s}/{s}", .{ want_kind, want_code, kindOf(err), diag.code });
        return .fail;
    }
    if (want.get("offset")) |o| {
        const want_offset: u64 = @intCast(o.integer);
        if (diag.offset == null or diag.offset.? != want_offset) {
            try why.print(arena, "expected offset {d}, got {?d}", .{ want_offset, diag.offset });
            return .fail;
        }
    }
    return .pass;
}
