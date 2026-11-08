import clsx from 'clsx';
import { AlertTriangle, CalendarRange, Lock, Plus, RotateCcw, Search, X } from 'lucide-react';
import { type ReactNode, useCallback, useEffect, useMemo, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, parseISODate, toISODate } from '@/lib/format';
import { useFiltrosAux } from '@/lib/hooks';
import { api } from '@/lib/supabase';
import type { EscalaColaborador, EscalaDia, EscalasGrade, FiltrosAux, HorarioDia, TipoEscala } from '@/lib/types';

/** Chave de uma célula da grade: colaborador + data */
const chave = (colaborador: string, data: string) => `${colaborador}|${data}`;

function horarioCurto(h: HorarioDia) {
  if (!h.entrada || !h.saida) return '';
  return h.saida_intervalo ? `${h.entrada}–${h.saida_intervalo} ${h.retorno_intervalo}–${h.saida}` : `${h.entrada}–${h.saida}`;
}

function semanaAtual(): { ini: string; fim: string } {
  const hoje = new Date();
  const ini = new Date(hoje);
  ini.setDate(hoje.getDate() - hoje.getDay()); // domingo
  const fim = new Date(ini);
  fim.setDate(ini.getDate() + 13); // duas semanas
  return { ini: toISODate(ini), fim: toISODate(fim) };
}

function datasEntre(ini: string, fim: string, diasSemana: number[]): string[] {
  const r: string[] = [];
  for (let d = parseISODate(ini); toISODate(d) <= fim && r.length <= 366; d.setDate(d.getDate() + 1)) {
    if (diasSemana.includes(d.getDay())) r.push(toISODate(d));
  }
  return r;
}

const DIAS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

/** Agrupa as células por conjunto de datas: cada grupo vira uma chamada (colaboradores × datas). */
function agrupar(celulas: { colaborador: string; data: string }[]) {
  const porColab = new Map<string, string[]>();
  for (const c of celulas) porColab.set(c.colaborador, [...(porColab.get(c.colaborador) ?? []), c.data]);
  const grupos = new Map<string, { colaboradores: string[]; datas: string[] }>();
  for (const [colab, datas] of porColab) {
    const k = [...datas].sort().join(',');
    const g = grupos.get(k) ?? { colaboradores: [], datas: [...datas].sort() };
    g.colaboradores.push(colab);
    grupos.set(k, g);
  }
  return [...grupos.values()];
}

interface FormEscala extends HorarioDia {
  tipo: TipoEscala;
  observacao: string;
  colaboradores: string[];
  ini: string;
  fim: string;
  diasSemana: number[];
}

function EscalaModal({
  aberto,
  celulas,
  sugestao,
  aux,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  /** Células selecionadas na grade; vazio = lançamento por período */
  celulas: { colaborador: string; data: string }[];
  sugestao: HorarioDia;
  aux: FiltrosAux | null;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const hoje = toISODate(new Date());
  const [form, setForm] = useState<FormEscala>(() => ({
    tipo: 'trabalho', observacao: '', colaboradores: [], ini: hoje, fim: hoje, diasSemana: [0, 1, 2, 3, 4, 5, 6], ...sugestao,
  }));
  const [busca, setBusca] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const porSelecao = celulas.length > 0;

  useEffect(() => {
    if (!aberto) return;
    setErro(null);
    setBusca('');
    setForm({ tipo: 'trabalho', observacao: '', colaboradores: [], ini: hoje, fim: hoje, diasSemana: [0, 1, 2, 3, 4, 5, 6], ...sugestao });
  }, [aberto, sugestao, hoje]);

  const set = <K extends keyof FormEscala>(k: K, v: FormEscala[K]) => setForm((f) => ({ ...f, [k]: v }));
  const visiveis = useMemo(
    () =>
      (aux?.colaboradores ?? []).filter(
        (c) => c.situacao !== 'desligado' && (!busca || `${c.nome} ${c.matricula}`.toLowerCase().includes(busca.toLowerCase())),
      ),
    [aux, busca],
  );
  const selecionados = new Set(form.colaboradores);
  const todos = visiveis.length > 0 && visiveis.every((c) => selecionados.has(c.id));

  const salvar = async () => {
    setErro(null);
    const grupos = porSelecao
      ? agrupar(celulas)
      : [{ colaboradores: form.colaboradores, datas: datasEntre(form.ini, form.fim, form.diasSemana) }];
    if (!porSelecao && grupos[0].datas.length === 0) return setErro('Nenhum dia no período com os dias da semana marcados.');
    setSalvando(true);
    try {
      let qtd = 0;
      for (const g of grupos) {
        const r = await api<{ qtd: number }>('api_escala_salvar', {
          p_dados: {
            colaboradores: g.colaboradores,
            datas: g.datas,
            tipo: form.tipo,
            entrada: form.entrada,
            saida_intervalo: form.saida_intervalo,
            retorno_intervalo: form.retorno_intervalo,
            saida: form.saida,
            observacao: form.observacao,
          },
        });
        qtd += r.qtd;
      }
      toast(`Escala lançada em ${qtd} dia(s).`);
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const hora = (k: keyof HorarioDia, rotulo: string, obrigatorio = false) => (
    <Field label={rotulo} obrigatorio={obrigatorio}>
      <input type="time" className="input" value={form[k] ?? ''} onChange={(e) => set(k, e.target.value || null)} />
    </Field>
  );

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura={porSelecao ? 'max-w-lg' : 'max-w-3xl'}
      titulo="Lançar escala"
      descricao={
        porSelecao
          ? `${celulas.length} dia(s) selecionado(s) na grade. A escala substitui o padrão da jornada nesses dias.`
          : 'A escala substitui o padrão da jornada nos dias escolhidos.'
      }
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button onClick={salvar} loading={salvando}>Lançar escala</Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className={clsx('grid gap-6', !porSelecao && 'lg:grid-cols-[1fr_1.1fr]')}>
        {!porSelecao && (
          <section>
            <div className="mb-2 flex items-center justify-between">
              <span className="label mb-0">Colaboradores <span className="text-accent-600">*</span></span>
              <span className="text-xs text-slate-500">{form.colaboradores.length} selecionado(s)</span>
            </div>
            <input className="input mb-2 h-9" placeholder="Buscar…" value={busca} onChange={(e) => setBusca(e.target.value)} />
            <div className="max-h-72 overflow-y-auto rounded-xl ring-1 ring-slate-200">
              <label className="flex cursor-pointer items-center gap-3 border-b border-slate-100 bg-slate-50 px-3 py-2 text-xs font-medium text-slate-600">
                <input type="checkbox" checked={todos} className="h-4 w-4 accent-primary-700"
                  onChange={() => set('colaboradores', todos
                    ? form.colaboradores.filter((id) => !visiveis.some((c) => c.id === id))
                    : Array.from(new Set([...form.colaboradores, ...visiveis.map((c) => c.id)])))} />
                Selecionar todos ({visiveis.length})
              </label>
              {visiveis.map((c) => (
                <label key={c.id} className="flex cursor-pointer items-center gap-3 px-3 py-2 text-sm hover:bg-slate-50">
                  <input type="checkbox" checked={selecionados.has(c.id)} className="h-4 w-4 accent-primary-700"
                    onChange={() => set('colaboradores', selecionados.has(c.id)
                      ? form.colaboradores.filter((x) => x !== c.id) : [...form.colaboradores, c.id])} />
                  <span className="min-w-0 flex-1 truncate text-slate-700">{c.nome}</span>
                  <span className="text-xs tabular-nums text-slate-400">{c.matricula}</span>
                </label>
              ))}
            </div>
          </section>
        )}

        <section className="space-y-4">
          <Field label="O colaborador neste dia" grupo>
            <div className="grid grid-cols-2 gap-1 rounded-xl bg-slate-100 p-1 text-sm font-medium">
              {(['trabalho', 'folga'] as const).map((t) => (
                <button key={t} type="button" onClick={() => set('tipo', t)}
                  className={clsx('rounded-lg py-2 transition', form.tipo === t ? 'bg-white text-primary-700 shadow-soft' : 'text-slate-500')}>
                  {t === 'trabalho' ? 'Trabalha (previsão)' : 'Folga'}
                </button>
              ))}
            </div>
          </Field>
          <p className="text-xs text-slate-500">
            {form.tipo === 'trabalho'
              ? 'O dia passa a ter previsão normal com estes horários, mesmo que seja folga na jornada ou feriado. Só o que passar da previsão é hora extra.'
              : 'O dia fica sem previsão, mesmo que seja dia de trabalho na jornada: não gera falta, e o que for trabalhado é hora extra.'}
          </p>

          {form.tipo === 'trabalho' && (
            <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
              {hora('entrada', 'Entrada', true)}
              {hora('saida_intervalo', 'Saída interv.')}
              {hora('retorno_intervalo', 'Retorno')}
              {hora('saida', 'Saída', true)}
            </div>
          )}

          {!porSelecao && (
            <>
              <div className="grid grid-cols-2 gap-3">
                <Field label="De" obrigatorio>
                  <input type="date" className="input" value={form.ini}
                    onChange={(e) => setForm((f) => ({ ...f, ini: e.target.value, fim: f.fim < e.target.value ? e.target.value : f.fim }))} />
                </Field>
                <Field label="Até" obrigatorio>
                  <input type="date" className="input" min={form.ini} value={form.fim} onChange={(e) => set('fim', e.target.value)} />
                </Field>
              </div>
              <Field label="Nos dias da semana" grupo>
                <div className="flex flex-wrap gap-1.5">
                  {DIAS.map((d, i) => (
                    <button key={d} type="button"
                      onClick={() => set('diasSemana', form.diasSemana.includes(i) ? form.diasSemana.filter((x) => x !== i) : [...form.diasSemana, i])}
                      className={clsx('rounded-lg px-2.5 py-1 text-xs font-medium ring-1 transition',
                        form.diasSemana.includes(i) ? 'bg-primary-50 text-primary-700 ring-primary-200' : 'text-slate-400 ring-slate-200')}>
                      {d}
                    </button>
                  ))}
                </div>
              </Field>
            </>
          )}

          <Field label="Observação">
            <input className="input" value={form.observacao} placeholder="Ex.: Inventário no feriado"
              onChange={(e) => set('observacao', e.target.value)} />
          </Field>
        </section>
      </div>
    </Modal>
  );
}

function Celula({
  dia,
  feriado,
  fora,
  fechado,
  selecionada,
  onClick,
}: {
  dia: EscalaDia;
  feriado?: string;
  fora: boolean;
  fechado: boolean;
  selecionada: boolean;
  onClick?: () => void;
}) {
  const e = dia.escala;
  let conteudo: ReactNode;
  let cor = '';
  if (fora) {
    conteudo = '';
    cor = 'bg-slate-50';
  } else if (e?.tipo === 'trabalho') {
    conteudo = <span className="whitespace-pre-line">{horarioCurto(e).replace(' ', '\n')}</span>;
    cor = 'bg-emerald-50 text-emerald-800 ring-1 ring-inset ring-emerald-200';
  } else if (e?.tipo === 'folga') {
    conteudo = 'Folga';
    cor = 'bg-amber-50 font-medium text-amber-800 ring-1 ring-inset ring-amber-200';
  } else if (feriado) {
    conteudo = 'Feriado';
    cor = 'text-rose-500';
  } else if (dia.jornada_folga) {
    conteudo = 'Folga';
    cor = 'text-slate-300';
  } else {
    conteudo = <span className="whitespace-pre-line">{horarioCurto(dia).replace(' ', '\n')}</span>;
    cor = 'text-slate-500';
  }
  const titulo = [
    e ? `Escala: ${e.tipo === 'trabalho' ? `trabalho ${horarioCurto(e)}` : 'folga'}${e.observacao ? ` — ${e.observacao}` : ''}${e.usuario ? ` (por ${e.usuario})` : ''}` : null,
    `Jornada: ${dia.jornada_folga ? 'folga' : horarioCurto(dia)}`,
    feriado ? `Feriado: ${feriado}` : null,
    fechado ? 'Período fechado' : null,
  ].filter(Boolean).join('\n');

  return (
    <td className="p-0.5">
      <button
        type="button"
        disabled={!onClick}
        onClick={onClick}
        title={fora ? undefined : titulo}
        data-celula={dia.data}
        className={clsx(
          'relative flex h-11 w-full min-w-[64px] items-center justify-center rounded-lg px-1 text-center text-[10px] leading-tight tabular-nums transition',
          cor,
          onClick && 'hover:ring-2 hover:ring-primary-300',
          selecionada && '!ring-2 !ring-primary-600',
        )}
      >
        {conteudo}
        {fechado && !fora && <Lock className="absolute right-0.5 top-0.5 h-2.5 w-2.5 text-slate-300" />}
      </button>
    </td>
  );
}

export default function Escalas() {
  const { pode } = useAuth();
  const toast = useToast();
  const podeEditar = pode('escalas', 'editar');
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => semanaAtual());
  const [filtros, setFiltros] = useState({ colaborador: '', departamento: '' });
  const [grade, setGrade] = useState<EscalasGrade | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [modal, setModal] = useState<{ aberto: boolean; celulas: { colaborador: string; data: string }[]; sugestao: HorarioDia }>({
    aberto: false, celulas: [], sugestao: { entrada: null, saida_intervalo: null, retorno_intervalo: null, saida: null },
  });
  const [removendo, setRemovendo] = useState(false);

  const consultar = useCallback(async () => {
    setCarregando(true);
    try {
      setErro(null);
      setGrade(
        await api<EscalasGrade>('api_escalas_grade', {
          p_ini: periodo.ini,
          p_fim: periodo.fim,
          p_departamento: filtros.departamento || null,
          p_colaborador: filtros.colaborador || null,
        }),
      );
      setSel(new Set());
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  }, [periodo, filtros]);

  useEffect(() => {
    consultar();
    // Consulta inicial; depois só ao clicar em "Consultar"
  }, []);

  const feriados = useMemo(() => new Map((grade?.feriados ?? []).map((f) => [f.data, f.descricao])), [grade]);
  const datas = grade?.colaboradores[0]?.dias.map((d) => d.data) ?? [];
  const fechado = (data: string) => !!grade?.fechado_ate && data <= grade.fechado_ate;
  const fora = (c: EscalaColaborador, data: string) => data < c.inicio || (!!c.desligamento && data > c.desligamento);

  const celulasSel = useMemo(
    () => [...sel].map((k) => { const [colaborador, data] = k.split('|'); return { colaborador, data }; }),
    [sel],
  );
  const comEscala = celulasSel.filter((c) =>
    grade?.colaboradores.find((x) => x.id === c.colaborador)?.dias.find((d) => d.data === c.data)?.escala);

  const alternar = (c: EscalaColaborador, data: string) =>
    setSel((s) => {
      const n = new Set(s);
      const k = chave(c.id, data);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });

  /** Horário sugerido para a escala: a escala já lançada, o dia da jornada ou o 1º dia de trabalho do colaborador */
  const sugestao = (celulas: { colaborador: string; data: string }[]): HorarioDia => {
    const vazio = { entrada: null, saida_intervalo: null, retorno_intervalo: null, saida: null };
    const c = celulas[0] && grade?.colaboradores.find((x) => x.id === celulas[0].colaborador);
    if (!c) return vazio;
    const d = c.dias.find((x) => x.data === celulas[0].data);
    const base = d?.escala?.tipo === 'trabalho' ? d.escala : d && !d.jornada_folga && d.entrada ? d : c.dias.find((x) => !x.jornada_folga && x.entrada);
    return base ? { entrada: base.entrada, saida_intervalo: base.saida_intervalo, retorno_intervalo: base.retorno_intervalo, saida: base.saida } : vazio;
  };

  const voltarAoPadrao = async () => {
    setRemovendo(true);
    try {
      let qtd = 0;
      for (const g of agrupar(comEscala)) {
        const r = await api<{ qtd: number }>('api_escala_excluir', { p_dados: g });
        qtd += r.qtd;
      }
      toast(`${qtd} dia(s) voltaram ao padrão da jornada.`);
      consultar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao remover.', 'erro');
    } finally {
      setRemovendo(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Escalas</h2>
          <p className="mt-1 max-w-3xl text-sm text-slate-500">
            Lance previsão de trabalho ou folga em dias específicos, fora do padrão da jornada. Um dia com escala de trabalho
            conta previsão normal (mesmo em feriado ou folga) e só o que passar dela é hora extra; um dia com escala de folga
            fica sem previsão.
          </p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={() => setModal({ aberto: true, celulas: [], sugestao: sugestao([]) })}>
            <Plus className="h-4 w-4" /> Lançar por período
          </Button>
        )}
      </div>

      <section className="card p-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
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
          <div className="flex items-end">
            <Button onClick={consultar} loading={carregando} className="h-10 w-full">
              <Search className="h-4 w-4" /> Consultar
            </Button>
          </div>
        </div>
        <div className="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-slate-500">
          <span className="flex items-center gap-1.5"><span className="h-3 w-3 rounded bg-emerald-100 ring-1 ring-emerald-300" /> Escala de trabalho</span>
          <span className="flex items-center gap-1.5"><span className="h-3 w-3 rounded bg-amber-100 ring-1 ring-amber-300" /> Escala de folga</span>
          <span className="flex items-center gap-1.5"><span className="font-medium text-slate-500">08:00–17:00</span> horário da jornada</span>
          <span className="flex items-center gap-1.5"><span className="text-slate-300">Folga</span> folga da jornada</span>
          <span className="flex items-center gap-1.5"><span className="text-rose-500">Feriado</span></span>
          {podeEditar && <span className="text-slate-400">· Clique nos dias para selecionar e lançar a escala.</span>}
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {podeEditar && sel.size > 0 && (
        <div className="sticky top-2 z-20 flex flex-wrap items-center gap-3 rounded-2xl bg-primary-900 px-4 py-3 text-sm text-white shadow-lg">
          <span className="font-medium">{sel.size} dia(s) selecionado(s)</span>
          <div className="ml-auto flex flex-wrap gap-2">
            <Button variant="accent" className="h-9" onClick={() => setModal({ aberto: true, celulas: celulasSel, sugestao: sugestao(celulasSel) })}>
              <CalendarRange className="h-4 w-4" /> Lançar escala
            </Button>
            {comEscala.length > 0 && (
              <Button variant="secondary" className="h-9" loading={removendo} onClick={voltarAoPadrao}>
                <RotateCcw className="h-4 w-4" /> Voltar ao padrão ({comEscala.length})
              </Button>
            )}
            <Button variant="ghost" className="h-9 text-white hover:bg-white/10" onClick={() => setSel(new Set())}>
              <X className="h-4 w-4" /> Limpar
            </Button>
          </div>
        </div>
      )}

      {grade === null ? (
        <div className="card h-64 animate-pulse" />
      ) : grade.colaboradores.length === 0 ? (
        <div className="card">
          <EmptyState icon={CalendarRange} titulo="Nenhum colaborador" descricao="Ajuste os filtros para ver a grade de escalas." />
        </div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full border-separate border-spacing-0 text-sm">
            <thead>
              <tr className="text-xs text-slate-400">
                <th className="sticky left-0 z-10 min-w-[200px] bg-white px-4 py-2 text-left font-medium">Colaborador</th>
                {datas.map((d) => {
                  const dt = parseISODate(d);
                  return (
                    <th key={d} title={feriados.get(d)}
                      className={clsx('px-0.5 py-2 text-center font-medium', feriados.has(d) ? 'text-rose-500' : [0, 6].includes(dt.getDay()) && 'text-slate-500')}>
                      <span className="block text-[10px] uppercase">{DIAS[dt.getDay()]}</span>
                      <span className="tabular-nums">{formatData(d)}</span>
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {grade.colaboradores.map((c) => (
                <tr key={c.id} className="border-t border-slate-100">
                  <td className="sticky left-0 z-10 bg-white px-4 py-1.5">
                    <p className="truncate font-medium text-slate-800">{c.nome}</p>
                    <p className="truncate text-xs text-slate-400">{c.jornada ?? 'Sem jornada'}{c.departamento && ` · ${c.departamento}`}</p>
                  </td>
                  {c.dias.map((d) => {
                    const f = fora(c, d.data);
                    const fe = fechado(d.data);
                    return (
                      <Celula
                        key={d.data}
                        dia={d}
                        feriado={feriados.get(d.data)}
                        fora={f}
                        fechado={fe}
                        selecionada={sel.has(chave(c.id, d.data))}
                        onClick={podeEditar && !f && !fe ? () => alternar(c, d.data) : undefined}
                      />
                    );
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <EscalaModal
        aberto={modal.aberto}
        celulas={modal.celulas}
        sugestao={modal.sugestao}
        aux={aux}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal((m) => ({ ...m, aberto: false }));
          consultar();
        }}
      />
    </div>
  );
}
