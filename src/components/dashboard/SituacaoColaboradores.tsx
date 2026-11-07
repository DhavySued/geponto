import clsx from 'clsx';
import { SITUACAO } from '@/components/ui/Badge';
import type { SituacaoColaborador } from '@/lib/types';

const ORDEM: SituacaoColaborador[] = ['ativo', 'ferias', 'afastado', 'desligado'];

const BARRA: Record<SituacaoColaborador, string> = {
  ativo: 'bg-emerald-500',
  ferias: 'bg-sky-500',
  afastado: 'bg-violet-500',
  desligado: 'bg-slate-300',
};

export function SituacaoColaboradores({ situacoes }: { situacoes: Record<SituacaoColaborador, number> }) {
  const total = ORDEM.reduce((s, k) => s + (situacoes[k] ?? 0), 0);

  return (
    <ul className="space-y-3.5">
      {ORDEM.map((k) => {
        const qtd = situacoes[k] ?? 0;
        const pct = total ? (qtd / total) * 100 : 0;
        return (
          <li key={k}>
            <div className="mb-1.5 flex items-center justify-between text-sm">
              <span className="flex items-center gap-2 text-slate-600">
                <span className={clsx('h-2 w-2 rounded-full', BARRA[k])} />
                {SITUACAO[k].label}
              </span>
              <span className="tabular-nums text-slate-800">
                <span className="font-semibold">{qtd}</span>
                <span className="ml-1.5 text-xs text-slate-400">{pct.toFixed(0)}%</span>
              </span>
            </div>
            <div className="h-1.5 overflow-hidden rounded-full bg-slate-100">
              <div className={clsx('h-full rounded-full', BARRA[k])} style={{ width: `${pct}%` }} />
            </div>
          </li>
        );
      })}
    </ul>
  );
}
