import clsx from 'clsx';
import { AlarmClock, AlertTriangle, Clock, Hourglass, Inbox, RefreshCw, Timer, UserX } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { KpiCard, KpiSkeleton } from '@/components/dashboard/KpiCard';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, formatMinutos, numero, toISODate } from '@/lib/format';
import { ocorrencia, rotuloMarcacao, siglaMarcacao } from '@/lib/ponto';
import { api } from '@/lib/supabase';
import type { MeuDashboardData } from '@/lib/types';

type Preset = 'mes' | 'mes_anterior';

function intervalo(preset: Preset) {
  const hoje = new Date();
  if (preset === 'mes_anterior') {
    return {
      ini: toISODate(new Date(hoje.getFullYear(), hoje.getMonth() - 1, 1)),
      fim: toISODate(new Date(hoje.getFullYear(), hoje.getMonth(), 0)),
    };
  }
  return { ini: toISODate(new Date(hoje.getFullYear(), hoje.getMonth(), 1)), fim: toISODate(hoje) };
}

function saudacao() {
  const h = new Date().getHours();
  return h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite';
}

/** Dashboard de quem só enxerga os próprios dados (perfil com abrangência "somente o próprio"). */
export function MeuDashboard() {
  const { usuario, pode } = useAuth();
  const [preset, setPreset] = useState<Preset>('mes');
  const [dados, setDados] = useState<MeuDashboardData | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    setCarregando(true);
    setErro(null);
    const { ini, fim } = intervalo(preset);
    try {
      setDados(await api<MeuDashboardData>('api_meu_dashboard', { p_ini: ini, p_fim: fim }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar o seu painel.');
    } finally {
      setCarregando(false);
    }
  }, [preset]);

  useEffect(() => {
    carregar();
    const id = window.setInterval(carregar, 60_000);
    return () => window.clearInterval(id);
  }, [carregar]);

  if (dados && !dados.vinculado) {
    return (
      <div className="card">
        <EmptyState
          icon={UserX}
          titulo="Seu usuário não está vinculado a um colaborador"
          descricao="Peça ao RH para vincular o seu acesso ao seu cadastro em Usuários & Permissões."
        />
      </div>
    );
  }

  const r = dados?.resumo;
  const bh = dados?.banco_horas;
  const hoje = dados?.hoje;
  const progresso = hoje && hoje.previsto_min > 0 ? Math.min(100, (hoje.trabalhado_min / hoje.previsto_min) * 100) : 0;

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">
            {saudacao()}, {usuario?.nome.split(' ')[0]} 👋
          </h2>
          <p className="mt-1 text-sm text-slate-500">
            {dados
              ? [dados.colaborador.cargo, dados.colaborador.departamento, `mat. ${dados.colaborador.matricula}`].filter(Boolean).join(' · ')
              : 'Seu ponto, seu banco de horas e suas ocorrências.'}
          </p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex rounded-xl bg-white p-1 shadow-soft ring-1 ring-slate-200/70">
            {([
              ['mes', 'Este mês'],
              ['mes_anterior', 'Mês anterior'],
            ] as const).map(([k, label]) => (
              <button
                key={k}
                onClick={() => setPreset(k)}
                className={clsx(
                  'rounded-lg px-3 py-1.5 text-xs font-medium transition',
                  preset === k ? 'bg-primary-700 text-white' : 'text-slate-500 hover:text-slate-800',
                )}
              >
                {label}
              </button>
            ))}
          </div>
          <Button variant="secondary" onClick={carregar} className="h-9 px-3" title="Atualizar">
            <RefreshCw className={clsx('h-4 w-4', carregando && 'animate-spin')} />
          </Button>
          {pode('meu_ponto', 'editar') && dados?.pode_registrar && (
            <Link
              to="/meu-ponto"
              className="inline-flex h-9 items-center gap-2 rounded-xl bg-accent-500 px-4 text-sm font-medium text-white transition hover:bg-accent-600"
            >
              <Timer className="h-4 w-4" /> Registrar ponto
            </Link>
          )}
        </div>
      </div>

      {erro && (
        <div className="flex items-start gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
          <p className="flex-1">{erro}</p>
          <button onClick={carregar} className="font-medium hover:underline">Tentar novamente</button>
        </div>
      )}

      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {!r || !bh ? (
          Array.from({ length: 4 }, (_, i) => <KpiSkeleton key={i} />)
        ) : (
          <>
            <KpiCard
              destaque
              icon={Hourglass}
              titulo="Meu banco de horas"
              valor={formatMinutos(bh.saldo, true)}
              rodape={<span>No período: {formatMinutos(bh.periodo, true)} · saldo anterior {formatMinutos(bh.anterior, true)}</span>}
            />
            <KpiCard
              icon={Clock}
              titulo="Horas trabalhadas"
              valor={formatMinutos(r.trabalhado_min)}
              complemento={`de ${formatMinutos(r.previsto_min)}`}
              rodape={<span>{numero(r.dias_trabalhados)} dia(s) trabalhado(s) · extras {formatMinutos(r.extra_min)}</span>}
            />
            <KpiCard
              icon={AlarmClock}
              titulo="Atrasos"
              valor={numero(r.atrasos)}
              complemento={formatMinutos(r.minutos_atraso)}
              rodape={<span>Tempo total de atraso no período</span>}
            />
            <KpiCard
              icon={UserX}
              titulo="Faltas"
              valor={numero(r.faltas)}
              complemento={`de ${numero(r.dias_previstos)} dias`}
              rodape={
                r.inconsistencias > 0 ? (
                  <span className="font-medium text-accent-700">{r.inconsistencias} dia(s) com marcação ímpar</span>
                ) : (
                  <span>Dias previstos até ontem</span>
                )
              }
            />
          </>
        )}
      </div>

      <div className="grid gap-6 xl:grid-cols-3">
        {/* Hoje */}
        <section className="card p-5">
          <h3 className="text-[15px] font-semibold text-slate-900">Hoje</h3>
          <p className="mt-0.5 text-xs text-slate-500">
            {dados?.colaborador.horario_hoje ? `Horário previsto: ${dados.colaborador.horario_hoje}` : 'Sem jornada prevista hoje'}
          </p>
          <div className="mt-5 flex flex-wrap gap-2">
            {hoje?.batidas.length ? (
              hoje.batidas.map((b) => (
                <span key={b.id} title={rotuloMarcacao(b.sentido, b.turno)} className={clsx('rounded-lg px-2.5 py-1 font-mono text-sm font-semibold ring-1',
                  b.sentido === 'E' ? 'bg-emerald-50 text-emerald-700 ring-emerald-200' : 'bg-slate-50 text-slate-700 ring-slate-200')}>
                  <span className="mr-1.5 font-sans text-[10px] opacity-60">{siglaMarcacao(b.sentido, b.turno)}</span>
                  {b.hora}
                </span>
              ))
            ) : (
              <span className="text-sm text-slate-400">Nenhuma marcação hoje.</span>
            )}
          </div>
          {hoje && (
            <div className="mt-5">
              <div className="flex justify-between text-xs text-slate-500">
                <span>Trabalhado {formatMinutos(hoje.trabalhado_min)}</span>
                <span>Previsto {formatMinutos(hoje.previsto_min)}</span>
              </div>
              <div className="mt-1.5 h-2 overflow-hidden rounded-full bg-slate-100">
                <div className="h-full rounded-full bg-primary-600 transition-all" style={{ width: `${progresso}%` }} />
              </div>
            </div>
          )}
          {!!dados?.solicitacoes_pendentes && (
            <Link to="/meu-ponto" className="mt-5 flex items-center gap-2 rounded-xl bg-sky-50 px-3 py-2 text-xs text-sky-800 ring-1 ring-sky-200">
              <Inbox className="h-4 w-4" />
              {dados.solicitacoes_pendentes} solicitação(ões) aguardando o gestor
            </Link>
          )}
        </section>

        {/* Dias do período */}
        <section className="card overflow-hidden xl:col-span-2">
          <header className="px-5 pb-3 pt-5">
            <h3 className="text-[15px] font-semibold text-slate-900">Meus dias</h3>
            <p className="mt-0.5 text-xs text-slate-500">Marcações, horas e saldo de cada dia do período</p>
          </header>
          <div className="max-h-[420px] overflow-auto">
            <table className="w-full min-w-[560px] text-sm">
              <thead className="sticky top-0 bg-slate-50 text-left text-xs text-slate-500">
                <tr>
                  <th className="px-5 py-2 font-medium">Dia</th>
                  <th className="px-3 py-2 font-medium">Marcações</th>
                  <th className="px-3 py-2 text-right font-medium">Trabalhado</th>
                  <th className="px-3 py-2 text-right font-medium">Saldo</th>
                  <th className="px-5 py-2 font-medium">Situação</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {(dados?.dias ?? []).map((d) => {
                  const oc = ocorrencia(d.ocorrencia ?? 'normal');
                  return (
                    <tr key={d.data}>
                      <td className="whitespace-nowrap px-5 py-2 text-slate-700">
                        <span className="tabular-nums">{formatData(d.data)}</span>{' '}
                        <span className="text-xs capitalize text-slate-400">{formatData(d.data, { weekday: 'short' }).replace('.', '')}</span>
                      </td>
                      <td className="px-3 py-2 font-mono text-xs text-slate-600">
                        {d.batidas.length ? (
                          d.batidas.map((b) => (
                            <span key={b.id} className="mr-2 whitespace-nowrap" title={rotuloMarcacao(b.sentido, b.turno)}>
                              <span className="font-sans text-[10px] text-slate-400">{siglaMarcacao(b.sentido, b.turno)}</span> {b.hora}
                            </span>
                          ))
                        ) : (
                          <span className="text-slate-300">—</span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums text-slate-700">
                        {d.trabalhado_min ? formatMinutos(d.trabalhado_min) : '—'}
                      </td>
                      <td className={clsx('px-3 py-2 text-right tabular-nums',
                        d.saldo_min > 0 ? 'text-primary-600' : d.saldo_min < 0 ? 'text-accent-700' : 'text-slate-400')}>
                        {d.saldo_min ? formatMinutos(d.saldo_min, true) : '—'}
                      </td>
                      <td className="px-5 py-2"><Badge tone={oc.tone}>{oc.label}</Badge></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </div>
  );
}
