# /// script
# requires-python = ">=3.10"
# dependencies = ["polyline==2.0.4"]
# ///
"""Generate conformance/manifest.json for the polyline spec.

Run from the repo root:  uv run conformance/generate/generate.py

Two sources of cases (see DECISIONS.md D-003):
  - "oracle": valid inputs, expected output produced by the pinned oracle (polyline==2.0.4).
  - "spec":   inputs the oracle can't handle (errors, the empty list) or gets wrong (D-002),
              expected output produced by spec_encode / spec_decode below, a direct
              transcription of spec/SPEC.md §3.

Every oracle result is also checked against the spec transcription, so a disagreement
fails generation instead of shipping a bad fixture. Output is deterministic: re-running
produces identical bytes (GENERATED_AT changes only when the case set does).
"""
from __future__ import annotations

import json
import math
from pathlib import Path

import polyline as oracle

ORACLE = {"language": "python", "package": "polyline", "version": "2.0.4", "script": "generate/generate.py"}
SPEC_VERSION = "0.1.1"
GENERATED_AT = "2026-10-05T00:00:00Z"  # bump by hand when cases change
OUT = Path(__file__).resolve().parents[1] / "manifest.json"

I64_MIN, I64_MAX = -(2**63), 2**63 - 1
U64_MASK = 2**64 - 1
DEFAULT_MAX_POINTS = 1_000_000
DEFAULT_MAX_TEXT = 16_777_216
FLOAT_TOL = 1e-12


# ---------------------------------------------------------------------------
# Spec transcription (spec/SPEC.md §3). Raises SpecError(code, offset).
# ---------------------------------------------------------------------------

class SpecError(Exception):
    def __init__(self, code: str, offset: int | None = None):
        super().__init__(code)
        self.code, self.offset = code, offset


KIND = {
    "polyline.invalid_char": "invalid_input",
    "polyline.truncated": "invalid_input",
    "polyline.overflow": "invalid_input",
    "polyline.precision_out_of_range": "invalid_input",
    "polyline.non_finite": "invalid_input",
    "polyline.too_many_points": "limit_exceeded",
    "polyline.text_too_long": "limit_exceeded",
}


def round_half_away(x: float) -> int:
    """Half away from zero, without the floor(abs(x) + 0.5) bug (D-002)."""
    a = abs(x)
    f = math.floor(a)
    if a - f >= 0.5:  # exact: subtracting the floor never rounds
        f += 1
    return -int(f) if x < 0 else int(f)


def encode_value(d: int) -> str:
    u = ((d << 1) ^ (d >> 63)) & U64_MASK
    out = []
    while u >= 0x20:
        out.append(chr((0x20 | (u & 0x1F)) + 63))
        u >>= 5
    out.append(chr(u + 63))
    return "".join(out)


def spec_encode(points: list[dict], precision: int = 5, max_points: int = DEFAULT_MAX_POINTS) -> str:
    if not 1 <= precision <= 10:
        raise SpecError("polyline.precision_out_of_range")
    if len(points) > max_points:
        raise SpecError("polyline.too_many_points")
    scale = 10.0 ** precision
    scaled = []
    for p in points:
        pair = []
        for x in (p["lat"], p["lon"]):
            if not math.isfinite(x):
                raise SpecError("polyline.non_finite")
            s = x * scale
            if not -(2.0**63) <= s < 2.0**63:
                raise SpecError("polyline.overflow")
            pair.append(round_half_away(s))
        scaled.append(pair)
    out, prev = [], [0, 0]
    for pair in scaled:
        for axis in (0, 1):
            d = pair[axis] - prev[axis]
            if not I64_MIN <= d <= I64_MAX:
                raise SpecError("polyline.overflow")
            out.append(encode_value(d))
        prev = pair
    return "".join(out)


def spec_decode(text: str, precision: int = 5, max_points: int = DEFAULT_MAX_POINTS,
                max_text_length: int = DEFAULT_MAX_TEXT) -> list[dict]:
    if not 1 <= precision <= 10:
        raise SpecError("polyline.precision_out_of_range")
    data = text.encode("utf-8")
    if len(data) > max_text_length:
        raise SpecError("polyline.text_too_long")
    scale = 10.0 ** precision
    i, axis, sums, lat_start, points = 0, 0, [0, 0], 0, []
    while i < len(data):
        start, u, shift, chunks = i, 0, 0, 0
        while True:
            if i >= len(data):
                raise SpecError("polyline.truncated", start)
            c = data[i]
            if not 63 <= c <= 126:
                raise SpecError("polyline.invalid_char", i)
            b = c - 63
            chunks += 1
            chunk = (b & 0x1F) << shift
            if chunks > 13 or chunk >> 64:
                raise SpecError("polyline.overflow", start)
            u |= chunk
            i += 1
            if b < 0x20:
                break
            shift += 5
        d = (u >> 1) ^ -(u & 1)
        total = sums[axis] + d
        if not I64_MIN <= total <= I64_MAX:
            raise SpecError("polyline.overflow", start)
        sums[axis] = total
        if axis == 0:
            lat_start, axis = start, 1
        else:
            if len(points) + 1 > max_points:
                raise SpecError("polyline.too_many_points")
            points.append({"lon": sums[1] / scale, "lat": sums[0] / scale})
            axis = 0
    if axis == 1:
        raise SpecError("polyline.truncated", lat_start)
    return points


# ---------------------------------------------------------------------------
# Case builders
# ---------------------------------------------------------------------------

def pt(lon: float, lat: float) -> dict:
    return {"lon": lon, "lat": lat}


def canon_float(x: float):
    if math.isnan(x):
        return "NaN"
    if math.isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    return x


def canon_points(points: list[dict]) -> list[dict]:
    return [{"lat": canon_float(p["lat"]), "lon": canon_float(p["lon"])} for p in points]


def options_of(precision: int, limits: dict) -> dict | None:
    opts = dict(limits)
    if precision != 5:
        opts["precision"] = precision
    return dict(sorted(opts.items())) or None


def close(a: list[dict], b: list[dict]) -> bool:
    return len(a) == len(b) and all(
        abs(x["lat"] - y["lat"]) <= FLOAT_TOL and abs(x["lon"] - y["lon"]) <= FLOAT_TOL for x, y in zip(a, b))


cases: list[dict] = []


def add(case: dict) -> None:
    case = {k: v for k, v in case.items() if v is not None}
    cases.append(case)


def oracle_encode_case(cid, desc, points, precision=5, group="encode", tags=None):
    expected = oracle.encode([(p["lat"], p["lon"]) for p in points], precision)
    mine = spec_encode(points, precision)
    assert expected == mine, f"{cid}: oracle {expected!r} != spec {mine!r}"
    add({"id": cid, "op": "encode", "level": "core", "group": group, "description": desc,
         "input": {"value": canon_points(points)}, "options": options_of(precision, {}),
         "expect": {"value": expected}, "compare": "exact", "source": "oracle", "tags": tags})


def oracle_decode_case(cid, desc, text, precision=5, group="decode", tags=None):
    expected = [pt(lon, lat) for lat, lon in oracle.decode(text, precision)]
    mine = spec_decode(text, precision)
    assert close(expected, mine), f"{cid}: oracle {expected} != spec {mine}"
    add({"id": cid, "op": "decode", "level": "core", "group": group, "description": desc,
         "input": {"value": text}, "options": options_of(precision, {}),
         "expect": {"value": canon_points(expected)}, "compare": "float_tol", "tolerance": FLOAT_TOL,
         "source": "oracle", "tags": tags})


def spec_case(cid, op, desc, value, precision=5, limits=None, group=None, tags=None):
    limits = limits or {}
    fn = spec_encode if op == "encode" else spec_decode
    try:
        result = fn(value, precision, **limits)
    except SpecError as e:
        err = {"kind": KIND[e.code], "code": e.code}
        if e.offset is not None:
            err["offset"] = e.offset
        expect, compare, tol = {"error": err}, "exact", None
    else:
        if op == "encode":
            expect, compare, tol = {"value": result}, "exact", None
        else:
            expect, compare, tol = {"value": canon_points(result)}, "float_tol", FLOAT_TOL
    add({"id": cid, "op": op, "level": "core", "group": group or op, "description": desc,
         "input": {"value": canon_points(value) if op == "encode" else value},
         "options": options_of(precision, limits), "expect": expect, "compare": compare,
         "tolerance": tol, "source": "spec", "tags": tags})


def exact_input(target: float, precision: int = 5) -> float | None:
    """An x within a few ulps of target / 10^p whose product x * 10^p is exactly target, if any."""
    scale = 10.0 ** precision
    up = down = target / scale
    for _ in range(64):
        for x in (up, down):
            if x * scale == target:
                return x
        up, down = math.nextafter(up, math.inf), math.nextafter(down, -math.inf)
    return None


def exact_tie(k: int, precision: int = 5) -> float:
    """First x at or after k + 0.5 whose scaled value is exactly a tie (most k + 0.5 aren't reachable)."""
    for j in range(k, k + 100):
        x = exact_input(j + 0.5, precision)
        if x is not None:
            return x
    raise AssertionError(f"no exact tie near k={k}")


def below_half(precision: int = 5) -> float:
    """An x with x * 10^p == 0.49999999999999994 (the largest double below 0.5)."""
    x = exact_input(math.nextafter(0.5, 0.0), precision)
    assert x is not None, "no input lands exactly below one half"
    return x


# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

GOOGLE_POINTS = [pt(-120.2, 38.5), pt(-120.95, 40.7), pt(-126.453, 43.252)]
GOOGLE_TEXT = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
NYC_ROUTE = [pt(-73.985713, 40.748441), pt(-73.978569, 40.751657), pt(-73.968285, 40.785091)]


def build() -> None:
    # encode: valid input (oracle)
    oracle_encode_case("encode.google_example", "Google's documented example", GOOGLE_POINTS, tags=["canonical"])
    oracle_encode_case("encode.single_point", "One point", [pt(-73.985713, 40.748441)])
    oracle_encode_case("encode.negatives", "Southern and western hemispheres", [pt(-58.3816, -34.6037), pt(-70.6693, -33.4489)])
    oracle_encode_case("encode.cross_equator", "Latitude changes sign", [pt(36.8219, 0.5), pt(36.8219, -0.5)])
    oracle_encode_case("encode.cross_prime_meridian", "Longitude changes sign near 0", [pt(-0.1, 51.5), pt(0.1, 51.5)])
    oracle_encode_case("encode.cross_antimeridian", "Longitude jumps from +179.9 to -179.9", [pt(179.9, -16.5), pt(-179.9, -16.5)])
    oracle_encode_case("encode.duplicate_points", "Zero deltas encode as ??", [pt(2.3522, 48.8566), pt(2.3522, 48.8566)])
    oracle_encode_case("encode.precision_1", "Coarsest precision", [pt(-122.4, 37.8), pt(-118.2, 34.1)], precision=1)
    oracle_encode_case("encode.precision_6", "OSRM / Valhalla precision", NYC_ROUTE, precision=6, tags=["canonical"])
    oracle_encode_case("encode.precision_10", "Finest precision; values exceed 32 bits (D-001)",
                       [pt(-179.9999999999, 89.9999999999), pt(179.9999999999, -89.9999999999)], precision=10)
    oracle_encode_case("encode.out_of_range", "Out-of-range coordinates still encode (A6)", [pt(200.0, 100.0), pt(-200.0, -100.0)])
    t_pos, t_neg = exact_tie(2), -exact_tie(4)
    oracle_encode_case("encode.tie_positive", "x * 10^5 is exactly 2.5: rounds to 3, not 2 (A1)", [pt(t_pos, t_pos)], tags=["rounding"])
    oracle_encode_case("encode.tie_negative", "x * 10^5 is exactly -4.5: rounds to -5, not -4 (A1)", [pt(t_neg, t_neg)], tags=["rounding"])

    # encode: spec-sourced
    spec_case("encode.empty", "encode", "Empty list encodes to empty string (oracle crashes)", [])
    nb = below_half()
    assert oracle.encode([(nb, nb)]) != spec_encode([pt(nb, nb)]), "oracle no longer differs; revisit D-002"
    spec_case("encode.near_tie_below", "encode", "x * 10^5 is the largest double below 0.5: rounds to 0 (D-002)",
              [pt(nb, nb)], tags=["rounding"])
    spec_case("encode.error.nan", "encode", "NaN latitude", [pt(1.0, math.nan)], group="encode.error")
    spec_case("encode.error.pos_inf", "encode", "+Infinity longitude", [pt(math.inf, 1.0)], group="encode.error")
    spec_case("encode.error.neg_inf", "encode", "-Infinity latitude", [pt(1.0, -math.inf)], group="encode.error")
    spec_case("encode.error.precision_0", "encode", "Precision below range", GOOGLE_POINTS, precision=0, group="encode.error")
    spec_case("encode.error.precision_11", "encode", "Precision above range", GOOGLE_POINTS, precision=11, group="encode.error")
    spec_case("encode.error.overflow_scaled", "encode", "Scaled value exceeds i64", [pt(0.0, 1e300)], group="encode.error")
    spec_case("encode.error.overflow_delta", "encode", "Each value fits i64; their delta doesn't",
              [pt(0.0, 9e8), pt(0.0, -9e8)], precision=10, group="encode.error")
    spec_case("encode.error.too_many_points", "encode", "Three points with max_points 2", GOOGLE_POINTS,
              limits={"max_points": 2}, group="encode.error")

    # decode: valid input (oracle)
    oracle_decode_case("decode.google_example", "Google's documented example", GOOGLE_TEXT, tags=["canonical"])
    oracle_decode_case("decode.single_point", "One point", spec_encode([pt(-73.985713, 40.748441)]))
    oracle_decode_case("decode.precision_6", "OSRM / Valhalla precision", spec_encode(NYC_ROUTE, 6), precision=6)
    oracle_decode_case("decode.precision_10", "Values beyond 32 bits",
                       spec_encode([pt(-179.9999999999, 89.9999999999)], 10), precision=10)
    oracle_decode_case("decode.overlong", "Extra zero chunks are accepted (A11, D-004)", "_?_?_p~iF~ps|U")
    for p, pts in ((5, GOOGLE_POINTS), (6, NYC_ROUTE)):
        oracle_decode_case(f"decode.round_trip_p{p}", f"Decodes what encode.* produced at precision {p}",
                           spec_encode(pts, p), precision=p, group="round_trip")

    # decode: spec-sourced
    spec_case("decode.empty", "decode", "Empty string decodes to empty list", "")
    e = "decode.error"
    spec_case(f"{e}.invalid_char_space", "decode", "Space is outside 63-126", "_p~iF ~ps|U", group=e)
    spec_case(f"{e}.invalid_char_62", "decode", "'>' (62) is just below the range", ">p~iF~ps|U", group=e)
    spec_case(f"{e}.invalid_char_del", "decode", "DEL (127) is just above the range", "_p~iF\x7f", group=e)
    spec_case(f"{e}.invalid_char_non_ascii", "decode", "Non-ASCII byte; offset counts UTF-8 bytes", "_p~iFé", group=e)
    spec_case(f"{e}.truncated_mid_value", "decode", "Ends inside a value", "_p~iF~ps|", group=e)
    spec_case(f"{e}.truncated_odd_count", "decode", "A latitude with no longitude", "_p~iF~ps|U_ulL", group=e)
    spec_case(f"{e}.overflow_chunks", "decode", "13th chunk sets bits beyond 64", "~" * 13 + "?", group=e)
    spec_case(f"{e}.overflow_14_chunks", "decode", "A 14th chunk, even a zero one", "_" * 13 + "?", group=e)
    big = encode_value(2**62)
    spec_case(f"{e}.overflow_sum", "decode", "Running latitude sum exceeds i64", big + "?" + big + "?", group=e)
    spec_case(f"{e}.precision_0", "decode", "Precision below range", GOOGLE_TEXT, precision=0, group=e)
    spec_case(f"{e}.precision_11", "decode", "Precision above range", GOOGLE_TEXT, precision=11, group=e)
    spec_case(f"{e}.too_many_points", "decode", "Three points with max_points 1", GOOGLE_TEXT,
              limits={"max_points": 1}, group=e)
    spec_case(f"{e}.text_too_long", "decode", "Input longer than max_text_length 4", GOOGLE_TEXT,
              limits={"max_text_length": 4}, group=e)

    # every spec-sourced error case must actually be an error
    for c in cases:
        if c["id"].split(".")[1] == "error":
            assert "error" in c["expect"], f"{c['id']} did not raise"


def main() -> None:
    build()
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)), "duplicate case ids"
    manifest = {"capability": "polyline", "spec_version": SPEC_VERSION, "oracle": ORACLE,
                "generated_at": GENERATED_AT, "cases": cases}
    OUT.write_text(json.dumps(manifest, indent=2, ensure_ascii=True) + "\n")
    by_source = {s: sum(c["source"] == s for c in cases) for s in ("oracle", "spec")}
    print(f"wrote {OUT.name}: {len(cases)} cases ({by_source['oracle']} oracle, {by_source['spec']} spec)")


if __name__ == "__main__":
    main()
