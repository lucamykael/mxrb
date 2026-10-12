import { useId, useRef, useState, type ReactNode } from 'react';
import type { WidgetTab } from '../../types';

interface TabControlProps {
  tabs: WidgetTab[];
  label: string;
  renderPanel: (tab: WidgetTab) => ReactNode;
}

export function TabControl({ tabs, label, renderPanel }: TabControlProps) {
  const id = useId();
  const buttons = useRef<Array<HTMLAnchorElement | null>>([]);
  const [selected, setSelected] = useState(tabs[0]?.name);
  const [visited, setVisited] = useState<string[]>([]);
  const active = tabs.find((tab) => tab.name === selected)?.name || tabs[0]?.name;
  const select = (index: number) => {
    const name = tabs[index]?.name;
    if (!name) return;
    setVisited((previous) => [...new Set([...previous, ...(active ? [active] : []), name])]);
    setSelected(name);
    buttons.current[index]?.focus();
  };

  return (
    <>
      {/* The Atlas tab container markup of the Mendix client. */}
      <ul className="nav nav-tabs mx-tabcontainer-tabs" role="tablist" aria-label={label}>
        {tabs.map((tab, index) => (
          <li key={tab.name} className={tab.name === active ? 'active' : undefined} role="presentation">
          <a
            ref={(button) => {
              buttons.current[index] = button;
            }}
            href="#"
            className={`mx-name-${tab.name}`}
            role="tab"
            id={`${id}-tab-${index}`}
            aria-controls={`${id}-panel-${index}`}
            aria-selected={tab.name === active}
            tabIndex={tab.name === active ? 0 : -1}
            onClick={(event) => {
              event.preventDefault();
              select(index);
            }}
            onKeyDown={(event) => {
              const next =
                event.key === 'ArrowRight'
                  ? (index + 1) % tabs.length
                  : event.key === 'ArrowLeft'
                    ? (index + tabs.length - 1) % tabs.length
                    : event.key === 'Home'
                      ? 0
                      : event.key === 'End'
                        ? tabs.length - 1
                        : null;
              if (next === null) return;
              event.preventDefault();
              select(next);
            }}
          >
            {tab.caption || tab.name}
          </a>
          </li>
        ))}
      </ul>
      <div className="tab-content mx-tabcontainer-content">
      {tabs.map((tab, index) => (
        <section
          key={tab.name}
          className={`tab-pane mx-tabcontainer-pane${tab.name === active ? ' active' : ''}`}
          role="tabpanel"
          id={`${id}-panel-${index}`}
          aria-labelledby={`${id}-tab-${index}`}
          hidden={tab.name !== active}
          tabIndex={0}
        >
          {/* Defer unopened panels, but never discard an opened panel's drafts. */}
          {tab.name === active || visited.includes(tab.name) ? renderPanel(tab) : null}
        </section>
      ))}
      </div>
    </>
  );
}
