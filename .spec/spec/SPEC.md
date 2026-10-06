# Polyline — Spec

> Capability id: `polyline` · Spec version: `0.1.1` · Status: draft
> Implements: Encoded Polyline Algorithm Format (unversioned, retrieved 2026-10-05) — https://developers.google.com/maps/documentation/utilities/polylinealgorithm
> Machine-readable contract: `capability.yaml` (this file explains it; if they disagree, fix one of them in the same PR)

## 1. Scope

Encode a list of coordinates as a compact ASCII string, and decode it back, using Google's Encoded Polyline Algorithm Format. Google Maps, OSRM, Valhalla and many routing APIs use it to send routes.

**In scope:** `encode` and `decode` at precision 1–10, with validation and limits.
**Out of scope:**
- Encoding raw integer series, such as elevation or time. Possibly a later minor version.
- HERE's "flexible polyline", which is a different format.
- Simplifying or smoothing lines, which is geometry, not encoding.

> **Coordinate order.** The API takes and returns `lonlat` values, in `(lon, lat)` order (`.kit/CONVENTIONS.md` §1). The encoded string stores **latitude first**, then longitude, for every point. Ports must convert at the boundary. This is the most likely bug in any port.

## 2. Concepts and types

No types of its own. Points are the canonical `lonlat` (`{lon: f64, lat: f64}`, WGS84 degrees).

**Precision** `p` is the number of decimal places kept, an integer from 1 to 10. Each coordinate is stored as the integer `round(x * 10^p)`. 5 is Google's default; 6 is used by OSRM and Valhalla. The string doesn't record its precision, so the decoder must be told.

## 3. Operations

### `encode` (layer: core)
- **Input:** `points: list<lonlat>`. Option `precision: u8 = 5`.
- **Output:** `string` containing only ASCII 63–126.
- **Behavior:**
  1. If `precision` is outside 1–10: `polyline.precision_out_of_range`.
  2. If `len(points) > max_points`: `polyline.too_many_points`.
  3. For each point, in order, for `lat` then `lon`:
     1. If the value is NaN or infinite: `polyline.non_finite`.
     2. `s = x * 10^p`, computed in `f64`, where `10^p` is the exact `f64` constant (exact for every allowed `p`).
     3. `n = round_half_away_from_zero(s)` (`.kit/CONVENTIONS.md` §1). If `n` is outside `[-2^63, 2^63)`: `polyline.overflow`.
  4. Deltas: the first point's values are taken as they are; each later value is `d = n[i] - n[i-1]` (lat from lat, lon from lon), in `i64`. If a subtraction overflows: `polyline.overflow`. **Round absolute values, then take deltas.** Never round the deltas, or rounding errors accumulate along the route.
  5. Write each delta, lat then lon per point, with the value encoding below.
- **Value encoding** (one `i64` `d`):
  1. `u = (d << 1) XOR (d >> 63)`, as an unsigned 64-bit value (arithmetic shift). This equals Google's "left-shift, invert if negative".
  2. While `u >= 0x20`: emit the character `(0x20 | (u & 0x1F)) + 63`, then `u = u >> 5`.
  3. Emit the character `u + 63`.
- **Errors:** checked in the order above. The first error wins. Encode errors carry no offset.
- **Limits used:** `max_points`.
- **Edge cases:**
  - `[]` encodes to `""`.
  - Coordinates outside ±90 / ±180 are **not** rejected; they encode and round-trip (A6).
  - `-0.0` encodes the same as `0.0`.

### `decode` (layer: core)
- **Input:** `text: string`, treated as bytes. Option `precision: u8 = 5`.
- **Output:** `list<lonlat>`.
- **Behavior:**
  1. If `precision` is outside 1–10: `polyline.precision_out_of_range`.
  2. If the text is longer than `max_text_length` bytes: `polyline.text_too_long`.
  3. Read values one after another until the text ends. For each value starting at byte offset `start`:
     1. Set `u = 0` and `shift = 0`, then read bytes one by one:
        - If a byte is outside 63–126: `polyline.invalid_char`, offset = that byte's index.
        - Let `b = byte - 63`.
        - Add `(b & 0x1F) << shift` to `u`. If this would set any bit at position 64 or higher: `polyline.overflow`, offset = `start`. A value has at most 13 chunks; a 14th chunk is `polyline.overflow` even if it is zero.
        - If `b < 0x20`, the value is complete. Otherwise `shift += 5` and continue.
        - If the text ends before the value is complete: `polyline.truncated`, offset = `start`.
     2. `d = (u >> 1) XOR -(u & 1)`, as `i64`. This undoes the zigzag step.
  4. Values alternate lat, lon. Each is added to a running `i64` sum for its axis. If an addition overflows: `polyline.overflow`, offset = `start` of that value.
  5. When a lon completes, emit the point `{lon: sum_lon / 10^p, lat: sum_lat / 10^p}`. Divide in `f64`; don't multiply by `10^-p`, which differs in the last bit. If this would make more than `max_points` points: `polyline.too_many_points`.
  6. If the text ends after a lat with no lon: `polyline.truncated`, offset = `start` of that lat.
- **Errors:** checked in the order above. The first error wins.
- **Limits used:** `max_points`, `max_text_length`.
- **Edge cases:**
  - `""` decodes to `[]`.
  - Overlong encodings, meaning extra zero chunks such as `_?` for 0, are **accepted** (A11). Encode never produces them.
  - `\` (92) is a valid character. Strings copied from JavaScript source often contain `\\` escapes, and they decode to different points without any error. Ports should mention this in their docs.

## 4. Ambiguities in the external standard

| # | Question | Our answer | Matches oracle? |
|---|---|---|---|
| A1 | How are exact halves rounded? Google says only "round". | Half away from zero, the family-wide rule (`.kit/CONVENTIONS.md` §1) | yes, except D-002 |
| A2 | Are absolute values or deltas rounded? | Absolute values, then deltas (§3 encode step 4) | yes |
| A3 | Integer width | `i64` throughout. Precision 10 at ±180° is 1.8e12, which doesn't fit 32 bits. | yes (Python ints are unbounded) |
| A4 | When is a value too large? | Any scaled value, delta, running sum or decoded value outside `i64` is `polyline.overflow` | n/a: the oracle doesn't check |
| A5 | What if input ends early? | `polyline.truncated`, both mid-value and lat-without-lon | n/a: the oracle raises `IndexError` |
| A6 | Are coordinates range-checked? | No. Only non-finite input is rejected. | yes |
| A7 | How is a decoded value turned back into degrees? | `n / 10^p` in `f64` | yes |
| A8 | Which coordinate comes first? | The string stores lat first; the API uses `(lon, lat)` | yes, after swapping |
| A9 | Which characters are valid? | ASCII 63–126 only; anything else is `polyline.invalid_char` | n/a: the oracle doesn't check |
| A10 | Can fixtures override limits? | Yes. Limits are passed in a case's `options`, e.g. `{"max_points": 2}` | n/a |
| A11 | Are overlong encodings accepted? | Yes on decode; encode always writes the shortest form | yes |

## 5. Limits

| Limit | Default | Why this default |
|---|---|---|
| `max_points` | 1,000,000 | Far above any real route, but stops a hostile string from allocating without bound |
| `max_text_length` | 16,777,216 (16 MiB) | Checked before any work, so oversized input fails at once |

Ports expose limits on the same options value as `precision` (A10).

## 6. Conformance

- Oracle: Python `polyline==2.0.4`.
- Levels: `core` covers `encode` and `decode`. There is no io layer, so `full` equals `core`.
- How fixtures are generated: `conformance/generate/generate.py` produces the `source: "oracle"` cases. The oracle doesn't validate its input, so error cases, the empty list, and the near-tie rounding case (D-002) are written by hand and marked `source: "spec"`.

## 7. The three canonical examples

Every port implements exactly these, in its README and as runnable examples in CI.

1. **encode_route:** encode `(-120.2, 38.5)`, `(-120.95, 40.7)`, `(-126.453, 43.252)` and print `` _p~iF~ps|U_ulLnnqC_mqNvxq`@ ``.
2. **decode_route:** decode that string and print each point as lon and lat.
3. **precision_6:** encode a route with `precision = 6`, decode it with `precision = 6`, and confirm the points match.

## 8. Performance target

Reference: Rust `polyline` crate, version pinned with the benchmark inputs · Input: `bench/route_100k` (100,000 points) · Target: within 2× of reference for both encode and decode.

## 9. Security notes

- Decoding is a single forward pass, with no recursion and no backtracking.
- `max_text_length` is checked before any work; `max_points` is checked before each point is stored.
- Values have at most 13 chunks, and every sum is checked, so hostile input can't cause silent wraparound.
- Ports must not let a language's own overflow trap or panic escape as a crash. Overflow is always reported as `polyline.overflow`.
