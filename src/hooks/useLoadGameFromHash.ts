import { useEffect, useRef } from 'react';
import { getDb, listGames } from '../storage/db';
import type { GameRecord } from '../types';

/**
 * Loads a game from IndexedDB if the URL hash contains ?gameId=<id>.
 *
 * StrictMode-safe: no "fire once" ref guard. React 18 dev mode mounts
 * effects twice (mount → cleanup → mount); a firedRef guard would cause
 * the second mount to no-op while the first mount's async work was
 * cancelled, so nothing ever loads. The `cancelled` flag alone handles
 * the double-mount correctly.
 */
export function useLoadGameFromHash(onLoad: (g: GameRecord) => void) {
  const onLoadRef = useRef(onLoad);
  onLoadRef.current = onLoad;

  useEffect(() => {
    const m = window.location.hash.match(/[?&]gameId=([^&]+)/);
    if (!m) {
      console.log('[useLoadGameFromHash] no gameId in hash:', window.location.hash);
      return;
    }
    const id = decodeURIComponent(m[1]);
    console.log('[useLoadGameFromHash] looking up', id);

    let cancelled = false;
    void (async () => {
      try {
        const db = await getDb();
        const g = (await db.get('games', id)) as GameRecord | undefined;
        console.log('[useLoadGameFromHash] db.get →', g ? `found id=${g.id}, plies=${g.plies}` : 'NOT FOUND');

        if (cancelled) return;

        if (g) {
          onLoadRef.current(g);
        } else {
          // Fallback diagnostic: is it in listGames under a different key?
          const all = await listGames();
          if (cancelled) return;
          console.warn('[useLoadGameFromHash] not in games store. All ids:',
            all.map((x) => x.id));
        }
      } catch (e) {
        console.error('[useLoadGameFromHash] error', e);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);
}
