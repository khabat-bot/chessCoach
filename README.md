# Chess Supercoach

An offline-first chess training app with a **real Stockfish** engine running in a
Web Worker. No backend, no accounts, no telemetry, no cloud AI.

## Install & run

Requires Node.js 18+.

    npm install     # also runs scripts/copy-engine.mjs to stage the WASM engine
    npm run dev     # http://localhost:5173

| Command | Purpose |
| --- | --- |
| npm run dev | dev server |
| npm run build | typecheck + production build |
| npm run preview | serve the production build |
| npm run test | Vitest unit tests |
| npm run typecheck | tsc --noEmit |
| npm run lint | placeholder (no ESLint configured) |

Windows PowerShell, macOS, and Linux all use the same commands.

## Where the engine comes from

npm install triggers postinstall -> scripts/copy-engine.mjs, which copies the
single-threaded NNUE build from the pinned stockfish npm package into
public/engine/ and writes public/engine/worker.js with the correct
importScripts path. If no known build is found, the worker reports
ENGINE_LOAD_ERROR and the UI shows a clear error - it never fakes analysis.

## Offline / PWA

    npm run build
    npm run preview      # http://localhost:4173

Open the preview URL, let the service worker install, then reload with DevTools
set to offline. The app, engine, and saved games keep working. The first load
needs network (to fetch npm packages at install time); after that, everything is
cached locally.

## Data

All state lives in IndexedDB under the `chess-supercoach` database. Export to
JSON from Settings; that export is the only backup mechanism.

## Known limitations

- The opening set in src/lib/openings.ts is a small hand-written sample, not a
  full ECO database.
- Analysis is two engine searches per ply, so long games at high depth are slow.
- No ESLint config is shipped; `npm run lint` is a no-op.
- PWA install prompt behaviour varies by browser.
- If react-chessboard renames customDarkSquareStyle or customLightSquareStyle in
  a future minor version, board colours may not apply. The board still works.
