type Token = { kind: 'field' | 'literal'; value: string };
const patterns = new Set([
  'yyyy',
  'M',
  'MM',
  'd',
  'dd',
  'H',
  'HH',
  'm',
  'mm',
  's',
  'ss',
  'S',
  'SS',
  'SSS',
  'X',
  'XX',
  'XXX',
  'Z',
]);
const fields: Record<string, number> = { y: 0, M: 1, d: 2, H: 3, m: 4, s: 5, S: 6 };

function tokenize(pattern: string): Token[] {
  const tokens: Token[] = [];
  for (let index = 0; index < pattern.length;) {
    if (pattern.slice(index, index + 2) === "''") {
      tokens.push({ kind: 'literal', value: "'" });
      index += 2;
    } else if (pattern[index] === "'") {
      let value = '';
      let closed = false;
      index += 1;
      while (index < pattern.length) {
        if (pattern.slice(index, index + 2) === "''") {
          value += "'";
          index += 2;
        } else if (pattern[index] === "'") {
          index += 1;
          closed = true;
          break;
        } else {
          value += pattern[index];
          index += 1;
        }
      }
      if (!closed) throw new Error('Unterminated date pattern literal');
      tokens.push({ kind: 'literal', value });
    } else {
      const field = /^([A-Za-z])\1*/.exec(pattern.slice(index))?.[0];
      if (field && !patterns.has(field)) throw new Error('Unsupported date pattern: ' + field);
      tokens.push({ kind: field ? 'field' : 'literal', value: field || pattern[index] });
      index += field?.length || 1;
    }
  }
  return tokens;
}

function parsedDate(text: string, tokens: Token[]): string | null {
  // Mendix 11.12.1 client parsing differs from microflows: offset patterns fail
  // parsing, suffixes are rejected and time-only input uses today's UTC date.
  if (tokens.some((token) => token.kind === 'field' && !(token.value[0] in fields))) return null;
  const source = tokens
    .map((token, index) => {
      if (token.kind === 'literal') return token.value.replace(/[.*+?^$(){}|[\]\\]/g, '\\$&');
      const adjacent = tokens[index + 1]?.kind === 'field';
      return '[ \\t]*(-?\\d' + (adjacent ? '{' + token.value.length + '}' : '+') + ')';
    })
    .join('');
  const match = new RegExp('^' + source + '$').exec(text.trim());
  if (!match || !match[0].length) return null;
  const values = tokens.filter((token) => token.kind === 'field');
  const present = new Set(values.map((token) => fields[token.value[0]]));
  const now = new Date();
  const parts = [
    now.getUTCFullYear(),
    present.has(0) ? 1 : now.getUTCMonth() + 1,
    present.has(0) || present.has(1) ? 1 : now.getUTCDate(),
    0,
    0,
    0,
    0,
  ];
  values.forEach((token, index) => {
    parts[fields[token.value[0]]] = Number(match[index + 1]);
  });
  if (parts.some((part) => !Number.isSafeInteger(part)) || parts[0] < 1800 || parts[0] > 9999)
    return null;
  const date = new Date(
    Date.UTC(parts[0], parts[1] - 1, parts[2], parts[3], parts[4], parts[5], parts[6]),
  );
  const actual = [
    date.getUTCFullYear(),
    date.getUTCMonth() + 1,
    date.getUTCDate(),
    date.getUTCHours(),
    date.getUTCMinutes(),
    date.getUTCSeconds(),
    date.getUTCMilliseconds(),
  ];
  return parts.every((part, index) => part === actual[index]) ? date.toISOString() : null;
}

export function parseDateTimeUTC(args: unknown[]): string | null {
  if (
    args.length < 2 ||
    args.length > 3 ||
    typeof args[0] !== 'string' ||
    typeof args[1] !== 'string'
  )
    throw new Error('parseDateTimeUTC requires a date string, pattern and optional date fallback');
  const parsed = parsedDate(args[0], tokenize(args[1]));
  if (parsed !== null) return parsed;
  if (args.length === 3) {
    if (args[2] === null) return null;
    if (
      typeof args[2] === 'string' &&
      /^\d{4}-\d\d-\d\dT/.test(args[2]) &&
      Number.isFinite(Date.parse(args[2]))
    )
      return args[2];
    throw new Error('Expected a date fallback');
  }
  throw new Error('Cannot parse date and time');
}
