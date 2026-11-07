import clsx from 'clsx';
import { AlertTriangle, CheckCircle2, ClipboardCheck, Lock, LockOpen, Search } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { useToast } from '@/components/ui/Toast';
import { formatData, numero, toISODate } from '@/lib/format';
import { competencia } from '@/lib/hooks';
import { ocorrencia } from '@/lib/ponto';
import { api } from '@/lib/supabase';
import type { Fechamento as FechamentoT, PreviaFechamento } from '@/lib/types';

const dataCurta = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });

function Indicador({ titulo, valor, alerta }: { titulo: string; valor: number; alerta: boolean }) {
  return (
    <div className={clsx('rounded-xl p-4 ring-1', alerta ? 'bg-accent-50 ring-accent-200' : 'bg-emerald-50/60 ring-emerald-200')}>
      <p className="text-xs text-slate-500">{titulo}</p>
      <p className={clsx('mt-1 text-2xl font-semibold tabular-nums', alerta ? 'text-accent-700' : 'text-emerald-700')}>{numero(valor)}</p>
    </div>
  );
}

export default function Fechamento() {
  const toast = useToast();
  const [dados, setDados] = useState<{ pode_editar: boolean; fechamentos: FechamentoT[] } | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [periodo, setPeriodo] = useState(() => competencia(-1));
  const [previa, setPrevia] = useState<PreviaFechamento | null>(null);
  const [verificando, setVerificando] = useState(false);
  const [observacao, setObservacao] = useState('');
  const [mesmoAssim, setMesmoAssim] = useState(false);
  const [fechando, setFechando] = useState(false);
  const [erroFechar, setErroFechar] = useState<string | null>(null);
  const [reabrindo, setReabrindo] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setDados(await api('api_fechamentos_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const verificar = async () => {
    setVerificando(true);
    setErroFechar(null);
    setMesmoAssim(false);
    try {
      setPrevia(await api<PreviaFechamento>('api_fechamento_previa', { p_ini: periodo.ini, p_fim: periodo.fim }));
    } catch (e) {
      setErroFechar(e instanceof Error ? e.message : 'Erro ao verificar.');
    } finally {
      setVerificando(false);
    }
  };

  const fechar = async () => {
    setFechando(true);
    setErroFechar(null);
    try {
      await api('api_fechamento_fechar', { p_ini: periodo.ini, p_fim: periodo.fim, p_observacao: observacao || null });
      toast('Período fechado. O ponto desses dias não pode mais ser alterado.');
      setPrevia(null);
      setObservacao('');
      carregar();
    } catch (e) {
      setErroFechar(e instanceof Error ? e.message : 'Erro ao fechar.');
    } finally {
      setFechando(false);
    }
  };

  const reabrir = async (id: string) => {
    try {
      await api('api_fechamento_reabrir', { p_id: id });
      toast('Período reaberto e recalculado.');
      setReabrindo(null);
      setPrevia(null); // a verificação anterior pode dizer que o período ainda está fechado
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao reabrir.', 'erro');
    }
  };

  const r = previa?.resumo;
  const pendencias = r ? r.inconsistentes + r.faltas + r.sem_jornada : 0;
  const ontem = toISODate(new Date(Date.now() - 86400000));

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Fechamento de período</h2>
        <p className="mt-1 text-sm text-slate-500">
          Confira as pendências da competência e feche o período: batidas, ocorrências e banco de horas desses dias ficam congelados para a folha.
        </p>
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {dados?.pode_editar && (
        <section className="card p-5">
          <h3 className="text-[15px] font-semibold text-slate-900">Novo fechamento</h3>
          <div className="mt-4 grid gap-4 sm:grid-cols-[180px_180px_auto] sm:items-end">
            <Field label="De">
              <input type="date" className="input" value={periodo.ini} max={periodo.fim}
                onChange={(e) => { if (e.target.value) { setPeriodo((p) => ({ ...p, ini: e.target.value })); setPrevia(null); } }} />
            </Field>
            <Field label="Até">
              <input type="date" className="input" value={periodo.fim} min={periodo.ini} max={ontem}
                onChange={(e) => { if (e.target.value) { setPeriodo((p) => ({ ...p, fim: e.target.value })); setPrevia(null); } }} />
            </Field>
            <div>
              <Button variant="secondary" onClick={verificar} loading={verificando}>
                <Search className="h-4 w-4" /> Verificar pendências
              </Button>
            </div>
          </div>

          <div className="mt-4"><AlertaErro mensagem={erroFechar} /></div>

          {previa && r && (
            <div className="space-y-4">
              {r.ja_fechado && (
                <div className="flex items-center gap-2 rounded-xl bg-rose-50 p-3 text-sm text-rose-700 ring-1 ring-rose-200">
                  <Lock className="h-4 w-4" /> Parte deste período já está fechada. Ajuste as datas.
                </div>
              )}
              <div className="grid gap-3 sm:grid-cols-3">
                <Indicador titulo="Marcações ímpares" valor={r.inconsistentes} alerta={r.inconsistentes > 0} />
                <Indicador titulo="Faltas sem justificativa" valor={r.faltas} alerta={r.faltas > 0} />
                <Indicador titulo="Dias sem jornada" valor={r.sem_jornada} alerta={r.sem_jornada > 0} />
              </div>

              {previa.pendencias.length > 0 && (
                <div className="max-h-72 overflow-auto rounded-xl ring-1 ring-slate-200">
                  <table className="w-full text-sm">
                    <thead className="sticky top-0 bg-slate-50 text-left text-xs text-slate-400">
                      <tr>
                        <th className="px-4 py-2 font-medium">Colaborador</th>
                        <th className="px-4 py-2 font-medium">Dia</th>
                        <th className="px-4 py-2 font-medium">Pendência</th>
                        <th className="px-4 py-2 text-right font-medium">Batidas</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-slate-100">
                      {previa.pendencias.map((p) => {
                        const oc = ocorrencia(p.ocorrencia);
                        return (
                          <tr key={`${p.colaborador_id}-${p.data}`}>
                            <td className="px-4 py-2 text-slate-700">{p.nome} <span className="text-xs text-slate-400">· {p.matricula}</span></td>
                            <td className="px-4 py-2 capitalize tabular-nums text-slate-600">
                              {formatData(p.data, { weekday: 'short', day: '2-digit', month: '2-digit' })}
                            </td>
                            <td className="px-4 py-2"><Badge tone={oc.tone} dot={false}>{oc.label}</Badge></td>
                            <td className="px-4 py-2 text-right tabular-nums text-slate-500">{p.qtd_batidas}</td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}

              {pendencias > 0 ? (
                <p className="text-xs text-slate-500">
                  Trate as pendências em <Link className="font-medium text-primary-600 hover:underline" to="/movimentos/consulta-batidas">Consulta de batidas</Link> e{' '}
                  <Link className="font-medium text-primary-600 hover:underline" to="/movimentos/ocorrencias">Ocorrências</Link> antes de fechar.
                </p>
              ) : (
                <p className="flex items-center gap-2 text-sm text-emerald-700">
                  <CheckCircle2 className="h-4 w-4" /> Nenhuma pendência em {numero(r.colaboradores)} colaborador(es).
                </p>
              )}

              <div className="grid gap-4 border-t border-slate-100 pt-4 sm:grid-cols-[1fr_auto] sm:items-end">
                <Field label="Observação">
                  <input className="input" value={observacao} placeholder={`Ex.: Competência ${formatData(periodo.ini, { month: 'long', year: 'numeric' })}`}
                    onChange={(e) => setObservacao(e.target.value)} />
                </Field>
                <div className="flex flex-col items-end gap-2">
                  {pendencias > 0 && (
                    <label className="flex items-center gap-2 text-xs text-slate-600">
                      <input type="checkbox" className="h-4 w-4 accent-primary-700" checked={mesmoAssim} onChange={(e) => setMesmoAssim(e.target.checked)} />
                      Fechar mesmo com pendências
                    </label>
                  )}
                  <Button onClick={fechar} loading={fechando} disabled={r.ja_fechado || (pendencias > 0 && !mesmoAssim)}>
                    <Lock className="h-4 w-4" /> Fechar período
                  </Button>
                </div>
              </div>
            </div>
          )}
        </section>
      )}

      <section className="card overflow-hidden">
        <header className="border-b border-slate-100 px-5 py-4">
          <h3 className="text-[15px] font-semibold text-slate-900">Períodos fechados</h3>
        </header>
        {dados === null ? (
          <div className="h-40 animate-pulse" />
        ) : dados.fechamentos.length === 0 ? (
          <EmptyState compacto icon={ClipboardCheck} titulo="Nenhum período fechado"
            descricao="Feche cada competência depois de tratar as batidas, para que a folha use números definitivos." />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[640px] text-sm">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-5 py-2.5 font-medium">Período</th>
                  <th className="px-5 py-2.5 font-medium">Observação</th>
                  <th className="px-5 py-2.5 font-medium">Fechado por</th>
                  <th className="px-5 py-2.5" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {dados.fechamentos.map((f) => (
                  <tr key={f.id}>
                    <td className="whitespace-nowrap px-5 py-3 font-medium tabular-nums text-slate-800">
                      <Lock className="mr-2 inline h-3.5 w-3.5 text-slate-400" />
                      {dataCurta(f.data_inicio)} a {dataCurta(f.data_fim)}
                    </td>
                    <td className="px-5 py-3 text-slate-500">{f.observacao ?? '—'}</td>
                    <td className="px-5 py-3 text-xs text-slate-500">
                      {f.usuario ?? '—'} · {new Date(f.created_at).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}
                    </td>
                    <td className="px-5 py-3 text-right">
                      {dados.pode_editar && (
                        reabrindo === f.id ? (
                          <span className="flex items-center justify-end gap-1 text-xs">
                            <span className="text-slate-500">Reabrir e recalcular?</span>
                            <button className="rounded-lg px-2 py-1 font-medium text-rose-600 hover:bg-rose-50" onClick={() => reabrir(f.id)}>Sim</button>
                            <button className="rounded-lg px-2 py-1 text-slate-500 hover:bg-slate-100" onClick={() => setReabrindo(null)}>Não</button>
                          </span>
                        ) : (
                          <Button variant="ghost" className="h-8 px-3 text-xs" onClick={() => setReabrindo(f.id)}>
                            <LockOpen className="h-3.5 w-3.5" /> Reabrir
                          </Button>
                        )
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
