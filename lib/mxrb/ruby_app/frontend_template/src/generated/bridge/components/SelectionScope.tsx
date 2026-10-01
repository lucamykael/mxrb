import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';
import type { EntityRecord } from '../../types';

const SelectionContext = createContext<{
  records: Record<string, EntityRecord | null>;
  select: (name: string, record: EntityRecord | null) => void;
}>({ records: {}, select: () => undefined });

export const useSelections = () => useContext(SelectionContext);

export function SelectionScope({ children }: { children: ReactNode }) {
  const [records, setRecords] = useState<Record<string, EntityRecord | null>>({});
  const select = useCallback((name: string, record: EntityRecord | null) => {
    setRecords((current) => ({ ...current, [name]: record }));
  }, []);
  return (
    <SelectionContext.Provider value={{ records, select }}>{children}</SelectionContext.Provider>
  );
}
