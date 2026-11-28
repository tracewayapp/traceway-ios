// The journey and fixture hashes run.json carries, computed the way
// tools/lib/hashes.mjs computes them, from FieldTest/shared/ (the vendored
// copy the CI run used).
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

/** "sha256:<hex>" of a journey.json. */
export function journeyHash(file) {
  return `sha256:${createHash('sha256').update(readFileSync(file)).digest('hex')}`;
}

/** "sha256:<lock hash>" of a fixtures.lock.json. */
export function fixturesHash(lockFile) {
  return `sha256:${JSON.parse(readFileSync(lockFile, 'utf8')).hash}`;
}
