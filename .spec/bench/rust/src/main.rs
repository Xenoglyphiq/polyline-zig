//! Reference timings for the polyline spec: the Rust `polyline` crate on
//! bench/route_100k.polyline. Method (shared by every port, see bench/README.md):
//! precision 5; decode once untimed to get the points; 3 warm-up runs, then 15
//! timed runs each of encode(points) and decode(text); report the median and min.
//!
//! Run from the repo root:  cargo run --release --manifest-path bench/rust/Cargo.toml

use std::time::Instant;

const WARMUP: usize = 3;
const RUNS: usize = 15;

fn time<T>(mut f: impl FnMut() -> T) -> (f64, f64) {
    for _ in 0..WARMUP {
        std::hint::black_box(f());
    }
    let mut ms: Vec<f64> = (0..RUNS)
        .map(|_| {
            let start = Instant::now();
            std::hint::black_box(f());
            start.elapsed().as_secs_f64() * 1e3
        })
        .collect();
    ms.sort_by(f64::total_cmp);
    (ms[RUNS / 2], ms[0])
}

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| "bench/route_100k.polyline".into());
    let raw = std::fs::read_to_string(&path).expect("read benchmark input");
    let text = raw.trim_end_matches('\n');

    let points = polyline::decode_polyline(text, 5).expect("decode");
    let again = polyline::encode_coordinates(points.0.iter().copied(), 5).expect("encode");
    assert_eq!(again, text, "round trip must reproduce the input");

    let (dec_med, dec_min) = time(|| polyline::decode_polyline(text, 5).unwrap());
    let (enc_med, enc_min) = time(|| polyline::encode_coordinates(points.0.iter().copied(), 5).unwrap());
    println!(
        "rust polyline 0.11.0 ({} points): encode median {enc_med:.3} ms (min {enc_min:.3}), decode median {dec_med:.3} ms (min {dec_min:.3})",
        points.0.len()
    );
}
