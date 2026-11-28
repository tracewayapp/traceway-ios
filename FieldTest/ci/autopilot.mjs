// node autopilot.mjs --udid <udid> --app <bundle id> --run <run id> --scenario S6
//                    --variant stream-img --out <run dir> --journey <journey.json> [--extra "…"]
//
// The one evidence run without XCUITest (AGENT-5 step 5, H-I3): the app is
// launched with -fmAutopilot 1 through `simctl launch` and plays the journey
// itself; accessibility stays off. This script watches the marker file the
// app writes (-fmMarkers), takes a Simulator screenshot at every FM_CP
// checkpoint, and at FM_DONE ends the run the standard way: the app goes to
// the background (another app comes to the front), 5 s, terminate.
// Writes checkpoints.json and driver.json in the shape the driver uses.
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith('--')) pairs.push([value.slice(2), all[index + 1] ?? '']);
    return pairs;
  }, []),
);
const { udid, app, run, scenario = 'S6', variant = 'stream-img', out, journey: journeyPath } = args;
const extra = (args.extra || '').split(' ').filter(Boolean);
mkdirSync(join(out, 'app'), { recursive: true });
const markersFile = join(out, 'markers.jsonl');
const log = [];
const note = (text) => { const line = `${Date.now()} ${text}`; log.push(line); console.error(line); };

const journey = JSON.parse(readFileSync(journeyPath, 'utf8'));
const key = journey.scenarios[scenario] ? scenario
  : Object.keys(journey.scenarios).find((k) => k.startsWith(`${scenario}-`));
const steps = journey.scenarios[key].steps;
const durationMs = journey.scenarios[key].durationMs;
const byName = Object.fromEntries(steps.filter((s) => s.do === 'checkpoint').map((s) => [s.name, s]));

const simctl = (...argv) => execFileSync('xcrun', ['simctl', ...argv], { encoding: 'utf8' });
const launchArgs = ['-fmRun', run, '-fmVariant', variant, '-fmScenario', scenario, '-fmEvidence', '1',
  '-fmAutopilot', '1', '-fmMarkers', markersFile, '-fmCampaign', args.campaign || 'manual', ...extra];
if (args.target) launchArgs.push('-fmTarget', args.target);
const launchStartMs = Date.now();
note(`launch ${app} ${launchArgs.join(' ')}`);
simctl('launch', '--terminate-running-process', udid, app, ...launchArgs);
const launchEndMs = Date.now();

const seen = new Set();
const checkpoints = [];
let t0 = null;
let done = null;
const deadline = Date.now() + durationMs + 90_000;
while (!done && Date.now() < deadline) {
  const lines = existsSync(markersFile) ? readFileSync(markersFile, 'utf8').split('\n').filter(Boolean) : [];
  for (const line of lines) {
    if (seen.has(line)) continue;
    seen.add(line);
    let marker;
    try { marker = JSON.parse(line); } catch { continue; }
    if (marker.name === 'FM_READY' && t0 === null) { t0 = marker.epochMs; note(`T0 ${t0}`); }
    if (marker.name === 'FM_DONE') { done = marker.epochMs; note('FM_DONE'); }
    if (marker.name === 'FM_CP' && marker.detail && !marker.detail.startsWith('mark:')) {
      const name = marker.detail;
      const shotStart = Date.now();
      const file = `app/${name}.png`;
      try { simctl('io', udid, 'screenshot', join(out, file)); } catch (error) { note(`screenshot ${name}: ${error}`); }
      const step = byName[name] || {};
      checkpoints.push({
        name, epochMs: marker.epochMs, tMs: t0 === null ? null : marker.epochMs - t0, scenario,
        shows: step.shows || [], hides: step.hides || [], masked: step.masked || [],
        ...(step.overlay ? { overlay: step.overlay } : {}), ...(step.list ? { list: step.list } : {}),
        ...(step.screen ? { screen: step.screen } : {}), screenshot: file,
        shotStartMs: shotStart, shotEndMs: Date.now(), source: 'autopilot FM_CP + simctl io screenshot',
      });
      note(`checkpoint ${name} (screenshot ${Date.now() - marker.epochMs} ms after the marker)`);
    }
  }
  execFileSync('sleep', ['0.1']);
}
if (!done) note('no FM_DONE before the deadline');

// The standard ending: to the background (another app in front), 5 s, terminate.
const endStart = Date.now();
try { simctl('launch', udid, 'com.apple.Preferences'); } catch (error) { note(`background: ${error}`); }
execFileSync('sleep', ['5']);
try { simctl('terminate', udid, app); } catch (error) { note(`terminate: ${error}`); }
try { simctl('terminate', udid, 'com.apple.Preferences'); } catch {}
note(`ending took ${Date.now() - endStart} ms`);

writeFileSync(join(out, 'checkpoints.json'), JSON.stringify(checkpoints, null, 2) + '\n');
writeFileSync(join(out, 'driver.json'), JSON.stringify({
  run, scenario, scenarioKey: key, variant, app, evidence: true, driver: 'autopilot (no XCUITest)',
  device: { width: 440, height: 956, scale: 3 }, t0EpochMs: t0, t0Source: 'FM_READY marker file', launchStartEpochMs: launchStartMs, launchEndEpochMs: launchEndMs,
  durationMs, endEpochMs: t0 === null ? null : t0 + durationMs, doneEpochMs: done, flags: done ? [] : ['no-done'],
}, null, 2) + '\n');
writeFileSync(join(out, 'driver.log'), log.join('\n') + '\n');
