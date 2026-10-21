// src/lib/coachTTS.ts
//
// Minimal speech wrapper. Speech only fires when the caller invokes speak()
// from inside a real user gesture (e.g. a click handler). That is the only
// reliable path on iOS Safari and it works everywhere else too.

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

/**
 * Speak. Call from inside a click handler for guaranteed playback.
 * If nothing happens on iOS Safari, it's because the device is on silent
 * mode (physical side switch), or the browser is missing a voice.
 */
export function speak(text: string, mood: TTSMood = 'neutral'): void {
  const s = synth();
  if (!s || !text) return;

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

  const start = () => {
    try { s.speak(utter); } catch { /* noop */ }
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
