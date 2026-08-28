import type { FormEvent } from 'react';
import type { AppError } from '../../core/errors';

interface LoginFormProps {
  onLogin: (username: string, password: string) => Promise<void>;
  error: AppError | null;
  busy: boolean;
}

export function LoginForm({ onLogin, error, busy }: LoginFormProps) {
  const submit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    const fields = new FormData(event.currentTarget);
    void onLogin(String(fields.get('username') || ''), String(fields.get('password') || ''));
  };
  return (
    <main className="login-page mxrb-login">
      <form id="loginForm" onSubmit={submit}>
        <h1>Sign in</h1>
        <label>
          Username
          <input id="usernameInput" name="username" autoComplete="username" required />
        </label>
        <label>
          Password
          <input
            id="passwordInput"
            name="password"
            type="password"
            autoComplete="current-password"
            required
          />
        </label>
        <button type="submit" disabled={busy}>
          Sign in
        </button>
        {error ? <p role="alert">{error.message}</p> : null}
      </form>
    </main>
  );
}
