import { describe, expect, it, vi } from 'vitest';
import { conditionValue, dynamicClass, expressionValue, isEntityRecord } from './value';
import type { EntityRecord } from '../types';

const animal: EntityRecord = {
  id: 'animal-1',
  type: 'VetClinic.Animal',
  attributes: { Name: 'Luna', Age: 4 },
};

describe('application value expressions', () => {
  it('reads typed record members without exposing platform objects', () => {
    expect(isEntityRecord(animal)).toBe(true);
    expect(expressionValue('$Animal/Name', animal, { Animal: animal })).toBe('Luna');
  });

  it('evaluates conditions used by generated presentation metadata', () => {
    expect(conditionValue('$Animal/Age >= 4', animal, { Animal: animal })).toBe(true);
  });

  it('reads dynamic classes as expressions', () => {
    expect(dynamicClass("'sd-pb-' + toString($currentObject/Age)", animal)).toBe('sd-pb-4');
    expect(dynamicClass("if $currentObject/Age > 3 then 'old  pet' else 'young'", animal)).toBe(
      'old pet',
    );
    expect(dynamicClass(undefined, animal)).toBe('');
    expect(dynamicClass('empty', animal)).toBe('');
    expect(dynamicClass(' card  card-wide ', animal)).toBe('card card-wide');
  });

  it('reports invalid dynamic classes once instead of reinterpreting them', () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);
    try {
      expect(dynamicClass("'tag-' + $currentObject/Name ;", animal)).toBe('');
      expect(dynamicClass("'tag-' + $currentObject/Name ;", animal)).toBe('');
      expect(dynamicClass('$currentObject/Age > 3', animal)).toBe('');
      expect(warn).toHaveBeenCalledTimes(2);
      expect(warn.mock.calls[0][0]).toContain('is not a valid expression');
      expect(warn.mock.calls[1][0]).toContain('evaluates to boolean, not to text');
    } finally {
      warn.mockRestore();
    }
  });
});
