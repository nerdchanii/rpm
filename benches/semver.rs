use std::{
    env,
    hint::black_box,
    process::Command,
    str::FromStr,
    time::{Duration, Instant},
};

use rpm::core::resolver::semver::{self, Range, Version};
use serde::Deserialize;

const DEFAULT_ITERATIONS: usize = 50_000;
const DEFAULT_SAMPLES: usize = 5;
const DEFAULT_WARMUP_SAMPLES: usize = 1;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let corpus = serde_json::from_str::<Corpus>(include_str!("semver_corpus.json"))?;
    let iterations = env_usize("RPM_SEMVER_BENCH_ITERATIONS", DEFAULT_ITERATIONS);
    let samples = env_usize("RPM_SEMVER_BENCH_SAMPLES", DEFAULT_SAMPLES);
    let warmup_samples = env_usize("RPM_SEMVER_BENCH_WARMUP_SAMPLES", DEFAULT_WARMUP_SAMPLES);
    let benchmark = Benchmark::new(&corpus, iterations);
    let operations = [
        Operation::VersionParse,
        Operation::ValidCanonical,
        Operation::InvalidVersion,
        Operation::RangeParse,
        Operation::InvalidRange,
        Operation::Satisfies,
        Operation::MaxSatisfying,
        Operation::MinSatisfying,
    ];

    for operation in operations {
        for _ in 0..warmup_samples {
            run(iterations, || operation.run(&benchmark));
        }
    }

    println!("semver benchmark suite=representative");
    println!("metadata,key,value");
    println!("metadata,implementation,rpm-rust");
    println!("metadata,crate_version,{}", env!("CARGO_PKG_VERSION"));
    println!("metadata,rustc_version,{}", command_version("rustc"));
    println!("metadata,target_os,{}", env::consts::OS);
    println!("metadata,target_arch,{}", env::consts::ARCH);
    println!("metadata,iterations,{iterations}");
    println!("metadata,samples,{samples}");
    println!("metadata,warmup_samples,{warmup_samples}");
    println!("metadata,outlier_policy,record_all_samples");
    println!("name,sample,total_ms,ns_per_iter");

    for operation in operations {
        for sample in 1..=samples {
            let elapsed = run(iterations, || operation.run(&benchmark));
            println!(
                "{},{sample},{:.3},{}",
                operation.name(),
                elapsed.as_secs_f64() * 1000.0,
                elapsed.as_nanos() / iterations as u128
            );
        }
    }

    Ok(())
}

#[derive(Clone, Copy)]
enum Operation {
    VersionParse,
    ValidCanonical,
    InvalidVersion,
    RangeParse,
    InvalidRange,
    Satisfies,
    MaxSatisfying,
    MinSatisfying,
}

impl Operation {
    fn name(self) -> &'static str {
        match self {
            Self::VersionParse => "version_parse",
            Self::ValidCanonical => "valid_canonical",
            Self::InvalidVersion => "invalid_version",
            Self::RangeParse => "range_parse",
            Self::InvalidRange => "invalid_range",
            Self::Satisfies => "satisfies",
            Self::MaxSatisfying => "max_satisfying",
            Self::MinSatisfying => "min_satisfying",
        }
    }

    fn run(self, benchmark: &Benchmark<'_>) {
        match self {
            Self::VersionParse => benchmark.bench_version_parse(),
            Self::ValidCanonical => benchmark.bench_valid_canonical(),
            Self::InvalidVersion => benchmark.bench_invalid_version(),
            Self::RangeParse => benchmark.bench_range_parse(),
            Self::InvalidRange => benchmark.bench_invalid_range(),
            Self::Satisfies => benchmark.bench_satisfies(),
            Self::MaxSatisfying => benchmark.bench_max_satisfying(),
            Self::MinSatisfying => benchmark.bench_min_satisfying(),
        }
    }
}

struct Benchmark<'a> {
    corpus: &'a Corpus,
    iterations: usize,
}

impl<'a> Benchmark<'a> {
    fn new(corpus: &'a Corpus, iterations: usize) -> Self {
        Self { corpus, iterations }
    }

    fn bench_version_parse(&self) {
        for _ in 0..self.iterations {
            for version in &self.corpus.versions {
                let _ = black_box(Version::from_str(black_box(version)));
            }
        }
    }

    fn bench_valid_canonical(&self) {
        for _ in 0..self.iterations {
            for version in &self.corpus.versions {
                black_box(semver::valid(black_box(version)));
            }
        }
    }

    fn bench_invalid_version(&self) {
        for _ in 0..self.iterations {
            for version in &self.corpus.invalid_versions {
                let _ = black_box(Version::from_str(black_box(version)));
            }
        }
    }

    fn bench_range_parse(&self) {
        for _ in 0..self.iterations {
            for range in &self.corpus.ranges {
                let _ = black_box(Range::from_str(black_box(range)));
            }
        }
    }

    fn bench_invalid_range(&self) {
        for _ in 0..self.iterations {
            for range in &self.corpus.invalid_ranges {
                let _ = black_box(Range::from_str(black_box(range)));
            }
        }
    }

    fn bench_satisfies(&self) {
        for _ in 0..self.iterations {
            for case in &self.corpus.satisfies {
                let _ = black_box(semver::satisfies(
                    black_box(&case.version),
                    black_box(&case.range),
                ));
            }
        }
    }

    fn bench_max_satisfying(&self) {
        for _ in 0..self.iterations {
            for set in &self.corpus.candidate_sets {
                let _ = black_box(semver::max_satisfying(
                    black_box(set.versions.iter().map(String::as_str)),
                    black_box(&set.range),
                ));
            }
        }
    }

    fn bench_min_satisfying(&self) {
        for _ in 0..self.iterations {
            for set in &self.corpus.candidate_sets {
                let _ = black_box(semver::min_satisfying(
                    black_box(set.versions.iter().map(String::as_str)),
                    black_box(&set.range),
                ));
            }
        }
    }
}

fn run(iterations: usize, mut benchmark: impl FnMut()) -> Duration {
    let start = Instant::now();
    benchmark();
    let elapsed = start.elapsed();
    black_box(iterations);
    elapsed
}

fn env_usize(name: &str, default: usize) -> usize {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(default)
}

fn command_version(command: &str) -> String {
    Command::new(command)
        .arg("--version")
        .output()
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| String::from_utf8(output.stdout).ok())
        .map(|version| version.trim().to_string())
        .filter(|version| !version.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Corpus {
    versions: Vec<String>,
    invalid_versions: Vec<String>,
    ranges: Vec<String>,
    invalid_ranges: Vec<String>,
    satisfies: Vec<SatisfiesCase>,
    candidate_sets: Vec<CandidateSet>,
}

#[derive(Deserialize)]
struct SatisfiesCase {
    version: String,
    range: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CandidateSet {
    range: String,
    versions: Vec<String>,
}
