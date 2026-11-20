// GePonto: gateway REST da API de integrações (v1)
//
// Traduz rotas REST (/v1/colaboradores, /v1/batidas…) com "Authorization: Bearer <chave>" para as
// funções api_v1_* do banco, chamadas pelo contrato PostgREST (POST {UPSTREAM_URL}/rpc/{funcao}).
// Funciona com o Supabase ou com um PostgREST próprio, sem nenhuma dependência além do Node 18+.
//
//   UPSTREAM_URL   https://SEU-PROJETO.supabase.co/rest/v1   (ou http://postgrest:3000)
//   UPSTREAM_KEY   chave pública do Supabase (sb_publishable_…) ou JWT do papel anon; vazio no PostgREST sem JWT
//   PORT           8080
//   CORS_ORIGENS   * (padrão) ou lista separada por vírgula
//   LIMITE_MINUTO  120 requisições por chave por minuto
//
// Documentação: GET /docs (OpenAPI em /openapi.yaml)

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const UPSTREAM = (process.env.UPSTREAM_URL ?? '').replace(/\/+$/, '');
const UPSTREAM_KEY = process.env.UPSTREAM_KEY ?? '';
const PORT = Number(process.env.PORT ?? 8080);
const CORS = (process.env.CORS_ORIGENS ?? '*').split(',').map((s) => s.trim()).filter(Boolean);
const LIMITE = Number(process.env.LIMITE_MINUTO ?? 120);
const MAX_CORPO = 5 * 1024 * 1024;

if (!UPSTREAM) {
  console.error('Defina UPSTREAM_URL (ex.: https://SEU-PROJETO.supabase.co/rest/v1).');
  process.exit(1);
}

const OPENAPI = (() => {
  for (const p of [path.join(DIR, 'openapi.yaml'), path.join(DIR, '..', 'docs', 'api', 'openapi.yaml')]) {
    if (fs.existsSync(p)) return fs.readFileSync(p, 'utf8');
  }
  return null;
})();

// ----- Rotas: método + caminho → função do banco e como montar os parâmetros -----
const data = (v, nome) => {
  if (v == null || v === '') return null;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(v)) throw new ErroHttp(400, 'parametro_invalido', `${nome} deve estar no formato AAAA-MM-DD.`);
  return v;
};
const obrigatorio = (v, nome) => {
  if (v == null || v === '') throw new ErroHttp(400, 'parametro_obrigatorio', `Informe ${nome}.`);
  return v;
};

const ROTAS = {
  'GET /v1/empresa': { fn: 'api_v1_empresa', params: () => ({}) },
  'GET /v1/colaboradores': {
    fn: 'api_v1_colaboradores',
    params: (q) => ({ p_situacao: q.get('situacao') || null, p_alterados_desde: q.get('alterados_desde') || null }),
  },
  'GET /v1/batidas': {
    fn: 'api_v1_batidas',
    params: (q) => ({
      p_inicio: data(obrigatorio(q.get('inicio'), 'inicio'), 'inicio'),
      p_fim: data(obrigatorio(q.get('fim'), 'fim'), 'fim'),
      p_colaborador: q.get('colaborador_id') || null,
      p_matricula: q.get('matricula') || null,
    }),
  },
  'POST /v1/batidas': {
    fn: 'api_v1_batidas_importar',
    corpo: true,
    params: (_q, corpo) => {
      const lista = Array.isArray(corpo) ? corpo : corpo?.batidas;
      if (!Array.isArray(lista)) throw new ErroHttp(400, 'corpo_invalido', 'Envie {"batidas": [...]} ou uma lista de batidas.');
      return { p_batidas: lista };
    },
  },
  'GET /v1/totais': {
    fn: 'api_v1_totais',
    params: (q) => ({ p_inicio: data(obrigatorio(q.get('inicio'), 'inicio'), 'inicio'), p_fim: data(obrigatorio(q.get('fim'), 'fim'), 'fim') }),
  },
  'GET /v1/banco-horas': { fn: 'api_v1_banco_horas', params: (q) => ({ p_data: data(q.get('data'), 'data') }) },
};

class ErroHttp extends Error {
  constructor(status, codigo, mensagem) {
    super(mensagem);
    this.status = status;
    this.codigo = codigo;
  }
}

// Erros do banco (SQLSTATE) → HTTP
function statusDoBanco(code) {
  if (code === '28000') return [401, 'nao_autorizado'];
  if (code === '42501') return [403, 'sem_permissao'];
  if (code === '22023' || code === 'P0001' || code?.startsWith('22') || code?.startsWith('23')) return [400, 'requisicao_invalida'];
  if (code === 'PGRST202') return [501, 'nao_instalado'];
  return [502, 'erro_servidor'];
}

// ----- Limite de requisições por chave (janela de 1 minuto, em memória) -----
const janelas = new Map();
function dentroDoLimite(chave) {
  const agora = Date.now();
  const j = janelas.get(chave);
  if (!j || agora - j.inicio > 60_000) {
    janelas.set(chave, { inicio: agora, n: 1 });
    return true;
  }
  return ++j.n <= LIMITE;
}
setInterval(() => {
  const limite = Date.now() - 60_000;
  for (const [k, j] of janelas) if (j.inicio < limite) janelas.delete(k);
}, 60_000).unref();

async function chamarBanco(fn, params) {
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json' };
  if (UPSTREAM_KEY) {
    headers.apikey = UPSTREAM_KEY;
    if (UPSTREAM_KEY.split('.').length === 3) headers.Authorization = `Bearer ${UPSTREAM_KEY}`;
  }
  let r;
  try {
    r = await fetch(`${UPSTREAM}/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(params) });
  } catch {
    throw new ErroHttp(503, 'banco_indisponivel', 'Banco de dados indisponível. Tente novamente.');
  }
  const texto = await r.text();
  let corpo = null;
  try { corpo = texto ? JSON.parse(texto) : null; } catch { corpo = texto; }
  if (!r.ok) {
    const [status, codigo] = statusDoBanco(corpo?.code);
    throw new ErroHttp(status, codigo, corpo?.message ?? `Erro ${r.status}.`);
  }
  return corpo;
}

function lerCorpo(req) {
  return new Promise((resolve, reject) => {
    let tamanho = 0;
    const partes = [];
    req.on('data', (c) => {
      tamanho += c.length;
      if (tamanho > MAX_CORPO) {
        reject(new ErroHttp(413, 'corpo_grande', 'Corpo maior que 5 MB.'));
        req.destroy();
      } else partes.push(c);
    });
    req.on('end', () => {
      const t = Buffer.concat(partes).toString('utf8');
      if (!t) return resolve(null);
      try { resolve(JSON.parse(t)); } catch { reject(new ErroHttp(400, 'json_invalido', 'O corpo não é um JSON válido.')); }
    });
    req.on('error', reject);
  });
}

function cors(req, res) {
  const origem = req.headers.origin;
  if (CORS.includes('*')) res.setHeader('Access-Control-Allow-Origin', '*');
  else if (origem && CORS.includes(origem)) {
    res.setHeader('Access-Control-Allow-Origin', origem);
    res.setHeader('Vary', 'Origin');
  }
  res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
}

function enviar(res, status, corpo, tipo = 'application/json; charset=utf-8') {
  res.writeHead(status, { 'Content-Type': tipo, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
  res.end(typeof corpo === 'string' ? corpo : JSON.stringify(corpo));
}

const PAGINA_DOCS = `<!doctype html><html lang="pt-BR"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>GePonto API</title></head><body style="margin:0">
<redoc spec-url="openapi.yaml"></redoc>
<script src="https://cdn.jsdelivr.net/npm/redoc@2.1.5/bundles/redoc.standalone.js"></script></body></html>`;

const servidor = http.createServer(async (req, res) => {
  const inicio = Date.now();
  const url = new URL(req.url ?? '/', 'http://localhost');
  const caminho = url.pathname.replace(/\/+$/, '') || '/';
  cors(req, res);
  try {
    if (req.method === 'OPTIONS') return enviar(res, 204, '');
    if (req.method === 'GET' && (caminho === '/health' || caminho === '/')) return enviar(res, 200, { ok: true, versao: 'v1' });
    if (req.method === 'GET' && caminho === '/openapi.yaml' && OPENAPI) return enviar(res, 200, OPENAPI, 'application/yaml; charset=utf-8');
    if (req.method === 'GET' && caminho === '/docs') return enviar(res, 200, PAGINA_DOCS, 'text/html; charset=utf-8');

    const rota = ROTAS[`${req.method} ${caminho}`];
    if (!rota) {
      const existe = Object.keys(ROTAS).some((k) => k.endsWith(` ${caminho}`));
      throw existe ? new ErroHttp(405, 'metodo_nao_permitido', 'Método não permitido.') : new ErroHttp(404, 'nao_encontrado', 'Rota não encontrada. Veja /docs.');
    }

    const auth = req.headers.authorization ?? '';
    const chave = /^Bearer\s+(\S+)$/i.exec(auth)?.[1];
    if (!chave) throw new ErroHttp(401, 'nao_autorizado', 'Envie o cabeçalho Authorization: Bearer <chave>.');
    if (!dentroDoLimite(chave)) {
      res.setHeader('Retry-After', '60');
      throw new ErroHttp(429, 'limite_excedido', `Limite de ${LIMITE} requisições por minuto excedido.`);
    }

    const corpo = rota.corpo ? await lerCorpo(req) : null;
    const resultado = await chamarBanco(rota.fn, { p_chave: chave, ...rota.params(url.searchParams, corpo) });
    enviar(res, 200, resultado);
  } catch (e) {
    const status = e instanceof ErroHttp ? e.status : 500;
    if (!(e instanceof ErroHttp)) console.error(e);
    enviar(res, status, { erro: { codigo: e.codigo ?? 'erro_interno', mensagem: e instanceof ErroHttp ? e.message : 'Erro interno.' } });
  } finally {
    // Log sem a chave nem parâmetros
    console.log(`${new Date().toISOString()} ${req.method} ${caminho} ${res.statusCode} ${Date.now() - inicio}ms`);
  }
});

servidor.listen(PORT, () => console.log(`GePonto API v1 em http://localhost:${PORT} (docs em /docs) → ${UPSTREAM}`));
