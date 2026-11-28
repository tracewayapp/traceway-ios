#!/usr/bin/env node
// node check-ids.mjs <ids.json> <source dir>…
//
// Every element id the journey uses (shared/ids.json) must exist in the app:
// as a string literal ("fm-nav-home") or as an interpolated prefix
// ("fm-home-product-\(id)" covers fm-home-product-17). Prints the ids that
// have neither, and exits 1 when there are any.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

const [idsFile, ...dirs] = process.argv.slice(2);
const raw = JSON.parse(readFileSync(idsFile, 'utf8'));
const ids = Array.isArray(raw) ? raw : raw.ids || Object.keys(raw);

function files(dir) {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return files(path);
    return name.endsWith('.swift') ? [path] : [];
  });
}
const source = dirs.flatMap(files).map((file) => readFileSync(file, 'utf8')).join('\n');
const literals = new Set([...source.matchAll(/"(fm-[A-Za-z0-9-]+)"/g)].map((m) => m[1]));
const prefixes = new Set([...source.matchAll(/"(fm-[A-Za-z0-9-]*-)\\\(/g)].map((m) => m[1]));
// Ids the driver reaches without an app identifier of the same name.
const driverOnly = new Set(['fm-nav-back']);

const missing = ids.filter((id) => {
  if (literals.has(id) || driverOnly.has(id)) return false;
  for (const prefix of prefixes) if (id.startsWith(prefix) && id.length > prefix.length) return false;
  return true;
});
console.log(`${ids.length} ids, ${ids.length - missing.length} found, ${missing.length} missing`);
for (const id of missing) console.log(`  missing: ${id}`);
process.exit(missing.length ? 1 : 0);
