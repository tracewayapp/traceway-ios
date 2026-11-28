// node record.mjs --udid <udid> --out <screen.raw.mp4> --meta <screen.json>
//
// Records the Simulator's screen with `xcrun simctl io <udid> recordVideo
// --codec=hevc` (on the runner VideoToolbox encodes 1320 x 2868 HEVC about
// twice as fast as H.264: out/encoder-check.txt) until this process gets SIGTERM or SIGINT, then stops the
// recording with SIGINT (so the file is finalized) and writes when the
// recording started on the same clock as the app's markers and the SDK's
// event timestamps (a Simulator app's clock is the runner's clock):
//   spawnEpochMs     recordVideo was started
//   startedEpochMs   it printed that the recording started (the first frame)
//   stoppedEpochMs   it was asked to stop
//   cpu[]            every 5 s: the busiest processes (pid, nice, %CPU, name)
//   renice[]         with --renice <n>: the priority of the processes that
//                    record and encode raised to n (sudo renice), so a busy
//                    runner does not starve them (the recorder then stamps a
//                    backlog of frames with one time: 716 frames in the
//                    fourth smoke run)
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith('--')) pairs.push([value.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);
const meta = { udid: args.udid, file: args.out, spawnEpochMs: Date.now(), startedEpochMs: null, lines: [] };
const child = spawn('xcrun', ['simctl', 'io', args.udid, 'recordVideo', '--codec=hevc', '--force', args.out], {
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

// simctl only asks CoreSimulator to record; the frames are captured and
// encoded in other processes (which ones is logged in cpu[]).
const RECORDING = /simctl|SimStreamProcessor|SimRenderServer|VTEncoder|VideoToolbox|MediaToolbox|SimulatorTrampoline/;
function processes() {
  const ps = spawnSync('ps', ['-A', '-o', 'pid=,ni=,%cpu=,comm='], { encoding: 'utf8', maxBuffer: 8 << 20 });
  return (ps.stdout || '').split('\n').map((line) => line.trim()).filter(Boolean).map((line) => {
    const [pid, ni, cpu, ...name] = line.split(/\s+/);
    return { pid, ni: Number(ni), cpu: Number(cpu), name: name.join(' ') };
  });
}
function sampleCpu() {
  const busiest = processes().sort((a, b) => b.cpu - a.cpu).slice(0, 8)
    .map((p) => `${p.pid} ${p.ni} ${p.cpu} ${p.name.split('/').pop()}`);
  meta.cpu = meta.cpu || [];
  meta.cpu.push({ epochMs: Date.now(), busiest });
}
const reniced = new Set();
function renice() {
  const pids = [String(child.pid), ...processes().filter((p) => RECORDING.test(p.name)).map((p) => p.pid)]
    .filter((pid) => !reniced.has(pid));
  if (!pids.length) return;
  const result = spawnSync('sudo', ['-n', 'renice', '-n', String(args.renice), '-p', ...pids], { encoding: 'utf8' });
  for (const pid of pids) reniced.add(pid);
  meta.renice = meta.renice || [];
  meta.renice.push({ epochMs: Date.now(), pids, value: Number(args.renice), status: result.status,
    output: `${result.stdout || ''}${result.stderr || ''}`.trim().slice(0, 400) });
}
if (args.renice) {
  // Encoder services start with the first frames: look again a few times.
  for (const delay of [500, 3000, 10000, 30000]) setTimeout(renice, delay);
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
