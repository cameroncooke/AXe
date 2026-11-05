import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

const root = new URL('./', import.meta.url);
const provenance = JSON.parse(await readFile(new URL('provenance.json', root), 'utf8'));
for (const [file, expected] of Object.entries(provenance.files)) {
  const body = await readFile(new URL(file, root));
  const actual = createHash('sha256').update(body).digest('hex');
  assert.equal(actual, expected, 'Vendored source changed: ' + file);
}
console.log('Verified ' + Object.keys(provenance.files).length + ' copied source and license files.');
