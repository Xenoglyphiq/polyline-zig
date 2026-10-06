//! Google's Encoded Polyline Algorithm Format: encode and decode lists of
//! coordinates as compact ASCII strings.
//!
//! Implements the polyline spec (see `.spec/spec/SPEC.md`). Points are
//! `(lon, lat)`; the encoded string stores latitude first.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A WGS84 coordinate in degrees. Field order matches the API, not the string.
pub const LonLat = struct {
    lon: f64,
    lat: f64,
};

/// Error kinds from the spec. `OutOfMemory` is Zig's own and never appears in
/// conformance fixtures. Details (the spec's error code and byte offset) go in
/// `Diagnostics`.
pub const Error = error{ InvalidInput, LimitExceeded, OutOfMemory };

/// Filled in when an operation fails, if the caller passes one.
pub const Diagnostics = struct {
    /// Stable spec error code, e.g. `"polyline.invalid_char"`; empty on success.
    code: []const u8 = "",
    /// Byte offset into the input, when the spec defines one.
    offset: ?u64 = null,
};

/// Precision and limits. Defaults match the spec.
pub const Options = struct {
    /// Decimal places kept, 1–10. 5 is Google's; 6 is OSRM's and Valhalla's.
    precision: u8 = 5,
    /// Maximum number of points accepted or produced.
    max_points: u64 = 1_000_000,
    /// Maximum input length for `decode`, in bytes (16 MiB).
    max_text_length: u64 = 16 * 1024 * 1024,
};

const pow10 = blk: {
    var table: [11]f64 = undefined;
    var v: f64 = 1;
    for (&table) |*slot| {
        slot.* = v;
        v *= 10;
    }
    break :blk table;
};

/// 2^63 as an f64; scaled values must lie in [-2^63, 2^63).
const two63: f64 = 9223372036854775808.0;

fn fail(diag: ?*Diagnostics, comptime code: []const u8, offset: ?u64, err: Error) Error {
    if (diag) |d| d.* = .{ .code = "polyline." ++ code, .offset = offset };
    return err;
}

fn checkPrecision(precision: u8, diag: ?*Diagnostics) Error!f64 {
    if (precision < 1 or precision > 10)
        return fail(diag, "precision_out_of_range", null, error.InvalidInput);
    return pow10[precision];
}

/// Scale one coordinate to its integer form (spec §3 `encode`, step 3).
fn scaleValue(x: f64, scale: f64, diag: ?*Diagnostics) Error!i64 {
    if (!std.math.isFinite(x)) return fail(diag, "non_finite", null, error.InvalidInput);
    const s = x * scale;
    if (!(s >= -two63 and s < two63)) return fail(diag, "overflow", null, error.InvalidInput);
    // @round rounds half away from zero, the family-wide rule.
    return @intFromFloat(@round(s));
}

fn zigzag(d: i64) u64 {
    const shifted: u64 = @bitCast(d << 1);
    const sign: u64 = @bitCast(d >> 63);
    return shifted ^ sign;
}

fn encodedLen(d: i64) usize {
    var u = zigzag(d);
    var n: usize = 1;
    while (u >= 0x20) : (u >>= 5) n += 1;
    return n;
}

fn writeValue(out: []u8, d: i64) usize {
    var u = zigzag(d);
    var i: usize = 0;
    while (u >= 0x20) : (u >>= 5) {
        out[i] = @intCast((0x20 | (u & 0x1F)) + 63);
        i += 1;
    }
    out[i] = @intCast(u + 63);
    return i + 1;
}

fn delta(curr: i64, prev: i64, diag: ?*Diagnostics) Error!i64 {
    return std.math.sub(i64, curr, prev) catch return fail(diag, "overflow", null, error.InvalidInput);
}

/// Spec operation `encode`. Encodes `points` as a polyline string.
/// The caller owns the returned slice and frees it with `gpa`.
pub fn encode(gpa: Allocator, points: []const LonLat, opts: Options, diag: ?*Diagnostics) Error![]u8 {
    const scale = try checkPrecision(opts.precision, diag);
    if (points.len > opts.max_points) return fail(diag, "too_many_points", null, error.LimitExceeded);

    // Pass 1: validate and scale every coordinate before any delta (spec error order).
    for (points) |p| {
        _ = try scaleValue(p.lat, scale, diag);
        _ = try scaleValue(p.lon, scale, diag);
    }

    // Pass 2: deltas, overflow checks and the exact output length.
    var len: usize = 0;
    var prev = [2]i64{ 0, 0 };
    for (points) |p| {
        const curr = [2]i64{ try scaleValue(p.lat, scale, diag), try scaleValue(p.lon, scale, diag) };
        len += encodedLen(try delta(curr[0], prev[0], diag));
        len += encodedLen(try delta(curr[1], prev[1], diag));
        prev = curr;
    }

    // Pass 3: write. No errors are possible past this point except allocation.
    const out = try gpa.alloc(u8, len);
    var i: usize = 0;
    prev = .{ 0, 0 };
    for (points) |p| {
        const curr = [2]i64{ scaleValue(p.lat, scale, null) catch unreachable, scaleValue(p.lon, scale, null) catch unreachable };
        i += writeValue(out[i..], curr[0] - prev[0]);
        i += writeValue(out[i..], curr[1] - prev[1]);
        prev = curr;
    }
    std.debug.assert(i == len);
    return out;
}

/// Spec operation `decode`. Decodes a polyline string into points.
/// The caller owns the returned slice and frees it with `gpa`.
pub fn decode(gpa: Allocator, text: []const u8, opts: Options, diag: ?*Diagnostics) Error![]LonLat {
    const scale = try checkPrecision(opts.precision, diag);
    if (text.len > opts.max_text_length) return fail(diag, "text_too_long", null, error.LimitExceeded);

    var points: std.ArrayList(LonLat) = .empty;
    errdefer points.deinit(gpa);

    var sums = [2]i64{ 0, 0 };
    var axis: usize = 0;
    var lat_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const start = i;
        var u: u64 = 0;
        var chunks: u8 = 0;
        while (true) {
            if (i >= text.len) return fail(diag, "truncated", start, error.InvalidInput);
            const c = text[i];
            if (c < 63 or c > 126) return fail(diag, "invalid_char", i, error.InvalidInput);
            const b: u64 = c - 63;
            chunks += 1;
            if (chunks > 13) return fail(diag, "overflow", start, error.InvalidInput);
            const shift: u6 = @intCast(5 * (chunks - 1));
            // At shift 60 only 4 bits fit in a u64.
            if (shift == 60 and (b & 0x1F) > 0xF) return fail(diag, "overflow", start, error.InvalidInput);
            u |= (b & 0x1F) << shift;
            i += 1;
            if (b < 0x20) break;
        }
        const half: i64 = @bitCast(u >> 1);
        const d = if (u & 1 == 1) ~half else half;
        sums[axis] = std.math.add(i64, sums[axis], d) catch
            return fail(diag, "overflow", start, error.InvalidInput);
        if (axis == 0) {
            lat_start = start;
            axis = 1;
        } else {
            if (points.items.len + 1 > opts.max_points)
                return fail(diag, "too_many_points", null, error.LimitExceeded);
            const lon = @as(f64, @floatFromInt(sums[1])) / scale;
            const lat = @as(f64, @floatFromInt(sums[0])) / scale;
            try points.append(gpa, .{ .lon = lon, .lat = lat });
            axis = 0;
        }
    }
    if (axis == 1) return fail(diag, "truncated", lat_start, error.InvalidInput);
    return points.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Unit tests. The conformance runner (`zig build conformance`) is the real
// test suite; these cover the canonical example and a few internals.
// ---------------------------------------------------------------------------

const testing = std.testing;
const google_points = [_]LonLat{
    .{ .lon = -120.2, .lat = 38.5 },
    .{ .lon = -120.95, .lat = 40.7 },
    .{ .lon = -126.453, .lat = 43.252 },
};
const google_text = "_p~iF~ps|U_ulLnnqC_mqNvxq`@";

test "encode Google's example" {
    const s = try encode(testing.allocator, &google_points, .{}, null);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings(google_text, s);
}

test "decode Google's example" {
    const pts = try decode(testing.allocator, google_text, .{}, null);
    defer testing.allocator.free(pts);
    try testing.expectEqual(@as(usize, 3), pts.len);
    for (pts, google_points) |got, want| {
        try testing.expectApproxEqAbs(want.lon, got.lon, 1e-12);
        try testing.expectApproxEqAbs(want.lat, got.lat, 1e-12);
    }
}

test "rounding is half away from zero, without the +0.5 bug" {
    try testing.expectEqual(@as(i64, 3), try scaleValue(2.5, 1, null));
    try testing.expectEqual(@as(i64, -3), try scaleValue(-2.5, 1, null));
    try testing.expectEqual(@as(i64, 0), try scaleValue(0.49999999999999994, 1, null));
}

test "diagnostics carry code and offset" {
    var diag: Diagnostics = .{};
    try testing.expectError(error.InvalidInput, decode(testing.allocator, "_p~iF ~ps|U", .{}, &diag));
    try testing.expectEqualStrings("polyline.invalid_char", diag.code);
    try testing.expectEqual(@as(?u64, 5), diag.offset);
}

test "fuzz: decode never crashes, and what it accepts re-encodes" {
    try testing.fuzz({}, fuzzDecode, .{});
}

fn fuzzDecode(context: void, smith: *testing.Smith) !void {
    _ = context;
    var buf: [256]u8 = undefined;
    const len = smith.valueRangeAtMost(u16, 0, buf.len);
    smith.bytes(buf[0..len]);
    const text = buf[0..len];

    const gpa = testing.allocator;
    var diag: Diagnostics = .{};
    const pts = decode(gpa, text, .{}, &diag) catch |err| {
        try testing.expect(err == error.InvalidInput or err == error.LimitExceeded);
        try testing.expect(diag.code.len > 0);
        return;
    };
    defer gpa.free(pts);
    // Re-encoding decoded points either succeeds or reports overflow (values near
    // the i64 edge lose precision as f64); it never fails any other way.
    const again = encode(gpa, pts, .{}, &diag) catch |err| {
        try testing.expect(err == error.InvalidInput);
        try testing.expectEqualStrings("polyline.overflow", diag.code);
        return;
    };
    gpa.free(again);
}
