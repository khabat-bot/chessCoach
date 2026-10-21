#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/chess/chess-supercoach"

# Replace the pointerdown-only listener block with the wider set.
perl -0pi -e '
  s{
    useEffect\(\(\)\s*=>\s*\{\s*
      if\s*\(!isTTSEnabled\(\)\)\s*return;\s*
      const\s+handler\s*=\s*\(\)\s*=>\s*\{\s*if\s*\(!isTTSUnlocked\(\)\)\s*unlockTTS\(\);\s*\};\s*
      document\.addEventListener\(.pointerdown.,\s*handler,\s*\{\s*once:\s*true\s*\}\);\s*
      document\.addEventListener\(.touchstart.,\s*handler,\s*\{\s*once:\s*true\s*\}\);\s*
      document\.addEventListener\(.keydown.,\s*handler,\s*\{\s*once:\s*true\s*\}\);\s*
      return\s*\(\)\s*=>\s*\{\s*
        document\.removeEventListener\(.pointerdown.,\s*handler\);\s*
        document\.removeEventListener\(.touchstart.,\s*handler\);\s*
        document\.removeEventListener\(.keydown.,\s*handler\);\s*
      \};\s*
    \},\s*\[\]\)\;
  }{
    useEffect(() => {
      if (!isTTSEnabled()) return;
      const handler = (e: Event) => {
        if (isTTSUnlocked()) return;
        console.info("[coach-tts] auto-unlock via " + e.type);
        unlockTTS();
      };
      const events = ["pointerdown", "touchend", "click", "keydown"];
      events.forEach(ev => document.addEventListener(ev, handler, { capture: true }));
      return () => {
        events.forEach(ev => document.removeEventListener(ev, handler, { capture: true }));
      };
    }, []);
  }sx
' src/pages/PlayCoach.tsx

echo "=== listeners now: ==="
grep -n 'addEventListener' src/pages/PlayCoach.tsx
echo
echo "Next: npm run typecheck && npm run dev"