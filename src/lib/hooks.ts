import { useEffect, useState } from 'react';
import { toISODate } from './format';
import { api, supabase } from './supabase';
import type { FiltrosAux } from './types';

/** Colaboradores, departamentos e motivos para os filtros das telas de movimentos e relatórios. */
export function useFiltrosAux() {
  const [aux, setAux] = useState<FiltrosAux | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  useEffect(() => {
    api<FiltrosAux>('api_filtros_auxiliares')
      .then(setAux)
      .catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar filtros.'));
  }, []);
  return { aux, erro };
}

/** Primeiro e último dia do mês de referência (deslocamento em meses a partir de hoje). */
export function competencia(deslocamento = 0): { ini: string; fim: string } {
  const hoje = new Date();
  const ini = new Date(hoje.getFullYear(), hoje.getMonth() + deslocamento, 1);
  const fim = new Date(hoje.getFullYear(), hoje.getMonth() + deslocamento + 1, 0);
  return { ini: toISODate(ini), fim: toISODate(fim) };
}

/** Domingo de Páscoa (algoritmo de Meeus/Jones/Butcher). */
function pascoa(ano: number): Date {
  const a = ano % 19;
  const b = Math.floor(ano / 100);
  const c = ano % 100;
  const d = Math.floor(b / 4);
  const e = b % 4;
  const f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3);
  const h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4);
  const k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7;
  const m = Math.floor((a + 11 * h + 22 * l) / 451);
  const mes = Math.floor((h + l - 7 * m + 114) / 31);
  const dia = ((h + l - 7 * m + 114) % 31) + 1;
  return new Date(ano, mes - 1, dia);
}

/** Feriados nacionais e pontos facultativos federais do ano. */
export function feriadosNacionais(ano: number): { data: string; descricao: string; tipo: 'nacional' | 'facultativo' }[] {
  const p = pascoa(ano);
  const mais = (dias: number) => {
    const d = new Date(p);
    d.setDate(d.getDate() + dias);
    return toISODate(d);
  };
  const fixo = (mmdd: string) => `${ano}-${mmdd}`;
  return [
    { data: fixo('01-01'), descricao: 'Confraternização Universal', tipo: 'nacional' as const },
    { data: mais(-48), descricao: 'Carnaval', tipo: 'facultativo' as const },
    { data: mais(-47), descricao: 'Carnaval', tipo: 'facultativo' as const },
    { data: mais(-2), descricao: 'Sexta-feira Santa', tipo: 'nacional' as const },
    { data: fixo('04-21'), descricao: 'Tiradentes', tipo: 'nacional' as const },
    { data: fixo('05-01'), descricao: 'Dia do Trabalho', tipo: 'nacional' as const },
    { data: mais(60), descricao: 'Corpus Christi', tipo: 'facultativo' as const },
    { data: fixo('09-07'), descricao: 'Independência do Brasil', tipo: 'nacional' as const },
    { data: fixo('10-12'), descricao: 'Nossa Senhora Aparecida', tipo: 'nacional' as const },
    { data: fixo('11-02'), descricao: 'Finados', tipo: 'nacional' as const },
    { data: fixo('11-15'), descricao: 'Proclamação da República', tipo: 'nacional' as const },
    { data: fixo('11-20'), descricao: 'Dia Nacional de Zumbi e da Consciência Negra', tipo: 'nacional' as const },
    { data: fixo('12-25'), descricao: 'Natal', tipo: 'nacional' as const },
  ].sort((x, y) => x.data.localeCompare(y.data));
}

/**
 * Hora oficial: o relógio das telas de registro segue o servidor (que é quem carimba a batida),
 * no fuso da empresa (Brasília), e não o relógio nem o fuso do computador do colaborador.
 */
export function useHoraOficial() {
  const [offset, setOffset] = useState(0);
  const [fuso, setFuso] = useState('America/Sao_Paulo');
  const [agora, setAgora] = useState(() => new Date());

  useEffect(() => {
    const sincronizar = async () => {
      const inicio = Date.now();
      const { data } = await supabase.rpc('api_hora_oficial');
      if (!data) return;
      const r = data as { agora: string; fuso: string };
      // Compensa metade do tempo de ida e volta da requisição
      setOffset(new Date(r.agora).getTime() - (inicio + Date.now()) / 2);
      setFuso(r.fuso);
    };
    sincronizar();
    const id = window.setInterval(sincronizar, 10 * 60_000);
    return () => window.clearInterval(id);
  }, []);

  useEffect(() => {
    const tick = () => setAgora(new Date(Date.now() + offset));
    tick();
    const id = window.setInterval(tick, 1000);
    return () => window.clearInterval(id);
  }, [offset]);

  return { agora, fuso };
}
