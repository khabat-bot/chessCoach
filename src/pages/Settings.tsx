import { useEffect, useState, type ChangeEvent } from 'react';
import { getPrefs, setPrefs, exportAll, importAll, clearAll, DEFAULT_PREFS } from '../storage/db';
import type { Prefs } from '../types';

export function Settings() {
  const [prefs, setLocal] = useState<Prefs>(DEFAULT_PREFS);
  const [msg, setMsg] = useState<string | null>(null);
  const [confirming, setConfirming] = useState(false);

  useEffect(() => { getPrefs().then(setLocal); }, []);

  async function save(patch: Partial<Prefs>) {
    const next = { ...prefs, ...patch };
    setLocal(next);
    await setPrefs(next);
  }

  async function doExport() {
    const json = await exportAll();
    const blob = new Blob([json], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = `chess-supercoach-${Date.now()}.json`;
    a.click();
    URL.revokeObjectURL(a.href);
    setMsg('Data exported.');
  }

  async function doImport(e: ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0];
    if (!f) return;
    try {
      await importAll(await f.text());
      setMsg('Import complete.');
      setLocal(await getPrefs());
    } catch (err) {
      setMsg('Import failed: ' + (err as Error).message);
    }
    e.target.value = '';
  }

  async function doClear() {
    await clearAll();
    setConfirming(false);
    setLocal(DEFAULT_PREFS);
    setMsg('All local data deleted.');
  }

  return (
    <div className="max-w-2xl space-y-4">
      <h1 className="text-2xl font-semibold tracking-tight">Settings</h1>

      <section className="rounded-xl border border-ink-600 bg-ink-800 p-4 space-y-4">
        <div>
          <label className="text-sm text-slate-300 block mb-1">Engine depth: {prefs.engineDepth}</label>
          <input type="range" min={6} max={18} value={prefs.engineDepth}
            onChange={(e) => save({ engineDepth: Number(e.target.value) })} className="w-full accent-lime" />
          <p className="text-xs text-slate-500 mt-1">
            Higher depth is stronger but markedly slower. 8-12 is a good range on mobile.
          </p>
        </div>

        <div>
          <label className="text-sm text-slate-300 block mb-1">Default session: {prefs.sessionMinutes} min</label>
          <input type="range" min={5} max={30} step={5} value={prefs.sessionMinutes}
            onChange={(e) => save({ sessionMinutes: Number(e.target.value) })} className="w-full accent-lime" />
        </div>

        <div className="flex items-center gap-3">
          <input id="anim" type="checkbox" checked={prefs.animation}
            onChange={(e) => save({ animation: e.target.checked })} className="accent-lime" />
          <label htmlFor="anim" className="text-sm text-slate-300">Piece animation</label>
        </div>

        <div>
          <label className="text-sm text-slate-300 block mb-1">Board orientation</label>
          <select value={prefs.orientation}
            onChange={(e) => save({ orientation: e.target.value as 'white' | 'black' })}
            className="rounded-lg bg-ink-900 border border-ink-600 px-3 py-1.5 text-sm">
            <option value="white">White at bottom</option>
            <option value="black">Black at bottom</option>
          </select>
        </div>
      </section>

      <section className="rounded-xl border border-ink-600 bg-ink-800 p-4 space-y-3">
        <h2 className="font-medium">Local data</h2>
        <p className="text-xs text-slate-500">
          Everything lives in this browser's IndexedDB. It is not a backup - export regularly.
        </p>
        <div className="flex flex-wrap gap-2">
          <button onClick={doExport} className="rounded-lg border border-ink-600 px-3 py-1.5 text-sm">Export JSON</button>
          <label className="rounded-lg border border-ink-600 px-3 py-1.5 text-sm cursor-pointer">
            Import JSON
            <input type="file" accept="application/json" onChange={doImport} className="hidden" />
          </label>
          <button onClick={() => setConfirming(true)}
            className="rounded-lg border border-rose-500/50 text-rose-300 px-3 py-1.5 text-sm">
            Delete all data
          </button>
        </div>
        {msg && <p className="text-xs text-slate-400">{msg}</p>}
      </section>

      {confirming && (
        <div className="fixed inset-0 bg-black/60 grid place-items-center p-4" role="dialog" aria-modal="true">
          <div className="w-full max-w-sm rounded-xl border border-ink-600 bg-ink-800 p-5 space-y-3">
            <h3 className="font-medium">Delete all local data?</h3>
            <p className="text-sm text-slate-400">
              This removes every game, analysis and training record permanently.
            </p>
            <div className="flex justify-end gap-2">
              <button onClick={() => setConfirming(false)}
                className="rounded-lg border border-ink-600 px-3 py-1.5 text-sm">Cancel</button>
              <button onClick={doClear}
                className="rounded-lg bg-rose-500 text-white px-3 py-1.5 text-sm">Delete</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
