import {
  AlertOctagon,
  ArrowRightLeft,
  BarChart3,
  CalendarClock,
  Building2,
  CalendarDays,
  CalendarRange,
  CalendarSearch,
  ClipboardList,
  Clock3,
  FileSpreadsheet,
  FileText,
  Fingerprint,
  Hourglass,
  KeyRound,
  LayoutDashboard,
  MessageSquareText,
  Lock,
  MapPinned,
  PenLine,
  ScrollText,
  Stethoscope,
  ShieldCheck,
  Settings,
  SlidersHorizontal,
  Timer,
  UserCog,
  Users,
  type LucideIcon,
} from 'lucide-react';
import type { PaginaChave } from './types';

export interface NavItem {
  chave: PaginaChave;
  titulo: string;
  descricao: string;
  path: string;
  icon: LucideIcon;
  /** Submenu (cascata) dentro do grupo no menu superior */
  submenu?: string;
}

export interface NavGroup {
  titulo: string;
  icon: LucideIcon;
  itens: NavItem[];
}

export const NAVEGACAO: NavGroup[] = [
  {
    titulo: 'Meu Ponto',
    icon: Timer,
    itens: [
      {
        chave: 'meu_ponto',
        titulo: 'Registrar ponto',
        descricao: 'Registre suas marcações e acompanhe as batidas do dia',
        path: '/meu-ponto',
        icon: Timer,
      },
    ],
  },
  {
    titulo: 'Dashboard',
    icon: LayoutDashboard,
    itens: [
      {
        chave: 'dashboard',
        titulo: 'Visão geral',
        descricao: 'Banco de horas, faltas, atrasos e registros do dia',
        path: '/',
        icon: LayoutDashboard,
      },
    ],
  },
  {
    titulo: 'Cadastros',
    icon: ClipboardList,
    itens: [
      {
        chave: 'colaboradores',
        titulo: 'Cadastro de Colaboradores',
        descricao: 'Dados pessoais, endereço, acesso ao ponto e histórico',
        path: '/cadastros/colaboradores',
        icon: Users,
        submenu: 'Colaboradores',
      },
      {
        chave: 'situacoes_colaborador',
        titulo: 'Situação do Colaborador',
        descricao: 'Situação, cargo, departamento, jornada, regra de cálculo e salário a partir de uma data',
        path: '/cadastros/colaboradores/situacoes',
        icon: UserCog,
        submenu: 'Colaboradores',
      },
      {
        chave: 'jornadas',
        titulo: 'Jornadas e Escalas',
        descricao: 'Horários semanais e escalas 12x36 e de revezamento',
        path: '/cadastros/jornadas',
        icon: CalendarClock,
      },
      {
        chave: 'perfis_eventos',
        titulo: 'Regras de Cálculo',
        descricao: 'Tolerâncias, percentual de hora extra por dia, adicional noturno e banco de horas',
        path: '/cadastros/perfis-eventos',
        icon: SlidersHorizontal,
      },
      {
        chave: 'feriados',
        titulo: 'Feriados',
        descricao: 'Feriados nacionais, estaduais, municipais e pontos facultativos',
        path: '/cadastros/feriados',
        icon: CalendarDays,
      },
      {
        chave: 'usuarios',
        titulo: 'Usuários & Permissões',
        descricao: 'Acessos ao sistema, perfis e níveis de permissão',
        path: '/cadastros/usuarios',
        icon: ShieldCheck,
      },
    ],
  },
  {
    titulo: 'Movimentos',
    icon: Clock3,
    itens: [
      {
        chave: 'consulta_batidas',
        submenu: 'Batidas',
        titulo: 'Consulta de Batidas',
        descricao: 'Uma linha por batida, com o horário previsto e a situação de cada marcação',
        path: '/movimentos/consulta-batidas',
        icon: CalendarSearch,
      },
      {
        chave: 'lancamento_manual',
        submenu: 'Batidas',
        titulo: 'Tratamento de Batidas',
        descricao: 'Inclusão, edição, exclusão e desconsideração de batidas com motivo',
        path: '/movimentos/lancamento-manual',
        icon: PenLine,
      },
      {
        chave: 'escalas',
        titulo: 'Escalas',
        descricao: 'Previsão de trabalho ou folga em dias específicos, fora do padrão da jornada',
        path: '/movimentos/escalas',
        icon: CalendarRange,
      },
      {
        chave: 'ocorrencias',
        titulo: 'Ocorrências e Afastamentos',
        descricao: 'Atestados, férias, afastamentos, folgas e abonos — individual ou em lote',
        path: '/movimentos/ocorrencias',
        icon: Stethoscope,
      },
      {
        chave: 'justificativas',
        titulo: 'Justificativas',
        descricao: 'Justifica ou abona atrasos, saídas antecipadas e faltas',
        path: '/movimentos/justificativas',
        icon: MessageSquareText,
      },
      {
        chave: 'banco_horas',
        submenu: 'Banco de horas',
        titulo: 'Banco de Horas',
        descricao: 'Créditos, débitos e compensações',
        path: '/movimentos/banco-horas',
        icon: Hourglass,
      },
      {
        chave: 'banco_horas_conversao',
        submenu: 'Banco de horas',
        titulo: 'Conversão do Banco de Horas',
        descricao: 'Converte o saldo em pagamento de horas extras ou em desconto na folha',
        path: '/movimentos/conversao-banco-horas',
        icon: ArrowRightLeft,
      },
      {
        chave: 'fechamento',
        titulo: 'Fechamento de Período',
        descricao: 'Confere pendências e congela o ponto da competência',
        path: '/movimentos/fechamento',
        icon: Lock,
      },
    ],
  },
  {
    titulo: 'Relatórios',
    icon: BarChart3,
    itens: [
      {
        chave: 'espelho_ponto',
        titulo: 'Espelho de Ponto',
        descricao: 'Relatório mensal por colaborador, pronto para impressão e assinatura',
        path: '/relatorios/espelho-ponto',
        icon: FileText,
      },
      {
        chave: 'totais_periodo',
        titulo: 'Totais e Exportação p/ Folha',
        descricao: 'Horas extras, noturno, faltas, atrasos e DSR por colaborador, com arquivo para a folha',
        path: '/relatorios/totais',
        icon: FileSpreadsheet,
      },
      {
        chave: 'quebra_regras',
        titulo: 'Quebra de Regras',
        descricao: 'Interjornada, intervalo, jornada acima de 10h, extras acima do limite e batidas fora do local',
        path: '/relatorios/quebra-regras',
        icon: AlertOctagon,
      },
      {
        chave: 'locais_batidas',
        titulo: 'Locais das Batidas',
        descricao: 'Endereço, local de ponto e distância de cada batida registrada pelo sistema',
        path: '/relatorios/locais-batidas',
        icon: MapPinned,
      },
      {
        chave: 'relatorio_banco_horas',
        titulo: 'Banco de Horas',
        descricao: 'Saldo anterior, créditos, débitos, ajustes, conversões e saldo final de cada colaborador',
        path: '/relatorios/banco-horas',
        icon: Hourglass,
      },
      {
        chave: 'relatorio_escalas',
        titulo: 'Escalas',
        descricao: 'Dias escalados no período, com horário, feriados e o que foi realizado',
        path: '/relatorios/escalas',
        icon: CalendarRange,
      },
    ],
  },
  {
    titulo: 'Configurações',
    icon: Settings,
    itens: [
      {
        chave: 'empresas',
        titulo: 'Empresas',
        descricao: 'Dados das empresas (CNPJ, endereço) e o local de ponto de cada uma',
        path: '/configuracoes/empresas',
        icon: Building2,
      },
      {
        chave: 'configuracoes',
        titulo: 'Registro de Ponto',
        descricao: 'Limitações para o registro de ponto (cerca virtual)',
        path: '/configuracoes/registro-ponto',
        icon: Fingerprint,
      },
      {
        chave: 'integracoes',
        titulo: 'Integrações (API)',
        descricao: 'Chaves de acesso para relógios, folha de pagamento e outros sistemas',
        path: '/configuracoes/integracoes',
        icon: KeyRound,
      },
      {
        chave: 'auditoria',
        titulo: 'Log e Auditoria',
        descricao: 'Quem incluiu, alterou ou excluiu cada informação, e os acessos ao sistema',
        path: '/configuracoes/auditoria',
        icon: ScrollText,
      },
    ],
  },
];

/** Ícones dos submenus em cascata */
export const ICONES_SUBMENU: Record<string, LucideIcon> = {
  Colaboradores: Users,
  Batidas: Fingerprint,
  'Banco de horas': Hourglass,
};

export const TODAS_PAGINAS = NAVEGACAO.flatMap((g) => g.itens);
