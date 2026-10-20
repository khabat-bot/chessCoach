export function EvalBar({ cp, mate }: { cp: number | null; mate: number | null }) {
  let whitePct = 50;
  if (mate !== null) whitePct = mate > 0 ? 100 : 0;
  else if (cp !== null) {
    const clamped = Math.max(-800, Math.min(800, cp));
    whitePct = 50 - (clamped / 800) * 50;
  }

  const label = mate !== null ? `M${Math.abs(mate)}` : cp !== null ? (cp / 100).toFixed(2) : '—';

  return (
    <div className="flex flex-col items-center gap-2">
      <div className="relative w-6 h-64 rounded-md overflow-hidden bg-ink-700 border border-ink-600">
        <div className="absolute inset-x-0 bottom-0 bg-slate-100 transition-all duration-300"
             style={{ height: `${whitePct}%` }} />
      </div>
      <span className="text-xs font-mono text-slate-400">{label}</span>
    </div>
  );
}
