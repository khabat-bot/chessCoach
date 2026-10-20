import { describe, it, expect } from 'vitest';
import { parsePgn, isValidFen, fenAtPly, PgnError } from '../src/lib/pgn';

const SAMPLE = '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6';

describe('pgn', () => {
  it('parses a valid pgn', () => {
    const g = parsePgn(SAMPLE);
    expect(g.plies).toBe(6);
    expect(g.pgn).toContain('e4');
  });

  it('rejects empty pgn', () => {
    expect(() => parsePgn('   ')).toThrow(PgnError);
  });

  it('rejects garbage', () => {
    expect(() => parsePgn('this is not chess')).toThrow(PgnError);
  });

  it('validates fens', () => {
    expect(isValidFen('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1')).toBe(true);
    expect(isValidFen('not a fen')).toBe(false);
  });

  it('replays to a given ply', () => {
    expect(fenAtPly(SAMPLE, 0)).toContain(' w ');
    expect(fenAtPly(SAMPLE, 1)).toContain(' b ');
  });
});
