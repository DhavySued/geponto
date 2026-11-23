import clsx from 'clsx';
import { AlertTriangle, CalendarRange, LayoutGrid, List, Lock, Pencil, Plus, Search, Trash2, X } from 'lucide-react';
import { type ReactNode, useCallback, useEffect, useMemo, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, parseISODate, toISODate } from '@/lib/format';
import { useFiltrosAux, opcoesColaboradores, paramColaboradores } from '@/lib/hooks';
import { api } from '@/lib/api';
import type { EscalaColaborador, EscalaDia, EscalaLancamento, EscalasGrade, EscalasLancamentos, FiltrosAux, HorarioDia, HorarioEscalaDia, TipoEscala } from '@/lib/types';

/** Período máximo de uma escala (dias corridos) */
const MAX_DIAS = 30;
const DIAS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];
const TODOS_DIAS = [0, 1, 2, 3, 4, 5, 6];
const HORARIO_VAZIO: HorarioDia = { entrada: null, saida_intervalo: null, retorno_intervalo: null, saida: null };

const chave = (colaborador: string, data: string) => `${colaborador}|${data}`;
const dataBR = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });
const dataHoraBR = (s: string) =>
  new Date(s).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const diasEntre = (ini: string, fim: string) => Math.round((parseISODate(fim).getTime() - parseISODate(ini).getTime()) / 86_400_000) + 1;

function horarioCurto(h: HorarioDia) {
  if (!h.entrada || !h.saida) return '';
  return h.saida_intervalo ? `${h.entrada}–${h.saida_intervalo} ${h.retorno_intervalo}–${h.saida}` : `${h.entrada}–${h.saida}`;
}

function textoDias(dias: number[]) {
  if (dias.length === 7) return 'Todos os dias';
  if (dias.join() === '1,2,3,4,5') return 'Segunda a sexta';
  if (dias.join() === '0,6') return 'Fins de semana';
  return dias.map((d) => DIAS[d]).join(', ');
}

function periodoInicial(): { ini: string; fim: string } {
  const hoje = new Date();
  const ini = new Date(hoje);
  ini.setDate(hoje.getDate() - hoje.getDay()); // domingo
  const fim = new Date(ini);
  fim.setDate(ini.getDate() + 13); // duas semanas
  return { ini: toISODate(ini), fim: toISODate(fim) };
}

interface FormEscala extends HorarioDia {
  nome: string;
  tipo: TipoEscala;
  observacao: string;
  colaboradores: string[];
  ini: string;
  fim: string;
  diasSemana: number[];
  /** Dias com horário próprio (AAAA-MM-DD) */
  horarios: Record<string, HorarioEscalaDia>;
}

/** Datas do período que caem nos dias da semana marcados */
function datasDaEscala(ini: string, fim: string, diasSemana: number[]): string[] {
  if (!ini || !fim || fim < ini) return [];
  const out: string[] = [];
  for (let d = parseISODate(ini); toISODate(d) <= fim && out.length <= 62; d.setDate(d.getDate() + 1)) {
    if (diasSemana.includes(d.getDay())) out.push(toISODate(d));
  }
  return out;
}

/** Valores para abrir uma escala nova já preenchida (ex.: dias selecionados na grade) */
type Prefill = Partial<Pick<FormEscala, 'colaboradores' | 'ini' | 'fim' | 'diasSemana'>> & { horario?: HorarioDia };

function formVazio(prefill: Prefill = {}): FormEscala {
  const hoje = toISODate(new Date());
  return {
    nome: '', tipo: 'trabalho', observacao: '', colaboradores: prefill.colaboradores ?? [],
    ini: prefill.ini ?? hoje, fim: prefill.fim ?? hoje, diasSemana: prefill.diasSemana ?? TODOS_DIAS,
    horarios: {},
    ...(prefill.horario ?? HORARIO_VAZIO),
  };
}

function EscalaModal({
  aberto,
  escala,
  prefill,
  aux,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  /** Escala existente (alteração) ou null (nova) */
  escala: EscalaLancamento | null;
  prefill: Prefill;
  aux: FiltrosAux | null;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<FormEscala>(() => formVazio());
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setErro(null);
    setForm(
      escala
        ? {
            nome: escala.nome, tipo: escala.tipo, observacao: escala.observacao ?? '',
            colaboradores: escala.colaboradores.map((c) => c.id), ini: escala.data_inicio, fim: escala.data_fim,
            diasSemana: escala.dias_semana, entrada: escala.entrada, saida_intervalo: escala.saida_intervalo,
            retorno_intervalo: escala.retorno_intervalo, saida: escala.saida, horarios: escala.horarios ?? {},
          }
        : formVazio(prefill),
    );
  }, [aberto, escala, prefill]);

  const set = <K extends keyof FormEscala>(k: K, v: FormEscala[K]) => setForm((f) => ({ ...f, [k]: v }));
  const qtdDias = form.ini && form.fim && form.fim >= form.ini ? diasEntre(form.ini, form.fim) : 0;
  const longo = qtdDias > MAX_DIAS;
  const opcoes = useMemo(
    () => opcoesColaboradores((aux?.colaboradores ?? []).filter((c) => c.situacao !== 'desligado' || form.colaboradores.includes(c.id))),
    [aux, form.colaboradores],
  );
  const somenteLeitura = !!escala?.fechado;
  const datas = useMemo(() => datasDaEscala(form.ini, form.fim, form.diasSemana), [form.ini, form.fim, form.diasSemana]);
  const qtdPersonalizados = datas.filter((d) => form.horarios[d]).length;
  const [porDia, setPorDia] = useState(false);
  useEffect(() => { if (aberto) setPorDia(!!escala && Object.keys(escala.horarios ?? {}).length > 0); }, [aberto, escala]);
  const padrao = (): HorarioEscalaDia => ({
    tipo: form.tipo, entrada: form.entrada, saida_intervalo: form.saida_intervalo, retorno_intervalo: form.retorno_intervalo, saida: form.saida,
  });
  const doDia = (d: string): HorarioEscalaDia => form.horarios[d] ?? padrao();
  const mudarDia = (d: string, patch: Partial<HorarioEscalaDia>) =>
    setForm((f) => ({ ...f, horarios: { ...f.horarios, [d]: { ...(f.horarios[d] ?? padrao()), ...patch } } }));
  const restaurarDia = (d: string) =>
    setForm((f) => { const h = { ...f.horarios }; delete h[d]; return { ...f, horarios: h }; });

  const salvar = async () => {
    setErro(null);
    if (!form.nome.trim()) return setErro('Dê um nome à escala.');
    if (longo) return setErro(`A escala pode ter no máximo ${MAX_DIAS} dias.`);
    setSalvando(true);
    try {
      const r = await api<{ id: string; dias: number }>('api_escala_lancamento_salvar', {
        p_dados: {
          id: escala?.id ?? null,
          nome: form.nome,
          tipo: form.tipo,
          data_inicio: form.ini,
          data_fim: form.fim,
          dias_semana: form.diasSemana,
          colaboradores: form.colaboradores,
          entrada: form.tipo === 'trabalho' ? form.entrada : null,
          saida_intervalo: form.tipo === 'trabalho' ? form.saida_intervalo : null,
          retorno_intervalo: form.tipo === 'trabalho' ? form.retorno_intervalo : null,
          saida: form.tipo === 'trabalho' ? form.saida : null,
          observacao: form.observacao,
          // Só os dias do período atual
          horarios: Object.fromEntries(datas.filter((d) => form.horarios[d]).map((d) => [d, form.horarios[d]])),
        },
      });
      toast(escala ? `Escala alterada (${r.dias} dia(s)).` : `Escala "${form.nome.trim()}" lançada em ${r.dias} dia(s).`);
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const hora = (k: keyof HorarioDia, rotulo: string, obrigatorio = false) => (
    <Field label={rotulo} obrigatorio={obrigatorio}>
      <input type="time" className="input" disabled={somenteLeitura} value={form[k] ?? ''} onChange={(e) => set(k, e.target.value || null)} />
    </Field>
  );

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-3xl"
      titulo={escala ? 'Escala' : 'Nova escala'}
      descricao="A escala substitui o padrão da jornada nos dias escolhidos e fica registrada para consultar e alterar depois."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>{somenteLeitura ? 'Fechar' : 'Cancelar'}</Button>
          {!somenteLeitura && <Button onClick={salvar} loading={salvando}>{escala ? 'Salvar alterações' : 'Lançar escala'}</Button>}
        </>
      }
    >
      <div className="space-y-5">
        {somenteLeitura && (
          <div className="flex items-center gap-2 rounded-xl bg-slate-50 p-3 text-sm text-slate-600 ring-1 ring-slate-200">
            <Lock className="h-4 w-4 shrink-0" /> Esta escala alcança um período fechado: reabra o período para alterá-la.
          </div>
        )}
        <AlertaErro mensagem={erro} />

        <Field label="Nome da escala" obrigatorio dica="Para reconhecer a escala na lista. Ex.: Plantão do feriado de novembro, Inventário de dezembro.">
          <input className="input" value={form.nome} maxLength={120} disabled={somenteLeitura} autoFocus={!escala}
            onChange={(e) => set('nome', e.target.value)} />
        </Field>

        <Field label="Colaboradores" obrigatorio>
          <ComboboxChips opcoes={opcoes} valor={form.colaboradores} onChange={(v) => set('colaboradores', v)} disabled={somenteLeitura}
            placeholder="Buscar por nome ou matrícula…" rotuloTodos="Todos" maxChips={6} />
        </Field>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="De" obrigatorio>
            <input type="date" className="input" value={form.ini} disabled={somenteLeitura}
              onChange={(e) => e.target.value && setForm((f) => ({ ...f, ini: e.target.value, fim: f.fim < e.target.value ? e.target.value : f.fim }))} />
          </Field>
          <Field label="Até" obrigatorio dica={<span className={clsx(longo && 'font-medium text-rose-600')}>{qtdDias} dia(s) · máximo de {MAX_DIAS}</span>}>
            <input type="date" className="input" min={form.ini} value={form.fim} disabled={somenteLeitura}
              onChange={(e) => e.target.value && set('fim', e.target.value)} />
          </Field>
        </div>

        <Field label="Nos dias da semana" grupo>
          <div className="flex flex-wrap gap-1.5">
            {DIAS.map((d, i) => (
              <button key={d} type="button" disabled={somenteLeitura}
                onClick={() => set('diasSemana', form.diasSemana.includes(i) ? form.diasSemana.filter((x) => x !== i) : [...form.diasSemana, i].sort())}
                className={clsx('rounded-lg px-2.5 py-1 text-xs font-medium ring-1 transition',
                  form.diasSemana.includes(i) ? 'bg-primary-50 text-primary-700 ring-primary-200' : 'text-slate-400 ring-slate-200')}>
                {d}
              </button>
            ))}
          </div>
        </Field>

        <Field label="O colaborador nesses dias" grupo>
          <div className="grid grid-cols-2 gap-1 rounded-xl bg-slate-100 p-1 text-sm font-medium">
            {(['trabalho', 'folga'] as const).map((t) => (
              <button key={t} type="button" disabled={somenteLeitura} onClick={() => set('tipo', t)}
                className={clsx('rounded-lg py-2 transition', form.tipo === t ? 'bg-white text-primary-700 shadow-soft' : 'text-slate-500')}>
                {t === 'trabalho' ? 'Trabalha' : 'Folga'}
              </button>
            ))}
          </div>
        </Field>
        <p className="-mt-2 text-xs text-slate-500">
          {form.tipo === 'trabalho'
            ? 'O dia passa a ter previsão com estes horários, mesmo que seja folga na jornada. No feriado, a previsão vale (faltar é falta) e todo o tempo trabalhado é hora extra com o percentual de Feriado.'
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

        {datas.length > 0 && (
          <div className="rounded-xl ring-1 ring-slate-200/80">
            <button type="button" onClick={() => setPorDia((v) => !v)}
              className="flex w-full items-center justify-between gap-3 px-4 py-3 text-left">
              <span>
                <span className="block text-sm font-medium text-slate-800">Horário de cada dia</span>
                <span className="block text-xs text-slate-500">
                  {qtdPersonalizados
                    ? `${qtdPersonalizados} de ${datas.length} dia(s) com horário próprio; os demais seguem o horário acima.`
                    : 'Todos os dias seguem o horário acima. Abra para mudar o horário (ou dar folga) em dias específicos.'}
                </span>
              </span>
              <span className="text-xs font-medium text-primary-600">{porDia ? 'Recolher' : 'Personalizar'}</span>
            </button>
            {porDia && (
              <div className="max-h-[360px] overflow-y-auto border-t border-slate-100">
                <table className="w-full text-sm">
                  <thead className="sticky top-0 bg-slate-50 text-left text-xs text-slate-400">
                    <tr>
                      <th className="px-3 py-2 font-medium">Dia</th>
                      <th className="px-2 py-2 font-medium">Trabalha</th>
                      <th className="px-2 py-2 font-medium">Entrada</th>
                      <th className="px-2 py-2 font-medium">Saída interv.</th>
                      <th className="px-2 py-2 font-medium">Retorno</th>
                      <th className="px-2 py-2 font-medium">Saída</th>
                      <th className="px-2 py-2" />
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {datas.map((d) => {
                      const h = doDia(d);
                      const proprio = !!form.horarios[d];
                      const campo = (k: keyof HorarioDia) => (
                        <td className="px-1 py-1.5">
                          <input type="time" className="input h-8 px-1.5 text-xs" disabled={somenteLeitura || h.tipo === 'folga'}
                            value={h.tipo === 'folga' ? '' : h[k] ?? ''} onChange={(e) => mudarDia(d, { [k]: e.target.value || null })} />
                        </td>
                      );
                      return (
                        <tr key={d} className={clsx(proprio && 'bg-primary-50/40')}>
                          <td className="whitespace-nowrap px-3 py-1.5 text-xs capitalize text-slate-700">
                            {formatData(d, { weekday: 'short', day: '2-digit', month: '2-digit' })}
                          </td>
                          <td className="px-2 py-1.5">
                            <input type="checkbox" className="h-4 w-4 accent-primary-600" disabled={somenteLeitura} checked={h.tipo === 'trabalho'}
                              onChange={(e) => mudarDia(d, e.target.checked
                                ? { tipo: 'trabalho', entrada: h.entrada ?? form.entrada, saida_intervalo: h.saida_intervalo ?? form.saida_intervalo,
                                    retorno_intervalo: h.retorno_intervalo ?? form.retorno_intervalo, saida: h.saida ?? form.saida }
                                : { tipo: 'folga' })} />
                          </td>
                          {campo('entrada')}
                          {campo('saida_intervalo')}
                          {campo('retorno_intervalo')}
                          {campo('saida')}
                          <td className="px-2 py-1.5 text-right">
                            {proprio && !somenteLeitura && (
                              <button type="button" onClick={() => restaurarDia(d)} className="text-[11px] text-slate-400 hover:text-primary-600"
                                title="Voltar ao horário da escala">padrão</button>
                            )}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        <Field label="Observação">
          <input className="input" value={form.observacao} disabled={somenteLeitura} placeholder="Opcional"
            onChange={(e) => set('observacao', e.target.value)} />
        </Field>

        {escala && (
          <p className="border-t border-slate-100 pt-3 text-xs text-slate-400">
            Lançada{escala.lancado_por ? ` por ${escala.lancado_por}` : ''} em {dataHoraBR(escala.lancado_em)}
            {escala.alterado_em && ` · alterada${escala.alterado_por ? ` por ${escala.alterado_por}` : ''} em ${dataHoraBR(escala.alterado_em)}`}
          </p>
        )}
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
    e ? `Escala "${e.nome ?? 'sem nome'}": ${e.tipo === 'trabalho' ? `trabalho ${horarioCurto(e)}` : 'folga'}${e.usuario ? ` (por ${e.usuario})` : ''}` : null,
    `Jornada: ${dia.jornada_folga ? 'folga' : horarioCurto(dia)}`,
    feriado ? `Feriado: ${feriado}` : null,
    fechado ? 'Período fechado' : null,
    e && onClick ? 'Clique para abrir a escala' : null,
  ].filter(Boolean).join('\n');

  return (
    <td className="p-0.5">
      <button
        type="button"
        disabled={!onClick}
        onClick={onClick}
        title={fora ? undefined : titulo}
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

function LinhaEscala({ e, podeEditar, onAbrir, onExcluir }: { e: EscalaLancamento; podeEditar: boolean; onAbrir: () => void; onExcluir: () => void }) {
  const visiveis = e.colaboradores.slice(0, 4);
  return (
    <li className="flex flex-wrap items-center gap-x-4 gap-y-2 px-5 py-4">
      <button type="button" onClick={onAbrir} className="min-w-0 flex-1 text-left">
        <p className="flex flex-wrap items-center gap-2 font-medium text-slate-800">
          {e.nome}
          {e.tipo === 'trabalho' ? <Badge tone="green">Trabalho</Badge> : <Badge tone="orange">Folga</Badge>}
          {e.fechado && <Badge tone="slate" dot={false}><Lock className="mr-1 inline h-3 w-3" />Período fechado</Badge>}
        </p>
        <p className="mt-0.5 text-sm text-slate-600">
          {e.data_inicio === e.data_fim ? dataBR(e.data_inicio) : `${dataBR(e.data_inicio)} a ${dataBR(e.data_fim)}`}
          {' · '}{textoDias(e.dias_semana)}
          {e.tipo === 'trabalho' && ` · ${horarioCurto(e)}`}
          {' · '}{e.dias} dia(s)
        </p>
        <p className="mt-1 flex flex-wrap items-center gap-1">
          {visiveis.map((c) => (
            <span key={c.id} className="rounded-md bg-slate-100 px-1.5 py-0.5 text-xs text-slate-600">{c.nome}</span>
          ))}
          {e.colaboradores.length > visiveis.length && (
            <span className="text-xs text-slate-400" title={e.colaboradores.slice(4).map((c) => c.nome).join(', ')}>
              +{e.colaboradores.length - visiveis.length}
            </span>
          )}
        </p>
        <p className="mt-1 text-xs text-slate-400">
          Lançada{e.lancado_por ? ` por ${e.lancado_por}` : ''} em {dataHoraBR(e.lancado_em)}
          {e.alterado_em && ` · alterada${e.alterado_por ? ` por ${e.alterado_por}` : ''} em ${dataHoraBR(e.alterado_em)}`}
          {e.observacao && ` · ${e.observacao}`}
        </p>
      </button>
      <div className="flex gap-1">
        <Button variant="ghost" className="h-9" onClick={onAbrir}>
          <Pencil className="h-4 w-4" /> {podeEditar && !e.fechado ? 'Alterar' : 'Ver'}
        </Button>
        {podeEditar && !e.fechado && (
          <Button variant="ghost" className="h-9 text-rose-600 hover:bg-rose-50" onClick={onExcluir}>
            <Trash2 className="h-4 w-4" /> Excluir
          </Button>
        )}
      </div>
    </li>
  );
}

export default function Escalas() {
  const { pode } = useAuth();
  const toast = useToast();
  const podeEditar = pode('escalas', 'editar');
  const { aux, erro: erroAux } = useFiltrosAux();
  const [visao, setVisao] = useState<'lista' | 'grade'>('lista');
  const [periodo, setPeriodo] = useState(() => periodoInicial());
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '', busca: '' });
  const [lista, setLista] = useState<EscalasLancamentos | null>(null);
  const [grade, setGrade] = useState<EscalasGrade | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [sel, setSel] = useState<Set<string>>(new Set());
  const [modal, setModal] = useState<{ aberto: boolean; escala: EscalaLancamento | null; prefill: Prefill }>({ aberto: false, escala: null, prefill: {} });
  const [excluir, setExcluir] = useState<EscalaLancamento | null>(null);
  const [excluindo, setExcluindo] = useState(false);

  // Colaboradores do filtro: os marcados ou, com departamento, todos dele
  const colaboradoresFiltro = useCallback(() => {
    if (filtros.colaboradores.length || !filtros.departamento) return paramColaboradores(filtros.colaboradores);
    const ids = opcoesColaboradores(aux?.colaboradores, filtros).map((c) => c.id);
    // Departamento sem ninguém: lista vazia (uma lista vazia valeria como "todos")
    return ids.length ? ids : ['00000000-0000-0000-0000-000000000000'];
  }, [filtros, aux]);

  const consultar = useCallback(async (qual = visao) => {
    if (periodo.fim < periodo.ini) return setErro('Informe um período válido.');
    setCarregando(true);
    try {
      setErro(null);
      if (qual === 'lista') {
        setLista(await api<EscalasLancamentos>('api_escalas_lancamentos', {
          p_ini: periodo.ini, p_fim: periodo.fim, p_colaboradores: colaboradoresFiltro(), p_busca: filtros.busca || null,
        }));
      } else {
        setGrade(await api<EscalasGrade>('api_escalas_grade', {
          p_ini: periodo.ini, p_fim: periodo.fim, p_departamento: filtros.departamento || null,
          p_colaboradores: paramColaboradores(filtros.colaboradores),
        }));
        setSel(new Set());
      }
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  }, [visao, periodo, filtros, colaboradoresFiltro]);

  useEffect(() => {
    consultar();
    // Consulta ao abrir e ao trocar de visão; os filtros valem ao clicar em "Consultar"
  }, [visao]);

  const abrirEscala = async (id: string) => {
    try {
      const e = await api<EscalaLancamento>('api_escala_lancamento', { p_id: id });
      setModal({ aberto: true, escala: e, prefill: {} });
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao abrir a escala.', 'erro');
    }
  };

  const confirmarExclusao = async () => {
    if (!excluir) return;
    setExcluindo(true);
    try {
      await api('api_escala_lancamento_excluir', { p_id: excluir.id });
      toast(`Escala "${excluir.nome}" excluída. Os dias voltaram ao padrão da jornada.`);
      setExcluir(null);
      consultar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    } finally {
      setExcluindo(false);
    }
  };

  // ----- Grade -----
  const feriados = useMemo(() => new Map((grade?.feriados ?? []).map((f) => [f.data, f.descricao])), [grade]);
  const datas = grade?.colaboradores[0]?.dias.map((d) => d.data) ?? [];
  const fechado = (data: string) => !!grade?.fechado_ate && data <= grade.fechado_ate;
  const fora = (c: EscalaColaborador, data: string) => data < c.inicio || (!!c.desligamento && data > c.desligamento);

  const alternar = (c: EscalaColaborador, data: string) =>
    setSel((s) => {
      const n = new Set(s);
      const k = chave(c.id, data);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });

  /** Escala nova a partir dos dias selecionados na grade */
  const novaComSelecao = () => {
    const cel = [...sel].map((k) => { const [colaborador, data] = k.split('|'); return { colaborador, data }; });
    const ds = cel.map((c) => c.data).sort();
    const c0 = grade?.colaboradores.find((x) => x.id === cel[0]?.colaborador);
    const base = c0?.dias.find((x) => !x.jornada_folga && x.entrada);
    setModal({
      aberto: true,
      escala: null,
      prefill: {
        colaboradores: [...new Set(cel.map((c) => c.colaborador))],
        ini: ds[0],
        fim: ds[ds.length - 1],
        diasSemana: [...new Set(ds.map((d) => parseISODate(d).getDay()))].sort(),
        horario: base ? { entrada: base.entrada, saida_intervalo: base.saida_intervalo, retorno_intervalo: base.retorno_intervalo, saida: base.saida } : HORARIO_VAZIO,
      },
    });
  };

  const abaClasse = (ativa: boolean) =>
    clsx('flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition', ativa ? 'bg-white text-primary-700 shadow-soft' : 'text-slate-500 hover:text-slate-700');

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Escalas</h2>
          <p className="mt-1 max-w-3xl text-sm text-slate-500">
            Previsão de trabalho ou folga fora do padrão da jornada, por períodos de até {MAX_DIAS} dias. Cada escala tem um nome e
            fica registrada para consultar, alterar ou excluir depois.
          </p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={() => setModal({ aberto: true, escala: null, prefill: {} })}>
            <Plus className="h-4 w-4" /> Nova escala
          </Button>
        )}
      </div>

      <section className="card p-5">
        <div className="mb-4 inline-flex rounded-xl bg-slate-100 p-1">
          <button type="button" className={abaClasse(visao === 'lista')} onClick={() => setVisao('lista')}>
            <List className="h-4 w-4" /> Escalas lançadas
          </button>
          <button type="button" className={abaClasse(visao === 'grade')} onClick={() => setVisao('grade')}>
            <LayoutGrid className="h-4 w-4" /> Grade por dia
          </button>
        </div>
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-6">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
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
          <Field label="Colaborador" className="lg:col-span-2">
            <ComboboxChips opcoes={opcoesColaboradores(aux?.colaboradores, filtros)} valor={filtros.colaboradores}
              onChange={(v) => setFiltros((f) => ({ ...f, colaboradores: v }))} rotuloTodos="Todos os colaboradores" />
          </Field>
          <div className="flex items-end">
            <Button onClick={() => consultar()} loading={carregando} className="h-10 w-full">
              <Search className="h-4 w-4" /> Consultar
            </Button>
          </div>
          {visao === 'lista' && (
            <Field label="Nome da escala" className="sm:col-span-2 lg:col-span-3">
              <input className="input" value={filtros.busca} placeholder="Buscar pelo nome ou observação…"
                onChange={(e) => setFiltros((f) => ({ ...f, busca: e.target.value }))}
                onKeyDown={(e) => e.key === 'Enter' && consultar()} />
            </Field>
          )}
        </div>
        {visao === 'grade' && (
          <div className="mt-4 flex flex-wrap items-center gap-x-4 gap-y-2 text-xs text-slate-500">
            <span className="flex items-center gap-1.5"><span className="h-3 w-3 rounded bg-emerald-100 ring-1 ring-emerald-300" /> Escala de trabalho</span>
            <span className="flex items-center gap-1.5"><span className="h-3 w-3 rounded bg-amber-100 ring-1 ring-amber-300" /> Escala de folga</span>
            <span className="flex items-center gap-1.5"><span className="font-medium text-slate-500">08:00–17:00</span> horário da jornada</span>
            <span className="flex items-center gap-1.5"><span className="text-slate-300">Folga</span> folga da jornada</span>
            <span className="flex items-center gap-1.5"><span className="text-rose-500">Feriado</span></span>
            {podeEditar && <span className="text-slate-400">· Clique numa escala para abri-la, ou selecione dias livres para lançar uma nova.</span>}
          </div>
        )}
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {visao === 'lista' ? (
        lista === null ? (
          <div className="card h-64 animate-pulse" />
        ) : lista.escalas.length === 0 ? (
          <div className="card">
            <EmptyState icon={CalendarRange} titulo="Nenhuma escala no período"
              descricao="Ajuste o período ou os filtros, ou lance uma nova escala." />
          </div>
        ) : (
          <div className="card overflow-hidden">
            <p className="border-b border-slate-100 px-5 py-3 text-xs text-slate-500">{lista.escalas.length} escala(s) no período</p>
            <ul className="divide-y divide-slate-100">
              {lista.escalas.map((e) => (
                <LinhaEscala key={e.id} e={e} podeEditar={podeEditar}
                  onAbrir={() => setModal({ aberto: true, escala: e, prefill: {} })} onExcluir={() => setExcluir(e)} />
              ))}
            </ul>
          </div>
        )
      ) : (
        <>
          {podeEditar && sel.size > 0 && (
            <div className="sticky top-2 z-20 flex flex-wrap items-center gap-3 rounded-2xl bg-primary-900 px-4 py-3 text-sm text-white shadow-lg">
              <span className="font-medium">{sel.size} dia(s) selecionado(s)</span>
              <div className="ml-auto flex flex-wrap gap-2">
                <Button variant="accent" className="h-9" onClick={novaComSelecao}>
                  <CalendarRange className="h-4 w-4" /> Nova escala com a seleção
                </Button>
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
                        const lanc = d.escala?.lancamento_id;
                        return (
                          <Celula
                            key={d.data}
                            dia={d}
                            feriado={feriados.get(d.data)}
                            fora={f}
                            fechado={fe}
                            selecionada={sel.has(chave(c.id, d.data))}
                            onClick={f ? undefined : lanc ? () => abrirEscala(lanc) : podeEditar && !fe ? () => alternar(c, d.data) : undefined}
                          />
                        );
                      })}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}

      <EscalaModal
        aberto={modal.aberto}
        escala={modal.escala}
        prefill={modal.prefill}
        aux={aux}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal((m) => ({ ...m, aberto: false }));
          consultar();
        }}
      />

      <Modal
        aberto={!!excluir}
        onFechar={() => setExcluir(null)}
        titulo="Excluir escala?"
        descricao={excluir ? `"${excluir.nome}": ${excluir.dias} dia(s) voltam ao padrão da jornada. O registro da escala é apagado.` : undefined}
        rodape={
          <>
            <Button variant="secondary" onClick={() => setExcluir(null)}>Cancelar</Button>
            <Button variant="accent" onClick={confirmarExclusao} loading={excluindo}>
              <Trash2 className="h-4 w-4" /> Excluir
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">Se for só ajustar dias, horários ou pessoas, prefira alterar a escala.</p>
      </Modal>
    </div>
  );
}
