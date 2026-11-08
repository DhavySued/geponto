import clsx from 'clsx';
import { AlertTriangle, Download, FileSpreadsheet, Save, Search, Settings2 } from 'lucide-react';
import { useState } from 'react';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { baixarArquivo, gerarArquivoFolha, type FormatoHoras, type LayoutArquivo } from '@/lib/exportacao';
import { formatData, formatMinutos } from '@/lib/format';
import { competencia, useFiltrosAux } from '@/lib/hooks';
import { textoPercentual } from '@/lib/perfilEvento';
import { api } from '@/lib/supabase';
import type { EventoFolha, TotaisColaborador, TotaisPeriodo as TotaisPeriodoT } from '@/lib/types';

const h = (min: number) => (min ? formatMinutos(min) : '—');

type Coluna = { titulo: string; valor: (t: TotaisColaborador) => string; destaque?: (t: TotaisColaborador) => string };

const heDe = (t: TotaisColaborador, p: number) => (t.he ?? []).find((x) => x.percentual === p)?.minutos ?? 0;

/** Uma coluna de hora extra para cada percentual que aparece no período (HE 50%, HE 100%…) */
function colunas(percentuais: number[]): Coluna[] {
  const he: Coluna[] = percentuais.length
    ? percentuais.map((p) => ({
        titulo: `HE ${textoPercentual(p)}`,
        valor: (t) => h(heDe(t, p)),
        destaque: (t) => (heDe(t, p) ? 'text-primary-700 font-semibold' : ''),
      }))
    : [{ titulo: 'Horas extras', valor: () => '—' }];
  return [...COLUNAS_INICIO, ...he, ...COLUNAS_FIM];
}

const COLUNAS_INICIO: Coluna[] = [
  { titulo: 'Dias trab.', valor: (t) => String(t.dias_trabalhados) },
  { titulo: 'Trabalhado', valor: (t) => h(t.trabalhado_min) },
];

const COLUNAS_FIM: Coluna[] = [
  { titulo: 'Noturno', valor: (t) => h(t.noturno_min) },
  { titulo: 'Faltas', valor: (t) => (t.faltas_dias ? `${t.faltas_dias}d · ${formatMinutos(t.faltas_min)}` : '—'), destaque: (t) => (t.faltas_dias ? 'text-rose-600 font-semibold' : '') },
  { titulo: 'Atrasos/saídas', valor: (t) => h(t.atraso_min + t.saida_antecipada_min), destaque: (t) => (t.atraso_min + t.saida_antecipada_min ? 'text-accent-700' : '') },
  { titulo: 'Desconto', valor: (t) => h(t.desconto_min) },
  { titulo: 'DSR', valor: (t) => (t.dsr_perdidos ? String(t.dsr_perdidos) : '—') },
  { titulo: 'BH período', valor: (t) => (t.bh_periodo_min ? formatMinutos(t.bh_periodo_min, true) : '—') },
  { titulo: 'BH saldo', valor: (t) => formatMinutos(t.bh_saldo_min, true), destaque: (t) => (t.bh_saldo_min < 0 ? 'text-accent-700' : 'text-primary-700') },
];

export default function TotaisPeriodo() {
  const toast = useToast();
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => competencia(-1));
  const [filtros, setFiltros] = useState({ colaborador: '', departamento: '' });
  const [dados, setDados] = useState<TotaisPeriodoT | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [config, setConfig] = useState(false);
  const [eventos, setEventos] = useState<EventoFolha[]>([]);
  const [salvando, setSalvando] = useState(false);
  const [formato, setFormato] = useState<FormatoHoras>('decimal');
  const [layout, setLayout] = useState<LayoutArquivo>('csv');

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      const d = await api<TotaisPeriodoT>('api_totais_periodo', {
        p_ini: periodo.ini,
        p_fim: periodo.fim,
        p_colaborador: filtros.colaborador || null,
        p_departamento: filtros.departamento || null,
      });
      setDados(d);
      setEventos(d.eventos);
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  // Fechar sem salvar descarta o que foi digitado (o arquivo usa só os códigos salvos)
  const fecharConfig = () => {
    setConfig(false);
    if (dados) setEventos(dados.eventos);
  };

  const salvarEventos = async () => {
    setSalvando(true);
    try {
      await api('api_eventos_folha_salvar', { p_eventos: eventos });
      setDados((d) => (d ? { ...d, eventos } : d));
      toast('Códigos dos eventos salvos.');
      setConfig(false);
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao salvar.', 'erro');
    } finally {
      setSalvando(false);
    }
  };

  const exportarFolha = () => {
    if (!dados) return;
    const semCodigo = dados.eventos.filter((e) => e.ativo && !e.codigo);
    if (dados.eventos.every((e) => !e.ativo || !e.codigo)) {
      toast('Cadastre o código de ao menos um evento da folha.', 'erro');
      setConfig(true);
      return;
    }
    const { conteudo, linhas } = gerarArquivoFolha(dados.colaboradores, dados.eventos, formato, layout);
    baixarArquivo(`folha_${periodo.ini}_${periodo.fim}.${layout}`, conteudo, layout === 'csv' ? 'text/csv' : 'text/plain');
    toast(`Arquivo gerado com ${linhas} lançamento(s).${semCodigo.length ? ` ${semCodigo.length} evento(s) sem código ficaram de fora.` : ''}`);
  };

  const exportarPlanilha = () => {
    if (!dados) return;
    const cab = ['Matrícula', 'Nome', 'Departamento', ...COLUNAS.map((c) => c.titulo)];
    const linhas = dados.colaboradores.map((t) => [t.matricula, t.nome, t.departamento ?? '', ...COLUNAS.map((c) => c.valor(t))]);
    baixarArquivo(`totais_${periodo.ini}_${periodo.fim}.csv`, [cab, ...linhas].map((l) => l.join(';')).join('\r\n'), 'text/csv');
  };

  const soma = (f: (t: TotaisColaborador) => number) => dados?.colaboradores.reduce((s, t) => s + f(t), 0) ?? 0;
  const percentuais = [...new Set((dados?.colaboradores ?? []).flatMap((t) => (t.he ?? []).map((x) => x.percentual)))].sort((a, b) => a - b);
  const COLUNAS = colunas(percentuais);
  const resumoHe = percentuais.map((p) => `${textoPercentual(p)}: ${formatMinutos(soma((t) => heDe(t, p)))}`).join(' · ');
  const inconsistentes = dados?.colaboradores.filter((t) => t.inconsistencias > 0).length ?? 0;

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Totais e exportação para a folha</h2>
          <p className="mt-1 text-sm text-slate-500">
            Horas extras, adicional noturno, faltas, atrasos e DSR do período, prontos para o arquivo de movimento da folha de pagamento.
          </p>
        </div>
        {dados && (
          <div className="flex shrink-0 flex-wrap gap-2">
            <Button variant="secondary" onClick={() => setConfig(true)}>
              <Settings2 className="h-4 w-4" /> Eventos da folha
            </Button>
            <Button variant="secondary" onClick={exportarPlanilha}>
              <FileSpreadsheet className="h-4 w-4" /> Planilha
            </Button>
          </div>
        )}
      </div>

      <section className="card p-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[180px_180px_1fr_1fr_auto] lg:items-end">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="Departamento">
            <select className="input" value={filtros.departamento} onChange={(e) => setFiltros({ departamento: e.target.value, colaborador: '' })}>
              <option value="">Todos</option>
              {aux?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
            </select>
          </Field>
          <Field label="Colaborador">
            <select className="input" value={filtros.colaborador} onChange={(e) => setFiltros((f) => ({ ...f, colaborador: e.target.value }))}>
              <option value="">Todos</option>
              {aux?.colaboradores
                .filter((c) => !filtros.departamento || c.departamento_id === filtros.departamento)
                .map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
            </select>
          </Field>
          <Button onClick={consultar} loading={carregando}>
            <Search className="h-4 w-4" /> Apurar
          </Button>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {!dados ? (
        <div className="card">
          <EmptyState icon={FileSpreadsheet} titulo="Escolha a competência e clique em Apurar"
            descricao="Os dias até ontem entram na apuração. Jornadas com banco de horas mandam o saldo para o banco, não para a folha." />
        </div>
      ) : (
        <>
          <div className="grid gap-4 sm:grid-cols-3 xl:grid-cols-5">
            {[
              ['Horas extras', formatMinutos(soma((t) => t.he_min ?? 0)), resumoHe],
              ['Adicional noturno', formatMinutos(soma((t) => t.noturno_min))],
              ['Faltas', `${soma((t) => t.faltas_dias)} dia(s)`],
              ['Atrasos e saídas', formatMinutos(soma((t) => t.atraso_min + t.saida_antecipada_min))],
              ['DSR descontados', String(soma((t) => t.dsr_perdidos))],
            ].map(([t, v, extra]) => (
              <div key={t} className="card p-4">
                <p className="text-xs text-slate-500">{t}</p>
                <p className="mt-1 text-xl font-semibold tabular-nums text-slate-900">{v}</p>
                {extra && <p className="mt-0.5 text-[11px] tabular-nums text-slate-400">{extra}</p>}
              </div>
            ))}
          </div>

          {inconsistentes > 0 && (
            <div className="flex items-center gap-3 rounded-2xl bg-accent-50 p-4 text-sm text-accent-700 ring-1 ring-accent-200">
              <AlertTriangle className="h-4 w-4 shrink-0" />
              {inconsistentes} colaborador(es) com marcação incompleta no período: o previsto dos turnos que não fecharam vira débito até as batidas serem tratadas.
            </div>
          )}

          <div className="card overflow-x-auto">
            <table className="w-full min-w-[1100px] text-sm">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-5 py-2.5 font-medium">Colaborador</th>
                  {COLUNAS.map((c) => <th key={c.titulo} className="px-3 py-2.5 text-right font-medium">{c.titulo}</th>)}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {dados.colaboradores.map((t) => (
                  <tr key={t.id} className="hover:bg-primary-50/30">
                    <td className="px-5 py-2.5">
                      <p className="flex items-center gap-1.5 font-medium text-slate-800">
                        {t.nome}
                        {t.inconsistencias > 0 && (
                          <span title={`${t.inconsistencias} dia(s) com marcação ímpar`}><AlertTriangle className="h-3.5 w-3.5 text-accent-600" /></span>
                        )}
                      </p>
                      <p className="text-xs text-slate-400">Mat. {t.matricula}{t.jornada && ` · ${t.jornada}`}</p>
                    </td>
                    {COLUNAS.map((c) => (
                      <td key={c.titulo} className={clsx('whitespace-nowrap px-3 py-2.5 text-right tabular-nums text-slate-600', c.destaque?.(t))}>
                        {c.valor(t)}
                      </td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <section className="card flex flex-col gap-4 p-5 lg:flex-row lg:items-end lg:justify-between">
            <div>
              <h3 className="text-[15px] font-semibold text-slate-900">Arquivo para a folha de pagamento</h3>
              <p className="mt-0.5 text-xs text-slate-500">
                Apurado até {formatData(dados.periodo.apurado_ate, { day: '2-digit', month: '2-digit', year: 'numeric' })}. Uma linha por colaborador e evento com quantidade.
              </p>
            </div>
            <div className="flex flex-wrap items-end gap-3">
              <Field label="Layout">
                <select className="input h-9 w-48" value={layout} onChange={(e) => setLayout(e.target.value as LayoutArquivo)}>
                  <option value="csv">CSV (matrícula;evento;quantidade)</option>
                  <option value="txt">TXT posicional (10+5+9)</option>
                </select>
              </Field>
              <Field label="Horas em">
                <select className="input h-9 w-40" value={formato} onChange={(e) => setFormato(e.target.value as FormatoHoras)}>
                  <option value="decimal">Decimal (1,50)</option>
                  <option value="hhmm">Horas:min (01:30)</option>
                </select>
              </Field>
              <Button onClick={exportarFolha} className="h-9">
                <Download className="h-4 w-4" /> Gerar arquivo
              </Button>
            </div>
          </section>
        </>
      )}

      <Modal
        aberto={config}
        onFechar={fecharConfig}
        titulo="Eventos da folha"
        descricao="Informe o código de cada verba no seu sistema de folha. Eventos sem código ou desligados não vão para o arquivo."
        largura="max-w-2xl"
        rodape={
          <>
            <Button variant="secondary" onClick={fecharConfig}>Fechar</Button>
            {dados?.pode_editar && (
              <Button onClick={salvarEventos} loading={salvando}>
                <Save className="h-4 w-4" /> Salvar códigos
              </Button>
            )}
          </>
        }
      >
        <table className="w-full text-sm">
          <thead>
            <tr className="text-left text-xs text-slate-400">
              <th className="pb-2 font-medium">Evento</th>
              <th className="pb-2 font-medium">Unidade</th>
              <th className="pb-2 font-medium">Código na folha</th>
              <th className="pb-2 text-center font-medium">Exportar</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {eventos.map((ev, i) => (
              <tr key={ev.chave}>
                <td className="py-2 pr-3 text-slate-700">{ev.descricao}</td>
                <td className="py-2 pr-3 text-xs text-slate-500">{ev.unidade}</td>
                <td className="py-2 pr-3">
                  <input className="input h-9 w-28 tabular-nums" value={ev.codigo ?? ''} disabled={!dados?.pode_editar}
                    onChange={(e) => setEventos((l) => l.map((x, j) => (j === i ? { ...x, codigo: e.target.value } : x)))} />
                </td>
                <td className="py-2 text-center">
                  <input type="checkbox" className="h-4 w-4 accent-primary-700" checked={ev.ativo} disabled={!dados?.pode_editar}
                    onChange={(e) => setEventos((l) => l.map((x, j) => (j === i ? { ...x, ativo: e.target.checked } : x)))} />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Modal>
    </div>
  );
}
