//! Canonical example `precision_6`: round-trip a route at precision 6 (OSRM, Valhalla).
const std = @import("std");
const polyline = @import("polyline");

pub fn main(init: std.process.Init) !void {
    const route = [_]polyline.LonLat{
        .{ .lon = -73.985713, .lat = 40.748441 },
        .{ .lon = -73.978569, .lat = 40.751657 },
        .{ .lon = -73.968285, .lat = 40.785091 },
    };
    const opts: polyline.Options = .{ .precision = 6 };
    const text = try polyline.encode(init.gpa, &route, opts, null);
    defer init.gpa.free(text);
    const back = try polyline.decode(init.gpa, text, opts, null);
    defer init.gpa.free(back);

    std.debug.print("{s}\n", .{text});
    for (route, back) |a, b| {
        std.debug.print("({d}, {d}) -> ({d}, {d})\n", .{ a.lon, a.lat, b.lon, b.lat });
        if (@abs(a.lon - b.lon) > 1e-6 or @abs(a.lat - b.lat) > 1e-6) return error.RoundTripMismatch;
    }
    std.debug.print("round trip matches\n", .{});
}
