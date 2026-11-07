import clsx from 'clsx';
import { Loader2 } from 'lucide-react';
import type { ButtonHTMLAttributes } from 'react';

type Variant = 'primary' | 'accent' | 'secondary' | 'ghost';

const variants: Record<Variant, string> = {
  primary: 'bg-primary-700 text-white hover:bg-primary-800 focus-visible:ring-primary-200',
  accent: 'bg-accent-500 text-white hover:bg-accent-600 focus-visible:ring-accent-200',
  secondary: 'bg-white text-slate-700 ring-1 ring-inset ring-slate-200 hover:bg-slate-50 focus-visible:ring-primary-100',
  ghost: 'text-slate-600 hover:bg-slate-100 focus-visible:ring-primary-100',
};

export function Button({
  variant = 'primary',
  loading = false,
  className,
  children,
  disabled,
  ...props
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant; loading?: boolean }) {
  return (
    <button
      {...props}
      disabled={disabled || loading}
      className={clsx(
        'inline-flex h-10 items-center justify-center gap-2 rounded-xl px-4 text-sm font-medium transition',
        'focus-visible:outline-none focus-visible:ring-4 disabled:cursor-not-allowed disabled:opacity-60',
        variants[variant],
        className,
      )}
    >
      {loading && <Loader2 className="h-4 w-4 animate-spin" />}
      {children}
    </button>
  );
}
