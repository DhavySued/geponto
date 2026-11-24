import clsx from 'clsx';
import { AlertTriangle, Download, Hourglass, Printer, Search } from 'lucide-react';
import { useMemo, useState } from 'react';
import { CabecalhoImpressao, useCabecalhoCsv } from '@/components/relatorios/CabecalhoImpressao';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { formatMinutos } from '@/lib/format';
import { competencia, opcoesColaboradores, paramColaboradores, useFiltrosAux } from '@/lib/hooks';
import type { RelatorioBancoHoras as Dados, RelatorioBancoHorasItem } from '@/lib/types';

type Ver = '' | 'positivo' | 'negativo' | 'zerado';

const COLUNAS: { chave: keyof RelatorioBancoHorasItem; titulo: string }[] = [
  { chave: 'saldo_anterior', titulo: 'Saldo anterior' },
  { chave: 'creditos', titulo: 'Créditos' },
  { chave: 'debitos', titulo: 'Débitos' },
  { chave: 'ajustes', titulo: 'Ajustes manuais' },
  { chave: 'conversoes', titulo: 'Conversões' },
  { chave: 'saldo_final', titulo: 'Saldo final' },
];

const tom = (m: number) => (m > 0 ? 'text-emerald-700' : m < 0 ? 'text-rose-600' : 'text-slate-400');

export default function RelatorioBancoHoras() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const cabecalhoCsv = useCabecalhoCsv();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '' });
  const [dados, setDados] = useState<Dados | null>(null);
  const [ver, setVer] = useState<Ver>('');
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(await api<Dados>('api_relatorio_banco_horas', {
        p_ini: periodo.ini,
        p_fim: periodo.fim,
        p_colaboradores: paramColaboradores(filtros.colaboradores),
        p_departamento: filtros.departamento || null,
      }));
      setVer('');
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  // Período do que está na tela (os campos podem ter mudado depois da consulta)
  const consultado = dados ? { ini: dados.periodo.inicio, fim: dados.periodo.fim } : periodo;
  const itens = dados?.itens ?? [];
  const visiveis = itens.filter((i) =>
    !ver || (ver === 'positivo' ? i.saldo_final > 0 : ver === 'negativo' ? i.saldo_final < 0 : i.saldo_final === 0));
  const totais = useMemo(() => {
    const t = Object.fromEntries(COLUNAS.map((c) => [c.chave, 0])) as Record<string, number>;
    for (const i of visiveis) for (const c of COLUNAS) t[c.chave] += Number(i[c.chave]) || 0;
    return t;
  }, [visiveis]);
  const contagem = {
    positivo: itens.filter((i) => i.saldo_final > 0).length,
    negativo: itens.filter((i) => i.saldo_final < 0).length,
    zerado: itens.filter((i) => i.saldo_final === 0).length,
  };

  const exportar = () => {
    const linhas = [
      ['Matrícula', 'Colaborador', 'Departamento', 'Cargo', ...COLUNAS.map((c) => c.titulo + ' (min)'), 'Saldo final'].join(';'),
      ...visiveis.map((i) => [i.matricula, i.nome, i.departamento ?? '', i.cargo ?? '',
        ...COLUNAS.map((c) => String(i[c.chave])), formatMinutos(i.saldo_final)].map((v) => `"${String(v).replace(/"/g, '""')}"`).join(';')),
    ];
    baixarArquivo(`resumo_banco_horas_${consultado.ini}_${consultado.fim}.csv`, [...cabecalhoCsv('Resumo do banco de horas', consultado), ...linhas].join('\r\n'), 'text/csv');
  };

  const chip = (ativo: boolean) =>
    clsx('rounded-xl px-3 py-2 text-xs font-medium ring-1 transition print:hidden',
      ativo ? 'bg-primary-700 text-white ring-primary-700' : 'bg-white text-slate-600 ring-slate-200 hover:bg-slate-50');

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3 print:hidden">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Resumo do banco de horas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Saldo de cada colaborador no período: o que vinha de antes, os créditos e débitos do dia a dia, ajustes, conversões e o saldo final.
          </p>
        </div>
        {visiveis.length > 0 && (
          <div className="flex gap-2 print:hidden">
            <Button variant="secondary" onClick={exportar}><Download className="h-4 w-4" /> Exportar CSV</Button>
            <Button variant="secondary" onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir</Button>
          </div>
        )}
      </div>

      <section className="card p-5 print:hidden">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[160px_160px_1fr_1fr_auto] lg:items-end">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="Departamento">
            <select className="input" value={filtros.departamento} onChange={(e) => setFiltros((f) => ({ ...f, departamento: e.target.value, colaboradores: [] }))}>
              <option value="">Todos</option>
              {aux?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
            </select>
          </Field>
          <Field label="Colaborador">
            <ComboboxChips opcoes={opcoesColaboradores(aux?.colaboradores, filtros)} valor={filtros.colaboradores}
              onChange={(v) => setFiltros((f) => ({ ...f, colaboradores: v }))} rotuloTodos="Todos os colaboradores" />
          </Field>
          <Button onClick={consultar} loading={carregando}><Search className="h-4 w-4" /> Consultar</Button>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card"><EmptyState icon={Hourglass} titulo="Escolha o período e clique em Consultar" descricao="Os lançamentos do banco de horas são atualizados antes de gerar o relatório." /></div>
      ) : itens.length === 0 ? (
        <div className="card"><EmptyState icon={Hourglass} titulo="Nenhum colaborador encontrado" descricao="Não há banco de horas com esses filtros." /></div>
      ) : (
        <>
          <CabecalhoImpressao titulo="Resumo do banco de horas" periodo={consultado} />
          <div className="flex flex-wrap gap-2">
            <button onClick={() => setVer('')} className={chip(!ver)}>Todos · {itens.length}</button>
            {contagem.positivo > 0 && <button onClick={() => setVer('positivo')} className={chip(ver === 'positivo')}>Saldo positivo · {contagem.positivo}</button>}
            {contagem.negativo > 0 && <button onClick={() => setVer('negativo')} className={chip(ver === 'negativo')}>Saldo negativo · {contagem.negativo}</button>}
            {contagem.zerado > 0 && <button onClick={() => setVer('zerado')} className={chip(ver === 'zerado')}>Zerado · {contagem.zerado}</button>}
          </div>
          <div className="card overflow-x-auto print:overflow-visible print:shadow-none print:ring-0">
            <table className="w-full min-w-[860px] text-sm print:min-w-0 print:text-xs">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-4 py-2.5 font-medium">Colaborador</th>
                  {COLUNAS.map((c) => <th key={c.chave} className="px-4 py-2.5 text-right font-medium">{c.titulo}</th>)}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {visiveis.map((i) => (
                  <tr key={i.colaborador_id} className="break-inside-avoid">
                    <td className="px-4 py-2.5">
                      <p className="font-medium text-slate-800">{i.nome}</p>
                      <p className="text-xs text-slate-400">Mat. {i.matricula}{i.departamento && ` · ${i.departamento}`}</p>
                    </td>
                    {COLUNAS.map((c) => {
                      const v = Number(i[c.chave]) || 0;
                      return (
                        <td key={c.chave} className={clsx('whitespace-nowrap px-4 py-2.5 text-right tabular-nums', c.chave === 'saldo_final' ? clsx('font-semibold', tom(v)) : v ? 'text-slate-700' : 'text-slate-300')}>
                          {v ? formatMinutos(v, c.chave !== 'saldo_anterior' || v > 0) : '—'}
                          {c.chave === 'creditos' && i.dias_credito > 0 && <span className="block text-[11px] font-normal text-slate-400">{i.dias_credito} dia(s)</span>}
                          {c.chave === 'debitos' && i.dias_debito > 0 && <span className="block text-[11px] font-normal text-slate-400">{i.dias_debito} dia(s)</span>}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
              <tfoot>
                <tr className="border-t border-slate-200 bg-slate-50/70 font-semibold">
                  <td className="px-4 py-2.5 text-slate-700">Total</td>
                  {COLUNAS.map((c) => (
                    <td key={c.chave} className={clsx('whitespace-nowrap px-4 py-2.5 text-right tabular-nums', c.chave === 'saldo_final' ? tom(totais[c.chave]) : 'text-slate-700')}>
                      {formatMinutos(totais[c.chave], true)}
                    </td>
                  ))}
                </tr>
              </tfoot>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
