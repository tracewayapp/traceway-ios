// node pick-sim.mjs <simctl list devices available -j output> [preferred name]
//
// Prints {udid, name, runtime} of the Simulator to use: the preferred name
// on the newest iOS runtime that has it, else the newest "iPhone N [Pro
// [Max]]" as simulator.yml picks it.
import { readFileSync } from 'node:fs';

const [file, preferred = 'iPhone 17 Pro Max'] = process.argv.slice(2);
const { devices } = JSON.parse(readFileSync(file, 'utf8'));

function runtimeVersion(key) {
  const match = /iOS-(\d+)-(\d+)(?:-(\d+))?$/.exec(key);
  return match ? match.slice(1).map((part) => Number(part || 0)) : null;
}

function compare(a, b) {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] || 0) - (b[i] || 0);
    if (d) return d;
  }
  return 0;
}

const candidates = [];
for (const [runtime, list] of Object.entries(devices)) {
  const version = runtimeVersion(runtime);
  if (!version) continue;
  for (const device of list) {
    if (device.isAvailable === false) continue;
    const model = /^iPhone (\d+)( Pro( Max)?)?$/.exec(device.name);
    if (!model) continue;
    candidates.push({
      udid: device.udid,
      name: device.name,
      runtime: `iOS ${version.join('.')}`,
      version,
      rank: [Number(model[1]), model[3] ? 2 : model[2] ? 1 : 0],
    });
  }
}
if (!candidates.length) {
  console.error('no iPhone Simulator available');
  process.exit(1);
}
const newest = (list) => list.sort((a, b) => compare(b.version, a.version) || compare(b.rank, a.rank))[0];
const chosen = newest(candidates.filter((c) => c.name === preferred)) || newest(candidates);
console.log(JSON.stringify({ udid: chosen.udid, name: chosen.name, runtime: chosen.runtime }));
