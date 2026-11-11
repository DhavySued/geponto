import type { BadgeTone } from '@/components/ui/Badge';
import type { Sentido, SituacaoBatida, TipoAusencia } from './types';

/** Classificação da batida (vem do servidor: declarada pelo RH ou pela sequência do dia). */
export function rotuloMarcacao(sentido: Sentido | null | undefined, turno: number | null | undefined): string {
  return `${sentido === 'S' ? 'Saída' : 'Entrada'} do ${turno ?? 1}º turno`;
}

/** Forma curta para chips e listas: E1, S1, E2, S2… */
export function siglaMarcacao(sentido: Sentido | null | undefined, turno: number | null | undefined): string {
  return `${sentido ?? 'E'}${turno ?? 1}`;
}

/** Classificações que o RH pode declarar (o colaborador nunca escolhe). */
export const CLASSIFICACOES: { sentido: Sentido; turno: number }[] = [1, 2, 3].flatMap((turno) => [
  { sentido: 'E' as Sentido, turno },
  { sentido: 'S' as Sentido, turno },
]);

const OCORRENCIAS: Record<string, { label: string; tone: BadgeTone }> = {
  normal: { label: 'Normal', tone: 'green' },
  atraso: { label: 'Atraso', tone: 'orange' },
  falta: { label: 'Falta', tone: 'red' },
  folga: { label: 'Folga', tone: 'slate' },
  feriado: { label: 'Feriado', tone: 'slate' },
  inconsistente: { label: 'Marcação ímpar', tone: 'orange' },
  saida_antecipada: { label: 'Saída antecipada', tone: 'orange' },
  hora_extra: { label: 'Hora extra', tone: 'violet' },
  em_andamento: { label: 'Em andamento', tone: 'blue' },
  sem_jornada: { label: 'Sem jornada', tone: 'slate' },
};

export const TIPOS_AUSENCIA: Record<TipoAusencia, { label: string; descricao: string }> = {
  atestado: { label: 'Atestado médico', descricao: 'Ausência por motivo de saúde com atestado' },
  afastamento: { label: 'Afastamento', descricao: 'INSS, licença maternidade/paternidade e outros' },
  ferias: { label: 'Férias', descricao: 'Período de gozo de férias' },
  folga: { label: 'Folga', descricao: 'Folga concedida ou compensada' },
  falta_justificada: { label: 'Falta justificada', descricao: 'Falta legal (CLT art. 473): casamento, óbito, doação…' },
  abono: { label: 'Abono', descricao: 'Abono do dia inteiro ou de algumas horas' },
};

export function ocorrencia(chave: string): { label: string; tone: BadgeTone } {
  if (chave.startsWith('ausencia:')) {
    const tipo = chave.split(':')[1] as TipoAusencia;
    return { label: TIPOS_AUSENCIA[tipo]?.label ?? tipo, tone: 'blue' };
  }
  return OCORRENCIAS[chave] ?? { label: chave, tone: 'slate' };
}

/** Situação de cada batida na Consulta (comparada ao horário previsto, com as tolerâncias da jornada). */
export const SITUACAO_BATIDA: Record<SituacaoBatida, { label: string; descricao: string; tone: BadgeTone }> = {
  precisa: { label: 'Batida precisa', descricao: 'Exatamente no minuto previsto', tone: 'green' },
  entrada_tolerancia: { label: 'Entrada dentro da tolerância', descricao: 'Entrada fora do minuto previsto, mas dentro da tolerância da jornada', tone: 'green' },
  saida_tolerancia: { label: 'Saída dentro da tolerância', descricao: 'Saída fora do minuto previsto, mas dentro da tolerância da jornada', tone: 'green' },
  atraso: { label: 'Batida em atraso', descricao: 'Entrada depois do previsto, além da tolerância', tone: 'orange' },
  antecipada: { label: 'Antes do previsto', descricao: 'Entrada antes do horário previsto, além da tolerância', tone: 'blue' },
  saida_antecipada: { label: 'Saída antecipada', descricao: 'Saída antes do horário previsto, além da tolerância', tone: 'red' },
  apos_previsto: { label: 'Após o previsto', descricao: 'Saída depois do horário previsto, além da tolerância', tone: 'violet' },
  feriado: { label: 'Batida em feriado', descricao: 'Marcação em dia de feriado', tone: 'primary' },
  folga: { label: 'Batida em dia de folga', descricao: 'Marcação em dia de folga da jornada ou da escala', tone: 'primary' },
  nao_controlada: { label: 'Batida não controlada', descricao: 'Colaborador sem controle de ponto no dia: a batida fica registrada, mas não entra na apuração', tone: 'slate' },
  ausencia: { label: 'Batida em ausência', descricao: 'Marcação em dia de férias, atestado ou afastamento', tone: 'primary' },
  fora_jornada: { label: 'Fora da jornada', descricao: 'Marcação além dos turnos previstos para o dia', tone: 'slate' },
  sem_jornada: { label: 'Sem jornada', descricao: 'Colaborador sem jornada de trabalho no dia', tone: 'slate' },
  desconsiderada: { label: 'Desconsiderada', descricao: 'Não entra na apuração', tone: 'slate' },
  turno_incompleto: { label: 'Turno incompleto', descricao: 'Batida sem o par (entrada sem saída ou saída sem entrada): o turno não é apurado', tone: 'orange' },
  turno_aberto: { label: 'Turno em andamento', descricao: 'Entrada de hoje aguardando a saída', tone: 'blue' },
  nao_registrada: { label: 'Não registrada', descricao: 'Marcação prevista na jornada que não foi batida', tone: 'red' },
  dia_ausencia: { label: 'Ausência registrada', descricao: 'Dia de férias, afastamento, atestado ou abono, sem batidas', tone: 'blue' },
  dia_feriado: { label: 'Feriado', descricao: 'Feriado sem batidas', tone: 'slate' },
  pendente: { label: 'Aguardando', descricao: 'Marcação prevista para mais tarde', tone: 'slate' },
};

/** Aviso ao colaborador quando a batida não é de um dia normal de trabalho */
export const SITUACAO_DIA_BATIDA: Record<'nao_controlada' | 'feriado' | 'folga', { titulo: string; texto: string }> = {
  nao_controlada: {
    titulo: 'Batida não controlada',
    texto: 'Seu ponto não é controlado pelo sistema: a batida fica registrada, mas não entra na apuração de horas.',
  },
  folga: { titulo: 'Batida em dia de folga', texto: 'Hoje é folga na sua jornada: a batida fica registrada como batida em dia de folga.' },
  feriado: { titulo: 'Batida em feriado', texto: 'Hoje é feriado: a batida fica registrada como batida em feriado.' },
};

export const ORIGEM_BATIDA: Record<string, string> = {
  relogio: 'Relógio',
  web: 'Sistema',
  mobile: 'Celular',
  manual: 'Manual',
  importacao: 'Importação',
};
