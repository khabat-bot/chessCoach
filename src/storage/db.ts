import { openDB, type IDBPDatabase } from 'idb';
import type { GameRecord, GameAnalysis, TrainingItem, Prefs } from '../types';
import { initialSrs } from '../lib/spacedRepetition';

const DB_NAME = 'chess-supercoach';
const DB_VERSION = 1;

export class StorageError extends Error {}

let dbp: Promise<IDBPDatabase> | null = null;

export function getDb(): Promise<IDBPDatabase> {
  if (!dbp) {
    dbp = openDB(DB_NAME, DB_VERSION, {
      upgrade(db) {
        if (!db.objectStoreNames.contains('games')) {
          const g = db.createObjectStore('games', { keyPath: 'id' });
          g.createIndex('createdAt', 'createdAt');
        }
        if (!db.objectStoreNames.contains('analyses')) {
          db.createObjectStore('analyses', { keyPath: 'gameId' });
        }
        if (!db.objectStoreNames.contains('training')) {
          const t = db.createObjectStore('training', { keyPath: 'id' });
          t.createIndex('dueAt', 'dueAt');
          t.createIndex('gameId', 'gameId');
        }
        if (!db.objectStoreNames.contains('prefs')) {
          db.createObjectStore('prefs', { keyPath: 'key' });
        }
      },
      blocked() { console.warn('IndexedDB upgrade blocked by another tab.'); },
      terminated() { dbp = null; }
    }).catch((e) => {
      dbp = null;
      throw new StorageError('Could not open local database: ' + (e as Error).message);
    });
  }
  return dbp;
}

export const DEFAULT_PREFS: Prefs = {
  key: 'prefs',
  orientation: 'white',
  engineDepth: 10,
  sessionMinutes: 10,
  dailyTarget: 10,
  sounds: false,
  animation: true,
  boardLight: '#e8eddf',
  boardDark: '#4f6f52'
};

export async function getPrefs(): Promise<Prefs> {
  const db = await getDb();
  const p = (await db.get('prefs', 'prefs')) as Prefs | undefined;
  return p ?? DEFAULT_PREFS;
}

export async function setPrefs(p: Prefs): Promise<void> {
  const db = await getDb();
  await db.put('prefs', p);
}

export async function saveGame(g: GameRecord): Promise<void> {
  const db = await getDb();
  await db.put('games', g);
}

export async function listGames(): Promise<GameRecord[]> {
  const db = await getDb();
  const all = (await db.getAll('games')) as GameRecord[];
  return all.sort((a, b) => b.createdAt - a.createdAt);
}

export async function deleteGame(id: string): Promise<void> {
  const db = await getDb();
  const tx = db.transaction(['games', 'analyses', 'training'], 'readwrite');
  await tx.objectStore('games').delete(id);
  await tx.objectStore('analyses').delete(id);
  const idx = tx.objectStore('training').index('gameId');
  for (const key of await idx.getAllKeys(id)) {
    await tx.objectStore('training').delete(key);
  }
  await tx.done;
}

export async function getAnalysis(gameId: string): Promise<GameAnalysis | undefined> {
  const db = await getDb();
  return (await db.get('analyses', gameId)) as GameAnalysis | undefined;
}

export async function saveAnalysis(a: GameAnalysis): Promise<void> {
  const db = await getDb();
  await db.put('analyses', a);
  const game = (await db.get('games', a.gameId)) as GameRecord | undefined;
  if (game) {
    await db.put('games', { ...game, status: a.complete ? 'complete' : 'partial' });
  }
}

export async function allAnalyses(): Promise<GameAnalysis[]> {
  const db = await getDb();
  return (await db.getAll('analyses')) as GameAnalysis[];
}

export async function addTrainingItem(item: TrainingItem): Promise<void> {
  const db = await getDb();
  const existing = (await db.getAll('training')) as TrainingItem[];
  const dup = existing.find((t) => t.gameId === item.gameId && t.ply === item.ply);
  if (dup) return;
  await db.put('training', item);
}

export function makeTrainingItem(
  gameId: string,
  ply: number,
  fen: string,
  playedSan: string,
  bestSan: string,
  bestPv: string[],
  loss: number,
  category: string
): TrainingItem {
  const srs = initialSrs();
  return {
    id: `${gameId}:${ply}`,
    gameId, ply, fen, playedSan, bestSan, bestPv, loss, category,
    createdAt: Date.now(),
    ...srs,
    attempts: 0,
    successes: 0
  };
}

export async function dueTrainingItems(limit = 20): Promise<TrainingItem[]> {
  const db = await getDb();
  const all = (await db.getAll('training')) as TrainingItem[];
  return all
    .filter((t) => t.dueAt <= Date.now())
    .sort((a, b) => b.loss - a.loss || a.dueAt - b.dueAt)
    .slice(0, limit);
}

export async function allTrainingItems(): Promise<TrainingItem[]> {
  const db = await getDb();
  return (await db.getAll('training')) as TrainingItem[];
}

export async function updateTrainingItem(t: TrainingItem): Promise<void> {
  const db = await getDb();
  await db.put('training', t);
}

export async function exportAll(): Promise<string> {
  const db = await getDb();
  const payload = {
    version: DB_VERSION,
    exportedAt: new Date().toISOString(),
    games: await db.getAll('games'),
    analyses: await db.getAll('analyses'),
    training: await db.getAll('training'),
    prefs: await db.getAll('prefs')
  };
  return JSON.stringify(payload, null, 2);
}

export async function importAll(json: string): Promise<void> {
  let data: any;
  try { data = JSON.parse(json); } catch { throw new StorageError('Import file is not valid JSON.'); }
  if (!data || typeof data !== 'object' || !Array.isArray(data.games)) {
    throw new StorageError('Import file has an unexpected shape.');
  }
  const db = await getDb();
  const tx = db.transaction(['games', 'analyses', 'training', 'prefs'], 'readwrite');
  for (const g of data.games) {
    if (g && typeof g.id === 'string' && typeof g.pgn === 'string') {
      await tx.objectStore('games').put(g);
    }
  }
  for (const a of data.analyses ?? []) {
    if (a && typeof a.gameId === 'string') await tx.objectStore('analyses').put(a);
  }
  for (const t of data.training ?? []) {
    if (t && typeof t.id === 'string') await tx.objectStore('training').put(t);
  }
  for (const p of data.prefs ?? []) {
    if (p && p.key) await tx.objectStore('prefs').put(p);
  }
  await tx.done;
}

export async function clearAll(): Promise<void> {
  const db = await getDb();
  const tx = db.transaction(['games', 'analyses', 'training', 'prefs'], 'readwrite');
  await tx.objectStore('games').clear();
  await tx.objectStore('analyses').clear();
  await tx.objectStore('training').clear();
  await tx.objectStore('prefs').clear();
  await tx.done;
}
