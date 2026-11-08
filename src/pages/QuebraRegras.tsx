import clsx from 'clsx';
import { AlertOctagon, AlertTriangle, Search, ShieldCheck } from 'lucide-react';
import { useMemo, useState } from 'react';
import { Badge, type BadgeTone } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { formatData, formatMinutos } from '@/lib/format';
import { competencia, useFiltrosAux } from '@/lib/hooks';
import { api } from '@/lib/supabase';
import type { QuebraRegra, RegraQuebrada } from '@/lib/types';

const REGRAS: Record<RegraQuebrada, { label: string; tone: BadgeTone; medida: string }> = {
  interjornada: { label: 'Interjornada < 11h', tone: 'red', medida: 'Descanso' },
  intrajornada: { label: 'Intervalo insuficiente', tone: 'orange', medida: 'Intervalo' },
  jornada_maxima: { label: 'Jornada acima de 10h', tone: 'red', medida: 'Trabalhado' },
  limite_he: { label: 'Extra acima do limite', tone: 'violet', medida: 'Extra' },
  marcacao_impar: { label: 'Marcação ímpar', tone: 'slate', medida: '' },
  fora_local: { label: 'Batida fora do local', tone: 'orange', medida: '' },
  sem_localizacao: { label: 'Batida sem localização', tone: 'slate', medida: '' },
};

export default function QuebraRegras() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaborador: '', departamento: '' });
  const [regra, setRegra] = useState<RegraQuebrada | ''>('');
  const [dados, setDados] = useState<QuebraRegra[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(
        await api<QuebraRegra[]>('api_quebra_regras', {
          p_ini: periodo.ini,
          p_fim: periodo.fim,
          p_colaborador: filtros.colaborador || null,
          p_departamento: filtros.departamento || null,
        }),
      );
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  const contagem = useMemo(() => {
    const c: Partial<Record<RegraQuebrada, number>> = {};
    for (const q of dados ?? []) c[q.regra] = (c[q.regra] ?? 0) + 1;
    return c;
  }, [dados]);
  const visiveis = (dados ?? []).filter((q) => !regra || q.regra === regra);

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Quebra de regras</h2>
        <p className="mt-1 text-sm text-slate-500">
          Dias que descumprem a CLT: descanso entre jornadas (art. 66), intervalo para refeição (art. 71), limite de 10h (art. 59) e
          extras acima do limite da jornada.
        </p>
      </div>

      <section className="card p-5">
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
                .map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
            </select>
          </Field>
          <Button onClick={consultar} loading={carregando}>
            <Search className="h-4 w-4" /> Analisar
          </Button>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card">
          <EmptyState icon={AlertOctagon} titulo="Escolha o período e clique em Analisar" />
        </div>
      ) : dados.length === 0 ? (
        <div className="card">
          <EmptyState icon={ShieldCheck} titulo="Nenhuma quebra de regra no período" descricao="Todos os dias analisados respeitam os limites da CLT." />
        </div>
      ) : (
        <>
          <div className="flex flex-wrap gap-2">
            <button onClick={() => setRegra('')}
              className={clsx('rounded-xl px-3 py-2 text-xs font-medium ring-1 transition', !regra ? 'bg-primary-700 text-white ring-primary-700' : 'bg-white text-slate-600 ring-slate-200 hover:bg-slate-50')}>
              Todas · {dados.length}
            </button>
            {(Object.keys(REGRAS) as RegraQuebrada[]).filter((k) => contagem[k]).map((k) => (
              <button key={k} onClick={() => setRegra(k)}
                className={clsx('rounded-xl px-3 py-2 text-xs font-medium ring-1 transition', regra === k ? 'bg-primary-700 text-white ring-primary-700' : 'bg-white text-slate-600 ring-slate-200 hover:bg-slate-50')}>
                {REGRAS[k].label} · {contagem[k]}
              </button>
            ))}
          </div>

          <div className="card overflow-x-auto">
            <table className="w-full min-w-[820px] text-sm">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-5 py-2.5 font-medium">Colaborador</th>
                  <th className="px-5 py-2.5 font-medium">Dia</th>
                  <th className="px-5 py-2.5 font-medium">Regra</th>
                  <th className="px-5 py-2.5 font-medium">Detalhe</th>
                  <th className="px-5 py-2.5 text-right font-medium">Apurado</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {visiveis.map((q, i) => (
                  <tr key={`${q.colaborador_id}-${q.data}-${q.regra}-${i}`}>
                    <td className="px-5 py-2.5">
                      <p className="font-medium text-slate-800">{q.nome}</p>
                      <p className="text-xs text-slate-400">Mat. {q.matricula}{q.departamento && ` · ${q.departamento}`}</p>
                    </td>
                    <td className="whitespace-nowrap px-5 py-2.5 capitalize tabular-nums text-slate-600">
                      {formatData(q.data, { weekday: 'short', day: '2-digit', month: '2-digit' })}
                    </td>
                    <td className="px-5 py-2.5"><Badge tone={REGRAS[q.regra].tone} dot={false}>{REGRAS[q.regra].label}</Badge></td>
                    <td className="px-5 py-2.5 text-xs text-slate-500">{q.detalhe}</td>
                    <td className="whitespace-nowrap px-5 py-2.5 text-right tabular-nums text-slate-700">
                      {q.minutos != null ? `${REGRAS[q.regra].medida} ${formatMinutos(q.minutos)}` : '—'}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
