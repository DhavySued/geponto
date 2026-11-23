import clsx from 'clsx';
import { AlertTriangle, Check, Contact, Download, Printer, RotateCcw, Search } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { CabecalhoImpressao } from '@/components/relatorios/CabecalhoImpressao';
import { SITUACAO } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { formatData } from '@/lib/format';
import { opcoesColaboradores, paramColaboradores, useFiltrosAux } from '@/lib/hooks';
import { mascaraCEP, mascaraCPF, mascaraPIS } from '@/lib/mask';
import type { RelatorioColaboradorItem as Item } from '@/lib/types';

interface Coluna {
  chave: string;
  titulo: string;
  grupo: string;
  /** Texto da célula (também vai para o CSV); vazio = campo em branco */
  valor: (i: Item) => string;
}

const data = (v: string | null) => (v ? formatData(v) : '');
const SEXO: Record<string, string> = { M: 'Masculino', F: 'Feminino', O: 'Outro' };
const LOCAL: Record<string, string> = { empresa: 'Local da empresa', proprio: 'Local próprio', ambos: 'Empresa e próprio' };

const COLUNAS: Coluna[] = [
  { grupo: 'Pessoais', chave: 'matricula', titulo: 'Matrícula', valor: (i) => i.matricula },
  { grupo: 'Pessoais', chave: 'nome', titulo: 'Nome', valor: (i) => i.nome },
  { grupo: 'Pessoais', chave: 'nome_social', titulo: 'Nome social', valor: (i) => i.nome_social ?? '' },
  { grupo: 'Pessoais', chave: 'cpf', titulo: 'CPF', valor: (i) => mascaraCPF(i.cpf ?? '') },
  { grupo: 'Pessoais', chave: 'pis', titulo: 'PIS / NIS', valor: (i) => mascaraPIS(i.pis ?? '') },
  { grupo: 'Pessoais', chave: 'rg', titulo: 'RG', valor: (i) => i.rg ?? '' },
  { grupo: 'Pessoais', chave: 'data_nascimento', titulo: 'Nascimento', valor: (i) => data(i.data_nascimento) },
  { grupo: 'Pessoais', chave: 'sexo', titulo: 'Sexo', valor: (i) => (i.sexo ? SEXO[i.sexo] : '') },
  { grupo: 'Contato', chave: 'email', titulo: 'E-mail', valor: (i) => i.email ?? '' },
  { grupo: 'Contato', chave: 'telefone', titulo: 'Telefone', valor: (i) => i.telefone ?? '' },
  { grupo: 'Endereço', chave: 'cep', titulo: 'CEP', valor: (i) => mascaraCEP(i.cep ?? '') },
  {
    grupo: 'Endereço', chave: 'endereco', titulo: 'Endereço',
    valor: (i) => [i.logradouro, i.numero, i.complemento].filter(Boolean).join(', '),
  },
  { grupo: 'Endereço', chave: 'bairro', titulo: 'Bairro', valor: (i) => i.bairro ?? '' },
  { grupo: 'Endereço', chave: 'cidade', titulo: 'Cidade', valor: (i) => i.cidade ?? '' },
  { grupo: 'Endereço', chave: 'uf', titulo: 'UF', valor: (i) => i.uf ?? '' },
  { grupo: 'Profissional', chave: 'empresa', titulo: 'Empresa', valor: (i) => i.empresa ?? '' },
  { grupo: 'Profissional', chave: 'cargo', titulo: 'Cargo', valor: (i) => i.cargo ?? '' },
  { grupo: 'Profissional', chave: 'cbo', titulo: 'CBO', valor: (i) => i.cbo ?? '' },
  { grupo: 'Profissional', chave: 'departamento', titulo: 'Departamento', valor: (i) => i.departamento ?? '' },
  { grupo: 'Profissional', chave: 'gestor', titulo: 'Gestor', valor: (i) => i.gestor ?? '' },
  { grupo: 'Profissional', chave: 'data_admissao', titulo: 'Admissão', valor: (i) => data(i.data_admissao) },
  { grupo: 'Profissional', chave: 'data_desligamento', titulo: 'Desligamento', valor: (i) => data(i.data_desligamento) },
  { grupo: 'Profissional', chave: 'situacao', titulo: 'Situação', valor: (i) => SITUACAO[i.situacao]?.label ?? i.situacao },
  {
    grupo: 'Profissional', chave: 'salario', titulo: 'Salário',
    valor: (i) => (i.salario === null ? '' : i.salario.toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })),
  },
  { grupo: 'Ponto', chave: 'jornada', titulo: 'Jornada', valor: (i) => i.jornada ?? '' },
  { grupo: 'Ponto', chave: 'regra', titulo: 'Regra de cálculo', valor: (i) => i.regra ?? '' },
  { grupo: 'Ponto', chave: 'controla_ponto', titulo: 'Controla ponto', valor: (i) => (i.controla_ponto ? 'Sim' : 'Não') },
  { grupo: 'Ponto', chave: 'controle_ponto_inicio', titulo: 'Controle desde', valor: (i) => data(i.controle_ponto_inicio) },
  { grupo: 'Ponto', chave: 'local_ponto_modo', titulo: 'Onde bate o ponto', valor: (i) => (i.local_ponto_modo ? LOCAL[i.local_ponto_modo] ?? '' : '') },
  { grupo: 'Ponto', chave: 'usuario', titulo: 'Acesso ao sistema', valor: (i) => i.usuario ?? '' },
  { grupo: 'Outros', chave: 'observacoes', titulo: 'Observações', valor: (i) => i.observacoes ?? '' },
];
const GRUPOS = [...new Set(COLUNAS.map((c) => c.grupo))];
const PADRAO = ['matricula', 'nome', 'cpf', 'cargo', 'departamento', 'data_admissao', 'situacao'];
const CHAVE_STORAGE = 'geponto.relatorio_colaboradores.colunas';

function lerColunas(): string[] {
  try {
    const v = JSON.parse(localStorage.getItem(CHAVE_STORAGE) ?? 'null');
    if (Array.isArray(v)) {
      const ok = v.filter((c) => COLUNAS.some((x) => x.chave === c));
      if (ok.length) return ok;
    }
  } catch { /* sem armazenamento: usa o padrão */ }
  return PADRAO;
}

type Situacao = 'ativos' | 'desligados' | 'todos';

export default function RelatorioColaboradores() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const [situacao, setSituacao] = useState<Situacao>('ativos');
  const [filtros, setFiltros] = useState({ colaboradores: [] as string[], departamento: '' });
  const [campo, setCampo] = useState({ chave: '', condicao: 'vazio' as 'vazio' | 'preenchido' });
  const [selecionadas, setSelecionadas] = useState<string[]>(lerColunas);
  const [itens, setItens] = useState<Item[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  useEffect(() => {
    try { localStorage.setItem(CHAVE_STORAGE, JSON.stringify(selecionadas)); } catch { /* ignora */ }
  }, [selecionadas]);

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      const r = await api<{ itens: Item[] }>('api_relatorio_colaboradores', {
        p_situacao: situacao === 'todos' ? null : situacao,
        p_colaboradores: paramColaboradores(filtros.colaboradores),
        p_departamento: filtros.departamento || null,
      });
      setItens(r.itens);
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  // Primeira consulta ao abrir a tela (não depende de período)
  useEffect(() => { void consultar(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // Colunas na ordem do cadastro
  const colunas = COLUNAS.filter((c) => selecionadas.includes(c.chave));
  const colunaFiltro = COLUNAS.find((c) => c.chave === campo.chave);
  const linhas = useMemo(() => (itens ?? []).filter((i) => {
    if (!colunaFiltro) return true;
    const vazio = colunaFiltro.valor(i).trim() === '';
    return campo.condicao === 'vazio' ? vazio : !vazio;
  }), [itens, colunaFiltro, campo.condicao]);

  const alternar = (chave: string) =>
    setSelecionadas((s) => (s.includes(chave) ? (s.length > 1 ? s.filter((c) => c !== chave) : s) : [...s, chave]));
  const alternarGrupo = (grupo: string) => {
    const doGrupo = COLUNAS.filter((c) => c.grupo === grupo).map((c) => c.chave);
    const todas = doGrupo.every((c) => selecionadas.includes(c));
    setSelecionadas((s) => {
      const n = todas ? s.filter((c) => !doGrupo.includes(c)) : [...new Set([...s, ...doGrupo])];
      return n.length ? n : s;
    });
  };

  const exportar = () => {
    const csv = [
      colunas.map((c) => c.titulo).join(';'),
      ...linhas.map((i) => colunas.map((c) => `"${c.valor(i).replace(/"/g, '""')}"`).join(';')),
    ];
    baixarArquivo('colaboradores.csv', csv.join('\r\n'), 'text/csv');
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Dados dos colaboradores</h2>
          <p className="mt-1 text-sm text-slate-500">
            Escolha as informações do cadastro que entram no relatório. Para achar cadastros incompletos, filtre por um campo em branco.
          </p>
        </div>
        {linhas.length > 0 && (
          <div className="flex gap-2 print:hidden">
            <Button variant="secondary" onClick={exportar}><Download className="h-4 w-4" /> Exportar CSV</Button>
            <Button variant="secondary" onClick={() => window.print()}><Printer className="h-4 w-4" /> Imprimir</Button>
          </div>
        )}
      </div>

      <section className="card space-y-4 p-5 print:hidden">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-[180px_1fr_1fr_auto] lg:items-end">
          <Field label="Situação">
            <select className="input" value={situacao} onChange={(e) => setSituacao(e.target.value as Situacao)}>
              <option value="ativos">Ativos</option>
              <option value="desligados">Desligados</option>
              <option value="todos">Todos</option>
            </select>
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

        <div className="grid gap-4 sm:grid-cols-2 lg:w-2/3">
          <Field label="Filtrar por campo" dica="Ex.: PIS em branco mostra quem ainda não tem PIS no cadastro">
            <select className="input" value={campo.chave} onChange={(e) => setCampo((c) => ({ ...c, chave: e.target.value }))}>
              <option value="">Sem filtro</option>
              {GRUPOS.map((g) => (
                <optgroup key={g} label={g}>
                  {COLUNAS.filter((c) => c.grupo === g && c.chave !== 'controla_ponto' && c.chave !== 'situacao').map((c) => (
                    <option key={c.chave} value={c.chave}>{c.titulo}</option>
                  ))}
                </optgroup>
              ))}
            </select>
          </Field>
          <Field label="Condição">
            <select className="input" value={campo.condicao} disabled={!campo.chave}
              onChange={(e) => setCampo((c) => ({ ...c, condicao: e.target.value as 'vazio' | 'preenchido' }))}>
              <option value="vazio">Em branco</option>
              <option value="preenchido">Preenchido</option>
            </select>
          </Field>
        </div>

        <div className="space-y-3 border-t border-slate-100 pt-4">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="text-sm font-medium text-slate-700">
              Colunas do relatório <span className="font-normal text-slate-400">· {selecionadas.length} de {COLUNAS.length}</span>
            </p>
            <div className="flex gap-2">
              <Button variant="ghost" className="!px-2.5 !py-1 text-xs" onClick={() => setSelecionadas(COLUNAS.map((c) => c.chave))}>Marcar todas</Button>
              <Button variant="ghost" className="!px-2.5 !py-1 text-xs" onClick={() => setSelecionadas(PADRAO)}><RotateCcw className="h-3.5 w-3.5" /> Padrão</Button>
            </div>
          </div>
          {GRUPOS.map((g) => {
            const doGrupo = COLUNAS.filter((c) => c.grupo === g);
            return (
              <div key={g} className="flex flex-wrap items-center gap-1.5">
                <button type="button" onClick={() => alternarGrupo(g)}
                  className="w-24 shrink-0 text-left text-xs font-semibold uppercase tracking-wide text-slate-400 hover:text-primary-700">
                  {g}
                </button>
                {doGrupo.map((c) => {
                  const ativa = selecionadas.includes(c.chave);
                  return (
                    <button key={c.chave} type="button" onClick={() => alternar(c.chave)} aria-pressed={ativa}
                      className={clsx('inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium ring-1 transition',
                        ativa ? 'bg-primary-50 text-primary-700 ring-primary-200' : 'bg-white text-slate-500 ring-slate-200 hover:bg-slate-50')}>
                      {ativa && <Check className="h-3 w-3" />} {c.titulo}
                    </button>
                  );
                })}
              </div>
            );
          })}
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {itens === null ? (
        <div className="card"><EmptyState icon={Contact} titulo={carregando ? 'Carregando…' : 'Clique em Consultar'} descricao="Os dados vêm do cadastro dos colaboradores." /></div>
      ) : linhas.length === 0 ? (
        <div className="card"><EmptyState icon={Contact} titulo="Nenhum colaborador" descricao="Não há colaboradores com esses filtros." /></div>
      ) : (
        <>
          <CabecalhoImpressao titulo="Dados dos colaboradores" />
          <p className="text-sm text-slate-500">
            {linhas.length} colaborador(es)
            {colunaFiltro && <> com <strong className="font-medium text-slate-700">{colunaFiltro.titulo}</strong> {campo.condicao === 'vazio' ? 'em branco' : 'preenchido'}</>}
          </p>
          <div className="card overflow-x-auto print:overflow-visible print:shadow-none print:ring-0">
            <table className="w-full text-sm print:text-xs">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  {colunas.map((c) => <th key={c.chave} className="whitespace-nowrap px-4 py-2.5 font-medium">{c.titulo}</th>)}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {linhas.map((i) => (
                  <tr key={i.colaborador_id} className="break-inside-avoid align-top">
                    {colunas.map((c) => {
                      const v = c.valor(i);
                      return (
                        <td key={c.chave} className={clsx('px-4 py-2.5',
                          c.chave === 'observacoes' || c.chave === 'endereco' ? 'min-w-[220px]' : 'whitespace-nowrap',
                          c.chave === 'nome' ? 'font-medium text-slate-800' : 'text-slate-700',
                          (c.chave === 'cpf' || c.chave === 'pis' || c.chave === 'matricula') && 'tabular-nums')}>
                          {v || <span className="text-slate-300">—</span>}
                        </td>
                      );
                    })}
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
