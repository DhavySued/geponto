import { useAuth } from '@/contexts/AuthContext';
import { formatData, toISODate } from '@/lib/format';

const dataBR = (d: string) => formatData(d, { day: '2-digit', month: '2-digit', year: 'numeric' });
/** Sem período (relatório de cadastro): a posição de hoje */
const textoPeriodo = (p?: { ini: string; fim: string }) =>
  p ? `Período de ${dataBR(p.ini)} a ${dataBR(p.fim)}` : `Posição em ${dataBR(toISODate(new Date()))}`;

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

/** Primeiras linhas dos CSV de relatório: nome do relatório, razão social, CNPJ e período */
export function useCabecalhoCsv() {
  const { usuario } = useAuth();
  const emp = usuario?.empresa ?? null;
  const q = (v: string) => `"${v.replace(/"/g, '""')}"`;
  return (titulo: string, periodo?: { ini: string; fim: string }): string[] => [
    q(titulo), q(emp?.razao_social ?? '—'), q(`CNPJ ${cnpj(emp?.cnpj)}`), q(textoPeriodo(periodo)), '',
  ];
}

/**
 * Cabeçalho dos relatórios, na tela e na impressão: nome do relatório, razão social, CNPJ e período
 * consultado à esquerda; a logo do GePonto no canto superior direito.
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
    <header className="mb-4 card flex items-start justify-between gap-4 p-4 print:rounded-none print:border-b print:border-slate-300 print:p-0 print:pb-3 print:shadow-none print:ring-0">
      <div>
        <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-slate-500">{titulo}</p>
        <p className="text-base font-semibold text-slate-900">{emp?.razao_social ?? '—'}</p>
        <p className="text-xs text-slate-600">CNPJ {cnpj(emp?.cnpj)}</p>
        <p className="mt-0.5 text-xs text-slate-600">{textoPeriodo(periodo)}</p>
      </div>
      <LogoImpressao />
    </header>
  );
}
