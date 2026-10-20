import { useEffect, useRef, useState } from 'react';
import { Chessboard } from 'react-chessboard';
import { Chess } from 'chess.js';
import { useEngine } from '../hooks/useEngine';
import { getEngine } from '../engine/stockfish';
import { classify, evalLoss, toCentipawns } from '../lib/eval';
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

  const gameRef = useRef(game);
  gameRef.current = game;
  const userColorRef = useRef(userColor);
  userColorRef.current = userColor;
  const difficultyRef = useRef(difficulty);
  difficultyRef.current = difficulty;

  const cachedBeforeEvalRef = useRef<number | null>(null);
  const abortRef = useRef<AbortController | null>(null);
  const initCacheRef = useRef(false);

  // When engine becomes ready and user is White, cache the starting position eval.
  useEffect(() => {
    if (status !== 'ready' || initCacheRef.current) return;
    if (userColorRef.current !== 'w') return;
    initCacheRef.current = true;
    (async () => {
      try {
        const res = await engine.evaluate(gameRef.current.fen(), COACH_DEPTH);
        cachedBeforeEvalRef.current = toCentipawns(res.raw);
      } catch { /* ignore */ }
    })();
  }, [status, engine]);

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

      // Cache the eval of the new position from the USER's POV.
      // After the engine's move, side-to-move = user, so cp is already user's POV.
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

      // True best = pv[0]. bestmove may be weakened by playDepth, so don't use it here.
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

  function newGame() {
    abortRef.current?.abort();
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setThinking(null);
    setEngineError(null);
    cachedBeforeEvalRef.current = null;
    initCacheRef.current = false;

    if (status === 'ready') {
      if (userColor === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        (async () => {
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
    // Reset with the new colour. newGame reads userColorRef, so update the ref first.
    userColorRef.current = color;
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setThinking(null);
    setEngineError(null);
    cachedBeforeEvalRef.current = null;
    initCacheRef.current = false;

    if (status === 'ready') {
      if (color === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        (async () => {
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

              <button onClick={newGame}
                className="ml-auto rounded-lg border border-ink-600 px-3 py-1 text-sm">
                New game
              </button>
            </div>
            <p className="text-xs text-slate-500">
              Coaching depth is {COACH_DEPTH} for accurate feedback. Difficulty only changes how
              strongly Stockfish plays its own moves.
            </p>
          </div>

          {gameOver && (
            <div className="rounded-xl border border-lime/40 bg-lime/10 p-3 text-sm">
              {game.isCheckmate()
                ? `Checkmate - ${game.turn() === userColor ? 'you lose' : 'you win'}.`
                : 'Draw.'}
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
                  The engine prefers <span className="font-mono text-slate-200">{feedback.bestSan}</span>.
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
            <div className="max-h-64 overflow-y-auto text-sm font-mono">
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
