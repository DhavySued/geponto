import clsx from 'clsx';
import { AlertTriangle, CalendarDays, Clock, Fingerprint, Hourglass, Inbox, RefreshCw, Timer, UserX } from 'lucide-react';
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
import type { BatidaResumo, MeuDashboardData } from '@/lib/types';

type Preset = 'hoje' | 'semana' | 'mes' | 'mes_anterior';

function intervalo(preset: Preset) {
  const hoje = new Date();
  const ano = hoje.getFullYear();
  const mes = hoje.getMonth();
  switch (preset) {
    case 'hoje':
      return { ini: toISODate(hoje), fim: toISODate(hoje) };
    case 'semana':
      return { ini: toISODate(new Date(ano, mes, hoje.getDate() - 6)), fim: toISODate(hoje) };
    case 'mes_anterior':
      return { ini: toISODate(new Date(ano, mes - 1, 1)), fim: toISODate(new Date(ano, mes, 0)) };
    default:
      return { ini: toISODate(new Date(ano, mes, 1)), fim: toISODate(hoje) };
  }
}

const PRESETS: [Preset, string][] = [
  ['hoje', 'Hoje'],
  ['semana', '7 dias'],
  ['mes', 'Este mês'],
  ['mes_anterior', 'Mês anterior'],
];

function saudacao() {
  const h = new Date().getHours();
  return h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite';
}

/** Chip de uma marcação: entrada em verde, saída em cinza */
function ChipBatida({ b }: { b: BatidaResumo }) {
  return (
    <span
      title={rotuloMarcacao(b.sentido, b.turno)}
      className={clsx(
        'inline-flex items-baseline gap-1.5 rounded-lg px-2 py-0.5 font-mono text-[13px] font-semibold tabular-nums ring-1',
        b.sentido === 'E' ? 'bg-emerald-50 text-emerald-700 ring-emerald-200' : 'bg-slate-50 text-slate-700 ring-slate-200',
      )}
    >
      <span className="font-sans text-[10px] font-medium opacity-60">{siglaMarcacao(b.sentido, b.turno)}</span>
      {b.hora}
    </span>
  );
}

/** Dashboard de quem só enxerga os próprios dados (perfil com abrangência "somente o próprio"). */
export function MeuDashboard() {
  const { usuario, pode } = useAuth();
  const [preset, setPreset] = useState<Preset | null>('mes');
  const [periodo, setPeriodo] = useState(() => intervalo('mes'));
  const [dados, setDados] = useState<MeuDashboardData | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const hojeIso = toISODate(new Date());
  const periodoInvalido = !periodo.ini || !periodo.fim || periodo.ini > periodo.fim;

  const carregar = useCallback(async () => {
    if (!periodo.ini || !periodo.fim || periodo.ini > periodo.fim) return;
    setCarregando(true);
    setErro(null);
    try {
      setDados(await api<MeuDashboardData>('api_meu_dashboard', { p_ini: periodo.ini, p_fim: periodo.fim }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar o seu painel.');
    } finally {
      setCarregando(false);
    }
  }, [periodo]);

  useEffect(() => {
    carregar();
    const id = window.setInterval(carregar, 60_000);
    return () => window.clearInterval(id);
  }, [carregar]);

  const escolherPreset = (p: Preset) => {
    setPreset(p);
    setPeriodo(intervalo(p));
  };
  const mudarData = (campo: 'ini' | 'fim', valor: string) => {
    setPreset(null);
    setPeriodo((atual) => ({ ...atual, [campo]: valor }));
  };

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
  const emJornada = !!hoje?.batidas.length && hoje.batidas[hoje.batidas.length - 1].sentido === 'E';
  // Mais recentes primeiro
  const dias = [...(dados?.dias ?? [])].reverse();
  const totalBatidas = dias.reduce((s, d) => s + d.batidas.length, 0);

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
              : 'Suas marcações, suas horas e seu banco de horas.'}
          </p>
        </div>
        {pode('meu_ponto', 'editar') && dados?.pode_registrar && (
          <Link
            to="/meu-ponto"
            className="inline-flex h-10 items-center gap-2 self-start rounded-xl bg-accent-500 px-5 text-sm font-medium text-white transition hover:bg-accent-600 xl:self-auto"
          >
            <Timer className="h-4 w-4" /> Registrar ponto
          </Link>
        )}
      </div>

      {/* Filtro do período */}
      <div className="card flex flex-wrap items-end gap-3 p-4">
        <div className="flex rounded-xl bg-slate-100 p-1">
          {PRESETS.map(([k, label]) => (
            <button
              key={k}
              onClick={() => escolherPreset(k)}
              className={clsx(
                'rounded-lg px-3 py-1.5 text-xs font-medium transition',
                preset === k ? 'bg-primary-700 text-white' : 'text-slate-500 hover:text-slate-800',
              )}
            >
              {label}
            </button>
          ))}
        </div>
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500">
          De
          <input type="date" className="input h-9 w-40" value={periodo.ini} max={hojeIso}
            onChange={(e) => mudarData('ini', e.target.value)} />
        </label>
        <label className="flex flex-col gap-1 text-xs font-medium text-slate-500">
          Até
          <input type="date" className="input h-9 w-40" value={periodo.fim} max={hojeIso}
            onChange={(e) => mudarData('fim', e.target.value)} />
        </label>
        <Button variant="secondary" onClick={carregar} className="h-9 px-3" title="Atualizar" disabled={periodoInvalido}>
          <RefreshCw className={clsx('h-4 w-4', carregando && 'animate-spin')} />
        </Button>
        {periodoInvalido && <p className="pb-2 text-xs text-accent-700">A data inicial precisa ser anterior ou igual à final.</p>}
      </div>

      {erro && (
        <div className="flex items-start gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
          <p className="flex-1">{erro}</p>
          <button onClick={carregar} className="font-medium hover:underline">Tentar novamente</button>
        </div>
      )}

      <div className="grid gap-6 xl:grid-cols-3">
        {/* Batidas de hoje, em destaque */}
        <section className="card relative overflow-hidden p-6 xl:col-span-2">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 className="flex items-center gap-2 text-lg font-semibold text-slate-900">
                <Fingerprint className="h-5 w-5 text-primary-600" /> Batidas de hoje
              </h3>
              <p className="mt-0.5 text-sm capitalize text-slate-500">
                {formatData(hojeIso, { weekday: 'long', day: '2-digit', month: 'long' })}
                <span className="normal-case">
                  {' · '}
                  {dados?.colaborador.horario_hoje ? `previsto ${dados.colaborador.horario_hoje}` : 'sem jornada prevista hoje'}
                </span>
              </p>
            </div>
            {emJornada && <Badge tone="green" pulse>Em jornada</Badge>}
          </div>

          <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-4">
            {!hoje ? (
              Array.from({ length: 4 }, (_, i) => <div key={i} className="h-20 animate-pulse rounded-2xl bg-slate-100" />)
            ) : hoje.batidas.length ? (
              hoje.batidas.map((b) => (
                <div
                  key={b.id}
                  className={clsx(
                    'rounded-2xl px-4 py-3 ring-1',
                    b.sentido === 'E' ? 'bg-emerald-50 ring-emerald-200' : 'bg-slate-50 ring-slate-200',
                  )}
                >
                  <p className={clsx('text-xs font-medium', b.sentido === 'E' ? 'text-emerald-700' : 'text-slate-500')}>
                    {rotuloMarcacao(b.sentido, b.turno)}
                  </p>
                  <p className="mt-1 text-3xl font-semibold tabular-nums tracking-tight text-slate-900">{b.hora}</p>
                </div>
              ))
            ) : (
              <p className="col-span-full rounded-2xl border border-dashed border-slate-200 py-8 text-center text-sm text-slate-400">
                Nenhuma batida registrada hoje.
              </p>
            )}
          </div>

          {hoje && hoje.previsto_min > 0 && (
            <div className="mt-6">
              <div className="flex justify-between text-xs text-slate-500">
                <span>Trabalhado <strong className="font-semibold text-slate-800">{formatMinutos(hoje.trabalhado_min)}</strong></span>
                <span>Previsto {formatMinutos(hoje.previsto_min)}</span>
              </div>
              <div className="mt-1.5 h-2.5 overflow-hidden rounded-full bg-slate-100">
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

        <div className="grid gap-4">
          {!r || !bh ? (
            Array.from({ length: 2 }, (_, i) => <KpiSkeleton key={i} />)
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
            </>
          )}
        </div>
      </div>

      {/* Batidas realizadas no período */}
      <section className="card overflow-hidden">
        <header className="flex flex-wrap items-end justify-between gap-2 px-5 pb-3 pt-5">
          <div>
            <h3 className="flex items-center gap-2 text-lg font-semibold text-slate-900">
              <CalendarDays className="h-5 w-5 text-primary-600" /> Batidas realizadas
            </h3>
            <p className="mt-0.5 text-xs text-slate-500">
              {dados
                ? `${formatData(dados.periodo.inicio, { day: '2-digit', month: '2-digit', year: 'numeric' })} a ${formatData(dados.periodo.fim, { day: '2-digit', month: '2-digit', year: 'numeric' })} · mais recentes primeiro`
                : 'Marcações de cada dia do período'}
            </p>
          </div>
          {dados && <span className="text-xs text-slate-500">{numero(totalBatidas)} batida(s)</span>}
        </header>
        <div className="max-h-[560px] overflow-auto">
          <table className="w-full min-w-[620px] text-sm">
            <thead className="sticky top-0 z-10 bg-slate-50 text-left text-xs text-slate-500">
              <tr>
                <th className="px-5 py-2 font-medium">Dia</th>
                <th className="px-3 py-2 font-medium">Batidas</th>
                <th className="px-3 py-2 text-right font-medium">Trabalhado</th>
                <th className="px-3 py-2 text-right font-medium">Saldo</th>
                <th className="px-5 py-2 font-medium">Situação</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {dias.length === 0 && (
                <tr>
                  <td colSpan={5} className="px-5 py-10 text-center text-sm text-slate-400">
                    {carregando ? 'Carregando…' : 'Nenhum dia no período.'}
                  </td>
                </tr>
              )}
              {dias.map((d) => {
                const oc = ocorrencia(d.ocorrencia ?? 'normal');
                const ehHoje = d.data === dados?.periodo.hoje;
                return (
                  <tr key={d.data} className={clsx(ehHoje && 'bg-primary-50/40')}>
                    <td className="whitespace-nowrap px-5 py-3 text-slate-700">
                      <span className="font-medium tabular-nums">{formatData(d.data)}</span>{' '}
                      <span className="text-xs capitalize text-slate-400">{formatData(d.data, { weekday: 'short' }).replace('.', '')}</span>
                      {ehHoje && <span className="ml-2 rounded bg-primary-700 px-1.5 py-0.5 text-[10px] font-semibold text-white">HOJE</span>}
                    </td>
                    <td className="px-3 py-3">
                      {d.batidas.length ? (
                        <div className="flex flex-wrap gap-1.5">
                          {d.batidas.map((b) => <ChipBatida key={b.id} b={b} />)}
                        </div>
                      ) : (
                        <span className="text-slate-300">—</span>
                      )}
                    </td>
                    <td className="px-3 py-3 text-right tabular-nums text-slate-700">
                      {d.trabalhado_min ? formatMinutos(d.trabalhado_min) : '—'}
                    </td>
                    <td className={clsx('px-3 py-3 text-right font-medium tabular-nums',
                      d.saldo_min > 0 ? 'text-primary-600' : d.saldo_min < 0 ? 'text-accent-700' : 'text-slate-400')}>
                      {d.saldo_min ? formatMinutos(d.saldo_min, true) : '—'}
                    </td>
                    <td className="px-5 py-3"><Badge tone={oc.tone}>{oc.label}</Badge></td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  );
}
