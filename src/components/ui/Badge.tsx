import clsx from 'clsx';
import type { ReactNode } from 'react';
import type { SituacaoColaborador, StatusHoje } from '@/lib/types';

export type BadgeTone = 'green' | 'blue' | 'orange' | 'red' | 'violet' | 'slate' | 'primary';

const tones: Record<BadgeTone, string> = {
  green: 'bg-emerald-50 text-emerald-700 ring-emerald-600/15',
  blue: 'bg-sky-50 text-sky-700 ring-sky-600/15',
  orange: 'bg-accent-50 text-accent-700 ring-accent-600/20',
  red: 'bg-rose-50 text-rose-700 ring-rose-600/15',
  violet: 'bg-violet-50 text-violet-700 ring-violet-600/15',
  slate: 'bg-slate-100 text-slate-600 ring-slate-500/15',
  primary: 'bg-primary-50 text-primary-700 ring-primary-600/15',
};

const dots: Record<BadgeTone, string> = {
  green: 'bg-emerald-500',
  blue: 'bg-sky-500',
  orange: 'bg-accent-500',
  red: 'bg-rose-500',
  violet: 'bg-violet-500',
  slate: 'bg-slate-400',
  primary: 'bg-primary-600',
};

export function Badge({
  tone = 'slate',
  dot = true,
  pulse = false,
  children,
}: {
  tone?: BadgeTone;
  dot?: boolean;
  pulse?: boolean;
  children: ReactNode;
}) {
  return (
    <span
      className={clsx(
        'inline-flex items-center gap-1.5 whitespace-nowrap rounded-full px-2.5 py-1 text-xs font-medium ring-1 ring-inset',
        tones[tone],
      )}
    >
      {dot && (
        <span className="relative flex h-1.5 w-1.5">
          {pulse && (
            <span className={clsx('absolute inline-flex h-full w-full animate-ping rounded-full opacity-60', dots[tone])} />
          )}
          <span className={clsx('relative inline-flex h-1.5 w-1.5 rounded-full', dots[tone])} />
        </span>
      )}
      {children}
    </span>
  );
}

export const SITUACAO: Record<SituacaoColaborador, { label: string; tone: BadgeTone }> = {
  ativo: { label: 'Ativo', tone: 'green' },
  ferias: { label: 'Férias', tone: 'blue' },
  afastado: { label: 'Afastado', tone: 'violet' },
  desligado: { label: 'Desligado', tone: 'slate' },
};

export const STATUS_HOJE: Record<StatusHoje, { label: string; tone: BadgeTone; pulse?: boolean }> = {
  em_jornada: { label: 'Em jornada', tone: 'green', pulse: true },
  em_intervalo: { label: 'Em intervalo', tone: 'orange' },
  finalizado: { label: 'Jornada encerrada', tone: 'primary' },
  aguardando: { label: 'Aguardando entrada', tone: 'slate' },
  ausente: { label: 'Ausente', tone: 'red' },
  folga: { label: 'Folga', tone: 'slate' },
  ausencia: { label: 'Ausência justificada', tone: 'blue' },
  ferias: { label: 'Férias', tone: 'blue' },
  afastado: { label: 'Afastado', tone: 'violet' },
  inconsistente: { label: 'Marcação ímpar', tone: 'orange' },
};

export function SituacaoBadge({ situacao }: { situacao: SituacaoColaborador }) {
  const s = SITUACAO[situacao];
  return <Badge tone={s.tone}>{s.label}</Badge>;
}

export function StatusHojeBadge({ status }: { status: StatusHoje }) {
  const s = STATUS_HOJE[status];
  return (
    <Badge tone={s.tone} pulse={s.pulse}>
      {s.label}
    </Badge>
  );
}
