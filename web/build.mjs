// Bundles the editor-window web panes into single self-contained ESM files,
// vendored into the app bundle so the app works fully offline (no CDN).
//
//   cd web && npm install && npm run build
//
// Output → ../Sources/LGTM/WebAssets/vendor/{trees,diffs}.bundle.js
// IMPORTANT: code-splitting is OFF so esbuild inlines dynamic import()s (Shiki's
// per-language grammar loaders) into the bundle instead of leaving them as
// runtime fetches — that is what makes the diff pane offline-safe.
import * as esbuild from 'esbuild';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';

const dir = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(dir, '../Sources/LGTM/WebAssets/vendor');
fs.mkdirSync(outDir, { recursive: true });

const common = {
  bundle: true,
  format: 'esm',
  platform: 'browser',
  target: 'es2022',
  minify: true,
  legalComments: 'none',
  logLevel: 'info',
  // No `splitting` → dynamic imports are inlined, not emitted as separate chunks.
};

const builds = [
  { entry: 'src/tree-entry.mjs', out: 'trees.bundle.js' },
  { entry: 'src/diff-entry.mjs', out: 'diffs.bundle.js' },
  { entry: 'src/conversation-entry.mjs', out: 'conversation.bundle.js' },
];

for (const b of builds) {
  await esbuild.build({
    ...common,
    entryPoints: [path.join(dir, b.entry)],
    outfile: path.join(outDir, b.out),
  });
  const size = fs.statSync(path.join(outDir, b.out)).size;
  console.log(`built ${b.out} (${(size / 1024 / 1024).toFixed(2)} MB)`);
}
