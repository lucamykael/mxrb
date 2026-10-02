import type { EntityRecord } from '../types';
import { conditionValue } from './value';

// Evaluate only the public, ACL-filtered DTO. Never query private attributes to
// decide which objects the user may see. Unsupported XPath fails closed.
export function selectable(records: EntityRecord[], xpath: string, current: EntityRecord | null) {
  if (!xpath.trim()) return records;
  const groups: string[] = [];
  let depth = 0;
  let quoted = false;
  let group = '';
  for (let index = 0; index < xpath.length; index++) {
    const char = xpath[index];
    if (char === "'") {
      if (quoted && xpath[index + 1] === "'") {
        group += "''";
        index++;
        continue;
      }
      quoted = !quoted;
    }
    if (!quoted && char === '[') {
      if (depth) throw new Error('Nested selectable XPath is not supported');
      depth = 1;
      continue;
    }
    if (!quoted && char === ']') {
      if (!depth || !group.trim()) throw new Error('Invalid selectable XPath');
      groups.push(group);
      group = '';
      depth = 0;
      continue;
    }
    if (depth) group += char;
    else if (char.trim()) throw new Error('Selectable XPath must contain bracketed predicates');
  }
  if (quoted || depth || !groups.length) throw new Error('Invalid selectable XPath');
  const expressions = groups.map((predicate) =>
    predicate.replace(
      /'(?:[^']|'')*'|\$[A-Za-z_]\w*(?:\/[\w.]+)?|[A-Za-z_][\w./]*/g,
      (token, offset: number) => {
        if (
          token.startsWith("'") ||
          token.startsWith('$') ||
          /^(true|false|empty|and|or|not|div|mod)$/.test(token) ||
          predicate
            .slice(offset + token.length)
            .trimStart()
            .startsWith('(')
        )
          return token;
        if (token.includes('/'))
          throw new Error('Association predicates require an explicit selectable source');
        if (token.split('.').length === 3) return token; // enumeration literal
        return `$candidate/${token}`;
      },
    ),
  );
  return records.filter((candidate) =>
    expressions.every((expression) =>
      conditionValue(expression, candidate, { candidate, currentObject: current }),
    ),
  );
}
