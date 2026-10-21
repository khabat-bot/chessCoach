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
let unlockedOnce = false;
let audioCtx: AudioContext | null = null;

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

function ensureAudioCtx(): AudioContext | null {
  if (typeof window === 'undefined') return null;
  if (audioCtx) return audioCtx;
  const Ctx =
    window.AudioContext ||
    (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!Ctx) return null;
  try { audioCtx = new Ctx(); } catch { return null; }
  return audioCtx;
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

// Call synchronously from ANY user gesture (pointerdown, click, touchend...).
// Idempotent: on the first gesture it activates the iOS audio session via
// AudioContext + a silent buffer. On later gestures it just resumes the ctx
// if suspended (e.g. after the tab was backgrounded).
export function unlockTTS(): void {
  const ctx = ensureAudioCtx();
  const s = synth();

  // iOS: only an AudioContext in 'running' state lets later speech work
  // outside a gesture. resume() must be called from inside a gesture.
  if (ctx) {
    try {
      if (ctx.state === 'suspended') void ctx.resume();
      // 1-sample silent buffer activates the audio session on iOS.
      const buffer = ctx.createBuffer(1, 1, 22050);
      const source = ctx.createBufferSource();
      source.buffer = buffer;
      source.connect(ctx.destination);
      source.start(0);
    } catch { /* noop */ }
  }

  // Belt and braces: fire a real (but near-inaudible) utterance once.
  if (s && !unlockedOnce) {
    try {
      const u = new SpeechSynthesisUtterance(' ');
      u.volume = 0.01;
      s.speak(u);
    } catch { /* noop */ }
  }

  unlocked = true;

  if (!unlockedOnce) {
    unlockedOnce = true;
    console.info('[coach-tts] unlocked', {
      voiceCount: s?.getVoices().length ?? 0,
      audioCtxState: ctx?.state ?? 'none',
      ua: navigator.userAgent,
    });
  }
}

export function isTTSUnlocked(): boolean { return unlocked; }

export function speak(text: string, mood: TTSMood = 'neutral'): void {
  if (!isTTSEnabled() || !text) return;
  const s = synth();
  if (!s) { console.warn('[coach-tts] no speechSynthesis'); return; }

  // Resume AudioContext (cheap; noop when already running).
  const ctx = ensureAudioCtx();
  if (ctx && ctx.state === 'suspended') {
    void ctx.resume();
  }

  if (!unlocked) {
    unlockTTS();
    if (!unlocked) {
      console.warn('[coach-tts] not unlocked — tap the page once or press Test voice');
      return;
    }
  }

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
  utter.onend = () => console.info('[coach-tts] ended');
  utter.onerror = (e) => console.warn('[coach-tts] error', e.error, text.slice(0, 30));

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

# ============================================================ 2/2 — PlayCoach sync unlock
# Ensure the top of the sync onPieceDrop calls unlockTTS() (inside the
# drop gesture). Idempotent, so the pointerdown listener also having fired
# is harmless.
if ! grep -q 'unlockTTS()' src/pages/PlayCoach.tsx; then
  echo "ERROR: unlockTTS not imported in PlayCoach.tsx — aborting" >&2
  exit 1
fi

perl -i -pe 's/(function onPieceDrop\(from: string, to: string\): boolean \{)/$1\n    unlockTTS();/' \
  src/pages/PlayCoach.tsx

echo "Patched:"
echo "  src/lib/coachTTS.ts       (AudioContext unlock + resume on speak)"
echo "  src/pages/PlayCoach.tsx   (unlockTTS at top of onPieceDrop)"
echo
echo "Next: cd $ROOT && npm run typecheck && npm run dev"