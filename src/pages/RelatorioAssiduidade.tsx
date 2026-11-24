import clsx from 'clsx';
import { AlertTriangle, Award, Download, Printer, Search } from 'lucide-react';
import { useMemo, useState } from 'react';
import { CabecalhoImpressao, useCabecalhoCsv } from '@/components/relatorios/CabecalhoImpressao';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { formatData, formatMinutos, toISODate } from '@/lib/format';
import { competencia, opcoesColaboradores, paramColaboradores, useFiltrosAux } from '@/lib/hooks';
import type { RelatorioAssiduidadeItem } from '@/lib/types';

const MAX_DIAS = 92;
const diasEntre = (a: string, b: string) => Math.round((new Date(b + 'T12:00').getTime() - new Date(a + 'T12:00').getTime()) / 86400000) + 1;

/** Percentual de dias previstos sem falta (null quando não há dia previsto) */
const assiduidade = (i: RelatorioAssiduidadeItem) =>
  i.dias_previstos > 0 ? ((i.dias_previstos - i.faltas) / i.dias_previstos) * 100 : null;
/** Percentual de dias previstos sem falta, atraso nem saída antecipada */
const semOcorrencia = (i: RelatorioAssiduidadeItem) =>
  i.dias_previstos > 0 ? ((i.dias_previstos - i.dias_com_ocorrencia) / i.dias_previstos) * 100 : null;
const pct = (v: number | null) => (v === null ? '—' : `${v.toLocaleString('pt-BR', { maximumFractionDigits: 1 })}%`);
const assiduo = (i: RelatorioAssiduidadeItem) => i.dias_previstos > 0 && i.dias_com_ocorrencia === 0;

type Mostrar = 'todos' | 'assiduos' | 'com_ocorrencia';
type Ordem = 'nome' | 'assiduidade';

interface Resposta {
  periodo: { inicio: string; fim: string; apurado_ate: string };
  itens: RelatorioAssiduidadeItem[];
}

export default function RelatorioAssiduidade() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const cabecalhoCsv = useCabecalhoCsv();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '' });
  const [mostrar, setMostrar] = useState<Mostrar>('todos');
  const [ordem, setOrdem] = useState<Ordem>('nome');
  const [dados, setDados] = useState<Resposta | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const dias = diasEntre(periodo.ini, periodo.fim);

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
      setDados(await api<Resposta>('api_relatorio_assiduidade', {
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

  const itens = useMemo(() => {
    const lista = (dados?.itens ?? []).filter((i) =>
      mostrar === 'todos' || (mostrar === 'assiduos' ? assiduo(i) : i.dias_com_ocorrencia > 0));
    if (ordem === 'assiduidade') {
      lista.sort((a, b) => (assiduidade(a) ?? 101) - (assiduidade(b) ?? 101)
        || (semOcorrencia(a) ?? 101) - (semOcorrencia(b) ?? 101) || a.colaborador.localeCompare(b.colaborador));
    }
    return lista;
  }, [dados, mostrar, ordem]);

  const totais = useMemo(() => {
    const t = { previstos: 0, faltas: 0, atrasos: 0, saidas: 0 };
    for (const i of itens) {
      t.previstos += i.dias_previstos;
      t.faltas += i.faltas;
      t.atrasos += i.atrasos;
      t.saidas += i.saidas_antecipadas;
    }
    return t;
  }, [itens]);

  // Período do que está na tela (os campos podem ter mudado depois da consulta)
  const consultado = dados ? { ini: dados.periodo.inicio, fim: dados.periodo.fim } : periodo;
  const exportar = () => {
    const cab = ['Matrícula', 'Colaborador', 'Departamento', 'Dias previstos', 'Dias trabalhados', 'Faltas', 'Faltas abonadas',
      'Dias de afastamento/ocorrência', 'Atrasos', 'Minutos de atraso', 'Saídas antecipadas', 'Minutos de saída antecipada',
      'Dias com falta/atraso/saída', 'Assiduidade (%)', 'Dias sem ocorrência (%)'];
    const num = (v: number | null) => (v === null ? '' : v.toFixed(1).replace('.', ','));
    const linhas = [cab.join(';'), ...itens.map((i) => [
      i.matricula, i.colaborador, i.departamento ?? '', i.dias_previstos, i.dias_trabalhados, i.faltas, i.faltas_abonadas,
      i.dias_ausencia, i.atrasos, i.atraso_min, i.saidas_antecipadas, i.saida_antecipada_min, i.dias_com_ocorrencia,
      num(assiduidade(i)), num(semOcorrencia(i)),
    ].map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';'))];
    baixarArquivo(`assiduidade_${consultado.ini}_${consultado.fim}.csv`, [...cabecalhoCsv('Listagem de assiduidade', consultado), ...linhas].join('\r\n'), 'text/csv');
  };

  const apuradoAte = dados && dados.periodo.apurado_ate < dados.periodo.fim ? dados.periodo.apurado_ate : null;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3 print:hidden">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Listagem de assiduidade</h2>
          <p className="mt-1 text-sm text-slate-500">
            Por colaborador: dias previstos, faltas, atrasos e saídas antecipadas no período. Assíduo é quem não teve nenhuma das três.
          </p>
        </div>
        {itens.length > 0 && (
          <div className="flex gap-2 print:hidden">
            <Button variant="secondary" onClick={exportar}><Download className="h-4 w-4" /> Exportar CSV</Button>
            <Button variant="secondary" onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir</Button>
          </div>
        )}
      </div>

      <section className="card space-y-4 p-5 print:hidden">
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
        <div className="grid gap-4 sm:grid-cols-2 lg:w-2/3">
          <Field label="Mostrar">
            <select className="input" value={mostrar} onChange={(e) => setMostrar(e.target.value as Mostrar)}>
              <option value="todos">Todos os colaboradores</option>
              <option value="assiduos">Só os assíduos (sem falta, atraso nem saída antecipada)</option>
              <option value="com_ocorrencia">Só quem teve falta, atraso ou saída antecipada</option>
            </select>
          </Field>
          <Field label="Ordenar por">
            <select className="input" value={ordem} onChange={(e) => setOrdem(e.target.value as Ordem)}>
              <option value="nome">Nome</option>
              <option value="assiduidade">Menor assiduidade primeiro</option>
            </select>
          </Field>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card"><EmptyState icon={Award} titulo="Escolha o período e clique em Consultar" descricao={`Até ${MAX_DIAS} dias por consulta.`} /></div>
      ) : itens.length === 0 ? (
        <div className="card"><EmptyState icon={Award} titulo="Nenhum colaborador" descricao="Não há colaboradores com dias previstos com esses filtros." /></div>
      ) : (
        <>
          <CabecalhoImpressao titulo="Listagem de assiduidade" periodo={consultado} />
          {apuradoAte && (
            <p className="text-xs text-slate-500">Apurado até {formatData(apuradoAte)}: os dias de hoje em diante ainda não entram.</p>
          )}
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
            {([
              ['Colaboradores', itens.length],
              ['Assíduos', itens.filter(assiduo).length],
              ['Faltas', totais.faltas],
              ['Assiduidade geral', pct(totais.previstos ? ((totais.previstos - totais.faltas) / totais.previstos) * 100 : null)],
            ] as const).map(([t, v]) => (
              <div key={t} className="card px-4 py-3">
                <p className="text-xs text-slate-400">{t}</p>
                <p className="text-xl font-semibold tabular-nums text-slate-800">{v}</p>
              </div>
            ))}
          </div>
          <div className="card overflow-x-auto print:overflow-visible print:shadow-none print:ring-0">
            <table className="w-full min-w-[980px] text-sm print:min-w-0 print:text-xs">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-4 py-2.5 font-medium">Colaborador</th>
                  <th className="px-3 py-2.5 text-right font-medium">Previstos</th>
                  <th className="px-3 py-2.5 text-right font-medium">Trabalhados</th>
                  <th className="px-3 py-2.5 text-right font-medium">Faltas</th>
                  <th className="px-3 py-2.5 text-right font-medium" title="Faltas abonadas por justificativa">Abonadas</th>
                  <th className="px-3 py-2.5 text-right font-medium" title="Dias de férias, atestado, afastamento ou outra ocorrência">Afastamentos</th>
                  <th className="px-3 py-2.5 text-right font-medium">Atrasos</th>
                  <th className="px-3 py-2.5 text-right font-medium">Saídas antecip.</th>
                  <th className="px-3 py-2.5 text-right font-medium">Assiduidade</th>
                  <th className="px-3 py-2.5 text-right font-medium" title="Dias previstos sem falta, atraso nem saída antecipada">Dias sem ocorrência</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {itens.map((i) => {
                  const a = assiduidade(i);
                  return (
                    <tr key={i.colaborador_id} className="break-inside-avoid">
                      <td className="px-4 py-2.5">
                        <p className="flex items-center gap-2 font-medium text-slate-800">
                          {i.colaborador}
                          {assiduo(i) && <Badge tone="green" dot={false}>Assíduo</Badge>}
                        </p>
                        <p className="text-xs text-slate-400">Mat. {i.matricula}{i.departamento && ` · ${i.departamento}`}</p>
                      </td>
                      <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">{i.dias_previstos}</td>
                      <td className="px-3 py-2.5 text-right tabular-nums text-slate-700">{i.dias_trabalhados}</td>
                      <td className={clsx('px-3 py-2.5 text-right tabular-nums', i.faltas ? 'font-medium text-rose-600' : 'text-slate-400')}>{i.faltas}</td>
                      <td className="px-3 py-2.5 text-right tabular-nums text-slate-500">{i.faltas_abonadas || '—'}</td>
                      <td className="px-3 py-2.5 text-right tabular-nums text-slate-500">{i.dias_ausencia || '—'}</td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-right tabular-nums text-slate-700">
                        {i.atrasos ? <>{i.atrasos} <span className="text-xs text-slate-400">· {formatMinutos(i.atraso_min)}</span></> : <span className="text-slate-400">0</span>}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-right tabular-nums text-slate-700">
                        {i.saidas_antecipadas
                          ? <>{i.saidas_antecipadas} <span className="text-xs text-slate-400">· {formatMinutos(i.saida_antecipada_min)}</span></>
                          : <span className="text-slate-400">0</span>}
                      </td>
                      <td className={clsx('px-3 py-2.5 text-right font-semibold tabular-nums',
                        a === null ? 'text-slate-400' : a >= 100 ? 'text-emerald-600' : a >= 90 ? 'text-slate-800' : 'text-rose-600')}>
                        {pct(a)}
                      </td>
                      <td className="px-3 py-2.5 text-right tabular-nums text-slate-600">{pct(semOcorrencia(i))}</td>
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
