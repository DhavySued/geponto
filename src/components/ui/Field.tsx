import clsx from 'clsx';
import type { ReactNode } from 'react';

export function Field({
  label,
  obrigatorio = false,
  dica,
  className,
  grupo = false,
  children,
}: {
  label: string;
  obrigatorio?: boolean;
  dica?: ReactNode;
  className?: string;
  /** O conteúdo é um grupo de botões: um <label> faria o clique no rótulo ou na dica acionar o 1º botão. */
  grupo?: boolean;
  children: ReactNode;
}) {
  const Tag = grupo ? 'div' : 'label';
  return (
    <Tag className={clsx('block', className)}>
      <span className="label">
        {label}
        {obrigatorio && <span className="ml-0.5 text-accent-600">*</span>}
      </span>
      {children}
      {dica && <span className="mt-1 block text-[11px] text-slate-400">{dica}</span>}
    </Tag>
  );
}

export function Switch({
  ativo,
  onChange,
  label,
  descricao,
}: {
  ativo: boolean;
  onChange: (v: boolean) => void;
  label: string;
  descricao?: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={ativo}
      onClick={() => onChange(!ativo)}
      className="flex w-full items-start gap-3 rounded-xl p-2 text-left transition hover:bg-slate-50"
    >
      <span
        className={clsx(
          'relative mt-0.5 inline-flex h-5 w-9 shrink-0 rounded-full transition',
          ativo ? 'bg-primary-700' : 'bg-slate-200',
        )}
      >
        <span
          className={clsx(
            'absolute top-0.5 h-4 w-4 rounded-full bg-white shadow transition-all',
            ativo ? 'left-[18px]' : 'left-0.5',
          )}
        />
      </span>
      <span>
        <span className="block text-sm font-medium text-slate-700">{label}</span>
        {descricao && <span className="block text-xs text-slate-400">{descricao}</span>}
      </span>
    </button>
  );
}

export function AlertaErro({ mensagem }: { mensagem: string | null }) {
  if (!mensagem) return null;
  return (
    <div className="mb-4 rounded-xl bg-rose-50 px-4 py-3 text-sm text-rose-700 ring-1 ring-rose-200">{mensagem}</div>
  );
}
