#!/usr/bin/env node
// node align-video.mjs <evidence run dir> [--ffmpeg /usr/bin/ffmpeg] [--window-ms 2500]
//
// Puts screen.mp4 on the clock of the checkpoints and of the SDK's event
// timestamps (the Simulator app, the UI test runner and the runner's own
// processes share one clock). `simctl io recordVideo` only says roughly when
// it started (screen-recorder.json: startedEpochMs, when it printed so), so the video
// clock is measured: each checkpoint screenshot (taken between epochMs and
// shotEndMs) is compared with the video's frames around that moment, and
// the best match says where that instant lies in the video. The median of
// the confident matches corrects the start. Writes screen.json in the shared
// shape (startEpochMs: the corrected device-clock time of video time 0) and
// the details in video.json:
//   firstFrameEpochMs   the corrected wall-clock time of video time 0
//   recordedEpochMs     what the recorder said
//   correctionMs        firstFrameEpochMs - recordedEpochMs
//   matches[]           per checkpoint: offset, score, confident
// and, for checkpoints taken while a finger was held (screenshot "video"),
// app/<name>.png cut from the video at the checkpoint time.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const dir = argv.find((a) => !a.startsWith('--'));
const option = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : fallback;
};
const ffmpeg = option('ffmpeg', '/usr/bin/ffmpeg');
const ffprobe = option('ffprobe', ffmpeg.replace(/ffmpeg$/, 'ffprobe'));
const windowMs = Number(option('window-ms', 2500));
const fps = 20;
// Compared at a quarter of the logical size (440 × 956 points on the iPhone 17 Pro Max).
const W = 110;
const H = 239;

if (!dir || !existsSync(join(dir, 'screen.mp4'))) {
  console.error('usage: align-video.mjs <evidence run dir with screen.mp4>');
  process.exit(2);
}
const read = (name, fallback = null) => {
  try { return JSON.parse(readFileSync(join(dir, name), 'utf8')); } catch { return fallback; }
};
const screen = read('screen-recorder.json', null) || read('screen.json', {});
const checkpoints = read('checkpoints.json', []);
const recorded = screen.startedEpochMs ?? screen.spawnEpochMs;
if (!recorded) {
  console.error('screen-recorder.json has no start time');
  process.exit(1);
}
const video = join(dir, 'screen.mp4');
let startTime = 0;
let duration = null;
try {
  const info = JSON.parse(execFileSync(ffprobe, ['-v', 'error', '-show_entries', 'format=start_time,duration',
    '-of', 'json', video], { encoding: 'utf8' }));
  startTime = Number(info.format.start_time) || 0;
  duration = Number(info.format.duration) || null;
} catch { /* defaults */ }

function gray(args) {
  return execFileSync(ffmpeg, ['-nostdin', '-loglevel', 'error', ...args, '-vf',
    `${args.includes('-t') ? `fps=${fps},` : ''}scale=${W}:${H},format=gray`, '-f', 'rawvideo', '-'],
  { maxBuffer: 1 << 28 });
}

function difference(a, offsetA, b) {
  let sum = 0;
  for (let i = 0; i < W * H; i++) sum += Math.abs(a[offsetA + i] - b[i]);
  return sum / (W * H);
}

const matches = [];
for (const cp of checkpoints) {
  if (!cp.screenshot || cp.screenshot === 'video' || !existsSync(join(dir, cp.screenshot))) continue;
  const shotEpoch = cp.shotEndMs ? (cp.epochMs + cp.shotEndMs) / 2 : cp.epochMs;
  const expected = (shotEpoch - recorded) / 1000;
  const from = Math.max(0, expected - windowMs / 1000);
  let frames;
  let picture;
  try {
    picture = gray(['-i', join(dir, cp.screenshot)]);
    frames = gray(['-ss', from.toFixed(3), '-i', video, '-t', ((2 * windowMs) / 1000).toFixed(3)]);
  } catch (error) {
    matches.push({ name: cp.name, error: String(error).slice(0, 200) });
    continue;
  }
  const count = Math.floor(frames.length / (W * H));
  if (!count || picture.length < W * H) continue;
  const scores = Array.from({ length: count }, (_, k) => difference(frames, k * W * H, picture));
  let best = 0;
  scores.forEach((score, k) => { if (score < scores[best]) best = k; });
  const sorted = [...scores].sort((a, b) => a - b);
  const typical = sorted[Math.floor(sorted.length / 2)];
  // Confident: clearly better than the window's typical frame, and the
  // screen changed in the window (a still screen matches everywhere).
  const confident = typical > 0 && scores[best] < 0.5 * typical && sorted[sorted.length - 1] - sorted[0] > 4;
  const bestTime = from + best / fps;
  matches.push({
    name: cp.name, expectedVideoSec: round(expected), bestVideoSec: round(bestTime),
    offsetMs: Math.round((expected - bestTime) * 1000), score: round(scores[best]), typical: round(typical), confident,
  });
}

function round(value) {
  return Math.round(value * 1000) / 1000;
}

const confident = matches.filter((m) => m.confident).map((m) => m.offsetMs).sort((a, b) => a - b);
const correction = confident.length >= 3 ? confident[Math.floor(confident.length / 2)] : 0;
const firstFrameEpochMs = recorded + correction - Math.round(startTime * 1000);
const spread = confident.length >= 3
  ? [confident[Math.floor(confident.length / 4)], confident[Math.floor((3 * confident.length) / 4)]] : null;

// Pictures of checkpoints taken with the finger held, from the video.
for (const cp of checkpoints) {
  if (cp.screenshot !== 'video') continue;
  const at = (cp.epochMs - firstFrameEpochMs) / 1000;
  if (at < 0 || (duration && at > duration)) continue;
  mkdirSync(join(dir, 'app'), { recursive: true });
  const file = `app/${cp.name}.png`;
  try {
    execFileSync(ffmpeg, ['-nostdin', '-loglevel', 'error', '-y', '-ss', at.toFixed(3), '-i', video, '-frames:v', '1',
      '-vf', 'scale=880:-2', join(dir, file)]);
    cp.screenshot = file;
    cp.screenshotSource = 'screen.mp4 (finger held during the checkpoint)';
  } catch (error) {
    console.error(`${cp.name}: ${error}`);
  }
}
writeFileSync(join(dir, 'checkpoints.json'), JSON.stringify(checkpoints, null, 2) + '\n');

const result = {
  file: 'screen.mp4',
  firstFrameEpochMs,
  recordedEpochMs: recorded,
  correctionMs: correction,
  videoStartTimeSec: startTime,
  durationSec: duration,
  method: confident.length >= 3
    ? `median of ${confident.length} confident screenshot matches (interquartile offsets ${spread.join(' … ')} ms)`
    : 'simctl "Recording started" time (too few confident screenshot matches to correct it)',
  matches,
};
writeFileSync(join(dir, 'video.json'), JSON.stringify(result, null, 2) + '\n');
const shared = read('screen.json', {}) || {};
writeFileSync(join(dir, 'screen.json'), JSON.stringify({
  ...shared,
  file: 'screen.mp4',
  startEpochMs: firstFrameEpochMs,
  source: `xcrun simctl io recordVideo; ${result.method} (align-video.mjs)`,
}, null, 2) + '\n');
console.log(`${dir}: first frame ${firstFrameEpochMs} (correction ${correction} ms, ${confident.length}/${matches.length} confident)`);
