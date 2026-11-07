import { Trophy } from 'lucide-react';
import { EmptyState } from '@/components/ui/EmptyState';
import { formatMinutos, iniciais } from '@/lib/format';
import type { RankingAtraso } from '@/lib/types';

export function RankingAtrasos({ dados }: { dados: RankingAtraso[] }) {
  if (dados.length === 0) {
    return (
      <EmptyState
        icon={Trophy}
        titulo="Equipe pontual!"
        descricao="Nenhum atraso ou falta registrado no período."
        compacto
      />
    );
  }

  return (
    <ul className="divide-y divide-slate-100">
      {dados.map((d, i) => (
        <li key={d.id} className="flex items-center gap-3 py-3 first:pt-0 last:pb-0">
          <span className="w-4 text-xs font-semibold tabular-nums text-slate-400">{i + 1}</span>
          <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-accent-50 text-xs font-semibold text-accent-700">
            {iniciais(d.nome)}
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate text-sm font-medium text-slate-800">{d.nome}</p>
            <p className="truncate text-xs text-slate-400">
              {d.ocorrencias} atraso{d.ocorrencias === 1 ? '' : 's'}
              {d.faltas > 0 && ` · ${d.faltas} falta${d.faltas === 1 ? '' : 's'}`}
            </p>
          </div>
          <span className="text-sm font-semibold tabular-nums text-slate-700">{formatMinutos(d.minutos)}</span>
        </li>
      ))}
    </ul>
  );
}
