#!/usr/bin/env node
// node align-video.mjs <evidence run dir> [--ffmpeg /usr/bin/ffmpeg] [--no-retime]
//
// Puts screen.mp4 on the clock of the checkpoints and of the SDK's event
// timestamps (the Simulator app, the UI test runner and the runner's own
// processes share one clock).
//
// `simctl io recordVideo` only says roughly when it started, and on a busy
// runner it falls behind: it then stamps a backlog of frames with one time,
// so the video loses seconds (13 s in the first 35 s of the sixth smoke run,
// then a steady offset). So the video clock is measured, not assumed: every
// checkpoint screenshot (taken between epochMs and shotEndMs) is compared
// with every frame of the video; a match that is clearly the only good one
// is an anchor (frame k was on screen at time r). Anchors that disagree with
// the order of the others are dropped.
//
// If one offset fits every anchor within 300 ms, screen.mp4 stays as it is.
// Otherwise the video is re-timed: between two anchors a frame keeps its own
// spacing where the recorder kept time, and the frames of a backlog are
// spread evenly between them; before the first and after the last anchor
// the recorder's spacing is kept. The recorded file is kept as
// screen.recorded.mp4. Writes screen.json in the shared shape (startEpochMs:
// the device-clock time of video time 0) and the details in video.json:
//   firstFrameEpochMs   startEpochMs
//   recordedEpochMs     when the recorder said it started
//   anchors[]           frame, recorded time, real time, used
//   matches[]           per checkpoint: best frame, score, why (not) used
//   offset              the one-offset fit: median and worst residual
//   retimed             whether screen.mp4 was re-timed
// and, for checkpoints taken while a finger was held (screenshot "video"),
// app/<name>.png cut from the video at the checkpoint time.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const dir = argv.find((a) => !a.startsWith('--'));
const option = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : fallback;
};
const ffmpeg = option('ffmpeg', '/usr/bin/ffmpeg');
const ffprobe = option('ffprobe', ffmpeg.replace(/ffmpeg$/, 'ffprobe'));
const retimeAllowed = !argv.includes('--no-retime');
// Compared at an eighth of the logical size (440 × 956 points on the iPhone 17 Pro Max).
const W = 55;
const H = 120;
const N = W * H;

if (!dir || !existsSync(join(dir, 'screen.mp4'))) {
  console.error('usage: align-video.mjs <evidence run dir with screen.mp4>');
  process.exit(2);
}
const read = (name, fallback = null) => {
  try { return JSON.parse(readFileSync(join(dir, name), 'utf8')); } catch { return fallback; }
};
const recorder = read('screen-recorder.json', null) || {};
const checkpoints = read('checkpoints.json', []);
const recorded = recorder.startedEpochMs ?? recorder.spawnEpochMs ?? read('screen.json', {})?.startEpochMs;
if (!recorded) {
  console.error('screen-recorder.json has no start time');
  process.exit(1);
}
// A re-run starts from the recorded file again.
const original = existsSync(join(dir, 'screen.recorded.mp4')) ? join(dir, 'screen.recorded.mp4') : join(dir, 'screen.mp4');

const pts = execFileSync(ffprobe, ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time',
  '-of', 'csv=p=0', original], { encoding: 'utf8', maxBuffer: 1 << 28 })
  .split('\n').map((line) => line.replace(/,/g, '').trim()).filter(Boolean).map(Number);
const frames = execFileSync(ffmpeg, ['-nostdin', '-loglevel', 'fatal', '-i', original, '-fps_mode', 'passthrough',
  '-vf', `scale=${W}:${H},format=gray`, '-f', 'rawvideo', '-'], { maxBuffer: 2 ** 31 });
const count = Math.min(pts.length, Math.floor(frames.length / N));
if (!count) {
  console.error(`${original}: no frames`);
  process.exit(1);
}

function picture(file) {
  return execFileSync(ffmpeg, ['-nostdin', '-loglevel', 'error', '-i', file, '-vf', `scale=${W}:${H},format=gray`,
    '-f', 'rawvideo', '-']);
}

const round = (value, digits = 3) => Math.round(value * 10 ** digits) / 10 ** digits;

// 1. Every screenshot against every frame.
const matches = [];
for (const cp of checkpoints) {
  if (!cp.screenshot || cp.screenshot === 'video' || !existsSync(join(dir, cp.screenshot))) continue;
  if (cp.screenshotSource === 'screen.mp4 (finger held during the checkpoint)') continue;
  const real = cp.shotEndMs ? (cp.epochMs + cp.shotEndMs) / 2 : cp.epochMs;
  let shot;
  try { shot = picture(join(dir, cp.screenshot)); } catch (error) {
    matches.push({ name: cp.name, error: String(error).slice(0, 200) });
    continue;
  }
  if (shot.length < N) continue;
  const scores = new Float64Array(count);
  let best = 0;
  for (let k = 0; k < count; k++) {
    let sum = 0;
    const offset = k * N;
    for (let i = 0; i < N; i++) sum += Math.abs(frames[offset + i] - shot[i]);
    scores[k] = sum / N;
    if (scores[k] < scores[best]) best = k;
  }
  // The only good match: no frame nearly as good more than 2.5 s of
  // recorded time away (a screen seen twice, or a still screen, is not).
  const near = scores[best] + Math.max(0.8, 0.2 * scores[best]);
  let first = best;
  let last = best;
  for (let k = 0; k < count; k++) {
    if (scores[k] <= near) { first = Math.min(first, k); last = Math.max(last, k); }
  }
  const spanSec = pts[last] - pts[first];
  const sorted = Array.from(scores).sort((a, b) => a - b);
  const typical = sorted[Math.floor(sorted.length / 2)];
  const distinct = scores[best] < 0.5 * typical;
  matches.push({
    name: cp.name, realEpochMs: Math.round(real), frame: best, recordedSec: round(pts[best]),
    offsetMs: Math.round(real - recorded - pts[best] * 1000), score: round(scores[best]), typical: round(typical),
    nearFrames: [first, last], nearSpanSec: round(spanSec),
    use: spanSec <= 2.5 && distinct ? 'anchor' : spanSec > 2.5 ? 'ambiguous (seen elsewhere)' : 'not distinct',
  });
}

// 2. Anchors in order: the longest run increasing in both time and frame.
const candidates = matches.filter((m) => m.use === 'anchor').sort((a, b) => a.realEpochMs - b.realEpochMs);
const chain = [];
{
  const length = candidates.map(() => 1);
  const previous = candidates.map(() => -1);
  for (let i = 0; i < candidates.length; i++) {
    for (let j = 0; j < i; j++) {
      if (candidates[j].frame < candidates[i].frame && candidates[j].realEpochMs < candidates[i].realEpochMs
        && length[j] + 1 > length[i]) {
        length[i] = length[j] + 1;
        previous[i] = j;
      }
    }
  }
  let end = length.indexOf(Math.max(0, ...length));
  while (end >= 0) { chain.unshift(candidates[end]); end = previous[end]; }
}
for (const m of candidates) if (!chain.includes(m)) m.use = 'out of order';
const anchors = chain.map((m) => ({ name: m.name, frame: m.frame, recordedSec: pts[m.frame], realEpochMs: m.realEpochMs }));

// 3. One offset for all?
const offsets = anchors.map((a) => a.realEpochMs - a.recordedSec * 1000).sort((a, b) => a - b);
const median = offsets.length ? offsets[Math.floor(offsets.length / 2)] : recorded;
const worst = offsets.length ? Math.max(...offsets.map((o) => Math.abs(o - median))) : 0;
let startEpochMs = Math.round(median);
let retimed = false;
let method;
if (anchors.length < 3) {
  startEpochMs = recorded;
  method = `simctl "Recording started" time (${anchors.length} anchor(s): too few to measure)`;
} else if (worst <= 300 || !retimeAllowed) {
  method = `one offset from ${anchors.length} screenshot anchors (worst residual ${Math.round(worst)} ms)`;
} else {
  // 4. Re-time: new time of every frame, as a setpts expression over the frame number.
  startEpochMs = Math.round(anchors[0].realEpochMs - anchors[0].recordedSec * 1000);
  const pieces = [];
  for (let i = 0; i + 1 < anchors.length; i++) {
    const a = anchors[i];
    const b = anchors[i + 1];
    const dr = (b.realEpochMs - a.realEpochMs) / 1000;
    const du = b.recordedSec - a.recordedSec;
    const from = (a.realEpochMs - startEpochMs) / 1000;
    const kept = du >= 0.5 * dr && du <= 2 * dr;
    const expression = kept
      ? `${from.toFixed(4)}+(PTS*TB-${a.recordedSec.toFixed(4)})*${(dr / du).toFixed(6)}`
      : `${from.toFixed(4)}+(N-${a.frame})*${(dr / (b.frame - a.frame)).toFixed(6)}`;
    pieces.push({ until: b.frame, expression, kept });
  }
  const lastAnchor = anchors[anchors.length - 1];
  let expression = `PTS*TB-${lastAnchor.recordedSec.toFixed(4)}+${((lastAnchor.realEpochMs - startEpochMs) / 1000).toFixed(4)}`;
  for (let i = pieces.length - 1; i >= 0; i--) expression = `if(lt(N,${pieces[i].until}),${pieces[i].expression},${expression})`;
  expression = `if(lt(N,${anchors[0].frame}),PTS*TB,${expression})`;
  if (original.endsWith('screen.mp4')) renameSync(original, join(dir, 'screen.recorded.mp4'));
  execFileSync(ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-i', join(dir, 'screen.recorded.mp4'),
    '-vf', `settb=1/1000,setpts='(${expression})/TB'`, '-fps_mode', 'vfr', '-c:v', 'libx264', '-preset', 'veryfast',
    '-crf', '23', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', join(dir, 'screen.mp4')]);
  retimed = true;
  const spread = pieces.filter((p) => !p.kept).length;
  method = `re-timed on ${anchors.length} screenshot anchors (one offset was off by up to ${Math.round(worst)} ms; `
    + `${spread} of ${pieces.length} stretches between anchors had a recorder backlog and were spread evenly)`;
}

// Pictures of checkpoints taken with the finger held, from the video.
let duration = null;
try {
  duration = Number(JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-show_entries', 'format=duration', '-of', 'json',
    join(dir, 'screen.mp4')], { encoding: 'utf8' })).format.duration) || null;
} catch { /* unknown */ }
for (const cp of checkpoints) {
  if (cp.screenshot !== 'video' && cp.screenshotSource !== 'screen.mp4 (finger held during the checkpoint)') continue;
  const at = (cp.epochMs - startEpochMs) / 1000;
  if (at < 0 || (duration && at > duration)) continue;
  mkdirSync(join(dir, 'app'), { recursive: true });
  const file = `app/${cp.name}.png`;
  try {
    execFileSync(ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-ss', at.toFixed(3), '-i', join(dir, 'screen.mp4'),
      '-frames:v', '1', '-vf', 'scale=880:-2', join(dir, file)]);
    cp.screenshot = file;
    cp.screenshotSource = 'screen.mp4 (finger held during the checkpoint)';
  } catch (error) {
    console.error(`${cp.name}: ${error}`);
  }
}
writeFileSync(join(dir, 'checkpoints.json'), JSON.stringify(checkpoints, null, 2) + '\n');

const result = {
  file: 'screen.mp4',
  firstFrameEpochMs: startEpochMs,
  recordedEpochMs: recorded,
  correctionMs: startEpochMs - recorded,
  frames: count,
  durationSec: duration,
  method,
  retimed,
  offset: { medianMs: Math.round(median - recorded), worstResidualMs: Math.round(worst) },
  anchors,
  matches,
};
writeFileSync(join(dir, 'video.json'), JSON.stringify(result, null, 2) + '\n');
const shared = read('screen.json', {}) || {};
writeFileSync(join(dir, 'screen.json'), JSON.stringify({
  ...shared,
  file: 'screen.mp4',
  startEpochMs,
  source: `xcrun simctl io recordVideo; ${method} (align-video.mjs)`,
}, null, 2) + '\n');
console.log(`${dir}: video time 0 = ${startEpochMs} (${method})`);
