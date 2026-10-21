#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/chess/chess-supercoach"
cd "$ROOT"
mkdir -p src/lib src/components src/pages

# ============================================================ 1/4 — TTS
cat > src/lib/coachTTS.ts <<'TS_EOF'
// src/lib/coachTTS.ts
//
// Web Speech API wrapper for the coach. Off by default; toggle persisted in
// localStorage under 'chess-supercoach:tts'. Prosody is nudged per mood so
// the excited lines sound fast/high and the sad lines sound slow/low.

export type TTSMood = 'happy' | 'excited' | 'neutral' | 'concerned' | 'sad';

const KEY = 'chess-supercoach:tts';
const listeners = new Set<(v: boolean) => void>();

const RATE: Record<TTSMood, number> = {
  excited: 1.08, happy: 1.03, neutral: 1.0, concerned: 0.96, sad: 0.9,
};
const PITCH: Record<TTSMood, number> = {
  excited: 1.15, happy: 1.06, neutral: 1.0, concerned: 0.94, sad: 0.88,
};

export function isTTSEnabled(): boolean {
  try { return localStorage.getItem(KEY) === '1'; } catch { return false; }
}

export function setTTSEnabled(v: boolean): void {
  try { localStorage.setItem(KEY, v ? '1' : '0'); } catch { /* noop */ }
  if (!v) stopSpeaking();
  listeners.forEach(fn => { try { fn(v); } catch { /* noop */ } });
}

export function onTTSChange(fn: (v: boolean) => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

function synth(): SpeechSynthesis | null {
  if (typeof window === 'undefined') return null;
  return window.speechSynthesis ?? null;
}

const PREFERRED_VOICES = [
  'Google UK English Male',
  'Google US English',
  'Samantha',
  'Daniel',
  'Alex',
  'Microsoft David',
  'Microsoft Mark',
  'Microsoft Zira',
];

function pickVoice(): SpeechSynthesisVoice | null {
  const s = synth();
  if (!s) return null;
  const voices = s.getVoices();
  if (voices.length === 0) return null;
  for (const name of PREFERRED_VOICES) {
    const v = voices.find(v => v.name === name);
    if (v) return v;
  }
  for (const name of PREFERRED_VOICES) {
    const v = voices.find(v => v.name.includes(name));
    if (v) return v;
  }
  return voices.find(v => v.lang.startsWith('en')) ?? voices[0];
}

let voicesWarmed = false;
function warmVoices(): void {
  if (voicesWarmed) return;
  const s = synth();
  if (!s) return;
  s.getVoices();
  s.onvoiceschanged = () => { /* triggers re-fetch on next pickVoice */ };
  voicesWarmed = true;
}

export function speak(text: string, mood: TTSMood = 'neutral', retries = 4): void {
  if (!isTTSEnabled()) return;
  const s = synth();
  if (!s || !text) return;
  warmVoices();
  const voices = s.getVoices();
  if (voices.length === 0 && retries > 0) {
    window.setTimeout(() => speak(text, mood, retries - 1), 120);
    return;
  }
  try {
    s.cancel();
    const u = new SpeechSynthesisUtterance(text);
    const v = pickVoice();
    if (v) u.voice = v;
    u.rate = RATE[mood] ?? 1.0;
    u.pitch = PITCH[mood] ?? 1.0;
    u.volume = 1;
    s.speak(u);
  } catch { /* noop */ }
}

export function stopSpeaking(): void {
  try { synth()?.cancel(); } catch { /* noop */ }
}
TS_EOF

# ============================================================ 2/4 — Voice
cat > src/lib/coachVoice.ts <<'TS_EOF'
// src/lib/coachVoice.ts
//
// The coach's script. Two functions:
//   coachLine(ctx)        — reaction to the user's last move
//   opponentComment(ctx)  — occasional aside after the engine replies
//
// Everything is seeded (no Math.random) so a given move always says the same
// thing across re-renders, and the phrasing is picked from generous pools so
// repeated games don't feel canned.

import { Chess } from 'chess.js';
import type { TTSMood } from './coachTTS';

export type CoachMood = TTSMood;

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
  lastOpponentSan?: string;
  moveCount?: number;
}

const PIECE_NAMES: Record<string, string> = {
  p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king',
};
const PIECE_VALUE: Record<string, number> = { p: 1, n: 3, b: 3, r: 5, q: 9 };

function pieceNameFromSan(san: string): string | null {
  if (!san) return null;
  if (san.startsWith('O-O')) return 'king';
  const c = san[0];
  if (c >= 'A' && c <= 'Z') return PIECE_NAMES[c.toLowerCase()] ?? null;
  return 'pawn';
}

function targetSquareFromSan(san: string): string | null {
  if (!san || san.startsWith('O-O')) return null;
  const m = san.match(/[a-h][1-8]/g);
  return m ? m[m.length - 1] : null;
}

function getAttackers(game: Chess, sq: string, color: 'w' | 'b'): string[] {
  const any = game as unknown as { attackers?: (s: string, c: 'w' | 'b') => string[] | undefined };
  return typeof any.attackers === 'function' ? any.attackers(sq, color) ?? [] : [];
}

function isPieceHanging(fen: string, sq: string, moverColor: 'w' | 'b'): boolean {
  try {
    const g = new Chess(fen);
    const opp = moverColor === 'w' ? 'b' : 'w';
    return getAttackers(g, sq, opp).length > 0 && getAttackers(g, sq, moverColor).length === 0;
  } catch { return false; }
}

function materialDiff(fen: string, forColor: 'w' | 'b'): number {
  const board = fen.split(' ')[0] ?? '';
  let diff = 0;
  for (const ch of board) {
    const v = PIECE_VALUE[ch.toLowerCase()];
    if (v === undefined) continue;
    diff += (ch === ch.toUpperCase() ? 1 : -1) * v;
  }
  return forColor === 'w' ? diff : -diff;
}

function describeBestMove(san: string): string {
  if (!san) return '';
  if (san.startsWith('O-O')) return ' — castling is the safe way';
  if (san.includes('=')) return ' — promoting';
  if (san.includes('#')) return ' — mating';
  if (san.includes('+')) return ' — with check';
  if (san.includes('x')) return ' — winning material';
  const c = san[0];
  if (c === 'N' || c === 'B') return ' — developing';
  if (c === 'Q') return ' — activating the queen';
  if (c === 'R') return ' — improving the rook';
  if (c === 'K') return ' — king safety first';
  return '';
}

function formatPawns(cp: number): string {
  const p = Math.round((Math.abs(cp) / 100) * 10) / 10;
  if (p < 0.1) return 'less than a pawn';
  return p === 1 ? 'a pawn' : `${p} pawns`;
}

function materialPhrase(diff: number): string {
  if (diff === 0) return '';
  const n = Math.abs(diff);
  if (n <= 1) return " You're basically level on material.";
  if (diff > 0) return ` You're up ${n} point${n === 1 ? '' : 's'} of material — good.`;
  return ` You're down ${n} point${n === 1 ? '' : 's'} — stay patient.`;
}

function phaseFlavor(moveCount: number): string {
  if (moveCount <= 6) return " Let's get these pieces out.";
  if (moveCount <= 20) return '';
  if (moveCount >= 35) return ' Endgame now — every tempo matters.';
  return '';
}

function hash(s: string): number {
  let h = 0;
  for (let i = 0; i < s.length; i++) h = ((h << 5) - h + s.charCodeAt(i)) | 0;
  return h;
}

function pick<T>(arr: T[], seed: number): T {
  return arr[Math.abs(seed) % arr.length];
}

// Occasionally prefix with a small exclamation, seeded so it's stable.
function quirk(seed: number, kinds: 'up' | 'down' | 'neutral'): string {
  if (hash('q' + seed) % 100 > 40) return '';
  if (kinds === 'up')   return pick(['Yes! ', 'Perfect. ', 'Boom. ', 'Nice. '], seed);
  if (kinds === 'down') return pick(['Oof. ', 'Oh no. ', 'Yikes. ', 'Hmm. '], seed + 7);
  return pick(['Alright. ', 'Hmm. ', 'Ok. '], seed + 13);
}

export function coachLine(ctx: CoachContext): CoachLine {
  const {
    classification, playedSan, bestSan, lossCp,
    fenBefore, fenAfter, isCheckmate, isDraw, userWon,
    lastOpponentSan, moveCount = 0,
  } = ctx;

  const seed = hash(playedSan + '|' + Math.round(lossCp));
  const moverColor = (fenBefore.split(' ')[1] as 'w' | 'b') || 'w';
  const material = materialDiff(fenAfter, moverColor);
  const matNote = materialPhrase(material);
  const phaseNote = phaseFlavor(moveCount);

  // --- Game over first. -----------------------------------------------------
  if (isCheckmate) {
    return userWon
      ? { text: `Checkmate! ${playedSan} — beautiful finish. Really well played.`, mood: 'excited', emoji: '🎉' }
      : { text: `Checkmate for your opponent. Tough game — let's analyse it together.`, mood: 'sad', emoji: '😔' };
  }
  if (isDraw) {
    return { text: 'A draw. You held your ground all the way — solid.', mood: 'neutral', emoji: '🤝' };
  }

  const piece = pieceNameFromSan(playedSan);
  const square = targetSquareFromSan(playedSan);
  const hanging = square ? isPieceHanging(fenAfter, square, moverColor) : false;
  const why = describeBestMove(bestSan);
  const gaveCheck = playedSan.includes('+') || playedSan.includes('#');
  const captured = playedSan.includes('x');
  const castled = playedSan.startsWith('O-O');
  const promoted = playedSan.includes('=');

  // --- Best / excellent -----------------------------------------------------
  if (classification === 'best' || classification === 'excellent' || classification === 'brilliant') {
    const q = quirk(seed, 'up');
    const pools = [
      [`${q}Perfect! ${playedSan} is exactly what I would play.`],
      [`${q}${playedSan} is the top engine choice — well spotted.`],
      [`${q}Brilliant find. ${playedSan} is the strongest move here.`],
      [`${q}That's the move. ${playedSan} — you're seeing the board clearly.`],
      [`${q}Now that's how you do it. ${playedSan} is best.`],
    ];
    let text = pick(pools, seed)[0];
    if (castled) text += " King safety first — always a good instinct.";
    else if (promoted) text += ' Promoting is huge.';
    else if (gaveCheck) text += ' Check adds pressure.';
    else if (captured) text += ' Winning material the right way.';
    text += matNote + phaseNote;
    return { text, mood: 'excited', emoji: '⭐' };
  }

  // --- Good ----------------------------------------------------------------
  if (classification === 'good' || classification === 'book') {
    const q = quirk(seed, 'up');
    const pools = [
      `${q}Good move. ${playedSan} keeps things solid.`,
      `${q}Nice — simple and strong.`,
      `${q}I like that. ${playedSan} is a sensible choice.`,
      `${q}Solid. Nothing flashy, but it does the job.`,
      `${q}Alright, that works. ${playedSan} is fine.`,
    ];
    let text = pick(pools, seed);
    if (castled) text += ' Castling was the right call.';
    text += matNote;
    return { text, mood: 'happy', emoji: '👍' };
  }

  // --- Hanging piece (supersedes blunder/mistake if it applies) -----------
  if (hanging && piece && square) {
    const q = quirk(seed, 'down');
    if (bestSan) {
      const pools = [
        `${q}Careful — your ${piece} on ${square} is hanging, nothing defends it. ${bestSan} was safer${why}.`,
        `${q}Wait — your ${piece} on ${square} is completely unprotected. ${bestSan} was the move${why}.`,
        `${q}Hmm, that ${piece} on ${square} is exposed. Try ${bestSan} instead${why}.`,
      ];
      return { text: pick(pools, seed) + matNote, mood: 'concerned', emoji: '⚠️' };
    }
    return {
      text: `Careful — your ${piece} on ${square} is hanging. Look for a move that defends it.${matNote}`,
      mood: 'concerned', emoji: '⚠️',
    };
  }

  // --- Blunder -------------------------------------------------------------
  if (classification === 'blunder') {
    const q = quirk(seed, 'down');
    if (bestSan) {
      const pools = [
        `${q}That's a blunder. ${playedSan} loses about ${formatPawns(lossCp)}. ${bestSan} was the move${why}.`,
        `${q}Ouch, ${playedSan} drops ${formatPawns(lossCp)}. I'd have played ${bestSan}${why}.`,
        `${q}Big mistake. ${bestSan} would have kept you in the game${why}.`,
        `${q}That one hurts — ${playedSan} costs ${formatPawns(lossCp)}. ${bestSan} was much better${why}.`,
      ];
      let text = pick(pools, seed) + matNote;
      if (material < -2) text += ' Still, keep fighting — games swing.';
      return { text, mood: 'sad', emoji: '😬' };
    }
    return {
      text: `That's a blunder — ${playedSan} loses about ${formatPawns(lossCp)}. There was a much better option here.${matNote}`,
      mood: 'sad', emoji: '😬',
    };
  }

  // --- Mistake -------------------------------------------------------------
  if (classification === 'mistake') {
    const q = quirk(seed, 'down');
    if (bestSan) {
      const pools = [
        `${q}Hmm, ${playedSan} is a mistake — it costs ${formatPawns(lossCp)}. ${bestSan} was better${why}.`,
        `${q}Not quite. ${playedSan} lets your opponent back in. ${bestSan} holds the position${why}.`,
        `${q}Careful — ${playedSan} drops ${formatPawns(lossCp)}. Try ${bestSan} next time${why}.`,
      ];
      return { text: pick(pools, seed) + matNote, mood: 'concerned', emoji: '😕' };
    }
    return {
      text: `Hmm, ${playedSan} is a mistake — it costs ${formatPawns(lossCp)}. There was a stronger move.${matNote}`,
      mood: 'concerned', emoji: '😕',
    };
  }

  // --- Inaccuracy or fallback ---------------------------------------------
  const q = quirk(seed, 'neutral');
  if (bestSan) {
    const pools = [
      `${q}A bit loose. ${playedSan} isn't bad, but ${bestSan} was cleaner${why}.`,
      `${q}Small inaccuracy. ${bestSan} would have kept more of your advantage${why}.`,
      `${q}Not a disaster — but ${bestSan} was slightly better${why}.`,
      `${q}Close. I would have nudged towards ${bestSan}${why}.`,
    ];
    return { text: pick(pools, seed) + matNote, mood: 'neutral', emoji: '🤔' };
  }
  let note = lastOpponentSan ? ` Their ${pieceNameFromSan(lastOpponentSan) ?? 'last'} move was worth answering, though.` : '';
  return {
    text: `${q}${playedSan} is a little loose — there was a slightly better move.${note}`,
    mood: 'neutral', emoji: '🤔',
  };
}

export function openingLine(): CoachLine {
  const lines = [
    "Alright, let's see what you've got. Take your time.",
    "Good luck! I'll be right here watching.",
    'Ready when you are. Think it through.',
    "New game. Let's make it a good one.",
  ];
  return { text: pick(lines, Date.now()), mood: 'happy', emoji: '♟️' };
}

// Occasional aside after the engine's reply. Returns null most of the time;
// only fires for genuinely notable events. Never replaces the user-feedback
// line — the caller displays it as a small secondary note.
export function opponentComment(ctx: {
  san: string;
  fenBefore: string;
  fenAfter: string;
  userColor: 'w' | 'b';
}): string | null {
  const { san, fenAfter } = ctx;
  const game = new Chess(fenAfter);
  const inCheck = game.inCheck();

  if (inCheck) {
    return pick(
      ['Careful — you\'re in check now.', 'Check — find a safe square for your king.', 'You\'re in check, respond carefully.'],
      hash(san) + 1,
    );
  }
  if (san.includes('#')) {
    return 'That\'s checkmate for them.';
  }
  if (san.startsWith('O-O')) {
    return 'They castled — their king is safe now.';
  }
  if (san.includes('=')) {
    return 'They promoted. That\'s dangerous.';
  }
  if (san.includes('x')) {
    const sq = targetSquareFromSan(san);
    const piece = pieceNameFromSan(san);
    return pick(
      [
        `They captured on ${sq}. Consider trading back if it helps.`,
        `Trade on ${sq} — check if you should recapture.`,
        `Their ${piece} took on ${sq}. Stay alert.`,
      ],
      hash(san) + 2,
    );
  }
  if (hash(san) % 100 < 20) {
    const piece = pieceNameFromSan(san);
    return `They played ${san}. Anything that ${piece ?? 'piece'} is attacking?`;
  }
  return null;
}
TS_EOF

# ============================================================ 3/4 — Bubble
cat > src/components/CoachBubble.tsx <<'TSX_EOF'
// src/components/CoachBubble.tsx
import { useEffect, useState } from 'react';
import { Bot, Volume2, VolumeX } from 'lucide-react';
import type { CoachLine, CoachMood } from '../lib/coachVoice';
import { isTTSEnabled, setTTSEnabled, onTTSChange } from '../lib/coachTTS';

interface Props {
  line: CoachLine | null;
  thinking?: boolean;
  aside?: string | null;
  className?: string;
}

const MOOD_STYLES: Record<CoachMood, { bubble: string; avatar: string }> = {
  happy:     { bubble: 'border-emerald-500/40 bg-emerald-500/10', avatar: 'from-emerald-400 to-emerald-600' },
  excited:   { bubble: 'border-lime-400/50 bg-lime-500/10',       avatar: 'from-lime-300 to-lime-500' },
  neutral:   { bubble: 'border-slate-500/30 bg-slate-500/10',     avatar: 'from-slate-400 to-slate-600' },
  concerned: { bubble: 'border-amber-500/40 bg-amber-500/10',     avatar: 'from-amber-400 to-amber-600' },
  sad:       { bubble: 'border-rose-500/40 bg-rose-500/10',       avatar: 'from-rose-400 to-rose-600' },
};

export function CoachBubble({ line, thinking = false, aside = null, className = '' }: Props) {
  const [shown, setShown] = useState('');
  const [ttsOn, setTtsOnState] = useState(() => isTTSEnabled());

  useEffect(() => onTTSChange(setTtsOnState), []);

  useEffect(() => {
    const text = line?.text ?? '';
    if (!text) { setShown(''); return; }
    setShown('');
    let i = 0;
    const timer = window.setInterval(() => {
      i += 1;
      setShown(text.slice(0, i));
      if (i >= text.length) window.clearInterval(timer);
    }, 14);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [line?.text]);

  const style = MOOD_STYLES[line?.mood ?? 'neutral'];
  const done = line ? shown.length >= line.text.length : true;
  const typing = !!line && !done;

  return (
    <div className={`flex flex-col gap-1.5 ${className}`}>
      <div key={line?.text ?? 'empty'} className="flex items-start gap-3 animate-[coachPop_180ms_ease-out]">
        <div
          className={`relative flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-gradient-to-br ${style.avatar} text-xl shadow-lg ring-2 ring-white/10 ${typing ? 'coachPulse' : ''}`}
        >
          {thinking ? <Bot className="h-5 w-5 animate-pulse text-black/80" /> : (line?.emoji ?? '♟️')}
        </div>
        <div className={`relative min-w-0 flex-1 rounded-2xl border ${style.bubble} px-4 py-3 pr-10 shadow-md`}>
          <div className={`absolute -left-2 top-4 h-3 w-3 rotate-45 border-b border-l ${style.bubble}`} />
          <button
            type="button"
            onClick={() => setTTSEnabled(!ttsOn)}
            title={ttsOn ? 'Mute coach voice' : 'Enable coach voice'}
            aria-label={ttsOn ? 'Mute coach voice' : 'Enable coach voice'}
            className={`absolute right-2 top-2 rounded-md p-1 transition-colors ${
              ttsOn ? 'text-lime hover:bg-lime/10' : 'text-slate-500 hover:bg-slate-500/10'
            } ${typing && ttsOn ? 'coachWave' : ''}`}
          >
            {ttsOn ? <Volume2 className="h-4 w-4" /> : <VolumeX className="h-4 w-4" />}
          </button>
          {thinking ? (
            <p className="text-sm italic text-slate-300">Coach is thinking…</p>
          ) : line ? (
            <p className="text-sm leading-relaxed text-slate-100">
              {shown}
              {!done && <span className="animate-pulse">▍</span>}
            </p>
          ) : (
            <p className="text-sm italic text-slate-400">Play a move to hear from your coach.</p>
          )}
        </div>
      </div>

      {aside && !thinking && (
        <p className="pl-14 text-xs italic text-slate-500">{aside}</p>
      )}

      <style>{`
        @keyframes coachPop {
          from { opacity: 0; transform: translateY(4px) scale(0.98); }
          to   { opacity: 1; transform: translateY(0) scale(1); }
        }
        @keyframes coachPulse {
          0%, 100% { box-shadow: 0 0 0 0 rgba(163, 230, 53, 0.35); }
          50%      { box-shadow: 0 0 0 6px rgba(163, 230, 53, 0.0); }
        }
        .coachPulse { animation: coachPulse 1.4s ease-out infinite; }
        .coachWave   { animation: coachPulse 1s ease-out infinite; }
      `}</style>
    </div>
  );
}
TSX_EOF

# ============================================================ 4/4 — PlayCoach
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
import {
  coachLine, openingLine, opponentComment,
  type CoachLine,
} from '../lib/coachVoice';
import { speak, stopSpeaking } from '../lib/coachTTS';

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
  } catch { return null; }
}

function sayLine(line: CoachLine | null) {
  if (!line) return;
  speak(line.text, line.mood);
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
  const [aside, setAside] = useState<string | null>(null);
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

  useEffect(() => () => stopSpeaking(), []);

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
      try { rebuilt.move(t.san); }
      catch { setEngineError(`Could not replay move ${t.ply}: ${t.san}`); return null; }
    }
    if (rebuilt.history().length === 0) return null;

    const plies = rebuilt.history().length;
    const result = rebuilt.isCheckmate()
      ? (rebuilt.turn() === 'w' ? '0-1' : '1-0')
      : rebuilt.isDraw() ? '1/2-1/2' : '*';

    const today = new Date().toISOString().slice(0, 10).replace(/-/g, '.');
    rebuilt.header(
      'Event', 'Coaching game', 'Site', 'chess-supercoach', 'Date', today,
      'White', 'You', 'Black', 'Coach', 'Result', result, 'PlyCount', String(plies)
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
    if (!id) { setSaveMsg('Nothing to save yet — play at least one move.'); return; }
    window.location.hash = `#analysis?gameId=${encodeURIComponent(id)}`;
  }

  async function playEngineMove(c: Chess): Promise<void> {
    setThinking('Coach is thinking...');
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      const idx = Math.max(0, Math.min(DIFFICULTIES.length - 1, difficultyRef.current));
      const playDepth = DIFFICULTIES[idx].playDepth;
      const fenBeforeEngine = c.fen();

      const res = await engine.evaluate(fenBeforeEngine, playDepth, ctrl.signal);
      const uci = res.bestMove;
      if (!uci || !UCI_MOVE.test(uci)) return;

      const c2 = new Chess(fenBeforeEngine);
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

      // Occasional aside about the engine's reply.
      const note = opponentComment({
        san: played.san,
        fenBefore: fenBeforeEngine,
        fenAfter: fenAfterEngine,
        userColor: userColorRef.current,
      });
      setAside(note);
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
    try { mv = c.move({ from, to, promotion: 'q' }); }
    catch { return false; }
    if (!mv) return false;

    setGame(c);
    setFeedback(null);
    setAside(null);
    setThinking('Analysing your move...');

    const ctrl = new AbortController();
    abortRef.current = ctrl;

    try {
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

      const userTurns = turns.filter(t => t.isUser).length + 1;
      const lastOpponentSan = [...turns].reverse().find(t => !t.isUser)?.san;

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

      const isCheckmate = c.isCheckmate();
      const userWon = isCheckmate && c.turn() !== userColorRef.current;
      const line = coachLine({
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
        userWon,
        lastOpponentSan,
        moveCount: userTurns,
      });
      setCoach(line);
      sayLine(line);

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
    stopSpeaking();
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setAside(null);
    setThinking(null);
    setEngineError(null);
    const greet = openingLine();
    setCoach(greet);
    sayLine(greet);
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
    stopSpeaking();
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setAside(null);
    setThinking(null);
    setEngineError(null);
    const greet = openingLine();
    setCoach(greet);
    sayLine(greet);
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
              plays its own moves. Finished games are saved automatically. Use the speaker icon
              on the coach to toggle voice.
            </p>
          </div>

          <CoachBubble
            line={thinking ? null : coach}
            thinking={!!thinking}
            aside={thinking ? null : aside}
          />

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

echo "Wrote 4 files:"
echo "  src/lib/coachTTS.ts        (NEW)"
echo "  src/lib/coachVoice.ts      (rewritten)"
echo "  src/components/CoachBubble.tsx  (mute toggle + animations)"
echo "  src/pages/PlayCoach.tsx    (TTS wired, richer context)"
echo
echo "Next: cd $ROOT && npm run typecheck && npm run dev"