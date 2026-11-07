import { X } from 'lucide-react';
import { useEffect, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

/** Modal padrão para criação/edição de registros. */
export function Modal({
  aberto,
  onFechar,
  titulo,
  descricao,
  children,
  rodape,
  largura = 'max-w-lg',
  fechavel = true,
}: {
  aberto: boolean;
  onFechar: () => void;
  titulo: string;
  descricao?: string;
  children: ReactNode;
  rodape?: ReactNode;
  largura?: string;
  /** false: sem o X e sem fechar pelo fundo (ex.: troca de senha obrigatória) */
  fechavel?: boolean;
}) {
  useEffect(() => {
    if (!aberto) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onFechar();
    document.addEventListener('keydown', onKey);
    document.body.style.overflow = 'hidden';
    return () => {
      document.removeEventListener('keydown', onKey);
      document.body.style.overflow = '';
    };
  }, [aberto, onFechar]);

  if (!aberto) return null;

  return createPortal(
    <div className="fixed inset-0 z-50 flex items-end justify-center p-0 sm:items-center sm:p-4">
      <div className="absolute inset-0 bg-primary-900/40 backdrop-blur-sm" onClick={onFechar} />
      <div
        role="dialog"
        aria-modal="true"
        aria-label={titulo}
        className={`relative flex max-h-[92vh] w-full ${largura} flex-col rounded-t-2xl bg-white shadow-2xl sm:rounded-2xl`}
      >
        <header className="flex items-start justify-between gap-4 border-b border-slate-100 px-6 py-5">
          <div>
            <h2 className="text-base font-semibold text-slate-900">{titulo}</h2>
            {descricao && <p className="mt-0.5 text-sm text-slate-500">{descricao}</p>}
          </div>
          {fechavel && (
            <button
              onClick={onFechar}
              className="rounded-lg p-1.5 text-slate-400 transition hover:bg-slate-100 hover:text-slate-600"
              aria-label="Fechar"
            >
              <X className="h-5 w-5" />
            </button>
          )}
        </header>
        <div className="flex-1 overflow-y-auto px-6 py-5">{children}</div>
        {rodape && (
          <footer className="flex justify-end gap-2 border-t border-slate-100 bg-slate-50/60 px-6 py-4 sm:rounded-b-2xl">
            {rodape}
          </footer>
        )}
      </div>
    </div>,
    document.body,
  );
}
