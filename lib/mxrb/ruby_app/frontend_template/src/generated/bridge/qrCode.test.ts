import { describe, expect, it } from 'vitest';
import { qrModules, qrPath } from './qrCode';

// The version 1 code of "hello" at level L, identical to qrencode's and read by zbar.
const HELLO = `
#######..#.##.#######
#.....#.##.#..#.....#
#.###.#.##..#.#.###.#
#.###.#..#.#..#.###.#
#.###.#.#...#.#.###.#
#.....#.#..##.#.....#
#######.#.#.#.#######
........#####........
##.#..##.##...###.##.
.#####.###....#....##
..##.####.#.##...##.#
...#.#..#..#.....#.##
....#.##.##.#.#.#....
........####...##.#.#
#######.###..#.#.###.
#.....#..#####.##....
#.###.#..#.#..###...#
#.###.#.#.##...#.####
#.###.#..##.#...#.#.#
#.....#.###..##......
#######.#.###..#.#.#.`.trim();

const drawn = (modules: boolean[][]) =>
  modules.map((row) => row.map((dark) => (dark ? '#' : '.')).join('')).join('\n');

describe('QR code encoder', () => {
  it('encodes a short text as the version 1 symbol a scanner reads', () => {
    const modules = qrModules('hello');
    expect(modules).toHaveLength(21);
    expect(drawn(modules!)).toBe(HELLO);
  });

  it('grows through the versions with the text and keeps the finder patterns', () => {
    const sizes = [
      ['A'.repeat(100), 37],
      ['v7 '.repeat(50), 45],
      ['C'.repeat(271), 57],
    ] as const;
    sizes.forEach(([text, size]) => {
      const modules = qrModules(text)!;
      expect(modules).toHaveLength(size);
      // Each finder is a 7x7 ring with a 3x3 centre, at three corners.
      const finder = (top: number, left: number) =>
        [...Array(7).keys()].map((row) => modules[top + row].slice(left, left + 7));
      const expected = [
        '#######',
        '#.....#',
        '#.###.#',
        '#.###.#',
        '#.###.#',
        '#.....#',
        '#######',
      ];
      [finder(0, 0), finder(0, size - 7), finder(size - 7, 0)].forEach((corner) =>
        expect(corner.map((row) => row.map((dark) => (dark ? '#' : '.')).join(''))).toEqual(
          expected,
        ),
      );
      // The timing pattern alternates between the finders.
      for (let index = 8; index < size - 8; index += 1)
        expect(modules[6][index]).toBe(index % 2 === 0);
    });
  });

  it('rejects text beyond version 10 and draws one square per dark module', () => {
    expect(qrModules('D'.repeat(272))).toBeUndefined();
    expect(
      qrPath([
        [true, false],
        [false, true],
      ]),
    ).toBe('M0 0h1v1h-1zM1 1h1v1h-1z');
  });
});
