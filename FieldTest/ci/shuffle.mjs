// node shuffle.mjs <comma-separated items> <seed>: the items in a seeded random order, space-separated.
import { FMRandom } from './random.mjs';

const [items = '', seed = '1'] = process.argv.slice(2);
const random = new FMRandom(Number(seed) >>> 0);
const out = items.split(',').map((s) => s.trim()).filter(Boolean);
for (let i = out.length - 1; i > 0; i--) {
  const j = Math.floor(random.next() * (i + 1));
  [out[i], out[j]] = [out[j], out[i]];
}
console.log(out.join(' '));
