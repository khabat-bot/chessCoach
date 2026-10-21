#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/chess/chess-supercoach"
cd "$ROOT"

# ============================================================ 1/2 — coachTTS.ts
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

export function unlockTTS(): void {
  unlocked = true;
}

export function isTTSUnlocked(): boolean { return unlocked; }

/**
 * Speak a line.
 *
 * @param fromGesture
 *   true ONLY when called synchronously inside a real user gesture
 *   (click handler, drag drop, etc). Skips the queue-check and speaks
 *   immediately — iOS Safari accepts this as the unlock event.
 *
 *   false (default) — normal path: cancel any queued speech, wait 150ms
 *   (Safari drops utterances queued right after cancel()), then speak.
 */
export function speak(text: string, mood: TTSMood = 'neutral', fromGesture = false): void {
  if (!isTTSEnabled() || !text) return;
  const s = synth();
  if (!s) { console.warn('[coach-tts] no speechSynthesis'); return; }

  const voices = s.getVoices();
  if (voices.length === 0 && !fromGesture) {
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

  if (fromGesture) {
    // Inside a gesture: cancel + speak IMMEDIATELY. No delays.
    try { s.cancel(); } catch { /* noop */ }
    try {
      s.speak(utter);
      unlocked = true;
      console.info('[coach-tts] spoke-in-gesture', text.slice(0, 40));
    } catch (e) {
      console.warn('[coach-tts] gesture-speak threw', e);
    }
    return;
  }

  if (!unlocked) {
    console.warn('[coach-tts] not unlocked yet — call speak(..., true) from a gesture first');
  }

  const start = () => {
    try {
      s.speak(utter);
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

# ============================================================ 2/2 — PlayCoach.tsx
# Ensure isTTSEnabled is imported.
if ! grep -q 'isTTSEnabled' src/pages/PlayCoach.tsx; then
  perl -i -pe "s/import \{ speak, stopSpeaking, unlockTTS \} from '\.\.\/lib\/coachTTS';/import { speak, stopSpeaking, unlockTTS, isTTSEnabled } from '..\/lib\/coachTTS';/" \
    src/pages/PlayCoach.tsx
fi

# Insert a synchronous placeholder speak inside onPieceDrop's sync wrapper.
if ! grep -q "Let me see" src/pages/PlayCoach.tsx; then
  perl -i -pe 's/(function onPieceDrop\(from: string, to: string\): boolean \{)/$1\n    if (isTTSEnabled()) speak("Let me see…", "neutral", true);/' \
    src/pages/PlayCoach.tsx
fi

# Sanity checks
echo
echo "=== onPieceDrop now looks like: ==="
grep -n -A6 "function onPieceDrop" src/pages/PlayCoach.tsx || true
echo
echo "=== import line: ==="
grep -n "from '../lib/coachTTS'" src/pages/PlayCoach.tsx || true
echo
echo "Next: npm run typecheck && npm run dev"