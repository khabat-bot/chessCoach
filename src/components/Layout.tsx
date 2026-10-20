import { useEffect, useState, type ReactNode } from 'react';
import {
  LayoutDashboard, Search, Dumbbell, CalendarCheck, TrendingUp, BookOpen, Settings, WifiOff
} from 'lucide-react';

const NAV = [
  { id: 'dashboard', label: 'Dashboard', icon: LayoutDashboard },
  { id: 'analysis', label: 'Analysis', icon: Search },
  { id: 'training', label: 'Training', icon: Dumbbell },
  { id: 'plan', label: 'Plan', icon: CalendarCheck },
  { id: 'progress', label: 'Progress', icon: TrendingUp },
  { id: 'openings', label: 'Openings', icon: BookOpen },
  { id: 'settings', label: 'Settings', icon: Settings }
];

export function Layout({ route, children }: { route: string; children: ReactNode }) {
  const [online, setOnline] = useState(navigator.onLine);

  useEffect(() => {
    const up = () => setOnline(true);
    const down = () => setOnline(false);
    window.addEventListener('online', up);
    window.addEventListener('offline', down);
    return () => { window.removeEventListener('online', up); window.removeEventListener('offline', down); };
  }, []);

  return (
    <div className="min-h-screen flex flex-col md:flex-row">
      <aside className="md:w-60 shrink-0 border-b md:border-b-0 md:border-r border-ink-600 bg-ink-800/60">
        <div className="p-4 flex items-center gap-2">
          <div className="w-8 h-8 rounded-lg bg-lime/15 grid place-items-center text-lime font-bold">N</div>
          <span className="font-semibold tracking-tight">Supercoach</span>
        </div>
        <nav className="px-2 pb-3 flex md:flex-col gap-1 overflow-x-auto">
          {NAV.map(({ id, label, icon: Icon }) => (
            <a key={id} href={`#${id}`}
               className={`flex items-center gap-2 px-3 py-2 rounded-lg text-sm whitespace-nowrap transition
                 ${route === id ? 'bg-lime/10 text-lime' : 'text-slate-400 hover:text-slate-200 hover:bg-ink-700'}`}>
              <Icon size={16} /> {label}
            </a>
          ))}
        </nav>
        {!online && (
          <div className="mx-3 mb-3 flex items-center gap-2 text-xs text-amber-300/90 bg-amber-400/10 rounded-lg px-2 py-1.5">
            <WifiOff size={14} /> Offline — cached data only
          </div>
        )}
      </aside>
      <main className="flex-1 min-w-0 p-4 md:p-8">{children}</main>
    </div>
  );
}
