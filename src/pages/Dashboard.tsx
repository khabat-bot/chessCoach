import { useEffect, useState } from 'react';
import { LineChart, Line, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts';
import { listGames, allAnalyses, allTrainingItems } from '../storage/db';
import { accuracyFromAcpl } from '../lib/eval';
import type { GameRecord, GameAnalysis, TrainingItem } from '../types';

function headerField(pgn: string | undefined, name: string): string | null {
  if (!pgn) return null;
  const m = pgn.match(new RegExp(`\\[${name} "([^"]*)"\\]`));
  if (!m) return null;
  const v = m[1].trim();
  return v && v !== '?' ? v : null;
}

export function Dashboard() {
  const [games, setGames] = useState<GameRecord[]>([]);
  const [analyses, setAnalyses] = useState<GameAnalysis[]>([]);
  const [training, setTraining] = useState<TrainingItem[]>([]);

  useEffect(() => {
    (async () => {
      setGames(await listGames());
      setAnalyses(await allAnalyses());
      setTraining(await allTrainingItems());
    })();
  }, []);

  const analysed = analyses.filter((a) => a.complete);
  const allMoves = analysed.flatMap((a) => a.moves).filter((m) => m.loss !== null);
  const acpl = allMoves.length
    ? allMoves.reduce((s, m) => s + (m.loss ?? 0), 0) / allMoves.length
    : null;

  const solved = training.reduce((s, t) => s + t.successes, 0);
  const attempts = training.reduce((s, t) => s + t.attempts, 0);

  const counts = { blunder: 0, mistake: 0, inaccuracy: 0 };
  for (const a of analysed) for (const m of a.moves) {
    if (m.classification === 'blunder') counts.blunder++;
    else if (m.classification === 'mistake') counts.mistake++;
    else if (m.classification === 'inaccuracy') counts.inaccuracy++;
  }

  const trend = analysed
    .slice()
    .sort((a, b) => a.updatedAt - b.updatedAt)
    .map((a, i) => {
      const losses = a.moves.map((m) => m.loss).filter((l): l is number => l !== null);
      const a2 = losses.length ? losses.reduce((x, y) => x + y, 0) / losses.length : 0;
      return { name: `#${i + 1}`, accuracy: Number(accuracyFromAcpl(a2).toFixed(1)) };
    });

  const recent = games
    .slice()
    .sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0))
    .slice(0, 6);

  const empty = games.length === 0;

  return (
    <div className="max-w-6xl space-y-6">
      <header>
        <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
        <p className="text-sm text-slate-400 mt-1">
          Every number below is computed from data stored on this device.
        </p>
      </header>

      {empty && (
        <div className="rounded-xl border border-ink-600 bg-ink-800 p-6">
          <h2 className="font-medium">No games yet</h2>
          <p className="text-sm text-slate-400 mt-1">
            Import a PGN on the Analysis page to start building your training data.
          </p>
          <a href="#analysis" className="inline-block mt-3 rounded-lg bg-lime text-ink-900 font-medium px-4 py-2 text-sm">
            Import a game
          </a>
        </div>
      )}

      <div className="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <Stat label="Games stored" value={games.length} />
        <Stat label="Games analysed" value={analysed.length} />
        <Stat label="Training accuracy" value={attempts ? `${Math.round((solved / attempts) * 100)}%` : '—'} />
        <Stat label="Puzzles solved" value={solved} />
      </div>

      <div className="grid lg:grid-cols-3 gap-4">
        <section className="lg:col-span-2 rounded-xl border border-ink-600 bg-ink-800 p-4">
          <h2 className="font-medium mb-3">Accuracy trend</h2>
          {trend.length < 2 ? (
            <p className="text-sm text-slate-500">Analyse at least two games to see a trend.</p>
          ) : (
            <div className="h-56">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart data={trend}>
                  <CartesianGrid stroke="#222c28" />
                  <XAxis dataKey="name" stroke="#64748b" fontSize={12} />
                  <YAxis domain={[0, 100]} stroke="#64748b" fontSize={12} />
                  <Tooltip contentStyle={{ background: '#111715', border: '1px solid #222c28' }} />
                  <Line type="monotone" dataKey="accuracy" stroke="#7ef29d" strokeWidth={2} dot={false} />
                </LineChart>
              </ResponsiveContainer>
            </div>
          )}
        </section>

        <section className="rounded-xl border border-ink-600 bg-ink-800 p-4">
          <h2 className="font-medium mb-3">Mistake mix</h2>
          <Bar label="Inaccuracies" n={counts.inaccuracy} total={allMoves.length} color="bg-amber-400" />
          <Bar label="Mistakes" n={counts.mistake} total={allMoves.length} color="bg-orange-500" />
          <Bar label="Blunders" n={counts.blunder} total={allMoves.length} color="bg-rose-500" />
          {allMoves.length === 0 && <p className="text-sm text-slate-500 mt-2">No analysed moves yet.</p>}
        </section>
      </div>

      <section className="rounded-xl border border-ink-600 bg-ink-800 p-4">
        <div className="flex items-center justify-between mb-3">
          <h2 className="font-medium">Recent games</h2>
          <a href="#analysis" className="text-xs text-slate-400 hover:text-lime">
            see all →
          </a>
        </div>
        {recent.length === 0 ? (
          <p className="text-sm text-slate-500">Nothing here yet.</p>
        ) : (
          <ul className="divide-y divide-ink-600">
            {recent.map((g) => {
              const white = g.white ?? headerField(g.pgn, 'White') ?? 'White';
              const black = g.black ?? headerField(g.pgn, 'Black') ?? 'Black';
              const result = g.result ?? headerField(g.pgn, 'Result') ?? '';
              const date = g.createdAt
                ? new Date(g.createdAt).toLocaleDateString(undefined, { month: 'short', day: 'numeric' })
                : '';
              return (
                <li key={g.id}>
                  <a
                    href={`#analysis?gameId=${encodeURIComponent(g.id)}`}
                    className="py-2 flex items-center justify-between gap-4 text-sm -mx-2 px-2 rounded hover:bg-ink-700/50 transition-colors">
                    <span className="truncate">
                      {white} vs {black}
                      {result ? ` · ${result}` : ''}
                      {g.plies ? <span className="text-slate-500"> · {g.plies} plies</span> : null}
                    </span>
                    <span className="shrink-0 flex items-center gap-2">
                      {date && <span className="text-xs text-slate-500 tabular-nums">{date}</span>}
                      <span className={`text-xs px-2 py-0.5 rounded-full ${
                        g.status === 'complete' ? 'bg-lime/10 text-lime' : 'bg-ink-700 text-slate-400'}`}>
                        {g.status}
                      </span>
                    </span>
                  </a>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-xl border border-ink-600 bg-ink-800 p-4">
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className="text-2xl font-semibold mt-1">{value}</div>
    </div>
  );
}

function Bar({ label, n, total, color }: { label: string; n: number; total: number; color: string }) {
  const pct = total ? Math.round((n / total) * 100) : 0;
  return (
    <div className="mb-3">
      <div className="flex justify-between text-xs text-slate-400 mb-1">
        <span>{label}</span><span>{n}</span>
      </div>
      <div className="h-2 rounded-full bg-ink-700 overflow-hidden">
        <div className={`h-full ${color}`} style={{ width: `${pct}%` }} />
      </div>
    </div>
  );
}
