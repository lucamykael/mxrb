import { describe, expect, it } from 'vitest';
import type { ExtensionWidgetDefinition, WidgetDefinition } from '../types';

describe('widget declaration contract', () => {
  it('rejects unknown widget types and misspelled options unless declared as extensions', () => {
    // @ts-expect-error 'buton' is not a widget type the runtime renders.
    const unknownType: WidgetDefinition = { type: 'buton', name: 'Save' };
    // @ts-expect-error 'captoin' is not a widget option.
    const misspelled: WidgetDefinition = {
      type: 'button',
      name: 'Save',
      options: { captoin: 'Save' },
    };
    const declared: WidgetDefinition = {
      type: 'button',
      name: 'Save',
      options: { caption: 'Save', extension: { analytics_id: 'save-button' } },
    };
    const extension: ExtensionWidgetDefinition = {
      type: 'vendor_chart',
      name: 'Chart',
      options: { series: 3 },
    };
    expect([unknownType, misspelled, declared, extension].map((widget) => widget.name)).toEqual([
      'Save',
      'Save',
      'Save',
      'Chart',
    ]);
  });
});
