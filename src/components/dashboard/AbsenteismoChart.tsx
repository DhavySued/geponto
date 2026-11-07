import clsx from 'clsx';
import { CalendarX2, Table2, BarChart3 } from 'lucide-react';
import { useState } from 'react';
import { EmptyState } from '@/components/ui/EmptyState';
import { formatData, parseISODate } from '@/lib/format';
import type { AbsenteismoDia } from '@/lib/types';

const SERIES = [
  { chave: 'faltas', nome: 'Faltas', cor: '#3b6fd8' },
  { chave: 'atrasos', nome: 'Atrasos', cor: '#f39200' },
] as const;

function escalaMaxima(valor: number) {
  if (valor <= 4) return 4;
  const passo = Math.pow(10, Math.floor(Math.log10(valor)));
  return Math.ceil(valor / passo) * passo;
}

export function AbsenteismoChart({ dados }: { dados: AbsenteismoDia[] }) {
  const [hover, setHover] = useState<number | null>(null);
  const [modo, setModo] = useState<'grafico' | 'tabela'>('grafico');

  const diasUteis = dados.filter((d) => d.previstos > 0);
  const total = diasUteis.reduce((s, d) => s + d.faltas + d.atrasos, 0);

  if (diasUteis.length === 0) {
    return (
      <EmptyState
        icon={CalendarX2}
        titulo="Sem dias úteis no período"
        descricao="Selecione outro intervalo para acompanhar faltas e atrasos."
        compacto
      />
    );
  }

  const max = escalaMaxima(Math.max(...diasUteis.map((d) => Math.max(d.faltas, d.atrasos)), 1));
  const ticks = [0, 0.5, 1].map((f) => Math.round(max * f));
  const passoRotulo = Math.max(1, Math.ceil(diasUteis.length / 10));
  const ativo = hover !== null ? diasUteis[hover] : null;

  return (
    <div>
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <div className="flex items-center gap-4 text-xs text-slate-500">
          {SERIES.map((s) => (
            <span key={s.chave} className="flex items-center gap-1.5">
              <span className="h-2.5 w-2.5 rounded-sm" style={{ background: s.cor }} />
              {s.nome}
            </span>
          ))}
        </div>
        <div className="flex rounded-lg bg-slate-100 p-0.5 text-xs">
          {(['grafico', 'tabela'] as const).map((m) => (
            <button
              key={m}
              onClick={() => setModo(m)}
              className={clsx(
                'flex items-center gap-1 rounded-md px-2.5 py-1 font-medium transition',
                modo === m ? 'bg-white text-slate-800 shadow-soft' : 'text-slate-500 hover:text-slate-700',
              )}
            >
              {m === 'grafico' ? <BarChart3 className="h-3.5 w-3.5" /> : <Table2 className="h-3.5 w-3.5" />}
              {m === 'grafico' ? 'Gráfico' : 'Tabela'}
            </button>
          ))}
        </div>
      </div>

      {modo === 'tabela' ? (
        <div className="max-h-[260px] overflow-y-auto rounded-xl ring-1 ring-slate-100">
          <table className="w-full text-sm">
            <thead className="sticky top-0 bg-slate-50 text-xs text-slate-500">
              <tr>
                <th className="px-3 py-2 text-left font-medium">Dia</th>
                <th className="px-3 py-2 text-right font-medium">Previstos</th>
                <th className="px-3 py-2 text-right font-medium">Faltas</th>
                <th className="px-3 py-2 text-right font-medium">Atrasos</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {diasUteis.map((d) => (
                <tr key={d.data}>
                  <td className="px-3 py-2 text-slate-600">
                    {formatData(d.data, { weekday: 'short', day: '2-digit', month: '2-digit' })}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums text-slate-500">{d.previstos}</td>
                  <td className="px-3 py-2 text-right tabular-nums text-slate-700">{d.faltas}</td>
                  <td className="px-3 py-2 text-right tabular-nums text-slate-700">{d.atrasos}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="relative">
          <div className="relative ml-7 h-[220px]" onMouseLeave={() => setHover(null)}>
            {/* grade e eixo Y */}
            {ticks.map((t) => (
              <div
                key={t}
                className={clsx('absolute inset-x-0 border-t', t === 0 ? 'border-slate-300' : 'border-dashed border-slate-100')}
                style={{ bottom: `${(t / max) * 100}%` }}
              >
                <span className="absolute -left-7 -translate-y-1/2 text-[11px] tabular-nums text-slate-400">{t}</span>
              </div>
            ))}

            <div className="absolute inset-0 flex">
              {diasUteis.map((d, i) => (
                <div
                  key={d.data}
                  className="relative flex flex-1 cursor-default items-end justify-center gap-[2px] px-[3px]"
                  onMouseEnter={() => setHover(i)}
                >
                  {hover === i && <div className="absolute inset-y-0 inset-x-0 rounded-md bg-primary-50/70" />}
                  {SERIES.map((s) => {
                    const v = d[s.chave];
                    return (
                      <div
                        key={s.chave}
                        className="relative w-full max-w-[14px] rounded-t-[4px] transition-[height]"
                        style={{ height: v > 0 ? `${(v / max) * 100}%` : 0, background: s.cor }}
                      />
                    );
                  })}
                </div>
              ))}
            </div>

            {ativo && hover !== null && (
              <div
                className="pointer-events-none absolute top-2 z-10 w-44 rounded-xl bg-white p-3 text-xs shadow-card ring-1 ring-slate-900/5"
                style={{
                  left: `${((hover + 0.5) / diasUteis.length) * 100}%`,
                  transform: hover > diasUteis.length / 2 ? 'translateX(calc(-100% - 12px))' : 'translateX(12px)',
                }}
              >
                <p className="mb-2 font-semibold capitalize text-slate-800">
                  {parseISODate(ativo.data).toLocaleDateString('pt-BR', {
                    weekday: 'short',
                    day: '2-digit',
                    month: 'short',
                  })}
                </p>
                {SERIES.map((s) => (
                  <div key={s.chave} className="flex items-center justify-between py-0.5">
                    <span className="flex items-center gap-1.5 text-slate-500">
                      <span className="h-2 w-2 rounded-sm" style={{ background: s.cor }} />
                      {s.nome}
                    </span>
                    <span className="font-semibold tabular-nums text-slate-800">{ativo[s.chave]}</span>
                  </div>
                ))}
                <div className="mt-1.5 flex justify-between border-t border-slate-100 pt-1.5 text-slate-400">
                  <span>Escalados</span>
                  <span className="tabular-nums">{ativo.previstos}</span>
                </div>
              </div>
            )}
          </div>

          <div className="ml-7 mt-2 flex">
            {diasUteis.map((d, i) => (
              <span key={d.data} className="flex-1 text-center text-[10px] tabular-nums text-slate-400">
                {i % passoRotulo === 0 ? formatData(d.data) : ''}
              </span>
            ))}
          </div>

          {total === 0 && (
            <p className="mt-3 text-center text-xs text-slate-500">
              Nenhuma falta ou atraso no período. 🎉
            </p>
          )}
        </div>
      )}
    </div>
  );
}
