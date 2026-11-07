import type { Jornada, JornadaDia } from './types';

export const DIAS_SEMANA = ['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado'];
export const DIAS_CURTOS = ['Dom', 'Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb'];

/** Minutos entre dois horários "HH:MM" (atravessa a meia-noite). */
export function minutosEntre(a: string | null, b: string | null): number | null {
  if (!a || !b) return null;
  const [ha, ma] = a.split(':').map(Number);
  const [hb, mb] = b.split(':').map(Number);
  const diff = hb * 60 + mb - (ha * 60 + ma);
  return diff >= 0 ? diff : diff + 24 * 60;
}

export function minutosDia(d: JornadaDia): number {
  if (d.folga) return 0;
  const total = minutosEntre(d.entrada, d.saida) ?? 0;
  const intervalo = minutosEntre(d.saida_intervalo, d.retorno_intervalo) ?? 0;
  return Math.max(0, total - intervalo);
}

const FOLGA = { folga: true, entrada: null, saida_intervalo: null, retorno_intervalo: null, saida: null };

/** Modelos de escala de revezamento mais comuns (dias do ciclo em ordem). */
export const MODELOS_ESCALA: { chave: string; nome: string; descricao: string; dias: Omit<JornadaDia, 'dia_semana'>[] }[] = [
  {
    chave: '12x36d',
    nome: '12x36 diurna',
    descricao: '12h de trabalho, 36h de descanso',
    dias: [{ folga: false, entrada: '07:00', saida_intervalo: '12:00', retorno_intervalo: '13:00', saida: '19:00' }, FOLGA],
  },
  {
    chave: '12x36n',
    nome: '12x36 noturna',
    descricao: 'Plantão 19h–7h com intervalo',
    dias: [{ folga: false, entrada: '19:00', saida_intervalo: '01:00', retorno_intervalo: '02:00', saida: '07:00' }, FOLGA],
  },
  {
    chave: '5x1',
    nome: '5x1',
    descricao: '5 dias de trabalho, 1 de folga',
    dias: [
      ...Array.from({ length: 5 }, () => ({ folga: false, entrada: '08:00', saida_intervalo: '12:00', retorno_intervalo: '13:00', saida: '16:20' })),
      FOLGA,
    ],
  },
  {
    chave: '6x2',
    nome: '6x2',
    descricao: '6 dias de trabalho, 2 de folga',
    dias: [
      ...Array.from({ length: 6 }, () => ({ folga: false, entrada: '07:00', saida_intervalo: '11:00', retorno_intervalo: '12:00', saida: '16:00' })),
      FOLGA,
      FOLGA,
    ],
  },
  {
    chave: '4x2',
    nome: '4x2',
    descricao: '4 dias de trabalho, 2 de folga',
    dias: [
      ...Array.from({ length: 4 }, () => ({ folga: false, entrada: '07:00', saida_intervalo: '12:00', retorno_intervalo: '13:00', saida: '18:00' })),
      FOLGA,
      FOLGA,
    ],
  },
];

/** Dias da escala com o índice do ciclo preenchido. */
export function diasDoModelo(chave: string): JornadaDia[] {
  const m = MODELOS_ESCALA.find((x) => x.chave === chave) ?? MODELOS_ESCALA[0];
  return m.dias.map((d, i) => ({ ...d, dia_semana: i }));
}

/** Ajusta a lista de dias ao novo tamanho do ciclo, mantendo os já preenchidos. */
export function redimensionarCiclo(dias: JornadaDia[], ciclo: number): JornadaDia[] {
  return Array.from({ length: ciclo }, (_, i) => dias.find((d) => d.dia_semana === i) ?? { ...FOLGA, dia_semana: i });
}

/** Rótulo de um dia da jornada: "Segunda" (semanal) ou "Dia 1" (escala). */
export function rotuloDiaJornada(j: Pick<Jornada, 'tipo'>, dia: number): string {
  return j.tipo === 'escala' ? `Dia ${dia + 1}` : DIAS_SEMANA[dia];
}

/** Resumo do ciclo: "12x36 · 07:00–19:00" etc. */
export function resumoCiclo(dias: JornadaDia[]): string {
  const trabalho = dias.filter((d) => !d.folga).length;
  return `${trabalho} dia${trabalho === 1 ? '' : 's'} de trabalho · ${dias.length - trabalho} de folga`;
}

export function novaJornada(): Jornada {
  return {
    nome: '',
    descricao: '',
    tipo: 'semanal',
    ciclo_dias: null,
    data_base: null,
    noturno_inicio: '22:00',
    noturno_fim: '05:00',
    percentual_noturno: 20,
    hora_noturna_reduzida: true,
    tolerancia_entrada_min: 5,
    tolerancia_saida_min: 5,
    tolerancia_diaria_min: 10,
    percentual_he_dia_util: 50,
    percentual_he_domingo: 100,
    limite_he_diario_min: 120,
    usa_banco_horas: true,
    ativo: true,
    dias: DIAS_SEMANA.map((_, i) => ({
      dia_semana: i,
      folga: i === 0 || i === 6,
      entrada: i === 0 || i === 6 ? null : '08:00',
      saida_intervalo: i === 0 || i === 6 ? null : '12:00',
      retorno_intervalo: i === 0 || i === 6 ? null : '13:00',
      saida: i === 0 || i === 6 ? null : '17:00',
    })),
  };
}

export function horarioTexto(d: JornadaDia): string {
  if (d.folga) return 'Folga';
  const partes = d.saida_intervalo
    ? `${d.entrada}–${d.saida_intervalo} · ${d.retorno_intervalo}–${d.saida}`
    : `${d.entrada}–${d.saida}`;
  return partes;
}

/** Agrupa dias consecutivos com o mesmo horário: "Seg–Qui 08:00–12:00 · 13:00–18:00". */
export function resumoEscala(dias: JornadaDia[]): { dias: string; horario: string }[] {
  // Começa na segunda para a leitura ficar natural (Seg … Dom)
  const ordem = [1, 2, 3, 4, 5, 6, 0].map((i) => dias.find((d) => d.dia_semana === i)).filter(Boolean) as JornadaDia[];
  const grupos: { ini: number; fim: number; horario: string }[] = [];
  for (const d of ordem) {
    const h = horarioTexto(d);
    const ultimo = grupos[grupos.length - 1];
    if (ultimo && ultimo.horario === h) ultimo.fim = d.dia_semana;
    else grupos.push({ ini: d.dia_semana, fim: d.dia_semana, horario: h });
  }
  return grupos
    .filter((g) => g.horario !== 'Folga')
    .map((g) => ({
      dias: g.ini === g.fim ? DIAS_CURTOS[g.ini] : `${DIAS_CURTOS[g.ini]}–${DIAS_CURTOS[g.fim]}`,
      horario: g.horario,
    }));
}
