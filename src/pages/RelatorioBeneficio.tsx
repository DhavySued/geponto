import clsx from 'clsx';
import { AlertTriangle, Download, Printer, Search, Wallet } from 'lucide-react';
import { useState } from 'react';
import { CabecalhoImpressao, useCabecalhoCsv } from '@/components/relatorios/CabecalhoImpressao';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { formatData, formatMinutos, formatMoeda, parseISODate } from '@/lib/format';
import { competencia, opcoesColaboradores, paramColaboradores, useFiltrosAux } from '@/lib/hooks';
import { ocorrencia, siglaMarcacao } from '@/lib/ponto';
import type { RelatorioBeneficio as Dados, RelatorioBeneficioDia, RelatorioBeneficioItem, TipoBeneficio } from '@/lib/types';

const MAX_DIAS = 92;
const TITULO: Record<TipoBeneficio, string> = { vt: 'Relatório de VT (vale-transporte)', va: 'Relatório de VA (vale-alimentação)' };

const dataBR = (d: string) => formatData(d, { day: '2-digit', month: '2-digit', year: 'numeric' });
const diasEntre = (a: string, b: string) => Math.round((parseISODate(b).getTime() - parseISODate(a).getTime()) / 86400000) + 1;
const batidasTexto = (d: RelatorioBeneficioDia) =>
  d.batidas.map((b) => `${siglaMarcacao(b.sentido, b.turno)} ${b.hora}${b.manual ? '*' : ''}`).join('  ');

/** Por que o dia não contou */
function motivo(d: RelatorioBeneficioDia): string {
  if (d.computa) return '';
  if (d.turnos > 0) return `Trabalhou ${d.turnos} de ${d.turnos_previstos} turnos`;
  if (d.batidas.length > 0) return 'Nenhum turno completo (batida sem par)';
  return ocorrencia(d.ocorrencia).label;
}

function RelatorioBeneficio({ tipo }: { tipo: TipoBeneficio }) {
  const sigla = tipo.toUpperCase();
  const { aux, erro: erroAux } = useFiltrosAux();
  const cabecalhoCsv = useCabecalhoCsv();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '' });
  const [dados, setDados] = useState<Dados | null>(null);
  const [soComputados, setSoComputados] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const consultar = async () => {
    if (diasEntre(periodo.ini, periodo.fim) > MAX_DIAS) return setErro(`Selecione um período de até ${MAX_DIAS} dias.`);
    setCarregando(true);
    try {
      setErro(null);
      setDados(await api<Dados>('api_relatorio_beneficio', {
        p_tipo: tipo,
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

  const consultado = dados ? { ini: dados.periodo.inicio, fim: dados.periodo.fim } : periodo;
  const itens = dados?.itens ?? [];
  const diasDe = (i: RelatorioBeneficioItem) => (soComputados ? i.dias.filter((d) => d.computa) : i.dias);
  const totalDias = itens.reduce((s, i) => s + i.dias_computados, 0);
  const totalValor = itens.reduce((s, i) => s + Number(i.valor_total), 0);

  const exportar = () => {
    const num = (v: number) => Number(v).toFixed(2).replace('.', ',');
    const linhas = [
      ...cabecalhoCsv(TITULO[tipo], consultado),
      ['Matrícula', 'Colaborador', 'Departamento', 'Data', 'Código', `Tipo de ${sigla}`, 'Batidas', 'Turnos trabalhados', `Computa ${sigla}`, 'Valor', 'Motivo'].join(';'),
      ...itens.flatMap((i) => diasDe(i).map((d) => [i.matricula, i.nome, i.departamento ?? '', dataBR(d.data), d.codigo, d.tipo,
        batidasTexto(d), d.turnos, d.computa ? 'Sim' : 'Não', num(d.computa ? d.valor_diario : 0), motivo(d)]
        .map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';'))),
    ];
    baixarArquivo(`${tipo}_${consultado.ini}_${consultado.fim}.csv`, linhas.join('\r\n'), 'text/csv');
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3 print:hidden">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">{TITULO[tipo]}</h2>
          <p className="mt-1 text-sm text-slate-500">
            Dias marcados para {sigla} na jornada de quem recebe {sigla}, quais foram trabalhados e o valor a considerar.
          </p>
        </div>
        {itens.length > 0 && (
          <div className="flex gap-2">
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
            <select className="input" value={filtros.departamento} onChange={(e) => setFiltros({ departamento: e.target.value, colaboradores: [] })}>
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
          <input type="checkbox" checked={soComputados} onChange={(e) => setSoComputados(e.target.checked)} />
          Mostrar só os dias que contam para o {sigla}
        </label>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200 print:hidden">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card"><EmptyState icon={Wallet} titulo="Escolha o período e clique em Consultar" descricao={`Até ${MAX_DIAS} dias por consulta.`} /></div>
      ) : itens.length === 0 ? (
        <div className="card"><EmptyState icon={Wallet} titulo={`Nenhum dia de ${sigla} no período`}
          descricao={`Confira se o colaborador está com "Recebe ${sigla}" e se os dias estão marcados na jornada.`} /></div>
      ) : (
        <>
          <CabecalhoImpressao titulo={TITULO[tipo]} periodo={consultado} />
          <p className="text-xs text-slate-500">
            O dia conta quando o colaborador trabalha {dados.turnos === 'dois' ? 'os dois turnos' : 'ao menos um turno'} (Configurações).
            {dados.periodo.apurado_ate < dados.periodo.fim && ` Apurado até ${dataBR(dados.periodo.apurado_ate)}.`} * = batida incluída manualmente.
          </p>
          <div className="grid grid-cols-3 gap-3">
            {([['Colaboradores', itens.length], [`Dias de ${sigla}`, totalDias], ['Valor total', formatMoeda(totalValor)]] as const).map(([t, v]) => (
              <div key={t} className="card px-4 py-3">
                <p className="text-xs text-slate-400">{t}</p>
                <p className="text-xl font-semibold tabular-nums text-slate-800">{v}</p>
              </div>
            ))}
          </div>
          {itens.map((i) => (
            <section key={i.colaborador_id} className="card overflow-hidden print:mb-4 print:overflow-visible print:shadow-none print:ring-0">
              <div className="flex flex-wrap items-center justify-between gap-3 border-b border-slate-100 px-4 py-3 print:break-after-avoid">
                <div>
                  <p className="font-semibold text-slate-800">{i.nome}</p>
                  <p className="text-xs text-slate-400">Mat. {i.matricula}{i.departamento && ` · ${i.departamento}`}</p>
                </div>
                <p className="text-sm tabular-nums text-slate-600">
                  <strong className="font-semibold text-slate-800">{i.dias_computados}</strong> de {i.dias_marcados} dia(s) ·{' '}
                  <strong className="font-semibold text-primary-700">{formatMoeda(Number(i.valor_total))}</strong>
                </p>
              </div>
              <div className="overflow-x-auto print:overflow-visible">
                <table className="w-full min-w-[820px] text-sm print:min-w-0 print:text-[10px]">
                  <thead>
                    <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                      <th className="px-4 py-2 font-medium">Data</th>
                      <th className="px-4 py-2 font-medium">Tipo</th>
                      <th className="px-4 py-2 font-medium">Batidas</th>
                      <th className="px-4 py-2 text-right font-medium">Turnos</th>
                      <th className="px-4 py-2 text-right font-medium">Trabalhado</th>
                      <th className="px-4 py-2 font-medium">Computa</th>
                      <th className="px-4 py-2 text-right font-medium">Valor</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {diasDe(i).map((d) => (
                      <tr key={d.data} className="break-inside-avoid align-top">
                        <td className="whitespace-nowrap px-4 py-2 tabular-nums text-slate-700">
                          {formatData(d.data, { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' })}
                        </td>
                        <td className="px-4 py-2 text-slate-600">{d.codigo} · {d.tipo}</td>
                        <td className="px-4 py-2 tabular-nums text-slate-700">
                          {batidasTexto(d) || '—'}
                          {d.pre_assinalado && <span className="block text-[11px] text-slate-400">Intervalo pré-assinalado</span>}
                        </td>
                        <td className="px-4 py-2 text-right tabular-nums text-slate-700">{d.turnos}</td>
                        <td className="px-4 py-2 text-right tabular-nums text-slate-700">{d.trabalhado_min ? formatMinutos(d.trabalhado_min) : '—'}</td>
                        <td className="px-4 py-2">
                          <Badge tone={d.computa ? 'green' : 'slate'} dot={false}>{d.computa ? 'Sim' : 'Não'}</Badge>
                          {!d.computa && <span className="ml-2 text-xs text-slate-500">{motivo(d)}</span>}
                        </td>
                        <td className={clsx('whitespace-nowrap px-4 py-2 text-right tabular-nums', d.computa ? 'text-slate-800' : 'text-slate-300')}>
                          {d.computa ? formatMoeda(Number(d.valor_diario)) : '—'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>
          ))}
        </>
      )}
    </div>
  );
}

// key: ao trocar de um relatório para o outro, a tela começa limpa
export const RelatorioVT = () => <RelatorioBeneficio key="vt" tipo="vt" />;
export const RelatorioVA = () => <RelatorioBeneficio key="va" tipo="va" />;
