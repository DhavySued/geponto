import { useAuth } from '@/contexts/AuthContext';
import { formatData } from '@/lib/format';

const cnpj = (v: string | null | undefined) => {
  const d = (v ?? '').replace(/\D/g, '');
  return d.length === 14 ? d.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5') : v ?? '—';
};

/** Logo do GePonto para impressão (fundo branco) */
export function LogoImpressao() {
  return (
    <div className="flex items-center gap-1.5">
      <svg viewBox="0 0 32 32" className="h-7 w-7" aria-hidden>
        <rect width="32" height="32" rx="8" fill="#00236a" />
        <circle cx="16" cy="16" r="9" fill="none" stroke="#fff" strokeWidth="2.5" />
        <path d="M16 11v5l3.5 2" fill="none" stroke="#f39200" strokeWidth="2.5" strokeLinecap="round" />
      </svg>
      <span className="text-base font-semibold tracking-tight text-[#00236a]">
        Ge<span className="text-[#f39200]">Ponto</span>
      </span>
    </div>
  );
}

/**
 * Cabeçalho dos relatórios impressos: empresa (nome e CNPJ) à esquerda e a logo do GePonto no canto
 * superior direito. Só aparece na impressão.
 */
export function CabecalhoImpressao({
  titulo,
  periodo,
  empresa,
}: {
  titulo: string;
  periodo?: { ini: string; fim: string };
  /** Empresa do relatório; sem ela, a empresa da sessão */
  empresa?: { razao_social: string; cnpj: string | null } | null;
}) {
  const { usuario } = useAuth();
  const emp = empresa ?? usuario?.empresa ?? null;
  return (
    <header className="mb-4 hidden items-start justify-between gap-4 border-b border-slate-300 pb-3 print:flex">
      <div>
        <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-slate-500">{titulo}</p>
        <p className="text-base font-semibold text-slate-900">{emp?.razao_social ?? '—'}</p>
        <p className="text-xs text-slate-600">CNPJ {cnpj(emp?.cnpj)}</p>
        {periodo && (
          <p className="mt-0.5 text-xs text-slate-600">
            Período de {formatData(periodo.ini)} a {formatData(periodo.fim)}
          </p>
        )}
      </div>
      <LogoImpressao />
    </header>
  );
}
