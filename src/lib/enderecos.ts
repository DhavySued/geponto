import { useEffect, useState } from 'react';
import { api } from './api';

/** Endereço de uma coordenada (rua, número, bairro, cidade e UF) */
export interface EnderecoGeo {
  rua: string | null;
  numero: string | null;
  bairro: string | null;
  cidade: string | null;
  uf: string | null;
  cep: string | null;
}

type Entrada = EnderecoGeo | 'vazio' | 'pendente';

/** Coordenadas arredondadas em 4 casas (~11 m), como no banco */
const chave = (lat: number, lng: number) => `${lat.toFixed(4)},${lng.toFixed(4)}`;

const cache = new Map<string, Entrada>();
const ouvintes = new Set<() => void>();
const avisar = () => ouvintes.forEach((f) => f());

/** "Rua das Flores, 120 – Centro, Fortaleza/CE" */
export function textoEndereco(e: EnderecoGeo | null | undefined): string | null {
  if (!e) return null;
  const rua = e.rua ? `${e.rua}${e.numero ? `, ${e.numero}` : ', s/n'}` : null;
  const cidade = e.cidade ? `${e.cidade}${e.uf ? `/${e.uf}` : ''}` : e.uf;
  const partes = [rua, e.bairro, cidade].filter(Boolean);
  if (!partes.length) return null;
  return rua ? `${rua}${partes.length > 1 ? ' – ' + partes.slice(1).join(', ') : ''}` : partes.join(', ');
}

/** Guarda endereços já vindos do banco (ex.: no relatório) */
export function semearEnderecos(lista: ({ latitude: number | null; longitude: number | null; endereco?: EnderecoGeo | null })[]) {
  let mudou = false;
  for (const i of lista) {
    if (i.latitude == null || i.longitude == null || !i.endereco) continue;
    const k = chave(i.latitude, i.longitude);
    if (cache.get(k) !== i.endereco) {
      cache.set(k, i.endereco);
      mudou = true;
    }
  }
  if (mudou) avisar();
}

// ----- Busca: primeiro no banco (em lote), depois no OpenStreetMap (1 por segundo) -----
let loteBanco: { lat: number; lng: number }[] = [];
let timerBanco: number | null = null;
const filaMapa: { lat: number; lng: number }[] = [];
let processandoMapa = false;

const UF: Record<string, string> = {
  Acre: 'AC', Alagoas: 'AL', Amapá: 'AP', Amazonas: 'AM', Bahia: 'BA', Ceará: 'CE', 'Distrito Federal': 'DF',
  'Espírito Santo': 'ES', Goiás: 'GO', Maranhão: 'MA', 'Mato Grosso': 'MT', 'Mato Grosso do Sul': 'MS',
  'Minas Gerais': 'MG', Pará: 'PA', Paraíba: 'PB', Paraná: 'PR', Pernambuco: 'PE', Piauí: 'PI',
  'Rio de Janeiro': 'RJ', 'Rio Grande do Norte': 'RN', 'Rio Grande do Sul': 'RS', Rondônia: 'RO', Roraima: 'RR',
  'Santa Catarina': 'SC', 'São Paulo': 'SP', Sergipe: 'SE', Tocantins: 'TO',
};

async function buscarNoMapa(lat: number, lng: number): Promise<EnderecoGeo | null> {
  const url = `https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=${lat}&lon=${lng}&zoom=18&addressdetails=1&accept-language=pt-BR`;
  const r = await fetch(url, { headers: { Accept: 'application/json' } });
  if (!r.ok) throw new Error(String(r.status));
  const j = await r.json();
  const a = j?.address;
  if (!a) return null;
  const iso: string | undefined = a['ISO3166-2-lvl4'];
  const e: EnderecoGeo = {
    rua: a.road ?? a.pedestrian ?? a.footway ?? a.street ?? a.residential ?? null,
    numero: a.house_number ?? null,
    bairro: a.suburb ?? a.neighbourhood ?? a.quarter ?? a.city_district ?? a.hamlet ?? null,
    cidade: a.city ?? a.town ?? a.village ?? a.municipality ?? null,
    uf: iso?.startsWith('BR-') ? iso.slice(3) : (UF[a.state] ?? a.state ?? null),
    cep: a.postcode ?? null,
  };
  return e.rua || e.bairro || e.cidade ? e : null;
}

async function processarMapa() {
  if (processandoMapa) return;
  processandoMapa = true;
  try {
    while (filaMapa.length) {
      const { lat, lng } = filaMapa.shift()!;
      const k = chave(lat, lng);
      try {
        const e = await buscarNoMapa(lat, lng);
        cache.set(k, e ?? 'vazio');
        if (e) api('api_endereco_geo_salvar', { p_dados: { lat, lng, ...e } }).catch(() => undefined);
      } catch {
        cache.set(k, 'vazio'); // sem rede ou serviço indisponível: fica só o link do mapa
      }
      avisar();
      // Política de uso do OpenStreetMap: no máximo 1 consulta por segundo
      if (filaMapa.length) await new Promise((res) => setTimeout(res, 1100));
    }
  } finally {
    processandoMapa = false;
  }
}

async function processarBanco() {
  const lote = loteBanco;
  loteBanco = [];
  timerBanco = null;
  try {
    const achados = await api<(EnderecoGeo & { lat: number; lng: number })[]>('api_enderecos_geo', {
      p_coords: lote.map((c) => [c.lat, c.lng]),
    });
    for (const a of achados) cache.set(chave(a.lat, a.lng), a);
  } catch {
    /* segue para o mapa */
  }
  for (const c of lote) if (cache.get(chave(c.lat, c.lng)) === 'pendente') filaMapa.push(c);
  avisar();
  processarMapa();
}

function solicitar(lat: number, lng: number) {
  const k = chave(lat, lng);
  if (cache.has(k)) return;
  cache.set(k, 'pendente');
  loteBanco.push({ lat, lng });
  if (timerBanco == null) timerBanco = window.setTimeout(processarBanco, 60);
}

/** Endereço da coordenada: undefined enquanto busca, null quando não foi encontrado */
export function useEndereco(lat: number | null | undefined, lng: number | null | undefined): EnderecoGeo | null | undefined {
  const [, forcar] = useState(0);
  useEffect(() => {
    const f = () => forcar((n) => n + 1);
    ouvintes.add(f);
    if (lat != null && lng != null) solicitar(lat, lng);
    return () => {
      ouvintes.delete(f);
    };
  }, [lat, lng]);
  if (lat == null || lng == null) return null;
  const e = cache.get(chave(lat, lng));
  return e === 'pendente' || e === undefined ? undefined : e === 'vazio' ? null : e;
}

// ----- Cadastro da empresa: CEP e localização a partir do endereço -----

/** Endereço pelo CEP (ViaCEP); null quando não encontrado */
export async function buscarCep(cep: string): Promise<{ logradouro: string; bairro: string; cidade: string; uf: string } | null> {
  const d = cep.replace(/\D/g, '');
  if (d.length !== 8) return null;
  const r = await fetch(`https://viacep.com.br/ws/${d}/json/`);
  if (!r.ok) return null;
  const j = await r.json();
  if (j?.erro) return null;
  return { logradouro: j.logradouro ?? '', bairro: j.bairro ?? '', cidade: j.localidade ?? '', uf: j.uf ?? '' };
}

/**
 * Coordenadas do endereço (OpenStreetMap). A precisão depende do cadastro do mapa: com número,
 * costuma cair na porta; sem número, no meio da rua. Para precisão total, capture estando no local.
 */
export async function localizarEndereco(e: {
  logradouro?: string | null;
  numero?: string | null;
  bairro?: string | null;
  cidade?: string | null;
  uf?: string | null;
  cep?: string | null;
}): Promise<{ lat: number; lng: number; exato: boolean } | null> {
  const buscar = async (params: Record<string, string>) => {
    const q = new URLSearchParams({ format: 'jsonv2', limit: '1', countrycodes: 'br', 'accept-language': 'pt-BR', ...params });
    const r = await fetch(`https://nominatim.openstreetmap.org/search?${q}`, { headers: { Accept: 'application/json' } });
    if (!r.ok) return null;
    const j = await r.json();
    return Array.isArray(j) && j[0] ? { lat: Number(Number(j[0].lat).toFixed(6)), lng: Number(Number(j[0].lon).toFixed(6)), tipo: String(j[0].type ?? '') } : null;
  };
  const rua = [e.numero, e.logradouro].filter(Boolean).join(' ');
  const base: Record<string, string> = {};
  if (e.cidade) base.city = e.cidade;
  if (e.uf) base.state = e.uf;
  // 1º: rua e número; 2º: só a rua; 3º: CEP
  if (rua) {
    const r = await buscar({ ...base, street: rua });
    if (r) return { lat: r.lat, lng: r.lng, exato: !!e.numero && ['house', 'building', 'commercial', 'yes'].includes(r.tipo) };
  }
  if (e.logradouro && e.numero) {
    const r = await buscar({ ...base, street: e.logradouro });
    if (r) return { lat: r.lat, lng: r.lng, exato: false };
  }
  if (e.cep) {
    const r = await buscar({ postalcode: e.cep, country: 'Brasil' });
    if (r) return { lat: r.lat, lng: r.lng, exato: false };
  }
  return null;
}
