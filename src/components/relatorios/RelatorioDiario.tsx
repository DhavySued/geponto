import clsx from 'clsx';
import { AlertTriangle, Download, Printer, Search, type LucideIcon } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import { CabecalhoImpressao } from '@/components/relatorios/CabecalhoImpressao';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { formatData, toISODate } from '@/lib/format';
import { competencia, opcoesColaboradores, paramColaboradores, useFiltrosAux } from '@/lib/hooks';
import type { RelatorioPeriodo } from '@/lib/types';

/** Máximo padrão de dias por consulta (fim − início ≤ 30: um mês inteiro) */
const MAX_PADRAO = 31;

export interface ColunaRel<T> {
  titulo: string;
  valor: (i: T) => ReactNode;
  csv: (i: T) => string | number;
  direita?: boolean;
}

const diasEntre = (a: string, b: string) => Math.round((new Date(b + 'T12:00').getTime() - new Date(a + 'T12:00').getTime()) / 86400000) + 1;

/** Relatório com uma linha por colaborador e dia, filtros padrão e limite de 31 dias por consulta. */
export function RelatorioDiario<T extends { colaborador_id: string; colaborador: string; matricula: string; departamento: string | null; data: string }>({
  titulo, descricao, icon, rpc, colunas, resumo, arquivo, vazio, maxDias = MAX_PADRAO,
}: {
  /** Máximo de dias por consulta (o mesmo limite da API) */
  maxDias?: number;
  titulo: string;
  descricao: string;
  icon: LucideIcon;
  rpc: string;
  colunas: ColunaRel<T>[];
  resumo?: (itens: T[]) => [string, ReactNode][];
  arquivo: string;
  vazio: string;
}) {
  const MAX_DIAS = maxDias;
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '' });
  const [dados, setDados] = useState<RelatorioPeriodo<T> | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const dias = diasEntre(periodo.ini, periodo.fim);

  // Ao mudar uma das datas, mantém o período dentro do limite
  const mudar = (campo: 'ini' | 'fim', v: string) => {
    if (!v) return;
    setPeriodo((p) => {
      const n = { ...p, [campo]: v };
      if (diasEntre(n.ini, n.fim) > MAX_DIAS || n.fim < n.ini) {
        const d = new Date(v + 'T12:00');
        d.setDate(d.getDate() + (campo === 'ini' ? MAX_DIAS - 1 : -(MAX_DIAS - 1)));
        if (campo === 'ini') n.fim = n.fim < n.ini ? v : toISODate(d);
        else n.ini = n.fim < n.ini ? v : toISODate(d);
      }
      return n;
    });
  };

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(await api<RelatorioPeriodo<T>>(rpc, {
        p_ini: periodo.ini, p_fim: periodo.fim,
        p_colaboradores: paramColaboradores(filtros.colaboradores),
        p_departamento: filtros.departamento || null,
      }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  const itens = dados?.itens ?? [];
  const exportar = () => {
    const linhas = [
      ['Matrícula', 'Colaborador', 'Departamento', 'Data', ...colunas.map((c) => c.titulo)].join(';'),
      ...itens.map((i) => [i.matricula, i.colaborador, i.departamento ?? '', formatData(i.data), ...colunas.map((c) => c.csv(i))]
        .map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';')),
    ];
    baixarArquivo(`${arquivo}_${periodo.ini}_${periodo.fim}.csv`, linhas.join('\r\n'), 'text/csv');
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">{titulo}</h2>
          <p className="mt-1 text-sm text-slate-500">{descricao}</p>
        </div>
        {itens.length > 0 && (
          <div className="flex gap-2 print:hidden">
            <Button variant="secondary" onClick={exportar}><Download className="h-4 w-4" /> Exportar CSV</Button>
            <Button variant="secondary" onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir</Button>
          </div>
        )}
      </div>

      <section className="card p-5 print:hidden">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[160px_160px_1fr_1fr_auto] lg:items-end">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} onChange={(e) => mudar('ini', e.target.value)} />
          </Field>
          <Field label="Até" dica={`${dias} dia(s) · máximo ${MAX_DIAS}`}>
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => mudar('fim', e.target.value)} />
          </Field>
          <Field label="Departamento">
            <select className="input" value={filtros.departamento} onChange={(e) => setFiltros((f) => ({ ...f, departamento: e.target.value, colaboradores: [] }))}>
              <option value="">Todos</option>
              {aux?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
            </select>
          </Field>
          <Field label="Colaborador">
            <ComboboxChips opcoes={opcoesColaboradores(aux?.colaboradores, filtros)} valor={filtros.colaboradores}
              onChange={(v) => setFiltros((f) => ({ ...f, colaboradores: v }))} rotuloTodos="Todos os colaboradores" />
          </Field>
          <Button onClick={consultar} loading={carregando}><Search className="h-4 w-4" /> Consultar</Button>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card"><EmptyState icon={icon} titulo="Escolha o período e clique em Consultar" descricao={`Até ${MAX_DIAS} dias por consulta.`} /></div>
      ) : itens.length === 0 ? (
        <div className="card"><EmptyState icon={icon} titulo={vazio} descricao="Não há registros com esses filtros." /></div>
      ) : (
        <>
          <CabecalhoImpressao titulo={titulo} periodo={periodo} />
          {resumo && (
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {resumo(itens).map(([t, v]) => (
                <div key={t} className="card px-4 py-3">
                  <p className="text-xs text-slate-400">{t}</p>
                  <p className="text-xl font-semibold tabular-nums text-slate-800">{v}</p>
                </div>
              ))}
            </div>
          )}
          <div className="card overflow-x-auto print:overflow-visible print:shadow-none print:ring-0">
            <table className="w-full min-w-[820px] text-sm print:min-w-0 print:text-xs">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-4 py-2.5 font-medium">Colaborador</th>
                  <th className="px-4 py-2.5 font-medium">Data</th>
                  {colunas.map((c) => <th key={c.titulo} className={clsx('px-4 py-2.5 font-medium', c.direita && 'text-right')}>{c.titulo}</th>)}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {itens.map((i, k) => {
                  const primeiro = k === 0 || itens[k - 1].colaborador_id !== i.colaborador_id;
                  return (
                    <tr key={`${i.colaborador_id}-${i.data}`} className={clsx('break-inside-avoid align-top', primeiro && k > 0 && 'border-t-2 border-slate-200')}>
                      <td className="px-4 py-2.5">
                        {primeiro ? (
                          <>
                            <p className="font-medium text-slate-800">{i.colaborador}</p>
                            <p className="text-xs text-slate-400">Mat. {i.matricula}{i.departamento && ` · ${i.departamento}`}</p>
                          </>
                        ) : <span className="text-slate-300">〃</span>}
                      </td>
                      <td className="whitespace-nowrap px-4 py-2.5 capitalize tabular-nums text-slate-700">
                        {formatData(i.data, { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' })}
                      </td>
                      {colunas.map((c) => (
                        <td key={c.titulo} className={clsx('whitespace-nowrap px-4 py-2.5 tabular-nums text-slate-700', c.direita && 'text-right')}>{c.valor(i)}</td>
                      ))}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
