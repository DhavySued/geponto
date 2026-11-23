import { UserX } from 'lucide-react';
import { RelatorioDiario } from '@/components/relatorios/RelatorioDiario';
import { Badge, type BadgeTone } from '@/components/ui/Badge';
import { formatMinutos } from '@/lib/format';
import type { RelatorioFaltasItem } from '@/lib/types';

const SITUACAO: Record<RelatorioFaltasItem['situacao'], { label: string; tone: BadgeTone }> = {
  injustificada: { label: 'Sem justificativa', tone: 'red' },
  justificada: { label: 'Justificada', tone: 'orange' },
  abonada: { label: 'Abonada', tone: 'green' },
};

export default function RelatorioFaltas() {
  return (
    <RelatorioDiario<RelatorioFaltasItem>
      titulo="Listagem de faltas"
      descricao="Dias previstos e já encerrados em que o colaborador não bateu o ponto. Férias, atestados e afastamentos que abonam o dia não entram."
      icon={UserX}
      rpc="api_relatorio_faltas"
      arquivo="faltas"
      maxDias={92}
      vazio="Nenhuma falta no período"
      resumo={(itens) => {
        const faltas = itens.filter((i) => i.situacao !== 'abonada');
        return [
          ['Colaboradores com falta', new Set(faltas.map((i) => i.colaborador_id)).size],
          ['Faltas', faltas.length],
          ['Sem justificativa', itens.filter((i) => i.situacao === 'injustificada').length],
          ['Abonadas', itens.filter((i) => i.situacao === 'abonada').length],
        ];
      }}
      colunas={[
        { titulo: 'Horário previsto', valor: (i) => i.horario ?? '—', csv: (i) => i.horario ?? '' },
        { titulo: 'Previsto', direita: true, valor: (i) => formatMinutos(i.previsto_min), csv: (i) => formatMinutos(i.previsto_min) },
        {
          titulo: 'Situação',
          valor: (i) => <Badge tone={SITUACAO[i.situacao].tone} dot={false}>{SITUACAO[i.situacao].label}</Badge>,
          csv: (i) => SITUACAO[i.situacao].label,
        },
        {
          titulo: 'Motivo',
          valor: (i) => (i.motivo ? <span className="whitespace-normal">{i.motivo}</span> : <span className="text-slate-300">—</span>),
          csv: (i) => i.motivo ?? '',
        },
        {
          titulo: 'Desconto',
          valor: (i) => (i.situacao === 'abonada' ? '—' : i.folha ? 'Folha' : 'Banco de horas'),
          csv: (i) => (i.situacao === 'abonada' ? '' : i.folha ? 'Folha' : 'Banco de horas'),
        },
      ]}
    />
  );
}
