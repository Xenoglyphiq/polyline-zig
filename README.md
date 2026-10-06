# Polyline for Zig

Encode and decode lists of coordinates as compact ASCII strings. Implements Google's Encoded Polyline Algorithm Format · Spec v0.1.0 · Conformance: **core ✓ full ✓** (44/44)

> **Coordinate order:** `LonLat` is `(lon, lat)`; the encoded string stores latitude first. The library converts at the boundary.

Requires Zig **0.17.0**. Standard library only.

## Install

```
zig fetch --save git+https://github.com/Xenoglyphiq/polyline-zig#v0.1.0
```

Then in `build.zig`:

```zig
const polyline = b.dependency("polyline", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("polyline", polyline.module("polyline"));
```

## Quick start

```zig
const polyline = @import("polyline");

const text = try polyline.encode(gpa, &.{
    .{ .lon = -120.2, .lat = 38.5 },
    .{ .lon = -120.95, .lat = 40.7 },
}, .{}, null);
defer gpa.free(text);

const points = try polyline.decode(gpa, text, .{}, null);
defer gpa.free(points);
```

Every allocating call takes the allocator first; the caller owns and frees the result.

## Examples

Run all three with `zig build examples`.

### 1. Encode a three-point route (`examples/encode_route.zig`)
```zig
const route = [_]polyline.LonLat{
    .{ .lon = -120.2, .lat = 38.5 },
    .{ .lon = -120.95, .lat = 40.7 },
    .{ .lon = -126.453, .lat = 43.252 },
};
const text = try polyline.encode(init.gpa, &route, .{}, null);
defer init.gpa.free(text);
// _p~iF~ps|U_ulLnnqC_mqNvxq`@
```

### 2. Decode Google's example (`examples/decode_route.zig`)
```zig
var diag: polyline.Diagnostics = .{};
const points = polyline.decode(init.gpa, "_p~iF~ps|U_ulLnnqC_mqNvxq`@", .{}, &diag) catch |err| {
    std.debug.print("{s}: {s} at byte {?d}\n", .{ @errorName(err), diag.code, diag.offset });
    return err;
};
defer init.gpa.free(points);
for (points) |p| std.debug.print("lon {d}, lat {d}\n", .{ p.lon, p.lat });
```

### 3. Round-trip at precision 6 (`examples/precision_6.zig`)
```zig
const opts: polyline.Options = .{ .precision = 6 }; // OSRM, Valhalla
const text = try polyline.encode(init.gpa, &route, opts, null);
defer init.gpa.free(text);
const back = try polyline.decode(init.gpa, text, opts, null);
defer init.gpa.free(back);
```

## Limits and errors

| Limit | Default | Option name |
|---|---|---|
| Points accepted or produced | 1,000,000 | `Options.max_points` |
| Input length for `decode` | 16 MiB | `Options.max_text_length` |

Precision (1–10, default 5) is `Options.precision`.

Errors are the error set `polyline.Error`, whose names are the spec's kinds: `InvalidInput` and `LimitExceeded` (plus Zig's `OutOfMemory`). Pass a `*polyline.Diagnostics` to get the stable `code` (such as `polyline.invalid_char`) and, where defined, the byte `offset`. Full list: spec §3.

`\` is a valid polyline character. Strings copied from JavaScript source often contain `\\` escapes and decode to different points without any error.

## Modules

| Module | Layer | Needs |
|---|---|---|
| `polyline` | core | nothing beyond the standard library |

There is no io layer: everything works on in-memory slices.

## Development

| Command | What |
|---|---|
| `zig build test` | Unit tests |
| `zig build test --fuzz=1M` | Fuzz the decoder |
| `zig build conformance` | Every case in `.spec/conformance/manifest.json` |
| `zig build examples` | The three canonical examples |

## Performance

| Benchmark | Reference | This port | Ratio |
|---|---|---|---|
| Encode 100k points | Rust `polyline` | — | — |
| Decode 100k points | Rust `polyline` | — | — |

Recorded before v0.1.0.

## License

MIT OR Apache-2.0
