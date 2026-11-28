#!/usr/bin/env node
// node FieldTest/harness/process.mjs --campaign <id> (--gh-run <workflow run id> | --artifacts <dir>)
//      [--results <campaign results dir>] [--tools <sdk-field-test/tools>]
//      [--no-forward] [--no-align] [--no-check] [--no-render] [--no-stats] [--only <run id,…>]
//      [--measured-platform ios@smoke]  (measured runs of a smoke or trial job, kept out of ios/runs)
//
// Turns the artifacts of a `fieldtest.yml` run into results/<campaign>/ios/
// (05-RESULTS-FORMAT.md), on the lead's machine (AGENT-5 step 4):
//   1. gh run download into ~/.cache/sdk-field-test/ios/<run id>;
//   2. each run's captured requests forwarded into the local Traceway, once
//      (gateway.mjs forward --run, `--speed 1` for evidence runs so the
//      backend sees the original spacing, `--forward-measured fast|same|skip`
//      for measured runs; a `.forwarded-<run>` file records it), and the run's
//      ledger slice exported into its folder (ledger.mjs export);
//   3. run.json, samples.jsonl, probe.json, checkpoints.json, actions.json,
//      app.log, driver.log for every run; the evidence files for evidence runs.
//      Runs of a sweep (a tag in the run id: ios-S4stack-…) go to ios@<tag>/;
//   4. on evidence runs (through benchrun): align-video.mjs (the screen
//      video on the checkpoints' clock), tools/tw/check.mjs and
//      tools/replay-render/render.mjs;
//   5. tools/stats/summarize.mjs.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync, cpSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync,
} from 'node:fs';
import { homedir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fixturesHash, journeyHash } from './hashes.mjs';
import {
  captureTimes, crashedBeforeEnd, logText, networkMetrics, probeMetrics, readJson, readJsonLines, round,
  samplesFile, sessionFromMarkers, splitProbe, startupMetrics,
} from './lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const flag = (name) => argv.includes(`--${name}`);
const option = (name, fallback = null) => {
  const index = argv.indexOf(`--${name}`);
  return index >= 0 && index + 1 < argv.length ? argv[index + 1] : fallback;
};

const campaign = option('campaign');
if (!campaign) {
  console.error('usage: process.mjs --campaign <id> (--gh-run <id> | --artifacts <dir>) [options]');
  process.exit(2);
}
// sdk-field-test/ sits beside the SDK repos in the workspace.
const fieldTest = resolve(option('field-test', join(here, '..', '..', '..', 'sdk-field-test')));
const tools = resolve(option('tools', join(fieldTest, 'tools')));
const resultsRoot = resolve(option('results', join(fieldTest, 'results', campaign)));
const platformDir = join(resultsRoot, 'ios');
const only = option('only') ? new Set(option('only').split(',')) : null;
const upstream = option('upstream', 'http://127.0.0.1:18182');
const forwardMeasured = option('forward-measured', 'fast');
const measuredPlatform = option('measured-platform');
const benchrun = join(tools, 'bin', 'benchrun');
const localHashes = {
  journeyHash: journeyHash(join(here, '..', 'shared', 'journey.json')),
  fixturesHash: fixturesHash(join(here, '..', 'shared', 'fixtures.lock.json')),
};
const say = (text) => console.error(`[ios] ${text}`);

// 1. The artifacts.
let artifacts = option('artifacts');
const ghRun = option('gh-run');
if (ghRun) {
  artifacts = join(homedir(), '.cache', 'sdk-field-test', 'ios', ghRun);
  if (!existsSync(artifacts)) {
    say(`downloading workflow run ${ghRun}`);
    execFileSync('gh', ['run', 'download', ghRun, '-R', 'tracewayapp/traceway-ios', '-D', artifacts],
      { stdio: 'inherit' });
  }
}
if (!artifacts || !existsSync(artifacts)) {
  console.error(`no artifacts at ${artifacts}`);
  process.exit(2);
}
artifacts = resolve(artifacts);

/** Every artifact root: a folder with plan.json, runs/, startup/ or build/. */
function roots(dir) {
  const mark = ['plan.json', 'runs', 'startup', 'build', 'launch-check'];
  if (mark.some((name) => existsSync(join(dir, name)))) return [dir];
  return readdirSync(dir).map((name) => join(dir, name))
    .filter((path) => statSync(path).isDirectory()).flatMap(roots);
}

const sha256 = (file) => (existsSync(file) ? `sha256:${createHash('sha256').update(readFileSync(file)).digest('hex')}` : null);

function ledgerLines(file) {
  if (!existsSync(file)) return [];
  const text = readFileSync(file, 'utf8').trim();
  if (!text) return [];
  if (text.startsWith('[')) {
    try { return JSON.parse(text); } catch { /* lines below */ }
  }
  if (text.startsWith('{') && !text.includes('\n')) {
    const one = JSON.parse(text);
    if (Array.isArray(one.lines)) return one.lines;
    return [one];
  }
  return readJsonLines(file);
}

const allowedFlags = new Set(['late', 'noisy', 'crashed', 'retry', 'budget-exhausted', 'capture-mode', 'warmup', 'invalid']);

/** `ios-S4stack-off-b01-1a2b` → tag `stack` (a sweep); `ios-S6-…` → none. */
function tagOf(runId, scenario) {
  const second = runId.split('-')[1] || '';
  return scenario && second.startsWith(scenario) && second.length > scenario.length ? second.slice(scenario.length) : '';
}

/** The ledger slice of a run, forwarded (once) and exported into its folder. */
function ledgerFor(root, runId, dest, evidence) {
  const ledgerDir = join(root, 'ledger');
  if (!existsSync(join(ledgerDir, `${runId}.jsonl`))) return;
  const marker = join(ledgerDir, `.forwarded-${runId}`);
  const mode = evidence ? 'same' : forwardMeasured;
  if (!flag('no-forward') && mode !== 'skip' && !existsSync(marker)) {
    const speed = mode === 'same' ? '1' : '0';
    run('node', [join(tools, 'gateway', 'gateway.mjs'), 'forward', '--ledger', ledgerDir, '--run', runId,
      '--upstream', upstream, '--speed', speed]);
    writeFileSync(marker, JSON.stringify({ at: new Date().toISOString(), upstream, speed }) + '\n');
  }
  run('node', [join(tools, 'gateway', 'ledger.mjs'), 'export', '--ledger', ledgerDir, '--run', runId, '--to', dest,
    ...(evidence ? [] : ['--no-bodies'])]);
}

/** One run folder of 05-RESULTS-FORMAT.md §2 from a CI run folder. */
function buildRun(root, runId, planEntry, env) {
  const src = join(root, 'runs', runId);
  const driver = readJson(join(src, 'driver.json'), {});
  const runner = readJson(join(src, 'runner.json'), {});
  const evidence = Boolean(runner.evidence ?? planEntry?.evidence ?? driver.evidence);
  const scenarioKey = driver.scenario || runner.scenario || planEntry?.scenario;
  const tag = tagOf(runId, scenarioKey);
  const platform = tag ? `ios@${tag.toLowerCase()}` : !evidence && measuredPlatform ? measuredPlatform : 'ios';
  const dest = join(resultsRoot, platform, evidence ? 'evidence' : 'runs', runId);
  mkdirSync(dest, { recursive: true });
  ledgerFor(root, runId, dest, evidence);

  const probe = splitProbe(readJsonLines(join(src, 'probe.jsonl')));
  const markers = [
    ...readJsonLines(join(src, 'markers.jsonl')),
    ...readJsonLines(join(src, 'markers.container.jsonl')),
  ].filter((m, i, all) => all.findIndex((n) => n.name === m.name && n.epochMs === m.epochMs && n.detail === m.detail) === i);
  const host = readJsonLines(join(src, 'host-samples.jsonl'));
  const ledger = ledgerLines(join(dest, 'ledger.jsonl'));
  const t0 = driver.t0EpochMs ?? null;
  const end = driver.endEpochMs ?? (t0 && driver.durationMs ? t0 + driver.durationMs : null);
  const scenario = scenarioKey;

  const { metrics, frames, nominalFrameMs, maxFps } = probeMetrics(probe, t0, end, scenario || '');
  Object.assign(metrics, startupMetrics(markers));
  Object.assign(metrics, networkMetrics(ledger, t0 && end ? (end - t0) / 1000 : 0));
  const processLog = readJsonLines(join(src, 'process.log.ndjson'));
  const capture = captureTimes(processLog);
  if (capture.length) metrics['M-SDK-4'] = { averageMs: capture[capture.length - 1], reports: capture };

  const flags = new Set(['capture-mode']);
  for (const f of driver.flags || []) if (allowedFlags.has(f)) flags.add(f);
  if ((driver.stepsLate || 0) > 0) flags.add('late');
  const crashed = end ? crashedBeforeEnd(host, end) : false;
  if (crashed && !/^S7b/.test(scenario || '')) flags.add('crashed');
  if (existsSync(join(src, 'retry.json'))) flags.add('retry');
  const other = host.map((h) => h.hostOtherPct).filter((v) => typeof v === 'number');
  const otherAvg = other.length ? other.reduce((a, b) => a + b, 0) / other.length : null;
  // Not flagged `noisy`: on a Simulator runner the system's own processes
  // (SpringBoard, testmanagerd, xcodebuild) are always busy; the off/off2
  // noise floor says how much that matters. The average is kept in run.json.
  if (planEntry?.warmup) flags.add('warmup');
  const finished = Boolean(driver.steps?.length || driver.doneEpochMs);
  const valid = finished && !flags.has('late') && !flags.has('crashed');

  const run = {
    runId,
    campaign,
    platform,
    target: `ios-simulator ${runner.simulator || env.simulator || ''} ${runner.runtime || env.simulatorRuntime || ''}`.trim()
      + (tag ? ` (${runner.extra || planEntry?.extra || tag})` : ''),
    scenario,
    variant: runner.variant || driver.variant || planEntry?.variant,
    block: planEntry?.block ?? null,
    orderInBlock: planEntry?.orderInBlock ?? null,
    warmup: Boolean(planEntry?.warmup),
    evidence,
    t0EpochMs: t0,
    endEpochMs: end,
    valid,
    flags: [...flags].sort(),
    sessionId: sessionFromMarkers(markers),
    projectId: null,
    ...(driver.device?.width ? { device: driver.device } : {}),
    metrics,
    units: 'see 03-MEASUREMENT.md §2',
    build: {
      sdkCommit: env.commit || null, sdkDirty: (env.dirtyFiles || 0) > 0,
      appBuildId: env.githubRunId ? `gh-${env.githubRunId}-${env.githubRunAttempt || 1}` : null,
    },
    journeyHash: env.journeyHash || localHashes.journeyHash,
    fixturesHash: env.fixturesHash || localHashes.fixturesHash,
    driver: {
      kind: driver.driver || 'xcuitest', t0Source: driver.t0Source || null, maxLateMs: driver.maxLateMs ?? null,
      stepsLate: driver.stepsLate ?? null, typeMode: driver.typeMode || null, quiescence: driver.quiescence || null,
      launchToT0Ms: t0 && driver.launchStartEpochMs ? t0 - driver.launchStartEpochMs : null,
      xcodebuildStatus: runner.xcodebuildStatus ?? null, notes: driver.notes || [],
    },
    frames: { nominalMs: nominalFrameMs, screenMaxFps: maxFps, count: frames.length },
    hostOtherPctAvg: round(otherAvg, 1),
    extra: runner.extra || planEntry?.extra || '',
  };
  writeFileSync(join(dest, 'run.json'), JSON.stringify(run, null, 2) + '\n');
  writeFileSync(join(dest, 'samples.jsonl'),
    samplesFile(probe.samples, host, t0 || 0, end || 0).map((l) => JSON.stringify(l)).join('\n') + '\n');
  writeFileSync(join(dest, 'probe.json'), JSON.stringify({
    frames, longTasks: [], events: [], vitals: {},
    markers: markers.map((m) => ({ name: m.name, epochMs: m.epochMs, ...(m.detail ? { detail: m.detail } : {}) })),
    header: probe.header,
  }) + '\n');
  const checkpoints = readJson(join(src, 'checkpoints.json'), []);
  writeFileSync(join(dest, 'checkpoints.json'), JSON.stringify(checkpoints, null, 2) + '\n');
  writeFileSync(join(dest, 'app.log'), logText(readJsonLines(join(src, 'app.log.ndjson'))));
  for (const name of ['driver.log', 'driver.json', 'actions.json', 'xcodebuild.log', 'host-samples.jsonl', 'runner.json',
    'fxlog-counts.json', 'quiet.json', 'autopilot.log', 'autopilot-app.log']) {
    if (existsSync(join(src, name))) copyFileSync(join(src, name), join(dest, name));
  }
  if (evidence) copyEvidence(src, dest, processLog);
  return { ...run, dir: dest };
}

/** The extra files of an evidence run (05-RESULTS-FORMAT.md §7, tools/README.md). */
function copyEvidence(src, dest, processLog) {
  for (const name of ['screen.mp4', 'screen-recorder.json', 'screen-probe.json', 'boxes.json']) {
    if (existsSync(join(src, name))) copyFileSync(join(src, name), join(dest, name));
  }
  for (const folder of ['app', 'tree']) {
    if (existsSync(join(src, folder))) cpSync(join(src, folder), join(dest, folder), { recursive: true });
  }
  if (processLog.length) writeFileSync(join(dest, 'process.log'), logText(processLog));
  // Where the screen video sits on the device clock: first the recorder's
  // own word; align-video.mjs measures it against the screenshots later.
  const recorder = readJson(join(src, 'screen-recorder.json'));
  const probe = readJson(join(src, 'screen-probe.json'));
  const stream = probe?.encoded?.streams?.[0];
  if (recorder && existsSync(join(dest, 'screen.mp4'))) {
    writeFileSync(join(dest, 'screen.json'), JSON.stringify({
      file: 'screen.mp4',
      startEpochMs: recorder.startedEpochMs ?? recorder.spawnEpochMs,
      source: recorder.startedEpochMs ? 'xcrun simctl io recordVideo: when it printed "Recording started"'
        : 'xcrun simctl io recordVideo: when it was started (approximate)',
      ...(stream ? { width: stream.width, height: stream.height } : {}),
      notes: 'Simulator app, UI test runner and recorder share the runner\'s clock.',
    }, null, 2) + '\n');
  }
}

/** One run per launch of the startup job, scenario S0-startup[-restored]. */
function buildStartup(root, env) {
  const launches = readJsonLines(join(root, 'startup', 'launches.jsonl'));
  for (const launch of launches) {
    if (only && !only.has(launch.runId)) continue;
    const dest = join(platformDir, 'runs', launch.runId);
    mkdirSync(dest, { recursive: true });
    const metrics = {};
    if (launch['M-ST-1'] !== null) metrics['M-ST-1'] = launch['M-ST-1'];
    if (launch['M-ST-2'] !== null) metrics['M-ST-2'] = launch['M-ST-2'];
    writeFileSync(join(dest, 'run.json'), JSON.stringify({
      runId: launch.runId, campaign, platform: 'ios',
      target: `ios-simulator ${env.simulator || ''} ${env.simulatorRuntime || ''}`.trim(),
      scenario: launch.pass === 'restored' ? 'S0-startup-restored' : 'S0-startup', variant: launch.variant,
      block: launch.i, orderInBlock: null, evidence: false, t0EpochMs: launch.readyEpochMs,
      endEpochMs: launch.readyEpochMs, valid: launch['M-ST-1'] !== null, flags: ['capture-mode'],
      sessionId: null, projectId: null, metrics, units: 'ms',
      startup: { launchEpochMs: launch.launchEpochMs, procStartEpochMs: launch.procStartEpochMs,
        launchToReadyMs: launch.launchToReadyMs, sdkStartMs: launch.sdkStartMs },
      build: { sdkCommit: env.commit || null, sdkDirty: (env.dirtyFiles || 0) > 0,
        appBuildId: env.githubRunId ? `gh-${env.githubRunId}-${env.githubRunAttempt || 1}` : null },
      journeyHash: env.journeyHash || null, fixturesHash: env.fixturesHash || null,
    }, null, 2) + '\n');
  }
  return launches.length;
}

function run(command, args, { tolerate = false } = {}) {
  say(`$ ${command} ${args.join(' ')}`);
  const result = spawnSync(command, args, { stdio: 'inherit' });
  if (result.status !== 0 && !tolerate) throw new Error(`${command} exited ${result.status}`);
  return result.status;
}

// 2–3. Every artifact.
mkdirSync(platformDir, { recursive: true });
const built = [];
for (const root of roots(artifacts)) {
  const name = basename(root);
  const env = readJson(join(root, 'env.json'), {});
  say(`artifact ${name} (${env.commit || 'no env.json'})`);
  const keep = join(platformDir, 'ci', ghRun || 'local', name);
  mkdirSync(keep, { recursive: true });
  for (const file of ['env.json', 'plan.json', 'sim.json', 'gateway.log', 'fixtures-check.log']) {
    if (existsSync(join(root, file))) copyFileSync(join(root, file), join(keep, file));
  }
  for (const folder of ['build', 'launch-check', 'startup']) {
    if (existsSync(join(root, folder))) cpSync(join(root, folder), join(keep, folder), { recursive: true });
  }

  const plan = readJson(join(root, 'plan.json'), { runs: [] });
  const byId = Object.fromEntries((plan.runs || []).map((r) => [r.runId, r]));
  const runsDir = join(root, 'runs');
  if (existsSync(runsDir)) {
    for (const runId of readdirSync(runsDir).sort()) {
      if (runId.endsWith('.failed-start') || (only && !only.has(runId))) continue;
      const retry = readJson(join(runsDir, runId, 'retry.json'));
      const entry = byId[runId] || (retry ? byId[retry.retryOf] : null) || null;
      const result = buildRun(root, runId, entry, env);
      built.push(result);
      say(`${runId}: ${result.valid ? 'valid' : 'INVALID'} [${result.flags.join(', ')}] CPU ${result.metrics['M-CPU-2'] ?? '?'}%`
        + ` mem ${result.metrics['M-MEM-1'] ?? '?'} MB, late max ${result.driver.maxLateMs ?? '?'} ms`);
    }
  }
  if (existsSync(join(root, 'startup'))) say(`startup launches: ${buildStartup(root, env)}`);
}
writeFileSync(join(platformDir, 'ci', `${ghRun || 'local'}.index.json`), JSON.stringify(built.map((r) => ({
  runId: r.runId, scenario: r.scenario, variant: r.variant, block: r.block, evidence: r.evidence, valid: r.valid,
  flags: r.flags,
})), null, 2) + '\n');

// 4. Checks and rendering of evidence runs (one at a time, through benchrun).
const evidenceRuns = built.filter((r) => r.evidence);
for (const result of evidenceRuns) {
  const dir = result.dir;
  if (!flag('no-align') && existsSync(join(dir, 'screen.mp4'))) {
    run(benchrun, ['--no-quiet', 'node', join(here, 'align-video.mjs'), dir], { tolerate: true });
  }
  if (!flag('no-check')) {
    run(benchrun, ['--no-quiet', 'node', join(tools, 'tw', 'check.mjs'), '--run-dir', dir, '--platform', 'ios'],
      { tolerate: true });
  }
  if (!flag('no-render')) {
    run(benchrun, ['--no-quiet', 'node', join(tools, 'replay-render', 'render.mjs'), '--run-dir', dir], { tolerate: true });
  }
}

// 5. Statistics, per platform folder that got measured runs.
if (!flag('no-stats')) {
  for (const dir of [...new Set(built.filter((r) => !r.evidence).map((r) => join(resultsRoot, r.platform)))]) {
    run('node', [join(tools, 'stats', 'summarize.mjs'), '--platform-dir', dir], { tolerate: true });
  }
}
say(`done: ${built.length} runs (${evidenceRuns.length} evidence) into ${platformDir}`);
