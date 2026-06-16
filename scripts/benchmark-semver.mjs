#!/usr/bin/env node
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';

const REPO_ROOT = resolve(import.meta.dirname, '..');
const HISTORY_ROOT = join(REPO_ROOT, 'benches', 'histories');
const TEMPLATE_PATH = join(REPO_ROOT, 'benches', 'template', 'BENCHMARKS.md');
const BENCHMARKS_PATH = join(REPO_ROOT, 'benches', 'BENCHMARKS.md');
const ITERATIONS = envPositiveInteger('RPM_SEMVER_BENCH_ITERATIONS', 50_000);
const SAMPLES = envPositiveInteger('RPM_SEMVER_BENCH_SAMPLES', 5);
const WARMUP_SAMPLES = envPositiveInteger('RPM_SEMVER_BENCH_WARMUP_SAMPLES', 1);

if (process.argv[2] === '--render') {
  const reportPath = process.argv[3];
  if (!reportPath) {
    throw new Error('usage: node scripts/benchmark-semver.mjs --render <benchmarks.json>');
  }
  const report = JSON.parse(await readFile(resolve(REPO_ROOT, reportPath), 'utf8'));
  await writeBenchmarkMarkdown(report);
  console.log(`benchmark summary written to ${relativePath(BENCHMARKS_PATH)}`);
  process.exit(0);
}

const env = {
  ...process.env,
  RPM_SEMVER_BENCH_ITERATIONS: ITERATIONS,
  RPM_SEMVER_BENCH_SAMPLES: SAMPLES,
  RPM_SEMVER_BENCH_WARMUP_SAMPLES: WARMUP_SAMPLES,
};
const commands = [
  {
    implementation: 'rpm-rust',
    command: ['cargo', 'bench', '--bench', 'semver', '--quiet'],
  },
  {
    implementation: 'node-semver',
    command: ['node', 'scripts/benchmark-node-semver.mjs'],
  },
];

const outputDir = await nextHistoryDir(HISTORY_ROOT, localDate());
const startedAt = new Date().toISOString();
const runs = commands.map((spec) => runBenchmark(spec, env));
const summaries = Object.fromEntries(
  runs.map((run) => [run.implementation, summarizeSamples(run.samples)]),
);
const comparisons = compareImplementations(summaries['rpm-rust'], summaries['node-semver']);
const report = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  startedAt,
  outputDir: relativePath(outputDir),
  history: {
    root: relativePath(HISTORY_ROOT),
    directory: outputDir.split('/').at(-1),
  },
  settings: {
    iterations: Number.parseInt(ITERATIONS, 10),
    samples: Number.parseInt(SAMPLES, 10),
    warmupSamples: Number.parseInt(WARMUP_SAMPLES, 10),
  },
  commands: commands.map((spec) => ({
    implementation: spec.implementation,
    command: spec.command.join(' '),
  })),
  runs,
  summaries,
  comparisons,
};
const svg = renderSvg(report);

await mkdir(outputDir, { recursive: true });
await writeFile(join(outputDir, 'benchmarks.json'), `${JSON.stringify(report, null, 2)}\n`);
await writeFile(join(outputDir, 'benchmark.svg'), svg);
await writeBenchmarkMarkdown(report);

console.log(`benchmark history written to ${relativePath(outputDir)}`);
console.log(`- ${relativePath(join(outputDir, 'benchmarks.json'))}`);
console.log(`- ${relativePath(join(outputDir, 'benchmark.svg'))}`);
console.log(`- ${relativePath(BENCHMARKS_PATH)}`);

function runBenchmark(spec, benchmarkEnv) {
  const [command, ...args] = spec.command;
  const result = spawnSync(command, args, {
    cwd: REPO_ROOT,
    env: benchmarkEnv,
    encoding: 'utf8',
  });
  if (result.status !== 0) {
    throw new Error(
      [
        `benchmark command failed: ${spec.command.join(' ')}`,
        result.stdout.trim(),
        result.stderr.trim(),
      ]
        .filter(Boolean)
        .join('\n'),
    );
  }
  const parsed = parseRunnerOutput(result.stdout);
  return {
    implementation: spec.implementation,
    command: spec.command.join(' '),
    metadata: parsed.metadata,
    samples: parsed.samples,
    rawOutput: result.stdout.trimEnd(),
  };
}

function parseRunnerOutput(output) {
  const metadata = {};
  const samples = [];
  let mode = 'header';
  for (const line of output.split(/\r?\n/)) {
    if (!line.trim()) {
      continue;
    }
    if (line === 'metadata,key,value') {
      mode = 'metadata';
      continue;
    }
    if (line === 'name,sample,total_ms,ns_per_iter') {
      mode = 'samples';
      continue;
    }
    if (mode === 'metadata' && line.startsWith('metadata,')) {
      const parts = line.split(',');
      metadata[parts[1]] = parts.slice(2).join(',');
      continue;
    }
    if (mode === 'samples') {
      const [name, sample, totalMs, nsPerIter] = line.split(',');
      samples.push({
        operation: name,
        sample: Number.parseInt(sample, 10),
        totalMs: Number.parseFloat(totalMs),
        nsPerIter: Number.parseInt(nsPerIter, 10),
      });
    }
  }
  return { metadata, samples };
}

function summarizeSamples(samples) {
  const grouped = new Map();
  for (const sample of samples) {
    const group = grouped.get(sample.operation) || [];
    group.push(sample.nsPerIter);
    grouped.set(sample.operation, group);
  }
  return Object.fromEntries(
    [...grouped.entries()].map(([operation, values]) => [
      operation,
      {
        meanNsPerIter: round(mean(values), 2),
        medianNsPerIter: round(median(values), 2),
        minNsPerIter: Math.min(...values),
        maxNsPerIter: Math.max(...values),
        stddevNsPerIter: round(stddev(values), 2),
        samples: values.length,
      },
    ]),
  );
}

function compareImplementations(rustSummary, nodeSummary) {
  const operations = Object.keys(rustSummary || {}).filter((operation) => nodeSummary?.[operation]);
  return operations.map((operation) => {
    const rust = rustSummary[operation].meanNsPerIter;
    const node = nodeSummary[operation].meanNsPerIter;
    return {
      operation,
      rpmRustMeanNsPerIter: rust,
      nodeSemverMeanNsPerIter: node,
      rustSpeedupVsNode: round(node / rust, 2),
    };
  });
}

async function nextHistoryDir(root, date) {
  await mkdir(root, { recursive: true });
  for (let index = 0; index < 1000; index += 1) {
    const candidate = join(root, `${date}-${String(index).padStart(3, '0')}`);
    if (!existsSync(candidate)) {
      return candidate;
    }
  }
  throw new Error(`could not allocate benchmark history directory for ${date}`);
}

function renderSvg(report) {
  const comparisons = report.comparisons;
  const rowHeight = 36;
  const width = 980;
  const height = 150 + comparisons.length * rowHeight;
  const labelWidth = 190;
  const chartWidth = 560;
  const maxValue = Math.max(
    ...comparisons.flatMap((comparison) => [
      comparison.rpmRustMeanNsPerIter,
      comparison.nodeSemverMeanNsPerIter,
    ]),
  );
  const rows = comparisons
    .map((comparison, index) => {
      const y = 100 + index * rowHeight;
      const rustWidth = scale(comparison.rpmRustMeanNsPerIter, maxValue, chartWidth);
      const nodeWidth = scale(comparison.nodeSemverMeanNsPerIter, maxValue, chartWidth);
      return `
  <text x="24" y="${y + 17}" class="label">${escapeXml(comparison.operation)}</text>
  <rect x="${labelWidth}" y="${y}" width="${rustWidth}" height="12" rx="2" fill="#2563eb"/>
  <rect x="${labelWidth}" y="${y + 16}" width="${nodeWidth}" height="12" rx="2" fill="#f97316"/>
  <text x="${labelWidth + chartWidth + 18}" y="${y + 11}" class="value">${comparison.rpmRustMeanNsPerIter} ns</text>
  <text x="${labelWidth + chartWidth + 18}" y="${y + 27}" class="value">${comparison.nodeSemverMeanNsPerIter} ns</text>
  <text x="${width - 112}" y="${y + 19}" class="speed">${comparison.rustSpeedupVsNode}x</text>`;
    })
    .join('\n');
  return `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="title desc">
  <title id="title">Semver benchmark comparison</title>
  <desc id="desc">Mean nanoseconds per iteration for RPM Rust and node-semver benchmark operations.</desc>
  <style>
    text { font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    .title { font-size: 22px; font-weight: 700; fill: #111827; }
    .meta { font-size: 12px; fill: #4b5563; }
    .legend { font-size: 12px; fill: #374151; }
    .label { font-size: 12px; fill: #111827; }
    .value { font-size: 11px; fill: #374151; }
    .speed { font-size: 12px; font-weight: 700; fill: #111827; text-anchor: end; }
  </style>
  <rect width="${width}" height="${height}" fill="#ffffff"/>
  <text x="24" y="34" class="title">Semver benchmark comparison</text>
  <text x="24" y="56" class="meta">${escapeXml(report.generatedAt)} · ${report.settings.iterations} iterations · ${report.settings.samples} samples</text>
  <rect x="24" y="72" width="12" height="12" fill="#2563eb"/>
  <text x="42" y="82" class="legend">RPM Rust</text>
  <rect x="126" y="72" width="12" height="12" fill="#f97316"/>
  <text x="144" y="82" class="legend">node-semver</text>
  <text x="${width - 24}" y="82" class="legend" text-anchor="end">Rust speedup</text>
${rows}
</svg>
`;
}

async function writeBenchmarkMarkdown(report) {
  const template = await readFile(TEMPLATE_PATH, 'utf8');
  const rustMetadata = report.runs.find((run) => run.implementation === 'rpm-rust')?.metadata || {};
  const nodeMetadata =
    report.runs.find((run) => run.implementation === 'node-semver')?.metadata || {};
  const command = commandForReport(report);
  const status = statusForReport(report);
  const historyDirectory = report.outputDir;
  const values = {
    benchmark_data: `${historyDirectory}/benchmarks.json`,
    benchmark_chart: `${historyDirectory}/benchmark.svg`,
    history_directory: historyDirectory,
    generated_at: report.generatedAt,
    status_yaml: yamlQuote(status),
    status,
    date: report.generatedAt.slice(0, 10),
    command,
    host: `${nodeMetadata.platform || rustMetadata.target_os || 'unknown'} ${
      nodeMetadata.arch || rustMetadata.target_arch || 'unknown'
    }`,
    rust: rustMetadata.rustc_version || 'unknown',
    node: nodeMetadata.node_version || 'unknown',
    npm: nodeMetadata.npm_version || 'unknown',
    node_semver: nodeMetadata.node_semver_version || 'unknown',
    iterations: report.settings.iterations,
    samples: report.settings.samples,
    warmup_samples: report.settings.warmupSamples,
    outlier_policy:
      rustMetadata.outlier_policy || nodeMetadata.outlier_policy || 'record_all_samples',
    summary_rows: renderSummaryRows(report.comparisons),
    notes: notesForReport(report),
  };
  await writeFile(BENCHMARKS_PATH, replaceTemplate(template, values));
}

function commandForReport(report) {
  const baseCommand = 'node scripts/benchmark-semver.mjs';
  if (
    report.settings.iterations === 50_000 &&
    report.settings.samples === 5 &&
    report.settings.warmupSamples === 1
  ) {
    return baseCommand;
  }
  return [
    `RPM_SEMVER_BENCH_ITERATIONS=${report.settings.iterations}`,
    `RPM_SEMVER_BENCH_SAMPLES=${report.settings.samples}`,
    `RPM_SEMVER_BENCH_WARMUP_SAMPLES=${report.settings.warmupSamples}`,
    baseCommand,
  ].join(' ');
}

function statusForReport(report) {
  if (
    report.settings.iterations === 50_000 &&
    report.settings.samples === 5 &&
    report.settings.warmupSamples === 1
  ) {
    return 'Representative suite';
  }
  return 'Quick validation checkpoint, not representative benchmark numbers';
}

function renderSummaryRows(comparisons) {
  return comparisons
    .map(
      (comparison) =>
        `| ${comparison.operation} | ${formatNumber(comparison.rpmRustMeanNsPerIter)} | ${formatNumber(
          comparison.nodeSemverMeanNsPerIter,
        )} | ${comparison.rustSpeedupVsNode.toFixed(2)}x |`,
    )
    .join('\n');
}

function notesForReport(report) {
  if (
    report.settings.iterations === 50_000 &&
    report.settings.samples === 5 &&
    report.settings.warmupSamples === 1
  ) {
    return '- Generated from tracked benchmark history.';
  }
  return [
    '- Generated from tracked benchmark history.',
    '- This run uses reduced settings for validation and should not be treated as representative performance data.',
  ].join('\n');
}

function replaceTemplate(template, values) {
  const rendered = template.replace(/\{\{([a-z_]+)\}\}/g, (match, key) => {
    if (!Object.hasOwn(values, key)) {
      throw new Error(`unknown benchmark template placeholder: ${key}`);
    }
    return String(values[key]);
  });
  return `${rendered.trimEnd()}\n`;
}

function formatNumber(value) {
  return Number(value).toLocaleString('en-US', { maximumFractionDigits: 2 });
}

function yamlQuote(value) {
  return JSON.stringify(value);
}

function localDate() {
  if (process.env.RPM_SEMVER_BENCH_HISTORY_DATE) {
    return process.env.RPM_SEMVER_BENCH_HISTORY_DATE;
  }
  const now = new Date();
  return [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
  ].join('-');
}

function relativePath(path) {
  return path.startsWith(REPO_ROOT) ? path.slice(REPO_ROOT.length + 1) : path;
}

function scale(value, maxValue, chartWidth) {
  if (maxValue <= 0) {
    return 0;
  }
  return Math.max(1, Math.round((value / maxValue) * chartWidth));
}

function mean(values) {
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function median(values) {
  const sorted = [...values].sort((left, right) => left - right);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle];
}

function stddev(values) {
  const avg = mean(values);
  return Math.sqrt(mean(values.map((value) => (value - avg) ** 2)));
}

function round(value, places) {
  const factor = 10 ** places;
  return Math.round(value * factor) / factor;
}

function escapeXml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
}

function envPositiveInteger(name, fallback) {
  const rawValue = process.env[name] || '';
  if (!/^[1-9][0-9]*$/.test(rawValue)) {
    return String(fallback);
  }
  return rawValue;
}
