import clsx from 'clsx';
import type { LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export function KpiCard({
  icon: Icon,
  titulo,
  valor,
  complemento,
  rodape,
  destaque = false,
}: {
  icon: LucideIcon;
  titulo: string;
  valor: ReactNode;
  complemento?: ReactNode;
  rodape?: ReactNode;
  destaque?: boolean;
}) {
  return (
    <div
      className={clsx(
        'card relative overflow-hidden p-5',
        destaque && 'bg-primary-700 text-white ring-0 [background-image:radial-gradient(120%_90%_at_100%_0%,rgba(243,146,0,0.28),transparent_55%)]',
      )}
    >
      <div className="flex items-start justify-between gap-3">
        <p className={clsx('text-sm font-medium', destaque ? 'text-white/70' : 'text-slate-500')}>{titulo}</p>
        <span
          className={clsx(
            'flex h-9 w-9 items-center justify-center rounded-xl',
            destaque ? 'bg-white/10 text-accent-400' : 'bg-primary-50 text-primary-600',
          )}
        >
          <Icon className="h-[18px] w-[18px]" strokeWidth={1.9} />
        </span>
      </div>
      <div className="mt-3 flex items-baseline gap-2">
        <p className={clsx('text-3xl font-semibold tracking-tight', destaque ? 'text-white' : 'text-slate-900')}>{valor}</p>
        {complemento && (
          <span className={clsx('text-sm', destaque ? 'text-white/60' : 'text-slate-400')}>{complemento}</span>
        )}
      </div>
      {rodape && (
        <div className={clsx('mt-3 text-xs', destaque ? 'text-white/70' : 'text-slate-500')}>{rodape}</div>
      )}
    </div>
  );
}

export function KpiSkeleton() {
  return (
    <div className="card animate-pulse p-5">
      <div className="h-4 w-28 rounded bg-slate-100" />
      <div className="mt-4 h-8 w-20 rounded bg-slate-100" />
      <div className="mt-4 h-3 w-36 rounded bg-slate-100" />
    </div>
  );
}
