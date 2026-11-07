import type { BadgeTone } from '@/components/ui/Badge';
import type { Abrangencia, StatusUsuario } from './types';

export const ABRANGENCIAS: Record<Abrangencia, { label: string; descricao: string }> = {
  todos: {
    label: 'Todos os colaboradores',
    descricao: 'Vê e trata o ponto de toda a empresa (RH, administração, consulta).',
  },
  equipe: {
    label: 'Somente a equipe',
    descricao: 'Vê o próprio ponto e o dos subordinados diretos (campo "Gestor" no cadastro do colaborador).',
  },
  proprio: {
    label: 'Somente o próprio',
    descricao: 'Vê apenas as próprias informações: dashboard pessoal, marcações, banco de horas e espelho.',
  },
};

export const STATUS_USUARIO: Record<StatusUsuario, { label: string; tone: BadgeTone }> = {
  ativo: { label: 'Ativo', tone: 'green' },
  inativo: { label: 'Inativo', tone: 'slate' },
  bloqueado: { label: 'Bloqueado', tone: 'red' },
};
