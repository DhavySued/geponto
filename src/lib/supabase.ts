import { createClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;

if (!url || !key) {
  throw new Error('Defina VITE_SUPABASE_URL e VITE_SUPABASE_PUBLISHABLE_KEY no arquivo .env');
}

// O Supabase Auth não é usado: a autenticação é própria (tabela `usuarios`)
// e todo acesso a dados passa pelas funções RPC `api_*`.
export const supabase = createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
});

const TOKEN_KEY = 'geponto.token';
export const SESSAO_EXPIRADA = 'geponto:sessao-expirada';

export const tokenStorage = {
  get: () => localStorage.getItem(TOKEN_KEY),
  set: (token: string) => localStorage.setItem(TOKEN_KEY, token),
  clear: () => localStorage.removeItem(TOKEN_KEY),
};

export class ApiError extends Error {
  constructor(
    message: string,
    public code?: string,
  ) {
    super(message);
  }
}

/** Chama uma função RPC autenticada, injetando o token da sessão como `p_token`. */
export async function api<T>(fn: string, params: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await supabase.rpc(fn, { p_token: tokenStorage.get(), ...params });
  if (error) {
    if (error.code === '28000') window.dispatchEvent(new Event(SESSAO_EXPIRADA));
    throw new ApiError(error.message, error.code);
  }
  return data as T;
}
