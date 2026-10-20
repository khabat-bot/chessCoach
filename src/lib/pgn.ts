import { Chess } from 'chess.js';
import type { GameRecord } from '../types';

export class PgnError extends Error {}

export function uid(): string {
  return Math.random().toString(36).slice(2) + Date.now().toString(36);
}

export function parsePgn(pgn: string): GameRecord {
  const trimmed = pgn.trim();
  if (!trimmed) throw new PgnError('PGN is empty.');

  const game = new Chess();
  try {
    game.loadPgn(trimmed);
  } catch (e) {
    throw new PgnError('Could not parse PGN: ' + (e as Error).message);
  }

  const history = game.history();
  if (history.length === 0) throw new PgnError('PGN contains no moves.');

  const headers = game.header() as Record<string, string>;

  return {
    id: uid(),
    pgn: trimmed,
    white: headers.White,
    black: headers.Black,
    result: headers.Result,
    event: headers.Event,
    date: headers.Date,
    createdAt: Date.now(),
    plies: history.length,
    status: 'none'
  };
}

export function fenAtPly(pgn: string, ply: number): string {
  const game = new Chess();
  game.loadPgn(pgn);
  const moves = game.history({ verbose: true });
  const g = new Chess();
  for (let i = 0; i < Math.min(ply, moves.length); i++) {
    g.move(moves[i].san);
  }
  return g.fen();
}

export function isValidFen(fen: string): boolean {
  try {
    new Chess(fen);
    return true;
  } catch {
    return false;
  }
}
