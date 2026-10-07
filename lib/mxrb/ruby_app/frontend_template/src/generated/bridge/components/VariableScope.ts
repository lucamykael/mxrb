import { createContext } from 'react';
import type { RuntimeVariables } from '../../types';

// Lexical snippet parameters are independent from the current editable object.
export const VariableScope = createContext<RuntimeVariables>({});

// Named surrounding data widgets remain available independently of a chart row.
export const WidgetObjectScope = createContext<RuntimeVariables>({});
