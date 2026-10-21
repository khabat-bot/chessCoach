#!/usr/bin/env bash
set -euo pipefail
cd "$HOME/chess/chess-supercoach"

cat > /tmp/patch.pl <<'PERL'
local $/;
my $f = 'src/pages/PlayCoach.tsx';
open my $in, '<', $f or die "open $f: $!";
my $src = <$in>;
close $in;

my $old = <<'OLD';
  function flushPending() {
    const line = pendingSpeechRef.current;
    if (!line) return;
    pendingSpeechRef.current = null;
    if (!isTTSEnabled()) return;
    speak(line.text, line.mood);
  }
OLD

my $new = <<'NEW';
  function flushPending(e?: Event) {
    // Skip taps on UI controls — those have their own TTS handling.
    // On iOS, `touchend` fires BEFORE `click`, so without this filter the
    // New game click would flush the previous move's queued feedback.
    if (e) {
      const t = e.target as HTMLElement | null;
      if (t && t.closest('button, a, select, input, textarea, [role="button"], [role="link"]')) {
        return;
      }
    }
    const line = pendingSpeechRef.current;
    if (!line) return;
    pendingSpeechRef.current = null;
    if (!isTTSEnabled()) return;
    speak(line.text, line.mood);
  }
NEW

if (index($src, $old) < 0) { die "OLD block not found — is PlayCoach.tsx the version from the last script?" }
$src =~ s/\Q$old\E/$new/;

open my $out, '>', $f or die "write $f: $!";
print $out $src;
close $out;
print "patched\n";
PERL

perl /tmp/patch.pl
echo
echo "Next: npm run typecheck && npm run dev"