import { useEffect, useState, type ComponentType } from 'react';
import { Layout } from './components/Layout';
import { Dashboard } from './pages/Dashboard';
import { Analysis } from './pages/Analysis';
import { Training } from './pages/Training';
import { Plan } from './pages/Plan';
import { Progress } from './pages/Progress';
import { Openings } from './pages/Openings';
import { Settings } from './pages/Settings';

const ROUTES: Record<string, ComponentType> = {
  dashboard: Dashboard,
  analysis: Analysis,
  training: Training,
  plan: Plan,
  progress: Progress,
  openings: Openings,
  settings: Settings
};

export default function App() {
  const [route, setRoute] = useState(() => location.hash.slice(1) || 'dashboard');

  useEffect(() => {
    const onHash = () => setRoute(location.hash.slice(1) || 'dashboard');
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  const Page = ROUTES[route] ?? Dashboard;

  return (
    <Layout route={route}>
      <Page />
    </Layout>
  );
}
