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
