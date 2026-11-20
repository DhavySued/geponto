import clsx from 'clsx';
import { AlertTriangle, MapPinned, Printer, Search } from 'lucide-react';
import { useMemo, useState } from 'react';
import { EnderecoLink } from '@/components/ponto/Geo';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { semearEnderecos } from '@/lib/enderecos';
import { formatData } from '@/lib/format';
import { GEO_STATUS, textoDistancia } from '@/lib/geo';
import { competencia, useFiltrosAux, opcoesColaboradores, paramColaboradores } from '@/lib/hooks';
import { ORIGEM_BATIDA } from '@/lib/ponto';
import { api } from '@/lib/api';
import type { GeoStatus, LocaisBatidasRelatorio } from '@/lib/types';

const SITUACOES: { valor: GeoStatus; label: string }[] = [
  { valor: 'dentro', label: 'No local' },
  { valor: 'fora', label: 'Fora do local' },
  { valor: 'registrada', label: 'Com localização (sem local cadastrado)' },
  { valor: 'sem_localizacao', label: 'Sem localização' },
];

export default function LocaisBatidas() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ local: '', situacao: '' as GeoStatus | '', colaboradores: [] as string[], departamento: '' });
  const [dados, setDados] = useState<LocaisBatidasRelatorio | null>(null);
  const [ver, setVer] = useState<GeoStatus | ''>('');
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      const r = await api<LocaisBatidasRelatorio>('api_relatorio_locais_batidas', {
        p_ini: periodo.ini,
        p_fim: periodo.fim,
        p_local: filtros.local || null,
        p_situacao: filtros.situacao || null,
        p_colaboradores: paramColaboradores(filtros.colaboradores),
        p_departamento: filtros.departamento || null,
      });
      semearEnderecos(r.itens);
      setDados(r);
      setVer('');
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  const contagem = useMemo(() => {
    const c: Partial<Record<GeoStatus, number>> = {};
    for (const i of dados?.itens ?? []) c[i.geo_status] = (c[i.geo_status] ?? 0) + 1;
    return c;
  }, [dados]);
  const visiveis = (dados?.itens ?? []).filter((i) => !ver || i.geo_status === ver);
  const chip = (ativo: boolean) =>
    clsx('rounded-xl px-3 py-2 text-xs font-medium ring-1 transition print:hidden',
      ativo ? 'bg-primary-700 text-white ring-primary-700' : 'bg-white text-slate-600 ring-slate-200 hover:bg-slate-50');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Locais das batidas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Onde cada ponto foi registrado pelo sistema: endereço, local de ponto mais próximo e distância. Clique no endereço para abrir o mapa.
          </p>
        </div>
        {dados && dados.itens.length > 0 && (
          <Button variant="secondary" onClick={() => window.print()} className="print:hidden">
            <Printer className="h-4 w-4" /> Imprimir
          </Button>
        )}
      </div>

      <section className="card p-5 print:hidden">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-[160px_160px_1fr_1fr_1fr_1fr_auto] xl:items-end">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="Local de ponto">
            <select className="input" value={filtros.local} onChange={(e) => setFiltros((f) => ({ ...f, local: e.target.value }))}>
              <option value="">Todos</option>
              {aux?.locais?.map((l) => <option key={l.id} value={l.id}>{l.nome}{l.ativo ? '' : ' (inativo)'}</option>)}
            </select>
          </Field>
          <Field label="Situação">
            <select className="input" value={filtros.situacao} onChange={(e) => setFiltros((f) => ({ ...f, situacao: e.target.value as GeoStatus | '' }))}>
              <option value="">Todas</option>
              {SITUACOES.map((s) => <option key={s.valor} value={s.valor}>{s.label}</option>)}
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
          <Button onClick={consultar} loading={carregando}>
            <Search className="h-4 w-4" /> Consultar
          </Button>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card">
          <EmptyState icon={MapPinned} titulo="Escolha os filtros e clique em Consultar" descricao="Entram as batidas registradas pelo sistema (Meu Ponto e quiosque); as do relógio e as manuais não têm localização." />
        </div>
      ) : dados.itens.length === 0 ? (
        <div className="card">
          <EmptyState icon={MapPinned} titulo="Nenhuma batida encontrada" descricao="Não há batidas registradas pelo sistema com esses filtros." />
        </div>
      ) : (
        <>
          <p className="hidden text-sm text-slate-600 print:block">
            Período de {formatData(periodo.ini)} a {formatData(periodo.fim)} · {visiveis.length} batida(s)
          </p>
          <div className="flex flex-wrap gap-2">
            <button onClick={() => setVer('')} className={chip(!ver)}>Todas · {dados.itens.length}</button>
            {SITUACOES.filter((s) => contagem[s.valor]).map((s) => (
              <button key={s.valor} onClick={() => setVer(s.valor)} className={chip(ver === s.valor)}>
                {GEO_STATUS[s.valor].label} · {contagem[s.valor]}
              </button>
            ))}
          </div>

          <div className="card overflow-x-auto print:overflow-visible print:shadow-none print:ring-0">
            <table className="w-full min-w-[900px] text-sm print:min-w-0 print:text-xs">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-4 py-2.5 font-medium">Data e hora</th>
                  <th className="px-4 py-2.5 font-medium">Colaborador</th>
                  <th className="px-4 py-2.5 font-medium">Situação</th>
                  <th className="px-4 py-2.5 font-medium">Local de ponto</th>
                  <th className="px-4 py-2.5 font-medium">Endereço da batida</th>
                  <th className="px-4 py-2.5 text-right font-medium">Precisão</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {visiveis.map((i) => {
                  const st = GEO_STATUS[i.geo_status];
                  return (
                    <tr key={i.id} className="break-inside-avoid align-top">
                      <td className="whitespace-nowrap px-4 py-2.5 tabular-nums">
                        <p className="capitalize text-slate-700">{formatData(i.data, { weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric' })}</p>
                        <p className="text-xs text-slate-400">{i.hora} · {ORIGEM_BATIDA[i.origem] ?? i.origem}</p>
                      </td>
                      <td className="px-4 py-2.5">
                        <p className="font-medium text-slate-800">{i.nome}</p>
                        <p className="text-xs text-slate-400">Mat. {i.matricula}{i.departamento && ` · ${i.departamento}`}</p>
                      </td>
                      <td className="px-4 py-2.5"><Badge tone={st.tone} dot={false}>{st.label}</Badge></td>
                      <td className="px-4 py-2.5 text-xs text-slate-600">
                        {i.local ? (
                          <>
                            <p className="font-medium text-slate-700">{i.local}</p>
                            {i.distancia_m != null && <p className="text-slate-400">a {textoDistancia(i.distancia_m)}</p>}
                          </>
                        ) : (
                          <span className="text-slate-300">—</span>
                        )}
                      </td>
                      <td className="max-w-[340px] px-4 py-2.5 text-xs">
                        {i.latitude != null && i.longitude != null ? (
                          <EnderecoLink lat={i.latitude} lng={i.longitude} />
                        ) : (
                          <span className="text-slate-400">{i.geo_erro ?? 'Sem localização'}</span>
                        )}
                      </td>
                      <td className="whitespace-nowrap px-4 py-2.5 text-right text-xs tabular-nums text-slate-500">
                        {i.precisao_m != null ? textoDistancia(i.precisao_m) : '—'}
                      </td>
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
