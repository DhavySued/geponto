import { formatMinutos } from './format';
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

type DiaModelo = Omit<JornadaDia, 'dia_semana'>;

export type GrupoTipoJornada = 'Semanal' | 'Revezamento (ciclo)' | 'Livre';

/**
 * Tipo de jornada: lista do sistema, sem cadastro (a mesma chave é aceita em api_jornada_salvar).
 * Os dias são os horários sugeridos; nos semanais, na ordem domingo … sábado.
 */
export interface TipoDeJornada {
  chave: string;
  grupo: GrupoTipoJornada;
  nome: string;
  descricao: string;
  base?: string;
  /** Como os dias se repetem */
  repete: 'semanal' | 'escala';
  dias: DiaModelo[];
  /** Horas semanais do tipo, em minutos: acima disso a tela avisa */
  limiteSemana?: number;
  livre?: boolean;
}

const T = (entrada: string, saida_intervalo: string | null, retorno_intervalo: string | null, saida: string): DiaModelo =>
  ({ folga: false, entrada, saida_intervalo, retorno_intervalo, saida });
const vezes = (n: number, d: DiaModelo): DiaModelo[] => Array.from({ length: n }, () => d);
/** Domingo de folga, segunda a sexta e o sábado */
const semana = (util: DiaModelo, sabado: DiaModelo = FOLGA): DiaModelo[] => [FOLGA, ...vezes(5, util), sabado];

export const TIPOS_JORNADA: TipoDeJornada[] = [
  { chave: '5x2_44', grupo: 'Semanal', nome: '5x2 — 44h semanais', descricao: '8h48 de segunda a sexta, compensando o sábado.',
    base: 'CF, art. 7º, XIII; CLT, art. 59 (acordo de compensação)', repete: 'semanal', limiteSemana: 2640, dias: semana(T('08:00', '12:00', '13:00', '17:48')) },
  { chave: '5x2_40', grupo: 'Semanal', nome: '5x2 — 40h semanais', descricao: '8h de segunda a sexta.',
    base: 'CF, art. 7º, XIII', repete: 'semanal', limiteSemana: 2400, dias: semana(T('08:00', '12:00', '13:00', '17:00')) },
  { chave: '6x1_44', grupo: 'Semanal', nome: '6x1 — 44h semanais (sábado reduzido)', descricao: '8h de segunda a sexta e 4h no sábado.',
    base: 'CF, art. 7º, XIII e XV; Lei 605/49', repete: 'semanal', limiteSemana: 2640, dias: semana(T('08:00', '12:00', '13:00', '17:00'), T('08:00', null, null, '12:00')) },
  { chave: '6x1_7h20', grupo: 'Semanal', nome: '6x1 — 44h semanais (7h20 por dia)', descricao: '7h20 em seis dias, com um dia de descanso.',
    base: 'CF, art. 7º, XIII e XV; Lei 605/49', repete: 'semanal', limiteSemana: 2640, dias: semana(T('08:00', '12:00', '13:00', '16:20'), T('08:00', '12:00', '13:00', '16:20')) },
  { chave: '6x1_36', grupo: 'Semanal', nome: '6x1 — 36h semanais (6h por dia)', descricao: '6h em seis dias, com intervalo de 15 minutos.',
    base: 'CF, art. 7º, XIII; CLT, art. 71, § 1º', repete: 'semanal', limiteSemana: 2160, dias: semana(T('08:00', '11:00', '11:15', '14:15'), T('08:00', '11:00', '11:15', '14:15')) },
  { chave: 'bancario_30', grupo: 'Semanal', nome: 'Bancário — 30h semanais', descricao: '6h de segunda a sexta.',
    base: 'CLT, art. 224', repete: 'semanal', limiteSemana: 1800, dias: semana(T('10:00', '13:00', '13:15', '16:15')) },
  { chave: 'parcial_30', grupo: 'Semanal', nome: 'Tempo parcial — até 30h semanais', descricao: 'Até 30h, sem horas extras.',
    base: 'CLT, art. 58-A', repete: 'semanal', limiteSemana: 1800, dias: semana(T('08:00', '11:00', '11:15', '14:15')) },
  { chave: 'parcial_26', grupo: 'Semanal', nome: 'Tempo parcial — até 26h semanais', descricao: 'Até 26h, com no máximo 6 horas extras por semana.',
    base: 'CLT, art. 58-A', repete: 'semanal', limiteSemana: 1560, dias: semana(T('08:00', '11:00', '11:15', '13:15')) },
  { chave: 'aprendiz_30', grupo: 'Semanal', nome: 'Aprendiz — 6h por dia', descricao: 'Até 6h por dia, sem prorrogação nem compensação.',
    base: 'CLT, art. 432', repete: 'semanal', limiteSemana: 1800, dias: semana(T('08:00', '11:00', '11:15', '14:15')) },
  { chave: 'estagio_30', grupo: 'Semanal', nome: 'Estágio — 30h semanais', descricao: 'Até 6h por dia (ensino superior, médio e profissional).',
    base: 'Lei 11.788/2008, art. 10, II', repete: 'semanal', limiteSemana: 1800, dias: semana(T('08:00', '11:00', '11:15', '14:15')) },
  { chave: 'estagio_20', grupo: 'Semanal', nome: 'Estágio — 20h semanais', descricao: 'Até 4h por dia (educação especial e anos finais do fundamental).',
    base: 'Lei 11.788/2008, art. 10, I', repete: 'semanal', limiteSemana: 1200, dias: semana(T('08:00', null, null, '12:00')) },
  { chave: 'intermitente', grupo: 'Semanal', nome: 'Intermitente', descricao: 'Sem horário fixo: os dias convocados são lançados no menu Escalas.',
    base: 'CLT, arts. 443, § 3º, e 452-A', repete: 'semanal', dias: vezes(7, FOLGA) },

  { chave: '12x36d', grupo: 'Revezamento (ciclo)', nome: '12x36 diurna', descricao: '12h de trabalho por 36h de descanso.',
    base: 'CLT, art. 59-A', repete: 'escala', dias: [T('07:00', '12:00', '13:00', '19:00'), FOLGA] },
  { chave: '12x36n', grupo: 'Revezamento (ciclo)', nome: '12x36 noturna', descricao: '12h de trabalho (19h às 7h) por 36h de descanso.',
    base: 'CLT, art. 59-A', repete: 'escala', dias: [T('19:00', '01:00', '02:00', '07:00'), FOLGA] },
  { chave: '5x1', grupo: 'Revezamento (ciclo)', nome: '5x1', descricao: '5 dias de 7h20 e 1 de folga.',
    base: 'CF, art. 7º, XIII e XV; convenção coletiva', repete: 'escala', limiteSemana: 2640, dias: [...vezes(5, T('08:00', '12:00', '13:00', '16:20')), FOLGA] },
  { chave: '6x2', grupo: 'Revezamento (ciclo)', nome: '6x2', descricao: '6 dias de 8h e 2 de folga.',
    base: 'CF, art. 7º, XIII e XV; convenção coletiva', repete: 'escala', limiteSemana: 2640, dias: [...vezes(6, T('07:00', '11:00', '12:00', '16:00')), FOLGA, FOLGA] },
  { chave: '4x2', grupo: 'Revezamento (ciclo)', nome: '4x2', descricao: '4 dias de trabalho e 2 de folga.',
    base: 'CF, art. 7º, XIII e XV; convenção coletiva', repete: 'escala', limiteSemana: 2640, dias: [...vezes(4, T('07:00', '12:00', '13:00', '16:00')), FOLGA, FOLGA] },
  { chave: '12x24x12x48', grupo: 'Revezamento (ciclo)', nome: '12x24 / 12x48', descricao: '12h diurnas, 24h de descanso, 12h noturnas e 48h de descanso.',
    base: 'Convenção ou acordo coletivo (CLT, art. 611-A)', repete: 'escala', dias: [T('07:00', '12:00', '13:00', '19:00'), T('19:00', '01:00', '02:00', '07:00'), FOLGA, FOLGA] },
  { chave: 'turno_ininterrupto', grupo: 'Revezamento (ciclo)', nome: 'Turno ininterrupto de revezamento (6h)', descricao: 'Manhã, tarde e noite alternadas: 2 dias em cada turno e 2 de folga.',
    base: 'CF, art. 7º, XIV', repete: 'escala', limiteSemana: 2160,
    dias: [...vezes(2, T('06:00', '09:00', '09:15', '12:15')), ...vezes(2, T('12:00', '15:00', '15:15', '18:15')), ...vezes(2, T('18:00', '21:00', '21:15', '00:15')), FOLGA, FOLGA] },

  { chave: 'semanal_livre', grupo: 'Livre', nome: 'Semanal livre', descricao: 'Horários definidos por você para cada dia da semana.',
    repete: 'semanal', livre: true, dias: semana(T('08:00', '12:00', '13:00', '17:00')) },
  { chave: 'ciclo_livre', grupo: 'Livre', nome: 'Ciclo livre', descricao: 'Você define quantos dias tem o ciclo (2 a 60) e o horário ou a folga de cada um.',
    repete: 'escala', livre: true, dias: [T('08:00', '12:00', '13:00', '17:00'), FOLGA] },
];

export const GRUPOS_TIPO_JORNADA: GrupoTipoJornada[] = ['Semanal', 'Revezamento (ciclo)', 'Livre'];

/** Tipo da jornada; sem tipo gravado (ou fora da lista), o livre correspondente */
export function tipoDaJornada(j: Pick<Jornada, 'tipo' | 'modelo'>): TipoDeJornada {
  return TIPOS_JORNADA.find((t) => t.chave === j.modelo && t.repete === j.tipo)
    ?? TIPOS_JORNADA.find((t) => t.chave === (j.tipo === 'escala' ? 'ciclo_livre' : 'semanal_livre'))!;
}

/** Dias sugeridos do tipo, com o índice (da semana ou do ciclo) preenchido */
export function diasDoTipo(t: TipoDeJornada): JornadaDia[] {
  return t.dias.map((d, i) => ({ ...d, dia_semana: i, dia_util: !d.folga, recebe_vt: !d.folga, recebe_va: !d.folga }));
}

/** Ajusta a lista de dias ao novo tamanho do ciclo, mantendo os já preenchidos. */
export function redimensionarCiclo(dias: JornadaDia[], ciclo: number): JornadaDia[] {
  return Array.from({ length: ciclo }, (_, i) => dias.find((d) => d.dia_semana === i) ?? { ...FOLGA, dia_semana: i });
}

/** Rótulo de um dia da jornada: "Segunda" (semanal) ou "Dia 1" (ciclo). */
export function rotuloDiaJornada(j: Pick<Jornada, 'tipo'>, dia: number): string {
  return j.tipo === 'escala' ? `Dia ${dia + 1}` : DIAS_SEMANA[dia];
}

export function novaJornada(): Jornada {
  return {
    nome: '',
    descricao: '',
    tipo: 'semanal',
    modelo: TIPOS_JORNADA[0].chave,
    ciclo_dias: null,
    data_base: null,
    ativo: true,
    intervalo_flexivel: false,
    intervalo_pre_assinalado: false,
    todas_empresas: false,
    dias: diasDoTipo(TIPOS_JORNADA[0]),
  };
}

export function horarioTexto(d: JornadaDia, intervaloFlexivel = false): string {
  if (d.folga) return 'Folga';
  if (d.saida_intervalo && intervaloFlexivel) {
    const min = minutosEntre(d.saida_intervalo, d.retorno_intervalo) ?? 0;
    return `${d.entrada}–${d.saida} · intervalo flexível de ${formatMinutos(min)}`;
  }
  const partes = d.saida_intervalo
    ? `${d.entrada}–${d.saida_intervalo} · ${d.retorno_intervalo}–${d.saida}`
    : `${d.entrada}–${d.saida}`;
  return partes;
}

/** Agrupa dias consecutivos com o mesmo horário: "Seg–Qui 08:00–12:00 · 13:00–18:00". */
export function resumoEscala(dias: JornadaDia[], intervaloFlexivel = false): { dias: string; horario: string }[] {
  // Começa na segunda para a leitura ficar natural (Seg … Dom)
  const ordem = [1, 2, 3, 4, 5, 6, 0].map((i) => dias.find((d) => d.dia_semana === i)).filter(Boolean) as JornadaDia[];
  const grupos: { ini: number; fim: number; horario: string }[] = [];
  for (const d of ordem) {
    const h = horarioTexto(d, intervaloFlexivel);
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
