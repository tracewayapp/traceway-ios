// node plan.mjs --mode <build|smoke|plan> --scenario S6 --variants off,off2,core,buffer,stream-img
//               --repetitions 5 [--warmup 1] [--evidence stream-img,buffer] [--seed 1112970949]
//               [--extra "-fmToolkit stack"] [--tag stack]
//
// The runs of one job, in order (03-MEASUREMENT.md §5.2): a block is one
// repetition of the scenario in every variant, in a random order drawn from
// the seed; one warm-up block (b00) runs first and is thrown away; evidence
// runs (screen video, screenshots, SDK debug log) come last and are never
// used for cost. Run ids: ios-<scenario>-<variant>-b<NN>-<4 hex> and
// ios-<scenario>-<variant>-ev-<4 hex> (05-RESULTS-FORMAT.md §1).
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FMRandom } from './random.mjs';

const journey = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'shared', 'journey.json'), 'utf8'));

const args = Object.fromEntries(
  process.argv.slice(2).reduce((pairs, value, index, all) => {
    if (value.startsWith('--')) pairs.push([value.slice(2), all[index + 1] ?? '']);
    return pairs;
  }, []),
);
const list = (text) => (text || '').split(/[,\s]+/).map((s) => s.trim()).filter(Boolean);
const mode = args.mode || 'plan';
const scenario = (args.scenario || 'S6').trim();
const seed = Number(args.seed || 1112970949) >>> 0;
const extra = (args.extra || '').trim();
const tag = (args.tag || '').replace(/[^A-Za-z0-9]/g, '');
const random = new FMRandom((seed ^ hash(`${mode}:${scenario}:${extra}`)) >>> 0);

function hash(text) {
  let h = 2166136261;
  for (const ch of text) h = Math.imul(h ^ ch.charCodeAt(0), 16777619) >>> 0;
  return h;
}

// The order of the variants comes from the seed; the 4-hex suffix of a run id
// from the workflow run, so a repeated plan never reuses an fm.run value.
const idRandom = new FMRandom(hash(`${process.env.GITHUB_RUN_ID || Date.now()}:${process.env.GITHUB_RUN_ATTEMPT || 1}:${scenario}`));

function hex4() {
  return Math.floor(idRandom.next() * 65536).toString(16).padStart(4, '0');
}

function shuffled(items) {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random.next() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

function id(scenarioId, variant, slot) {
  const name = tag ? `${scenarioId}${tag}` : scenarioId;
  return `ios-${name}-${variant}-${slot}-${hex4()}`;
}

const runs = [];
function add(scenarioId, variant, block, order, evidence) {
  const slot = evidence ? 'ev' : `b${String(block).padStart(2, '0')}`;
  runs.push({
    runId: id(scenarioId, variant, slot), scenario: scenarioId, variant, block: evidence ? null : block,
    orderInBlock: order, evidence, warmup: !evidence && block === 0, extra,
  });
}

if (mode === 'smoke') {
  // The smoke gate: S6 in stream-img with evidence, one block of S1 with off and off2.
  shuffled(['off', 'off2']).forEach((variant, order) => add('S1', variant, 1, order, false));
  add('S6', 'stream-img', null, 0, true);
} else if (mode === 'build') {
  // After the build: one S0 run in off and one in core (launch, driver, probe, gateway, artifact).
  add('S0', 'off', 1, 0, false);
  add('S0', 'core', 1, 1, false);
} else if (/^S7[a-z]$/.test(scenario)) {
  // Things going wrong: one launch in the part's own variant, checked like an
  // evidence run (screen video included).
  const part = journey.scenarios[scenario];
  if (!part) throw new Error(`no scenario ${scenario} in journey.json`);
  if (part.platforms && !part.platforms.includes('ios')) throw new Error(`${scenario} is not run on iOS (${part.platforms})`);
  if (part.tiers && !part.tiers.includes('ci')) throw new Error(`${scenario} needs a live Traceway (tiers ${part.tiers})`);
  add(scenario, part.variant || 'stream-img', null, 0, true);
} else {
  const part = journey.scenarios[scenario];
  if (!part) throw new Error(`no scenario ${scenario} in journey.json`);
  if (part.platforms && !part.platforms.includes('ios')) throw new Error(`${scenario} is not run on iOS (${part.platforms})`);
  const variants = list(args.variants || 'off,off2,core,buffer,stream-img');
  const repetitions = Number(args.repetitions || 5);
  const warmup = args.warmup === undefined ? true : !['0', 'false', 'no'].includes(String(args.warmup));
  for (let block = warmup ? 0 : 1; block <= repetitions; block++) {
    shuffled(variants).forEach((variant, order) => add(scenario, variant, block, order, false));
  }
  list(args.evidence).filter((v) => v !== 'none').forEach((variant, order) => add(scenario, variant, null, order, true));
}

console.log(JSON.stringify({ mode, scenario, seed, extra, tag, runs }, null, 2));
