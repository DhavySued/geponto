/**
 * Acesso ao backend, independente de fornecedor.
 *
 * Todas as telas falam com o servidor por um único contrato: chamar uma função pelo nome com
 * parâmetros nomeados e receber JSON (as funções `api_*` do banco). Quem entrega esse contrato é
 * um "transporte", escolhido pelo .env:
 *
 *  - http (VITE_API_URL): POST {VITE_API_URL}/rpc/{funcao} com o JSON dos parâmetros. É o formato
 *    do PostgREST, então serve para o Supabase (…supabase.co/rest/v1), para um PostgREST próprio
 *    (pasta servidor/) ou para qualquer servidor que implemente o mesmo contrato (docs/api).
 *  - supabase (VITE_SUPABASE_URL): o cliente oficial do Supabase. Mantido para compatibilidade.
 *
 * Trocar de backend = mudar o .env. Nenhuma tela importa o cliente do Supabase.
 */

const env = import.meta.env;
const URL_HTTP = (env.VITE_API_URL as string | undefined)?.replace(/\/+$/, '');
const CHAVE_HTTP = env.VITE_API_CHAVE as string | undefined;
const URL_SUPABASE = env.VITE_SUPABASE_URL as string | undefined;
const CHAVE_SUPABASE = env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;

export class ApiError extends Error {
  constructor(
    message: string,
    public code?: string,
  ) {
    super(message);
  }
}

/** Resultado de uma chamada: o mesmo formato em qualquer transporte */
export interface RespostaRpc<T> {
  data: T | null;
  error: ApiError | null;
}

interface Transporte {
  nome: 'http' | 'supabase';
  chamar(funcao: string, params: Record<string, unknown>): Promise<RespostaRpc<unknown>>;
}

const ERRO_CONEXAO = 'Não foi possível conectar ao servidor. Tente novamente.';

/** Contrato HTTP genérico (PostgREST): POST /rpc/{funcao} */
function transporteHttp(base: string, chave?: string): Transporte {
  const cabecalhos: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'application/json' };
  if (chave) {
    cabecalhos.apikey = chave;
    // Chaves JWT (PostgREST próprio ou chave "anon" antiga do Supabase) também vão no Authorization
    if (chave.split('.').length === 3) cabecalhos.Authorization = `Bearer ${chave}`;
  }
  return {
    nome: 'http',
    async chamar(funcao, params) {
      let r: Response;
      try {
        r = await fetch(`${base}/rpc/${encodeURIComponent(funcao)}`, { method: 'POST', headers: cabecalhos, body: JSON.stringify(params) });
      } catch {
        return { data: null, error: new ApiError(ERRO_CONEXAO, 'conexao') };
      }
      const texto = await r.text();
      let corpo: unknown = null;
      try {
        corpo = texto ? JSON.parse(texto) : null;
      } catch {
        corpo = texto;
      }
      if (!r.ok) {
        const e = (corpo ?? {}) as { message?: string; code?: string };
        return { data: null, error: new ApiError(e.message ?? `Erro ${r.status} no servidor.`, e.code ?? String(r.status)) };
      }
      return { data: corpo, error: null };
    },
  };
}

/** Cliente oficial do Supabase, carregado só quando este transporte é usado */
function transporteSupabase(url: string, chave: string): Transporte {
  type Cliente = { rpc: (f: string, p: Record<string, unknown>) => PromiseLike<{ data: unknown; error: { message: string; code?: string } | null }> };
  let cliente: Promise<Cliente> | null = null;
  const obter = () =>
    (cliente ??= import('@supabase/supabase-js').then(({ createClient }) =>
      // O Supabase Auth não é usado: a autenticação é própria (tabela usuarios)
      createClient(url, chave, { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } }) as unknown as Cliente,
    ));
  return {
    nome: 'supabase',
    async chamar(funcao, params) {
      try {
        const { data, error } = await (await obter()).rpc(funcao, params);
        return error ? { data: null, error: new ApiError(error.message, error.code) } : { data, error: null };
      } catch {
        return { data: null, error: new ApiError(ERRO_CONEXAO, 'conexao') };
      }
    },
  };
}

function escolherTransporte(): Transporte {
  if (URL_HTTP) return transporteHttp(URL_HTTP, CHAVE_HTTP);
  if (URL_SUPABASE && CHAVE_SUPABASE) return transporteSupabase(URL_SUPABASE, CHAVE_SUPABASE);
  throw new Error('Configure o backend no .env: VITE_API_URL (e VITE_API_CHAVE, se houver) ou VITE_SUPABASE_URL e VITE_SUPABASE_PUBLISHABLE_KEY.');
}

export const transporte = escolherTransporte();

// ----- Sessão -----
const TOKEN_KEY = 'geponto.token';
export const SESSAO_EXPIRADA = 'geponto:sessao-expirada';

export const tokenStorage = {
  get: () => localStorage.getItem(TOKEN_KEY),
  set: (token: string) => localStorage.setItem(TOKEN_KEY, token),
  clear: () => localStorage.removeItem(TOKEN_KEY),
};

/** Chamada sem sessão (login, registro rápido de ponto, hora oficial) */
export function rpc<T = unknown>(funcao: string, params: Record<string, unknown> = {}): Promise<RespostaRpc<T>> {
  return transporte.chamar(funcao, params) as Promise<RespostaRpc<T>>;
}

/** Chamada autenticada: injeta o token da sessão como `p_token` e lança ApiError em caso de erro */
export async function api<T>(funcao: string, params: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await rpc<T>(funcao, { p_token: tokenStorage.get(), ...params });
  if (error) {
    if (error.code === '28000') window.dispatchEvent(new Event(SESSAO_EXPIRADA));
    throw error;
  }
  return data as T;
}
