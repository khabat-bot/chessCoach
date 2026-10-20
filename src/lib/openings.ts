export interface Opening {
  id: string;
  name: string;
  eco: string;
  moves: string[];
  idea: string;
}

export const OPENINGS: Opening[] = [
  { id: 'berlin', name: 'Berlin Defence', eco: 'C65',
    moves: ['e4','e5','Nf3','Nc6','Bb5','Nf6'],
    idea: 'Solid, drawish structure; Black invites the endgame.' },
  { id: 'ruy', name: 'Ruy Lopez', eco: 'C60',
    moves: ['e4','e5','Nf3','Nc6','Bb5'],
    idea: 'Pressure on the c6-knight and long-term central play.' },
  { id: 'sicilian', name: 'Sicilian Defence', eco: 'B20',
    moves: ['e4','c5'],
    idea: 'Asymmetric counterplay against e4.' },
  { id: 'najdorf', name: 'Sicilian Najdorf', eco: 'B90',
    moves: ['e4','c5','Nf3','d6','d4','cxd4','Nxd4','Nf6','Nc3','a6'],
    idea: 'Flexible queenside play and control of d5.' },
  { id: 'french', name: 'French Defence', eco: 'C00',
    moves: ['e4','e6'],
    idea: 'Solid centre, counterattack with c5 and f6.' },
  { id: 'caro', name: 'Caro-Kann Defence', eco: 'B10',
    moves: ['e4','c6','d4','d5'],
    idea: 'Sturdy pawn chain with a healthy light-squared bishop.' },
  { id: 'qgd', name: "Queen's Gambit Declined", eco: 'D30',
    moves: ['d4','d5','c4','e6'],
    idea: 'Classical central tension and piece development.' },
  { id: 'slav', name: 'Slav Defence', eco: 'D10',
    moves: ['d4','d5','c4','c6'],
    idea: 'Holds d5 while keeping the c8-bishop free.' },
  { id: 'kings-indian', name: "King's Indian Defence", eco: 'E60',
    moves: ['d4','Nf6','c4','g6','Nc3','Bg7','e4','d6'],
    idea: 'Hypermodern: concede the centre, strike back later.' },
  { id: 'london', name: 'London System', eco: 'D02',
    moves: ['d4','d5','Nf3','Nf6','Bf4'],
    idea: 'Simple, repeatable setup with Bf4 and e3.' },
  { id: 'italian', name: 'Italian Game', eco: 'C50',
    moves: ['e4','e5','Nf3','Nc6','Bc4'],
    idea: 'Fast development aiming at f7.' },
  { id: 'scotch', name: 'Scotch Game', eco: 'C45',
    moves: ['e4','e5','Nf3','Nc6','d4'],
    idea: 'Immediate central clarification.' },
  { id: 'english', name: 'English Opening', eco: 'A10',
    moves: ['c4'],
    idea: 'Flank strategy, often transposing to d4 systems.' },
  { id: 'kings-gambit', name: "King's Gambit", eco: 'C30',
    moves: ['e4','e5','f4'],
    idea: 'Sharp, romantic attacking play on the f-file.' },
  { id: 'pirc', name: 'Pirc Defence', eco: 'B07',
    moves: ['e4','d6','d4','Nf6','Nc3','g6'],
    idea: 'Hypermodern setup with pressure on the centre.' }
];

export function openingFor(moves: string[]): Opening | null {
  let best: Opening | null = null;
  for (const o of OPENINGS) {
    if (o.moves.length <= moves.length && o.moves.length > (best?.moves.length ?? 0)) {
      if (o.moves.every((m, i) => moves[i] === m)) best = o;
    }
  }
  return best;
}
