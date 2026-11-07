import clsx from 'clsx';
import { Fingerprint, Search, Smartphone } from 'lucide-react';
import { rotuloMarcacao, siglaMarcacao } from '@/lib/ponto';
import { useMemo, useState } from 'react';
import { StatusHojeBadge } from '@/components/ui/Badge';
import { EmptyState } from '@/components/ui/EmptyState';
import { formatMinutos, iniciais } from '@/lib/format';
import type { RegistroHoje, StatusHoje } from '@/lib/types';

const FILTROS: { chave: string; label: string; status: StatusHoje[] | null }[] = [
  { chave: 'todos', label: 'Todos', status: null },
  { chave: 'trabalhando', label: 'Em jornada', status: ['em_jornada'] },
  { chave: 'intervalo', label: 'Intervalo', status: ['em_intervalo'] },
  { chave: 'encerrados', label: 'Encerrados', status: ['finalizado'] },
  { chave: 'ausentes', label: 'Ausentes', status: ['ausente', 'aguardando'] },
  { chave: 'outros', label: 'Folga / Afastados', status: ['folga', 'ausencia', 'ferias', 'afastado'] },
];

function Batidas({ batidas }: { batidas: RegistroHoje['batidas'] }) {
  if (batidas.length === 0) return <span className="text-xs text-slate-400">Sem marcações</span>;
  return (
    <div className="flex flex-wrap gap-1.5">
      {batidas.map((b) => (
        <span
          key={b.id}
          title={`${rotuloMarcacao(b.sentido, b.turno)} · ${b.origem}`}
          className={clsx(
            'inline-flex items-center gap-1 rounded-lg px-2 py-0.5 text-xs font-medium tabular-nums ring-1 ring-inset',
            b.origem === 'manual'
              ? 'bg-accent-50 text-accent-700 ring-accent-600/20'
              : 'bg-slate-50 text-slate-700 ring-slate-200',
          )}
        >
          {b.origem === 'mobile' && <Smartphone className="h-3 w-3 text-slate-400" />}
          <span className="text-[10px] font-semibold text-slate-400">{siglaMarcacao(b.sentido, b.turno)}</span>
          {b.hora}
        </span>
      ))}
    </div>
  );
}

export function RegistrosHoje({ dados }: { dados: RegistroHoje[] }) {
  const [filtro, setFiltro] = useState('todos');
  const [busca, setBusca] = useState('');

  const contagem = useMemo(() => {
    const c: Record<string, number> = {};
    for (const f of FILTROS) c[f.chave] = f.status ? dados.filter((d) => f.status!.includes(d.status)).length : dados.length;
    return c;
  }, [dados]);

  const filtrados = useMemo(() => {
    const f = FILTROS.find((x) => x.chave === filtro);
    const termo = busca.trim().toLowerCase();
    return dados.filter(
      (d) =>
        (!f?.status || f.status.includes(d.status)) &&
        (!termo || d.nome.toLowerCase().includes(termo) || d.matricula.toLowerCase().includes(termo)),
    );
  }, [dados, filtro, busca]);

  return (
    <div>
      <div className="flex flex-col gap-3 border-b border-slate-100 px-5 pb-4 lg:flex-row lg:items-center lg:justify-between">
        <div className="-mx-1 flex gap-1 overflow-x-auto px-1 pb-1 lg:pb-0">
          {FILTROS.map((f) => (
            <button
              key={f.chave}
              onClick={() => setFiltro(f.chave)}
              className={clsx(
                'flex shrink-0 items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium transition',
                filtro === f.chave
                  ? 'bg-primary-700 text-white'
                  : 'text-slate-500 hover:bg-slate-100 hover:text-slate-700',
              )}
            >
              {f.label}
              <span
                className={clsx(
                  'rounded-md px-1.5 text-[10px] tabular-nums',
                  filtro === f.chave ? 'bg-white/15' : 'bg-slate-100 text-slate-500',
                )}
              >
                {contagem[f.chave]}
              </span>
            </button>
          ))}
        </div>
        <div className="relative lg:w-64">
          <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
          <input
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            placeholder="Buscar colaborador ou matrícula"
            className="input h-9 pl-9"
          />
        </div>
      </div>

      {filtrados.length === 0 ? (
        <EmptyState
          icon={Fingerprint}
          titulo={dados.length === 0 ? 'Nenhum colaborador escalado hoje' : 'Nenhum registro encontrado'}
          descricao={
            dados.length === 0
              ? 'Cadastre colaboradores e vincule uma jornada para acompanhar as batidas do dia.'
              : 'Ajuste o filtro ou o termo de busca para ver outros colaboradores.'
          }
        />
      ) : (
        <>
          {/* Desktop: tabela */}
          <div className="hidden overflow-x-auto md:block">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-xs text-slate-400">
                  <th className="px-5 py-3 font-medium">Colaborador</th>
                  <th className="px-5 py-3 font-medium">Departamento</th>
                  <th className="px-5 py-3 font-medium">Entrada prevista</th>
                  <th className="px-5 py-3 font-medium">Marcações</th>
                  <th className="px-5 py-3 font-medium">Status</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {filtrados.map((r) => (
                  <tr key={r.id} className="transition hover:bg-slate-50/70">
                    <td className="px-5 py-3">
                      <div className="flex items-center gap-3">
                        <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-xs font-semibold text-primary-700">
                          {iniciais(r.nome)}
                        </span>
                        <div className="min-w-0">
                          <p className="truncate font-medium text-slate-800">{r.nome}</p>
                          <p className="truncate text-xs text-slate-400">
                            Mat. {r.matricula}
                            {r.cargo && ` · ${r.cargo}`}
                          </p>
                        </div>
                      </div>
                    </td>
                    <td className="px-5 py-3 text-slate-600">{r.departamento ?? '—'}</td>
                    <td className="px-5 py-3">
                      <span className="tabular-nums text-slate-600">{r.entrada_prevista ?? '—'}</span>
                      {r.atraso_min > 0 && (
                        <span className="ml-2 rounded-md bg-accent-50 px-1.5 py-0.5 text-[11px] font-medium text-accent-700">
                          +{formatMinutos(r.atraso_min)}
                        </span>
                      )}
                    </td>
                    <td className="px-5 py-3">
                      <Batidas batidas={r.batidas} />
                    </td>
                    <td className="px-5 py-3">
                      <StatusHojeBadge status={r.status} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Mobile: cards */}
          <ul className="divide-y divide-slate-100 md:hidden">
            {filtrados.map((r) => (
              <li key={r.id} className="space-y-2.5 px-5 py-4">
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    <p className="truncate font-medium text-slate-800">{r.nome}</p>
                    <p className="truncate text-xs text-slate-400">
                      {r.departamento ?? `Mat. ${r.matricula}`}
                      {r.entrada_prevista && ` · entrada ${r.entrada_prevista}`}
                    </p>
                  </div>
                  <StatusHojeBadge status={r.status} />
                </div>
                <Batidas batidas={r.batidas} />
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  );
}
