// Pure functions of the iOS harness: from what a CI run wrote (probe file,
// markers, driver output, host samples, ledger) to the result files of
// 05-RESULTS-FORMAT.md §2–3. No I/O here except the small readers.
import { existsSync, readFileSync } from 'node:fs';

export function readJson(file, fallback = null) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

export function readJsonLines(file) {
  if (!existsSync(file)) return [];
  return readFileSync(file, 'utf8').split('\n').filter(Boolean).flatMap((line) => {
    try {
      return [JSON.parse(line)];
    } catch {
      return [];
    }
  });
}

/** The probe file: its header line and its samples, in time order. */
export function splitProbe(lines) {
  const header = lines.find((line) => line.probe === 1) || null;
  const samples = lines.filter((line) => line.probe === undefined && typeof line.epochMs === 'number')
    .sort((a, b) => a.epochMs - b.epochMs);
  return { header, samples };
}

/** A cumulative counter (`field` of the samples) at time `at`, linearly interpolated. */
export function counterAt(samples, field, at) {
  if (!samples.length) return null;
  if (at <= samples[0].epochMs) return samples[0][field];
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1];
    const b = samples[i];
    if (at <= b.epochMs) {
      const span = b.epochMs - a.epochMs || 1;
      return a[field] + ((b[field] - a[field]) * (at - a.epochMs)) / span;
    }
  }
  return samples[samples.length - 1][field];
}

export function percentile(sorted, p) {
  if (!sorted.length) return null;
  const rank = (p / 100) * (sorted.length - 1);
  const lo = Math.floor(rank);
  const hi = Math.ceil(rank);
  return sorted[lo] + (sorted[hi] - sorted[lo]) * (rank - lo);
}

export function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return percentile(sorted, 50);
}

const round = (value, digits = 2) => (value === null || value === undefined || Number.isNaN(value)
  ? null : Math.round(value * 10 ** digits) / 10 ** digits);

/** CPU seconds between two times from the probe's process counters. */
function cpuSeconds(samples, from, to, user, sys) {
  const a = (counterAt(samples, user, from) ?? 0) + (counterAt(samples, sys, from) ?? 0);
  const b = (counterAt(samples, user, to) ?? 0) + (counterAt(samples, sys, to) ?? 0);
  return (b - a) / 1000;
}

/**
 * The cost metrics of 03-MEASUREMENT.md §2.1 that the iOS probe gives
 * (§3.4): CPU (process and main thread), memory (phys_footprint), frames
 * (display-link intervals), for the scenario window [t0, end].
 */
export function probeMetrics({ samples, header }, t0, end, scenario) {
  const metrics = {};
  if (!samples.length || !t0 || !end || end <= t0) return { metrics, frames: [], nominalFrameMs: null };
  const seconds = (end - t0) / 1000;
  const cpu = cpuSeconds(samples, t0, end, 'cpuUserMs', 'cpuSysMs');
  metrics['M-CPU-1'] = round(cpu, 3);
  metrics['M-CPU-2'] = round((cpu / seconds) * 100);
  metrics['M-CPU-3'] = round(cpuSeconds(samples, t0, end, 'mainUserMs', 'mainSysMs'), 3);
  if (/^S0/.test(scenario) && end - t0 >= 70_000) {
    const idle = cpuSeconds(samples, t0 + 10_000, t0 + 70_000, 'cpuUserMs', 'cpuSysMs');
    metrics['M-CPU-5'] = round((idle / 60) * 100, 3);
  }
  const inWindow = samples.filter((s) => s.epochMs >= t0 && s.epochMs <= end);
  const memory = inWindow.map((s) => s.footprintKb / 1024);
  const tail = inWindow.filter((s) => s.epochMs >= end - 20_000).map((s) => s.footprintKb / 1024);
  if (tail.length) metrics['M-MEM-1'] = round(median(tail), 1);
  if (memory.length) metrics['M-MEM-2'] = round(Math.max(...memory), 1);

  // Each line holds the intervals of the second before it.
  const frames = samples.filter((s) => s.epochMs > t0 + 500 && s.epochMs <= end + 500)
    .flatMap((s) => s.frames || []);
  let nominalFrameMs = null;
  if (frames.length) {
    const ms = frames.map((us) => us / 1000).sort((a, b) => a - b);
    // The display's interval: the median of what the display link saw (the
    // Simulator may run below the screen's maximumFramesPerSecond).
    nominalFrameMs = percentile(ms, 50);
    metrics['M-FR-1'] = {
      p50: round(percentile(ms, 50)), p90: round(percentile(ms, 90)),
      p95: round(percentile(ms, 95)), p99: round(percentile(ms, 99)),
    };
    metrics['M-FR-2'] = round((ms.filter((v) => v > 1.5 * nominalFrameMs).length / ms.length) * 100, 3);
    metrics['M-FR-3'] = ms.filter((v) => v >= 700).length;
    metrics['M-FR-4'] = round(ms[ms.length - 1]);
  }
  return { metrics, frames, nominalFrameMs: round(nominalFrameMs, 3), maxFps: header?.maxFps ?? null };
}

/** M-ST-1 and M-ST-2 from the app's own markers (process start by sysctl). */
export function startupMetrics(markers) {
  const first = (name) => markers.find((m) => m.name === name)?.epochMs ?? null;
  const start = first('FM_PROC_START');
  const ready = first('FM_READY');
  const fully = first('FM_FULLY');
  const out = {};
  if (start && ready) out['M-ST-1'] = ready - start;
  if (start && fully) out['M-ST-2'] = fully - start;
  return out;
}

/** M-NET-1 and M-NET-2 from the gateway's ledger lines of one run. */
export function networkMetrics(ledger, seconds) {
  const sdk = ledger.filter((line) => typeof line.path === 'string' && line.path.startsWith('/api/'));
  const byRoute = {};
  const requests = {};
  let total = 0;
  for (const line of sdk) {
    const bytes = Number(line.wireBytes) || 0;
    byRoute[line.path] = (byRoute[line.path] || 0) + bytes / 1024;
    requests[line.path] = (requests[line.path] || 0) + 1;
    total += bytes / 1024;
  }
  for (const key of Object.keys(byRoute)) byRoute[key] = round(byRoute[key], 1);
  return {
    'M-NET-1': { totalKb: round(total, 1), perMinKb: round(seconds > 0 ? total / (seconds / 60) : 0, 1), byRoute },
    'M-NET-2': requests,
  };
}

/** The host sampler's line nearest to `epochMs`. */
function nearest(lines, epochMs) {
  let best = null;
  for (const line of lines) {
    if (line.gone) continue;
    if (!best || Math.abs(line.epochMs - epochMs) < Math.abs(best.epochMs - epochMs)) best = line;
  }
  return best && Math.abs(best.epochMs - epochMs) <= 1500 ? best : null;
}

/** samples.jsonl: one line per probe sample inside the run, host values beside. */
export function samplesFile(samples, host, t0, end) {
  return samples.filter((s) => s.epochMs >= t0 - 1000 && s.epochMs <= end + 6000).map((s) => {
    const h = nearest(host, s.epochMs);
    const line = {
      t: s.epochMs - t0, cpuUserMs: s.cpuUserMs, cpuSysMs: s.cpuSysMs, rssKb: s.residentKb,
      footprintKb: s.footprintKb, threads: { main: round((s.mainUserMs || 0) + (s.mainSysMs || 0), 1) },
      threadCount: s.threads,
    };
    if (h) {
      line.hostRssKb = h.rssKb;
      line.hostCpuMs = h.cpuMs;
      line.hostOtherPct = h.hostOtherPct;
    }
    return line;
  });
}

/** Whether the app process ended on its own before the standard ending. */
export function crashedBeforeEnd(host, end) {
  const gone = host.find((line) => line.gone);
  return Boolean(gone && gone.epochMs < end - 2000);
}

/** The unified log (ndjson from `log show`) as plain lines. */
export function logText(entries) {
  return entries.filter((e) => e.eventMessage !== undefined)
    .map((e) => `${e.timestamp ?? ''} ${e.subsystem ?? ''}${e.category ? ':' + e.category : ''} ${e.eventMessage}`)
    .join('\n') + '\n';
}

/** The SDK's self-reported capture time (M-SDK-4) from its debug lines. */
export function captureTimes(entries) {
  const out = [];
  for (const entry of entries) {
    const match = /wireframe capture takes ([\d.]+) ms on average/.exec(entry.eventMessage || '');
    if (match) out.push(Number(match[1]));
  }
  return out;
}

/** The session id the app logged (`FM_SESSION <id>`), if any. */
export function sessionFromMarkers(markers) {
  return markers.find((m) => m.name === 'FM_SESSION')?.detail ?? null;
}

export { round };
