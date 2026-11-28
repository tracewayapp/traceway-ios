// node host-sampler.mjs --match <path fragment> --out <file> [--interval-ms 1000]
//
// The cross-check of 03-MEASUREMENT.md §3.4 from the runner's side: a
// Simulator app is a host process, so once a second `ps` gives its resident
// size and CPU time. Also the CPU every other process used (hostOtherPct).
// Keeps looking for the process until it is stopped (SIGTERM), so a
// relaunch (S7e) is followed too.
import { execFileSync } from 'node:child_process';
import { appendFileSync, writeFileSync } from 'node:fs';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith('--')) pairs.push([value.slice(2), all[index + 1]]);
    return pairs;
  }, []),
);
const match = args.match;
const out = args.out;
const intervalMs = Number(args['interval-ms'] || 1000);
if (!match || !out) {
  console.error('usage: host-sampler.mjs --match <fragment> --out <file>');
  process.exit(2);
}
writeFileSync(out, '');

function run(command, argv) {
  try {
    return execFileSync(command, argv, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch (error) {
    return error.stdout || '';
  }
}

// `ps` TIME: [[dd-]hh:]mm:ss.ss
function seconds(text) {
  let days = 0;
  let rest = text.trim();
  if (rest.includes('-')) {
    const [d, r] = rest.split('-');
    days = Number(d);
    rest = r;
  }
  return rest.split(':').reduce((total, part) => total * 60 + Number(part), 0) + days * 86400;
}

function findPid() {
  const lines = run('pgrep', ['-f', match]).trim().split('\n').filter(Boolean);
  return lines.length ? Number(lines[lines.length - 1]) : null;
}

let pid = null;
let stopped = false;
process.on('SIGTERM', () => { stopped = true; });
process.on('SIGINT', () => { stopped = true; });

function tick() {
  if (stopped) process.exit(0);
  const epochMs = Date.now();
  if (!pid) pid = findPid();
  if (pid) {
    const line = run('ps', ['-o', 'pid=,rss=,time=,%cpu=', '-p', String(pid)]).trim();
    if (!line) {
      appendFileSync(out, JSON.stringify({ epochMs, pid, gone: true }) + '\n');
      pid = null;
    } else {
      const [, rss, time, cpu] = line.split(/\s+/);
      let otherPct = null;
      const all = run('ps', ['-A', '-o', 'pid=,%cpu=']).trim().split('\n');
      otherPct = all.reduce((sum, row) => {
        const [p, c] = row.trim().split(/\s+/);
        return Number(p) === pid ? sum : sum + (Number(c) || 0);
      }, 0);
      appendFileSync(out, JSON.stringify({
        epochMs, pid, rssKb: Number(rss), cpuMs: Math.round(seconds(time) * 1000), cpuPct: Number(cpu),
        hostOtherPct: Math.round(otherPct * 10) / 10,
      }) + '\n');
    }
  }
  const next = intervalMs - (Date.now() - epochMs);
  setTimeout(tick, Math.max(50, next));
}
tick();
