import { format, getWeekYear, parse, type Day, type Locale } from 'date-fns';
import { enUS } from 'date-fns/locale/en-US';

// The Mendix client formats and parses nanoflow dates with date-fns after
// rewriting the Java pattern: unsupported Java letters become literals, short
// widths are widened and `u` (ISO day of week) maps to date-fns `i`.
type Replacement = [string, string];

const repeated = (letter: string, replacement: (symbol: string) => string): Replacement[] =>
  [1, 2, 3, 4, 5, 6].map((count) => [letter.repeat(count), replacement(letter.repeat(count))]);
const literal = (symbol: string) => `'${symbol}'`;

const javaToMendix: Replacement[] = [
  ['GGGG', 'GGG'],
  ['GGGGG', 'GGG'],
  ['GGGGGG', 'GGG'],
  ['MMMMM', 'MMMM'],
  ['E', 'EEE'],
  ['EE', 'EEE'],
  ['EEEEE', 'EEEE'],
  ['EEEEEE', 'EEEE'],
  ['S', 'SSS'],
  ['SS', 'SSS'],
  ['SSSS', "'0'SSS"],
  ['SSSSS', "'00'SSS"],
  ['SSSSSS', "'000'SSS"],
  ...['W', 'F', 'Z', 'z', 'X'].flatMap((letter) => repeated(letter, literal)),
];
const mendixToDateFns: Replacement[] = [
  ['yyy', 'yyyy'],
  ['E', 'e'],
  ['EE', 'ee'],
  ['YYY', 'YYYY'],
  ['Z', 'XX'],
  ['ZZ', 'XX'],
  ['ZZZ', 'XX'],
  ['ZZZZ', 'zzzz'],
];

// Replaces whole runs of one letter, leaving quoted literals untouched.
function replaceSymbols(pattern: string, replacements: Replacement[]): string {
  const groups = pattern.match(/''|'(?:''|[^'])+(?:'|$)|(.)\1*/g) ?? [];
  return groups
    .map((group) => replacements.find(([existing]) => existing === group)?.[1] ?? group)
    .join('');
}

const toDateFnsPattern = (javaPattern: string) =>
  replaceSymbols(replaceSymbols(javaPattern, javaToMendix), mendixToDateFns);

function language(): string {
  const tag =
    (typeof document !== 'undefined' && document.documentElement.lang) ||
    (typeof navigator !== 'undefined' && navigator.language) ||
    'en-US';
  try {
    return Intl.getCanonicalLocales(tag)[0] ?? 'en-US';
  } catch {
    return 'en-US';
  }
}

// CLDR regions whose first week needs four days (Java's minimalDaysInFirstWeek);
// browsers no longer report it, so it is read from the region of the language.
const fourDayWeekRegions = new Set(
  (
    'AD AN AT AX BE BG CH CZ DE DK EE ES FI FJ FO FR GB GF GG GI GP GR HU IE IM IS IT JE LI LT LU ' +
    'MC MQ NL NO PL PT RE RU SE SJ SK SM VA'
  ).split(' '),
);
type Week = { weekStartsOn: Day; firstWeekContainsDate: 1 | 4 };
function weekRules(tag: string): Week {
  const locale = new Intl.Locale(tag).maximize() as Intl.Locale & {
    getWeekInfo?: () => { firstDay: number };
    weekInfo?: { firstDay: number };
  };
  const info = locale.getWeekInfo?.() ?? locale.weekInfo;
  return {
    weekStartsOn: ((info?.firstDay ?? 7) % 7) as Day,
    firstWeekContainsDate: fourDayWeekRegions.has(locale.region ?? '') ? 4 : 1,
  };
}

const sample = (month: number, day = 5) => new Date(Date.UTC(2024, month, day, 13, 4, 5));
function names(tag: string, options: Intl.DateTimeFormatOptions, type: string, dates: Date[]) {
  const formatter = new Intl.DateTimeFormat(tag, { ...options, timeZone: 'UTC' });
  return dates.map(
    (date) => formatter.formatToParts(date).find((part) => part.type === type)?.value ?? '',
  );
}

type Width = 'narrow' | 'short' | 'abbreviated' | 'wide' | 'any';
const escaped = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// Matches the longest name at the start of the text, case-insensitively, and
// reports the index of the first name it starts with.
function matcher(values: string[]) {
  const longest = [...new Set(values)].sort((left, right) => right.length - left.length);
  const any = new RegExp(`^(${longest.map(escaped).join('|')})`, 'i');
  return (text: string) => {
    const match = any.exec(text)?.[0];
    if (match === undefined) return null;
    const value = values.findIndex((name) => new RegExp(`^${escaped(name)}`, 'i').test(match));
    return value < 0 ? null : { value, rest: text.slice(match.length) };
  };
}

// Month, weekday, era and day period names of the session language with the
// week rules of its region, built like the locale of the Mendix client: narrow
// widths use full month names and abbreviated weekdays, day periods are AM/PM.
function sessionLocale(tag: string): Locale {
  const months = Array.from({ length: 12 }, (_, month) => sample(month));
  // 2024-09-01 is a Sunday; weekday indexes start on Sunday.
  const days = Array.from({ length: 7 }, (_, day) => sample(8, day + 1));
  const standalone = names(tag, { month: 'long' }, 'month', months);
  const standaloneShort = names(tag, { month: 'short' }, 'month', months);
  const formatting = names(tag, { day: 'numeric', month: 'long' }, 'month', months);
  const formattingShort = names(tag, { day: 'numeric', month: 'short' }, 'month', months);
  const weekdays = names(tag, { weekday: 'long', day: 'numeric', month: 'long' }, 'weekday', days);
  const shortWeekdays = names(tag, { weekday: 'short', day: 'numeric', month: 'long' }, 'weekday', days);
  const eras = names(tag, { era: 'short', year: 'numeric' }, 'era', [
    new Date(Date.UTC(-1, 0, 1)),
    sample(0),
  ]);
  const periods = names(tag, { hour: 'numeric', hour12: true }, 'dayPeriod', [
    new Date(Date.UTC(2024, 0, 1, 1)),
    new Date(Date.UTC(2024, 0, 1, 13)),
  ]);
  const monthNames = (width: Width | undefined, context: string | undefined) => {
    const [wide, short] =
      context === 'formatting' ? [formatting, formattingShort] : [standalone, standaloneShort];
    return width === 'abbreviated' ? short : wide;
  };
  const monthMatchers = (context: string) => {
    const [wide, short] =
      context === 'formatting' ? [formatting, formattingShort] : [standalone, standaloneShort];
    const abbreviated = matcher([...short, ...wide]);
    const full = matcher(wide);
    return (text: string, width?: Width) => {
      const result = width === 'abbreviated' ? abbreviated(text) : full(text);
      return result && { ...result, value: result.value % 12 };
    };
  };
  const formattingMonth = monthMatchers('formatting');
  const standaloneMonth = monthMatchers('standalone');
  const dayMatchers = { wide: matcher(weekdays), other: matcher(shortWeekdays) };
  return {
    ...enUS,
    code: tag,
    options: weekRules(tag),
    localize: {
      ...enUS.localize,
      era: (era) => eras[era] ?? '',
      month: (month, options) => monthNames(options?.width, options?.context)[month] ?? '',
      day: (day, options) => (options?.width === 'wide' ? weekdays : shortWeekdays)[day] ?? '',
      dayPeriod: (period) => (period === 'am' ? periods[0] : period === 'pm' ? periods[1] : ''),
    },
    match: {
      ...enUS.match,
      era: matcher(eras),
      month: (text, options) =>
        (options?.context === 'formatting' ? formattingMonth : standaloneMonth)(
          text,
          options?.width as Width | undefined,
        ),
      day: (text, options) =>
        (options?.width === 'wide' || !options?.width ? dayMatchers.wide : dayMatchers.other)(
          text,
        ),
      dayPeriod: (text) => {
        const result = matcher(periods)(text);
        return result && { ...result, value: result.value ? 'pm' : 'am' };
      },
    },
  } as Locale;
}

let cached: { tag: string; locale: Locale } | undefined;
export function dateLocale(): Locale {
  const tag = language();
  if (cached?.tag !== tag) cached = { tag, locale: sessionLocale(tag) };
  return cached.locale;
}

const options = () => ({
  useAdditionalDayOfYearTokens: true,
  useAdditionalWeekYearTokens: true,
  locale: dateLocale(),
});

// Java patterns of the session language's short styles, as the Mendix
// runtime sends them: nanoflow defaults keep two-digit years, toString shows four.
function intlPattern(tag: string, style: Intl.DateTimeFormatOptions): string {
  const parts = new Intl.DateTimeFormat(tag, { ...style, timeZone: 'UTC' }).formatToParts(
    new Date(Date.UTC(2024, 0, 5, 13, 4, 5)),
  );
  const twelveHour = new Intl.DateTimeFormat(tag, { ...style, timeZone: 'UTC' }).resolvedOptions()
    .hour12;
  // Java's CLDR data puts a narrow no-break space before English day periods;
  // browsers print a plain space there.
  const english = /^en\b/i.test(tag);
  return parts
    .map(({ type, value }, index) => {
      if (english && value === ' ' && parts[index + 1]?.type === 'dayPeriod') return '\u202f';
      if (type === 'year') return value.length === 2 ? 'yy' : 'y';
      if (type === 'month') return /^\d+$/.test(value) ? 'M'.repeat(value.length) : 'MMM';
      if (type === 'day') return 'd'.repeat(value.length);
      if (type === 'hour') return (twelveHour ? 'h' : 'H').repeat(value.length);
      if (type === 'minute') return 'mm';
      if (type === 'second') return 'ss';
      if (type === 'dayPeriod') return 'a';
      if (type === 'weekday') return 'EEE';
      return /[A-Za-z']/.test(value) ? `'${value.replaceAll("'", "''")}'` : value;
    })
    .join('');
}

type Style = 'date' | 'time' | 'datetime';
const styles: Record<Style, Intl.DateTimeFormatOptions> = {
  date: { dateStyle: 'short' },
  time: { timeStyle: 'short' },
  datetime: { dateStyle: 'short', timeStyle: 'short' },
};
export const defaultPattern = (style: Style, fourDigitYear = false): string => {
  const pattern = intlPattern(language(), styles[style]);
  return fourDigitYear ? replaceSymbols(pattern, [['yy', 'yyyy']]) : pattern;
};

// UTC variants read and write the UTC components through local dates.
export function localized(date: Date): Date {
  const result = new Date();
  result.setFullYear(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
  result.setHours(
    date.getUTCHours(),
    date.getUTCMinutes(),
    date.getUTCSeconds(),
    date.getUTCMilliseconds(),
  );
  return result;
}
export function delocalized(date: Date): Date {
  const result = new Date();
  result.setUTCFullYear(date.getFullYear(), date.getMonth(), date.getDate());
  result.setUTCHours(date.getHours(), date.getMinutes(), date.getSeconds(), date.getMilliseconds());
  return result;
}

// `u` becomes date-fns `i`; the client pads by the run length measured on the
// pattern, which only matters for repeated `u`.
const dayOfWeek = (pattern: string) => ({
  start: pattern.indexOf('u'),
  end: pattern.lastIndexOf('u'),
  converted: pattern.replace(/u+/g, 'i'),
});

const thai = () => /^th\b/i.test(language());
function buddhist(pattern: string, date: Date): string {
  if (!thai()) return pattern;
  const year = date.getFullYear() + 543;
  const weekYear = getWeekYear(date, { locale: dateLocale() }) + 543;
  const twoDigits = (value: number) => String(value).slice(-2);
  return replaceSymbols(pattern, [
    ['yy', `'${twoDigits(year)}'`],
    ['yyyy', `'${year}'`],
    ['YY', `'${twoDigits(weekYear)}'`],
    ['YYYY', `'${weekYear}'`],
  ]);
}

export function formatJavaPattern(date: Date, javaPattern: string): string {
  const pattern = buddhist(toDateFnsPattern(javaPattern), date);
  if (!pattern.includes('u')) return format(date, pattern, options());
  const { start, end, converted } = dayOfWeek(pattern);
  const text = format(date, converted, options());
  return text.slice(0, start) + '0'.repeat(end - start) + text.slice(start);
}

// Tries the two-digit-year form first, then the pattern itself, and both with
// the first no-break, figure and narrow no-break space read as plain spaces.
export function parseJavaPattern(value: string, javaPattern: string): Date | undefined {
  const pattern = toDateFnsPattern(javaPattern);
  const twoDigitYear = replaceSymbols(pattern, [['yyyy', 'yy']]);
  const plain = (text: string) =>
    text.replace('\u00a0', ' ').replace('\u2007', ' ').replace('\u202f', ' ');
  for (const candidate of [twoDigitYear, pattern, plain(pattern), plain(twoDigitYear)]) {
    const { start, end, converted } = dayOfWeek(candidate);
    const date = parse(value.slice(0, start) + value.slice(end), converted, new Date(), options());
    if (Number.isNaN(date.getTime())) continue;
    if (thai() && /[yY]/.test(converted.replace(/'(?:''|[^'])*'?/g, '')))
      date.setFullYear(date.getFullYear() - 543);
    return date;
  }
  return undefined;
}
