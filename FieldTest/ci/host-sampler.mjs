// node host-sampler.mjs --match <path fragment> --out <file> [--interval-ms 1000]
//                       [--top-out <file> [--top-interval-ms 10000]]
//
// The cross-check of 03-MEASUREMENT.md §3.4 from the runner's side: a
// Simulator app is a host process, so once a second `ps` gives its resident
// size and CPU time. Also the CPU every other process used (hostOtherPct).
// Keeps looking for the process until it is stopped (SIGTERM), so a
// relaunch (S7e) is followed too. With --top-out, every 10 s the ten
// processes that used the most CPU time since the last look (pid, parent,
// CPU ms, share of one core, command line): where the background load
// comes from.
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
const topOut = args['top-out'];
const topIntervalMs = Number(args['top-interval-ms'] || 10000);
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

let lastTop = null;
function top() {
  if (stopped) return;
  const epochMs = Date.now();
  const now = new Map();
  for (const row of run('ps', ['-A', '-o', 'pid=,ppid=,time=,comm=']).trim().split('\n')) {
    const [p, pp, time, ...name] = row.trim().split(/\s+/);
    if (p) now.set(p, { ppid: Number(pp), cpuMs: Math.round(seconds(time) * 1000), name: name.join(' ') });
  }
  if (lastTop) {
    const span = epochMs - lastTop.epochMs;
    const used = [...now].map(([p, v]) => ({ pid: Number(p), ppid: v.ppid, name: v.name.split('/').pop(),
      cpuMs: v.cpuMs - (lastTop.procs.get(p)?.cpuMs ?? 0) }))
      .filter((v) => v.cpuMs > 0).sort((a, b) => b.cpuMs - a.cpuMs).slice(0, 10);
    const commands = new Map(run('ps', ['-o', 'pid=,args=', '-p', used.map((v) => v.pid).join(',') || '1']).trim()
      .split('\n').map((row) => { const m = row.trim().match(/^(\d+)\s+(.*)$/); return m ? [Number(m[1]), m[2].slice(0, 200)] : null; })
      .filter(Boolean));
    const total = [...now].reduce((sum, [p, v]) => sum + Math.max(0, v.cpuMs - (lastTop.procs.get(p)?.cpuMs ?? v.cpuMs)), 0);
    appendFileSync(topOut, JSON.stringify({ epochMs, spanMs: span, totalCpuPct: Math.round((total / span) * 1000) / 10,
      top: used.map((v) => ({ ...v, pct: Math.round((v.cpuMs / span) * 1000) / 10, command: commands.get(v.pid) || '' })) }) + '\n');
  }
  lastTop = { epochMs, procs: now };
  setTimeout(top, topIntervalMs);
}
if (topOut) {
  writeFileSync(topOut, '');
  top();
}
