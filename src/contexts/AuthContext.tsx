import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { api, ApiError, SESSAO_EXPIRADA, supabase, tokenStorage } from '@/lib/supabase';
import type { PaginaChave, Usuario } from '@/lib/types';

interface LoginResposta {
  ok: boolean;
  erro?: string;
  token?: string;
  usuario?: Usuario;
}

interface AuthContextValue {
  usuario: Usuario | null;
  carregando: boolean;
  entrar: (login: string, senha: string) => Promise<string | null>;
  sair: () => Promise<void>;
  /** Relê a sessão (ex.: depois de trocar a senha ou mudar as próprias permissões). */
  recarregar: () => Promise<void>;
  pode: (pagina: PaginaChave, acao?: 'visualizar' | 'editar') => boolean;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [usuario, setUsuario] = useState<Usuario | null>(null);
  const [carregando, setCarregando] = useState(true);

  // Restaura a sessão a partir do token salvo
  useEffect(() => {
    if (!tokenStorage.get()) {
      setCarregando(false);
      return;
    }
    api<Usuario>('api_sessao')
      .then(setUsuario)
      .catch((e) => {
        // Só descarta o token se a sessão expirou de fato: uma queda de rede não pode deslogar
        if (e instanceof ApiError && e.code === '28000') tokenStorage.clear();
      })
      .finally(() => setCarregando(false));
  }, []);

  // Qualquer chamada que receba "sessão expirada" derruba o usuário para o login
  useEffect(() => {
    const expirar = () => {
      tokenStorage.clear();
      setUsuario(null);
    };
    window.addEventListener(SESSAO_EXPIRADA, expirar);
    return () => window.removeEventListener(SESSAO_EXPIRADA, expirar);
  }, []);

  const entrar = useCallback(async (login: string, senha: string) => {
    const { data, error } = await supabase.rpc('api_login', {
      p_login: login,
      p_senha: senha,
      p_user_agent: navigator.userAgent,
    });
    if (error) return 'Não foi possível conectar ao servidor. Tente novamente.';
    const resp = data as LoginResposta;
    if (!resp.ok || !resp.token || !resp.usuario) return resp.erro ?? 'Falha no login.';
    tokenStorage.set(resp.token);
    setUsuario(resp.usuario);
    return null;
  }, []);

  const sair = useCallback(async () => {
    try {
      await api('api_logout');
    } catch {
      // Sem conexão: a sessão expira sozinha no servidor; aqui o usuário sai do mesmo jeito
    } finally {
      tokenStorage.clear();
      setUsuario(null);
    }
  }, []);

  const recarregar = useCallback(async () => {
    setUsuario(await api<Usuario>('api_sessao'));
  }, []);

  const pode = useCallback(
    (pagina: PaginaChave, acao: 'visualizar' | 'editar' = 'visualizar') =>
      !!usuario && (usuario.perfil.is_admin || !!usuario.permissoes[pagina]?.[acao]),
    [usuario],
  );

  const value = useMemo(
    () => ({ usuario, carregando, entrar, sair, recarregar, pode }),
    [usuario, carregando, entrar, sair, recarregar, pode],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth deve ser usado dentro de <AuthProvider>');
  return ctx;
}
