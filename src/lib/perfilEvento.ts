import type { PerfilEvento } from './types';

/** Dias do percentual de hora extra, na ordem da tela (0 = domingo … 6 = sábado, 7 = feriado) */
export const DIAS_HE: { dia: number; nome: string; curto: string }[] = [
  { dia: 1, nome: 'Segunda', curto: 'Seg' },
  { dia: 2, nome: 'Terça', curto: 'Ter' },
  { dia: 3, nome: 'Quarta', curto: 'Qua' },
  { dia: 4, nome: 'Quinta', curto: 'Qui' },
  { dia: 5, nome: 'Sexta', curto: 'Sex' },
  { dia: 6, nome: 'Sábado', curto: 'Sáb' },
  { dia: 0, nome: 'Domingo', curto: 'Dom' },
  { dia: 7, nome: 'Feriado', curto: 'Fer' },
];

export function novoPerfilEvento(): PerfilEvento {
  return {
    nome: '',
    descricao: '',
    padrao: false,
    tolerancia_entrada_min: 5,
    tolerancia_saida_min: 5,
    tolerancia_diaria_min: 10,
    limite_he_diario_min: 120,
    usa_banco_horas: true,
    noturno_inicio: '22:00',
    noturno_fim: '05:00',
    percentual_noturno: 20,
    hora_noturna_reduzida: true,
    ativo: true,
    he: [0, 1, 2, 3, 4, 5, 6, 7].map((dia) => ({ dia, percentual: dia === 0 || dia === 7 ? 100 : 50 })),
  };
}

/** "50%" com vírgula decimal: 62.5 → "62,5%" */
export const textoPercentual = (p: number) => `${String(Number(p)).replace('.', ',')}%`;
