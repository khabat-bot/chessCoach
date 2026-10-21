#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/chess/chess-supercoach"

cat > src/components/EvalBar.tsx <<'TSX_EOF'
// src/components/EvalBar.tsx
//
// Convention (single source of truth):
//   cp   — centipawns, WHITE POV. Positive = White winning. Negative = Black winning.
//   mate — mate in N, WHITE POV.   Positive = White mates.  Negative = Black mates.
//
// Rendering: black portion grows from the top, white from the bottom.
// Positive cp ⇒ white portion taller. Negative cp ⇒ black portion taller.

interface EvalBarProps {
  cp: number | null;
  mate: number | null;
}

export function EvalBar({ cp, mate }: EvalBarProps) {
  let whiteShare: number;
  if (mate !== null) {
    whiteShare = mate > 0 ? 1 : 0;
  } else if (cp === null) {
    whiteShare = 0.5;
  } else {
    const clamped = Math.max(-1200, Math.min(1200, cp));
    whiteShare = 1 / (1 + Math.exp(-clamped / 400));
  }

  const whitePct = Math.max(0, Math.min(100, Math.round(whiteShare * 100)));
  const blackPct = 100 - whitePct;

  const label =
    mate !== null
      ? mate > 0
        ? `M${mate}`
        : `−M${Math.abs(mate)}`
      : cp !== null
        ? cp >= 0
          ? `+${(cp / 100).toFixed(1)}`
          : `−${(Math.abs(cp) / 100).toFixed(1)}`
        : '?';

  return (
    <div
      className="self-stretch flex flex-col items-center gap-1 min-h-[300px] w-9 select-none"
      title={`Evaluation: ${label} (White POV)`}
    >
      <div className="text-[10px] text-slate-400 font-mono tabular-nums whitespace-nowrap">
        {label}
      </div>
      <div
        className="relative w-4 flex-1 rounded overflow-hidden border border-ink-600"
        role="img"
        aria-label={`Evaluation ${label}, White perspective`}
      >
        {/* Black portion — top */}
        <div
          className="absolute inset-x-0 top-0 bg-slate-900 transition-[height] duration-300"
          style={{ height: `${blackPct}%` }}
        />
        {/* White portion — bottom */}
        <div
          className="absolute inset-x-0 bottom-0 bg-slate-100 transition-[height] duration-300"
          style={{ height: `${whitePct}%` }}
        />
        {/* Faint centre line so "equal" is visually obvious */}
        <div className="absolute inset-x-0 top-1/2 h-px bg-rose-500/40 pointer-events-none" />
      </div>
    </div>
  );
}
TSX_EOF

echo "Wrote src/components/EvalBar.tsx"
echo "Next: npm run typecheck && npm run dev"