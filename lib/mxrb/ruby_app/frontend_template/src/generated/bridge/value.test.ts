import { describe, expect, it } from 'vitest';
import { conditionValue, expressionValue, isEntityRecord } from './value';
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
});
