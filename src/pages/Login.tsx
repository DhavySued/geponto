import clsx from 'clsx';
import { AlertCircle, CheckCircle2, Eye, EyeOff, Fingerprint, LogIn, Lock, User } from 'lucide-react';
import { useEffect, useRef, useState, type FormEvent } from 'react';
import { Navigate, useLocation } from 'react-router-dom';
import { AvisoGeo } from '@/components/ponto/Geo';
import { Button } from '@/components/ui/Button';
import { useAuth } from '@/contexts/AuthContext';
import { formatData } from '@/lib/format';
import { obterLocalizacao } from '@/lib/geo';
import { useHoraOficial } from '@/lib/hooks';
import { supabase } from '@/lib/supabase';
import type { RegistroPonto } from '@/lib/types';

type Modo = 'entrar' | 'ponto';

/** Relógio da tela de registro (a batida usa sempre a hora do servidor). */
function Relogio() {
  const { agora, fuso } = useHoraOficial();
  return (
    <div className="rounded-2xl bg-primary-700 px-5 py-4 text-center text-white">
      <p className="font-mono text-4xl font-semibold tabular-nums tracking-tight">
        {agora.toLocaleTimeString('pt-BR', { timeZone: fuso })}
      </p>
      <p className="mt-1 text-xs capitalize text-white/60">
        {agora.toLocaleDateString('pt-BR', { weekday: 'long', day: '2-digit', month: 'long', timeZone: fuso })}
      </p>
    </div>
  );
}

export default function Login() {
  const { usuario, entrar } = useAuth();
  const location = useLocation();
  const [modo, setModo] = useState<Modo>('entrar');
  const [login, setLogin] = useState('');
  const [senha, setSenha] = useState('');
  const [mostrarSenha, setMostrarSenha] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [enviando, setEnviando] = useState(false);
  const [comprovante, setComprovante] = useState<RegistroPonto | null>(null);
  const limpar = useRef<number>();

  useEffect(() => () => window.clearTimeout(limpar.current), []);

  if (usuario) {
    const destino = (location.state as { from?: string } | null)?.from ?? '/';
    return <Navigate to={destino} replace />;
  }

  const trocarModo = (m: Modo) => {
    setModo(m);
    setErro(null);
    setSenha('');
    setComprovante(null);
  };

  const registrarPonto = async () => {
    // A localização acompanha a batida; sem ela o ponto é registrado mesmo assim (Portaria 671)
    const geo = await obterLocalizacao();
    const { data, error } = await supabase.rpc('api_registrar_ponto_rapido', {
      p_login: login,
      p_senha: senha,
      p_user_agent: navigator.userAgent,
      ...geo,
    });
    if (error) return setErro('Não foi possível conectar ao servidor. Tente novamente.');
    const r = data as RegistroPonto & { erro?: string };
    if (!r.ok) return setErro(r.erro ?? 'Não foi possível registrar o ponto.');
    // Libera o terminal para o próximo colaborador
    setComprovante(r);
    setLogin('');
    setSenha('');
    window.clearTimeout(limpar.current);
    limpar.current = window.setTimeout(() => setComprovante(null), 15_000);
  };

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setErro(null);
    setEnviando(true);
    if (modo === 'ponto') {
      setComprovante(null);
      await registrarPonto();
      setEnviando(false);
      return;
    }
    const falha = await entrar(login, senha);
    setEnviando(false);
    if (falha) setErro(falha);
  };

  return (
    <div className="grid min-h-screen lg:grid-cols-[1.1fr_1fr]">
      {/* Painel institucional */}
      <div className="relative hidden overflow-hidden bg-primary-700 p-12 text-white lg:flex lg:flex-col lg:justify-between">
        <div className="absolute -right-32 -top-32 h-[420px] w-[420px] rounded-full bg-accent-500/20 blur-3xl" />
        <div className="absolute -bottom-40 -left-20 h-[380px] w-[380px] rounded-full bg-white/5 blur-2xl" />

        <div className="relative flex items-center gap-3">
          <div className="flex h-11 w-11 items-center justify-center rounded-2xl bg-white/10 ring-1 ring-white/15">
            <svg viewBox="0 0 32 32" className="h-7 w-7" aria-hidden>
              <circle cx="16" cy="16" r="10" fill="none" stroke="#fff" strokeWidth="2.6" />
              <path d="M16 10.5v5.5l4 2.3" fill="none" stroke="#f39200" strokeWidth="2.6" strokeLinecap="round" />
            </svg>
          </div>
          <span className="text-xl font-semibold">
            Ge<span className="text-accent-400">Ponto</span>
          </span>
        </div>

        <div className="relative max-w-md">
          <h1 className="text-4xl font-semibold leading-tight tracking-tight">
            Gestão de ponto <span className="text-accent-400">simples</span>, precisa e em tempo real.
          </h1>
          <p className="mt-4 text-white/70">
            Jornadas, batidas, banco de horas e espelho de ponto em um só lugar — com indicadores para decidir rápido.
          </p>
          <div className="mt-10 grid grid-cols-3 gap-4">
            {[
              ['Tempo real', 'batidas do dia'],
              ['Banco de horas', 'automático'],
              ['Espelho', 'em PDF'],
            ].map(([t, s]) => (
              <div key={t} className="rounded-2xl bg-white/[0.06] p-4 ring-1 ring-white/10">
                <p className="text-sm font-semibold">{t}</p>
                <p className="mt-0.5 text-xs text-white/60">{s}</p>
              </div>
            ))}
          </div>
        </div>

        <p className="relative text-xs text-white/40">© {new Date().getFullYear()} GePonto · ERP de Controle de Ponto</p>
      </div>

      {/* Formulário */}
      <div className="flex items-center justify-center px-4 py-12 sm:px-8">
        <div className="w-full max-w-sm">
          <div className="mb-8 lg:hidden">
            <span className="text-2xl font-semibold text-primary-700">
              Ge<span className="text-accent-500">Ponto</span>
            </span>
          </div>
          <div className="mb-8 grid grid-cols-2 rounded-xl bg-slate-100 p-1">
            {([
              ['entrar', 'Entrar no sistema', LogIn],
              ['ponto', 'Registrar ponto', Fingerprint],
            ] as const).map(([m, label, Icon]) => (
              <button
                key={m}
                type="button"
                onClick={() => trocarModo(m)}
                className={clsx(
                  'flex items-center justify-center gap-2 rounded-lg py-2 text-sm font-medium transition',
                  modo === m ? 'bg-white text-primary-700 shadow-sm' : 'text-slate-500 hover:text-slate-700',
                )}
              >
                <Icon className="h-4 w-4" /> {label}
              </button>
            ))}
          </div>

          {modo === 'entrar' ? (
            <>
              <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Acesse sua conta</h2>
              <p className="mt-1.5 text-sm text-slate-500">Entre com o usuário fornecido pelo administrador.</p>
            </>
          ) : (
            <>
              <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Registrar ponto</h2>
              <p className="mt-1.5 text-sm text-slate-500">
                Informe o seu login e a sua senha. A marcação é feita no seu nome, no horário oficial de Brasília.
              </p>
              <div className="mt-6">
                <Relogio />
              </div>
            </>
          )}

          <form onSubmit={onSubmit} className={clsx('space-y-5', modo === 'entrar' ? 'mt-8' : 'mt-6')}>
            {comprovante && (
              <div className="flex items-start gap-3 rounded-xl bg-emerald-50 p-4 text-sm text-emerald-800 ring-1 ring-emerald-200" role="status">
                <CheckCircle2 className="mt-0.5 h-5 w-5 shrink-0 text-emerald-600" />
                <div>
                  <p className="font-semibold">
                    {comprovante.tipo} registrada às {comprovante.hora}
                  </p>
                  <p className="mt-0.5">{comprovante.colaborador} · mat. {comprovante.matricula}</p>
                  <p className="mt-1 text-xs text-emerald-700/80">
                    Comprovante · {formatData(comprovante.data, { day: '2-digit', month: '2-digit', year: 'numeric' })} · NSR{' '}
                    {String(comprovante.nsr).padStart(9, '0')}
                  </p>
                </div>
              </div>
            )}
            {comprovante && <AvisoGeo g={comprovante} />}
            {erro && (
              <div className="flex items-start gap-2 rounded-xl bg-rose-50 p-3 text-sm text-rose-700 ring-1 ring-rose-200">
                <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" />
                {erro}
              </div>
            )}

            <div>
              <label htmlFor="login" className="label">
                Usuário ou e-mail
              </label>
              <div className="relative">
                <User className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
                <input
                  id="login"
                  autoComplete={modo === 'entrar' ? 'username' : 'off'}
                  autoFocus
                  required
                  value={login}
                  onChange={(e) => setLogin(e.target.value)}
                  className="input h-11 pl-10"
                  placeholder="seu.usuario"
                />
              </div>
            </div>

            <div>
              <label htmlFor="senha" className="label">
                Senha
              </label>
              <div className="relative">
                <Lock className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
                <input
                  id="senha"
                  type={mostrarSenha ? 'text' : 'password'}
                  autoComplete={modo === 'entrar' ? 'current-password' : 'off'}
                  required
                  value={senha}
                  onChange={(e) => setSenha(e.target.value)}
                  className="input h-11 px-10"
                  placeholder="••••••••"
                />
                <button
                  type="button"
                  onClick={() => setMostrarSenha((v) => !v)}
                  className="absolute right-2 top-1/2 -translate-y-1/2 rounded-lg p-1.5 text-slate-400 hover:text-slate-600"
                  aria-label={mostrarSenha ? 'Ocultar senha' : 'Mostrar senha'}
                >
                  {mostrarSenha ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
            </div>

            <Button type="submit" variant="accent" loading={enviando} className="h-11 w-full">
              {modo === 'entrar' ? (
                'Entrar'
              ) : (
                <>
                  <Fingerprint className="h-4 w-4" /> Registrar meu ponto
                </>
              )}
            </Button>
          </form>
        </div>
      </div>
    </div>
  );
}
