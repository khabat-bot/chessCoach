import { useEffect, useState } from 'react';
import { allTrainingItems, getPrefs } from '../storage/db';
import type { TrainingItem } from '../types';

export function Plan() {
  const [items, setItems] = useState<TrainingItem[]>([]);
  const [minutes, setMinutes] = useState(10);

  useEffect(() => {
    (async () => {
      const prefs = await getPrefs();
      setMinutes(prefs.sessionMinutes);
      setItems(await allTrainingItems());
    })();
  }, []);

  const now = Date.now();
  const scored = items
    .map((t) => {
      const overdueDays = Math.max(0, (now - t.dueAt) / 86_400_000);
      const severity = Math.min(t.loss, 1000) / 1000;
      const failRate = t.attempts ? 1 - t.successes / t.attempts : 0.5;
      const score = severity * 3 + Math.min(overdueDays, 14) * 0.3 + failRate * 2 + t.loss / 2000;
      return { t, score };
    })
    .sort((a, b) => b.score - a.score);

  const session = scored.slice(0, minutes);

  const byCategory = new Map<string, number>();
  for (const { t } of session) byCategory.set(t.category, (byCategory.get(t.category) ?? 0) + 1);

  return (
    <div className="max-w-3xl space-y-4">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight">Training plan</h1>
        <p className="text-sm text-slate-400 mt-1">
          Deterministic ordering by severity, recurrence, staleness and past failures.
          Classifications are engine-derived heuristics, not psychological profiling.
        </p>
      </header>

      <div className="flex flex-wrap gap-2">
        {[5, 10, 15, 30].map((m) => (
          <button key={m} onClick={() => setMinutes(m)}
            className={`px-3 py-1.5 rounded-lg text-sm border ${
              minutes === m ? 'border-lime bg-lime/10 text-lime' : 'border-ink-600 text-slate-400'}`}>
            {m} min
          </button>
        ))}
      </div>

      {items.length === 0 ? (
        <p className="text-sm text-slate-500">
          No training items yet. Analyse a game and mistakes will be collected automatically.
        </p>
      ) : (
        <>
          <div className="rounded-xl border border-ink-600 bg-ink-800 p-4 text-sm">
            <div className="flex justify-between">
              <span className="text-slate-400">Session length</span>
              <span>{session.length} position{session.length === 1 ? '' : 's'}</span>
            </div>
            <div className="mt-2 flex flex-wrap gap-2 text-xs">
              {[...byCategory.entries()].map(([c, n]) => (
                <span key={c} className="px-2 py-0.5 rounded-full bg-ink-700 text-slate-300">{c}: {n}</span>
              ))}
            </div>
          </div>

          <ol className="rounded-xl border border-ink-600 bg-ink-800 divide-y divide-ink-600">
            {session.map(({ t }) => (
              <li key={t.id} className="p-3 text-sm flex items-center justify-between gap-3">
                <span className="truncate">
                  Move {Math.ceil(t.ply / 2)} · {t.playedSan} → best {t.bestSan}
                </span>
                <span className="text-xs text-slate-500 shrink-0">
                  -{(t.loss / 100).toFixed(2)}
                </span>
              </li>
            ))}
          </ol>

          <a href="#training" className="inline-block rounded-lg bg-lime text-ink-900 font-medium px-4 py-2 text-sm">
            Start session
          </a>
        </>
      )}
    </div>
  );
}
