#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/chess/chess-supercoach"
cd "$ROOT"

# ---------------------------------------------------------------- 1/2
cat > src/lib/coachVoice.ts <<'TS_EOF'
// src/lib/coachVoice.ts
import { Chess } from 'chess.js';

export type CoachMood = 'happy' | 'excited' | 'neutral' | 'concerned' | 'sad';

export interface CoachLine {
  text: string;
  mood: CoachMood;
  emoji: string;
}

export interface CoachContext {
  classification: string;
  playedSan: string;
  bestSan: string;
  lossCp: number;
  fenBefore: string;
  fenAfter: string;
  bestPv: string[];
  evalForUserCp?: number;
  isGameOver: boolean;
  isCheckmate: boolean;
  isDraw: boolean;
  userWon?: boolean;
}

const PIECE_NAMES: Record<string, string> = {
  p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king',
};

function pieceNameFromSan(san: string): string | null {
  if (!san) return null;
  if (san.startsWith('O-O')) return 'king';
  const c = san[0];
  if (c >= 'A' && c <= 'Z') return PIECE_NAMES[c.toLowerCase()] ?? null;
  return 'pawn';
}

function targetSquareFromSan(san: string): string | null {
  if (!san || san.startsWith('O-O')) return null;
  const matches = san.match(/[a-h][1-8]/g);
  return matches ? matches[matches.length - 1] : null;
}

function getAttackers(game: Chess, square: string, color: 'w' | 'b'): string[] {
  const anyGame = game as unknown as {
    attackers?: (sq: string, c: 'w' | 'b') => string[] | undefined;
  };
  return typeof anyGame.attackers === 'function'
    ? anyGame.attackers(square, color) ?? []
    : [];
}

function isPieceHanging(fen: string, square: string, moverColor: 'w' | 'b'): boolean {
  try {
    const game = new Chess(fen);
    const oppColor = moverColor === 'w' ? 'b' : 'w';
    const attackers = getAttackers(game, square, oppColor);
    const defenders = getAttackers(game, square, moverColor);
    return attackers.length > 0 && defenders.length === 0;
  } catch {
    return false;
  }
}

function describeBestMove(bestSan: string): string {
  if (!bestSan) return '';
  if (bestSan.startsWith('O-O')) return ' — getting your king to safety';
  if (bestSan.includes('x')) return ' — winning material';
  const c = bestSan[0];
  if (c === 'N' || c === 'B') return ' — developing a piece';
  if (c === 'Q') return ' — activating your queen';
  if (c === 'R') return ' — improving your rook';
  if (c === 'K') return ' — moving the king to safety';
  return '';
}

function formatPawns(cp: number): string {
  const p = Math.round((Math.abs(cp) / 100) * 10) / 10;
  if (p < 0.1) return 'less than a pawn';
  return p === 1 ? '1 pawn' : `${p} pawns`;
}

function hashStr(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0;
  return h;
}

function pick<T>(arr: T[], seed: number): T {
  return arr[Math.abs(seed) % arr.length];
}

export function coachLine(ctx: CoachContext): CoachLine {
  const {
    classification, playedSan, bestSan, lossCp,
    fenBefore, fenAfter, isCheckmate, isDraw, userWon,
  } = ctx;

  const seed = hashStr(playedSan + '|' + Math.round(lossCp));

  if (isCheckmate) {
    return userWon
      ? { text: `Checkmate! Beautiful finish with ${playedSan}. Really well played.`, mood: 'excited', emoji: '🎉' }
      : { text: "Checkmate for your opponent. Tough one — let's analyse it and find where it slipped.", mood: 'sad', emoji: '😔' };
  }
  if (isDraw) {
    return { text: 'A draw. Solid — you held your ground all the way.', mood: 'neutral', emoji: '🤝' };
  }

  const moverColor = (fenBefore.split(' ')[1] as 'w' | 'b') || 'w';
  const piece = pieceNameFromSan(playedSan);
  const square = targetSquareFromSan(playedSan);
  const hanging = square ? isPieceHanging(fenAfter, square, moverColor) : false;
  const why = describeBestMove(bestSan);

  const winning = ctx.evalForUserCp !== undefined && ctx.evalForUserCp > 150;
  const losing = ctx.evalForUserCp !== undefined && ctx.evalForUserCp < -150;
  const tag = winning
    ? " You're in control — keep it up."
    : losing
      ? " You're behind, but there's still play."
      : '';

  if (classification === 'best' || classification === 'excellent' || classification === 'brilliant') {
    const lines = [
      `Perfect! ${playedSan} is exactly what I would play.${tag}`,
      `Excellent — ${playedSan} is the top engine choice. Well spotted.${tag}`,
      `Wow, brilliant find. ${playedSan} is the strongest move here.${tag}`,
      `That's the move! ${playedSan} — you're seeing the board clearly.${tag}`,
    ];
    return { text: pick(lines, seed), mood: 'excited', emoji: '⭐' };
  }

  if (classification === 'good' || classification === 'book') {
    const lines = [
      `Good move. ${playedSan} keeps things solid.${tag}`,
      `Nice — simple and strong.${tag}`,
      `I like that. ${playedSan} is a sensible choice.${tag}`,
      `Solid. Nothing flashy, but ${playedSan} does the job.${tag}`,
    ];
    return { text: pick(lines, seed), mood: 'happy', emoji: '👍' };
  }

  if (hanging && piece && square) {
    if (bestSan) {
      const lines = [
        `Careful! Your ${piece} on ${square} is hanging — nothing defends it. ${bestSan} would have been safer${why}.`,
        `Wait — your ${piece} on ${square} is completely unprotected. ${bestSan} was better${why}.`,
        `Hmm, that ${piece} is exposed on ${square}. Try ${bestSan} instead${why}.`,
      ];
      return { text: pick(lines, seed), mood: 'concerned', emoji: '⚠️' };
    }
    return {
      text: `Careful! Your ${piece} on ${square} is hanging — nothing defends it. Look for a move that keeps it safe.`,
      mood: 'concerned',
      emoji: '⚠️',
    };
  }

  if (classification === 'blunder') {
    if (bestSan) {
      const lines = [
        `Ouch — that's a blunder. ${playedSan} loses about ${formatPawns(lossCp)}. ${bestSan} was the move${why}.`,
        `That one hurts. ${playedSan} drops ${formatPawns(lossCp)} — I'd have played ${bestSan}${why}.`,
        `Big mistake there. ${bestSan} would have kept you in the game${why}.`,
      ];
      return { text: pick(lines, seed), mood: 'sad', emoji: '😬' };
    }
    return {
      text: `Ouch — that's a blunder. ${playedSan} loses about ${formatPawns(lossCp)}. There was a much better option here.`,
      mood: 'sad',
      emoji: '😬',
    };
  }

  if (classification === 'mistake') {
    if (bestSan) {
      const lines = [
        `Hmm, ${playedSan} is a mistake — it costs ${formatPawns(lossCp)}. ${bestSan} was better${why}.`,
        `Not quite. ${playedSan} lets your opponent back in. ${bestSan} holds the position${why}.`,
        `Careful — ${playedSan} drops ${formatPawns(lossCp)}. Try ${bestSan} next time${why}.`,
      ];
      return { text: pick(lines, seed), mood: 'concerned', emoji: '😕' };
    }
    return {
      text: `Hmm, ${playedSan} is a mistake — it costs ${formatPawns(lossCp)}. There was a stronger move available.`,
      mood: 'concerned',
      emoji: '😕',
    };
  }

  // inaccuracy or fallback
  if (bestSan) {
    const lines = [
      `A bit loose. ${playedSan} isn't bad, but ${bestSan} was cleaner${why}.`,
      `Hmm, small inaccuracy. ${bestSan} would have kept more of your advantage${why}.`,
      `Not a disaster — but ${bestSan} was slightly better${why}.`,
    ];
    return { text: pick(lines, seed), mood: 'neutral', emoji: '🤔' };
  }
  return {
    text: `${playedSan} is a little loose — there was a slightly better move.`,
    mood: 'neutral',
    emoji: '🤔',
  };
}

export function openingLine(): CoachLine {
  const lines = [
    "Good luck! Take your time — I'll be right here.",
    "Alright, let's see what you've got. Play your move.",
    'Ready when you are. Think carefully.',
  ];
  return { text: pick(lines, Date.now()), mood: 'happy', emoji: '♟️' };
}
TS_EOF

# ---------------------------------------------------------------- 2/2
cat > src/pages/PlayCoach.tsx <<'TSX_EOF'
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
import { CoachBubble } from '../components/CoachBubble';
import { coachLine, openingLine, type CoachLine } from '../lib/coachVoice';

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

// Cached from the "before" search (side-to-move = the user), so pv[0]
// really is the user's best move for the position they're about to move from.
interface BeforeCache {
  cp: number | null;
  bestSan: string | null;
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

function uciToSan(fen: string, uci: string | null | undefined): string | null {
  if (!uci || !UCI_MOVE.test(uci)) return null;
  try {
    const g = new Chess(fen);
    const m = g.move({
      from: uci.slice(0, 2),
      to: uci.slice(2, 4),
      promotion: uci.slice(4, 5) || undefined
    });
    return m?.san ?? null;
  } catch {
    return null;
  }
}

export function PlayCoach() {
  const { status, error } = useEngine();
  const engine = getEngine();

  const [game, setGame] = useState(() => new Chess());
  const [userColor, setUserColor] = useState<'w' | 'b'>('w');
  const [difficulty, setDifficulty] = useState(1);
  const [thinking, setThinking] = useState<string | null>(null);
  const [turns, setTurns] = useState<Turn[]>([]);
  const [feedback, setFeedback] = useState<CoachFeedback | null>(null);
  const [coach, setCoach] = useState<CoachLine | null>(openingLine());
  const [engineError, setEngineError] = useState<string | null>(null);
  const [savedGameId, setSavedGameId] = useState<string | null>(null);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);

  const gameRef = useRef(game);
  gameRef.current = game;
  const userColorRef = useRef(userColor);
  userColorRef.current = userColor;
  const difficultyRef = useRef(difficulty);
  difficultyRef.current = difficulty;

  const cachedBeforeRef = useRef<BeforeCache>({ cp: null, bestSan: null });
  const abortRef = useRef<AbortController | null>(null);
  const initCacheRef = useRef(false);
  const savedRef = useRef(false);

  useEffect(() => {
    if (status !== 'ready' || initCacheRef.current) return;
    if (userColorRef.current !== 'w') return;
    initCacheRef.current = true;
    void (async () => {
      try {
        const fen = gameRef.current.fen();
        const res = await engine.evaluate(fen, COACH_DEPTH);
        cachedBeforeRef.current = {
          cp: toCentipawns(res.raw),
          bestSan: uciToSan(fen, res.pv[0] ?? res.bestMove ?? null)
        };
      } catch { /* ignore */ }
    })();
  }, [status, engine]);

  useEffect(() => {
    if (!savedRef.current && gameRef.current.isGameOver()) {
      void persistGame();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [turns]);

  async function persistGame(): Promise<string | null> {
    if (savedRef.current) return savedGameId;
    if (turns.length === 0) return null;

    const rebuilt = new Chess();
    for (const t of turns) {
      try {
        rebuilt.move(t.san);
      } catch {
        setEngineError(`Could not replay move ${t.ply}: ${t.san}`);
        return null;
      }
    }
    if (rebuilt.history().length === 0) return null;

    const plies = rebuilt.history().length;
    const result = rebuilt.isCheckmate()
      ? (rebuilt.turn() === 'w' ? '0-1' : '1-0')
      : rebuilt.isDraw() ? '1/2-1/2' : '*';

    const today = new Date().toISOString().slice(0, 10).replace(/-/g, '.');
    rebuilt.header(
      'Event', 'Coaching game',
      'Site', 'chess-supercoach',
      'Date', today,
      'White', 'You',
      'Black', 'Coach',
      'Result', result,
      'PlyCount', String(plies)
    );

    const pgn = rebuilt.pgn();
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
      const fenAfterEngine = c2.fen();
      const coachRes = await engine.evaluate(fenAfterEngine, COACH_DEPTH, ctrl.signal);
      const cp = toCentipawns(coachRes.raw);

      // c2 side-to-move is the USER — so pv[0] is the user's best next move.
      cachedBeforeRef.current = {
        cp,
        bestSan: uciToSan(fenAfterEngine, coachRes.pv[0] ?? coachRes.bestMove ?? null)
      };

      const cpWhite = cp === null ? null : (userColorRef.current === 'w' ? cp : -cp);

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

    const fenBefore = gameRef.current.fen();
    const c = new Chess(fenBefore);
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
      // Best move for the position the user just moved FROM — cached during
      // the previous engine move (or at game start), where the user was to move.
      const cached = cachedBeforeRef.current;
      const beforeUserPov = cached.cp;
      const bestSan = cached.bestSan ?? undefined;

      const coachRes = await engine.evaluate(c.fen(), COACH_DEPTH, ctrl.signal);
      const afterCpOpp = toCentipawns(coachRes.raw);
      const afterCpUserPov = afterCpOpp === null ? null : -afterCpOpp;
      const loss = evalLoss(beforeUserPov, afterCpUserPov);

      const isBest = bestSan !== undefined && mv.san === bestSan;
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

      const fb: CoachFeedback = { classification, san: mv.san, loss, bestSan, bestPv: coachRes.pv };
      setFeedback(fb);

      const isCheckmate = c.isCheckmate();
      const userWon = isCheckmate && c.turn() !== userColorRef.current;
      setCoach(coachLine({
        classification,
        playedSan: mv.san,
        bestSan: bestSan ?? '',
        lossCp: loss ?? 0,
        fenBefore,
        fenAfter: c.fen(),
        bestPv: coachRes.pv ?? [],
        evalForUserCp: afterCpUserPov ?? undefined,
        isGameOver: c.isGameOver(),
        isCheckmate,
        isDraw: c.isDraw(),
        userWon
      }));

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
    setCoach(openingLine());
    resetSaved();
    cachedBeforeRef.current = { cp: null, bestSan: null };
    initCacheRef.current = false;

    if (status === 'ready') {
      if (userColor === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        void (async () => {
          try {
            const fen = c.fen();
            const res = await engine.evaluate(fen, COACH_DEPTH);
            cachedBeforeRef.current = {
              cp: toCentipawns(res.raw),
              bestSan: uciToSan(fen, res.pv[0] ?? res.bestMove ?? null)
            };
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
    setCoach(openingLine());
    resetSaved();
    cachedBeforeRef.current = { cp: null, bestSan: null };
    initCacheRef.current = false;

    if (status === 'ready') {
      if (color === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        void (async () => {
          try {
            const fen = c.fen();
            const res = await engine.evaluate(fen, COACH_DEPTH);
            cachedBeforeRef.current = {
              cp: toCentipawns(res.raw),
              bestSan: uciToSan(fen, res.pv[0] ?? res.bestMove ?? null)
            };
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
            Play against Stockfish. Your coach watches every move and talks you through it.
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
              Coaching depth is {COACH_DEPTH}. Difficulty only changes how strongly Stockfish
              plays its own moves. Finished games are saved automatically.
            </p>
          </div>

          <CoachBubble line={thinking ? null : coach} thinking={!!thinking} />

          {feedback && !thinking && (
            <div className="space-y-1 px-2">
              <div className="flex flex-wrap items-center gap-2 text-xs text-slate-500">
                <Badge cls={feedback.classification} />
                <span className="font-mono text-slate-300">{feedback.san}</span>
                {feedback.loss !== null && feedback.loss > 0 && (
                  <span>−{(feedback.loss / 100).toFixed(2)} pawns</span>
                )}
                {feedback.bestSan && feedback.classification !== 'best' && (
                  <span>· engine's pick: <span className="font-mono text-slate-300">{feedback.bestSan}</span></span>
                )}
              </div>
              {feedback.bestPv && feedback.bestPv.length > 0 && (
                <div className="text-xs font-mono text-slate-500 break-words">
                  Engine line: {feedback.bestPv.slice(0, 8).join(' ')}
                </div>
              )}
            </div>
          )}

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
TSX_EOF

echo "Wrote 2 files:"
echo "  src/lib/coachVoice.ts"
echo "  src/pages/PlayCoach.tsx"
echo ""
echo "Next: cd $ROOT && npm run typecheck && npm run dev"