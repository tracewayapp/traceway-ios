// node record.mjs --udid <udid> --out <screen.raw.mp4> --meta <screen.json>
//
// Records the Simulator's screen with `xcrun simctl io <udid> recordVideo
// --codec=h264` until this process gets SIGTERM or SIGINT, then stops the
// recording with SIGINT (so the file is finalized) and writes when the
// recording started on the same clock as the app's markers and the SDK's
// event timestamps (a Simulator app's clock is the runner's clock):
//   spawnEpochMs     recordVideo was started
//   startedEpochMs   it printed that the recording started (the first frame)
//   stoppedEpochMs   it was asked to stop
//   cpu[]            every 5 s: %CPU and CPU time of the recording processes
//   renice           with --renice <n>: the recording processes' priority
//                    raised to n (sudo renice), so a busy runner does not
//                    starve the recorder (it then stamps a backlog of frames
//                    with one time: 716 frames in the fourth smoke run)
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith('--')) pairs.push([value.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);
const meta = { udid: args.udid, file: args.out, spawnEpochMs: Date.now(), startedEpochMs: null, lines: [] };
const child = spawn('xcrun', ['simctl', 'io', args.udid, 'recordVideo', '--codec=h264', '--force', args.out], {
  stdio: ['ignore', 'pipe', 'pipe'],
});

function onData(chunk) {
  const now = Date.now();
  for (const line of chunk.toString().split('\n').map((l) => l.trim()).filter(Boolean)) {
    meta.lines.push({ epochMs: now, line });
    if (meta.startedEpochMs === null && /recording started/i.test(line)) meta.startedEpochMs = now;
  }
}
child.stdout.on('data', onData);
child.stderr.on('data', onData);

// The recording runs in simctl (xcrun may start it as a child).
function recorderPids() {
  const found = spawnSync('pgrep', ['-f', `simctl io ${args.udid} recordVideo`], { encoding: 'utf8' });
  const pids = (found.stdout || '').split('\n').map((l) => l.trim()).filter(Boolean);
  return [...new Set([String(child.pid), ...pids])];
}
function sampleCpu() {
  const pids = recorderPids();
  const ps = spawnSync('ps', ['-o', 'pid=,ni=,%cpu=,time=', '-p', pids.join(',')], { encoding: 'utf8' });
  meta.cpu = meta.cpu || [];
  meta.cpu.push({ epochMs: Date.now(), ps: (ps.stdout || '').trim().split('\n').map((l) => l.trim().split(/\s+/).join(' ')) });
}
if (args.renice) {
  setTimeout(() => {
    const pids = recorderPids();
    const result = spawnSync('sudo', ['-n', 'renice', '-n', String(args.renice), '-p', ...pids], { encoding: 'utf8' });
    meta.renice = { pids, value: Number(args.renice), status: result.status, output: `${result.stdout || ''}${result.stderr || ''}`.trim() };
  }, 500);
}
const cpuTimer = setInterval(sampleCpu, 5000);

function save() {
  writeFileSync(args.meta, JSON.stringify(meta, null, 2) + '\n');
}

let stopping = false;
function stop() {
  if (stopping) return;
  stopping = true;
  sampleCpu();
  clearInterval(cpuTimer);
  meta.stoppedEpochMs = Date.now();
  child.kill('SIGINT');
  setTimeout(() => { child.kill('SIGKILL'); }, 20000).unref();
}
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
child.on('exit', (code, signal) => {
  meta.exitCode = code;
  meta.exitSignal = signal;
  meta.exitEpochMs = Date.now();
  save();
  process.exit(0);
});
save();
