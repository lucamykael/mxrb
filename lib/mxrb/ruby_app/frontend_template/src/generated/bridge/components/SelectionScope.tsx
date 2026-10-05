import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import type { EntityRecord } from '../../types';

const SelectionContext = createContext<{
  records: Record<string, EntityRecord | null>;
  select: (name: string, record: EntityRecord | null) => void;
  lists: Record<string, EntityRecord[]>;
  selectMany: (name: string, records: EntityRecord[]) => void;
}>({ records: {}, lists: {}, select: () => undefined, selectMany: () => undefined });

export const useSelections = () => useContext(SelectionContext);

export function SelectionScope({ children }: { children: ReactNode }) {
  const [records, setRecords] = useState<Record<string, EntityRecord | null>>({});
  const [lists, setLists] = useState<Record<string, EntityRecord[]>>({});
  const selectMany = useCallback((name: string, selected: EntityRecord[]) => {
    setLists((current) => ({ ...current, [name]: selected }));
    setRecords((current) => ({ ...current, [name]: selected[0] || null }));
  }, []);
  const select = useCallback((name: string, record: EntityRecord | null) => {
    setRecords((current) => ({ ...current, [name]: record }));
  }, []);
  return (
    <SelectionContext.Provider value={{ records, select, lists, selectMany }}>
      {children}
    </SelectionContext.Provider>
  );
}
