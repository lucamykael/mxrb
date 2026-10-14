// "mx-global", which JavaScript actions import: installs window.mx before the
// action runs; each call completes it with the page's schema and session.
import { api } from '../api';
import { expressionSchema } from '../schemaLookup';
import type { ApiRequest } from '../../types';
import { installMx } from './mx';

installMx({
  schema: expressionSchema() ?? undefined,
  request: api as ApiRequest,
  session: {},
  locale: typeof navigator === 'undefined' ? 'en-US' : navigator.language || 'en-US',
});
