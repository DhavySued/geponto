import clsx from 'clsx';
import type { MouseEvent } from 'react';
import { ORIGEM_BATIDA, rotuloMarcacao, siglaMarcacao } from '@/lib/ponto';
import type { BatidaTratamento, StatusBatida } from '@/lib/types';

/** Cores da legenda: preto = original, azul = incluída, vermelho = desconsiderada. */
export const STATUS_BATIDA: Record<StatusBatida, { label: string; chip: string; texto: string; ponto: string }> = {
  original: {
    label: 'Original',
    chip: 'bg-white text-slate-900 ring-slate-300',
    texto: 'text-slate-900',
    ponto: 'bg-slate-900',
  },
  incluida: {
    label: 'Incluída',
    chip: 'bg-blue-50 text-blue-700 ring-blue-300',
    texto: 'text-blue-700',
    ponto: 'bg-blue-600',
  },
  desconsiderada: {
    label: 'Desconsiderada',
    chip: 'bg-rose-50 text-rose-700 ring-rose-300 line-through decoration-rose-400',
    texto: 'text-rose-700',
    ponto: 'bg-rose-600',
  },
};

export function descricaoBatida(b: BatidaTratamento): string {
  const partes = [
    STATUS_BATIDA[b.status].label,
    b.sentido && b.status !== 'desconsiderada'
      ? rotuloMarcacao(b.sentido, b.turno) + (b.sentido_declarado || b.turno_declarado ? ' (classificada pelo RH)' : '')
      : null,
    ORIGEM_BATIDA[b.origem] ?? b.origem,
    b.motivo,
    b.observacao,
    b.data_referencia !== b.data ? `Referência ${b.data_referencia.split('-').reverse().join('/')}` : null,
  ];
  return partes.filter(Boolean).join(' · ');
}

export function BatidaChip({
  batida,
  onAcao,
}: {
  batida: BatidaTratamento;
  onAcao?: (e: MouseEvent, b: BatidaTratamento) => void;
}) {
  const st = STATUS_BATIDA[batida.status];
  const outroDia = batida.data_referencia !== batida.data;
  return (
    <button
      type="button"
      title={descricaoBatida(batida)}
      onClick={(e) => {
        e.stopPropagation();
        onAcao?.(e, batida);
      }}
      onContextMenu={(e) => {
        e.preventDefault();
        e.stopPropagation();
        onAcao?.(e, batida);
      }}
      className={clsx(
        'inline-flex items-center gap-1 rounded-lg px-2 py-0.5 text-xs font-semibold tabular-nums ring-1 ring-inset transition',
        st.chip,
        onAcao && 'cursor-pointer hover:shadow-soft hover:brightness-95',
      )}
    >
      {batida.hora}
      {batida.sentido && batida.status !== 'desconsiderada' && (
        <span
          className={clsx(
            'rounded px-0.5 text-[9px] font-bold leading-tight no-underline',
            batida.sentido_declarado || batida.turno_declarado ? 'bg-black/5 underline decoration-dotted' : 'opacity-50',
          )}
        >
          {siglaMarcacao(batida.sentido, batida.turno)}
        </span>
      )}
      {outroDia && <span className="text-[9px] font-bold opacity-60" aria-label="Data de referência alterada">↺</span>}
    </button>
  );
}

export function LegendaBatidas({ dica }: { dica?: string }) {
  return (
    <div className="flex flex-wrap items-center gap-x-5 gap-y-2 text-xs text-slate-500">
      {(Object.keys(STATUS_BATIDA) as StatusBatida[]).map((s) => (
        <span key={s} className="flex items-center gap-1.5">
          <span className={clsx('h-2.5 w-2.5 rounded-full', STATUS_BATIDA[s].ponto)} />
          <span className={STATUS_BATIDA[s].texto}>{STATUS_BATIDA[s].label}</span>
        </span>
      ))}
      <span className="flex items-center gap-1.5">
        <span className="rounded bg-slate-100 px-1 text-[9px] font-bold text-slate-600">E1</span>
        <span className="rounded bg-slate-100 px-1 text-[9px] font-bold text-slate-600">S1</span>
        Entrada / saída do turno
      </span>
      <span className="flex items-center gap-1.5">
        <span className="rounded bg-slate-100 px-1 text-[9px] font-bold text-slate-600 underline decoration-dotted">E2</span>
        Classificada pelo RH
      </span>
      <span className="flex items-center gap-1.5">
        <span className="text-[11px] font-bold text-slate-500">↺</span> Data de referência alterada
      </span>
      {dica && <span className="text-slate-400 lg:ml-auto">{dica}</span>}
    </div>
  );
}
