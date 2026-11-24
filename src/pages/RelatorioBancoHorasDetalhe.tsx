import clsx from 'clsx';
import { AlertTriangle, Download, Hourglass, Printer, Search } from 'lucide-react';
import { useState } from 'react';
import { CabecalhoImpressao, useCabecalhoCsv } from '@/components/relatorios/CabecalhoImpressao';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { formatData, formatMinutos, parseISODate } from '@/lib/format';
import { competencia, opcoesColaboradores, paramColaboradores, useFiltrosAux } from '@/lib/hooks';
import { ocorrencia, siglaMarcacao } from '@/lib/ponto';
import type { BancoHorasDetalheDia, BancoHorasDetalheItem, RelatorioBancoHorasDetalhe as Dados } from '@/lib/types';

const MAX_DIAS = 92;
const TIPO: Record<string, string> = { credito: 'Crédito', debito: 'Débito', compensacao: 'Compensação', ajuste: 'Ajuste', conversao: 'Conversão' };

const tom = (m: number) => (m > 0 ? 'text-emerald-700' : m < 0 ? 'text-rose-600' : 'text-slate-400');
const min = (m: number | null, sinal = false) => (m === null ? '—' : formatMinutos(m, sinal));
const dataCurta = (d: string) => `${formatData(d)} ${parseISODate(d).toLocaleDateString('pt-BR', { weekday: 'short' }).replace('.', '')}`;
const diasEntre = (a: string, b: string) => Math.round((parseISODate(b).getTime() - parseISODate(a).getTime()) / 86400000) + 1;
const ajustesDe = (d: BancoHorasDetalheDia) => d.lancamentos.reduce((s, x) => s + x.minutos, 0);
const temMovimento = (d: BancoHorasDetalheDia) => d.banco_min !== 0 || d.lancamentos.length > 0;

/** De onde veio o valor do dia no banco */
function explicacao(d: BancoHorasDetalheDia): string[] {
  const l: string[] = [];
  if (d.descricao) l.push(d.descricao);
  else if (d.banco_horas === false && d.saldo_min) l.push('Fora do banco de horas (vai para a folha)');
  for (const x of d.lancamentos) {
    l.push(`${TIPO[x.tipo] ?? x.tipo} ${formatMinutos(x.minutos, true)}${x.descricao ? ` — ${x.descricao}` : ''}`);
  }
  return l;
}

export default function RelatorioBancoHorasDetalhe() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const cabecalhoCsv = useCabecalhoCsv();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '' });
  const [dados, setDados] = useState<Dados | null>(null);
  const [soMovimento, setSoMovimento] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const consultar = async () => {
    if (diasEntre(periodo.ini, periodo.fim) > MAX_DIAS) {
      setErro(`Selecione um período de até ${MAX_DIAS} dias.`);
      return;
    }
    setCarregando(true);
    try {
      setErro(null);
      setDados(await api<Dados>('api_relatorio_banco_horas_detalhe', {
        p_ini: periodo.ini,
        p_fim: periodo.fim,
        p_colaboradores: paramColaboradores(filtros.colaboradores),
        p_departamento: filtros.departamento || null,
      }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  // Período do que está na tela (os campos podem ter mudado depois da consulta)
  const consultado = dados ? { ini: dados.periodo.inicio, fim: dados.periodo.fim } : periodo;
  const diasDe = (i: BancoHorasDetalheItem) => (soMovimento ? i.dias.filter(temMovimento) : i.dias);
  const visiveis = (dados?.itens ?? []).filter((i) => diasDe(i).length > 0 || i.saldo_anterior !== 0);

  const exportar = () => {
    const csv = (v: string | number) => `"${String(v).replace(/"/g, '""')}"`;
    const m = (v: number | null) => (v === null ? '' : formatMinutos(v));
    const linhas = [...cabecalhoCsv('Detalhamento de banco de horas', consultado), ['Matrícula', 'Colaborador', 'Departamento', 'Data', 'Horário previsto', 'Batidas', 'Ocorrência', 'Feriado',
      'Previsto', 'Trabalhado', 'Saldo do dia', 'Banco do dia', 'Ajustes e conversões', 'Saldo acumulado', 'Saldo acumulado (min)', 'Detalhe'].join(';')];
    for (const i of visiveis) {
      const base = [i.matricula, i.nome, i.departamento ?? ''];
      linhas.push([...base, '', '', '', 'Saldo anterior', '', '', '', '', '', '', m(i.saldo_anterior), i.saldo_anterior, ''].map(csv).join(';'));
      for (const d of diasDe(i)) {
        linhas.push([...base, formatData(d.data, { day: '2-digit', month: '2-digit', year: 'numeric' }), d.horario === 'Feriado' ? 'Feriado' : d.previsto_min === 0 ? '' : d.horario ?? '',
          d.batidas.map((b) => `${siglaMarcacao(b.sentido, b.turno)} ${b.hora}${b.manual ? '*' : ''}`).join(' '),
          d.ocorrencia ? ocorrencia(d.ocorrencia).label : '', d.feriado ?? '',
          m(d.previsto_min), m(d.trabalhado_min), m(d.saldo_min), m(d.banco_min), m(ajustesDe(d)),
          m(d.saldo_acumulado), d.saldo_acumulado, explicacao(d).join(' | ')].map(csv).join(';'));
      }
    }
    baixarArquivo(`detalhamento_banco_horas_${consultado.ini}_${consultado.fim}.csv`, linhas.join('\r\n'), 'text/csv');
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3 print:hidden">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Detalhamento de banco de horas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Dia a dia de cada colaborador: as batidas, o previsto, o trabalhado, o que entrou no banco e o saldo acumulado.
          </p>
        </div>
        {visiveis.length > 0 && (
          <div className="flex gap-2 print:hidden">
            <Button variant="secondary" onClick={exportar}><Download className="h-4 w-4" /> Exportar CSV</Button>
            <Button variant="secondary" onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir</Button>
          </div>
        )}
      </div>

      <section className="card space-y-4 p-5 print:hidden">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[160px_160px_1fr_1fr_auto] lg:items-end">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
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
        <label className="flex items-center gap-2 text-sm text-slate-600">
          <input type="checkbox" checked={soMovimento} onChange={(e) => setSoMovimento(e.target.checked)} />
          Mostrar só os dias que mudaram o banco de horas
        </label>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card"><EmptyState icon={Hourglass} titulo="Escolha o período e clique em Consultar" descricao="Os lançamentos do banco de horas são atualizados antes de gerar o relatório." /></div>
      ) : visiveis.length === 0 ? (
        <div className="card"><EmptyState icon={Hourglass} titulo="Nada para mostrar" descricao="Não há dias com esses filtros no período." /></div>
      ) : (
        <>
          <CabecalhoImpressao titulo="Detalhamento de banco de horas" periodo={consultado} />
          <p className="text-xs text-slate-500">
            Batidas e apuração até {formatData(dados.periodo.apurado_ate)}. E1/S1/E2/S2 = entrada e saída de cada turno · * = batida incluída manualmente.
          </p>
          {visiveis.map((i) => <Colaborador key={i.colaborador_id} item={i} dias={diasDe(i)} />)}
        </>
      )}
    </div>
  );
}

function Colaborador({ item, dias }: { item: BancoHorasDetalheItem; dias: BancoHorasDetalheDia[] }) {
  const th = 'px-3 py-2 font-medium';
  const num = 'whitespace-nowrap px-3 py-2 text-right tabular-nums';
  return (
    <section className="card overflow-hidden print:mb-4 print:overflow-visible print:shadow-none print:ring-0">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-100 px-4 py-3 print:break-after-avoid">
        <div>
          <p className="font-semibold text-slate-800">{item.nome}</p>
          <p className="text-xs text-slate-400">
            Mat. {item.matricula}{item.departamento && ` · ${item.departamento}`}{item.cargo && ` · ${item.cargo}`}
          </p>
        </div>
        <div className="flex gap-6 text-right text-sm tabular-nums">
          <div>
            <p className="text-xs text-slate-400">Saldo anterior</p>
            <p className={clsx('font-medium', tom(item.saldo_anterior))}>{formatMinutos(item.saldo_anterior, true)}</p>
          </div>
          <div>
            <p className="text-xs text-slate-400">Saldo final</p>
            <p className={clsx('font-semibold', tom(item.saldo_final))}>{formatMinutos(item.saldo_final, true)}</p>
          </div>
        </div>
      </div>
      {dias.length === 0 ? (
        <p className="px-4 py-3 text-sm text-slate-400">Sem dias para mostrar no período.</p>
      ) : (
        <div className="overflow-x-auto print:overflow-visible">
          <table className="w-full min-w-[980px] text-sm print:min-w-0 print:text-[10px]">
            <thead>
              <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                <th className={th}>Data</th>
                <th className={th}>Batidas</th>
                <th className={th}>Ocorrência</th>
                <th className={clsx(th, 'text-right')}>Previsto</th>
                <th className={clsx(th, 'text-right')}>Trabalhado</th>
                <th className={clsx(th, 'text-right')}>Saldo do dia</th>
                <th className={clsx(th, 'text-right')}>Banco</th>
                <th className={clsx(th, 'text-right')}>Acumulado</th>
                <th className={th}>Detalhe</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {dias.map((d) => {
                const banco = d.banco_min + ajustesDe(d);
                const oc = d.ocorrencia ? ocorrencia(d.ocorrencia) : null;
                return (
                  <tr key={d.data} className="break-inside-avoid align-top">
                    <td className="whitespace-nowrap px-3 py-2 text-slate-700">
                      {dataCurta(d.data)}
                      {d.horario && d.previsto_min !== 0 && <span className="block text-[11px] text-slate-400">{d.horario}</span>}
                    </td>
                    <td className="px-3 py-2">
                      {d.batidas.length === 0 ? <span className="text-slate-300">—</span> : (
                        <div className="flex flex-wrap gap-x-2.5 gap-y-0.5 tabular-nums text-slate-700">
                          {d.batidas.map((b, k) => (
                            <span key={k} className="whitespace-nowrap">
                              <span className="text-[10px] text-slate-400">{siglaMarcacao(b.sentido, b.turno)}</span> {b.hora}{b.manual && '*'}
                            </span>
                          ))}
                        </div>
                      )}
                      {d.pre_assinalado && <span className="block text-[11px] text-slate-400">Intervalo pré-assinalado</span>}
                    </td>
                    <td className="px-3 py-2">
                      {oc ? <Badge tone={oc.tone} dot={false}>{oc.label}</Badge> : <span className="text-slate-300">—</span>}
                      {(d.feriado || d.escala) && (
                        <span className="mt-0.5 block text-[11px] text-slate-400">
                          {[d.feriado && `Feriado: ${d.feriado}`, d.escala && `Escala de ${d.escala}`].filter(Boolean).join(' · ')}
                        </span>
                      )}
                    </td>
                    <td className={clsx(num, 'text-slate-700')}>{min(d.previsto_min)}</td>
                    <td className={clsx(num, 'text-slate-700')}>{min(d.trabalhado_min)}</td>
                    <td className={clsx(num, 'text-slate-700')}>{min(d.saldo_min, true)}</td>
                    <td className={clsx(num, 'font-medium', tom(banco))}>{temMovimento(d) ? formatMinutos(banco, true) : '—'}</td>
                    <td className={clsx(num, 'font-semibold', tom(d.saldo_acumulado))}>{formatMinutos(d.saldo_acumulado, true)}</td>
                    <td className="px-3 py-2 text-xs text-slate-500">
                      {explicacao(d).map((t, k) => <span key={k} className="block">{t}</span>)}
                      {d.fechado && <span className="block text-slate-400">Período fechado</span>}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
