import { describe, expect, it, vi } from 'vitest';
import { conditionValue, dynamicClass, expressionValue, isEntityRecord, withXPath } from './value';
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

describe('data source XPath requests', () => {
  const owner: EntityRecord = { id: 'owner-1', type: 'VetClinic.Owner', attributes: {} };
  const query = (path: string) => new URLSearchParams(path.split('?')[1]);

  it('leaves paths without a constraint unchanged', () => {
    expect(withXPath('/api/entities/A', undefined, animal)).toBe('/api/entities/A');
  });

  it('sends the context object for $currentObject and [%CurrentObject%]', () => {
    for (const xpath of ['[Owner = $currentObject]', "[Owner = '[%CurrentObject%]']"]) {
      const sent = query(withXPath('/api/entities/A?association=X', xpath, animal));
      expect(sent.get('xpath')).toBe(xpath);
      expect(sent.get('association')).toBe('X');
      expect([sent.get('xpath_context_type'), sent.get('xpath_context_id')]).toEqual([
        'VetClinic.Animal',
        'animal-1',
      ]);
    }
    expect(query(withXPath('/api/entities/A', '[Age > 1]', animal)).has('xpath_context_id')).toBe(
      false,
    );
  });

  it('sends the page parameters the constraint refers to', () => {
    const variables = { Owner: owner, Limit: { __mxrb_decimal: '2.5' }, Unused: 3 };
    const sent = query(
      withXPath(
        '/api/entities/A',
        '[Owner = $Owner][Age > $Limit][Name = $Owner/Name]',
        null,
        variables,
      ),
    );
    expect(JSON.parse(sent.get('xpath_variables') || '{}')).toEqual({
      Owner: { type: 'VetClinic.Owner', id: 'owner-1' },
      Limit: { __mxrb_decimal: '2.5' },
    });
    expect(
      query(withXPath('/api/entities/A', '[Age > $Missing]', null, variables)).has(
        'xpath_variables',
      ),
    ).toBe(false);
  });
});
