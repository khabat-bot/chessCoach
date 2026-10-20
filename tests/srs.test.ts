import { describe, it, expect } from 'vitest';
import { initialSrs, review } from '../src/lib/spacedRepetition';

describe('spaced repetition', () => {
  it('schedules a clean solve into the future', () => {
    const s = review(initialSrs(0), 2, 0);
    expect(s.reps).toBe(1);
    expect(s.intervalDays).toBe(1);
    expect(s.dueAt).toBeGreaterThan(0);
  });

  it('resets interval on failure', () => {
    let s = review(initialSrs(0), 2, 0);
    s = review(s, 2, 0);
    s = review(s, 0, 0);
    expect(s.lapses).toBe(1);
    expect(s.intervalDays).toBe(0);
    expect(s.reps).toBe(0);
  });

  it('keeps ease within bounds', () => {
    let s = initialSrs(0);
    for (let i = 0; i < 20; i++) s = review(s, 0, 0);
    expect(s.ease).toBeGreaterThanOrEqual(1.3);
  });
});
