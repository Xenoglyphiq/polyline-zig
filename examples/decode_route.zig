//! Canonical example `decode_route`: decode Google's example and print each point.
const std = @import("std");
const polyline = @import("polyline");

pub fn main(init: std.process.Init) !void {
    var diag: polyline.Diagnostics = .{};
    const points = polyline.decode(init.gpa, "_p~iF~ps|U_ulLnnqC_mqNvxq`@", .{}, &diag) catch |err| {
        std.debug.print("{s}: {s} at byte {?d}\n", .{ @errorName(err), diag.code, diag.offset });
        return err;
    };
    defer init.gpa.free(points);
    for (points) |p| std.debug.print("lon {d}, lat {d}\n", .{ p.lon, p.lat });
}
