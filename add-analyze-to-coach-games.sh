#!/usr/bin/env bash
set -euo pipefail
cd ~/chess/chess-supercoach || { echo "cd failed"; exit 1; }

# ---------- 1. New hook ----------
cat > src/hooks/useLoadGameFromHash.ts << 'TSEOF'
import { useEffect, useRef } from 'react';
import { listGames } from '../storage/db';
import type { GameRecord } from '../types';

/**
 * One-shot loader: if the URL hash contains ?gameId=<id>, load that game
 * from IndexedDB and hand it to onLoad. Fires at most once per mount.
 *
 * Used by Analysis.tsx so "Save & Analyse" from PlayCoach opens the
 * record that was just played, without creating a duplicate.
 */
export function useLoadGameFromHash(onLoad: (g: GameRecord) => void) {
  const onLoadRef = useRef(onLoad);
  onLoadRef.current = onLoad;
  const firedRef = useRef(false);

  useEffect(() => {
    if (firedRef.current) return;
    const m = window.location.hash.match(/[?&]gameId=([^&]+)/);
    if (!m) return;
    firedRef.current = true;
    const id = decodeURIComponent(m[1]);
    let cancelled = false;
    void (async () => {
      try {
        const games = await listGames();
        const g = games.find((x) => x.id === id);
        if (!cancelled && g) onLoadRef.current(g);
      } catch {
        /* silently ignore — normal PGN flow still works */
      }
    })();
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
}
TSEOF

# ---------- 2. PlayCoach.tsx ----------
cat > src/pages/PlayCoach.tsx << 'TSEOF'
import { useEffect, useRef, useState } from 'react';
import { Chessboard } from 'react-chessboard';
import { Chess } from 'chess.js';
import { useEngine } from '../hooks/useEngine';
import { getEngine } from '../engine/stockfish';
import { classify, evalLoss, toCentipawns } from '../lib/eval';
import { parsePgn } from '../lib/pgn';
import { saveGame } from '../storage/db';
import type { Classification } from '../types';
import { EvalBar } from '../components/EvalBar';

interface Turn {
  ply: number;
  san: string;
  isUser: boolean;
  classification: Classification;
  loss: number | null;
  bestSan?: string;
  bestPv?: string[];
  evalWhitePov: number | null;
}

interface CoachFeedback {
  classification: Classification;
  san: string;
  loss: number | null;
  bestSan?: string;
  bestPv?: string[];
}

const DIFFICULTIES = [
  { label: 'Beginner', playDepth: 2 },
  { label: 'Easy', playDepth: 3 },
  { label: 'Intermediate', playDepth: 5 },
  { label: 'Advanced', playDepth: 8 },
  { label: 'Expert', playDepth: 12 }
];

const COACH_DEPTH = 10;
const UCI_MOVE = /^[a-h][1-8][a-h][1-8][qrbn]?$/;

export function PlayCoach() {
  const { status, error } = useEngine();
  const engine = getEngine();

  const [game, setGame] = useState(() => new Chess());
  const [userColor, setUserColor] = useState<'w' | 'b'>('w');
  const [difficulty, setDifficulty] = useState(1);
  const [thinking, setThinking] = useState<string | null>(null);
  const [turns, setTurns] = useState<Turn[]>([]);
  const [feedback, setFeedback] = useState<CoachFeedback | null>(null);
  const [engineError, setEngineError] = useState<string | null>(null);
  const [savedGameId, setSavedGameId] = useState<string | null>(null);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);

  const gameRef = useRef(game);
  gameRef.current = game;
  const userColorRef = useRef(userColor);
  userColorRef.current = userColor;
  const difficultyRef = useRef(difficulty);
  difficultyRef.current = difficulty;

  const cachedBeforeEvalRef = useRef<number | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const initCacheRef = useRef(false);
  const savedRef = useRef(false);

  useEffect(() => {
    if (status !== 'ready' || initCacheRef.current) return;
    if (userColorRef.current !== 'w') return;
    initCacheRef.current = true;
    void (async () => {
      try {
        const res = await engine.evaluate(gameRef.current.fen(), COACH_DEPTH);
        cachedBeforeEvalRef.current = toCentipawns(res.raw);
      } catch { /* ignore */ }
    })();
  }, [status, engine]);

  // Auto-save when the game ends. Fires on every ply, cheap no-op otherwise.
  useEffect(() => {
    if (!savedRef.current && gameRef.current.isGameOver()) {
      void persistGame();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [turns]);

  async function persistGame(): Promise<string | null> {
    if (savedRef.current) return savedGameId;
    if (gameRef.current.history().length === 0) return null;
    const pgn = gameRef.current.pgn();
    if (!pgn || !pgn.trim()) return null;
    try {
      const rec = parsePgn(pgn);
      await saveGame(rec);
      savedRef.current = true;
      setSavedGameId(rec.id);
      return rec.id;
    } catch (e) {
      setEngineError((e as Error).message);
      return null;
    }
  }

  async function saveAndAnalyze() {
    setSaveMsg(null);
    const id = savedRef.current ? savedGameId : await persistGame();
    if (!id) {
      setSaveMsg('Nothing to save yet — play at least one move.');
      return;
    }
    window.location.hash = `#analysis?gameId=${encodeURIComponent(id)}`;
  }

  async function playEngineMove(c: Chess): Promise<void> {
    setThinking('Coach is thinking...');
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      const idx = Math.max(0, Math.min(DIFFICULTIES.length - 1, difficultyRef.current));
      const playDepth = DIFFICULTIES[idx].playDepth;

      const res = await engine.evaluate(c.fen(), playDepth, ctrl.signal);
      const uci = res.bestMove;
      if (!uci || !UCI_MOVE.test(uci)) return;

      const c2 = new Chess(c.fen());
      const played = c2.move({
        from: uci.slice(0, 2),
        to: uci.slice(2, 4),
        promotion: uci.slice(4, 5) || undefined
      });
      if (!played) return;

      setThinking('Updating evaluation...');
      const coachRes = await engine.evaluate(c2.fen(), COACH_DEPTH, ctrl.signal);
      const cp = toCentipawns(coachRes.raw);
      cachedBeforeEvalRef.current = cp;

      const engineColor = userColorRef.current === 'w' ? 'b' : 'w';
      const cpWhite = cp === null ? null : (engineColor === 'w' ? cp : -cp);

      setTurns((prev) => [...prev, {
        ply: c2.history().length,
        san: played.san,
        isUser: false,
        classification: 'best',
        loss: null,
        evalWhitePov: cpWhite
      }]);

      setGame(c2);
    } catch (e) {
      if ((e as Error).name !== 'AbortError') setEngineError((e as Error).message);
    } finally {
      setThinking(null);
      abortRef.current = null;
    }
  }

  async function onPieceDrop(from: string, to: string): Promise<boolean> {
    if (thinking || status !== 'ready') return false;
    if (gameRef.current.turn() !== userColorRef.current) return false;
    if (gameRef.current.isGameOver()) return false;

    const c = new Chess(gameRef.current.fen());
    let mv;
    try {
      mv = c.move({ from, to, promotion: 'q' });
    } catch {
      return false;
    }
    if (!mv) return false;

    setGame(c);
    setFeedback(null);
    setThinking('Analysing your move...');

    const ctrl = new AbortController();
    abortRef.current = ctrl;

    try {
      const beforeUserPov = cachedBeforeEvalRef.current;

      const coachRes = await engine.evaluate(c.fen(), COACH_DEPTH, ctrl.signal);
      const afterCpOpp = toCentipawns(coachRes.raw);
      const afterCpUserPov = afterCpOpp === null ? null : -afterCpOpp;
      const loss = evalLoss(beforeUserPov, afterCpUserPov);

      const trueBestUci = coachRes.pv[0] ?? '';
      let bestSan: string | undefined;
      if (UCI_MOVE.test(trueBestUci)) {
        const probe = new Chess(gameRef.current.fen());
        try {
          const bm = probe.move({
            from: trueBestUci.slice(0, 2),
            to: trueBestUci.slice(2, 4),
            promotion: trueBestUci.slice(4, 5) || undefined
          });
          bestSan = bm?.san;
        } catch { /* ignore */ }
      }

      const isBest = mv.san === bestSan;
      const classification = classify(loss, isBest);

      const engineColor = userColorRef.current === 'w' ? 'b' : 'w';
      const afterCpWhite = afterCpOpp === null ? null : (engineColor === 'w' ? afterCpOpp : -afterCpOpp);

      setTurns((prev) => [...prev, {
        ply: c.history().length,
        san: mv.san,
        isUser: true,
        classification,
        loss,
        bestSan,
        bestPv: coachRes.pv,
        evalWhitePov: afterCpWhite
      }]);

      setFeedback({ classification, san: mv.san, loss, bestSan, bestPv: coachRes.pv });

      if (!c.isGameOver()) {
        await playEngineMove(c);
      }
    } catch (e) {
      if ((e as Error).name !== 'AbortError') setEngineError((e as Error).message);
    } finally {
      setThinking(null);
      abortRef.current = null;
    }

    return true;
  }

  function resetSaved() {
    savedRef.current = false;
    setSavedGameId(null);
    setSaveMsg(null);
  }

  function newGame() {
    abortRef.current?.abort();
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setThinking(null);
    setEngineError(null);
    resetSaved();
    cachedBeforeEvalRef.current = null;
    initCacheRef.current = false;

    if (status === 'ready') {
      if (userColor === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        void (async () => {
          try {
            const res = await engine.evaluate(c.fen(), COACH_DEPTH);
            cachedBeforeEvalRef.current = toCentipawns(res.raw);
          } catch { /* ignore */ }
        })();
      }
    }
  }

  function changeColor(color: 'w' | 'b') {
    setUserColor(color);
    userColorRef.current = color;
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setThinking(null);
    setEngineError(null);
    resetSaved();
    cachedBeforeEvalRef.current = null;
    initCacheRef.current = false;

    if (status === 'ready') {
      if (color === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        void (async () => {
          try {
            const res = await engine.evaluate(c.fen(), COACH_DEPTH);
            cachedBeforeEvalRef.current = toCentipawns(res.raw);
          } catch { /* ignore */ }
        })();
      }
    }
  }

  const boardOrientation = userColor === 'w' ? 'white' : 'black';
  const lastEval = turns.length ? turns[turns.length - 1].evalWhitePov : null;
  const gameOver = game.isGameOver();

  return (
    <div className="max-w-6xl space-y-4">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Play the coach</h1>
          <p className="text-sm text-slate-400 mt-1">
            Play against Stockfish. After each of your moves, the coach checks whether you followed
            the engine's top choice and shows what you should have played.
          </p>
        </div>
        <span className={`text-xs px-2 py-1 rounded-full ${
          status === 'ready' ? 'bg-lime/10 text-lime'
          : status === 'error' ? 'bg-rose-500/10 text-rose-300'
          : 'bg-ink-700 text-slate-400'}`}>
          engine: {status}
        </span>
      </header>

      {(error || engineError) && (
        <div className="rounded-lg border border-rose-500/40 bg-rose-500/10 text-rose-200 text-sm p-3">
          Engine error: {error ?? engineError}
        </div>
      )}

      <div className="grid lg:grid-cols-[auto_1fr] gap-4">
        <div className="flex gap-3">
          <EvalBar cp={lastEval} mate={null} />
          <div className="w-[min(78vw,480px)]">
            <Chessboard
              position={game.fen()}
              onPieceDrop={onPieceDrop}
              boardOrientation={boardOrientation}
              arePiecesDraggable={!thinking && !gameOver && game.turn() === userColor}
              customDarkSquareStyle={{ backgroundColor: '#4f6f52' }}
              customLightSquareStyle={{ backgroundColor: '#e8eddf' }}
            />
          </div>
        </div>

        <div className="space-y-3 min-w-0">
          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3 space-y-2">
            <div className="flex flex-wrap gap-2 items-center text-sm">
              <label className="text-slate-400">You play:</label>
              <select
                value={userColor}
                onChange={(e) => changeColor(e.target.value as 'w' | 'b')}
                className="rounded-lg bg-ink-900 border border-ink-600 px-2 py-1 text-sm">
                <option value="w">White</option>
                <option value="b">Black</option>
              </select>

              <label className="text-slate-400 ml-2">Difficulty:</label>
              <select
                value={difficulty}
                onChange={(e) => setDifficulty(Number(e.target.value))}
                className="rounded-lg bg-ink-900 border border-ink-600 px-2 py-1 text-sm">
                {DIFFICULTIES.map((d, i) => (
                  <option key={d.label} value={i}>{d.label} (depth {d.playDepth})</option>
                ))}
              </select>

              <div className="ml-auto flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={saveAndAnalyze}
                  className="rounded-lg bg-lime text-ink-900 font-medium px-3 py-1 text-sm">
                  {savedGameId ? 'Saved ✓ — Analyse' : 'Save & Analyse'}
                </button>
                <button
                  type="button"
                  onClick={newGame}
                  className="rounded-lg border border-ink-600 px-3 py-1 text-sm">
                  New game
                </button>
              </div>
            </div>
            {saveMsg && <p className="text-xs text-amber-300">{saveMsg}</p>}
            <p className="text-xs text-slate-500">
              Coaching depth is {COACH_DEPTH} for accurate feedback. Difficulty only changes how
              strongly Stockfish plays its own moves. Finished games are saved automatically.
            </p>
          </div>

          {gameOver && (
            <div className="rounded-xl border border-lime/40 bg-lime/10 p-3 text-sm">
              {game.isCheckmate()
                ? `Checkmate - ${game.turn() === userColor ? 'you lose' : 'you win'}.`
                : 'Draw.'}
              {' '}
              {savedGameId
                ? 'Click "Saved ✓ — Analyse" to run a full game analysis.'
                : 'Saving...'}
            </div>
          )}

          {thinking && (
            <div className="rounded-xl border border-ink-600 bg-ink-800 p-3 text-sm text-slate-400">
              {thinking}
            </div>
          )}

          {feedback && (
            <div className={`rounded-xl border p-4 text-sm space-y-2 ${
              feedback.classification === 'blunder' ? 'border-rose-500/40 bg-rose-500/10'
              : feedback.classification === 'mistake' ? 'border-orange-500/40 bg-orange-500/10'
              : feedback.classification === 'inaccuracy' ? 'border-amber-400/40 bg-amber-400/10'
              : feedback.classification === 'best' ? 'border-lime/40 bg-lime/10'
              : 'border-ink-600 bg-ink-800'
            }`}>
              <div className="flex items-center gap-2">
                <Badge cls={feedback.classification} />
                <span className="font-medium font-mono">{feedback.san}</span>
                {feedback.loss !== null && feedback.loss > 0 && (
                  <span className="text-xs text-slate-400">
                    -{(feedback.loss / 100).toFixed(2)} pawns
                  </span>
                )}
              </div>
              {feedback.classification === 'best' && (
                <p>That is the engine's top choice.</p>
              )}
              {feedback.classification === 'good' && (
                <p>Solid move. The engine slightly prefers {feedback.bestSan ?? 'a different line'}.</p>
              )}
              {['inaccuracy', 'mistake', 'blunder'].includes(feedback.classification) && feedback.bestSan && (
                <p>
                  {feedback.classification === 'inaccuracy' ? 'Slightly inaccurate. '
                    : feedback.classification === 'mistake' ? 'A mistake. '
                    : 'A blunder. '}
                  The engine prefers <span className="font-mono text--slate-200">{feedback.bestSan}</span>.
                </p>
              )}
              {feedback.bestPv && feedback.bestPv.length > 0 && (
                <div className="text-xs font-mono text-slate-500 break-words">
                  PV: {feedback.bestPv.slice(0, 8).join(' ')}
                </div>
              )}
            </div>
          )}

          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3">
            <h2 className="text-xs uppercase tracking-wide text-slate-500 mb-2">Moves</h2>
            <div className="max-h64 overflow-y-auto text-sm font-mono">
              {turns.length === 0 && <p className="text-slate-500 font-sans">Waiting...</p>}
              <div className="grid grid-cols-[2.5rem_1fr_1fr] gap-x-2">
                {chunkPairs(turns).map(([w, b], i) => (
                  <Row key={i} n={i + 1} white={w} black={b} />
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function Badge({ cls }: { cls: Classification }) {
  const map: Record<string, string> = {
    best: 'bg-lime/15 text-lime',
    good: 'bg-slate-500/15 text-slate-300',
    inaccuracy: 'bg-amber-400/15 text-amber-300',
    mistake: 'bg-orange-500/15 text-orange-300',
    blunder: 'bg-rose-500/15 text-rose-300',
    unknown: 'bg-ink-700 text-slate-500'
  };
  return (
    <span className={`text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded ${map[cls] ?? map.unknown}`}>
      {cls}
    </span>
  );
}

function chunkPairs<T>(arr: T[]): [T | undefined, T | undefined][] {
  const out: [T | undefined, T | undefined][] = [];
  for (let i = 0; i < arr.length; i += 2) out.push([arr[i], arr[i + 1]]);
  return out;
}

function Row({ n, white, black }: { n: number; white?: Turn; black?: Turn }) {
  return (
    <>
      <span className="text-slate-600 text-right">{n}.</span>
      <MoveCell turn={white} />
      <MoveCell turn={black} />
    </>
  );
}

function MoveCell({ turn }: { turn?: Turn }) {
  if (!turn) return <span />;
  const mark = !turn.isUser ? '' :
    turn.classification === 'blunder' ? '??' :
    turn.classification === 'mistake' ? '?' :
    turn.classification === 'inaccuracy' ? '?!' :
    turn.classification === 'best' ? '!' : '';
  const color = !turn.isUser ? 'text-slate-400' :
    turn.classification === 'blunder' ? 'text-rose-400' :
    turn.classification === 'mistake' ? 'text-orange-400' :
    turn.classification === 'inaccuracy' ? 'text-amber-300' :
    turn.classification === 'best' ? 'text-lime' : 'text-slate-200';
  return (
    <span className={`text-left px-1 ${color}`}>
      {turn.san}{mark && <span className="ml-0.5">{mark}</span>}
    </span>
  );
}
TSEOF

# ---------- 3. Analysis.tsx ----------
cat > src/pages/Analysis.tsx << 'TSEOF'
import { useEffect, useMemo, useRef, useState, type ChangeEvent, type ReactNode } from 'react';
import { Chessboard } from 'react-chessboard';
import { Chess } from 'chess.js';
import { ChevronFirst, ChevronLeft, ChevronRight, ChevronLast, Play, Square, Upload } from 'lucide-react';
import { parsePgn, isValidFen, fenAtPly, PgnError } from '../lib/pgn';
import { getEngine } from '../engine/stockfish';
import { useEngine } from '../hooks/useEngine';
import { useLoadGameFromHash } from '../hooks/useLoadGameFromHash';
import { runAnalysis } from '../features-runner';
import { saveGame, saveAnalysis, addTrainingItem, makeTrainingItem, getAnalysis, getPrefs } from '../storage/db';
import { openingFor } from '../lib/openings';
import { EvalBar } from '../components/EvalBar';
import type { GameRecord, MoveEval } from '../types';

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

  // Load a specific game if the URL hash has ?gameId= (from PlayCoach).
  // Bypasses parsePgn/importPgn so we keep the existing record id.
  useLoadGameFromHash((g) => {
    setPgnText(g.pgn);
    setGame(g);
    setPly(0);
    setPartial([]);
    partialRef.current = [];
    setMsg(`Loaded game (${g.plies} half-moves).`);
    void (async () => {
      try {
        const existing = await getAnalysis(g.id);
        if (existing) {
          setPartial(existing.moves);
          partialRef.current = existing.moves;
        }
      } catch { /* ignore */ }
    })();
  });

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
      setGame(parsed);
      setPly(0);
      setPartial([]);
      await saveGame(parsed);
      const existing = await getAnalysis(parsed.id);
      if (existing) {
        setPartial(existing.moves);
        partialRef.current = existing.moves;
      }
      setMsg(`Imported ${parsed.plies} half-moves.`);
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

echo "✓ wrote src/hooks/useLoadGameFromHash.ts"
echo "✓ wrote src/pages/PlayCoach.tsx"
echo "✓ wrote 