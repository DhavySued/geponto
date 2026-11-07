import clsx from 'clsx';
import { AlertTriangle, Fingerprint, MoreHorizontal, Plus, Search } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { BatidaChip, LegendaBatidas, STATUS_BATIDA } from '@/components/tratamento/BatidaChip';
import { useAcoesBatida } from '@/components/tratamento/useAcoesBatida';
import { Button } from '@/components/ui/Button';
import { ContextMenu } from '@/components/ui/ContextMenu';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { formatData, toISODate } from '@/lib/format';
import { ORIGEM_BATIDA, rotuloMarcacao } from '@/lib/ponto';
import { api } from '@/lib/supabase';
import type { BatidaTratamento, StatusBatida, TratamentoAux } from '@/lib/types';

type FiltroStatus = 'todas' | StatusBatida;
const STATUS_FILTRO: { chave: FiltroStatus; label: string }[] = [
  { chave: 'todas', label: 'Todas' },
  { chave: 'original', label: 'Original' },
  { chave: 'incluida', label: 'Incluída' },
  { chave: 'desconsiderada', label: 'Desconsiderada' },
];

function diasAtras(n: number) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return toISODate(d);
}

export default function TratamentoBatidas() {
  const [aux, setAux] = useState<TratamentoAux | null>(null);
  const [filtros, setFiltros] = useState({ ini: diasAtras(6), fim: toISODate(new Date()), colaborador: '', departamento: '', status: 'todas' as FiltroStatus });
  const [lista, setLista] = useState<BatidaTratamento[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  useEffect(() => {
    api<TratamentoAux>('api_tratamento_auxiliares')
      .then(setAux)
      .catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar.'));
  }, []);

  const pesquisar = useCallback(async () => {
    setCarregando(true);
    try {
      setErro(null);
      setLista(
        await api<BatidaTratamento[]>('api_tratamento_batidas', {
          p_ini: filtros.ini,
          p_fim: filtros.fim,
          p_colaborador: filtros.colaborador || null,
          p_departamento: filtros.departamento || null,
          p_status: filtros.status,
        }),
      );
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao pesquisar.');
    } finally {
      setCarregando(false);
    }
  }, [filtros]);

  useEffect(() => {
    pesquisar();
  }, [pesquisar]);

  const acoes = useAcoesBatida(aux, pesquisar);
  const set = (k: keyof typeof filtros, v: string) => setFiltros((f) => ({ ...f, [k]: v }));
  const colaboradores = aux?.colaboradores.filter((c) => !filtros.departamento || c.departamento_id === filtros.departamento) ?? [];

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Tratamento de batidas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Inclua batidas esquecidas, edite ou apague as incluídas e desconsidere marcações originais indevidas.
          </p>
        </div>
        {aux?.pode_editar && (
          <Button variant="accent" onClick={() => acoes.incluir(filtros.colaborador || null)}>
            <Plus className="h-4 w-4" /> Incluir batida
          </Button>
        )}
      </div>

      {/* Contexto de pesquisa */}
      <section className="card p-5">
        <div className="grid gap-4 md:grid-cols-2 xl:grid-cols-[150px_150px_1fr_1fr]">
          <Field label="Data inicial">
            <input type="date" className="input" value={filtros.ini} max={filtros.fim} onChange={(e) => e.target.value && set('ini', e.target.value)} />
          </Field>
          <Field label="Data final">
            <input type="date" className="input" value={filtros.fim} min={filtros.ini} onChange={(e) => e.target.value && set('fim', e.target.value)} />
          </Field>
          <Field label="Lotação">
            <select className="input" value={filtros.departamento} onChange={(e) => setFiltros((f) => ({ ...f, departamento: e.target.value, colaborador: '' }))}>
              <option value="">Todas</option>
              {aux?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
            </select>
          </Field>
          <Field label="Empregado">
            <select className="input" value={filtros.colaborador} onChange={(e) => set('colaborador', e.target.value)}>
              <option value="">Todos</option>
              {colaboradores.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
            </select>
          </Field>
        </div>
        <div className="mt-4 flex flex-wrap items-center justify-between gap-3">
          <div className="flex rounded-xl bg-slate-100 p-1" role="radiogroup" aria-label="Status da batida">
            {STATUS_FILTRO.map((s) => (
              <button
                key={s.chave}
                role="radio"
                aria-checked={filtros.status === s.chave}
                onClick={() => set('status', s.chave)}
                className={clsx(
                  'flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium transition',
                  filtros.status === s.chave ? 'bg-white text-slate-900 shadow-soft' : 'text-slate-500 hover:text-slate-800',
                )}
              >
                {s.chave !== 'todas' && <span className={clsx('h-2 w-2 rounded-full', STATUS_BATIDA[s.chave].ponto)} />}
                {s.label}
              </button>
            ))}
          </div>
          <Button variant="secondary" onClick={pesquisar} loading={carregando} className="h-9">
            <Search className="h-4 w-4" /> Pesquisar
          </Button>
        </div>
      </section>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      <section className="card">
        <div className="border-b border-slate-100 px-5 py-3">
          <LegendaBatidas dica="Clique ou use o botão direito na linha para ver as ações" />
        </div>
        {lista === null ? (
          <div className="space-y-3 p-5">
            {Array.from({ length: 5 }, (_, i) => <div key={i} className="h-11 animate-pulse rounded-xl bg-slate-50" />)}
          </div>
        ) : lista.length === 0 ? (
          <EmptyState icon={Fingerprint} titulo="Nenhuma batida encontrada" descricao="Ajuste o período, o empregado ou o status." />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[860px] text-sm">
              <thead>
                <tr className="text-left text-xs text-slate-400">
                  <th className="px-5 py-3 font-medium">Empregado</th>
                  <th className="px-5 py-3 font-medium">Data / hora</th>
                  <th className="px-5 py-3 font-medium">Referência</th>
                  <th className="px-5 py-3 font-medium">Sentido</th>
                  <th className="px-5 py-3 font-medium">Status</th>
                  <th className="px-5 py-3 font-medium">Motivo / observação</th>
                  <th className="px-5 py-3 font-medium">Origem</th>
                  <th className="w-12 px-3 py-3" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {lista.map((b) => {
                  const st = STATUS_BATIDA[b.status];
                  return (
                    <tr
                      key={b.id}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        acoes.abrirMenuBatida(e, b);
                      }}
                      className="hover:bg-slate-50/70"
                    >
                      <td className="px-5 py-3">
                        <p className="font-medium text-slate-800">{b.colaborador}</p>
                        <p className="text-xs text-slate-400">{b.departamento ?? `Mat. ${b.matricula}`}</p>
                      </td>
                      <td className="whitespace-nowrap px-5 py-3">
                        <span className="capitalize text-slate-500">{formatData(b.data, { weekday: 'short', day: '2-digit', month: '2-digit' })}</span>{' '}
                        <BatidaChip batida={b} onAcao={acoes.abrirMenuBatida} />
                      </td>
                      <td className={clsx('px-5 py-3 tabular-nums', b.data_referencia !== b.data ? 'font-medium text-accent-700' : 'text-slate-400')}>
                        {formatData(b.data_referencia, { day: '2-digit', month: '2-digit' })}
                      </td>
                      <td className="px-5 py-3 text-slate-600">
                        {b.status === 'desconsiderada' ? '—' : rotuloMarcacao(b.sentido, b.turno)}
                        {(b.sentido_declarado || b.turno_declarado) && <span className="ml-1 text-[11px] text-slate-400">(classificada)</span>}
                      </td>
                      <td className="px-5 py-3">
                        <span className={clsx('inline-flex items-center gap-1.5 text-xs font-semibold', st.texto)}>
                          <span className={clsx('h-2 w-2 rounded-full', st.ponto)} />
                          {st.label}
                        </span>
                      </td>
                      <td className="max-w-[260px] px-5 py-3">
                        <p className="truncate text-slate-700" title={b.motivo ?? undefined}>{b.motivo ?? '—'}</p>
                        {b.observacao && <p className="truncate text-xs text-slate-400" title={b.observacao}>{b.observacao}</p>}
                      </td>
                      <td className="px-5 py-3 text-slate-500">{ORIGEM_BATIDA[b.origem] ?? b.origem}</td>
                      <td className="px-3 py-3">
                        <button
                          onClick={(e) => acoes.abrirMenuBatida(e, b)}
                          className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-slate-700"
                          aria-label="Ações da batida"
                        >
                          <MoreHorizontal className="h-4 w-4" />
                        </button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <ContextMenu menu={acoes.menu} onFechar={acoes.fecharMenu} />
      {acoes.modais}
    </div>
  );
}
