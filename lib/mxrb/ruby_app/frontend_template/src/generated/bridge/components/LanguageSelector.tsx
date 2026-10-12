import { useEffect, useState } from 'react';
import type { ApiRequest, ApplicationSchema, EntityCollectionResponse, EntityRecord } from '../../types';
import { expressionValue, sortRecords } from '../value';

const STORAGE_KEY = 'mxrb.language';

const stored = (): string | null => {
  try {
    return window.localStorage.getItem(STORAGE_KEY);
  } catch {
    return null;
  }
};

// The page language follows the chosen Mendix language code (en_US → en-US).
export const applyLanguage = (code: string) => {
  document.documentElement.lang = code.replaceAll('_', '-');
};

interface Props {
  properties: Record<string, unknown>;
  schema?: ApplicationSchema;
  request?: ApiRequest;
  label: string;
}

// The Language selector widget: a popup menu of the System.Language objects of
// its data source, showing the current language.
export function LanguageSelector({ properties, schema, request, label }: Props) {
  const source = (properties.languageOptions as { data_source?: Record<string, unknown> })
    ?.data_source;
  const entity = String(source?.entity || 'System.Language');
  const caption = String(properties.languageCaption || '$currentObject/Description').trim();
  const [languages, setLanguages] = useState<EntityRecord[]>([]);
  const [open, setOpen] = useState(false);
  const [code, setCode] = useState(() => stored() || schema?.languages?.default || '');
  const [signedIn, setSignedIn] = useState(false);
  // A signed-in user's language comes from the server (System.User_Language).
  useEffect(() => {
    if (!request) return;
    request<{ user?: string | null; language?: string | null }>('/api/session')
      .then((session) => {
        setSignedIn(Boolean(session?.user));
        if (session?.language) setCode(session.language);
      })
      .catch(() => setSignedIn(false));
  }, [request]);
  useEffect(() => {
    if (!request) return;
    request<EntityCollectionResponse>(`/api/entities/${encodeURIComponent(entity)}`)
      .then((payload) =>
        setLanguages(
          sortRecords(
            payload.records || [],
            (source?.sort as Array<{ attribute: string; direction?: string }>) || [],
          ),
        ),
      )
      .catch(() => setLanguages([]));
  }, [entity, request, source?.sort]);
  useEffect(() => {
    if (code) applyLanguage(code);
  }, [code]);
  const text = (language: EntityRecord) => String(expressionValue(caption, language) ?? '');
  const current = languages.find((language) => language.attributes.Code === code);
  if (properties.hideForSingle === true && languages.length <= 1) return null;
  return (
    <div className="widget-language-selector popupmenu">
      <div
        className="popupmenu-trigger popupmenu-trigger-alignment"
        role="combobox"
        tabIndex={0}
        aria-label={String(properties.screenReaderLabelCaption || '') || label}
        aria-haspopup="listbox"
        aria-expanded={open}
        onClick={() => setOpen(!open)}
        onKeyDown={(event) => {
          if (['Enter', ' '].includes(event.key)) {
            event.preventDefault();
            setOpen(!open);
          }
        }}
      >
        <span className="current-language-text">{current ? text(current) : code}</span>
        <span className="language-arrow">
          <div className={`arrow-image ${open ? 'arrow-up' : 'arrow-down'}`} />
        </span>
      </div>
      {open && (
        <div className={`popupmenu-menu popupmenu-position-${properties.position || 'bottom'}`} role="listbox">
          {languages.map((language) => {
            const value = String(language.attributes.Code || '');
            return (
              <div
                key={language.id}
                className={`popupmenu-basic-item${value === code ? ' active' : ''}`}
                role="option"
                aria-selected={value === code}
                onClick={() => {
                  try {
                    window.localStorage.setItem(STORAGE_KEY, value);
                  } catch {
                    // Without storage the choice lasts for the page.
                  }
                  setCode(value);
                  setOpen(false);
                  if (signedIn && request)
                    void request('/api/session/language', {
                      method: 'POST',
                      body: JSON.stringify({ code: value }),
                    }).catch(() => undefined);
                }}
              >
                {text(language)}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
