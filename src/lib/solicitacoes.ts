import type { BadgeTone } from '@/components/ui/Badge';
import { formatData, formatMinutos } from './format';
import { TIPOS_AUSENCIA } from './ponto';
import type { Solicitacao, StatusSolicitacao } from './types';

export const STATUS_SOLICITACAO: Record<StatusSolicitacao, { label: string; tone: BadgeTone }> = {
  pendente: { label: 'Pendente', tone: 'orange' },
  aprovada: { label: 'Aprovada', tone: 'green' },
  reprovada: { label: 'Reprovada', tone: 'red' },
  cancelada: { label: 'Cancelada', tone: 'slate' },
};

/** Texto do que foi pedido: "Batida de entrada às 08:00" ou "Atestado médico até 12/10". */
export function resumoSolicitacao(s: Solicitacao): string {
  if (s.tipo === 'inclusao_batida') {
    const sentido = s.sentido === 'E' ? ' de entrada' : s.sentido === 'S' ? ' de saída' : '';
    return `Incluir batida${sentido} às ${s.hora}`;
  }
  const tipo = s.tipo_ausencia ? TIPOS_AUSENCIA[s.tipo_ausencia].label : 'Abono';
  if (s.minutos) return `${tipo} de ${formatMinutos(s.minutos)}`;
  if (s.data_fim && s.data_fim !== s.data) return `${tipo} até ${formatData(s.data_fim)}`;
  return `${tipo} do dia inteiro`;
}
