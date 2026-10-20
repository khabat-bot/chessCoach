import { useEffect, useState } from 'react';
import { getEngine, type EngineStatus } from '../engine/stockfish';

export function useEngine() {
  const engine = getEngine();
  const [status, setStatus] = useState<EngineStatus>(engine.getStatus());
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const off = engine.onStatus(setStatus);
    if (engine.getStatus() === 'idle') {
      engine.init().catch((e: Error) => setError(e.message));
    }
    return () => { off(); };
  }, [engine]);

  return { engine, status, error };
}
