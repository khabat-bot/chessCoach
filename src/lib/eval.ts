import type { Classification } from '../types';

/** Mate scores are mapped into a large centipawn band so ordering is preserved. */
export const MATE = 10000;

export interface RawEval { scoreCp?: number; mate?: number }

/**
 * Convert a raw UCI score (which is ALWAYS from side-to-move's POV) into a
 * signed centipawn number in that same POV. Callers flip as needed.
 */
export function toCentipawns(e: RawEval): number | null {
  if (typeof e.mate === 'number') {
    return e.mate > 0 ? MATE - e.mate * 10 : -MATE - e.mate * 10;
  }
  if (typeof e.scoreCp === 'number') return e.scoreCp;
  return null;
}

/**
 * Convert between White POV and mover POV. Because the flip is its own inverse,
 * this works in both directions: pass a White-POV score with `turn` to get the
 * mover-POV score, or vice versa.
 */
export function flipForBlack(cp: number, turn: 'w' | 'b'): number {
  return turn === 'w' ? cp : -cp;
}

/** Centipawn loss for the player who moved. Never negative. */
export function evalLoss(beforeMoverCp: number | null, afterMoverCp: number | null): number | null {
  if (beforeMoverCp === null || afterMoverCp === null) return null;
  return Math.max(0, beforeMoverCp - afterMoverCp);
}

export interface Thresholds { inaccuracy: number; mistake: number; blunder: number }

/** Documented, configurable heuristics — not engine ground truth. */
export const DEFAULT_THRESHOLDS: Thresholds = { inaccuracy: 50, mistake: 100, blunder: 250 };

export function classify(
  loss: number | null,
  isEngineBest: boolean,
  t: Thresholds = DEFAULT_THRESHOLDS
): Classification {
  if (loss === null) return 'unknown';
  if (isEngineBest) return 'best';
  if (loss >= t.blunder) return 'blunder';
  if (loss >= t.mistake) return 'mistake';
  if (loss >= t.inaccuracy) return 'inaccuracy';
  return 'good';
}

/** Accuracy percentage from average centipawn loss (Lichess-style curve). */
export function accuracyFromAcpl(acpl: number): number {
  return Math.max(0, Math.min(100, 103.1668 * Math.exp(-0.04354 * acpl) - 3.1669));
}
