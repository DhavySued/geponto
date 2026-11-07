import clsx from 'clsx';
import { AlertTriangle, Lock, Pencil, Plus, Search, Stethoscope, Trash2, Users } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, formatMinutos, horasParaMinutos, toISODate } from '@/lib/format';
import { competencia, useFiltrosAux } from '@/lib/hooks';
import { TIPOS_AUSENCIA } from '@/lib/ponto';
import { api } from '@/lib/supabase';
import type { FiltrosAux, Ocorrencia, TipoAusencia } from '@/lib/types';

const dataCurta = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: '2-digit' });

interface FormOcorrencia {
  colaboradores: string[];
  tipo: TipoAusencia;
  data_inicio: string;
  data_fim: string;
  abona: boolean;
  emHoras: boolean;
  horas: string;
  justificativa: string;
}

function OcorrenciaModal({
  aberto,
  ocorrencia,
  aux,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  ocorrencia: Ocorrencia | null;
  aux: FiltrosAux | null;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const hoje = toISODate(new Date());
  const [form, setForm] = useState<FormOcorrencia>({
    colaboradores: [], tipo: 'atestado', data_inicio: hoje, data_fim: hoje, abona: true, emHoras: false, horas: '', justificativa: '',
  });
  const [busca, setBusca] = useState('');
  const [depto, setDepto] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setErro(null);
    setBusca('');
    setDepto('');
    setForm(
      ocorrencia
        ? {
            colaboradores: [ocorrencia.colaborador_id],
            tipo: ocorrencia.tipo,
            data_inicio: ocorrencia.data_inicio,
            data_fim: ocorrencia.data_fim,
            abona: ocorrencia.abona,
            emHoras: ocorrencia.minutos != null,
            horas: ocorrencia.minutos != null ? formatMinutos(ocorrencia.minutos).replace('h', ':') : '',
            justificativa: ocorrencia.justificativa ?? '',
          }
        : { colaboradores: [], tipo: 'atestado', data_inicio: hoje, data_fim: hoje, abona: true, emHoras: false, horas: '', justificativa: '' },
    );
  }, [aberto, ocorrencia, hoje]);

  const set = <K extends keyof FormOcorrencia>(k: K, v: FormOcorrencia[K]) => setForm((f) => ({ ...f, [k]: v }));
  const visiveis = useMemo(
    () =>
      (aux?.colaboradores ?? []).filter(
        (c) =>
          c.situacao !== 'desligado' &&
          (!depto || c.departamento_id === depto) &&
          (!busca || `${c.nome} ${c.matricula}`.toLowerCase().includes(busca.toLowerCase())),
      ),
    [aux, depto, busca],
  );
  const selecionados = new Set(form.colaboradores);
  const alternar = (id: string) =>
    set('colaboradores', selecionados.has(id) ? form.colaboradores.filter((x) => x !== id) : [...form.colaboradores, id]);
  const todosVisiveis = visiveis.length > 0 && visiveis.every((c) => selecionados.has(c.id));
  const alternarTodos = () =>
    set(
      'colaboradores',
      todosVisiveis
        ? form.colaboradores.filter((id) => !visiveis.some((c) => c.id === id))
        : Array.from(new Set([...form.colaboradores, ...visiveis.map((c) => c.id)])),
    );

  const salvar = async () => {
    setErro(null);
    const emHoras = form.tipo === 'abono' && form.emHoras;
    if (emHoras && horasParaMinutos(form.horas) <= 0) return setErro('Informe as horas abonadas (ex.: 1:30).');
    setSalvando(true);
    try {
      const r = await api<{ qtd: number }>('api_ocorrencia_salvar', {
        p_dados: {
          id: ocorrencia?.id ?? null,
          colaboradores: form.colaboradores,
          tipo: form.tipo,
          data_inicio: form.data_inicio,
          data_fim: emHoras ? form.data_inicio : form.data_fim,
          // Abono em horas sempre abona (o botão "Abona a jornada" fica oculto nesse modo)
          abona: emHoras || form.abona,
          minutos: emHoras ? horasParaMinutos(form.horas) : null,
          justificativa: form.justificativa,
        },
      });
      toast(ocorrencia ? 'Ocorrência atualizada.' : `Ocorrência lançada para ${r.qtd} colaborador(es).`);
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const emHoras = form.tipo === 'abono' && form.emHoras;

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-3xl"
      titulo={ocorrencia ? 'Editar ocorrência' : 'Lançar ocorrência'}
      descricao="Dias com ocorrência que abona não geram falta nem débito no banco de horas."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button onClick={salvar} loading={salvando}>
            {ocorrencia ? 'Salvar' : `Lançar${form.colaboradores.length > 1 ? ` para ${form.colaboradores.length}` : ''}`}
          </Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className="grid gap-6 lg:grid-cols-[1fr_1.1fr]">
        {/* Colaboradores */}
        <section>
          {ocorrencia ? (
            <Field label="Colaborador">
              <p className="input flex items-center bg-slate-50">{ocorrencia.colaborador}</p>
            </Field>
          ) : (
            <>
              <div className="mb-2 flex items-center justify-between">
                <span className="label mb-0">
                  Colaboradores <span className="text-accent-600">*</span>
                </span>
                <span className="text-xs text-slate-500">{form.colaboradores.length} selecionado(s)</span>
              </div>
              <div className="mb-2 grid grid-cols-2 gap-2">
                <input className="input h-9" placeholder="Buscar…" value={busca} onChange={(e) => setBusca(e.target.value)} />
                <select className="input h-9" value={depto} onChange={(e) => setDepto(e.target.value)}>
                  <option value="">Todos os departamentos</option>
                  {aux?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
                </select>
              </div>
              <div className="max-h-72 overflow-y-auto rounded-xl ring-1 ring-slate-200">
                <label className="flex cursor-pointer items-center gap-3 border-b border-slate-100 bg-slate-50 px-3 py-2 text-xs font-medium text-slate-600">
                  <input type="checkbox" checked={todosVisiveis} onChange={alternarTodos} className="h-4 w-4 accent-primary-700" />
                  Selecionar todos ({visiveis.length})
                </label>
                {visiveis.map((c) => (
                  <label key={c.id} className="flex cursor-pointer items-center gap-3 px-3 py-2 text-sm hover:bg-slate-50">
                    <input type="checkbox" checked={selecionados.has(c.id)} onChange={() => alternar(c.id)} className="h-4 w-4 accent-primary-700" />
                    <span className="min-w-0 flex-1 truncate text-slate-700">{c.nome}</span>
                    <span className="text-xs tabular-nums text-slate-400">{c.matricula}</span>
                  </label>
                ))}
                {visiveis.length === 0 && <p className="px-3 py-6 text-center text-xs text-slate-400">Nenhum colaborador.</p>}
              </div>
            </>
          )}
        </section>

        {/* Dados */}
        <section className="space-y-4">
          <Field label="Tipo" obrigatorio dica={TIPOS_AUSENCIA[form.tipo].descricao}>
            <select className="input" value={form.tipo} onChange={(e) => set('tipo', e.target.value as TipoAusencia)}>
              {Object.entries(TIPOS_AUSENCIA).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
            </select>
          </Field>

          {form.tipo === 'abono' && (
            <div className="grid grid-cols-2 gap-1 rounded-xl bg-slate-100 p-1 text-xs font-medium">
              {[false, true].map((v) => (
                <button key={String(v)} type="button" onClick={() => set('emHoras', v)}
                  className={clsx('rounded-lg py-1.5 transition', form.emHoras === v ? 'bg-white text-primary-700 shadow-soft' : 'text-slate-500')}>
                  {v ? 'Algumas horas' : 'Dia(s) inteiro(s)'}
                </button>
              ))}
            </div>
          )}

          <div className="grid grid-cols-2 gap-3">
            <Field label={emHoras ? 'Data' : 'De'} obrigatorio>
              <input type="date" className="input" value={form.data_inicio}
                onChange={(e) => setForm((f) => ({ ...f, data_inicio: e.target.value, data_fim: f.data_fim < e.target.value ? e.target.value : f.data_fim }))} />
            </Field>
            {emHoras ? (
              <Field label="Horas abonadas" obrigatorio dica="Ex.: 1:30">
                <input className="input" placeholder="0:00" value={form.horas} onChange={(e) => set('horas', e.target.value)} />
              </Field>
            ) : (
              <Field label="Até" obrigatorio>
                <input type="date" className="input" min={form.data_inicio} value={form.data_fim} onChange={(e) => set('data_fim', e.target.value)} />
              </Field>
            )}
          </div>

          {!emHoras && (
            <Switch
              ativo={form.abona}
              onChange={(v) => set('abona', v)}
              label="Abona a jornada"
              descricao={form.abona ? 'Os dias não geram falta nem débito.' : 'Fica registrado, mas o dia continua como falta.'}
            />
          )}

          <Field label="Justificativa" obrigatorio>
            <textarea className="input h-20 resize-none py-2" value={form.justificativa}
              placeholder="Ex.: Atestado médico CID J11, Dr. Fulano (CRM 1234)"
              onChange={(e) => set('justificativa', e.target.value)} />
          </Field>
        </section>
      </div>
    </Modal>
  );
}

export default function Ocorrencias() {
  const { pode } = useAuth();
  const toast = useToast();
  const podeEditar = pode('ocorrencias', 'editar');
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaborador: '', departamento: '', tipo: '' });
  const [lista, setLista] = useState<Ocorrencia[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [modal, setModal] = useState<{ aberto: boolean; ocorrencia: Ocorrencia | null }>({ aberto: false, ocorrencia: null });
  const [excluindo, setExcluindo] = useState<string | null>(null);

  const consultar = useCallback(async () => {
    setCarregando(true);
    try {
      setErro(null);
      setLista(
        await api<Ocorrencia[]>('api_ocorrencias_listar', {
          p_ini: periodo.ini,
          p_fim: periodo.fim,
          p_colaborador: filtros.colaborador || null,
          p_departamento: filtros.departamento || null,
          p_tipo: filtros.tipo || null,
        }),
      );
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

  const excluir = async (o: Ocorrencia) => {
    try {
      await api('api_ocorrencia_excluir', { p_id: o.id });
      toast('Ocorrência excluída.');
      setExcluindo(null);
      consultar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    }
  };

  const totais = useMemo(() => {
    const t: Partial<Record<TipoAusencia, number>> = {};
    for (const o of lista ?? []) t[o.tipo] = (t[o.tipo] ?? 0) + 1;
    return t;
  }, [lista]);

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Ocorrências e afastamentos</h2>
          <p className="mt-1 text-sm text-slate-500">
            Atestados, férias, afastamentos, folgas, faltas justificadas e abonos. Lance para um colaborador ou para vários de uma vez.
          </p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={() => setModal({ aberto: true, ocorrencia: null })}>
            <Plus className="h-4 w-4" /> Lançar ocorrência
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
          <Field label="Tipo">
            <select className="input" value={filtros.tipo} onChange={(e) => setFiltros((f) => ({ ...f, tipo: e.target.value }))}>
              <option value="">Todos</option>
              {Object.entries(TIPOS_AUSENCIA).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
            </select>
          </Field>
          <Field label="Departamento">
            <select className="input" value={filtros.departamento} onChange={(e) => setFiltros((f) => ({ ...f, departamento: e.target.value, colaborador: '' }))}>
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
        </div>
        <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
          <div className="flex flex-wrap gap-1.5">
            {Object.entries(totais).map(([k, n]) => (
              <Badge key={k} tone="blue" dot={false}>{TIPOS_AUSENCIA[k as TipoAusencia].label}: {n}</Badge>
            ))}
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

      {lista === null ? (
        <div className="card h-64 animate-pulse" />
      ) : lista.length === 0 ? (
        <div className="card">
          <EmptyState
            icon={Stethoscope}
            titulo="Nenhuma ocorrência no período"
            descricao="Lance atestados, férias e afastamentos para que esses dias não sejam contados como falta."
          />
        </div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[900px] text-sm">
            <thead>
              <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                <th className="px-5 py-2.5 font-medium">Colaborador</th>
                <th className="px-5 py-2.5 font-medium">Tipo</th>
                <th className="px-5 py-2.5 font-medium">Período</th>
                <th className="px-5 py-2.5 font-medium">Justificativa</th>
                <th className="px-5 py-2.5 font-medium">Lançado por</th>
                <th className="w-24 px-3 py-2.5" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lista.map((o) => (
                <tr key={o.id} className="group hover:bg-primary-50/30">
                  <td className="px-5 py-3">
                    <p className="font-medium text-slate-800">{o.colaborador}</p>
                    <p className="text-xs text-slate-400">Mat. {o.matricula}{o.departamento && ` · ${o.departamento}`}</p>
                  </td>
                  <td className="px-5 py-3">
                    <Badge tone={o.abona ? 'blue' : 'orange'} dot={false}>{TIPOS_AUSENCIA[o.tipo]?.label ?? o.tipo}</Badge>
                    {!o.abona && <p className="mt-1 text-[11px] text-accent-700">Não abona</p>}
                  </td>
                  <td className="whitespace-nowrap px-5 py-3 tabular-nums text-slate-600">
                    {o.minutos != null ? (
                      <>{formatMinutos(o.minutos)} em {dataCurta(o.data_inicio)}</>
                    ) : o.data_inicio === o.data_fim ? (
                      dataCurta(o.data_inicio)
                    ) : (
                      <>
                        {dataCurta(o.data_inicio)} – {dataCurta(o.data_fim)}
                        <span className="ml-1.5 text-xs text-slate-400">({o.dias} dias)</span>
                      </>
                    )}
                  </td>
                  <td className="max-w-xs px-5 py-3 text-slate-500"><p className="line-clamp-2">{o.justificativa}</p></td>
                  <td className="px-5 py-3 text-xs text-slate-400">{o.usuario ?? '—'}</td>
                  <td className="px-3 py-3 text-right">
                    {o.fechado ? (
                      <span title="Período fechado" className="inline-flex text-slate-300"><Lock className="h-4 w-4" /></span>
                    ) : podeEditar && (
                      excluindo === o.id ? (
                        <span className="flex items-center justify-end gap-1 text-xs">
                          <button className="rounded-lg px-2 py-1 font-medium text-rose-600 hover:bg-rose-50" onClick={() => excluir(o)}>Excluir</button>
                          <button className="rounded-lg px-2 py-1 text-slate-500 hover:bg-slate-100" onClick={() => setExcluindo(null)}>Não</button>
                        </span>
                      ) : (
                        <span className="flex justify-end gap-1 opacity-60 transition group-hover:opacity-100">
                          <button className="rounded-lg p-1.5 text-slate-400 hover:bg-white hover:text-primary-600"
                            onClick={() => setModal({ aberto: true, ocorrencia: o })} aria-label="Editar">
                            <Pencil className="h-4 w-4" />
                          </button>
                          <button className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                            onClick={() => setExcluindo(o.id)} aria-label="Excluir">
                            <Trash2 className="h-4 w-4" />
                          </button>
                        </span>
                      )
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          <p className="flex items-center gap-1.5 border-t border-slate-100 px-5 py-3 text-xs text-slate-400">
            <Users className="h-3.5 w-3.5" /> {lista.length} ocorrência(s)
          </p>
        </div>
      )}

      <OcorrenciaModal
        aberto={modal.aberto}
        ocorrencia={modal.ocorrencia}
        aux={aux}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal({ aberto: false, ocorrencia: null });
          consultar();
        }}
      />
    </div>
  );
}
