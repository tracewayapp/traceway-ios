// node make-artifact.mjs <dir>: a hand-made CI artifact in the shape the
// workflow writes (out/), with known numbers, for testing process.mjs
// before any CI run exists.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2];
if (!dir) {
  console.error('usage: make-artifact.mjs <dir>');
  process.exit(2);
}
const root = join(dir, 'fieldtest-ios-smoke-smoke');
const lines = (items) => items.map((item) => JSON.stringify(item)).join('\n') + '\n';
const write = (path, text) => {
  mkdirSync(join(root, path, '..'), { recursive: true });
  writeFileSync(join(root, path), text);
};

const base = 1_795_000_000_000;
const runs = [
  { runId: 'ios-S1-off-b01-0001', scenario: 'S1', variant: 'off', block: 1, orderInBlock: 0, evidence: false, warmup: false, extra: '' },
  { runId: 'ios-S1-off2-b01-0002', scenario: 'S1', variant: 'off2', block: 1, orderInBlock: 1, evidence: false, warmup: false, extra: '' },
  { runId: 'ios-S6-stream-img-ev-0003', scenario: 'S6', variant: 'stream-img', block: null, orderInBlock: 0, evidence: true, warmup: false, extra: '' },
  { runId: 'ios-S4stack-core-b00-0004', scenario: 'S4', variant: 'core', block: 0, orderInBlock: 0, evidence: false, warmup: true, extra: '-fmToolkit stack' },
];
write('plan.json', JSON.stringify({ mode: 'smoke', scenario: 'smoke', seed: 1, runs }, null, 2));
write('env.json', JSON.stringify({
  platform: 'ios', commit: 'abc1234', dirtyFiles: 0, githubRunId: '42', githubRunAttempt: '1',
  simulator: 'iPhone 17 Pro Max', simulatorRuntime: 'iOS 26.5', journeyHash: 'sha256:j', fixturesHash: 'sha256:f',
}));

runs.forEach((plan, index) => {
  const start = base + index * 1_000_000;
  const t0 = start + 1500;
  const durationMs = { S1: 75_000, S4: 60_000, S6: 300_000 }[plan.scenario];
  const end = t0 + durationMs;
  const out = `runs/${plan.runId}`;
  // The process uses 0.25 s CPU per second (25 %), 0.1 s of it on the main
  // thread; footprint 100 MB, 120 MB in the last 20 s; 60 frames a second
  // of 16,667 µs with one 800 ms frame.
  const header = { probe: 1, run: plan.runId, variant: plan.variant, scenario: plan.scenario, build: 'Fieldmart 2.1.0',
    startEpochMs: start, maxFps: 60, procStartEpochMs: start - 400 };
  const samples = [];
  for (let s = 0; s <= Math.ceil((end - start) / 1000) + 8; s++) {
    const epochMs = start + s * 1000;
    const frames = s === 0 ? [] : Array.from({ length: 60 }, () => 16667);
    if (s === 10) frames[5] = 800_000;
    samples.push({ t: s * 1000, epochMs, cpuUserMs: s * 200, cpuSysMs: s * 50, mainUserMs: s * 80, mainSysMs: s * 20,
      threads: 20, footprintKb: (epochMs >= end - 20_000 ? 120 : 100) * 1024, residentKb: 150 * 1024, frames });
  }
  write(`${out}/probe.jsonl`, lines([header, ...samples]));
  write(`${out}/markers.jsonl`, lines([
    { name: 'FM_PROC_START', epochMs: start - 400 },
    { name: 'FM_SDK_STARTED', epochMs: start, detail: '12' },
    { name: 'FM_READY', epochMs: t0 },
    { name: 'FM_SESSION', epochMs: 0, detail: plan.variant === 'stream-img' ? 'session-0003' : 'none' },
    { name: 'FM_FULLY', epochMs: t0 + 900 },
  ]));
  write(`${out}/host-samples.jsonl`, lines(samples.map((s) => ({ epochMs: s.epochMs + 30, pid: 4242, rssKb: 160_000,
    cpuMs: s.cpuUserMs + s.cpuSysMs, cpuPct: 25, hostOtherPct: 40 }))));
  write(`${out}/driver.json`, JSON.stringify({
    run: plan.runId, scenario: plan.scenario, scenarioKey: plan.scenario, variant: plan.variant, evidence: plan.evidence,
    t0EpochMs: t0, t0Source: 'FM_READY marker file', launchStartEpochMs: start - 900, launchEndEpochMs: t0 + 300,
    device: { width: 440, height: 956, scale: 3 },
    durationMs, endEpochMs: end, typeMode: 'paced', quiescence: 'wait', maxLateMs: plan.variant === 'off2' ? 1700 : 300,
    stepsLate: plan.variant === 'off2' ? 1 : 0, flags: plan.variant === 'off2' ? ['late'] : [], notes: [],
    lateLimitMs: 1500,
    // off2: an acting step 1.7 s late (late); every run: a checkpoint 2.5 s late, which does not count (iOS platform note).
    steps: [
      { i: 0, do: 'waitFor', dueEpochMs: t0, startEpochMs: t0 + 10, endEpochMs: t0 + 20, lateMs: 10 },
      { i: 1, do: 'fling', dueEpochMs: t0 + 2000, startEpochMs: t0 + 2000 + (plan.variant === 'off2' ? 1700 : 300),
        endEpochMs: t0 + 4000, lateMs: plan.variant === 'off2' ? 1700 : 300 },
      { i: 2, do: 'checkpoint', dueEpochMs: t0 + 2300, startEpochMs: t0 + 4800, endEpochMs: t0 + 5400, lateMs: 2500 },
    ],
  }));
  write(`${out}/runner.json`, JSON.stringify({ runId: plan.runId, scenario: plan.scenario, variant: plan.variant,
    evidence: plan.evidence, app: plan.variant.startsWith('off') ? 'com.tracewayapp.fieldmart.off' : 'com.tracewayapp.fieldmart',
    extra: plan.extra, xcodebuildStatus: 0, startEpochMs: start - 5000, endEpochMs: end + 9000, simulator: 'iPhone 17 Pro Max',
    runtime: 'iOS 26.5', udid: 'X' }));
  write(`${out}/checkpoints.json`, JSON.stringify([{ name: `${plan.scenario.toLowerCase()}-home`, epochMs: t0 + 5400,
    tMs: 5400, plannedTMs: 5400, scenario: plan.scenario, shows: ['Fieldmart'], hides: [], masked: [],
    ...(plan.evidence ? { screenshot: 'app/s6-home.png' } : {}) }]));
  write(`${out}/app.log.ndjson`, lines([
    { timestamp: '2026-11-28 10:00:00.000', subsystem: 'com.tracewayapp.fieldmart', category: 'fm', eventMessage: `FM_READY ${t0}` },
    { timestamp: '2026-11-28 10:00:01.000', subsystem: 'com.tracewayapp.fieldmart', category: 'app', eventMessage: 'FM log 1' },
  ]));
  // The gateway's ledger folder: <run>.jsonl, <run>.fx.jsonl, bodies/<run>/.
  const sdk = plan.variant.startsWith('off') ? [] : [
    { seq: 1, run: plan.runId, recvEpochMs: t0 + 2000, method: 'POST', path: '/api/otel/v1/logs', status: 200,
      wireBytes: 2048, decodedBytes: 9000, body: `bodies/${plan.runId}/000001.bin`, mode: 'capture' },
    { seq: 2, run: plan.runId, recvEpochMs: t0 + 12000, method: 'POST', path: '/api/recordings', status: 200,
      wireBytes: 30_720, decodedBytes: 200_000, body: `bodies/${plan.runId}/000002.bin`, mode: 'capture' },
  ];
  write(`ledger/${plan.runId}.jsonl`, lines([{ seq: 0, run: plan.runId, recvEpochMs: start - 3000, mark: 'run-start', mode: 'capture' }, ...sdk]));
  write(`ledger/${plan.runId}.fx.jsonl`, lines([{ run: plan.runId, route: '/fx/api/products', status: 200 }]));
  for (const line of sdk) write(`ledger/${line.body}`, `body ${line.seq}`);
  write(`${out}/actions.json`, JSON.stringify([{ step: 3, do: 'tap', id: 'fm-home-logo', epochMs: t0 + 4000, x: 60, y: 90 }]));
  if (plan.evidence) {
    write(`${out}/screen-recorder.json`, JSON.stringify({ spawnEpochMs: start - 2100, startedEpochMs: start - 1900, stoppedEpochMs: end + 6000 }));
    write(`${out}/screen.mp4`, 'not a real video');
    write(`${out}/app/s6-home.png`, 'png');
    write(`${out}/boxes.json`, JSON.stringify({ 's6-home': [{ text: 'Fieldmart', x: 16, y: 70, w: 90, h: 26 }] }));
    write(`${out}/process.log.ndjson`, lines([{ timestamp: 'x', eventMessage: '[Traceway] wireframe capture takes 3.42 ms on average' }]));
  }
});

write('startup/launches.jsonl', lines([
  { runId: 'ios-S0startup-off-clean-1-aaaa', variant: 'off', pass: 'clean', i: 1, launchEpochMs: base, launchReturnedEpochMs: base + 200,
    procStartEpochMs: base + 50, readyEpochMs: base + 450, fullyEpochMs: base + 1200, sdkStartMs: null, 'M-ST-1': 400, 'M-ST-2': 1150,
    launchToReadyMs: 450 },
  { runId: 'ios-S0startup-core-restored-1-bbbb', variant: 'core', pass: 'restored', i: 1, launchEpochMs: base, launchReturnedEpochMs: base + 210,
    procStartEpochMs: base + 50, readyEpochMs: base + 480, fullyEpochMs: null, sdkStartMs: 15, 'M-ST-1': 430, 'M-ST-2': null,
    launchToReadyMs: 480 },
]));
write('build/size.json', JSON.stringify({ Fieldmart: { appKb: 9000 }, FieldmartOff: { appKb: 1200 } }));
console.log(root);
