cd ~/chess/chess-supercoach
cp src/pages/Analysis.tsx src/pages/Analysis.tsx.bak

cat > src/pages/Analysis.tsx << 'TSEOF'
import { useEffect, useMemo, useRef, useState, type ChangeEvent, type ReactNode } from 'react';
import { Chessboard } from 'react-chessboard';
import { Chess } from 'chess.js';
import {
  ChevronFirst, ChevronLeft, ChevronRight, ChevronLast, Play, Square, Upload,
  FolderOpen, X
} from 'lucide-react';
import { parsePgn, isValidFen, fenAtPly, PgnError } from '../lib/pgn';
import { getEngine } from '../engine/stockfish';
import { useEngine } from '../hooks/useEngine';
import { runAnalysis } from '../features-runner';
import {
  saveGame, saveAnalysis, addTrainingItem, makeTrainingItem, getAnalysis, getPrefs, listGames
} from '../storage/db';
import { openingFor } from '../lib/openings';
import { EvalBar } from '../components/EvalBar';
import type { GameRecord, MoveEval } from '../types';

function extractGameId(): string | null {
  const m = window.location.hash.match(/[?&]gameId=([^&]+)/);
  return m ? decodeURIComponent(m[1]) : null;
}

function gameResult(g: GameRecord): string {
  const m = g.pgn?.match(/\[Result "([^"]+)"\]/);
  return m ? m[1] : '?';
}

export function Analysis() {
  const { status, error } = useEngine();
  const [game, setGame] = useState<GameRecord | null>(null);
  const [pgnText, setPgnText] = useState('');
  const [fenInput, setFenInput] = useState('');
  const [ply, setPly] = useState(0);
  const [partial, setPartial] = useState<MoveEval[]>([]);
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState({ done: 0, total: 0 });
  const [msg, setMsg] = useState<string | null>(null);
  const [liveEval, setLiveEval] = useState<{ cp: number | null; mate: number | null }>({ cp: null, mate: null });
  const abortRef = useRef<AbortController | null>(null);
  const partialRef = useRef<MoveEval[]>([]);

  // ─── hash-driven game loader ─────────────────────────────────
  const [hashGameId, setHashGameId] = useState<string | null>(() => extractGameId());
  const [allGames, setAllGames] = useState<GameRecord[]>([]);
  const [pickerOpen, setPickerOpen] = useState(false);
  const [gamesCount, setGamesCount] = useState(0);

  useEffect(() => {
    const onHash = () => setHashGameId(extractGameId());
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  useEffect(() => {
    if (!hashGameId) return;
    if (game?.id === hashGameId) return;
    let cancelled = false;
    void (async () => {
      try {
        const all = await listGames();
        const g = all.find((x) => x.id === hashGameId);
        if (cancelled) return;
        if (!g) { setMsg('Game not found.'); return; }
        setGame(g);
        setPgnText(g.pgn);
        setPly(0);
        setPartial([]);
        partialRef.current = [];
        setMsg(`Loaded game (${g.plies} half-moves).`);
        const existing = await getAnalysis(g.id);
        if (cancelled) return;
        if (existing) {
          setPartial(existing.moves);
          partialRef.current = existing.moves;
        }
      } catch {
        if (!cancelled) setMsg('Failed to load game.');
      }
    })();
    return () => { cancelled = true; };
  }, [hashGameId, game?.id]);

  useEffect(() => {
    if (!pickerOpen) return;
    let cancelled = false;
    void (async () => {
      try {
        const games = await listGames();
        games.sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0));
        if (!cancelled) {
          setAllGames(games);
          setGamesCount(games.length);
        }
      } catch { /* ignore */ }
    })();
    return () => { cancelled = true; };
  }, [pickerOpen]);

  useEffect(() => {
    void (async () => {
      try {
        const games = await listGames();
        setGamesCount(games.length);
      } catch { /* ignore */ }
    })();
  }, [game?.id]);

  // ─── (rest unchanged from here on) ───────────────────────────

  useEffect(() => {
    const m = partial.find((x) => x.ply === ply);
    if (m) setLiveEval({ cp: m.beforeCp, mate: null });
  }, [ply, partial]);

  const moves = useMemo(() => {
    if (!game) return [] as { san: string }[];
    const c = new Chess();
    c.loadPgn(game.pgn);
    return c.history({ verbose: true }).map((m) => ({ san: m.san }));
  }, [game]);

  const boardFen = useMemo(() => {
    if (game) return fenAtPly(game.pgn, ply);
    if (fenInput && isValidFen(fenInput)) return fenInput;
    return new Chess().fen();
  }, [game, ply, fenInput]);

  const currentMove = partial.find((m) => m.ply === ply);

  const arrows = useMemo<[string, string, string?][]>(() => {
    if (!currentMove?.bestPv?.length) return [];
    const uci = currentMove.bestPv[0];
    if (!/^[a-h][1-8][a-h][1-8]/.test(uci)) return [];
    return [[uci.slice(0, 2), uci.slice(2, 4), '#7ef29d']];
  }, [currentMove]);

  const opening = useMemo(() => openingFor(moves.map((m) => m.san)), [moves]);

  async function importPgn(text: string) {
    setMsg(null);
    try {
      const parsed = parsePgn(text);
      await saveGame(parsed);
      setMsg(`Imported ${parsed.plies} half-moves.`);
      window.location.hash = `#analysis?gameId=${encodeURIComponent(parsed.id)}`;
    } catch (e) {
      setMsg(e instanceof PgnError ? e.message : 'Could not import PGN.');
    }
  }

  async function onFile(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file) return;
    await importPgn(await file.text());
    e.target.value = '';
  }

  async function startAnalysis() {
    if (!game) return;
    if (status !== 'ready') { setMsg('Engine is not ready yet.'); return; }
    const prefs = await getPrefs();
    const engine = getEngine();
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    setRunning(true);
    setMsg(null);

    try {
      const existing = await getAnalysis(game.id);
      const startMoves = existing?.moves ?? [];
      partialRef.current = startMoves;
      setPartial(startMoves);

      const result = await runAnalysis(game, engine, {
        depth: prefs.engineDepth,
        existingMoves: startMoves,
        signal: ctrl.signal,
        onProgress: (done, total, movesSoFar) => {
          setProgress({ done, total });
          const copy = [...movesSoFar];
          partialRef.current = copy;
          setPartial(copy);
          if (done % 5 === 0 || done === total) {
            void saveAnalysis({
              gameId: game.id,
              depth: prefs.engineDepth,
              moves: copy,
              updatedAt: Date.now(),
              complete: done === total
            }).catch(() => undefined);
          }
        }
      });
      await saveAnalysis(result);

      for (const m of result.moves) {
        if (m.classification === 'mistake' || m.classification === 'blunder') {
          if (m.bestSan && m.loss !== null) {
            await addTrainingItem(
              makeTrainingItem(game.id, m.ply, m.fenBefore, m.san, m.bestSan, m.bestPv ?? [], m.loss, m.classification)
            );
          }
        }
      }
      setMsg(result.complete ? 'Analysis complete.' : 'Analysis stopped early — progress saved.');
    } catch (e) {
      const err = e as Error;
      if (err.name !== 'AbortError') {
        setMsg('Analysis failed: ' + err.message);
      } else {
        if (partialRef.current.length > 0) {
          await saveAnalysis({
            gameId: game.id,
            depth: prefs.engineDepth,
            moves: partialRef.current,
            updatedAt: Date.now(),
            complete: false
          }).catch(() => undefined);
        }
        setMsg('Analysis stopped — progress saved.');
      }
    } finally {
      setRunning(false);
      abortRef.current = null;
    }
  }

  function stopAnalysis() {
    abortRef.current?.abort();
  }

  function exportPgn() {
    if (!game) return;
    const blob = new Blob([game.pgn], { type: 'application/x-chess-pgn' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'game.pgn';
    a.click();
    URL.revokeObjectURL(a.href);
  }

  return (
    <div className="max-w-6xl space-y-4">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h1 className="text-2xl font-semibold tracking-tight">Game analysis</h1>
        <span className={`text-xs px-2 py-1 rounded-full ${
          status === 'ready' ? 'bg-lime/10 text-lime'
          : status === 'error' ? 'bg-rose-500/10 text-rose-300'
          : 'bg-ink-700 text-slate-400'}`}>
          engine: {status}
        </span>
      </header>

      {error && (
        <div className="rounded-lg border border-rose-500/40 bg-rose-500/10 text-rose-200 text-sm p-3">
          Engine failed to load: {error}
        </div>
      )}

      <div className="grid lg:grid-cols-[auto_1fr] gap-4">
        <div className="flex gap-3">
          <EvalBar cp={liveEval.cp} mate={liveEval.mate} />
          <div className="w-[min(78vw,480px)]">
            <Chessboard
              position={boardFen}
              onPieceDrop={() => false}
              boardOrientation="white"
              customArrows={arrows as never}
              customDarkSquareStyle={{ backgroundColor: '#4f6f52' }}
              customLightSquareStyle={{ backgroundColor: '#e8eddf' }}
            />
            <div className="flex items-center justify-center gap-1 mt-3">
              <IconBtn onClick={() => setPly(0)} disabled={ply === 0}><ChevronFirst size={18} /></IconBtn>
              <IconBtn onClick={() => setPly((p) => Math.max(0, p - 1))} disabled={ply === 0}><ChevronLeft size={18} /></IconBtn>
              <span className="text-sm text-slate-400 px-2 tabular-nums">{ply} / {moves.length}</span>
              <IconBtn onClick={() => setPly((p) => Math.min(moves.length, p + 1))} disabled={ply >= moves.length}><ChevronRight size={18} /></IconBtn>
              <IconBtn onClick={() => setPly(moves.length)} disabled={ply >= moves.length}><ChevronLast size={18} /></IconBtn>
            </div>
          </div>
        </div>

        <div className="space-y-3 min-w-0">
          {/* ─── Game picker ─────────────────────────────────── */}
          <div className="rounded-xl border border-ink-600 bg-ink-800">
            <button
              type="button"
              onClick={() => setPickerOpen((o) => !o)}
              className="w-full p-3 flex items-center justify-between text-sm">
              <span className="flex items-center gap-2 text-slate-300">
                <FolderOpen size={14} />
                Your games
                <span className="text-xs text-slate-500">({gamesCount})</span>
              </span>
              {pickerOpen ? <X size={14} /> : <span className="text-xs text-slate-500">open ▾</span>}
            </button>
            {pickerOpen && (
              <div className="border-t border-ink-600 max-h-72 overflow-y-auto">
                {allGames.length === 0 ? (
                  <p className="text-xs text-slate-500 p-3">No saved games yet — play a coach game or import a PGN.</p>
                ) : (
                  <ul className="divide-y divide-ink-700">
                    {allGames.map((g) => (
                      <li key={g.id}>
                        <button
                          type="button"
                          onClick={() => {
                            setPickerOpen(false);
                            window.location.hash = `#analysis?gameId=${encodeURIComponent(g.id)}`;
                          }}
                          className={`w-full text-left px-3 py-2 text-xs hover:bg-ink-700 ${
                            game?.id === g.id ? 'bg-lime/10 text-lime' : 'text-slate-300'
                          }`}>
                          <div className="flex items-center justify-between gap-2">
                            <span>
                              {g.createdAt ? new Date(g.createdAt).toLocaleDateString() : '—'}
                              {' · '}{g.plies} plies
                            </span>
                            <span className="font-mono">{gameResult(g)}</span>
                          </div>
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            )}
          </div>

          {/* ─── Analysis controls ───────────────────────────── */}
          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3">
            <div className="flex flex-wrap gap-2">
              <button
                onClick={startAnalysis}
                disabled={!game || running || status !== 'ready'}
                className="inline-flex items-center gap-1.5 rounded-lg bg-lime text-ink-900 font-medium px-3 py-1.5 text-sm disabled:opacity-40">
                <Play size={14} /> {running ? 'Analysing...' : 'Analyse'}
              </button>
              <button onClick={stopAnalysis} disabled={!running}
                className="inline-flex items-center gap-1.5 rounded-lg border border-ink-600 px-3 py-1.5 text-sm disabled:opacity-40">
                <Square size={14} /> Stop
              </button>
              <button onClick={exportPgn} disabled={!game}
                className="rounded-lg border border-ink-600 px-3 py-1.5 text-sm disabled:opacity-40">
                Export PGN
              </button>
            </div>
            {running && (
              <div className="mt-3">
                <div className="h-1.5 rounded-full bg-ink-700 overflow-hidden">
                  <div className="h-full bg-lime transition-all"
                       style={{ width: `${progress.total ? (progress.done / progress.total) * 100 : 0}%` }} />
                </div>
                <p className="text-xs text-slate-500 mt-1">
                  {progress.done} / {progress.total} positions
                </p>
              </div>
            )}
            {msg && <p className="text-xs text-slate-400 mt-2">{msg}</p>}
          </div>

          {/* ─── PGN import ──────────────────────────────────── */}
          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3 space-y-2">
            <label className="text-xs uppercase tracking-wide text-slate-500">Import PGN</label>
            <textarea
              value={pgnText}
              onChange={(e) => setPgnText(e.target.value)}
              rows={4}
              className="w-full rounded-lg bg-ink-900 border border-ink-600 p-2 text-sm font-mono resize-y"
            />
            <div className="flex flex-wrap gap-2">
              <button onClick={() => importPgn(pgnText)} disabled={!pgnText.trim()}
                className="rounded-lg bg-ink-700 px-3 py-1.5 text-sm disabled:opacity-40">Load PGN text</button>
              <label className="inline-flex items-center gap-1.5 rounded-lg border border-ink-600 px-3 py-1.5 text-sm cursor-pointer">
                <Upload size={14} /> Upload file
                <input type="file" accept=".pgn,text/plain" onChange={onFile} className="hidden" />
              </label>
            </div>
          </div>

          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3 space-y-2">
            <label className="text-xs uppercase tracking-wide text-slate-500">Position FEN</label>
            <input
              value={fenInput}
              onChange={(e) => setFenInput(e.target.value)}
              placeholder="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
              className="w-full rounded-lg bg-ink-900 border border-ink-600 p-2 text-xs font-mono"
            />
            {fenInput && !isValidFen(fenInput) && (
              <p className="text-xs text-rose-300">Invalid FEN.</p>
            )}
          </div>

          {opening && (
            <div className="rounded-xl border border-ink-600 bg-ink-800 p-3 text-sm">
              <span className="text-slate-500 text-xs uppercase tracking-wide">Opening</span>
              <div className="mt-0.5">{opening.name} <span className="text-slate-500">({opening.eco})</span></div>
              <p className="text-xs text-slate-500 mt-1">{opening.idea}</p>
            </div>
          )}

          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3">
            <h2 className="text-xs uppercase tracking-wide text-slate-500 mb-2">Moves</h2>
            <div className="max-h-64 overflow-y-auto text-sm font-mono">
              {moves.length === 0 && <p className="text-slate-500 font-sans">No game loaded.</p>}
              <div className="grid grid-cols-[2.5rem_1fr_1fr] gap-x-2">
                {chunkPairs(moves).map(([w, b], i) => (
                  <Row key={i} n={i + 1} white={w} black={b}
                       ply={ply} onSelect={setPly} partial={partial} />
                ))}
              </div>
            </div>
          </div>

          {currentMove && (
            <div className="rounded-xl border border-ink-600 bg-ink-800 p-3 text-sm space-y-1">
              <div className="flex items-center gap-2">
                <span className="text-slate-500 text-xs uppercase tracking-wide">Move {currentMove.ply}</span>
                <Badge cls={currentMove.classification} />
              </div>
              <div className="text-slate-400">
                {currentMove.san} · loss {((currentMove.loss ?? 0) / 100).toFixed(2)} pawns
              </div>
              {currentMove.bestSan && (
                <div className="text-slate-300">Engine preferred: <span className="font-mono">{currentMove.bestSan}</span></div>
              )}
              {currentMove.bestPv && currentMove.bestPv.length > 0 && (
                <div className="text-xs text-slate-500 font-mono break-words">
                  PV: {currentMove.bestPv.slice(0, 10).join(' ')}
                </div>
              )}
              <div className="text-xs text-slate-500">depth {currentMove.depth}</div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

function IconBtn({ children, onClick, disabled }: {
  children: ReactNode; onClick: () => void; disabled?: boolean;
}) {
  return (
    <button onClick={onClick} disabled={disabled}
      className="p-1.5 rounded-lg border border-ink-600 text-slate-300 disabled:opacity-30 hover:bg-ink-700">
      {children}
    </button>
  );
}

function Badge({ cls }: { cls: string }) {
  const map: Record<string, string> = {
    best: 'bg-lime/15 text-lime',
    good: 'bg-slate-500/15 text-slate-300',
    inaccuracy: 'bg-amber-400/15 text-amber-300',
    mistake: 'bg-orange-500/15 text-orange-300',
    blunder: 'bg-rose-500/15 text-rose-300',
    unknown: 'bg-ink-700 text-slate-500'
  };
  return <span className={`text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded ${map[cls] ?? map.unknown}`}>{cls}</span>;
}

function chunkPairs<T>(arr: T[]): [T | undefined, T | undefined][] {
  const out: [T | undefined, T | undefined][] = [];
  for (let i = 0; i < arr.length; i += 2) out.push([arr[i], arr[i + 1]]);
  return out;
}

function Row({ n, white, black, ply, onSelect, partial }: {
  n: number;
  white?: { san: string };
  black?: { san: string };
  ply: number;
  onSelect: (p: number) => void;
  partial: MoveEval[];
}) {
  const wp = n * 2 - 1;
  const bp = n * 2;
  const cls = (p: number) => partial.find((m) => m.ply === p)?.classification;
  return (
    <>
      <span className="text-slate-600 text-right">{n}.</span>
      {white && (
        <button onClick={() => onSelect(wp)}
          className={`text-left px-1 rounded ${ply === wp ? 'bg-lime/10 text-lime' : 'hover:bg-ink-700'}`}>
          {white.san}
          {cls(wp) && cls(wp) !== 'good' && cls(wp) !== 'best' && <span className="text-rose-400 ml-0.5">?</span>}
        </button>
      )}
      {black ? (
        <button onClick={() => onSelect(bp)}
          className={`text-left px-1 rounded ${ply === bp ? 'bg-lime/10 text-lime' : 'hover:bg-ink-700'}`}>
          {black.san}
          {cls(bp) && cls(bp) !== 'good' && cls(bp) !== 'best' && <span className="text-rose-400 ml-0.5">?</span>}
        </button>
      ) : <span />}
    </>
  );
}
TSEOF
echo "wrote src/pages/Analysis.tsx"
npm run typecheck