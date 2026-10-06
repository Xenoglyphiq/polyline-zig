//! Canonical example `encode_route`: encode a three-point route and print the string.
const std = @import("std");
const polyline = @import("polyline");

pub fn main(init: std.process.Init) !void {
    const route = [_]polyline.LonLat{
        .{ .lon = -120.2, .lat = 38.5 },
        .{ .lon = -120.95, .lat = 40.7 },
        .{ .lon = -126.453, .lat = 43.252 },
    };
    const text = try polyline.encode(init.gpa, &route, .{}, null);
    defer init.gpa.free(text);
    std.debug.print("{s}\n", .{text});
}
