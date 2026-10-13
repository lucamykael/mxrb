import { useEffect, useId, useRef, useState } from 'react';

export interface ComboboxOption {
  id: string;
  caption: string;
}

// The multiple-selection Combo box of Mendix (reference sets): a text field
// listing the chosen objects, a clear button, and a menu of checkbox items.
// Its markup follows the widget's, so the package styles apply.
export function ReferenceSetCombobox({
  id,
  labelId,
  options,
  selected,
  disabled,
  onChange,
}: {
  id?: string;
  labelId?: string;
  options: ComboboxOption[];
  selected: string[];
  disabled?: boolean;
  onChange: (ids: string[]) => void;
}) {
  const [open, setOpen] = useState(false);
  const [highlighted, setHighlighted] = useState(-1);
  const root = useRef<HTMLDivElement>(null);
  const field = useRef<HTMLInputElement>(null);
  const menuId = `${useId()}-menu`;
  const itemId = (index: number) => `${menuId}-item-${index}`;
  const text = options
    .filter((option) => selected.includes(option.id))
    .map((option) => option.caption)
    .join(', ');
  const toggle = (option: ComboboxOption) =>
    onChange(
      selected.includes(option.id)
        ? selected.filter((value) => value !== option.id)
        : [...selected, option.id],
    );

  useEffect(() => {
    if (!open) return;
    const close = (event: PointerEvent) => {
      if (!root.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', close);
    return () => document.removeEventListener('pointerdown', close);
  }, [open]);

  return (
    <div className="widget-combobox" ref={root}>
      <div
        tabIndex={-1}
        className={`widget-combobox-input-container${open ? ' widget-combobox-input-container-active' : ''} form-control${disabled ? ' widget-combobox-input-container-disabled' : ''}`}
        onClick={() => {
          if (disabled) return;
          field.current?.focus();
          setOpen(!open);
        }}
      >
        <div className="widget-combobox-selected-items widget-combobox-text">
          <input
            ref={field}
            id={id}
            className="widget-combobox-input"
            placeholder=" "
            role="combobox"
            aria-labelledby={labelId}
            aria-controls={menuId}
            aria-expanded={open}
            aria-autocomplete="list"
            aria-activedescendant={open && highlighted >= 0 ? itemId(highlighted) : ''}
            autoComplete="off"
            readOnly
            disabled={disabled}
            value=""
            onKeyDown={(event) => {
              if (event.key === 'Escape') setOpen(false);
              else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
                event.preventDefault();
                setOpen(true);
                const step = event.key === 'ArrowDown' ? 1 : -1;
                setHighlighted((current) =>
                  Math.max(0, Math.min(options.length - 1, current + step)),
                );
              } else if (event.key === 'Enter' && open && options[highlighted]) {
                event.preventDefault();
                toggle(options[highlighted]);
              }
            }}
          />
          <div
            className={`widget-combobox-placeholder-text${text ? '' : ' widget-combobox-placeholder-empty'}`}
          >
            {text}
          </div>
        </div>
        {text && !disabled && (
          <button
            type="button"
            className="widget-combobox-clear-button"
            aria-label="Clear selection"
            onClick={(event) => {
              event.stopPropagation();
              onChange([]);
            }}
          >
            <span className="widget-combobox-icon-container">
              <svg
                width="14"
                height="14"
                viewBox="0 0 32 32"
                className="widget-combobox-clear-button-icon"
              >
                <path
                  stroke="currentColor"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  fill="currentColor"
                  d="M27.71 5.71004L26.29 4.29004L16 14.59L5.71004 4.29004L4.29004 5.71004L14.59 16L4.29004 26.29L5.71004 27.71L16 17.41L26.29 27.71L27.71 26.29L17.41 16L27.71 5.71004Z"
                />
              </svg>
            </span>
          </button>
        )}
        <div className="widget-combobox-down-arrow">
          <span className="widget-combobox-icon-container">
            <svg
              className={`widget-combobox-down-arrow-icon mx-icon-lined mx-icon-chevron-down${open ? ' active' : ''}`}
              width="16"
              height="16"
              viewBox="0 0 32 32"
            >
              <path d="M16 23.41L4.29004 11.71L5.71004 10.29L16 20.59L26.29 10.29L27.71 11.71L16 23.41Z" />
            </svg>
          </span>
        </div>
      </div>
      <div className={`widget-combobox-menu${open ? '' : ' widget-combobox-menu-hidden'}`}>
        <ul
          className="widget-combobox-menu-list widget-combobox-menu-lazy-scroll"
          id={menuId}
          role="listbox"
          aria-labelledby={labelId}
          aria-multiselectable
          // Choosing items keeps the focus in the field, for the keyboard.
          onMouseDown={(event) => event.preventDefault()}
        >
          {options.map((option, index) => {
            const chosen = selected.includes(option.id);
            return (
              <li
                key={option.id}
                id={itemId(index)}
                className={`widget-combobox-item${chosen ? ' widget-combobox-item-selected' : ''}${index === highlighted ? ' widget-combobox-item-highlighted' : ''}`}
                role="option"
                aria-selected={chosen}
                onMouseEnter={() => setHighlighted(index)}
                onClick={() => {
                  setHighlighted(index);
                  toggle(option);
                }}
              >
                <span className="widget-combobox-icon-container">
                  <input
                    tabIndex={-1}
                    role="presentation"
                    type="checkbox"
                    checked={chosen}
                    readOnly
                  />
                </span>
                <span className="widget-combobox-caption-text">{option.caption}</span>
              </li>
            );
          })}
        </ul>
      </div>
    </div>
  );
}
