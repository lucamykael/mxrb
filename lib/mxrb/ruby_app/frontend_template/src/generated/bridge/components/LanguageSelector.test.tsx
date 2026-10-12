import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { ApiRequest, ApplicationSchema, EntityRecord } from '../../types';
import { LanguageSelector } from './LanguageSelector';

const language = (code: string, description: string): EntityRecord => ({
  id: code,
  type: 'System.Language',
  attributes: { Code: code, Description: description },
});
const properties = {
  languageOptions: {
    data_source: {
      entity: 'System.Language',
      sort: [{ attribute: 'System.Language.Description', direction: 'Ascending' }],
    },
  },
  languageCaption: '$currentObject/Description\n',
  position: 'bottom',
};
const schema = { languages: { default: 'en_US' } } as unknown as ApplicationSchema;

const storage = new Map<string, string>();
beforeEach(() => {
  storage.clear();
  vi.stubGlobal('localStorage', {
    getItem: (key: string) => storage.get(key) ?? null,
    setItem: (key: string, value: string) => storage.set(key, value),
  });
});

describe('Language selector', () => {
  it('shows the current language and switches the page language', async () => {
    const request = vi.fn().mockResolvedValue({
      records: [language('pt_BR', 'Portuguese, Brazil'), language('en_US', 'English, United States')],
    });
    const user = userEvent.setup();
    render(
      <LanguageSelector
        properties={properties}
        schema={schema}
        request={request as unknown as ApiRequest}
        label="Language selector"
      />,
    );
    const trigger = screen.getByRole('combobox', { name: 'Language selector' });
    expect(await screen.findByText('English, United States')).toHaveClass('current-language-text');
    expect(document.documentElement.lang).toBe('en-US');
    await user.click(trigger);
    const options = screen.getAllByRole('option');
    expect(options.map((option) => option.textContent)).toEqual([
      'English, United States',
      'Portuguese, Brazil',
    ]);
    expect(options[0]).toHaveClass('popupmenu-basic-item', 'active');
    await user.click(options[1]);
    expect(document.documentElement.lang).toBe('pt-BR');
    expect(window.localStorage.getItem('mxrb.language')).toBe('pt_BR');
    expect(screen.queryByRole('listbox')).not.toBeInTheDocument();
    expect(trigger).toHaveTextContent('Portuguese, Brazil');
  });

  it('hides a single language when asked to', async () => {
    const request = vi.fn().mockResolvedValue({ records: [language('en_US', 'English')] });
    const { container } = render(
      <LanguageSelector
        properties={{ ...properties, hideForSingle: true }}
        schema={schema}
        request={request as unknown as ApiRequest}
        label="Language selector"
      />,
    );
    await vi.waitFor(() => expect(request).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
  });
});
