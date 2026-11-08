import clsx from 'clsx';
import { AlertTriangle, CheckCircle2, Fingerprint, Hourglass, Info, Timer, UserX } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { formatData, formatMinutos } from '@/lib/format';
import { ocorrencia, ORIGEM_BATIDA, rotuloMarcacao } from '@/lib/ponto';
import { useHoraOficial } from '@/lib/hooks';
import { api } from '@/lib/supabase';
import type { MeuPontoData, RegistroPonto } from '@/lib/types';

function Indicador({ titulo, valor, detalhe, icon: Icon }: { titulo: string; valor: string; detalhe?: string; icon: typeof Timer }) {
  return (
    <div className="card p-5">
      <div className="flex items-center justify-between">
        <p className="text-sm font-medium text-slate-500">{titulo}</p>
        <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-primary-50 text-primary-600">
          <Icon className="h-4 w-4" />
        </span>
      </div>
      <p className="mt-2 text-2xl font-semibold tabular-nums tracking-tight text-slate-900">{valor}</p>
      {detalhe && <p className="mt-1 text-xs text-slate-400">{detalhe}</p>}
    </div>
  );
}

export default function MeuPonto() {
  const [dados, setDados] = useState<MeuPontoData | null>(null);
  const [carregadoEm, setCarregadoEm] = useState(() => Date.now());
  const [erro, setErro] = useState<string | null>(null);
  const [registrando, setRegistrando] = useState(false);
  const [comprovante, setComprovante] = useState<RegistroPonto | null>(null);
  const { agora, fuso } = useHoraOficial();

  const carregar = useCallback(async () => {
    try {
      const d = await api<MeuPontoData>('api_meu_ponto');
      setDados(d);
      setCarregadoEm(Date.now());
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const registrar = async () => {
    setErro(null);
    setRegistrando(true);
    try {
      const r = await api<RegistroPonto>('api_registrar_ponto');
      setComprovante(r);
      await carregar();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Não foi possível registrar o ponto.');
    } finally {
      setRegistrando(false);
    }
  };

  if (dados && !dados.vinculado) {
    return (
      <div className="card">
        <EmptyState
          icon={UserX}
          titulo="Seu usuário não está vinculado a um colaborador"
          descricao="Para registrar ponto, o acesso precisa ser criado no cadastro do colaborador (aba “Acesso ao ponto”)."
        />
      </div>
    );
  }

  const hoje = dados?.hoje;
  // Só uma previsão para orientar o colaborador; a classificação final é do servidor/RH
  const ultima = hoje?.batidas[hoje.batidas.length - 1];
  const proxima = !ultima
    ? rotuloMarcacao('E', 1)
    : ultima.sentido === 'E'
      ? rotuloMarcacao('S', ultima.turno)
      : rotuloMarcacao('E', ultima.turno + 1);
  // Mesmo critério do servidor (fn_trabalhado_ao_vivo): a última batida do dia é uma entrada
  const emJornada = ultima?.sentido === 'E';
  // Enquanto está em jornada, o trabalhado do dia continua contando na tela
  const trabalhado = (hoje?.trabalhado_min ?? 0) + (emJornada ? Math.floor((agora.getTime() - carregadoEm) / 60000) : 0);
  const jd = hoje?.jornada_dia;

  return (
    <div className="space-y-6">
      <div className="grid gap-6 xl:grid-cols-[1.25fr_1fr]">
        {/* Relógio + botão */}
        <section className="card relative overflow-hidden bg-primary-700 p-6 text-white ring-0 sm:p-8 [background-image:radial-gradient(110%_80%_at_100%_0%,rgba(243,146,0,0.30),transparent_55%)]">
          <p className="text-sm text-white/70">
            {dados ? `Olá, ${dados.colaborador.nome.split(' ')[0]}` : 'Carregando…'}
          </p>
          <p className="mt-1 text-sm capitalize text-white/60">
            {agora.toLocaleDateString('pt-BR', { weekday: 'long', day: '2-digit', month: 'long', year: 'numeric', timeZone: fuso })}
          </p>
          <p className="mt-4 text-5xl font-semibold tabular-nums tracking-tight sm:text-6xl">
            {agora.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit', timeZone: fuso })}
            <span className="text-2xl text-white/50 sm:text-3xl">:{String(agora.getSeconds()).padStart(2, '0')}</span>
          </p>

          <div className="mt-6 flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-white/70">
            <span>
              Jornada: <strong className="font-medium text-white">{dados?.colaborador.jornada ?? '—'}</strong>
            </span>
            {jd && !jd.folga && (
              <span className="tabular-nums">
                Hoje: {jd.entrada}
                {jd.saida_intervalo && ` – ${jd.saida_intervalo} · ${jd.retorno_intervalo}`} – {jd.saida}
              </span>
            )}
            {jd?.folga && <span>Hoje é sua folga</span>}
          </div>

          <div className="mt-8">
            {dados && !dados.pode_registrar ? (
              <div className="flex items-start gap-3 rounded-xl bg-white/10 p-4 text-sm">
                <Info className="mt-0.5 h-4 w-4 shrink-0 text-accent-400" />
                {dados.motivo}
              </div>
            ) : (
              <>
                <Button
                  variant="accent"
                  onClick={registrar}
                  loading={registrando}
                  disabled={!dados}
                  className="h-14 w-full gap-3 rounded-2xl text-base font-semibold shadow-lg shadow-black/20 sm:w-auto sm:px-10"
                >
                  {!registrando && <Fingerprint className="h-5 w-5" />}
                  Registrar ponto
                </Button>
                <p className="mt-3 text-xs text-white/60">
                  Próxima marcação: {proxima.toLowerCase()} · registrada no horário oficial de Brasília
                </p>
              </>
            )}
          </div>

          {erro && (
            <div className="mt-4 flex items-start gap-2 rounded-xl bg-rose-500/20 p-3 text-sm text-white ring-1 ring-rose-300/40">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" /> {erro}
            </div>
          )}
        </section>

        {/* Marcações do dia */}
        <section className="card p-6">
          <div className="flex items-center justify-between">
            <h2 className="text-[15px] font-semibold text-slate-900">Marcações de hoje</h2>
            {emJornada && <Badge tone="green" pulse>Em jornada</Badge>}
          </div>

          {comprovante && (
            <div className="mt-4 flex items-start gap-3 rounded-xl bg-emerald-50 p-4 text-sm ring-1 ring-emerald-200">
              <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-emerald-600" />
              <div className="text-emerald-800">
                <p className="font-semibold">Ponto registrado: {comprovante.tipo.toLowerCase()} às {comprovante.hora}</p>
                <p className="mt-0.5 text-xs text-emerald-700/80">
                  Comprovante · {formatData(comprovante.data, { day: '2-digit', month: '2-digit', year: 'numeric' })} · NSR{' '}
                  {String(comprovante.nsr).padStart(9, '0')}
                </p>
              </div>
            </div>
          )}

          {!hoje || hoje.batidas.length === 0 ? (
            <p className="py-10 text-center text-sm text-slate-400">Nenhuma marcação registrada hoje.</p>
          ) : (
            <ol className="relative mt-5 space-y-4 border-l border-slate-200 pl-6">
              {hoje.batidas.map((b, i) => (
                <li key={b.id} className="relative">
                  <span
                    className={clsx(
                      'absolute -left-[29px] top-1 h-3 w-3 rounded-full ring-4 ring-white',
                      i % 2 === 0 ? 'bg-primary-600' : 'bg-accent-500',
                    )}
                  />
                  <div className="flex items-baseline justify-between gap-3">
                    <p className="text-sm font-medium text-slate-700">{rotuloMarcacao(b.sentido, b.turno)}</p>
                    <p className="text-lg font-semibold tabular-nums text-slate-900">{b.hora}</p>
                  </div>
                  <p className="text-[11px] text-slate-400">
                    {ORIGEM_BATIDA[b.origem] ?? b.origem}
                    {b.nsr != null && ` · NSR ${String(b.nsr).padStart(9, '0')}`}
                  </p>
                </li>
              ))}
            </ol>
          )}
        </section>
      </div>

      <div className="grid gap-4 sm:grid-cols-3">
        <Indicador icon={Timer} titulo="Trabalhado hoje" valor={formatMinutos(trabalhado)}
          detalhe={emJornada ? 'Contando até agora' : undefined} />
        <Indicador icon={Fingerprint} titulo="Previsto hoje" valor={formatMinutos(hoje?.previsto_min ?? 0)}
          detalhe={jd?.folga ? 'Folga' : undefined} />
        <Indicador icon={Hourglass} titulo="Banco de horas" valor={formatMinutos(dados?.saldo_banco_min ?? 0, true)}
          detalhe="Saldo até ontem" />
      </div>

      <section className="card">
        <header className="px-5 pb-3 pt-5">
          <h2 className="text-[15px] font-semibold text-slate-900">Últimos dias</h2>
          <p className="mt-0.5 text-xs text-slate-500">Cada dia encerrado entra automaticamente no seu banco de horas.</p>
        </header>
        {!dados || dados.ultimos_dias.length === 0 ? (
          <p className="px-5 pb-8 pt-4 text-center text-sm text-slate-400">Ainda não há dias encerrados.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[560px] text-sm">
              <thead>
                <tr className="text-left text-xs text-slate-400">
                  <th className="px-5 py-2.5 font-medium">Dia</th>
                  <th className="px-5 py-2.5 font-medium">Marcações</th>
                  <th className="px-5 py-2.5 text-right font-medium">Trabalhado</th>
                  <th className="px-5 py-2.5 text-right font-medium">Saldo</th>
                  <th className="px-5 py-2.5 font-medium">Ocorrência</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {dados.ultimos_dias.map((d) => {
                  const oc = ocorrencia(d.ocorrencia);
                  return (
                    <tr key={d.data}>
                      <td className="px-5 py-3 capitalize text-slate-700">
                        {formatData(d.data, { weekday: 'short', day: '2-digit', month: '2-digit' })}
                      </td>
                      <td className="px-5 py-3 tabular-nums text-slate-500">
                        {d.batidas.length ? d.batidas.map((b) => b.hora).join(' · ') : '—'}
                      </td>
                      <td className="px-5 py-3 text-right tabular-nums text-slate-700">{formatMinutos(d.trabalhado_min)}</td>
                      <td
                        className={clsx(
                          'px-5 py-3 text-right font-medium tabular-nums',
                          d.saldo_min > 0 ? 'text-primary-600' : d.saldo_min < 0 ? 'text-accent-700' : 'text-slate-400',
                        )}
                      >
                        {d.saldo_min === 0 ? '—' : formatMinutos(d.saldo_min, true)}
                      </td>
                      <td className="px-5 py-3">
                        <Badge tone={oc.tone}>{oc.label}</Badge>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
