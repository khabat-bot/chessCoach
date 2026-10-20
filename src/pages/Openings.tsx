import { useState } from 'react';
import { Chessboard } from 'react-chessboard';
import { Chess } from 'chess.js';
import { OPENINGS } from '../lib/openings';

export function Openings() {
  const [selected, setSelected] = useState(0);
  const [step, setStep] = useState(0);
  const [feedback, setFeedback] = useState<string | null>(null);

  const line = OPENINGS[selected];

  function chessAt(n: number): Chess {
    const c = new Chess();
    for (let i = 0; i < n; i++) c.move(line.moves[i]);
    return c;
  }

  const game = chessAt(step);
  const expected = line.moves[step];

  function onDrop(source: string, target: string): boolean {
    if (step >= line.moves.length) return false;
    const probe = chessAt(step);
    let move;
    try { move = probe.move({ from: source, to: target, promotion: 'q' }); }
    catch { return false; }
    if (!move) return false;

    if (move.san === expected) {
      setFeedback('Correct.');
      setStep((s) => s + 1);
    } else {
      setFeedback(`That is legal, but the line plays ${expected}.`);
    }
    return true;
  }

  return (
    <div className="max-w-5xl space-y-4">
      <h1 className="text-2xl font-semibold tracking-tight">Opening practice</h1>
      <p className="text-sm text-slate-400">
        A small original set of common lines bundled offline. Moves are validated against
        the line, not merely against legality.
      </p>

      <div className="grid md:grid-cols-[220px_1fr] gap-4">
        <ul className="rounded-xl border border-ink-600 bg-ink-800 max-h-80 overflow-y-auto">
          {OPENINGS.map((o, i) => (
            <li key={o.id}>
              <button
                onClick={() => { setSelected(i); setStep(0); setFeedback(null); }}
                className={`w-full text-left px-3 py-2 text-sm border-b border-ink-600 last:border-0 ${
                  i === selected ? 'bg-lime/10 text-lime' : 'hover:bg-ink-700'}`}>
                {o.name}
                <span className="block text-xs text-slate-500">{o.eco}</span>
              </button>
            </li>
          ))}
        </ul>

        <div className="grid sm:grid-cols-[auto_1fr] gap-4">
          <div className="w-[min(80vw,400px)]">
            <Chessboard
              position={game.fen()}
              onPieceDrop={onDrop}
              boardOrientation={game.turn() === 'w' ? 'white' : 'black'}
              customDarkSquareStyle={{ backgroundColor: '#4f6f52' }}
              customLightSquareStyle={{ backgroundColor: '#e8eddf' }}
            />
          </div>
          <div className="space-y-2 text-sm">
            <div className="rounded-xl border border-ink-600 bg-ink-800 p-3">
              <div className="font-medium">{line.name}</div>
              <p className="text-xs text-slate-500 mt-1">{line.idea}</p>
            </div>
            <div className="rounded-xl border border-ink-600 bg-ink-800 p-3">
              <div className="text-xs uppercase tracking-wide text-slate-500 mb-1">Line</div>
              <div className="font-mono text-xs break-words">
                {line.moves.map((m, i) => (
                  <span key={i} className={i < step ? 'text-lime' : i === step ? 'text-slate-200 underline' : 'text-slate-500'}>
                    {i % 2 === 0 ? `${i / 2 + 1}. ` : ''}{m}{' '}
                  </span>
                ))}
              </div>
            </div>
            {step < line.moves.length ? (
              <p className="text-slate-400">Play: <span className="font-mono text-slate-200">{expected}</span></p>
            ) : (
              <p className="text-lime">Line complete.</p>
            )}
            {feedback && <p className="text-xs text-slate-400">{feedback}</p>}
            <button onClick={() => { setStep(0); setFeedback(null); }}
              className="rounded-lg border border-ink-600 px-3 py-1.5 text-sm">
              Restart line
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
