import { Moon } from 'lucide-react';
import { RelatorioDiario } from '@/components/relatorios/RelatorioDiario';
import { formatMinutos } from '@/lib/format';
import type { RelatorioNoturnoItem } from '@/lib/types';

export default function RelatorioNoturno() {
  return (
    <RelatorioDiario<RelatorioNoturnoItem>
      titulo="Relatório de adicional noturno"
      descricao="Horas trabalhadas na faixa noturna da regra de cálculo, com a hora noturna reduzida (52min30s) e o percentual do adicional."
      icon={Moon}
      rpc="api_relatorio_noturno"
      arquivo="adicional_noturno"
      vazio="Nenhuma hora noturna no período"
      resumo={(itens) => [
        ['Colaboradores', new Set(itens.map((i) => i.colaborador_id)).size],
        ['Dias com noturno', itens.length],
        ['Horas noturnas (relógio)', formatMinutos(itens.reduce((s, i) => s + i.noturno_min, 0))],
        ['Horas noturnas (reduzidas)', formatMinutos(itens.reduce((s, i) => s + i.noturno_reduzido_min, 0))],
      ]}
      colunas={[
        { titulo: 'Horário previsto', valor: (i) => i.horario ?? '—', csv: (i) => i.horario ?? '' },
        { titulo: 'Faixa noturna', valor: (i) => i.faixa, csv: (i) => i.faixa },
        { titulo: 'Trabalhado', direita: true, valor: (i) => formatMinutos(i.trabalhado_min), csv: (i) => formatMinutos(i.trabalhado_min) },
        { titulo: 'Noturno (relógio)', direita: true, valor: (i) => formatMinutos(i.noturno_min), csv: (i) => formatMinutos(i.noturno_min) },
        {
          titulo: 'Noturno a pagar', direita: true,
          valor: (i) => <span className="font-semibold text-primary-700">{formatMinutos(i.noturno_reduzido_min)}{i.reduzida && <sup className="ml-px text-slate-400">R</sup>}</span>,
          csv: (i) => formatMinutos(i.noturno_reduzido_min),
        },
        { titulo: 'Adicional', direita: true, valor: (i) => `${i.percentual}%`, csv: (i) => `${i.percentual}%` },
      ]}
    />
  );
}
