import { Hourglass } from 'lucide-react';
import { useState } from 'react';
import { EmptyState } from '@/components/ui/EmptyState';
import { formatMinutos, iniciais } from '@/lib/format';
import type { SaldoColaborador } from '@/lib/types';

// Diverging: azul = saldo positivo, laranja = saldo negativo, eixo neutro no zero.
// Cores validadas para daltonismo (dataviz validate_palette).
const COR_POSITIVO = '#3b6fd8';
const COR_NEGATIVO = '#f39200';
const LIMITE_INICIAL = 8;

export function BancoHorasChart({ dados }: { dados: SaldoColaborador[] }) {
  const [verTodos, setVerTodos] = useState(false);

  const comSaldo = dados.filter((d) => d.saldo_minutos !== 0);
  if (comSaldo.length === 0) {
    return (
      <EmptyState
        icon={Hourglass}
        titulo="Nenhum saldo de banco de horas"
        descricao="Os saldos aparecem aqui após o processamento das batidas ou lançamentos manuais."
        compacto
      />
    );
  }

  // Maiores saldos (em valor absoluto) primeiro, mantendo positivos acima dos negativos
  const ordenados = [...comSaldo].sort((a, b) => b.saldo_minutos - a.saldo_minutos);
  const visiveis = verTodos
    ? ordenados
    : [
        ...ordenados.filter((d) => d.saldo_minutos > 0).slice(0, LIMITE_INICIAL / 2),
        ...ordenados.filter((d) => d.saldo_minutos < 0).slice(-LIMITE_INICIAL / 2),
      ];
  const max = Math.max(...comSaldo.map((d) => Math.abs(d.saldo_minutos)), 60);

  return (
    <div>
      <div className="mb-3 flex items-center gap-4 text-xs text-slate-500">
        <span className="flex items-center gap-1.5">
          <span className="h-2.5 w-2.5 rounded-sm" style={{ background: COR_POSITIVO }} /> Saldo positivo
        </span>
        <span className="flex items-center gap-1.5">
          <span className="h-2.5 w-2.5 rounded-sm" style={{ background: COR_NEGATIVO }} /> Saldo negativo
        </span>
      </div>

      <ul className="space-y-1" role="list">
        {visiveis.map((d) => {
          const pct = (Math.abs(d.saldo_minutos) / max) * 100;
          const positivo = d.saldo_minutos > 0;
          const rotulo = `${d.nome}: ${formatMinutos(d.saldo_minutos, true)}`;
          return (
            <li
              key={d.id}
              title={rotulo}
              aria-label={rotulo}
              className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.4fr)_64px] items-center gap-3 rounded-lg px-2 py-1.5 transition hover:bg-slate-50 sm:grid-cols-[minmax(0,180px)_1fr_72px]"
            >
              <div className="flex min-w-0 items-center gap-2">
                <span className="hidden h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-slate-100 text-[11px] font-semibold text-slate-600 sm:flex">
                  {iniciais(d.nome)}
                </span>
                <div className="min-w-0">
                  <p className="truncate text-sm font-medium text-slate-700">{d.nome}</p>
                  <p className="truncate text-[11px] text-slate-400">{d.departamento ?? `Mat. ${d.matricula}`}</p>
                </div>
              </div>

              <div className="relative grid h-6 grid-cols-2">
                <div className="flex justify-end pr-px">
                  {!positivo && (
                    <div
                      className="h-full rounded-l-[4px]"
                      style={{ width: `${pct}%`, background: COR_NEGATIVO }}
                    />
                  )}
                </div>
                <div className="flex justify-start pl-px">
                  {positivo && (
                    <div
                      className="h-full rounded-r-[4px]"
                      style={{ width: `${pct}%`, background: COR_POSITIVO }}
                    />
                  )}
                </div>
                <span className="absolute inset-y-[-4px] left-1/2 w-px -translate-x-1/2 bg-slate-300" />
              </div>

              <span className="text-right text-sm font-semibold tabular-nums text-slate-700">
                {formatMinutos(d.saldo_minutos, true)}
              </span>
            </li>
          );
        })}
      </ul>

      {ordenados.length > visiveis.length || verTodos ? (
        <button
          onClick={() => setVerTodos((v) => !v)}
          className="mt-3 text-xs font-medium text-primary-600 hover:text-primary-800"
        >
          {verTodos ? 'Mostrar apenas os extremos' : `Ver todos os ${ordenados.length} colaboradores`}
        </button>
      ) : null}
    </div>
  );
}
