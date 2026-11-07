import clsx from 'clsx';
import { CheckCircle2, XCircle } from 'lucide-react';
import { createContext, useCallback, useContext, useState, type ReactNode } from 'react';

type Tipo = 'sucesso' | 'erro';
interface Toast {
  id: number;
  tipo: Tipo;
  mensagem: string;
}

const ToastContext = createContext<(mensagem: string, tipo?: Tipo) => void>(() => {});

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const mostrar = useCallback((mensagem: string, tipo: Tipo = 'sucesso') => {
    const id = Date.now() + Math.random();
    setToasts((t) => [...t, { id, tipo, mensagem }]);
    window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 4000);
  }, []);

  return (
    <ToastContext.Provider value={mostrar}>
      {children}
      <div className="pointer-events-none fixed bottom-4 right-4 z-[60] flex flex-col gap-2" aria-live="polite">
        {toasts.map((t) => (
          <div
            key={t.id}
            className="pointer-events-auto flex max-w-sm items-center gap-3 rounded-xl bg-white px-4 py-3 text-sm text-slate-700 shadow-card ring-1 ring-slate-900/5"
          >
            {t.tipo === 'sucesso' ? (
              <CheckCircle2 className="h-5 w-5 shrink-0 text-emerald-500" />
            ) : (
              <XCircle className={clsx('h-5 w-5 shrink-0 text-rose-500')} />
            )}
            {t.mensagem}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export const useToast = () => useContext(ToastContext);
