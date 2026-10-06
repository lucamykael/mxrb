// ISO strings are the runtime's DateTime transport. Calendar arithmetic uses
// wall-clock components in a named zone; duration arithmetic uses epoch time.
const durations: Record<string, number> = {
  milliseconds: 1,
  seconds: 1000,
  minutes: 60000,
  hours: 3600000,
};
const months: Record<string, number> = { months: 1, quarters: 3, years: 12 };
const shift =
  /^(add|subtract)(milliseconds|seconds|minutes|hours|days|weeks|months|quarters|years)(utc)?$/;
const trim = /^trimto(seconds|minutes|hours|days|months|years)(utc)?$/;
export const isCalendarFunction = (name: string): boolean =>
  shift.test(name.toLowerCase()) ||
  trim.test(name.toLowerCase()) ||
  ['datetime', 'datetimeutc', 'datetimetoepoch', 'epochtodatetime'].includes(name.toLowerCase());

function integer(value: unknown): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value))
    throw new Error('Date component must be a safe integer');
  return value;
}

function instant(value: unknown): number {
  if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT/.test(value))
    throw new Error('Expected a date and time');
  const time = Date.parse(value);
  if (!Number.isFinite(time)) throw new Error('Invalid date and time');
  return time;
}

function local(time: number, zone: string): number[] {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: zone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  }).formatToParts(time);
  const read = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((part) => part.type === type)!.value);
  return ['year', 'month', 'day', 'hour', 'minute', 'second'].map((part) =>
    read(part as Intl.DateTimeFormatPartTypes),
  );
}

const wallTime = (parts: number[]): number => Date.UTC(parts[0], parts[1] - 1, ...parts.slice(2));
const offset = (time: number, zone: string): number =>
  wallTime(local(time, zone)) - Math.floor(time / 1000) * 1000;

function resolve(wall: number, zone: string): number {
  const offsets = [
    ...new Set([-2, -1, 0, 1, 2].map((days) => offset(wall + days * 86400000, zone))),
  ];
  const candidates = offsets.map((delta) => wall - delta).sort((a, b) => a - b);
  const valid = candidates.filter((time) => time + offset(time, zone) === wall);
  if (valid.length) return valid.at(-1)!;
  // Match lenient calendar construction inside a forward transition, including
  // Lord Howe's half-hour gap and Apia's skipped calendar day.
  const later = candidates.filter((time) => time + offset(time, zone) > wall);
  if (!later.length) throw new Error('Cannot resolve local date');
  return later[0];
}

export function calendarFunction(
  functionName: string,
  args: unknown[],
  timeZone = Intl.DateTimeFormat().resolvedOptions().timeZone,
): string | number {
  const name = functionName.toLowerCase();
  const operation = shift.exec(name);
  const trimming = trim.exec(name);
  const zone = name.endsWith('utc') ? 'UTC' : timeZone;
  const arity = (count: number) => {
    if (args.length !== count) throw new Error(`Expected ${count} date arguments`);
  };
  if (name === 'datetimetoepoch') {
    arity(1);
    return instant(args[0]);
  }
  if (name === 'epochtodatetime') {
    arity(1);
    return new Date(integer(args[0])).toISOString();
  }
  if (operation) {
    arity(2);
    const time = instant(args[0]);
    const count = integer(args[1]) * (operation[1] === 'add' ? 1 : -1);
    const unit = operation[2];
    if (unit in durations) return new Date(time + count * durations[unit]).toISOString();
    const parts = local(time, zone);
    let wall: number;
    if (unit in months) {
      const target = new Date(Date.UTC(parts[0], parts[1] - 1 + count * months[unit], 1));
      const last = new Date(
        Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0),
      ).getUTCDate();
      wall = Date.UTC(
        target.getUTCFullYear(),
        target.getUTCMonth(),
        Math.min(parts[2], last),
        ...parts.slice(3),
      );
    } else {
      const days = count * (unit === 'weeks' ? 7 : 1);
      const elapsed = time + days * 86400000;
      const adjusted = elapsed + offset(time, zone) - offset(elapsed, zone);
      const expected = new Date(wallTime(parts) + days * 86400000).toISOString().slice(0, 10);
      const actual = new Date(wallTime(local(adjusted, zone))).toISOString().slice(0, 10);
      return new Date(actual === expected ? adjusted : elapsed).toISOString();
    }
    return new Date(resolve(wall + (((time % 1000) + 1000) % 1000), zone)).toISOString();
  }
  if (trimming) {
    arity(1);
    const time = instant(args[0]);
    const parts = local(time, zone);
    const length =
      ['years', 'months', 'days', 'hours', 'minutes', 'seconds'].indexOf(trimming[1]) + 1;
    parts.splice(length, 6 - length, ...[0, 1, 1, 0, 0, 0].slice(length));
    return new Date(resolve(wallTime(parts), zone)).toISOString();
  }
  if (!['datetime', 'datetimeutc'].includes(name)) throw new Error(`Unknown date function ${name}`);
  if (args.length < 1 || args.length > 6) throw new Error('dateTime requires one to six arguments');
  const parts = [...args.map(integer), ...[0, 1, 1, 0, 0, 0].slice(args.length)];
  const wall = wallTime(parts);
  const actual = local(wall, 'UTC');
  if (parts[0] < 1800 || parts.some((part, index) => part !== actual[index]))
    throw new Error('Invalid dateTime components');
  return new Date(resolve(wall, zone)).toISOString();
}
