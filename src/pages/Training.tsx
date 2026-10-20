import { useEffect, useState } from 'react';
import { Chessboard } from 'react-chessboard';
import { Chess } from 'chess.js';
import { dueTrainingItems, updateTrainingItem } from '../storage/db';
import { review } from '../lib/spacedRepetition';
import type { TrainingItem } from '../types';

export function Training() {
  const [queue, setQueue] = useState<TrainingItem[]>([]);
  const [index, setIndex] = useState(0);
  const [feedback, setFeedback] = useState<null | { ok: boolean; text: string }>(null);
  const [loaded, setLoaded] = useState(false);

  useEffect(() => {
    (async () => {
      setQueue(await dueTrainingItems(20));
      setLoaded(true);
    })();
  }, []);

  const item = queue[index];

  if (!loaded) return <p className="text-slate-500">Loading...</p>;

  if (!item) {
    return (
      <div className="max-w-2xl">
        <h1 className="text-2xl font-semibold tracking-tight mb-2">Blunder training</h1>
        <p className="text-sm text-slate-400">
          Nothing is due. Positions are generated automatically when you analyse games and
          the engine flags mistakes or blunders.
        </p>
        <a href="#analysis" className="inline-block mt-4 rounded-lg bg-lime text-ink-900 font-medium px-4 py-2 text-sm">
          Analyse a game
        </a>
      </div>
    );
  }

  const game = new Chess(item.fen);

  function onDrop(source: string, target: string): boolean {
    if (feedback) return false;
    const probe = new Chess(item!.fen);
    let move;
    try {
      move = probe.move({ from: source, to: target, promotion: 'q' });
    } catch {
      return false;
    }
    if (!move) return false;

    const correct = move.san === item!.bestSan;
    setFeedback({
      ok: correct,
      text: correct
        ? `Correct - ${move.san} matches the engine's choice.`
        : `Not the engine's move. You played ${move.san}; best was ${item!.bestSan}.`
    });

    const grade: 0 | 2 = correct ? 2 : 0;
    const next: TrainingItem = {
      ...item!,
      ...review(
        {
          ease: item!.ease, intervalDays: item!.intervalDays, reps: item!.reps,
          lapses: item!.lapses, dueAt: item!.dueAt
        },
        grade
      ),
      attempts: item!.attempts + 1,
      successes: item!.successes + (correct ? 1 : 0)
    };
    void updateTrainingItem(next);
    return true;
  }

  function next() {
    setFeedback(null);
    setIndex((i) => i + 1);
  }

  return (
    <div className="max-w-4xl space-y-4">
      <header className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold tracking-tight">Blunder training</h1>
        <span className="text-sm text-slate-400">{index + 1} / {queue.length}</span>
      </header>

      <div className="grid md:grid-cols-[auto_1fr] gap-4">
        <div className="w-[min(82vw,420px)]">
          <Chessboard
            position={game.fen()}
            onPieceDrop={onDrop}
            boardOrientation={game.turn() === 'w' ? 'white' : 'black'}
            customDarkSquareStyle={{ backgroundColor: '#4f6f52' }}
            customLightSquareStyle={{ backgroundColor: '#e8eddf' }}
          />
        </div>

        <div className="space-y-3">
          <div className="rounded-xl border border-ink-600 bg-ink-800 p-4 text-sm space-y-2">
            <div className="text-xs uppercase tracking-wide text-slate-500">Position</div>
            <p className="text-slate-300">
              {game.turn() === 'w' ? 'White' : 'Black'} to move. In the original game the move
              played was <span className="font-mono">{item.playedSan}</span>, losing
              <span className="text-rose-300"> {(item.loss / 100).toFixed(2)}</span> pawns of evaluation.
            </p>
            <p className="text-xs text-slate-500">
              Category: {item.category} · reviews: {item.reps} · lapses: {item.lapses}
            </p>
          </div>

          {feedback && (
            <div className={`rounded-xl border p-4 text-sm ${
              feedback.ok ? 'border-lime/40 bg-lime/10 text-lime' : 'border-rose-500/40 bg-rose-500/10 text-rose-200'}`}>
              {feedback.text}
              {item.bestPv.length > 0 && (
                <div className="mt-2 text-xs font-mono text-slate-400 break-words">
                  Continuation: {item.bestPv.slice(0, 8).join(' ')}
                </div>
              )}
            </div>
          )}

          <div className="flex gap-2">
            <button onClick={next} disabled={!feedback}
              className="rounded-lg bg-lime text-ink-900 font-medium px-4 py-2 text-sm disabled:opacity-40">
              Next position
            </button>
            <button onClick={() => setIndex(queue.length)} className="rounded-lg border border-ink-600 px-4 py-2 text-sm">
              Finish session
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
