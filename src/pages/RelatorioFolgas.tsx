import { Coffee } from 'lucide-react';
import { RelatorioDiario } from '@/components/relatorios/RelatorioDiario';
import { Badge } from '@/components/ui/Badge';
import { formatMinutos } from '@/lib/format';
import type { RelatorioFolgasItem } from '@/lib/types';

const ORIGEM: Record<RelatorioFolgasItem['origem'], string> = {
  jornada: 'Jornada',
  escala: 'Escala',
  ocorrencia: 'Folga lançada',
};

export default function RelatorioFolgas() {
  return (
    <RelatorioDiario<RelatorioFolgasItem>
      titulo="Relatório de folgas"
      descricao="Dias de folga de cada colaborador (pela jornada, pela escala ou lançados como ocorrência) e se houve trabalho na folga."
      icon={Coffee}
      rpc="api_relatorio_folgas"
      arquivo="folgas"
      vazio="Nenhuma folga no período"
      resumo={(itens) => [
        ['Colaboradores', new Set(itens.map((i) => i.colaborador_id)).size],
        ['Folgas', itens.length],
        ['Trabalhou na folga', itens.filter((i) => i.trabalhou).length],
        ['Horas em folga', formatMinutos(itens.reduce((s, i) => s + (i.trabalhou ? i.trabalhado_min : 0), 0))],
      ]}
      colunas={[
        { titulo: 'Origem', valor: (i) => ORIGEM[i.origem], csv: (i) => ORIGEM[i.origem] },
        { titulo: 'Feriado', valor: (i) => i.feriado ?? '—', csv: (i) => i.feriado ?? '' },
        {
          titulo: 'Situação',
          valor: (i) => !i.realizado ? <span className="text-xs text-slate-400">a realizar</span>
            : i.trabalhou ? <Badge tone="orange" dot={false}>Trabalhou</Badge> : <Badge tone="green" dot={false}>Folgou</Badge>,
          csv: (i) => (!i.realizado ? 'A realizar' : i.trabalhou ? 'Trabalhou' : 'Folgou'),
        },
        { titulo: 'Trabalhado', direita: true, valor: (i) => (i.trabalhou ? formatMinutos(i.trabalhado_min) : '—'), csv: (i) => (i.trabalhou ? formatMinutos(i.trabalhado_min) : '') },
        {
          titulo: 'Hora extra', direita: true,
          valor: (i) => (i.extra_min ? `${formatMinutos(i.extra_min)} · ${i.he_percentual}%` : '—'),
          csv: (i) => (i.extra_min ? formatMinutos(i.extra_min) : ''),
        },
      ]}
    />
  );
}
