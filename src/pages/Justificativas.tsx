import clsx from 'clsx';
import { AlertTriangle, CheckCircle2, Lock, MessageSquareText, Pencil, Search, Trash2, Users } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge, type BadgeTone } from '@/components/ui/Badge';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, formatMinutos, horasParaMinutos } from '@/lib/format';
import { competencia, useFiltrosAux, opcoesColaboradores, paramColaboradores } from '@/lib/hooks';
import { api } from '@/lib/api';
import type { JustificativaItem, JustificativasLista, TipoJustificativa } from '@/lib/types';

const TIPOS: Record<TipoJustificativa, { label: string; tone: BadgeTone }> = {
  atraso: { label: 'Atraso', tone: 'orange' },
  saida_antecipada: { label: 'Saída antecipada', tone: 'orange' },
  falta: { label: 'Falta', tone: 'red' },
};

const MOTIVOS_PADRAO = [
  'Consulta médica',
  'Acompanhamento de familiar ao médico',
  'Problema no transporte público',
  'Trânsito',
  'Liberado pelo gestor',
  'Serviço externo',
  'Compensação de horas',
  'Problema pessoal',
];

type Situacao = 'pendentes' | 'justificadas' | 'abonadas' | '';
type Modo = 'justificar' | 'abonar' | 'parcial';

const chave = (i: JustificativaItem) => `${i.colaborador_id}|${i.data}|${i.tipo}`;
const dataDia = (s: string) => formatData(s, { weekday: 'short', day: '2-digit', month: '2-digit', year: '2-digit' });

/** "30 min de atraso" · "Falta (jornada de 8h00)" */
function descreverEvento(i: JustificativaItem): string {
  if (i.tipo === 'falta') return `Jornada prevista de ${formatMinutos(i.minutos)}`;
  const tempo = i.minutos < 60 ? `${i.minutos} min` : formatMinutos(i.minutos);
  return i.tipo === 'atraso' ? `${tempo} de atraso${i.hora ? ` · entrou ${i.hora}` : ''}` : `${tempo} antes do horário`;
}

function JustificativaModal({
  itens,
  motivos,
  onFechar,
  onSalvo,
}: {
  itens: JustificativaItem[] | null;
  motivos: string[];
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const aberto = !!itens?.length;
  const unico = itens?.length === 1 ? itens[0] : null;
  const [motivo, setMotivo] = useState('');
  const [modo, setModo] = useState<Modo>('justificar');
  const [horas, setHoras] = useState('');
  const [observacao, setObservacao] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (!itens?.length) return;
    setErro(null);
    // Editando uma justificativa: abre como estava. Em lote, parte do zero.
    const j = itens.length === 1 ? itens[0].justificativa : null;
    setMotivo(j?.motivo ?? '');
    setModo(!j || !j.abona ? 'justificar' : j.minutos != null ? 'parcial' : 'abonar');
    setHoras(j?.minutos != null ? formatMinutos(j.minutos).replace('h', ':') : '');
    setObservacao(j?.observacao ?? '');
  }, [itens]);

  const sugestoes = useMemo(() => Array.from(new Set([...motivos, ...MOTIVOS_PADRAO])), [motivos]);
  const colaboradores = new Set(itens?.map((i) => i.colaborador_id)).size;

  const salvar = async () => {
    if (!itens?.length) return;
    setErro(null);
    if (!motivo.trim()) return setErro('Informe o motivo.');
    let minutos: number | null = null;
    if (modo === 'parcial' && unico) {
      minutos = horasParaMinutos(horas);
      if (minutos <= 0) return setErro('Informe quanto tempo abonar (ex.: 0:15).');
      if (minutos > unico.minutos) return setErro(`O abono não pode passar de ${formatMinutos(unico.minutos)}.`);
    }
    setSalvando(true);
    try {
      const r = await api<{ qtd: number }>('api_justificativa_salvar', {
        p_dados: {
          itens: itens.map((i) => ({ colaborador_id: i.colaborador_id, data: i.data, tipo: i.tipo })),
          motivo: motivo.trim(),
          abona: modo !== 'justificar',
          minutos,
          observacao: observacao.trim() || null,
        },
      });
      toast(
        r.qtd === 1
          ? modo === 'justificar' ? 'Justificativa registrada.' : 'Justificativa registrada e tempo abonado.'
          : `${r.qtd} justificativas registradas.`,
      );
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const opcoes: { valor: Modo; label: string; descricao: string }[] = [
    {
      valor: 'justificar',
      label: 'Só justificar',
      descricao: 'Registra o motivo, mas o tempo continua sendo descontado (atraso, falta ou débito no banco).',
    },
    {
      valor: 'abonar',
      label: 'Abonar tudo',
      descricao:
        unico?.tipo === 'falta'
          ? 'O dia deixa de ser falta e não gera débito.'
          : 'O tempo deixa de contar como atraso/saída antecipada e não gera débito.',
    },
    ...(unico
      ? [{ valor: 'parcial' as Modo, label: 'Abonar parte', descricao: 'Abona só a quantidade informada; o restante continua sendo descontado.' }]
      : []),
  ];

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-xl"
      titulo={unico?.justificativa ? 'Editar justificativa' : itens && itens.length > 1 ? `Justificar ${itens.length} ocorrências` : 'Justificar'}
      descricao={
        unico
          ? `${unico.colaborador} · ${dataDia(unico.data)} · ${TIPOS[unico.tipo].label}: ${descreverEvento(unico)}`
          : `${itens?.length ?? 0} ocorrência(s) de ${colaboradores} colaborador(es), com o mesmo motivo.`
      }
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button onClick={salvar} loading={salvando}>
            {modo === 'justificar' ? 'Justificar' : 'Justificar e abonar'}
          </Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className="space-y-4">
        <Field label="Motivo" obrigatorio dica="Escolha uma sugestão ou escreva outro motivo.">
          <input className="input" list="motivos-justificativa" value={motivo} autoFocus
            placeholder="Ex.: Consulta médica" onChange={(e) => setMotivo(e.target.value)} />
          <datalist id="motivos-justificativa">
            {sugestoes.map((m) => <option key={m} value={m} />)}
          </datalist>
        </Field>

        <Field label="O que fazer com o tempo" grupo>
          <div className={clsx('grid gap-1 rounded-xl bg-slate-100 p-1 text-xs font-medium', opcoes.length === 3 ? 'grid-cols-3' : 'grid-cols-2')}>
            {opcoes.map((o) => (
              <button key={o.valor} type="button" onClick={() => setModo(o.valor)}
                className={clsx('rounded-lg py-1.5 transition', modo === o.valor ? 'bg-white text-primary-700 shadow-soft' : 'text-slate-500')}>
                {o.label}
              </button>
            ))}
          </div>
          <span className="mt-1.5 block text-xs text-slate-500">{opcoes.find((o) => o.valor === modo)?.descricao}</span>
        </Field>

        {modo === 'parcial' && unico && (
          <Field label="Tempo abonado" obrigatorio dica={`Ex.: 0:15 — no máximo ${formatMinutos(unico.minutos)}`}>
            <input className="input w-40" placeholder="0:00" inputMode="numeric" value={horas} onChange={(e) => setHoras(e.target.value)} />
          </Field>
        )}

        <Field label="Observação">
          <textarea className="input h-20 resize-none py-2" value={observacao}
            placeholder="Ex.: Apresentou declaração de comparecimento" onChange={(e) => setObservacao(e.target.value)} />
        </Field>

        {itens && itens.length > 1 && (
          <div className="max-h-40 overflow-y-auto rounded-xl text-xs ring-1 ring-slate-200">
            {itens.map((i) => (
              <div key={chave(i)} className="flex items-center gap-2 border-b border-slate-100 px-3 py-1.5 last:border-0">
                <span className="min-w-0 flex-1 truncate text-slate-700">{i.colaborador}</span>
                <span className="tabular-nums text-slate-400">{dataDia(i.data)}</span>
                <span className="w-32 text-right text-slate-500">{TIPOS[i.tipo].label}</span>
              </div>
            ))}
          </div>
        )}
      </div>
    </Modal>
  );
}

export default function Justificativas() {
  const { pode } = useAuth();
  const toast = useToast();
  const podeEditar = pode('justificativas', 'editar');
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState<{ colaboradores: string[]; departamento: string; situacao: Situacao; tipo: string }>({
    colaboradores: [], departamento: '', situacao: 'pendentes', tipo: '',
  });
  const [dados, setDados] = useState<JustificativasLista | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [selecao, setSelecao] = useState<Set<string>>(new Set());
  const [modal, setModal] = useState<JustificativaItem[] | null>(null);
  const [excluindo, setExcluindo] = useState<string | null>(null);

  const consultar = useCallback(async () => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(
        await api<JustificativasLista>('api_justificativas_listar', {
          p_ini: periodo.ini,
          p_fim: periodo.fim,
          p_colaboradores: paramColaboradores(filtros.colaboradores),
          p_departamento: filtros.departamento || null,
          p_situacao: filtros.situacao || null,
        }),
      );
      setSelecao(new Set());
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

  const lista = useMemo(
    () => (dados?.itens ?? []).filter((i) => !filtros.tipo || i.tipo === filtros.tipo),
    [dados, filtros.tipo],
  );
  const selecionaveis = lista.filter((i) => podeEditar && !i.fechado && i.ocorreu);
  const todos = selecionaveis.length > 0 && selecionaveis.every((i) => selecao.has(chave(i)));
  const alternar = (i: JustificativaItem) =>
    setSelecao((s) => {
      const n = new Set(s);
      if (n.has(chave(i))) n.delete(chave(i));
      else n.add(chave(i));
      return n;
    });
  const alternarTodos = () => setSelecao(todos ? new Set() : new Set(selecionaveis.map(chave)));
  const selecionados = lista.filter((i) => selecao.has(chave(i)));

  const resumo = useMemo(() => {
    const r = { pendentes: 0, justificadas: 0, abonado: 0 };
    for (const i of lista) {
      if (!i.justificativa) r.pendentes++;
      else {
        r.justificadas++;
        r.abonado += i.justificativa.minutos_abonados;
      }
    }
    return r;
  }, [lista]);

  const excluir = async (i: JustificativaItem) => {
    if (!i.justificativa) return;
    try {
      await api('api_justificativa_excluir', { p_id: i.justificativa.id });
      toast('Justificativa excluída.');
      setExcluindo(null);
      consultar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Justificativas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Atrasos, saídas antecipadas e faltas apurados no ponto. Registre o motivo e decida se o tempo é abonado (todo ou em parte) ou só fica justificado.
          </p>
        </div>
      </div>

      <section className="card p-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-6">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="Situação">
            <select className="input" value={filtros.situacao} onChange={(e) => setFiltros((f) => ({ ...f, situacao: e.target.value as Situacao }))}>
              <option value="pendentes">Sem justificativa</option>
              <option value="justificadas">Justificadas</option>
              <option value="abonadas">Abonadas</option>
              <option value="">Todas</option>
            </select>
          </Field>
          <Field label="Tipo">
            <select className="input" value={filtros.tipo} onChange={(e) => setFiltros((f) => ({ ...f, tipo: e.target.value }))}>
              <option value="">Todos</option>
              {Object.entries(TIPOS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
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
        </div>
        <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
          <div className="flex flex-wrap gap-1.5">
            {dados && (
              <>
                <Badge tone={resumo.pendentes ? 'orange' : 'slate'} dot={false}>Sem justificativa: {resumo.pendentes}</Badge>
                <Badge tone="blue" dot={false}>Justificadas: {resumo.justificadas}</Badge>
                {resumo.abonado > 0 && <Badge tone="green" dot={false}>Tempo abonado: {formatMinutos(resumo.abonado)}</Badge>}
              </>
            )}
          </div>
          <Button onClick={consultar} loading={carregando} className="h-9">
            <Search className="h-4 w-4" /> Consultar
          </Button>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {selecionados.length > 0 && (
        <div className="sticky top-2 z-10 flex flex-wrap items-center justify-between gap-3 rounded-2xl bg-primary-700 px-5 py-3 text-sm text-white shadow-lg">
          <span>{selecionados.length} selecionada(s)</span>
          <span className="flex gap-2">
            <button className="rounded-lg px-3 py-1.5 text-white/80 hover:bg-white/10" onClick={() => setSelecao(new Set())}>Limpar</button>
            <button className="rounded-lg bg-white px-3 py-1.5 font-medium text-primary-700 hover:bg-primary-50" onClick={() => setModal(selecionados)}>
              Justificar selecionadas
            </button>
          </span>
        </div>
      )}

      {dados === null ? (
        <div className="card h-64 animate-pulse" />
      ) : lista.length === 0 ? (
        <div className="card">
          <EmptyState
            icon={filtros.situacao === 'pendentes' ? CheckCircle2 : MessageSquareText}
            titulo={filtros.situacao === 'pendentes' ? 'Nada pendente no período' : 'Nenhuma ocorrência no período'}
            descricao={
              filtros.situacao === 'pendentes'
                ? 'Todos os atrasos, saídas antecipadas e faltas do período já têm justificativa.'
                : 'Ajuste o período ou os filtros e consulte novamente.'
            }
          />
        </div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[960px] text-sm">
            <thead>
              <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                <th className="w-10 px-4 py-2.5">
                  {selecionaveis.length > 0 && (
                    <input type="checkbox" checked={todos} onChange={alternarTodos} aria-label="Selecionar todas" className="h-4 w-4 accent-primary-700" />
                  )}
                </th>
                <th className="px-3 py-2.5 font-medium">Colaborador</th>
                <th className="px-3 py-2.5 font-medium">Dia</th>
                <th className="px-3 py-2.5 font-medium">Ocorrência</th>
                <th className="px-3 py-2.5 font-medium">Justificativa</th>
                <th className="w-40 px-3 py-2.5" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lista.map((i) => {
                const j = i.justificativa;
                const k = chave(i);
                const editavel = podeEditar && !i.fechado;
                return (
                  <tr key={k} className={clsx('group hover:bg-primary-50/30', selecao.has(k) && 'bg-primary-50/40')}>
                    <td className="px-4 py-3">
                      {editavel && i.ocorreu && (
                        <input type="checkbox" checked={selecao.has(k)} onChange={() => alternar(i)} aria-label="Selecionar" className="h-4 w-4 accent-primary-700" />
                      )}
                    </td>
                    <td className="px-3 py-3">
                      <p className="font-medium text-slate-800">{i.colaborador}</p>
                      <p className="text-xs text-slate-400">Mat. {i.matricula}{i.departamento && ` · ${i.departamento}`}</p>
                    </td>
                    <td className="whitespace-nowrap px-3 py-3 tabular-nums text-slate-600">{dataDia(i.data)}</td>
                    <td className="px-3 py-3">
                      <Badge tone={TIPOS[i.tipo].tone} dot={false}>{TIPOS[i.tipo].label}</Badge>
                      <p className="mt-1 text-xs text-slate-500">{i.ocorreu ? descreverEvento(i) : 'Não aparece mais na apuração (batidas corrigidas)'}</p>
                    </td>
                    <td className="max-w-sm px-3 py-3">
                      {j ? (
                        <>
                          <div className="flex flex-wrap items-center gap-1.5">
                            <span className="font-medium text-slate-700">{j.motivo}</span>
                            {j.abona ? (
                              <Badge tone="green" dot={false}>
                                {j.minutos == null ? 'Abonado' : `Abonado ${formatMinutos(j.minutos)}`}
                              </Badge>
                            ) : (
                              <Badge tone="slate" dot={false}>Só justificado</Badge>
                            )}
                          </div>
                          {j.observacao && <p className="mt-0.5 line-clamp-2 text-xs text-slate-500">{j.observacao}</p>}
                          <p className="mt-0.5 text-[11px] text-slate-400">{j.usuario ?? '—'}</p>
                        </>
                      ) : (
                        <span className="text-xs text-accent-700">Sem justificativa</span>
                      )}
                    </td>
                    <td className="px-3 py-3 text-right">
                      {i.fechado ? (
                        <span title="Período fechado" className="inline-flex text-slate-300"><Lock className="h-4 w-4" /></span>
                      ) : !editavel ? null : excluindo === k ? (
                        <span className="flex items-center justify-end gap-1 text-xs">
                          <button className="rounded-lg px-2 py-1 font-medium text-rose-600 hover:bg-rose-50" onClick={() => excluir(i)}>Excluir</button>
                          <button className="rounded-lg px-2 py-1 text-slate-500 hover:bg-slate-100" onClick={() => setExcluindo(null)}>Não</button>
                        </span>
                      ) : j ? (
                        <span className="flex justify-end gap-1 opacity-60 transition group-hover:opacity-100">
                          {i.ocorreu && (
                            <button className="rounded-lg p-1.5 text-slate-400 hover:bg-white hover:text-primary-600"
                              onClick={() => setModal([i])} aria-label="Editar justificativa">
                              <Pencil className="h-4 w-4" />
                            </button>
                          )}
                          <button className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                            onClick={() => setExcluindo(k)} aria-label="Excluir justificativa">
                            <Trash2 className="h-4 w-4" />
                          </button>
                        </span>
                      ) : (
                        <Button variant="secondary" className="h-8 px-3 text-xs" onClick={() => setModal([i])}>Justificar</Button>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <p className="flex items-center gap-1.5 border-t border-slate-100 px-5 py-3 text-xs text-slate-400">
            <Users className="h-3.5 w-3.5" /> {lista.length} ocorrência(s)
          </p>
        </div>
      )}

      <JustificativaModal
        itens={modal}
        motivos={dados?.motivos ?? []}
        onFechar={() => setModal(null)}
        onSalvo={() => {
          setModal(null);
          consultar();
        }}
      />
    </div>
  );
}
