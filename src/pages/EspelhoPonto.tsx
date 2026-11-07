import { AlertTriangle, FileText, Printer, Search } from 'lucide-react';
import { useState } from 'react';
import { EspelhoImpressao } from '@/components/relatorios/EspelhoImpressao';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { competencia, useFiltrosAux } from '@/lib/hooks';
import { api } from '@/lib/supabase';
import type { EspelhoPonto as EspelhoPontoT } from '@/lib/types';

export default function EspelhoPonto() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaborador: '', departamento: '' });
  const [dados, setDados] = useState<EspelhoPontoT | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const gerar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(
        await api<EspelhoPontoT>('api_espelho_ponto', {
          p_ini: periodo.ini,
          p_fim: periodo.fim,
          p_colaborador: filtros.colaborador || null,
          p_departamento: filtros.departamento || null,
        }),
      );
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao gerar o espelho.');
    } finally {
      setCarregando(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between print:hidden">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Espelho de ponto</h2>
          <p className="mt-1 text-sm text-slate-500">
            Marcações originais e tratadas, horas extras, noturno, faltas e banco de horas do período, com campo de assinatura.
          </p>
        </div>
        {dados && dados.espelhos.length > 0 && (
          <Button variant="secondary" onClick={() => window.print()}>
            <Printer className="h-4 w-4" /> Imprimir / salvar PDF
          </Button>
        )}
      </div>

      <section className="card p-5 print:hidden">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[180px_180px_1fr_1fr_auto] lg:items-end">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="Departamento">
            <select className="input" value={filtros.departamento} onChange={(e) => setFiltros({ departamento: e.target.value, colaborador: '' })}>
              <option value="">Todos</option>
              {aux?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
            </select>
          </Field>
          <Field label="Colaborador">
            <select className="input" value={filtros.colaborador} onChange={(e) => setFiltros((f) => ({ ...f, colaborador: e.target.value }))}>
              <option value="">Todos</option>
              {aux?.colaboradores
                .filter((c) => !filtros.departamento || c.departamento_id === filtros.departamento)
                .map((c) => <option key={c.id} value={c.id}>{c.nome} · {c.matricula}</option>)}
            </select>
          </Field>
          <Button onClick={gerar} loading={carregando}>
            <Search className="h-4 w-4" /> Gerar
          </Button>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200 print:hidden">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {!dados ? (
        <div className="card print:hidden">
          <EmptyState icon={FileText} titulo="Escolha o período e gere o espelho"
            descricao="Cada colaborador sai em uma página, pronta para imprimir ou salvar em PDF e colher a assinatura." />
        </div>
      ) : dados.espelhos.length === 0 ? (
        <div className="card print:hidden">
          <EmptyState icon={FileText} titulo="Nenhum colaborador com ponto no período" />
        </div>
      ) : (
        <EspelhoImpressao dados={dados} />
      )}
    </div>
  );
}
