#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/chess/chess-supercoach"
cd "$ROOT"

# ============================================================ 1/3 — coachTTS.ts
cat > src/lib/coachTTS.ts <<'TS_EOF'
// src/lib/coachTTS.ts
export type TTSMood = 'happy' | 'excited' | 'neutral' | 'concerned' | 'sad';

const KEY = 'chess-supercoach:tts';
const listeners = new Set<(v: boolean) => void>();

const RATE: Record<TTSMood, number> = {
  excited: 1.08, happy: 1.03, neutral: 1.0, concerned: 0.96, sad: 0.9,
};
const PITCH: Record<TTSMood, number> = {
  excited: 1.15, happy: 1.06, neutral: 1.0, concerned: 0.94, sad: 0.88,
};

let unlocked = false;

export function isTTSEnabled(): boolean {
  try { return localStorage.getItem(KEY) === '1'; } catch { return false; }
}

export function isTTSUnlocked(): boolean { return unlocked; }

export function setTTSEnabled(v: boolean): void {
  try { localStorage.setItem(KEY, v ? '1' : '0'); } catch { /* noop */ }
  if (!v) {
    stopSpeaking();
    unlocked = false;
  }
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

/**
 * iOS Safari: speechSynthesis is only unlocked by a REAL, AUDIBLE utterance
 * fired synchronously inside a REAL user gesture. Silent / 0-volume /
 * whitespace utterances do NOT unlock it. AudioContext does not help.
 *
 * Call from a click / pointerdown / touchend / keydown handler.
 * Idempotent.
 */
export function unlockTTS(): void {
  if (unlocked) return;
  const s = synth();
  if (!s) { console.warn('[coach-tts] no speechSynthesis'); return; }
  try {
    s.cancel();
    const u = new SpeechSynthesisUtterance('Coach ready.');
    const v = pickVoice();
    if (v) u.voice = v;
    u.lang = 'en-US';
    u.rate = 1.15;
    u.pitch = 1.05;
    u.volume = 1;
    s.speak(u);
    unlocked = true;
    console.info('[coach-tts] unlocked', { voiceCount: s.getVoices().length });
  } catch (e) {
    console.warn('[coach-tts] unlock failed', e);
  }
}

/** Speak, respecting the on/off toggle. */
export function speak(text: string, mood: TTSMood = 'neutral'): void {
  if (!isTTSEnabled() || !text) return;
  speakUnchecked(text, mood);
}

/** Speak regardless of the toggle (used by Test voice). */
export function speakUnchecked(text: string, mood: TTSMood = 'neutral'): void {
  const s = synth();
  if (!s || !text) return;

  const voices = s.getVoices();
  if (voices.length === 0) {
    window.setTimeout(() => speakUnchecked(text, mood), 150);
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
      unlocked = true;
      console.info('[coach-tts] speak', { voice: v?.name ?? '(default)', text: text.slice(0, 40) });
    } catch (e) {
      console.warn('[coach-tts] speak threw', e);
    }
  };

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

# ============================================================ 2/3 — CoachBubble.tsx
cat > src/components/CoachBubble.tsx <<'TSX_EOF'
// src/components/CoachBubble.tsx
import { useEffect, useState } from 'react';
import { Bot, Volume2, VolumeX } from 'lucide-react';
import type { CoachLine, CoachMood } from '../lib/coachVoice';
import { isTTSEnabled, setTTSEnabled, onTTSChange, unlockTTS } from '../lib/coachTTS';

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

  function onToggleClick() {
    const next = !ttsOn;
    // The click is a real gesture — unlock iOS TTS right here.
    if (next) unlockTTS();
    setTTSEnabled(next);
  }

  return (
    <div className={`flex flex-col gap-1.5 ${className}`}>
      <div key={line?.text ?? 'empty'} className="flex items-start gap-3 animate-[coachPop_180ms_ease-out]">
        <div
          className={`relative flex h-11 w-11 shrink-0 items-center justify-center rounded-full bg-gradient-to-br ${style.avatar} text-xl shadow-lg ring-2 ring-white/10 ${typing ? 'coachPulse' : ''}`}
        >
          {thinking ? <Bot className="h-5 w-5 animate-pulse text-black/80" /> : (line?.emoji ?? '♟️')}
        </div>
        <div className={`relative min-w-0 flex-1 rounded-2xl border ${style.bubble} px-4 py-3 pr-10 shadow-md`}>
          <div className={`absolute -left-2 top-4 h-3 w-3 rotate-45 border-b border-l ${style.bubble}`} />
          <button
            type="button"
            onClick={onToggleClick}
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

# ============================================================ 3/3 — PlayCoach.tsx (surgical edits)
# 3a. Fix import line
perl -i -pe "s/import \{[^}]*\} from '\.\.\/lib\/coachTTS';/import { speak, stopSpeaking, unlockTTS, isTTSEnabled, isTTSUnlocked, speakUnchecked } from '..\/lib\/coachTTS';/" src/pages/PlayCoach.tsx

# 3b. Remove the broken "Let me see…" placeholder (3-arg speak no longer valid)
perl -i -ne 'print unless /speak\("Let me see…"/' src/pages/PlayCoach.tsx

# 3c. Add the one-shot document listener for auto-unlock
perl -0pi -e "s|useEffect\(\(\) => \(\) => stopSpeaking\(\), \[\]\);|useEffect(() => () => stopSpeaking(), []);\n\n  useEffect(() => {\n    if (!isTTSEnabled()) return;\n    const handler = () => { if (!isTTSUnlocked()) unlockTTS(); };\n    document.addEventListener('pointerdown', handler, { once: true });\n    document.addEventListener('touchstart', handler, { once: true });\n    document.addEventListener('keydown', handler, { once: true });\n    return () => {\n      document.removeEventListener('pointerdown', handler);\n      document.removeEventListener('touchstart', handler);\n      document.removeEventListener('keydown', handler);\n    };\n  }, []);|" src/pages/PlayCoach.tsx

# 3d. Simplify test voice — works even when toggle is off
perl -0pi -e 's/function testVoice\(\) \{[^}]*\}/function testVoice() {\n    speakUnchecked("Coach voice ready. Good luck and have fun.", "happy");\n  }/s' src/pages/PlayCoach.tsx

# Report
echo "=== import line ==="
grep -n "from '../lib/coachTTS'" src/pages/PlayCoach.tsx || true
echo "=== pointerdown listener ==="
grep -n "pointerdown" src/pages/PlayCoach.tsx || true
echo "=== testVoice ==="
grep -n -A2 "function testVoice" src/pages/PlayCoach.tsx || true
echo
echo "Next: npm run typecheck && npm run dev"