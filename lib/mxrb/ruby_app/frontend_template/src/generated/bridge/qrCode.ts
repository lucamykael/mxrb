// A QR code encoder for the native QR code widget: byte mode, error
// correction level L, versions 1 to 10 (up to 271 bytes), the mask chosen by
// the penalty rules of ISO/IEC 18004. Returns the module matrix, true for a
// dark module, or undefined when the text does not fit.

// Per version: data codewords of each block and the error correction
// codewords per block, at level L.
const VERSIONS: Array<{ blocks: number[]; ec: number; alignment: number[] }> = [
  { blocks: [19], ec: 7, alignment: [] },
  { blocks: [34], ec: 10, alignment: [6, 18] },
  { blocks: [55], ec: 15, alignment: [6, 22] },
  { blocks: [80], ec: 20, alignment: [6, 26] },
  { blocks: [108], ec: 26, alignment: [6, 30] },
  { blocks: [68, 68], ec: 18, alignment: [6, 34] },
  { blocks: [78, 78], ec: 20, alignment: [6, 22, 38] },
  { blocks: [97, 97], ec: 24, alignment: [6, 24, 42] },
  { blocks: [116, 116], ec: 30, alignment: [6, 26, 46] },
  { blocks: [68, 68, 69, 69], ec: 18, alignment: [6, 28, 50] },
];

// GF(256) with the QR primitive polynomial x^8 + x^4 + x^3 + x^2 + 1.
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
for (let value = 1, index = 0; index < 255; index += 1) {
  EXP[index] = value;
  LOG[value] = index;
  value <<= 1;
  if (value & 0x100) value ^= 0x11d;
}
for (let index = 255; index < 512; index += 1) EXP[index] = EXP[index - 255];

const multiply = (a: number, b: number): number => (a && b ? EXP[LOG[a] + LOG[b]] : 0);

function errorCorrection(data: number[], count: number): number[] {
  let generator = [1];
  for (let degree = 0; degree < count; degree += 1) {
    const next = new Array<number>(generator.length + 1).fill(0);
    generator.forEach((coefficient, index) => {
      next[index] ^= coefficient;
      next[index + 1] ^= multiply(coefficient, EXP[degree]);
    });
    generator = next;
  }
  const remainder = new Array<number>(count).fill(0);
  for (const byte of data) {
    const factor = byte ^ remainder.shift()!;
    remainder.push(0);
    if (factor)
      generator.slice(1).forEach((coefficient, index) => {
        remainder[index] ^= multiply(coefficient, factor);
      });
  }
  return remainder;
}

// The data bit stream: byte mode, the byte count, the bytes, the terminator
// and the pad codewords, interleaved with the error correction codewords.
function codewords(bytes: Uint8Array, version: number): number[] {
  const { blocks, ec } = VERSIONS[version - 1];
  const capacity = blocks.reduce((sum, size) => sum + size, 0);
  const bits: number[] = [];
  const push = (value: number, length: number) => {
    for (let bit = length - 1; bit >= 0; bit -= 1) bits.push((value >> bit) & 1);
  };
  push(0b0100, 4);
  push(bytes.length, version < 10 ? 8 : 16);
  bytes.forEach((byte) => push(byte, 8));
  push(0, Math.min(4, capacity * 8 - bits.length));
  while (bits.length % 8) bits.push(0);
  const data: number[] = [];
  for (let index = 0; index < bits.length; index += 8)
    data.push(bits.slice(index, index + 8).reduce((value, bit) => (value << 1) | bit, 0));
  for (let pad = 0; data.length < capacity; pad += 1) data.push(pad % 2 ? 0x11 : 0xec);

  let offset = 0;
  const dataBlocks = blocks.map((size) => {
    const block = data.slice(offset, offset + size);
    offset += size;
    return block;
  });
  const ecBlocks = dataBlocks.map((block) => errorCorrection(block, ec));
  const result: number[] = [];
  const longest = Math.max(...blocks);
  for (let index = 0; index < longest; index += 1)
    dataBlocks.forEach((block) => {
      if (index < block.length) result.push(block[index]);
    });
  for (let index = 0; index < ec; index += 1)
    ecBlocks.forEach((block) => result.push(block[index]));
  return result;
}

type Matrix = { size: number; modules: Uint8Array; reserved: Uint8Array };

const mark = (matrix: Matrix, row: number, column: number, dark: boolean) => {
  matrix.modules[row * matrix.size + column] = dark ? 1 : 0;
  matrix.reserved[row * matrix.size + column] = 1;
};

// The finder, separator, timing and alignment patterns, the dark module, and
// the reserved format and version areas.
function functionPatterns(version: number): Matrix {
  const size = version * 4 + 17;
  const matrix: Matrix = {
    size,
    modules: new Uint8Array(size * size),
    reserved: new Uint8Array(size * size),
  };
  const finder = (top: number, left: number) => {
    for (let row = -1; row <= 7; row += 1)
      for (let column = -1; column <= 7; column += 1) {
        const y = top + row;
        const x = left + column;
        if (y < 0 || x < 0 || y >= size || x >= size) continue;
        const edge = Math.max(Math.abs(row - 3), Math.abs(column - 3));
        mark(matrix, y, x, edge <= 1 || edge === 3);
      }
  };
  finder(0, 0);
  finder(0, size - 7);
  finder(size - 7, 0);
  for (let index = 8; index < size - 8; index += 1) {
    mark(matrix, 6, index, index % 2 === 0);
    mark(matrix, index, 6, index % 2 === 0);
  }
  const centers = VERSIONS[version - 1].alignment;
  const last = centers[centers.length - 1];
  centers.forEach((row) =>
    centers.forEach((column) => {
      // No alignment pattern where a finder sits.
      if ((row === 6 && (column === 6 || column === last)) || (row === last && column === 6))
        return;
      for (let dy = -2; dy <= 2; dy += 1)
        for (let dx = -2; dx <= 2; dx += 1)
          mark(matrix, row + dy, column + dx, Math.max(Math.abs(dy), Math.abs(dx)) !== 1);
    }),
  );
  mark(matrix, size - 8, 8, true);
  for (let index = 0; index < 8; index += 1) {
    matrix.reserved[8 * size + index] = 1;
    matrix.reserved[index * size + 8] = 1;
    matrix.reserved[8 * size + size - 1 - index] = 1;
    matrix.reserved[(size - 1 - index) * size + 8] = 1;
  }
  matrix.reserved[8 * size + 8] = 1;
  if (version >= 7)
    for (let index = 0; index < 18; index += 1) {
      const row = Math.floor(index / 3);
      const column = size - 11 + (index % 3);
      matrix.reserved[row * size + column] = 1;
      matrix.reserved[column * size + row] = 1;
    }
  return matrix;
}

// Places the codeword bits in the zigzag order, two columns at a time from the
// right, skipping the vertical timing column.
function placeData(matrix: Matrix, data: number[]) {
  const { size } = matrix;
  let bit = 0;
  let upward = true;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right -= 1;
    for (let step = 0; step < size; step += 1) {
      const row = upward ? size - 1 - step : step;
      for (const column of [right, right - 1]) {
        const index = row * size + column;
        if (matrix.reserved[index]) continue;
        const byte = data[bit >> 3];
        matrix.modules[index] = byte === undefined ? 0 : (byte >> (7 - (bit & 7))) & 1;
        bit += 1;
      }
    }
    upward = !upward;
  }
}

const MASKS: Array<(row: number, column: number) => boolean> = [
  (row, column) => (row + column) % 2 === 0,
  (row) => row % 2 === 0,
  (_row, column) => column % 3 === 0,
  (row, column) => (row + column) % 3 === 0,
  (row, column) => (Math.floor(row / 2) + Math.floor(column / 3)) % 2 === 0,
  (row, column) => ((row * column) % 2) + ((row * column) % 3) === 0,
  (row, column) => (((row * column) % 2) + ((row * column) % 3)) % 2 === 0,
  (row, column) => (((row + column) % 2) + ((row * column) % 3)) % 2 === 0,
];

const bch = (value: number, length: number, generator: number, degree: number): number => {
  let code = value << degree;
  for (let bit = length - 1; bit >= degree; bit -= 1)
    if (code & (1 << bit)) code ^= generator << (bit - degree);
  return (value << degree) | code;
};

function writeFormat(matrix: Matrix, mask: number) {
  const { size } = matrix;
  const set = (row: number, column: number, dark: boolean) => {
    matrix.modules[row * size + column] = dark ? 1 : 0;
  };
  // Level L is 01 in the format information.
  const format = bch((0b01 << 3) | mask, 15, 0b10100110111, 10) ^ 0b101010000010010;
  for (let index = 0; index < 15; index += 1) {
    const dark = ((format >> index) & 1) === 1;
    if (index < 6) set(index, 8, dark);
    else if (index === 6) set(7, 8, dark);
    else if (index === 7) set(8, 8, dark);
    else if (index === 8) set(8, 7, dark);
    else set(8, 14 - index, dark);
    if (index < 8) set(8, size - 1 - index, dark);
    else set(size - 15 + index, 8, dark);
  }
}

function writeVersion(matrix: Matrix, version: number) {
  if (version < 7) return;
  const { size } = matrix;
  const info = bch(version, 18, 0b1111100100101, 12);
  for (let index = 0; index < 18; index += 1) {
    const dark = ((info >> index) & 1) === 1;
    const row = Math.floor(index / 3);
    const column = size - 11 + (index % 3);
    matrix.modules[row * size + column] = dark ? 1 : 0;
    matrix.modules[column * size + row] = dark ? 1 : 0;
  }
}

// The penalty score of ISO/IEC 18004 8.8.2: runs, blocks, finder-like
// patterns and the dark module proportion.
function penalty(modules: Uint8Array, size: number): number {
  let score = 0;
  const at = (row: number, column: number) => modules[row * size + column];
  const runs = (read: (index: number, position: number) => number) => {
    for (let index = 0; index < size; index += 1) {
      let run = 1;
      for (let position = 1; position < size; position += 1) {
        if (read(index, position) === read(index, position - 1)) {
          run += 1;
          if (position === size - 1 && run >= 5) score += run - 2;
        } else {
          if (run >= 5) score += run - 2;
          run = 1;
        }
      }
    }
  };
  runs((row, column) => at(row, column));
  runs((column, row) => at(row, column));
  for (let row = 0; row < size - 1; row += 1)
    for (let column = 0; column < size - 1; column += 1) {
      const sum =
        at(row, column) + at(row, column + 1) + at(row + 1, column) + at(row + 1, column + 1);
      if (sum === 0 || sum === 4) score += 3;
    }
  const finderLike = (read: (position: number) => number) => {
    for (let start = 0; start <= size - 11; start += 1) {
      const pattern = [...Array(11).keys()].map((offset) => read(start + offset)).join('');
      if (pattern === '10111010000' || pattern === '00001011101') score += 40;
    }
  };
  for (let index = 0; index < size; index += 1) {
    finderLike((position) => at(index, position));
    finderLike((position) => at(position, index));
  }
  const dark = modules.reduce((sum, module) => sum + module, 0);
  score += Math.floor(Math.abs((dark * 100) / (size * size) - 50) / 5) * 10;
  return score;
}

export function qrModules(text: string): boolean[][] | undefined {
  const bytes = new TextEncoder().encode(text);
  const version =
    VERSIONS.findIndex(({ blocks }, index) => {
      const capacity = blocks.reduce((sum, size) => sum + size, 0);
      return capacity - (index < 9 ? 2 : 3) >= bytes.length;
    }) + 1;
  if (version === 0) return undefined;
  const base = functionPatterns(version);
  placeData(base, codewords(bytes, version));
  const { size } = base;
  let best: Uint8Array | undefined;
  let bestScore = Infinity;
  MASKS.forEach((pattern, mask) => {
    const candidate = new Uint8Array(base.modules);
    for (let row = 0; row < size; row += 1)
      for (let column = 0; column < size; column += 1) {
        const index = row * size + column;
        if (!base.reserved[index] && pattern(row, column)) candidate[index] ^= 1;
      }
    const masked: Matrix = { size, modules: candidate, reserved: base.reserved };
    writeFormat(masked, mask);
    writeVersion(masked, version);
    const score = penalty(candidate, size);
    if (score < bestScore) {
      bestScore = score;
      best = candidate;
    }
  });
  const modules = best!;
  return [...Array(size).keys()].map((row) =>
    [...Array(size).keys()].map((column) => modules[row * size + column] === 1),
  );
}

// The dark modules as one SVG path, each module a unit square.
export const qrPath = (modules: boolean[][]): string =>
  modules
    .flatMap((row, y) => row.flatMap((dark, x) => (dark ? [`M${x} ${y}h1v1h-1z`] : [])))
    .join('');
