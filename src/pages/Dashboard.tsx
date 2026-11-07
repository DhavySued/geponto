import clsx from 'clsx';
import { AlarmClock, AlertTriangle, Hourglass, RefreshCw, UserCheck, UserX } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import { AbsenteismoChart } from '@/components/dashboard/AbsenteismoChart';
import { BancoHorasChart } from '@/components/dashboard/BancoHorasChart';
import { KpiCard, KpiSkeleton } from '@/components/dashboard/KpiCard';
import { MeuDashboard } from '@/components/dashboard/MeuDashboard';
import { RankingAtrasos } from '@/components/dashboard/RankingAtrasos';
import { RegistrosHoje } from '@/components/dashboard/RegistrosHoje';
import { SituacaoColaboradores } from '@/components/dashboard/SituacaoColaboradores';
import { Button } from '@/components/ui/Button';
import { useAuth } from '@/contexts/AuthContext';
import { formatMinutos, numero, toISODate } from '@/lib/format';
import { api } from '@/lib/supabase';
import type { DashboardData } from '@/lib/types';

type Preset = 'mes' | 'mes_anterior' | '30d' | 'personalizado';

function intervalo(preset: Preset): { ini: string; fim: string } {
  const hoje = new Date();
  switch (preset) {
    case 'mes_anterior': {
      const ini = new Date(hoje.getFullYear(), hoje.getMonth() - 1, 1);
      const fim = new Date(hoje.getFullYear(), hoje.getMonth(), 0);
      return { ini: toISODate(ini), fim: toISODate(fim) };
    }
    case '30d': {
      const ini = new Date(hoje);
      ini.setDate(ini.getDate() - 29);
      return { ini: toISODate(ini), fim: toISODate(hoje) };
    }
    default:
      return { ini: toISODate(new Date(hoje.getFullYear(), hoje.getMonth(), 1)), fim: toISODate(hoje) };
  }
}

const PRESETS: { chave: Exclude<Preset, 'personalizado'>; label: string }[] = [
  { chave: 'mes', label: 'Este mês' },
  { chave: 'mes_anterior', label: 'Mês anterior' },
  { chave: '30d', label: 'Últimos 30 dias' },
];

function Painel({
  titulo,
  subtitulo,
  acao,
  children,
  className,
  semPadding = false,
}: {
  titulo: string;
  subtitulo?: string;
  acao?: ReactNode;
  children: ReactNode;
  className?: string;
  semPadding?: boolean;
}) {
  return (
    <section className={clsx('card', className)}>
      <header className="flex items-start justify-between gap-3 px-5 pb-4 pt-5">
        <div>
          <h2 className="text-[15px] font-semibold text-slate-900">{titulo}</h2>
          {subtitulo && <p className="mt-0.5 text-xs text-slate-500">{subtitulo}</p>}
        </div>
        {acao}
      </header>
      <div className={semPadding ? 'pb-2' : 'px-5 pb-5'}>{children}</div>
    </section>
  );
}

function saudacao() {
  const h = new Date().getHours();
  return h < 12 ? 'Bom dia' : h < 18 ? 'Boa tarde' : 'Boa noite';
}

/** Quem só enxerga os próprios dados vê o painel pessoal; os demais, o da equipe/empresa. */
export default function Dashboard() {
  const { usuario } = useAuth();
  return usuario?.perfil.abrangencia === 'proprio' ? <MeuDashboard /> : <DashboardGeral />;
}

function DashboardGeral() {
  const { usuario } = useAuth();
  const [preset, setPreset] = useState<Preset>('mes');
  const [periodo, setPeriodo] = useState(() => intervalo('mes'));
  const [dados, setDados] = useState<DashboardData | null>(null);
  const [carregando, setCarregando] = useState(true);
  const [erro, setErro] = useState<string | null>(null);
  const [atualizadoEm, setAtualizadoEm] = useState<Date | null>(null);

  const carregar = useCallback(async () => {
    setCarregando(true);
    setErro(null);
    try {
      const d = await api<DashboardData>('api_dashboard', { p_ini: periodo.ini, p_fim: periodo.fim });
      setDados(d);
      setAtualizadoEm(new Date());
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar o dashboard.');
    } finally {
      setCarregando(false);
    }
  }, [periodo]);

  useEffect(() => {
    carregar();
    const id = window.setInterval(carregar, 60_000); // batidas do dia quase em tempo real
    return () => window.clearInterval(id);
  }, [carregar]);

  const escolherPreset = (p: Exclude<Preset, 'personalizado'>) => {
    setPreset(p);
    setPeriodo(intervalo(p));
  };

  const r = dados?.resumo;
  const saldoLiquido = useMemo(
    () => (r ? r.banco_horas.saldo_positivo + r.banco_horas.saldo_negativo : 0),
    [r],
  );

  return (
    <div className="space-y-6">
      {/* Cabeçalho + filtro de período */}
      <div className="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">
            {saudacao()}, {usuario?.nome.split(' ')[0]} 👋
          </h2>
          <p className="mt-1 text-sm text-slate-500">
            {usuario?.perfil.abrangencia === 'equipe'
              ? 'Indicadores da sua equipe: jornada, banco de horas e absenteísmo.'
              : 'Acompanhe a jornada da equipe, o banco de horas e os indicadores de absenteísmo.'}
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-2">
          <div className="flex rounded-xl bg-white p-1 shadow-soft ring-1 ring-slate-200/70">
            {PRESETS.map((p) => (
              <button
                key={p.chave}
                onClick={() => escolherPreset(p.chave)}
                className={clsx(
                  'rounded-lg px-3 py-1.5 text-xs font-medium transition',
                  preset === p.chave ? 'bg-primary-700 text-white' : 'text-slate-500 hover:text-slate-800',
                )}
              >
                {p.label}
              </button>
            ))}
          </div>
          <div className="flex items-center gap-1.5 rounded-xl bg-white p-1 pl-2 shadow-soft ring-1 ring-slate-200/70">
            <input
              type="date"
              value={periodo.ini}
              max={periodo.fim}
              onChange={(e) => {
                if (!e.target.value) return;
                setPreset('personalizado');
                setPeriodo((p) => ({ ...p, ini: e.target.value }));
              }}
              className="h-7 rounded-md border-0 bg-transparent text-xs text-slate-600 focus:outline-none focus:ring-2 focus:ring-primary-100"
              aria-label="Data inicial"
            />
            <span className="text-xs text-slate-300">→</span>
            <input
              type="date"
              value={periodo.fim}
              min={periodo.ini}
              max={toISODate(new Date())}
              onChange={(e) => {
                if (!e.target.value) return;
                setPreset('personalizado');
                setPeriodo((p) => ({ ...p, fim: e.target.value }));
              }}
              className="h-7 rounded-md border-0 bg-transparent text-xs text-slate-600 focus:outline-none focus:ring-2 focus:ring-primary-100"
              aria-label="Data final"
            />
          </div>
          <Button variant="secondary" onClick={carregar} className="h-9 px-3" title="Atualizar">
            <RefreshCw className={clsx('h-4 w-4', carregando && 'animate-spin')} />
          </Button>
        </div>
      </div>

      {erro && (
        <div className="flex items-start gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
          <div className="flex-1">
            <p className="font-medium">Não foi possível carregar os indicadores.</p>
            <p className="mt-0.5 text-rose-600/80">{erro}</p>
          </div>
          <button onClick={carregar} className="font-medium underline-offset-2 hover:underline">
            Tentar novamente
          </button>
        </div>
      )}

      {/* KPIs */}
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {!r ? (
          Array.from({ length: 4 }, (_, i) => <KpiSkeleton key={i} />)
        ) : (
          <>
            <KpiCard
              destaque
              icon={UserCheck}
              titulo="Presentes hoje"
              valor={numero(r.hoje.presentes)}
              complemento={`de ${numero(r.hoje.previstos)} escalados`}
              rodape={
                <div>
                  <div className="h-1.5 overflow-hidden rounded-full bg-white/15">
                    <div
                      className="h-full rounded-full bg-accent-500"
                      style={{ width: `${r.hoje.previstos ? (r.hoje.presentes / r.hoje.previstos) * 100 : 0}%` }}
                    />
                  </div>
                  <p className="mt-2">{numero(r.hoje.batidas)} marcações registradas hoje</p>
                </div>
              }
            />
            <KpiCard
              icon={UserX}
              titulo="Faltas no período"
              valor={numero(r.periodo.faltas)}
              complemento={r.periodo.absenteismo_pct !== null ? `${r.periodo.absenteismo_pct.toLocaleString('pt-BR')}%` : undefined}
              rodape={
                <span>
                  Taxa de absenteísmo sobre {numero(r.periodo.dias_previstos)} dias escalados ·{' '}
                  <strong className="font-medium text-slate-700">{numero(r.hoje.ausentes)} ausentes hoje</strong>
                </span>
              }
            />
            <KpiCard
              icon={AlarmClock}
              titulo="Atrasos no período"
              valor={numero(r.periodo.atrasos)}
              complemento={formatMinutos(r.periodo.minutos_atraso)}
              rodape={
                <span>
                  Tempo total de atraso ·{' '}
                  <strong className="font-medium text-slate-700">{numero(r.hoje.atrasados)} atrasados hoje</strong>
                </span>
              }
            />
            <KpiCard
              icon={Hourglass}
              titulo="Saldo do banco de horas"
              valor={formatMinutos(saldoLiquido, true)}
              rodape={
                <div className="flex gap-4">
                  <span className="flex items-center gap-1.5">
                    <span className="h-2 w-2 rounded-sm bg-[#3b6fd8]" />
                    {formatMinutos(r.banco_horas.saldo_positivo, true)} ({r.banco_horas.qtd_positivos})
                  </span>
                  <span className="flex items-center gap-1.5">
                    <span className="h-2 w-2 rounded-sm bg-accent-500" />
                    {formatMinutos(r.banco_horas.saldo_negativo, true)} ({r.banco_horas.qtd_negativos})
                  </span>
                </div>
              }
            />
          </>
        )}
      </div>

      {/* Banco de horas + situação */}
      <div className="grid gap-6 xl:grid-cols-3">
        <Painel
          className="xl:col-span-2"
          titulo="Banco de horas por colaborador"
          subtitulo="Saldo acumulado até o fim do período selecionado"
        >
          {dados ? <BancoHorasChart dados={dados.banco_horas} /> : <div className="h-64 animate-pulse rounded-xl bg-slate-50" />}
        </Painel>

        <div className="grid gap-6">
          <Painel titulo="Situação dos colaboradores" subtitulo="Quadro atual">
            {r ? <SituacaoColaboradores situacoes={r.situacoes} /> : <div className="h-36 animate-pulse rounded-xl bg-slate-50" />}
          </Painel>
        </div>
      </div>

      {/* Absenteísmo */}
      <div className="grid gap-6 xl:grid-cols-3">
        <Painel
          className="xl:col-span-2"
          titulo="Faltas e atrasos por dia"
          subtitulo="Ocorrências diárias no período (dias úteis)"
        >
          {dados ? (
            <AbsenteismoChart dados={dados.absenteismo_diario} />
          ) : (
            <div className="h-64 animate-pulse rounded-xl bg-slate-50" />
          )}
        </Painel>
        <Painel titulo="Maiores atrasos" subtitulo="Top 5 por tempo acumulado no período">
          {dados ? <RankingAtrasos dados={dados.ranking_atrasos} /> : <div className="h-48 animate-pulse rounded-xl bg-slate-50" />}
        </Painel>
      </div>

      {/* Registros do dia */}
      <Painel
        titulo="Registros diários"
        subtitulo={
          atualizadoEm
            ? `Batidas de hoje · atualizado às ${atualizadoEm.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })}`
            : 'Batidas de hoje'
        }
        acao={
          <span className="flex items-center gap-1.5 rounded-full bg-emerald-50 px-2.5 py-1 text-[11px] font-medium text-emerald-700">
            <span className="relative flex h-1.5 w-1.5">
              <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-500 opacity-60" />
              <span className="relative h-1.5 w-1.5 rounded-full bg-emerald-500" />
            </span>
            Ao vivo
          </span>
        }
        semPadding
      >
        {dados ? <RegistrosHoje dados={dados.registros_hoje} /> : <div className="mx-5 mb-4 h-64 animate-pulse rounded-xl bg-slate-50" />}
      </Painel>
    </div>
  );
}
