import { BrowserRouter, Route, Routes } from 'react-router-dom';
import { ApplicationRuntime } from '../generated/bridge/ApplicationRuntime';
import { applicationRoutes } from '../features/routes';

export function AppRouter() {
  return (
    <BrowserRouter>
      <Routes>
        {applicationRoutes.map((route) => (
          <Route key={route.path} path={route.path} element={route.element} />
        ))}
        <Route path="/" element={<ApplicationRuntime />} />
        <Route path="/pages/:pageName" element={<ApplicationRuntime />} />
        <Route path="*" element={<ApplicationRuntime />} />
      </Routes>
    </BrowserRouter>
  );
}
