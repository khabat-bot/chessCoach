export type Classification =
  | 'best' | 'good' | 'inaccuracy' | 'mistake' | 'blunder' | 'unknown';

export interface GameRecord {
  id: string;
  pgn: string;
  white?: string;
  black?: string;
  result?: string;
  event?: string;
  date?: string;
  createdAt: number;
  plies: number;
  status: 'none' | 'partial' | 'complete';
}

export interface MoveEval {
  ply: number;
  fenBefore: string;
  fenAfter: string;
  san: string;
  /** Evaluation BEFORE the move, from WHITE's point of view (centipawns). */
  beforeCp: number | null;
  /** Evaluation AFTER the move, from WHITE's point of view (centipawns). */
  afterCp: number | null;
  /** Centipawn loss for the player who moved. Always >= 0. */
  loss: number | null;
  classification: Classification;
  bestSan?: string;
  bestPv?: string[];
  depth: number;
}

export interface GameAnalysis {
  gameId: string;
  depth: number;
  moves: MoveEval[];
  updatedAt: number;
  complete: boolean;
}

export interface TrainingItem {
  id: string;
  gameId: string;
  ply: number;
  fen: string;
  playedSan: string;
  bestSan: string;
  bestPv: string[];
  loss: number;
  category: string;
  createdAt: number;
  dueAt: number;
  ease: number;
  intervalDays: number;
  reps: number;
  lapses: number;
  attempts: number;
  successes: number;
}

export interface Prefs {
  key: 'prefs';
  orientation: 'white' | 'black';
  engineDepth: number;
  sessionMinutes: number;
  dailyTarget: number;
  sounds: boolean;
  animation: boolean;
  boardLight: string;
  boardDark: string;
}
