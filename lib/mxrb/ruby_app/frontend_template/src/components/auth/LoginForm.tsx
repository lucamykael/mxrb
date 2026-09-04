import type { FormEvent } from 'react';
import type { AppError } from '../../core/errors';
import logoUrl from '../../generated/platform/theme/web/logo.png';

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
    <main className="loginpage mxrb-login">
      <div className="loginpage-left">
        <div className="loginpage-image" />
      </div>
      <div className="loginpage-right">
        <div className="loginpage-formwrapper">
          <h2 id="loginHeader">Sign in</h2>
          <form id="loginForm" className="loginpage-form" autoComplete="off" onSubmit={submit}>
            {error ? (
              <div id="loginMessage" className="alert alert-danger" role="alert">
                {error.message}
              </div>
            ) : null}
            <div className="form-group">
              <label className="control-label" htmlFor="usernameInput">
                Username
              </label>
              <div className="inputwrapper">
                <input
                  id="usernameInput"
                  className="form-control"
                  name="username"
                  placeholder="Username"
                  autoComplete="username"
                  required
                />
                <span className="glyphicon glyphicon-user" aria-hidden="true" />
              </div>
            </div>
            <div className="form-group">
              <label className="control-label" htmlFor="passwordInput">
                Password
              </label>
              <div className="inputwrapper">
                <input
                  id="passwordInput"
                  className="form-control"
                  name="password"
                  type="password"
                  placeholder="Password"
                  autoComplete="current-password"
                  required
                />
                <span className="glyphicon glyphicon-eye-close" aria-hidden="true" />
              </div>
            </div>
            <button
              id="loginButton"
              className="btn btn-success btn-lg"
              type="submit"
              disabled={busy}
            >
              Sign in
            </button>
          </form>
        </div>
      </div>
      <div className="loginpage-logo">
        <img src={logoUrl} role="presentation" height="45" alt="" />
      </div>
    </main>
  );
}
