//! Benchmark per `.spec/bench/README.md`: precision 5; decode once untimed;
//! 3 warm-up runs, then 15 timed runs each of encode(points) and decode(text);
//! report median and min. Always built ReleaseFast (`zig build bench`).

const std = @import("std");
const Io = std.Io;
const polyline = @import("polyline");

const warmup = 3;
const runs = 15;

fn elapsedMs(io: Io, start: Io.Timestamp) f64 {
    const ns = start.durationTo(Io.Timestamp.now(io, .awake)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn report(name: []const u8, samples: *[runs]f64) void {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    std.debug.print("{s} median {d:.3} ms (min {d:.3})", .{ name, samples[runs / 2], samples[0] });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else ".spec/bench/route_100k.polyline";

    const raw = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    defer gpa.free(raw);
    const text = std.mem.trimEnd(u8, raw, "\n");

    const points = try polyline.decode(gpa, text, .{}, null);
    defer gpa.free(points);
    const again = try polyline.encode(gpa, points, .{}, null);
    defer gpa.free(again);
    if (!std.mem.eql(u8, again, text)) return error.RoundTripMismatch;

    var enc: [runs]f64 = undefined;
    for (0..warmup + runs) |i| {
        const start = Io.Timestamp.now(io, .awake);
        const s = try polyline.encode(gpa, points, .{}, null);
        const ms = elapsedMs(io, start);
        gpa.free(s);
        if (i >= warmup) enc[i - warmup] = ms;
    }
    var dec: [runs]f64 = undefined;
    for (0..warmup + runs) |i| {
        const start = Io.Timestamp.now(io, .awake);
        const p = try polyline.decode(gpa, text, .{}, null);
        const ms = elapsedMs(io, start);
        gpa.free(p);
        if (i >= warmup) dec[i - warmup] = ms;
    }

    std.debug.print("polyline zig ReleaseFast ({d} points): ", .{points.len});
    report("encode", &enc);
    std.debug.print(", ", .{});
    report("decode", &dec);
    std.debug.print("\n", .{});
}
