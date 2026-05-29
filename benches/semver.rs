use std::{
    hint::black_box,
    time::{Duration, Instant},
};

use rpm::core::semver;

const ITERATIONS: usize = 50_000;

fn main() {
    let benchmarks = [
        run("parse", ITERATIONS, bench_parse),
        run("compare", ITERATIONS, bench_compare),
        run("satisfies", ITERATIONS, bench_satisfies),
        run("max_satisfying", ITERATIONS, bench_max_satisfying),
    ];

    println!("semver benchmark iterations={ITERATIONS}");
    println!("name,total_ms,ns_per_iter");
    for result in benchmarks {
        println!(
            "{},{:.3},{}",
            result.name,
            result.elapsed.as_secs_f64() * 1000.0,
            result.elapsed.as_nanos() / result.iterations as u128
        );
    }
}

struct BenchmarkResult {
    name: &'static str,
    iterations: usize,
    elapsed: Duration,
}

fn run(name: &'static str, iterations: usize, mut benchmark: impl FnMut()) -> BenchmarkResult {
    let start = Instant::now();
    for _ in 0..iterations {
        benchmark();
    }
    BenchmarkResult {
        name,
        iterations,
        elapsed: start.elapsed(),
    }
}

fn bench_parse() {
    for version in ["1.2.3", "2.0.0-alpha.1+build.5", "0.0.1-beta", "10.20.30"] {
        black_box(semver::valid(black_box(version)));
    }
}

fn bench_compare() {
    for (left, right) in [
        ("1.2.3", "1.2.4"),
        ("2.0.0-alpha.1", "2.0.0-alpha.2"),
        ("1.2.3+build.1", "1.2.3+build.2"),
        ("0.9.9", "1.0.0"),
    ] {
        let _ = black_box(semver::compare(black_box(left), black_box(right)));
    }
}

fn bench_satisfies() {
    for (version, range) in [
        ("1.8.1", "^1.2.3"),
        ("0.2.5", "^0.2.0"),
        ("1.2.9", "~1.2.3"),
        ("1.5.0", ">=1.0.0 <2.0.0"),
        ("2.0.0", "1.0.0 - 2.0.0"),
    ] {
        let _ = black_box(semver::satisfies(black_box(version), black_box(range)));
    }
}

fn bench_max_satisfying() {
    let versions = [
        "0.1.0",
        "0.2.0",
        "0.2.5",
        "1.0.0",
        "1.2.3",
        "1.2.4",
        "1.3.0",
        "1.8.1",
        "2.0.0-alpha.1",
        "2.0.0",
    ];

    for range in ["^1.2.3", "~1.2.3", ">=1.0.0 <2.0.0", "1.x"] {
        let _ = black_box(semver::max_satisfying(
            black_box(versions.iter().copied()),
            black_box(range),
        ));
    }
}
