import { Chess } from 'chess.js';
import type { GameAnalysis, GameRecord, MoveEval } from './types';
import type { StockfishEngine } from './engine/stockfish';
import { classify, evalLoss, toCentipawns } from './lib/eval';

export interface RunOptions {
  depth: number;
  existingMoves?: MoveEval[];
  onProgress: (done: number, total: number, partial: MoveEval[]) => void;
  signal: AbortSignal;
}

const UCI_MOVE = /^[a-h][1-8][a-h][1-8][qrbn]?$/;

/**
 * Two-search pipeline per ply:
 *   1. evaluate the position BEFORE the move (side-to-move POV)
 *   2. play the move, evaluate the resulting position (opponent POV)
 * Loss = eval(before, mover POV) - eval(after, mover POV), floored at 0.
 */
export async function runAnalysis(
  game: GameRecord,
  engine: StockfishEngine,
  opts: RunOptions
): Promise<GameAnalysis> {
  const chess = new Chess();
  chess.loadPgn(game.pgn);
  const verbose = chess.history({ verbose: true });
  const total = verbose.length;
  const moves: MoveEval[] = [...(opts.existingMoves ?? [])];
  const startFrom = moves.length;
  const replay = new Chess();

  // Advance the replay board to where we're resuming.
  for (let i = 0; i < startFrom; i++) replay.move(verbose[i].san);

  for (let i = startFrom; i < total; i++) {
    if (opts.signal.aborted) break;

    const fenBefore = replay.fen();
    const turn = replay.turn();
    const mv = verbose[i];

    const beforeRes = await engine.evaluate(fenBefore, opts.depth, opts.signal);
    // UCI scores are always side-to-move POV. Before the move, mover IS side-to-move.
    const beforeCpMover = toCentipawns(beforeRes.raw);

    replay.move(mv.san);
    const fenAfter = replay.fen();
    const afterRes = await engine.evaluate(fenAfter, opts.depth, opts.signal);
    // After the move, side-to-move is the OPPONENT of the mover, so negate.
    const afterCpOpp = toCentipawns(afterRes.raw);
    const afterCpMover = afterCpOpp === null ? null : -afterCpOpp;

    const loss = evalLoss(beforeCpMover, afterCpMover);
    const bestUci = beforeRes.bestMove ?? '';
    const playedUci = mv.from + mv.to + (mv.promotion ?? '');
    const isBest = UCI_MOVE.test(bestUci) && bestUci === playedUci;

    let bestSan: string | undefined;
    if (UCI_MOVE.test(bestUci)) {
      const probe = new Chess(fenBefore);
      try {
        const m = probe.move({
          from: bestUci.slice(0, 2),
          to: bestUci.slice(2, 4),
          promotion: bestUci.slice(4, 5) || undefined
        });
        bestSan = m?.san;
      } catch { /* ignore */ }
    }

    // Store evals in White POV (so the UI eval bar can use them directly).
    const beforeCpWhite = beforeCpMover === null ? null : (turn === 'w' ? beforeCpMover : -beforeCpMover);
    const afterCpWhite  = afterCpMover  === null ? null : (turn === 'w' ? afterCpMover  : -afterCpMover);

    moves.push({
      ply: i + 1,
      fenBefore,
      fenAfter,
      san: mv.san,
      beforeCp: beforeCpWhite,
      afterCp: afterCpWhite,
      loss,
      classification: classify(loss, isBest),
      bestSan,
      bestPv: beforeRes.pv,
      depth: beforeRes.depth
    });

    opts.onProgress(moves.length, total, moves);
  }

  return {
    gameId: game.id,
    depth: opts.depth,
    moves,
    updatedAt: Date.now(),
    complete: moves.length === total
  };
}
