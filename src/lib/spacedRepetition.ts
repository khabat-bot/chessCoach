export interface SrsState {
  ease: number;
  intervalDays: number;
  reps: number;
  lapses: number;
  dueAt: number;
}

const DAY = 86_400_000;

export function initialSrs(now = Date.now()): SrsState {
  return { ease: 2.5, intervalDays: 0, reps: 0, lapses: 0, dueAt: now };
}

export function review(state: SrsState, grade: 0 | 1 | 2, now = Date.now()): SrsState {
  let { ease, intervalDays, reps, lapses } = state;

  if (grade === 0) {
    lapses += 1;
    reps = 0;
    ease = Math.max(1.3, ease - 0.2);
    intervalDays = 0;
  } else {
    reps += 1;
    if (grade === 2) ease = Math.min(3.0, ease + 0.05);
    if (reps === 1) intervalDays = 1;
    else if (reps === 2) intervalDays = 3;
    else intervalDays = Math.round(intervalDays * ease);
  }

  const dueAt = intervalDays === 0 ? now : now + intervalDays * DAY;
  return { ease, intervalDays, reps, lapses, dueAt };
}
