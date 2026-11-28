// node --test FieldTest/harness/test/process.test.mjs
//
// process.mjs on a hand-made artifact (make-artifact.mjs), without the
// shared tools (--no-forward --no-check --no-render --no-stats): the result
// files exist and the numbers are the ones the artifact was made with.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { counterAt, networkMetrics, percentile, probeMetrics, splitProbe } from '../lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const scratch = mkdtempSync(join(process.env.FM_TEST_TMP || tmpdir(), 'fm-ios-harness-'));
const artifacts = join(scratch, 'artifacts');
const results = join(scratch, 'results');
execFileSync('node', [join(here, 'make-artifact.mjs'), artifacts]);
execFileSync('node', [join(here, '..', 'process.mjs'), '--campaign', 'FT-TEST', '--artifacts', artifacts,
  '--results', results, '--no-forward', '--no-check', '--no-render', '--no-stats'], { stdio: 'pipe' });
const ios = join(results, 'ios');
const json = (path) => JSON.parse(readFileSync(join(ios, path), 'utf8'));

test('lib: interpolation and percentiles', () => {
  const samples = [{ epochMs: 0, v: 0 }, { epochMs: 1000, v: 100 }];
  assert.equal(counterAt(samples, 'v', 250), 25);
  assert.equal(counterAt(samples, 'v', -5), 0);
  assert.equal(counterAt(samples, 'v', 5000), 100);
  assert.equal(percentile([1, 2, 3, 4], 50), 2.5);
  assert.deepEqual(networkMetrics([{ path: '/api/recordings', wireBytes: 2048 }, { path: '/fx/api/x', wireBytes: 9 }], 60)['M-NET-2'],
    { '/api/recordings': 1 });
});

test('lib: probe metrics of a steady 25 % process', () => {
  const header = { probe: 1, maxFps: 60 };
  const samples = Array.from({ length: 100 }, (_, s) => ({ epochMs: s * 1000, cpuUserMs: s * 200, cpuSysMs: s * 50,
    mainUserMs: s * 80, mainSysMs: s * 20, footprintKb: 102_400, frames: [16_667, 16_667] }));
  const { metrics } = probeMetrics(splitProbe([header, ...samples]), 10_000, 80_000, 'S0');
  assert.equal(metrics['M-CPU-1'], 17.5);
  assert.equal(metrics['M-CPU-2'], 25);
  assert.equal(metrics['M-CPU-3'], 7);
  assert.equal(metrics['M-CPU-5'], 25);
  assert.equal(metrics['M-MEM-1'], 100);
  assert.equal(metrics['M-FR-2'], 0);
});

test('a measured run', () => {
  const run = json('runs/ios-S1-off-b01-0001/run.json');
  assert.equal(run.platform, 'ios');
  assert.equal(run.scenario, 'S1');
  assert.equal(run.variant, 'off');
  assert.equal(run.block, 1);
  assert.equal(run.valid, true);
  assert.deepEqual(run.flags, ['capture-mode']);
  assert.equal(run.metrics['M-CPU-1'], 18.75);
  assert.equal(run.metrics['M-CPU-2'], 25);
  assert.equal(run.metrics['M-CPU-3'], 7.5);
  assert.equal(run.metrics['M-MEM-1'], 120);
  assert.equal(run.metrics['M-MEM-2'], 120);
  assert.equal(run.metrics['M-FR-3'], 1);
  assert.equal(run.metrics['M-FR-4'], 800);
  assert.equal(run.metrics['M-FR-1'].p50, 16.67);
  assert.equal(run.metrics['M-ST-1'], 1900);
  assert.equal(run.metrics['M-NET-1'].totalKb, 0);
  assert.equal(run.build.appBuildId, 'gh-42-1');
  assert.deepEqual(run.device, { width: 440, height: 956, scale: 3 });
  assert.equal(run.journeyHash, 'sha256:j');
  for (const file of ['samples.jsonl', 'probe.json', 'checkpoints.json', 'ledger.jsonl', 'fxlog.jsonl', 'app.log', 'actions.json']) {
    assert.ok(existsSync(join(ios, 'runs/ios-S1-off-b01-0001', file)), file);
  }
  const samples = readFileSync(join(ios, 'runs/ios-S1-off-b01-0001/samples.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
  assert.equal(samples[0].t < 0, true);
  assert.equal(samples.find((s) => s.t >= 0).hostRssKb, 160_000);
  assert.match(readFileSync(join(ios, 'runs/ios-S1-off-b01-0001/app.log'), 'utf8'), /FM log 1/);
});

test('a late run is invalid and flagged', () => {
  const run = json('runs/ios-S1-off2-b01-0002/run.json');
  assert.equal(run.valid, false);
  assert.deepEqual(run.flags, ['capture-mode', 'late']);
  assert.equal(run.driver.maxLateActingMs, 1700);
});

test('a late checkpoint alone does not make a run late (iOS platform note)', () => {
  const run = json('runs/ios-S1-off-b01-0001/run.json');
  assert.equal(run.valid, true);
  assert.equal(run.driver.maxLateMs, 300);
  assert.equal(run.driver.maxLateActingMs, 300);
  assert.equal(run.driver.stepsLate, 0);
});

test('an evidence run', () => {
  const dir = 'evidence/ios-S6-stream-img-ev-0003';
  const run = json(`${dir}/run.json`);
  assert.equal(run.evidence, true);
  assert.equal(run.sessionId, 'session-0003');
  assert.equal(run.metrics['M-NET-1'].totalKb, 32);
  assert.equal(run.metrics['M-NET-2']['/api/recordings'], 1);
  assert.equal(run.metrics['M-SDK-4'].averageMs, 3.42);
  assert.ok(existsSync(join(ios, dir, 'screen.mp4')));
  assert.ok(existsSync(join(ios, dir, 'app/s6-home.png')));
  assert.ok(existsSync(join(ios, dir, 'ledger-bodies/000002.bin')));
  assert.equal(json(`${dir}/screen.json`).startEpochMs, 1_795_000_000_000 + 2_000_000 - 1900);
  assert.equal(json(`${dir}/screen.json`).file, 'screen.mp4');
  assert.deepEqual(Object.keys(json(`${dir}/boxes.json`)), ['s6-home']);
});

test('startup launches', () => {
  const clean = json('runs/ios-S0startup-off-clean-1-aaaa/run.json');
  assert.equal(clean.scenario, 'S0-startup');
  assert.equal(clean.metrics['M-ST-1'], 400);
  const restored = json('runs/ios-S0startup-core-restored-1-bbbb/run.json');
  assert.equal(restored.scenario, 'S0-startup-restored');
  assert.equal(restored.metrics['M-ST-2'], undefined);
});

test('a sweep run goes to its own platform folder, flagged warm-up', () => {
  const run = JSON.parse(readFileSync(join(results, 'ios@stack/runs/ios-S4stack-core-b00-0004/run.json'), 'utf8'));
  assert.equal(run.platform, 'ios@stack');
  assert.equal(run.scenario, 'S4');
  assert.deepEqual(run.flags, ['capture-mode', 'warmup']);
  assert.match(run.target, /-fmToolkit stack/);
  assert.equal(run.metrics['M-NET-2']['/api/recordings'], 1);
});
