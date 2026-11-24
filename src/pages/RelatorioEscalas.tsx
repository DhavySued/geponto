import clsx from 'clsx';
import { AlertTriangle, CalendarRange, Download, Printer, Search } from 'lucide-react';
import { useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { CabecalhoImpressao, useCabecalhoCsv } from '@/components/relatorios/CabecalhoImpressao';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { formatData, formatMinutos } from '@/lib/format';
import { competencia, opcoesColaboradores, paramColaboradores, useFiltrosAux } from '@/lib/hooks';
import type { RelatorioEscalas as Dados, RelatorioEscalasItem } from '@/lib/types';

const horario = (i: RelatorioEscalasItem) =>
  i.tipo === 'folga' ? 'Folga' : [i.entrada, i.saida_intervalo, i.retorno_intervalo, i.saida].filter(Boolean).join(' · ');

export default function RelatorioEscalas() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const cabecalhoCsv = useCabecalhoCsv();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '', tipo: '' });
  const [dados, setDados] = useState<Dados | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(await api<Dados>('api_relatorio_escalas', {
        p_ini: periodo.ini,
        p_fim: periodo.fim,
        p_colaboradores: paramColaboradores(filtros.colaboradores),
        p_departamento: filtros.departamento || null,
        p_tipo: filtros.tipo || null,
      }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  // Período do que está na tela (os campos podem ter mudado depois da consulta)
  const consultado = dados ? { ini: dados.periodo.inicio, fim: dados.periodo.fim } : periodo;
  const itens = dados?.itens ?? [];
  const trabalho = itens.filter((i) => i.tipo === 'trabalho');
  const resumo = {
    colaboradores: new Set(itens.map((i) => i.colaborador_id)).size,
    trabalho: trabalho.length,
    folga: itens.length - trabalho.length,
    feriados: trabalho.filter((i) => i.feriado).length,
    faltas: trabalho.filter((i) => i.realizado && i.falta).length,
  };

  const exportar = () => {
    const linhas = [
      ['Matrícula', 'Colaborador', 'Departamento', 'Data', 'Tipo', 'Escala', 'Horário', 'Feriado', 'Previsto', 'Trabalhado', 'Saldo', 'Falta'].join(';'),
      ...itens.map((i) => [i.matricula, i.colaborador, i.departamento ?? '', formatData(i.data), i.tipo === 'folga' ? 'Folga' : 'Trabalho',
        i.escala ?? '', horario(i), i.feriado ?? '',
        i.realizado && i.previsto_min != null ? formatMinutos(i.previsto_min) : '',
        i.realizado && i.trabalhado_min != null ? formatMinutos(i.trabalhado_min) : '',
        i.realizado && i.saldo_min != null ? formatMinutos(i.saldo_min, true) : '',
        i.realizado && i.falta ? 'Sim' : ''].map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';')),
    ];
    baixarArquivo(`escalas_${consultado.ini}_${consultado.fim}.csv`, [...cabecalhoCsv('Relatório de escalas', consultado), ...linhas].join('\r\n'), 'text/csv');
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3 print:hidden">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Relatório de escalas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Dias escalados (trabalho ou folga) no período, com o horário, se caiu em feriado e o que foi realizado.
          </p>
        </div>
        {itens.length > 0 && (
          <div className="flex gap-2 print:hidden">
            <Button variant="secondary" onClick={exportar}><Download className="h-4 w-4" /> Exportar CSV</Button>
            <Button variant="secondary" onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir</Button>
          </div>
        )}
      </div>

      <section className="card p-5 print:hidden">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[160px_160px_1fr_1fr_1fr_auto] lg:items-end">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="Tipo">
            <select className="input" value={filtros.tipo} onChange={(e) => setFiltros((f) => ({ ...f, tipo: e.target.value }))}>
              <option value="">Trabalho e folga</option>
              <option value="trabalho">Só trabalho</option>
              <option value="folga">Só folga</option>
            </select>
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
        <div className="card"><EmptyState icon={CalendarRange} titulo="Escolha o período e clique em Consultar" descricao="Entram os dias lançados no menu Escalas (até 3 meses por consulta)." /></div>
      ) : itens.length === 0 ? (
        <div className="card"><EmptyState icon={CalendarRange} titulo="Nenhuma escala no período" descricao="Não há dias escalados com esses filtros." /></div>
      ) : (
        <>
          <CabecalhoImpressao titulo="Relatório de escalas" periodo={consultado} />
          <div className="grid gap-3 sm:grid-cols-5">
            {[
              ['Colaboradores', resumo.colaboradores],
              ['Dias de trabalho', resumo.trabalho],
              ['Folgas', resumo.folga],
              ['Em feriado', resumo.feriados],
              ['Faltas', resumo.faltas],
            ].map(([t, v]) => (
              <div key={t} className="card px-4 py-3">
                <p className="text-xs text-slate-400">{t}</p>
                <p className="text-xl font-semibold tabular-nums text-slate-800">{v}</p>
              </div>
            ))}
          </div>
          <div className="card overflow-x-auto print:overflow-visible print:shadow-none print:ring-0">
            <table className="w-full min-w-[920px] text-sm print:min-w-0 print:text-xs">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-4 py-2.5 font-medium">Colaborador</th>
                  <th className="px-4 py-2.5 font-medium">Data</th>
                  <th className="px-4 py-2.5 font-medium">Escala</th>
                  <th className="px-4 py-2.5 font-medium">Horário</th>
                  <th className="px-4 py-2.5 text-right font-medium">Previsto</th>
                  <th className="px-4 py-2.5 text-right font-medium">Trabalhado</th>
                  <th className="px-4 py-2.5 text-right font-medium">Saldo</th>
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
                      <td className="whitespace-nowrap px-4 py-2.5 tabular-nums">
                        <p className="capitalize text-slate-700">{formatData(i.data, { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' })}</p>
                        {i.feriado && <Badge tone="orange" dot={false}>Feriado · {i.feriado}</Badge>}
                      </td>
                      <td className="px-4 py-2.5 text-slate-600">{i.escala ?? <span className="text-slate-300">—</span>}</td>
                      <td className="whitespace-nowrap px-4 py-2.5 tabular-nums">
                        {i.tipo === 'folga' ? <Badge tone="slate" dot={false}>Folga</Badge> : <span className="text-slate-700">{horario(i)}</span>}
                      </td>
                      <td className="whitespace-nowrap px-4 py-2.5 text-right tabular-nums text-slate-600">
                        {i.realizado && i.previsto_min ? formatMinutos(i.previsto_min) : '—'}
                      </td>
                      <td className="whitespace-nowrap px-4 py-2.5 text-right tabular-nums text-slate-700">
                        {!i.realizado ? <span className="text-xs text-slate-400">a realizar</span>
                          : i.falta ? <Badge tone="red" dot={false}>Falta</Badge>
                          : i.trabalhado_min ? formatMinutos(i.trabalhado_min) : '—'}
                      </td>
                      <td className={clsx('whitespace-nowrap px-4 py-2.5 text-right font-medium tabular-nums',
                        !i.realizado || !i.saldo_min ? 'text-slate-300' : i.saldo_min > 0 ? 'text-emerald-700' : 'text-rose-600')}>
                        {i.realizado && i.saldo_min ? formatMinutos(i.saldo_min, true) : '—'}
                      </td>
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
