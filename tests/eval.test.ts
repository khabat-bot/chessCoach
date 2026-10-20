import { describe, it, expect } from 'vitest';
import { classify, evalLoss, flipForBlack, toCentipawns, accuracyFromAcpl, MATE } from '../src/lib/eval';

describe('eval helpers', () => {
  it('maps mate scores into a monotonic band', () => {
    expect(toCentipawns({ mate: 3 })).toBe(MATE - 30);
    expect(toCentipawns({ mate: -3 })).toBe(-MATE + 30);
    expect(toCentipawns({ scoreCp: 42 })).toBe(42);
    expect(toCentipawns({})).toBeNull();
  });

  it('flips perspective for black to move', () => {
    expect(flipForBlack(100, 'w')).toBe(100);
    expect(flipForBlack(100, 'b')).toBe(-100);
  });

  it('never returns negative loss', () => {
    expect(evalLoss(50, 120)).toBe(0);
    expect(evalLoss(120, 20)).toBe(100);
    expect(evalLoss(null, 20)).toBeNull();
  });

  it('classifies by documented thresholds', () => {
    expect(classify(0, true)).toBe('best');
    expect(classify(0, false)).toBe('good');
    expect(classify(60, false)).toBe('inaccuracy');
    expect(classify(150, false)).toBe('mistake');
    expect(classify(400, false)).toBe('blunder');
    expect(classify(null, false)).toBe('unknown');
  });

  it('accuracy is bounded 0..100', () => {
    expect(accuracyFromAcpl(0)).toBeGreaterThan(99);
    expect(accuracyFromAcpl(5000)).toBe(0);
  });
});
