/** 754 → "12h34" · -90 → "-1h30" · com sinal: 90 → "+1h30" */
export function formatMinutos(min: number, comSinal = false): string {
  const sinal = min < 0 ? '-' : comSinal && min > 0 ? '+' : '';
  const abs = Math.abs(Math.round(min));
  const h = Math.floor(abs / 60);
  const m = abs % 60;
  return `${sinal}${h}h${String(m).padStart(2, '0')}`;
}

/**
 * Horas digitadas → minutos: "8:30", "8" ou "830" (com 3 dígitos ou mais, os 2 últimos são minutos).
 * O teclado numérico do celular não tem ":", então "230" precisa ser 2h30, e não 230 horas.
 */
export function horasParaMinutos(v: string): number {
  const t = v.trim();
  const [h, m = '0'] = /^\d{3,}$/.test(t) ? [t.slice(0, -2), t.slice(-2)] : t.split(':');
  return (parseInt(h || '0', 10) || 0) * 60 + (parseInt(m, 10) || 0);
}

export function toISODate(d: Date): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, '0');
  const day = String(d.getDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export function parseISODate(s: string): Date {
  const [y, m, d] = s.split('-').map(Number);
  return new Date(y, m - 1, d);
}

export function formatData(
  s: string,
  opts: Intl.DateTimeFormatOptions = { day: '2-digit', month: '2-digit' },
): string {
  return parseISODate(s).toLocaleDateString('pt-BR', opts);
}

export function iniciais(nome: string): string {
  const partes = nome.trim().split(/\s+/);
  const primeira = partes[0]?.[0] ?? '';
  const ultima = partes.length > 1 ? partes[partes.length - 1][0] : '';
  return (primeira + ultima).toUpperCase();
}

export const numero = (n: number) => n.toLocaleString('pt-BR');
