#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/chess/chess-supercoach"

# ============================================================ 1/3
cat > src/lib/coachTTS.ts <<'TS_EOF'
export type TTSMood = 'happy' | 'excited' | 'neutral' | 'concerned' | 'sad';

const KEY = 'chess-supercoach:tts';
const listeners = new Set<(v: boolean) => void>();

const RATE: Record<TTSMood, number> = {
  excited: 1.08, happy: 1.03, neutral: 1.0, concerned: 0.96, sad: 0.9,
};
const PITCH: Record<TTSMood, number> = {
  excited: 1.15, happy: 1.06, neutral: 1.0, concerned: 0.94, sad: 0.88,
};

export function isTTSEnabled(): boolean {
  try { return localStorage.getItem(KEY) === '1'; } catch { return false; }
}

export function setTTSEnabled(v: boolean): void {
  try { localStorage.setItem(KEY, v ? '1' : '0'); } catch { /* noop */ }
  if (!v) stopSpeaking();
  listeners.forEach(fn => { try { fn(v); } catch { /* noop */ } });
}

export function onTTSChange(fn: (v: boolean) => void): () => void {
  listeners.add(fn);
  return () => { listeners.delete(fn); };
}

function synth(): SpeechSynthesis | null {
  if (typeof window === 'undefined') return null;
  return window.speechSynthesis ?? null;
}

function pickVoice(): SpeechSynthesisVoice | null {
  const s = synth();
  if (!s) return null;
  const voices = s.getVoices();
  if (voices.length === 0) return null;
  const preferred = [
    'Google UK English Male', 'Google US English',
    'Samantha', 'Daniel', 'Alex', 'Karen', 'Moira', 'Tessa',
    'Microsoft David', 'Microsoft Mark', 'Microsoft Zira',
  ];
  for (const name of preferred) {
    const v = voices.find(x => x.name === name);
    if (v) return v;
  }
  for (const name of preferred) {
    const v = voices.find(x => x.name.includes(name));
    if (v) return v;
  }
  return voices.find(v => v.lang.startsWith('en')) ?? voices[0];
}

export function isIOS(): boolean {
  if (typeof navigator === 'undefined') return false;
  return /iPad|iPhone|iPod/.test(navigator.userAgent)
    || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

/**
 * Speak synchronously. MUST be called from inside a real click/touchend/keydown
 * handler to work on iOS Safari. Everywhere else, this is fine to call async.
 */
export function speak(text: string, mood: TTSMood = 'neutral'): void {
  const s = synth();
  if (!s || !text) { console.warn('[coach-tts] no speechSynthesis or empty text'); return; }

  const voices = s.getVoices();
  if (voices.length === 0) {
    window.setTimeout(() => speak(text, mood), 150);
    return;
  }

  const utter = new SpeechSynthesisUtterance(text);
  const v = pickVoice();
  if (v) utter.voice = v;
  utter.lang = 'en-US';
  utter.rate = RATE[mood] ?? 1.0;
  utter.pitch = PITCH[mood] ?? 1.0;
  utter.volume = 1;

  utter.onstart = () => console.info('[coach-tts] started', text.slice(0, 30));
  utter.onerror = (e) => console.warn('[coach-tts] error', e.error, text.slice(0, 30));

  const start = () => {
    try {
      s.speak(utter);
      console.info('[coach-tts] speak', { voice: v?.name ?? '(default)', text: text.slice(0, 40) });
    } catch (e) {
      console.warn('[coach-tts] speak threw', e);
    }
  };

  // Safari drops utterances queued synchronously after cancel().
  if (s.speaking || s.pending) {
    try { s.cancel(); } catch { /* noop */ }
    window.setTimeout(start, 150);
  } else {
    start();
  }
}

export function stopSpeaking(): void {
  try { synth()?.cancel(); } catch { /* noop */ }
}
TS_EOF

# ============================================================ 2/3
cat > src/components/CoachBubble.tsx <<'TSX_EOF'
import { useEffect, useState } from 'react';
import { Bot, Volume2, VolumeX, RotateCcw } from 'lucide-react';
import type { CoachLine, CoachMood } from '../lib/coachVoice';
import { isTTSEnabled, setTTSEnabled, onTTSChange, speak } from '../lib/coachTTS';

interface Props {
  line: CoachLine | null;
  thinking?: boolean;
  aside?: string | null;
  className?: string;
}

const MOOD_STYLES: Record<CoachMood, { bubble: string; avatar: string }> = {
  happy:     { bubble: 'border-emerald-500/40 bg-emerald-500/10', avatar: 'from-emerald-400 to-emerald-600' },
  excited:   { bubble: 'border-lime-400/50 bg-lime-500/10',       avatar: 'from-lime-300 to-lime-500' },
  neutral:   { bubble: 'border-slate-500/30 bg-slate-500/10',     avatar: 'from-slate-400 to-slate-600' },
  concerned: { bubble: 'border-amber-500/40 bg-amber-500/10',     avatar: 'from-amber-400 to-amber-600' },
  sad:       { bubble: 'border-rose-500/40 bg-rose-500/10',       avatar: 'from-rose-400 to-rose-600' },
};

export function CoachBubble({ line, thinking = false, aside = null, className = '' }: Props) {
  const [shown, setShown] = useState('');
  const [ttsOn, setTtsOnState] = useState(() => isTTSEnabled());

  useEffect(() => onTTSChange(setTtsOnState), []);

  useEffect(() => {
    const text = line?.text ?? '';
    if (!text) { setShown(''); return; }
    setShown('');
    let i = 0;
    const timer = window.setInterval(() => {
      i += 1;
      setShown(text.slice(0, i));
      if (i >= text.length) window.clearInterval(timer);
    }, 14);
    return () => window.clearInterval(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [line?.text]);

  const style = MOOD_STYLES[line?.mood ?? 'neutral'];
  const done = line ? shown.length >= line.text.length : true;
  const typing = !!line && !done;

  function onReplay() {
    if (line) speak(line.text, line.mood);
  }

  return (
    <div className={`flex flex-col gap-1.5 ${className}`}>
      <div key={line?.text ?? 'empty'} className="flex items-start gap-3 animate-[coachPop_180ms_ease-out]">
        <div
          className={`relative flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-gradient-to-br ${style.avatar} text-xl shadow-lg ring-2 ring-white/10 ${typing ? 'coachPulse' : ''}`}
        >
          {thinking ? <Bot className="h-5 w-5 animate-pulse text-black/80" /> : (line?.emoji ?? '♟️')}
        </div>
        <div className={`relative min-w-0 flex-1 rounded-2xl border ${style.bubble} px-4 py-3 pr-20 shadow-md`}>
          <div className={`absolute -left-2 top-4 h-3 w-3 rotate-45 border-b border-l ${style.bubble}`} />

          {line && !thinking && (
            <button
              type="button"
              onClick={onReplay}
              title="Replay coach voice"
              aria-label="Replay coach voice"
              className="absolute right-8 top-2 rounded-md p-1 text-slate-400 hover:bg-slate-500/10 hover:text-slate-200 transition-colors"
            >
              <RotateCcw className="h-4 w-4" />
            </button>
          )}

          <button
            type="button"
            onClick={() => setTTSEnabled(!ttsOn)}
            title={ttsOn ? 'Mute coach voice' : 'Enable coach voice'}
            aria-label={ttsOn ? 'Mute coach voice' : 'Enable coach voice'}
            className={`absolute right-2 top-2 rounded-md p-1 transition-colors ${
              ttsOn ? 'text-lime hover:bg-lime/10' : 'text-slate-500 hover:bg-slate-500/10'
            } ${typing && ttsOn ? 'coachWave' : ''}`}
          >
            {ttsOn ? <Volume2 className="h-4 w-4" /> : <VolumeX className="h-4 w-4" />}
          </button>

          {thinking ? (
            <p className="text-sm italic text-slate-300">Coach is thinking…</p>
          ) : line ? (
            <p className="text-sm leading-relaxed text-slate-100">
              {shown}
              {!done && <span className="animate-pulse">▍</span>}
            </p>
          ) : (
            <p className="text-sm italic text-slate-400">Play a move to hear from your coach.</p>
          )}
        </div>
      </div>

      {aside && !thinking && (
        <p className="pl-14 text-xs italic text-slate-500">{aside}</p>
      )}

      <style>{`
        @keyframes coachPop {
          from { opacity: 0; transform: translateY(4px) scale(0.98); }
          to   { opacity: 1; transform: translateY(0) scale(1); }
        }
        @keyframes coachPulse {
          0%, 100% { box-shadow: 0 0 0 0 rgba(163, 230, 53, 0.35); }
          50%      { box-shadow: 0 0 0 6px rgba(163, 230, 53, 0.0); }
        }
        .coachPulse { animation: coachPulse 1.4s ease-out infinite; }
        .coachWave   { animation: coachPulse 1s ease-out infinite; }
      `}</style>
    </div>
  );
}
TSX_EOF

# ============================================================ 3/3
cat > src/pages/PlayCoach.tsx <<'TSX_EOF'
import { useEffect, useRef, useState } from 'react';
import { Chessboard } from 'react-chessboard';
import { Chess } from 'chess.js';
import { useEngine } from '../hooks/useEngine';
import { getEngine } from '../engine/stockfish';
import { classify, evalLoss, toCentipawns } from '../lib/eval';
import { parsePgn } from '../lib/pgn';
import { saveGame } from '../storage/db';
import type { Classification } from '../types';
import { EvalBar } from '../components/EvalBar';
import { CoachBubble } from '../components/CoachBubble';
import {
  coachLine, openingLine, opponentComment,
  type CoachLine,
} from '../lib/coachVoice';
import { speak, stopSpeaking, isTTSEnabled, isIOS } from '../lib/coachTTS';

interface Turn {
  ply: number;
  san: string;
  isUser: boolean;
  classification: Classification;
  loss: number | null;
  bestSan?: string;
  bestPv?: string[];
  evalWhitePov: number | null;
}

interface CoachFeedback {
  classification: Classification;
  san: string;
  loss: number | null;
  bestSan?: string;
  bestPv?: string[];
}

interface BeforeCache {
  cp: number | null;
  bestSan: string | null;
}

const DIFFICULTIES = [
  { label: 'Beginner', playDepth: 2 },
  { label: 'Easy', playDepth: 3 },
  { label: 'Intermediate', playDepth: 5 },
  { label: 'Advanced', playDepth: 8 },
  { label: 'Expert', playDepth: 12 }
];

const COACH_DEPTH = 10;
const UCI_MOVE = /^[a-h][1-8][a-h][1-8][qrbn]?$/;

function uciToSan(fen: string, uci: string | null | undefined): string | null {
  if (!uci || !UCI_MOVE.test(uci)) return null;
  try {
    const g = new Chess(fen);
    const m = g.move({
      from: uci.slice(0, 2),
      to: uci.slice(2, 4),
      promotion: uci.slice(4, 5) || undefined
    });
    return m?.san ?? null;
  } catch { return null; }
}

export function PlayCoach() {
  const { status, error } = useEngine();
  const engine = getEngine();

  const [game, setGame] = useState(() => new Chess());
  const [userColor, setUserColor] = useState<'w' | 'b'>('w');
  const [difficulty, setDifficulty] = useState(1);
  const [thinking, setThinking] = useState<string | null>(null);
  const [turns, setTurns] = useState<Turn[]>([]);
  const [feedback, setFeedback] = useState<CoachFeedback | null>(null);
  const [coach, setCoach] = useState<CoachLine | null>(openingLine());
  const [aside, setAside] = useState<string | null>(null);
  const [engineError, setEngineError] = useState<string | null>(null);
  const [savedGameId, setSavedGameId] = useState<string | null>(null);
  const [saveMsg, setSaveMsg] = useState<string | null>(null);

  const gameRef = useRef(game);
  gameRef.current = game;
  const userColorRef = useRef(userColor);
  userColorRef.current = userColor;
  const difficultyRef = useRef(difficulty);
  difficultyRef.current = difficulty;

  const cachedBeforeRef = useRef<BeforeCache>({ cp: null, bestSan: null });
  const abortRef = useRef<AbortController | null>(null);
  const initCacheRef = useRef(false);
  const savedRef = useRef(false);

  // iOS speechSynthesis only works inside real click/touchend/keydown.
  // We queue the pending line and speak it on the next such event.
  const pendingSpeechRef = useRef<CoachLine | null>(null);

  function sayLine(line: CoachLine | null) {
    if (!line || !isTTSEnabled()) return;
    if (isIOS()) {
      pendingSpeechRef.current = line;
      console.info('[coach-tts] queued (iOS) — will speak on next tap');
    } else {
      speak(line.text, line.mood);
    }
  }

  useEffect(() => () => stopSpeaking(), []);

  // Flush any queued line inside a real user gesture. This is the only
  // path that works on iOS Safari.
  useEffect(() => {
    const flush = () => {
      const line = pendingSpeechRef.current;
      if (!line) return;
      pendingSpeechRef.current = null;
      speak(line.text, line.mood);
    };
    // click, touchend, keydown are the three events iOS honors.
    document.addEventListener('click', flush);
    document.addEventListener('touchend', flush);
    document.addEventListener('keydown', flush);
    return () => {
      document.removeEventListener('click', flush);
      document.removeEventListener('touchend', flush);
      document.removeEventListener('keydown', flush);
    };
  }, []);

  useEffect(() => {
    if (status !== 'ready' || initCacheRef.current) return;
    if (userColorRef.current !== 'w') return;
    initCacheRef.current = true;
    void (async () => {
      try {
        const fen = gameRef.current.fen();
        const res = await engine.evaluate(fen, COACH_DEPTH);
        cachedBeforeRef.current = {
          cp: toCentipawns(res.raw),
          bestSan: uciToSan(fen, res.pv[0] ?? res.bestMove ?? null)
        };
      } catch { /* ignore */ }
    })();
  }, [status, engine]);

  useEffect(() => {
    if (!savedRef.current && gameRef.current.isGameOver()) {
      void persistGame();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [turns]);

  async function persistGame(): Promise<string | null> {
    if (savedRef.current) return savedGameId;
    if (turns.length === 0) return null;

    const rebuilt = new Chess();
    for (const t of turns) {
      try { rebuilt.move(t.san); }
      catch { setEngineError(`Could not replay move ${t.ply}: ${t.san}`); return null; }
    }
    if (rebuilt.history().length === 0) return null;

    const plies = rebuilt.history().length;
    const result = rebuilt.isCheckmate()
      ? (rebuilt.turn() === 'w' ? '0-1' : '1-0')
      : rebuilt.isDraw() ? '1/2-1/2' : '*';

    const today = new Date().toISOString().slice(0, 10).replace(/-/g, '.');
    rebuilt.header(
      'Event', 'Coaching game', 'Site', 'chess-supercoach', 'Date', today,
      'White', 'You', 'Black', 'Coach', 'Result', result, 'PlyCount', String(plies)
    );

    const pgn = rebuilt.pgn();
    if (!pgn || !pgn.trim()) return null;

    try {
      const rec = parsePgn(pgn);
      await saveGame(rec);
      savedRef.current = true;
      setSavedGameId(rec.id);
      return rec.id;
    } catch (e) {
      setEngineError((e as Error).message);
      return null;
    }
  }

  async function saveAndAnalyze() {
    setSaveMsg(null);
    const id = savedRef.current ? savedGameId : await persistGame();
    if (!id) { setSaveMsg('Nothing to save yet — play at least one move.'); return; }
    window.location.hash = `#analysis?gameId=${encodeURIComponent(id)}`;
  }

  async function playEngineMove(c: Chess): Promise<void> {
    setThinking('Coach is thinking...');
    const ctrl = new AbortController();
    abortRef.current = ctrl;
    try {
      const idx = Math.max(0, Math.min(DIFFICULTIES.length - 1, difficultyRef.current));
      const playDepth = DIFFICULTIES[idx].playDepth;
      const fenBeforeEngine = c.fen();

      const res = await engine.evaluate(fenBeforeEngine, playDepth, ctrl.signal);
      const uci = res.bestMove;
      if (!uci || !UCI_MOVE.test(uci)) return;

      const c2 = new Chess(fenBeforeEngine);
      const played = c2.move({
        from: uci.slice(0, 2),
        to: uci.slice(2, 4),
        promotion: uci.slice(4, 5) || undefined
      });
      if (!played) return;

      setThinking('Updating evaluation...');
      const fenAfterEngine = c2.fen();
      const coachRes = await engine.evaluate(fenAfterEngine, COACH_DEPTH, ctrl.signal);
      const cp = toCentipawns(coachRes.raw);

      cachedBeforeRef.current = {
        cp,
        bestSan: uciToSan(fenAfterEngine, coachRes.pv[0] ?? coachRes.bestMove ?? null)
      };

      const cpWhite = cp === null ? null : (userColorRef.current === 'w' ? cp : -cp);

      setTurns((prev) => [...prev, {
        ply: c2.history().length,
        san: played.san,
        isUser: false,
        classification: 'best',
        loss: null,
        evalWhitePov: cpWhite
      }]);

      setGame(c2);

      const note = opponentComment({
        san: played.san,
        fenBefore: fenBeforeEngine,
        fenAfter: fenAfterEngine,
        userColor: userColorRef.current,
      });
      setAside(note);
    } catch (e) {
      if ((e as Error).name !== 'AbortError') setEngineError((e as Error).message);
    } finally {
      setThinking(null);
      abortRef.current = null;
    }
  }

  function onPieceDrop(from: string, to: string): boolean {
    if (thinking || status !== 'ready') return false;
    if (gameRef.current.turn() !== userColorRef.current) return false;
    if (gameRef.current.isGameOver()) return false;
    try {
      const probe = new Chess(gameRef.current.fen());
      if (!probe.move({ from, to, promotion: 'q' })) return false;
    } catch {
      return false;
    }
    void executeUserMove(from, to);
    return true;
  }

  async function executeUserMove(from: string, to: string): Promise<boolean> {
    const fenBefore = gameRef.current.fen();
    const c = new Chess(fenBefore);
    let mv;
    try { mv = c.move({ from, to, promotion: 'q' }); }
    catch { return false; }
    if (!mv) return false;

    setGame(c);
    setFeedback(null);
    setAside(null);
    setThinking('Analysing your move...');

    const ctrl = new AbortController();
    abortRef.current = ctrl;

    try {
      const cached = cachedBeforeRef.current;
      const beforeUserPov = cached.cp;
      const bestSan = cached.bestSan ?? undefined;

      const coachRes = await engine.evaluate(c.fen(), COACH_DEPTH, ctrl.signal);
      const afterCpOpp = toCentipawns(coachRes.raw);
      const afterCpUserPov = afterCpOpp === null ? null : -afterCpOpp;
      const loss = evalLoss(beforeUserPov, afterCpUserPov);

      const isBest = bestSan !== undefined && mv.san === bestSan;
      const classification = classify(loss, isBest);

      const engineColor = userColorRef.current === 'w' ? 'b' : 'w';
      const afterCpWhite = afterCpOpp === null ? null : (engineColor === 'w' ? afterCpOpp : -afterCpOpp);

      const userTurns = turns.filter(t => t.isUser).length + 1;
      const lastOpponentSan = [...turns].reverse().find(t => !t.isUser)?.san;

      setTurns((prev) => [...prev, {
        ply: c.history().length,
        san: mv.san,
        isUser: true,
        classification,
        loss,
        bestSan,
        bestPv: coachRes.pv,
        evalWhitePov: afterCpWhite
      }]);

      setFeedback({ classification, san: mv.san, loss, bestSan, bestPv: coachRes.pv });

      const isCheckmate = c.isCheckmate();
      const userWon = isCheckmate && c.turn() !== userColorRef.current;
      const line = coachLine({
        classification,
        playedSan: mv.san,
        bestSan: bestSan ?? '',
        lossCp: loss ?? 0,
        fenBefore,
        fenAfter: c.fen(),
        bestPv: coachRes.pv ?? [],
        evalForUserCp: afterCpUserPov ?? undefined,
        isGameOver: c.isGameOver(),
        isCheckmate,
        isDraw: c.isDraw(),
        userWon,
        lastOpponentSan,
        moveCount: userTurns,
      });
      setCoach(line);
      sayLine(line);

      if (!c.isGameOver()) {
        await playEngineMove(c);
      }
    } catch (e) {
      if ((e as Error).name !== 'AbortError') setEngineError((e as Error).message);
    } finally {
      setThinking(null);
      abortRef.current = null;
    }
    return true;
  }

  function resetSaved() {
    savedRef.current = false;
    setSavedGameId(null);
    setSaveMsg(null);
  }

  function newGame() {
    pendingSpeechRef.current = null;
    abortRef.current?.abort();
    stopSpeaking();
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setAside(null);
    setThinking(null);
    setEngineError(null);
    const greet = openingLine();
    setCoach(greet);
    if (isTTSEnabled()) speak(greet.text, greet.mood); // inside click gesture
    resetSaved();
    cachedBeforeRef.current = { cp: null, bestSan: null };
    initCacheRef.current = false;

    if (status === 'ready') {
      if (userColor === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        void (async () => {
          try {
            const fen = c.fen();
            const res = await engine.evaluate(fen, COACH_DEPTH);
            cachedBeforeRef.current = {
              cp: toCentipawns(res.raw),
              bestSan: uciToSan(fen, res.pv[0] ?? res.bestMove ?? null)
            };
          } catch { /* ignore */ }
        })();
      }
    }
  }

  function changeColor(color: 'w' | 'b') {
    pendingSpeechRef.current = null;
    setUserColor(color);
    userColorRef.current = color;
    stopSpeaking();
    const c = new Chess();
    setGame(c);
    setTurns([]);
    setFeedback(null);
    setAside(null);
    setThinking(null);
    setEngineError(null);
    const greet = openingLine();
    setCoach(greet);
    if (isTTSEnabled()) speak(greet.text, greet.mood);
    resetSaved();
    cachedBeforeRef.current = { cp: null, bestSan: null };
    initCacheRef.current = false;

    if (status === 'ready') {
      if (color === 'b') {
        void playEngineMove(c);
      } else {
        initCacheRef.current = true;
        void (async () => {
          try {
            const fen = c.fen();
            const res = await engine.evaluate(fen, COACH_DEPTH);
            cachedBeforeRef.current = {
              cp: toCentipawns(res.raw),
              bestSan: uciToSan(fen, res.pv[0] ?? res.bestMove ?? null)
            };
          } catch { /* ignore */ }
        })();
      }
    }
  }

  function testVoice() {
    speak('Coach voice ready. Good luck and have fun.', 'happy');
  }

  const boardOrientation = userColor === 'w' ? 'white' : 'black';
  const lastEval = turns.length ? turns[turns.length - 1].evalWhitePov : null;
  const gameOver = game.isGameOver();

  return (
    <div className="max-w-6xl space-y-4">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight">Play the coach</h1>
          <p className="text-sm text-slate-400 mt-1">
            Play against Stockfish. Your coach watches every move and talks you through it.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={testVoice}
            className="text-xs px-2 py-1 rounded-full border border-ink-600 text-slate-400 hover:text-lime hover:border-lime/40 transition-colors"
            title="Play a test phrase through the speech engine"
          >
            Test voice
          </button>
          <span className={`text-xs px-2 py-1 rounded-full ${
            status === 'ready' ? 'bg-lime/10 text-lime'
            : status === 'error' ? 'bg-rose-500/10 text-rose-300'
            : 'bg-ink-700 text-slate-400'}`}>
            engine: {status}
          </span>
        </div>
      </header>

      {(error || engineError) && (
        <div className="rounded-lg border border-rose-500/40 bg-rose-500/10 text-rose-200 text-sm p-3">
          Engine error: {error ?? engineError}
        </div>
      )}

      <div className="grid lg:grid-cols-[auto_1fr] gap-4">
        <div className="flex gap-3">
          <EvalBar cp={lastEval} mate={null} />
          <div className="w-[min(78vw,480px)]">
            <Chessboard
              position={game.fen()}
              onPieceDrop={onPieceDrop}
              boardOrientation={boardOrientation}
              arePiecesDraggable={!thinking && !gameOver && game.turn() === userColor}
              customDarkSquareStyle={{ backgroundColor: '#4f6f52' }}
              customLightSquareStyle={{ backgroundColor: '#e8eddf' }}
            />
          </div>
        </div>

        <div className="space-y-3 min-w-0">
          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3 space-y-2">
            <div className="flex flex-wrap gap-2 items-center text-sm">
              <label className="text-slate-400">You play:</label>
              <select
                value={userColor}
                onChange={(e) => changeColor(e.target.value as 'w' | 'b')}
                className="rounded-lg bg-ink-900 border border-ink-600 px-2 py-1 text-sm">
                <option value="w">White</option>
                <option value="b">Black</option>
              </select>

              <label className="text-slate-400 ml-2">Difficulty:</label>
              <select
                value={difficulty}
                onChange={(e) => setDifficulty(Number(e.target.value))}
                className="rounded-lg bg-ink-900 border border-ink-600 px-2 py-1 text-sm">
                {DIFFICULTIES.map((d, i) => (
                  <option key={d.label} value={i}>{d.label} (depth {d.playDepth})</option>
                ))}
              </select>

              <div className="ml-auto flex flex-wrap gap-2">
                <button
                  type="button"
                  onClick={saveAndAnalyze}
                  className="rounded-lg bg-lime text-ink-900 font-medium px-3 py-1 text-sm">
                  {savedGameId ? 'Saved ✓ — Analyse' : 'Save & Analyse'}
                </button>
                <button
                  type="button"
                  onClick={newGame}
                  className="rounded-lg border border-ink-600 px-3 py-1 text-sm">
                  New game
                </button>
              </div>
            </div>
            {saveMsg && <p className="text-xs text-amber-300">{saveMsg}</p>}
            <p className="text-xs text-slate-500">
              Coaching depth is {COACH_DEPTH}. Finished games are saved automatically. Tap
              the ⟲ icon on a coach line to replay it aloud.
            </p>
          </div>

          <CoachBubble
            line={thinking ? null : coach}
            thinking={!!thinking}
            aside={thinking ? null : aside}
          />

          {feedback && !thinking && (
            <div className="space-y-1 px-2">
              <div className="flex flex-wrap items-center gap-2 text-xs text-slate-500">
                <Badge cls={feedback.classification} />
                <span className="font-mono text-slate-300">{feedback.san}</span>
                {feedback.loss !== null && feedback.loss > 0 && (
                  <span>−{(feedback.loss / 100).toFixed(2)} pawns</span>
                )}
                {feedback.bestSan && feedback.classification !== 'best' && (
                  <span>· engine's pick: <span className="font-mono text-slate-300">{feedback.bestSan}</span></span>
                )}
              </div>
              {feedback.bestPv && feedback.bestPv.length > 0 && (
                <div className="text-xs font-mono text-slate-500 break-words">
                  Engine line: {feedback.bestPv.slice(0, 8).join(' ')}
                </div>
              )}
            </div>
          )}

          {gameOver && (
            <div className="rounded-xl border border-lime/40 bg-lime/10 p-3 text-sm">
              {game.isCheckmate()
                ? `Checkmate - ${game.turn() === userColor ? 'you lose' : 'you win'}.`
                : 'Draw.'}
              {' '}
              {savedGameId
                ? 'Click "Saved ✓ — Analyse" to run a full game analysis.'
                : 'Saving...'}
            </div>
          )}

          <div className="rounded-xl border border-ink-600 bg-ink-800 p-3">
            <h2 className="text-xs uppercase tracking-wide text-slate-500 mb-2">Moves</h2>
            <div className="max-h-64 overflow-y-auto text-sm font-mono">
              {turns.length === 0 && <p className="text-slate-500 font-sans">Waiting...</p>}
              <div className="grid grid-cols-[2.5rem_1fr_1fr] gap-x-2">
                {chunkPairs(turns).map(([w, b], i) => (
                  <Row key={i} n={i + 1} white={w} black={b} />
                ))}
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

function Badge({ cls }: { cls: Classification }) {
  const map: Record<string, string> = {
    best: 'bg-lime/15 text-lime',
    good: 'bg-slate-500/15 text-slate-300',
    inaccuracy: 'bg-amber-400/15 text-amber-300',
    mistake: 'bg-orange-500/15 text-orange-300',
    blunder: 'bg-rose-500/15 text-rose-300',
    unknown: 'bg-ink-700 text-slate-500'
  };
  return (
    <span className={`text-[10px] uppercase tracking-wide px-1.5 py-0.5 rounded ${map[cls] ?? map.unknown}`}>
      {cls}
    </span>
  );
}

function chunkPairs<T>(arr: T[]): [T | undefined, T | undefined][] {
  const out: [T | undefined, T | undefined][] = [];
  for (let i = 0; i < arr.length; i += 2) out.push([arr[i], arr[i + 1]]);
  return out;
}

function Row({ n, white, black }: { n: number; white?: Turn; black?: Turn }) {
  return (
    <>
      <span className="text-slate-600 text-right">{n}.</span>
      <MoveCell turn={white} />
      <MoveCell turn={black} />
    </>
  );
}

function MoveCell({ turn }: { turn?: Turn }) {
  if (!turn) return <span />;
  const mark = !turn.isUser ? '' :
    turn.classification === 'blunder' ? '??' :
    turn.classification === 'mistake' ? '?' :
    turn.classification === 'inaccuracy' ? '?!' :
    turn.classification === 'best' ? '!' : '';
  const color = !turn.isUser ? 'text-slate-400' :
    turn.classification === 'blunder' ? 'text-rose-400' :
    turn.classification === 'mistake' ? 'text-orange-400' :
    turn.classification === 'inaccuracy' ? 'text-amber-300' :
    turn.classification === 'best' ? 'text-lime' : 'text-slate-200';
  return (
    <span className={`text-left px-1 ${color}`}>
      {turn.san}{mark && <span className="ml-0.5">{mark}</span>}
    </span>
  );
}
TSX_EOF

echo "Wrote 3 files."
echo "Next: npm run typecheck && npm run dev"