import type { PerfilEvento } from './types';

/** Dias do percentual de hora extra, na ordem da tela (0 = domingo … 6 = sábado, 7 = feriado, 8 = folga) */
export const DIAS_HE: { dia: number; nome: string; curto: string }[] = [
  { dia: 1, nome: 'Segunda', curto: 'Seg' },
  { dia: 2, nome: 'Terça', curto: 'Ter' },
  { dia: 3, nome: 'Quarta', curto: 'Qua' },
  { dia: 4, nome: 'Quinta', curto: 'Qui' },
  { dia: 5, nome: 'Sexta', curto: 'Sex' },
  { dia: 6, nome: 'Sábado', curto: 'Sáb' },
  { dia: 0, nome: 'Domingo', curto: 'Dom' },
  { dia: 7, nome: 'Feriado', curto: 'Fer' },
  { dia: 8, nome: 'Folga', curto: 'Flg' },
];

export function novoPerfilEvento(): PerfilEvento {
  return {
    nome: '',
    descricao: '',
    padrao: false,
    tolerancia_entrada_min: 5,
    tolerancia_saida_min: 5,
    tolerancia_diaria_min: 10,
    tolerancia_modo: 'batida',
    limite_he_diario_min: 120,
    usa_banco_horas: true,
    noturno_inicio: '22:00',
    noturno_fim: '05:00',
    percentual_noturno: 20,
    hora_noturna_reduzida: true,
    ativo: true,
    he: DIAS_HE.map(({ dia }) => ({ dia, percentual: dia === 0 || dia >= 7 ? 100 : 50 })),
  };
}

/** Garante os 9 percentuais (perfis antigos podem vir sem a folga: assume o do domingo) */
export function completarPerfil(p: PerfilEvento): PerfilEvento {
  const pct = (dia: number) => p.he.find((h) => h.dia === dia)?.percentual;
  return {
    ...p,
    tolerancia_modo: p.tolerancia_modo ?? 'batida',
    he: DIAS_HE.map(({ dia }) => ({ dia, percentual: pct(dia) ?? (dia === 8 ? pct(0) ?? 100 : 50) })),
  };
}

/** "50%" com vírgula decimal: 62.5 → "62,5%" */
export const textoPercentual = (p: number) => `${String(Number(p)).replace('.', ',')}%`;
