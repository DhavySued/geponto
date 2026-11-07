import clsx from 'clsx';
import { AlertTriangle, CalendarSearch, Filter, Plus, Search } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { BatidaChip, LegendaBatidas } from '@/components/tratamento/BatidaChip';
import { useAcoesBatida } from '@/components/tratamento/useAcoesBatida';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ContextMenu } from '@/components/ui/ContextMenu';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { formatData, toISODate } from '@/lib/format';
import { ORIGEM_BATIDA, SITUACAO_BATIDA, TIPOS_AUSENCIA, rotuloMarcacao, siglaMarcacao } from '@/lib/ponto';
import { api } from '@/lib/supabase';
import type { ConsultaLinha, SituacaoBatida, TratamentoAux } from '@/lib/types';

interface Filtros {
  ini: string;
  fim: string;
  colaborador: string;
  departamento: string;
  cargo: string;
  jornada: string;
}

const hoje = () => toISODate(new Date());
const filtrosIniciais = (): Filtros => ({ ini: hoje(), fim: hoje(), colaborador: '', departamento: '', cargo: '', jornada: '' });
const dataBR = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });

export default function ConsultaBatidas() {
  const [aux, setAux] = useState<TratamentoAux | null>(null);
  const [filtros, setFiltros] = useState<Filtros | null>(null);
  const [filtroAberto, setFiltroAberto] = useState(true);
  const [dados, setDados] = useState<ConsultaLinha[] | null>(null);
  const [situacao, setSituacao] = useState<SituacaoBatida | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  useEffect(() => {
    api<TratamentoAux>('api_tratamento_auxiliares')
      .then(setAux)
      .catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar.'));
  }, []);

  const consultar = useCallback(async (f: Filtros) => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(
        await api<ConsultaLinha[]>('api_consulta_batidas', {
          p_ini: f.ini,
          p_fim: f.fim,
          p_colaborador: f.colaborador || null,
          p_departamento: f.departamento || null,
          p_cargo: f.cargo || null,
          p_jornada: f.jornada || null,
        }),
      );
      return true;
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
      return false;
    } finally {
      setCarregando(false);
    }
  }, []);

  // Após um ajuste, refaz a mesma consulta
  const recarregar = useCallback(() => {
    if (filtros) consultar(filtros);
  }, [filtros, consultar]);

  const acoes = useAcoesBatida(aux, recarregar);

  const aplicar = async (f: Filtros) => {
    setFiltros(f);
    setSituacao(null);
    if (await consultar(f)) setFiltroAberto(false);
  };

  const contagem = useMemo(() => {
    const c = new Map<SituacaoBatida, number>();
    dados?.forEach((b) => c.set(b.situacao, (c.get(b.situacao) ?? 0) + 1));
    return c;
  }, [dados]);

  const linhas = useMemo(() => {
    const lista = situacao ? dados?.filter((b) => b.situacao === situacao) : dados;
    if (!lista) return lista;
    const desconsiderada = (b: ConsultaLinha) => b.tipo === 'batida' && b.status === 'desconsiderada';
    const ordem = (b: ConsultaLinha) => (b.sentido && b.turno && !desconsiderada(b) ? b.turno * 2 + (b.sentido === 'S' ? 1 : 0) : 99);
    const hora = (b: ConsultaLinha) => (b.tipo === 'batida' ? b.data_hora : '');
    return [...lista].sort(
      (a, b) =>
        a.data_referencia.localeCompare(b.data_referencia) ||
        a.colaborador.localeCompare(b.colaborador) ||
        ordem(a) - ordem(b) ||
        hora(a).localeCompare(hora(b)),
    );
  }, [dados, situacao]);
  const nomeColaborador = aux?.colaboradores.find((c) => c.id === filtros?.colaborador)?.nome;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Consulta de batidas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Cada batida e cada marcação prevista na jornada, com o horário previsto e a situação. Clique na batida (ou com o botão direito na linha) para ajustá-la.
          </p>
        </div>
        <div className="flex gap-2">
          {aux?.pode_editar && filtros && (
            <Button variant="secondary" onClick={() => acoes.incluir(filtros.colaborador || null, filtros.fim)}>
              <Plus className="h-4 w-4" /> Incluir batida
            </Button>
          )}
          <Button onClick={() => setFiltroAberto(true)}>
            <Filter className="h-4 w-4" /> Filtrar
          </Button>
        </div>
      </div>

      {filtros && (
        <div className="card flex flex-wrap items-center gap-x-6 gap-y-2 px-5 py-3 text-sm">
          <span className="text-slate-500">
            Colaborador: <strong className="font-medium text-slate-800">{nomeColaborador ?? 'Todos'}</strong>
          </span>
          <span className="text-slate-500">
            Período:{' '}
            <strong className="font-medium tabular-nums text-slate-800">
              {filtros.ini === filtros.fim ? dataBR(filtros.ini) : `${dataBR(filtros.ini)} a ${dataBR(filtros.fim)}`}
            </strong>
          </span>
          {dados && (
            <span className="text-slate-500">
              <strong className="font-medium tabular-nums text-slate-800">{dados.filter((b) => b.tipo === 'batida').length}</strong> batida(s)
            </span>
          )}
          <button onClick={() => setFiltroAberto(true)} className="ml-auto text-sm font-medium text-primary-600 hover:text-primary-700">
            Alterar filtro
          </button>
        </div>
      )}

      {erro && !filtroAberto && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {/* Totais por situação — clique para filtrar */}
      {dados && dados.length > 0 && (
        <div className="flex flex-wrap gap-2">
          {(Object.keys(SITUACAO_BATIDA) as SituacaoBatida[])
            .filter((s) => contagem.get(s))
            .map((s) => (
              <button
                key={s}
                onClick={() => setSituacao((atual) => (atual === s ? null : s))}
                title={SITUACAO_BATIDA[s].descricao}
                className={clsx(
                  'rounded-full transition',
                  situacao && situacao !== s && 'opacity-40 hover:opacity-80',
                  situacao === s && 'ring-2 ring-primary-400 ring-offset-1',
                )}
              >
                <Badge tone={SITUACAO_BATIDA[s].tone}>
                  {SITUACAO_BATIDA[s].label} · <span className="tabular-nums">{contagem.get(s)}</span>
                </Badge>
              </button>
            ))}
          {situacao && (
            <button onClick={() => setSituacao(null)} className="px-2 text-xs font-medium text-slate-500 hover:text-slate-700">
              Mostrar todas
            </button>
          )}
        </div>
      )}

      {!filtros ? (
        <div className="card">
          <EmptyState
            icon={CalendarSearch}
            titulo="Selecione o colaborador e o período"
            descricao="Escolha quem e quais dias consultar para ver as batidas."
            acao={<Button onClick={() => setFiltroAberto(true)}><Filter className="h-4 w-4" /> Filtrar</Button>}
          />
        </div>
      ) : dados === null || (carregando && !dados.length) ? (
        <div className="card h-64 animate-pulse" />
      ) : !linhas?.length ? (
        <div className="card">
          <EmptyState
            icon={CalendarSearch}
            titulo="Nenhuma batida encontrada"
            descricao="Não há batidas nem marcações previstas para o filtro selecionado."
          />
        </div>
      ) : (
        <section className="card overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[1040px] border-collapse text-sm">
              <thead>
                <tr className="bg-slate-100 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
                  <th className="border border-slate-200 px-3 py-2">Data</th>
                  <th className="border border-slate-200 px-3 py-2">Dia</th>
                  <th className="border border-slate-200 px-3 py-2">Colaborador</th>
                  <th className="border border-slate-200 px-3 py-2">Marcação</th>
                  <th className="border border-slate-200 px-3 py-2 text-center">Previsão</th>
                  <th className="border border-slate-200 px-3 py-2 text-center">Realizado</th>
                  <th className="border border-slate-200 px-3 py-2">Status da batida</th>
                  <th className="border border-slate-200 px-3 py-2">Origem</th>
                  <th className="border border-slate-200 px-3 py-2">Observação</th>
                </tr>
              </thead>
              <tbody>
                {linhas.map((b, i) => {
                  const ant = linhas[i - 1];
                  const novoDia = !!ant && (ant.colaborador_id !== b.colaborador_id || ant.data_referencia !== b.data_referencia);
                  const st = SITUACAO_BATIDA[b.situacao];
                  const classificada = !!b.sentido && !(b.tipo === 'batida' && b.status === 'desconsiderada');
                  return (
                    <tr
                      key={b.id}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        if (b.tipo === 'batida') acoes.abrirMenuBatida(e, b);
                        else acoes.abrirMenuDia(e, b.colaborador_id, b.data_referencia);
                      }}
                      className={clsx('transition hover:bg-primary-50/50', novoDia && '[&>td]:border-t-2 [&>td]:border-t-slate-300')}
                    >
                      <td className="whitespace-nowrap border border-slate-200 px-3 py-2 tabular-nums text-slate-700">{dataBR(b.data_referencia)}</td>
                      <td className="whitespace-nowrap border border-slate-200 px-3 py-2 capitalize text-slate-600">
                        {formatData(b.data_referencia, { weekday: 'short' }).replace('.', '')}
                      </td>
                      <td className="border border-slate-200 px-3 py-2">
                        <span className="font-medium text-slate-800">{b.colaborador}</span>
                        <span className="ml-1.5 text-xs text-slate-400">{b.matricula}</span>
                      </td>
                      <td className="whitespace-nowrap border border-slate-200 px-3 py-2 text-slate-600">
                        {classificada ? (
                          <>
                            <span className="mr-1.5 rounded bg-slate-100 px-1 text-[10px] font-bold text-slate-600">
                              {siglaMarcacao(b.sentido, b.turno)}
                            </span>
                            {rotuloMarcacao(b.sentido, b.turno)}
                          </>
                        ) : (
                          <span className="text-slate-300">—</span>
                        )}
                      </td>
                      <td className="border border-slate-200 px-3 py-2 text-center tabular-nums text-slate-600">
                        {b.previsto ?? <span className="text-slate-300">—</span>}
                      </td>
                      <td className="border border-slate-200 px-3 py-2 text-center">
                        {b.tipo === 'batida' ? (
                          <BatidaChip batida={b} onAcao={acoes.abrirMenuBatida} />
                        ) : b.tipo === 'dia' ? (
                          <span className="text-slate-300">—</span>
                        ) : (
                          <button
                            type="button"
                            disabled={!aux?.pode_editar}
                            onClick={(e) => acoes.abrirMenuDia(e, b.colaborador_id, b.data_referencia)}
                            title={aux?.pode_editar ? 'Incluir a batida que faltou' : undefined}
                            className="inline-flex items-center gap-1 rounded-lg border border-dashed border-slate-300 px-2 py-0.5 text-xs font-semibold text-slate-400 transition enabled:hover:border-primary-400 enabled:hover:text-primary-600"
                          >
                            --:--{aux?.pode_editar && <Plus className="h-3 w-3" />}
                          </button>
                        )}
                      </td>
                      <td className="border border-slate-200 px-3 py-2" title={st.descricao}>
                        <Badge tone={st.tone}>
                          {b.tipo === 'dia' && b.ausencia
                            ? TIPOS_AUSENCIA[b.ausencia].label
                            : b.tipo === 'batida' && b.situacao === 'ausencia' && b.ausencia
                              ? `Batida em ${TIPOS_AUSENCIA[b.ausencia].label.toLowerCase()}`
                              : st.label}
                        </Badge>
                      </td>
                      <td className="border border-slate-200 px-3 py-2 text-xs text-slate-600">
                        {b.tipo === 'batida' ? (
                          <>
                            {ORIGEM_BATIDA[b.origem] ?? b.origem}
                            {b.motivo && <span className="block truncate text-slate-400" title={b.motivo}>{b.motivo}</span>}
                          </>
                        ) : (
                          <span className="text-slate-300">—</span>
                        )}
                      </td>
                      <td className="border border-slate-200 px-3 py-2 text-xs font-medium text-slate-600">
                        {b.obs_dia ?? <span className="font-normal text-slate-300">—</span>}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <div className="border-t border-slate-100 px-5 py-3">
            <LegendaBatidas dica="Clique na batida → ações e classificação" />
          </div>
        </section>
      )}

      <FiltroModal
        aberto={filtroAberto}
        aux={aux}
        inicial={filtros ?? filtrosIniciais()}
        carregando={carregando}
        erro={filtroAberto ? erro : null}
        onFechar={() => setFiltroAberto(false)}
        onAplicar={aplicar}
      />
      <ContextMenu menu={acoes.menu} onFechar={acoes.fecharMenu} />
      {acoes.modais}
    </div>
  );
}

/** Popup de filtro: abre ao entrar na tela e pelo botão "Filtrar". */
function FiltroModal({
  aberto,
  aux,
  inicial,
  carregando,
  erro,
  onFechar,
  onAplicar,
}: {
  aberto: boolean;
  aux: TratamentoAux | null;
  inicial: Filtros;
  carregando: boolean;
  erro: string | null;
  onFechar: () => void;
  onAplicar: (f: Filtros) => void;
}) {
  const [f, setF] = useState(inicial);
  const [busca, setBusca] = useState('');

  useEffect(() => {
    if (aberto) {
      setF(inicial);
      setBusca('');
    }
    // Reinicia o formulário só quando o popup abre
  }, [aberto]);

  const set = (patch: Partial<Filtros>) => setF((atual) => ({ ...atual, ...patch }));
  const termo = busca.trim().toLowerCase();
  const colaboradores =
    aux?.colaboradores.filter(
      (c) =>
        (!f.departamento || c.departamento_id === f.departamento) &&
        (!f.cargo || c.cargo_id === f.cargo) &&
        (!f.jornada || c.jornada_id === f.jornada) &&
        (!termo || c.nome.toLowerCase().includes(termo) || c.matricula.toLowerCase().includes(termo)),
    ) ?? [];
  const atalho = (dias: number) => {
    const d = new Date();
    d.setDate(d.getDate() - dias);
    set({ ini: toISODate(d), fim: hoje() });
  };

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      titulo="Filtrar batidas"
      descricao="Selecione o colaborador e a data que deseja consultar."
      rodape={
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onFechar}>Cancelar</Button>
          <Button onClick={() => onAplicar(f)} loading={carregando}>
            <Search className="h-4 w-4" /> Consultar
          </Button>
        </div>
      }
    >
      <form
        className="space-y-4"
        onSubmit={(e) => {
          e.preventDefault();
          onAplicar(f);
        }}
      >
        <Field label="Colaborador">
          <input
            className="input mb-2"
            placeholder="Buscar por nome ou matrícula…"
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
          />
          <select className="input" value={f.colaborador} onChange={(e) => set({ colaborador: e.target.value })}>
            <option value="">Todos os colaboradores</option>
            {colaboradores.map((c) => (
              <option key={c.id} value={c.id}>{c.nome} · {c.matricula}</option>
            ))}
          </select>
        </Field>

        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Data inicial">
            <input type="date" className="input" value={f.ini} max={f.fim} onChange={(e) => e.target.value && set({ ini: e.target.value })} />
          </Field>
          <Field label="Data final">
            <input type="date" className="input" value={f.fim} min={f.ini} max={hoje()} onChange={(e) => e.target.value && set({ fim: e.target.value })} />
          </Field>
        </div>
        <div className="flex flex-wrap gap-2 text-xs">
          {[
            ['Hoje', 0],
            ['Últimos 7 dias', 6],
            ['Últimos 30 dias', 29],
          ].map(([label, dias]) => (
            <button
              key={label}
              type="button"
              onClick={() => atalho(dias as number)}
              className="rounded-full bg-slate-100 px-3 py-1 font-medium text-slate-600 transition hover:bg-primary-50 hover:text-primary-700"
            >
              {label}
            </button>
          ))}
        </div>

        <details className="rounded-xl border border-slate-200 px-4 py-3">
          <summary className="cursor-pointer text-sm font-medium text-slate-600">Mais filtros</summary>
          <div className="mt-3 grid gap-4 sm:grid-cols-3">
            <Field label="Lotação">
              <select className="input" value={f.departamento} onChange={(e) => set({ departamento: e.target.value, colaborador: '' })}>
                <option value="">Todas</option>
                {aux?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
              </select>
            </Field>
            <Field label="Cargo">
              <select className="input" value={f.cargo} onChange={(e) => set({ cargo: e.target.value, colaborador: '' })}>
                <option value="">Todos</option>
                {aux?.cargos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
              </select>
            </Field>
            <Field label="Jornada">
              <select className="input" value={f.jornada} onChange={(e) => set({ jornada: e.target.value, colaborador: '' })}>
                <option value="">Todas</option>
                {aux?.jornadas.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
              </select>
            </Field>
          </div>
        </details>

        {erro && (
          <div className="flex items-center gap-2 rounded-xl bg-rose-50 p-3 text-sm text-rose-700 ring-1 ring-rose-200">
            <AlertTriangle className="h-4 w-4 shrink-0" /> {erro}
          </div>
        )}
        <button type="submit" className="hidden" />
      </form>
    </Modal>
  );
}
