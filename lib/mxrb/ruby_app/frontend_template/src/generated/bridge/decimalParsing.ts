// parseDecimal(text, pattern): Java DecimalFormat.parse (en_US, BigDecimal
// results) as Mendix 11.12.1 applies it, mirroring Runtime::DecimalParsing. The
// longest matching prefix decides the sign, digits may carry ',' anywhere when the
// pattern groups, an 'E' exponent is always read, the suffix must match, '%' and
// '‰' divide the value, and text after the suffix is ignored. Returns decimal
// text, or null when nothing parses.
interface Subpattern {
  prefix: string;
  number: string;
  suffix: string;
  scale: number;
}
type Token = [string, boolean];

const special: Record<string, [string, number]> = {
  '%': ['%', 2],
  '‰': ['‰', 3],
  '¤': ['$', 0],
};
const numberCharacters = '#0,.';

function literals(text: string): Token[] {
  return (text.match(/'(?:[^']|'')*'|[\s\S]/g) ?? []).flatMap((token): Token[] => {
    if (token === "''") return [["'", true]];
    if (!token.startsWith("'")) return [[token, false]];
    return [...token.slice(1, -1).replaceAll("''", "'")].map((character): Token => [
      character,
      true,
    ]);
  });
}

function affix(tokens: Token[]): [string, number] {
  const symbols = tokens.map(([character, quoted]) =>
    quoted ? ([character, 0] as [string, number]) : (special[character] ?? [character, 0]),
  );
  return [symbols.map(([symbol]) => symbol).join(''), Math.max(0, ...symbols.map(([, s]) => s))];
}

function subpattern(text: string): Subpattern {
  const tokens = literals(text);
  let start = tokens.findIndex(
    ([character, quoted]) => !quoted && numberCharacters.includes(character),
  );
  if (start < 0) start = tokens.length;
  let finish = tokens.findIndex(
    ([character, quoted], index) =>
      index >= start && (quoted || !`${numberCharacters}E`.includes(character)),
  );
  if (finish < 0) finish = tokens.length;
  const [prefix, prefixScale] = affix(tokens.slice(0, start));
  const [suffix, suffixScale] = affix(tokens.slice(finish));
  const number = tokens
    .slice(start, finish)
    .map(([character]) => character)
    .join('');
  return { prefix, number, suffix, scale: Math.max(prefixScale, suffixScale) };
}

function subpatterns(pattern: string): [Subpattern, Subpattern] {
  let quoted = false;
  let separator = -1;
  for (let index = 0; index < pattern.length && separator < 0; index += 1) {
    if (pattern[index] === "'") quoted = !quoted;
    else if (pattern[index] === ';' && !quoted) separator = index;
  }
  const positive = subpattern(separator < 0 ? pattern : pattern.slice(0, separator));
  const negative =
    separator < 0
      ? { ...positive, prefix: `-${positive.prefix}` }
      : { ...subpattern(pattern.slice(separator + 1)), scale: positive.scale };
  return [positive, negative];
}

function longest(
  candidates: Array<[boolean, Subpattern]>,
  part: 'prefix' | 'suffix',
): Array<[boolean, Subpattern]> {
  const length = Math.max(...candidates.map(([, item]) => item[part].length));
  return candidates.filter(([, item]) => item[part].length === length);
}

// Digits from position: unsigned decimal text and the position after them.
function digits(text: string, position: number, grouping: boolean): [string, number] | null {
  const match = (grouping ? /^([0-9,]*)(?:\.([0-9]*))?/ : /^([0-9]*)(?:\.([0-9]*))?/).exec(
    text.slice(position),
  )!;
  const whole = match[1].replaceAll(',', '');
  const fraction = match[2] ?? '';
  if (!whole && !fraction) return null;
  const end = position + match[0].length;
  const exponent = /^E(-?[0-9]+)/.exec(text.slice(end));
  // Trailing grouping separators are not consumed, as in DecimalFormat.
  const trailing = !fraction && match[1].endsWith(',') ? position + match[1].lastIndexOf(',') : -1;
  const finish = trailing >= 0 ? trailing : exponent ? end + exponent[0].length : end;
  return [`${whole || '0'}.${fraction || '0'}e${exponent ? exponent[1] : '0'}`, finish];
}

export function parseDecimalPattern(input: unknown, pattern: string): string | null {
  const text = String(input ?? '');
  const [positive, negative] = subpatterns(pattern);
  const signs = longest(
    (
      [
        [true, positive],
        [false, negative],
      ] as Array<[boolean, Subpattern]>
    ).filter(([, item]) => text.startsWith(item.prefix)),
    'prefix',
  );
  if (signs.length === 0) return null;
  const parsed = digits(text, signs[0][1].prefix.length, positive.number.includes(','));
  if (!parsed) return null;
  const rest = text.slice(parsed[1]);
  const sign = longest(
    signs.filter(([, item]) => rest.startsWith(item.suffix)),
    'suffix',
  );
  if (sign.length !== 1) return null;
  const [mantissa, exponent] = parsed[0].split('e');
  const shifted = `${mantissa}e${Number(exponent) - positive.scale}`;
  return sign[0][0] ? shifted : `-${shifted}`;
}
