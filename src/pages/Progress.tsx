import { useEffect, useState } from 'react';
import { BarChart, Bar as RBar, XAxis, YAxis, Tooltip, ResponsiveContainer, CartesianGrid } from 'recharts';
import { allAnalyses, allTrainingItems } from '../storage/db';
import { accuracyFromAcpl } from '../lib/eval';
import type { GameAnalysis, TrainingItem } from '../types';

export function Progress() {
  const [analyses, setAnalyses] = useState<GameAnalysis[]>([]);
  const [training, setTraining] = useState<TrainingItem[]>([]);

  useEffect(() => {
    (async () => {
      setAnalyses(await allAnalyses());
      setTraining(await allTrainingItems());
    })();
  }, []);

  const dist = { inaccuracy: 0, mistake: 0, blunder: 0 };
  let totalMoves = 0;
  let totalLoss = 0;
  let lossCount = 0;
  for (const a of analyses) {
    for (const m of a.moves) {
      totalMoves++;
      if (m.loss !== null) { totalLoss += m.loss; lossCount++; }
      if (m.classification === 'inaccuracy') dist.inaccuracy++;
      else if (m.classification === 'mistake') dist.mistake++;
      else if (m.classification === 'blunder') dist.blunder++;
    }
  }

  const acpl = lossCount ? totalLoss / lossCount : null;
  const attempts = training.reduce((s, t) => s + t.attempts, 0);
  const successes = training.reduce((s, t) => s + t.successes, 0);

  const chart = [
    { name: 'Inaccuracy', n: dist.inaccuracy },
    { name: 'Mistake', n: dist.mistake },
    { name: 'Blunder', n: dist.blunder }
  ];

  return (
    <div className="max-w-4xl space-y-4">
      <h1 className="text-2xl font-semibold tracking-tight">Progress</h1>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        <Card label="Games analysed" value={analyses.filter((a) => a.complete).length} />
        <Card label="Avg centipawn loss" value={acpl === null ? '—' : Math.round(acpl)} />
        <Card label="Accuracy" value={acpl === null ? '—' : `${accuracyFromAcpl(acpl).toFixed(1)}%`} />
        <Card label="Training success" value={attempts ? `${Math.round((successes / attempts) * 100)}%` : '—'} />
      </div>

      <section className="rounded-xl border border-ink-600 bg-ink-800 p-4">
        <h2 className="font-medium mb-3">Mistake distribution ({totalMoves} moves)</h2>
        <div className="h-56">
          <ResponsiveContainer width="100%" height="100%">
            <BarChart data={chart}>
              <CartesianGrid stroke="#222c28" />
              <XAxis dataKey="name" stroke="#64748b" fontSize={12} />
              <YAxis stroke="#64748b" fontSize={12} allowDecimals={false} />
              <Tooltip contentStyle={{ background: '#111715', border: '1px solid #222c28' }} />
              <RBar dataKey="n" fill="#7ef29d" radius={[6, 6, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      </section>

      <section className="rounded-xl border border-ink-600 bg-ink-800 p-4 text-sm space-y-2">
        <h2 className="font-medium">How these numbers are derived</h2>
        <p className="text-slate-400">
          <strong>Centipawn loss</strong> is the difference between the engine's evaluation of the
          position before a move (from the mover's point of view) and the evaluation after the move
          was played. Mate scores are mapped into a ±10000 band so ordering is preserved.
        </p>
        <p className="text-slate-400">
          <strong>Accuracy</strong> uses the standard exponential curve
          <code className="mx-1 text-slate-300">103.1668*e^(-0.04354*acpl) - 3.1669</code>
          clipped to 0-100.
        </p>
        <p className="text-slate-400">
          <strong>Classification thresholds</strong> (configurable heuristics): inaccuracy &gt;= 50cp,
          mistake &gt;= 100cp, blunder &gt;= 250cp. A move matching the engine's top choice is always
          reported as <em>best</em>.
        </p>
      </section>
    </div>
  );
}

function Card({ label, value }: { label: string; value: string | number }) {
  return (
    <div className="rounded-xl border border-ink-600 bg-ink-800 p-4">
      <div className="text-xs uppercase tracking-wide text-slate-500">{label}</div>
      <div className="text-xl font-semibold mt-1">{value}</div>
    </div>
  );
}
