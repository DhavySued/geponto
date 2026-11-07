import type { LucideIcon } from 'lucide-react';
import type { ReactNode } from 'react';

export function EmptyState({
  icon: Icon,
  titulo,
  descricao,
  acao,
  compacto = false,
}: {
  icon: LucideIcon;
  titulo: string;
  descricao?: string;
  acao?: ReactNode;
  compacto?: boolean;
}) {
  return (
    <div className={compacto ? 'px-6 py-8 text-center' : 'px-6 py-14 text-center'}>
      <div className="relative mx-auto mb-4 flex h-14 w-14 items-center justify-center">
        <span className="absolute inset-0 rounded-2xl bg-primary-50" />
        <span className="absolute -right-1 -top-1 h-3 w-3 rounded-full bg-accent-200" />
        <Icon className="relative h-6 w-6 text-primary-600" strokeWidth={1.75} />
      </div>
      <p className="text-sm font-semibold text-slate-800">{titulo}</p>
      {descricao && <p className="mx-auto mt-1 max-w-sm text-sm text-slate-500">{descricao}</p>}
      {acao && <div className="mt-5">{acao}</div>}
    </div>
  );
}
