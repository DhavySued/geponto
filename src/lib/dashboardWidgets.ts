/** Indicadores e gráficos do dashboard geral, que cada empresa liga ou desliga em Configurações › Dashboard */
export type WidgetChave =
  | 'kpi_presentes'
  | 'kpi_faltas'
  | 'kpi_atrasos'
  | 'kpi_saldo_bh'
  | 'banco_horas'
  | 'situacao'
  | 'absenteismo'
  | 'ranking_atrasos'
  | 'registros_hoje';

export interface WidgetInfo {
  chave: WidgetChave;
  titulo: string;
  descricao: string;
  tipo: 'indicador' | 'grafico';
  /** Largura no painel: 1 = um terço, 2 = dois terços, 3 = linha inteira */
  largura: 1 | 2 | 3;
  padrao: boolean;
}

export const WIDGETS: WidgetInfo[] = [
  { chave: 'kpi_presentes', tipo: 'indicador', largura: 1, padrao: true, titulo: 'Presentes hoje', descricao: 'Presentes e escalados do dia, com as marcações registradas hoje' },
  { chave: 'kpi_faltas', tipo: 'indicador', largura: 1, padrao: true, titulo: 'Faltas no período', descricao: 'Faltas, taxa de absenteísmo e ausentes hoje' },
  { chave: 'kpi_atrasos', tipo: 'indicador', largura: 1, padrao: true, titulo: 'Atrasos no período', descricao: 'Quantidade e tempo total de atraso, e atrasados hoje' },
  { chave: 'kpi_saldo_bh', tipo: 'indicador', largura: 1, padrao: false, titulo: 'Saldo do banco de horas', descricao: 'Saldo líquido, com o total positivo e negativo e quantos colaboradores' },
  { chave: 'banco_horas', tipo: 'grafico', largura: 2, padrao: true, titulo: 'Banco de horas por colaborador', descricao: 'Gráfico do saldo acumulado até o fim do período' },
  { chave: 'situacao', tipo: 'grafico', largura: 1, padrao: true, titulo: 'Situação dos colaboradores', descricao: 'Ativos, férias, afastados e desligados' },
  { chave: 'absenteismo', tipo: 'grafico', largura: 2, padrao: true, titulo: 'Faltas e atrasos por dia', descricao: 'Ocorrências diárias no período' },
  { chave: 'ranking_atrasos', tipo: 'grafico', largura: 1, padrao: true, titulo: 'Maiores atrasos', descricao: 'Top 5 por tempo de atraso no período' },
  { chave: 'registros_hoje', tipo: 'grafico', largura: 3, padrao: true, titulo: 'Registros diários', descricao: 'Batidas de hoje, ao vivo' },
];

export type ConfigDashboard = Partial<Record<WidgetChave, boolean>>;

export const widgetLigado = (cfg: ConfigDashboard | null, chave: WidgetChave) =>
  cfg?.[chave] ?? WIDGETS.find((w) => w.chave === chave)!.padrao;

/**
 * Distribui os painéis em linhas de 3 colunas, na ordem: quando um painel não cabe, fecha a linha e o
 * último painel dela estica até o fim — assim, desligar um gráfico não deixa buraco no layout.
 */
export function distribuir<T extends { largura: number }>(itens: T[]): (T & { span: number })[][] {
  const linhas: (T & { span: number })[][] = [];
  let atual: (T & { span: number })[] = [];
  let soma = 0;
  const fechar = () => {
    if (!atual.length) return;
    atual[atual.length - 1].span += 3 - soma;
    linhas.push(atual);
    atual = [];
    soma = 0;
  };
  for (const i of itens) {
    if (soma + i.largura > 3) fechar();
    atual.push({ ...i, span: i.largura });
    soma += i.largura;
  }
  fechar();
  return linhas;
}
