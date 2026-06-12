#!/usr/bin/env node
import { createRequire } from 'node:module';
import { mkdtempSync, rmSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFileSync } from 'node:child_process';
import { performance } from 'node:perf_hooks';

const DEFAULT_ITERATIONS = 50_000;
const DEFAULT_SAMPLES = 5;
const DEFAULT_WARMUP_SAMPLES = 1;
const REPO_ROOT = resolve(import.meta.dirname, '..');
const CORPUS_PATH = join(REPO_ROOT, 'benches', 'semver_corpus.json');

const corpus = JSON.parse(await readFile(CORPUS_PATH, 'utf8'));
const iterations = envPositiveInteger('RPM_SEMVER_BENCH_ITERATIONS', DEFAULT_ITERATIONS);
const samples = envPositiveInteger('RPM_SEMVER_BENCH_SAMPLES', DEFAULT_SAMPLES);
const warmupSamples = envPositiveInteger(
  'RPM_SEMVER_BENCH_WARMUP_SAMPLES',
  DEFAULT_WARMUP_SAMPLES,
);
const moduleDir = process.env.NODE_SEMVER_MODULE_DIR
  ? resolve(process.env.NODE_SEMVER_MODULE_DIR)
  : installNodeSemver(corpus.nodeSemverVersion);
const require = createRequire(join(moduleDir, 'benchmark-node-semver.cjs'));
const semver = require('semver');
const operations = [
  ['version_parse', benchVersionParse],
  ['valid_canonical', benchValidCanonical],
  ['invalid_version', benchInvalidVersion],
  ['range_parse', benchRangeParse],
  ['invalid_range', benchInvalidRange],
  ['satisfies', benchSatisfies],
  ['max_satisfying', benchMaxSatisfying],
  ['min_satisfying', benchMinSatisfying],
];

for (const [, operation] of operations) {
  for (let sample = 0; sample < warmupSamples; sample += 1) {
    run(operation);
  }
}

console.log('semver benchmark suite=representative');
console.log('metadata,key,value');
console.log('metadata,implementation,node-semver');
console.log(`metadata,node_version,${process.version}`);
console.log(`metadata,npm_version,${npmVersion()}`);
console.log(`metadata,node_semver_version,${semverVersion(semver)}`);
console.log(`metadata,platform,${process.platform}`);
console.log(`metadata,arch,${process.arch}`);
console.log(`metadata,iterations,${iterations}`);
console.log(`metadata,samples,${samples}`);
console.log(`metadata,warmup_samples,${warmupSamples}`);
console.log('metadata,outlier_policy,record_all_samples');
console.log('name,sample,total_ms,ns_per_iter');

for (const [name, operation] of operations) {
  for (let sample = 1; sample <= samples; sample += 1) {
    const elapsedMs = run(operation);
    const nsPerIter = Math.trunc((elapsedMs * 1_000_000) / iterations);
    console.log(`${name},${sample},${elapsedMs.toFixed(3)},${nsPerIter}`);
  }
}

if (!process.env.NODE_SEMVER_MODULE_DIR) {
  rmSync(moduleDir, { recursive: true, force: true });
}

function benchVersionParse() {
  for (let index = 0; index < iterations; index += 1) {
    for (const version of corpus.versions) {
      semver.parse(version);
    }
  }
}

function benchValidCanonical() {
  for (let index = 0; index < iterations; index += 1) {
    for (const version of corpus.versions) {
      semver.valid(version);
    }
  }
}

function benchInvalidVersion() {
  for (let index = 0; index < iterations; index += 1) {
    for (const version of corpus.invalidVersions) {
      semver.parse(version);
    }
  }
}

function benchRangeParse() {
  for (let index = 0; index < iterations; index += 1) {
    for (const range of corpus.ranges) {
      semver.validRange(range);
    }
  }
}

function benchInvalidRange() {
  for (let index = 0; index < iterations; index += 1) {
    for (const range of corpus.invalidRanges) {
      semver.validRange(range);
    }
  }
}

function benchSatisfies() {
  for (let index = 0; index < iterations; index += 1) {
    for (const testCase of corpus.satisfies) {
      semver.satisfies(testCase.version, testCase.range);
    }
  }
}

function benchMaxSatisfying() {
  for (let index = 0; index < iterations; index += 1) {
    for (const set of corpus.candidateSets) {
      semver.maxSatisfying(set.versions, set.range);
    }
  }
}

function benchMinSatisfying() {
  for (let index = 0; index < iterations; index += 1) {
    for (const set of corpus.candidateSets) {
      semver.minSatisfying(set.versions, set.range);
    }
  }
}

function run(operation) {
  const start = performance.now();
  operation();
  return performance.now() - start;
}

function installNodeSemver(version) {
  const prefix = mkdtempSync(join(tmpdir(), 'rpm-node-semver-bench-'));
  try {
    execFileSync('npm', ['install', '--silent', '--prefix', prefix, `semver@${version}`], {
      stdio: 'inherit',
    });
  } catch (error) {
    rmSync(prefix, { recursive: true, force: true });
    throw error;
  }
  return prefix;
}

function semverVersion(semverModule) {
  const moduleRequire = createRequire(require.resolve('semver'));
  return moduleRequire('semver/package.json').version || semverModule.SEMVER_SPEC_VERSION;
}

function npmVersion() {
  return execFileSync('npm', ['--version'], { encoding: 'utf8' }).trim();
}

function envPositiveInteger(name, fallback) {
  const value = Number.parseInt(process.env[name] || '', 10);
  return Number.isInteger(value) && value > 0 ? value : fallback;
}
