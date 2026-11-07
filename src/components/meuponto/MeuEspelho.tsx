import { ArrowLeft, ChevronLeft, ChevronRight, Printer } from 'lucide-react';
import { useEffect, useState } from 'react';
import { EspelhoImpressao } from '@/components/relatorios/EspelhoImpressao';
import { Button } from '@/components/ui/Button';
import { formatData } from '@/lib/format';
import { competencia } from '@/lib/hooks';
import { api } from '@/lib/supabase';
import type { EspelhoPonto } from '@/lib/types';

/** Extrato mensal do próprio colaborador, para conferir e imprimir/assinar. */
export function MeuEspelho({ onVoltar }: { onVoltar: () => void }) {
  const [mes, setMes] = useState(0);
  const [dados, setDados] = useState<EspelhoPonto | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const periodo = competencia(mes);

  useEffect(() => {
    setDados(null);
    setErro(null);
    api<EspelhoPonto>('api_meu_espelho', { p_ini: periodo.ini, p_fim: periodo.fim })
      .then(setDados)
      .catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar o espelho.'));
  }, [periodo.ini, periodo.fim]);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-center justify-between gap-3 print:hidden">
        <Button variant="ghost" onClick={onVoltar}>
          <ArrowLeft className="h-4 w-4" /> Voltar ao Meu Ponto
        </Button>
        <div className="flex items-center gap-2">
          <div className="flex items-center rounded-xl bg-white ring-1 ring-slate-200">
            <button className="rounded-l-xl p-2.5 text-slate-500 hover:bg-slate-50" onClick={() => setMes(mes - 1)} aria-label="Mês anterior">
              <ChevronLeft className="h-4 w-4" />
            </button>
            <span className="w-36 text-center text-sm font-semibold capitalize text-slate-800">
              {formatData(periodo.ini, { month: 'long', year: 'numeric' })}
            </span>
            <button className="rounded-r-xl p-2.5 text-slate-500 hover:bg-slate-50 disabled:opacity-40" disabled={mes >= 0}
              onClick={() => setMes(mes + 1)} aria-label="Próximo mês">
              <ChevronRight className="h-4 w-4" />
            </button>
          </div>
          <Button variant="secondary" onClick={() => window.print()} disabled={!dados}>
            <Printer className="h-4 w-4" /> Imprimir / PDF
          </Button>
        </div>
      </div>
      {erro && <p className="rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">{erro}</p>}
      {dados ? <EspelhoImpressao dados={dados} /> : !erro && <div className="card h-96 animate-pulse" />}
    </div>
  );
}
