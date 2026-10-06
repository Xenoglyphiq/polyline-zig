# /// script
# requires-python = ">=3.10"
# dependencies = ["polyline==2.0.4"]
# ///
"""Generate bench/route_100k.polyline: a deterministic 100,000-point route at precision 5.

Run from the repo root:  uv run bench/generate.py
A seeded random walk around Manhattan, with steps of a few meters, like a dense GPS trace.
Re-running produces identical bytes.
"""
import random
from pathlib import Path

import polyline

N, SEED, PRECISION = 100_000, 20261005, 5
rng = random.Random(SEED)
lat, lon, points = 40.7484, -73.9857, []
for _ in range(N):
    lat += rng.uniform(-0.0003, 0.0003)
    lon += rng.uniform(-0.0003, 0.0003)
    points.append((round(lat, 6), round(lon, 6)))

out = Path(__file__).resolve().parent / "route_100k.polyline"
out.write_text(polyline.encode(points, PRECISION) + "\n")
print(f"wrote {out.name}: {N} points, {out.stat().st_size} bytes")
