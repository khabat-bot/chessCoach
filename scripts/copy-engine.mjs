/**
 * Copies a Stockfish WASM build from node_modules into public/engine/
 * and generates the worker shim that loads it.
 */
import fs from 'node:fs';
import path from 'node:path';

const outDir = path.resolve('public/engine');
fs.mkdirSync(outDir, { recursive: true });

const candidates = [
  'node_modules/stockfish/src/stockfish-nnue-16-single.js',
  'node_modules/stockfish/src/stockfish.js',
  'node_modules/stockfish/stockfish.js',
  'node_modules/stockfish.js/stockfish.js'
];

const found = candidates.find((c) => fs.existsSync(c));
const workerPath = path.join(outDir, 'worker.js');

if (!found) {
  fs.writeFileSync(
    workerPath,
    `self.postMessage('ENGINE_LOAD_ERROR: no Stockfish build found in node_modules');\n`
  );
  console.warn('[copy-engine] No Stockfish build found. Engine will be unavailable.');
  process.exit(0);
}

const base = path.basename(found);
const srcDir = path.dirname(found);

for (const file of fs.readdirSync(srcDir)) {
  if (/\.(js|wasm)$/.test(file)) {
    fs.copyFileSync(path.join(srcDir, file), path.join(outDir, file));
  }
}

fs.writeFileSync(
  workerPath,
  `try {\n  self.importScripts('/engine/${base}');\n} catch (e) {\n  self.postMessage('ENGINE_LOAD_ERROR: ' + e.message);\n}\n`
);

fs.writeFileSync(
  path.join(outDir, 'ENGINE_LICENSE.txt'),
  'Stockfish is licensed under the GNU General Public License v3.\n' +
  'Source: https://github.com/official-stockfish/Stockfish\n' +
  'Distributed via the npm package "stockfish" (pinned in package.json).\n'
);

console.log(`[copy-engine] installed ${base} -> public/engine/`);
