import { toCentipawns, type RawEval } from '../lib/eval';

export interface EvalResult {
  bestMove: string | null;
  pv: string[];
  depth: number;
  raw: RawEval;
  cp: number | null;
  mate: number | null;
}

export type EngineStatus = 'idle' | 'loading' | 'ready' | 'error';

interface Pending {
  id: number;
  resolve: (r: EvalResult) => void;
  reject: (e: Error) => void;
  best: { move: string | null; pv: string[]; depth: number; raw: RawEval };
  stopped: boolean;
}

const WORKER_URL = '/engine/worker.js';
const INIT_TIMEOUT_MS = 30_000;
const SEARCH_TIMEOUT_MS = 120_000;

export class StockfishEngine {
  private worker: Worker | null = null;
  private status: EngineStatus = 'idle';
  private listeners = new Set<(s: EngineStatus) => void>();
  private pending: Pending | null = null;
  private nextId = 1;
  private chain: Promise<unknown> = Promise.resolve();
  private readyPromise: Promise<void> | null = null;

  getStatus(): EngineStatus { return this.status; }

  onStatus(fn: (s: EngineStatus) => void): () => void {
    this.listeners.add(fn);
    return () => { this.listeners.delete(fn); };
  }

  private setStatus(s: EngineStatus) {
    this.status = s;
    this.listeners.forEach((l) => l(s));
  }

  init(): Promise<void> {
    if (this.readyPromise) return this.readyPromise;
    this.setStatus('loading');

    this.readyPromise = new Promise<void>((resolve, reject) => {
      let worker: Worker;
      try {
        worker = new Worker(WORKER_URL);
      } catch (e) {
        this.setStatus('error');
        reject(new Error('Could not start engine worker: ' + (e as Error).message));
        return;
      }
      this.worker = worker;

      const timer = setTimeout(() => {
        this.setStatus('error');
        reject(new Error('Engine did not respond to UCI handshake within 30s.'));
      }, INIT_TIMEOUT_MS);

      let uciOk = false;

      worker.onerror = (ev) => {
        clearTimeout(timer);
        this.setStatus('error');
        reject(new Error('Engine worker error: ' + ev.message));
      };

      worker.onmessage = (ev: MessageEvent) => {
        const data = typeof ev.data === 'string' ? ev.data : String(ev.data);
        if (data.startsWith('ENGINE_LOAD_ERROR')) {
          clearTimeout(timer);
          this.setStatus('error');
          reject(new Error(data.replace('ENGINE_LOAD_ERROR: ', '')));
          return;
        }
        if (!uciOk && data.trim() === 'uciok') {
          uciOk = true;
          worker.postMessage('isready');
          return;
        }
        if (!uciOk) return;
        if (data.trim() === 'readyok') {
          clearTimeout(timer);
          this.setStatus('ready');
          resolve();
          return;
        }
        this.handleLine(data);
      };

      worker.postMessage('uci');
    });

    return this.readyPromise;
  }

  private handleLine(line: string) {
    const p = this.pending;
    if (!p || p.stopped) return;

    if (line.startsWith('info') && line.includes(' pv ')) {
      const tokens = line.split(/\s+/);
      let depth = p.best.depth;
      const raw: RawEval = {};
      const pv: string[] = [];
      for (let i = 0; i < tokens.length; i++) {
        const t = tokens[i];
        if (t === 'depth') depth = Number(tokens[i + 1]) || depth;
        else if (t === 'score' && tokens[i + 1] === 'cp') raw.scoreCp = Number(tokens[i + 2]);
        else if (t === 'score' && tokens[i + 1] === 'mate') raw.mate = Number(tokens[i + 2]);
        else if (t === 'pv') { pv.push(...tokens.slice(i + 1)); break; }
      }
      p.best.depth = depth;
      if (pv.length) p.best.pv = pv;
      if (raw.scoreCp !== undefined || raw.mate !== undefined) p.best.raw = raw;
      return;
    }

    if (line.startsWith('bestmove')) {
      const move = line.split(/\s+/)[1];
      p.best.move = move && move !== '(none)' ? move : null;
      const b = p.best;
      p.resolve({
        bestMove: b.move,
        pv: b.pv,
        depth: b.depth,
        raw: b.raw,
        cp: b.raw.scoreCp ?? null,
        mate: b.raw.mate ?? null
      });
      this.pending = null;
    }
  }

  evaluate(fen: string, depth: number, signal?: AbortSignal): Promise<EvalResult> {
    const run = () => this.doEvaluate(fen, depth, signal);
    const result = this.chain.then(run, run);
    this.chain = result.catch(() => undefined);
    return result;
  }

  private doEvaluate(fen: string, depth: number, signal?: AbortSignal): Promise<EvalResult> {
    return new Promise<EvalResult>((resolve, reject) => {
      if (!this.worker || this.status !== 'ready') {
        reject(new Error('Engine is not ready.'));
        return;
      }
      if (signal?.aborted) {
        reject(new DOMException('Aborted', 'AbortError'));
        return;
      }

      const id = this.nextId++;
      const pending: Pending = {
        id, resolve, reject,
        best: { move: null, pv: [], depth: 0, raw: {} },
        stopped: false
      };
      this.pending = pending;

      const timer = setTimeout(() => {
        if (this.pending?.id === id) this.worker?.postMessage('stop');
      }, SEARCH_TIMEOUT_MS);

      const onAbort = () => {
        if (this.pending?.id === id) {
          pending.stopped = true;
          this.worker?.postMessage('stop');
          this.pending = null;
          clearTimeout(timer);
          signal?.removeEventListener('abort', onAbort);
          reject(new DOMException('Aborted', 'AbortError'));
        }
      };
      signal?.addEventListener('abort', onAbort, { once: true });

      const origResolve = pending.resolve;
      pending.resolve = (r) => {
        clearTimeout(timer);
        signal?.removeEventListener('abort', onAbort);
        origResolve(r);
      };

      this.worker.postMessage(`position fen ${fen}`);
      this.worker.postMessage(`go depth ${depth}`);
    });
  }

  async stop(): Promise<void> {
    this.worker?.postMessage('stop');
    this.pending = null;
  }

  destroy(): void {
    this.worker?.terminate();
    this.worker = null;
    this.readyPromise = null;
    this.pending = null;
    this.setStatus('idle');
  }
}

let singleton: StockfishEngine | null = null;

export function getEngine(): StockfishEngine {
  if (!singleton) singleton = new StockfishEngine();
  return singleton;
}

export { toCentipawns };
