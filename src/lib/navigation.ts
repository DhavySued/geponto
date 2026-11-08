import {
  AlertOctagon,
  ArrowRightLeft,
  BarChart3,
  CalendarClock,
  CalendarHeart,
  CalendarSearch,
  ClipboardList,
  Clock3,
  FileSpreadsheet,
  FileText,
  Fingerprint,
  Hourglass,
  LayoutDashboard,
  Lock,
  PenLine,
  Stethoscope,
  ShieldCheck,
  SlidersHorizontal,
  Timer,
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
        descricao: 'Registre suas marcações, peça ajustes e consulte seu espelho',
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
        titulo: 'Colaboradores',
        descricao: 'Dados pessoais e profissionais, situação e histórico',
        path: '/cadastros/colaboradores',
        icon: Users,
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
        titulo: 'Perfis de Eventos',
        descricao: 'Tolerâncias, percentual de hora extra por dia, adicional noturno e banco de horas',
        path: '/cadastros/perfis-eventos',
        icon: SlidersHorizontal,
      },
      {
        chave: 'feriados',
        titulo: 'Feriados',
        descricao: 'Feriados nacionais, estaduais, municipais e pontos facultativos',
        path: '/cadastros/feriados',
        icon: CalendarHeart,
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
        chave: 'ocorrencias',
        titulo: 'Ocorrências e Afastamentos',
        descricao: 'Atestados, férias, afastamentos, folgas e abonos — individual ou em lote',
        path: '/movimentos/ocorrencias',
        icon: Stethoscope,
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
        descricao: 'Interjornada, intervalo, jornada acima de 10h e extras acima do limite',
        path: '/relatorios/quebra-regras',
        icon: AlertOctagon,
      },
    ],
  },
];

/** Ícones dos submenus em cascata */
export const ICONES_SUBMENU: Record<string, LucideIcon> = {
  Batidas: Fingerprint,
  'Banco de horas': Hourglass,
};

export const TODAS_PAGINAS = NAVEGACAO.flatMap((g) => g.itens);
