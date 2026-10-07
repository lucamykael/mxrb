import { act, render, screen, waitFor } from '@testing-library/react';
import { describe, expect, it } from 'vitest';
import type { ApplicationSchema, EntityRecord } from '../types';
import { chartCaption, captionDate, useCaptionEnvironment } from './captions';
import { PageParameters } from './PageVariables';
import { decimal } from './decimal';

const record: EntityRecord = {
  id: '1',
  type: 'App.Item',
  attributes: {
    Amount: 1234.5,
    Count: 1234,
    Date: '2026-10-06T12:34:56Z',
    Name: 'Owner',
    State: 'Open',
  },
};
const schema: ApplicationSchema = {
  project: { name: 'App', mendix_version: '11.12.1' },
  modules: [
    {
      name: 'App',
      pages: [],
      models: [
        {
          name: 'App.Item',
          attributes: [
            { name: 'Amount', type: 'Decimal' },
            { name: 'Count', type: 'Integer' },
            { name: 'Date', type: 'DateTime', localize_date: false },
            { name: 'State', type: 'Enumeration', enumeration: 'App.State' },
          ],
        },
      ],
      enumerations: [
        {
          id: 'state',
          name: 'App.State',
          values: [{ name: 'Open', caption: 'Open', caption_translations: { pt_BR: 'Aberto' } }],
        },
      ],
    },
  ],
};

describe('structured chart captions', () => {
  it('preserves transported Decimal precision in formatted attributes and expressions', () => {
    const precise = { ...record, attributes: { Amount: decimal('9007199254740993.12345678') } };
    expect(chartCaption({ text: '{1}', parameters: [{ attribute: 'Amount',
      format: { decimal_precision: 8, group_digits: true } }] }, precise, { locale: 'en-US', schema }))
      .toBe('9,007,199,254,740,993.12345678');
    expect(chartCaption({ text: '{1}', parameters: ['$currentObject/Amount'] }, precise))
      .toBe('9007199254740993.12345678');
    expect(chartCaption({ text: '{1}', parameters: [{ expression: '$currentObject/Amount' }] }, precise))
      .toBe('9007199254740993.12345678');
  });

  it('formats attributes with native precision and grouping in the selected translation', () => {
    const caption = {
      text: 'Amount {1}',
      translations: { pt_BR: 'Valor {1}' },
      parameters: [
        { attribute: 'App.Item.Amount', format: { decimal_precision: 3, group_digits: true } },
      ],
    };
    expect(chartCaption(caption, record, { locale: 'pt-BR', schema })).toBe('Valor 1.234,500');
    expect(chartCaption(caption, record, { locale: 'en-US', schema })).toBe('Amount 1,234.500');
    expect(
      chartCaption(
        { text: '{1} / {2}', parameters: ['$currentObject/Amount', '$currentObject/Count'] },
        record,
        { locale: 'en-US', schema },
      ),
    ).toBe('1234.50 / 1234');
  });

  it('resolves alternate page objects and primitive expressions without replacing the row context', () => {
    const caption = {
      text: '{1}: {2}',
      parameters: [
        { attribute: 'Name', source: { kind: 'page_parameter', name: 'App.Home.Owner' } },
        { expression: '$Prefix + $currentObject/Name' },
      ],
    };
    expect(
      chartCaption(
        caption,
        { ...record, attributes: { Name: 'Row' } },
        {
          locale: 'en-US',
          pageParameters: { Owner: record },
          localVariables: { Prefix: 'Value ' },
        },
      ),
    ).toBe('Owner: Value Row');
    expect(
      chartCaption({ ...caption, fallback: 'No owner' }, record, {
        locale: 'en-US',
        pageParameters: { Owner: null },
        localVariables: { Prefix: '' },
      }),
    ).toBe('No owner');
  });

  it('replaces each placeholder once and preserves unmatched placeholders', () => {
    expect(chartCaption({ text: '{1}/{2}/{3}', parameters: ["'{2}'", "'done'"] }, null)).toBe(
      '{2}/done/{3}',
    );
  });

  it('formats unlocalized dates, custom patterns and translated enumerations', () => {
    expect(
      chartCaption(
        {
          text: '{1} {2}',
          parameters: [
            {
              attribute: 'Date',
              format: { date_format: 'Custom', custom_date_format: "yyyyMMdd'T'HH:mm:ss" },
            },
            { attribute: 'State' },
          ],
        },
        record,
        { locale: 'pt-BR', schema },
      ),
    ).toBe('20261006T12:34:56 Aberto');
    expect(captionDate('2026-10-06T12:34:56Z', { date_format: 'Date' }, 'en-US', false)).toBe(
      '10/6/2026',
    );
    expect(captionDate('2026-10-06T12:34:56Z', { date_format: 'Time' }, 'en-US', false)).toBe(
      '12:34:56 PM',
    );
    expect(() => captionDate('invalid', {}, 'en-US')).toThrow('Caption date is invalid');
    expect(() =>
      captionDate('2026-10-06', { date_format: 'Custom', custom_date_format: 'Q' }, 'en-US'),
    ).toThrow('Unsupported caption date token');
  });

  it('reports invalid parameters and resolves missing attribute values as empty text', () => {
    expect(() =>
      chartCaption({ text: '{1}', parameters: [{ expression: 'x', attribute: 'y' }] }, record),
    ).toThrow('exactly one');
    expect(chartCaption({ text: '{1}', parameters: [{ attribute: 'Missing' }] }, record)).toBe('');
  });

  it('reacts to document language and context provider changes', async () => {
    function Caption() {
      const environment = useCaptionEnvironment(schema);
      return (
        <output>
          {chartCaption(
            {
              text: 'Owner {1}',
              translations: { pt_BR: 'Pessoa {1}' },
              parameters: [
                { attribute: 'Name', source: { kind: 'page_parameter', name: 'Owner' } },
              ],
            },
            null,
            environment,
          )}
        </output>
      );
    }
    const previous = document.documentElement.lang;
    document.documentElement.lang = 'en-US';
    try {
      const { rerender } = render(
        <PageParameters.Provider value={{ Owner: record }}>
          <Caption />
        </PageParameters.Provider>,
      );
      expect(screen.getByRole('status')).toHaveTextContent('Owner Owner');
      await act(async () => {
        document.documentElement.lang = 'pt-BR';
      });
      await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Pessoa Owner'));
      rerender(
        <PageParameters.Provider value={{ Owner: { ...record, attributes: { Name: 'New' } } }}>
          <Caption />
        </PageParameters.Provider>,
      );
      expect(screen.getByRole('status')).toHaveTextContent('Pessoa New');
    } finally {
      document.documentElement.lang = previous;
    }
  });
});
