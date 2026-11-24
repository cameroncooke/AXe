// Renders chosen frames of the 2.1 film at half size, for checking: node stillsTour.mjs 3 8 11.2 ...
import {bundle} from '@remotion/bundler';
import {renderStill, selectComposition} from '@remotion/renderer';
import path from 'node:path';
import fs from 'node:fs';
const times = process.argv.slice(2).map(Number);
const out = process.env.OUT_DIR || 'out/stillsTour';
fs.mkdirSync(out, {recursive: true});
const serveUrl = await bundle({entryPoint: path.resolve('src/index.ts')});
const composition = await selectComposition({serveUrl, id: process.env.COMP || 'Film21', inputProps: {music: false}});
console.log('duration', composition.durationInFrames / composition.fps);
for (const t of times) {
  const file = path.join(out, `t${t.toFixed(2).padStart(6, '0')}.jpg`);
  await renderStill({composition, serveUrl, output: file, frame: Math.round(t * composition.fps), scale: 0.5, imageFormat: 'jpeg', jpegQuality: 80, inputProps: {music: false}});
  console.log('wrote', file);
}
