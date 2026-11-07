import clsx from 'clsx';
import { Check, type LucideIcon } from 'lucide-react';
import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';

export type ItemMenu =
  | { tipo?: 'acao'; label: string; icon?: LucideIcon; onClick: () => void; perigo?: boolean; marcado?: boolean; desabilitado?: boolean }
  | { tipo: 'titulo'; label: string }
  | { tipo: 'separador' };

export interface MenuAberto {
  x: number;
  y: number;
  titulo?: string;
  itens: ItemMenu[];
}

/** Menu de contexto (botão direito / clique), posicionado no cursor e mantido dentro da tela. */
export function ContextMenu({ menu, onFechar }: { menu: MenuAberto | null; onFechar: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const [pos, setPos] = useState({ x: 0, y: 0 });

  useLayoutEffect(() => {
    if (!menu || !ref.current) return;
    const { offsetWidth: w, offsetHeight: h } = ref.current;
    setPos({
      x: Math.max(8, Math.min(menu.x, window.innerWidth - w - 8)),
      y: Math.max(8, Math.min(menu.y, window.innerHeight - h - 8)),
    });
    ref.current.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
  }, [menu]);

  useEffect(() => {
    if (!menu) return;
    const fora = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onFechar();
    };
    const tecla = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onFechar();
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        const botoes = Array.from(ref.current?.querySelectorAll<HTMLButtonElement>('button:not(:disabled)') ?? []);
        const i = botoes.indexOf(document.activeElement as HTMLButtonElement);
        botoes[(i + (e.key === 'ArrowDown' ? 1 : -1) + botoes.length) % botoes.length]?.focus();
      }
    };
    document.addEventListener('mousedown', fora);
    document.addEventListener('keydown', tecla);
    window.addEventListener('scroll', onFechar, true);
    window.addEventListener('resize', onFechar);
    return () => {
      document.removeEventListener('mousedown', fora);
      document.removeEventListener('keydown', tecla);
      window.removeEventListener('scroll', onFechar, true);
      window.removeEventListener('resize', onFechar);
    };
  }, [menu, onFechar]);

  if (!menu) return null;

  return createPortal(
    <div
      ref={ref}
      role="menu"
      style={{ left: pos.x, top: pos.y }}
      onContextMenu={(e) => e.preventDefault()}
      className="fixed z-[70] min-w-[220px] max-w-[280px] overflow-hidden rounded-xl bg-white py-1.5 text-sm shadow-2xl ring-1 ring-slate-900/10"
    >
      {menu.titulo && (
        <p className="truncate border-b border-slate-100 px-3 pb-2 pt-1 text-xs font-semibold text-slate-800">{menu.titulo}</p>
      )}
      {menu.itens.map((it, i) => {
        if (it.tipo === 'separador') return <div key={i} className="my-1 h-px bg-slate-100" />;
        if (it.tipo === 'titulo')
          return (
            <p key={i} className="px-3 pb-1 pt-2 text-[10px] font-semibold uppercase tracking-wider text-slate-400">
              {it.label}
            </p>
          );
        const Icon = it.icon;
        return (
          <button
            key={i}
            role="menuitem"
            disabled={it.desabilitado}
            onClick={() => {
              onFechar();
              it.onClick();
            }}
            className={clsx(
              'flex w-full items-center gap-2.5 px-3 py-2 text-left outline-none transition disabled:cursor-not-allowed disabled:opacity-40',
              it.perigo ? 'text-rose-600 hover:bg-rose-50 focus:bg-rose-50' : 'text-slate-700 hover:bg-slate-50 focus:bg-slate-50',
            )}
          >
            {Icon ? <Icon className="h-4 w-4 shrink-0 opacity-70" /> : <span className="w-4" />}
            <span className="flex-1">{it.label}</span>
            {it.marcado && <Check className="h-4 w-4 text-primary-600" />}
          </button>
        );
      })}
    </div>,
    document.body,
  );
}
