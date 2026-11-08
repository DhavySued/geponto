import type { EventoFolha, TotaisColaborador } from './types';

/**
 * Quantidade de cada evento da folha a partir dos totais do colaborador (minutos ou dias).
 * Faltas e atrasos usam os campos "_folha": só o que não foi para o banco de horas e sem repetir
 * o mesmo débito em dois eventos. Os demais campos de faltas e atrasos são os da tela.
 */
export const VALOR_EVENTO: Record<string, (t: TotaisColaborador) => number> = {
  adicional_noturno: (t) => t.noturno_min,
  faltas_dias: (t) => t.faltas_folha_dias,
  faltas_horas: (t) => t.faltas_folha_min,
  atrasos: (t) => t.atraso_folha_min,
  desconto_horas: (t) => t.desconto_min,
  dsr: (t) => t.dsr_perdidos,
  bh_pago: (t) => t.bh_pago_min,
  bh_descontado: (t) => t.bh_descontado_min,
};

/** Eventos de hora extra: um por percentual (he_50, he_100, he_62_5…), vindos dos perfis de eventos */
export const ehEventoHe = (chave: string) => /^he_\d/.test(chave);

/** Quantidade do evento para o colaborador; null quando o evento não é exportável */
export function valorEvento(chave: string, t: TotaisColaborador): number | null {
  if (ehEventoHe(chave)) return (t.he ?? []).find((h) => h.chave === chave)?.minutos ?? 0;
  return VALOR_EVENTO[chave]?.(t) ?? null;
}

export type FormatoHoras = 'decimal' | 'hhmm';
export type LayoutArquivo = 'csv' | 'txt';

function quantidade(valor: number, unidade: EventoFolha['unidade'], formato: FormatoHoras, layout: LayoutArquivo): string {
  if (unidade === 'dias') return layout === 'txt' ? String(valor * 100).padStart(9, '0') : String(valor);
  if (formato === 'hhmm') {
    const txt = `${String(Math.floor(valor / 60)).padStart(2, '0')}:${String(valor % 60).padStart(2, '0')}`;
    return layout === 'txt' ? txt.replace(':', '').padStart(9, '0') : txt;
  }
  const dec = (valor / 60).toFixed(2);
  return layout === 'txt' ? dec.replace('.', '').padStart(9, '0') : dec.replace('.', ',');
}

/**
 * Arquivo de movimento para a folha: uma linha por colaborador × evento com quantidade.
 *  CSV: matricula;evento;descricao;quantidade
 *  TXT: matrícula (10, zeros à esquerda) + evento (5) + quantidade (9, 2 decimais implícitas)
 */
export function gerarArquivoFolha(
  colaboradores: TotaisColaborador[],
  eventos: EventoFolha[],
  formato: FormatoHoras,
  layout: LayoutArquivo,
): { conteudo: string; linhas: number } {
  const ativos = eventos.filter((e) => e.ativo && e.codigo && (VALOR_EVENTO[e.chave] || ehEventoHe(e.chave)));
  const linhas: string[] = layout === 'csv' ? ['matricula;evento;descricao;quantidade'] : [];
  for (const c of colaboradores) {
    for (const ev of ativos) {
      const v = valorEvento(ev.chave, c);
      if (!v) continue;
      const q = quantidade(v, ev.unidade, formato, layout);
      linhas.push(
        layout === 'csv'
          ? [c.matricula, ev.codigo, ev.descricao, q].join(';')
          : `${c.matricula.replace(/\D/g, '').padStart(10, '0')}${String(ev.codigo).padStart(5, '0').slice(-5)}${q}`,
      );
    }
  }
  return { conteudo: linhas.join('\r\n') + '\r\n', linhas: layout === 'csv' ? linhas.length - 1 : linhas.length };
}

export function baixarArquivo(nome: string, conteudo: string, tipo = 'text/plain') {
  // BOM para o Excel abrir acentos corretamente no CSV
  const blob = new Blob([tipo === 'text/csv' ? '﻿' + conteudo : conteudo], { type: `${tipo};charset=utf-8` });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = nome;
  a.click();
  URL.revokeObjectURL(url);
}
