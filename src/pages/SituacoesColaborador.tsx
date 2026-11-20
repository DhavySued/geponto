import clsx from 'clsx';
import { AlertTriangle, CalendarClock, Lock, Pencil, Plus, Search, Trash2, UserCog } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { Badge, SITUACAO } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, parseISODate, toISODate } from '@/lib/format';
import { opcoesColaboradores, paramColaboradores } from '@/lib/hooks';
import { api } from '@/lib/api';
import type { ColaboradorSituacao, SituacaoColaborador, SituacoesDados } from '@/lib/types';

/** Situações que se lançam aqui (o desligamento é a data de desligamento do cadastro) */
const SITUACOES: SituacaoColaborador[] = ['ativo', 'ferias', 'afastado'];

const dataBR = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });
const dataHoraBR = (s: string) =>
  new Date(s).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' });
const moeda = (v: number | null) =>
  v == null ? '—' : Number(v).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' });
const vespera = (s: string) => {
  const d = parseISODate(s);
  d.setDate(d.getDate() - 1);
  return toISODate(d);
};
/** "1.234,56" e "2.500" → "1234.56" / "2500"; "2500.00" (vindo do banco) segue como está */
const salarioParaApi = (s: string) =>
  s.includes(',') ? s.replace(/\./g, '').replace(',', '.') : /^\d{1,3}(\.\d{3})+$/.test(s) ? s.replace(/\./g, '') : s;

interface Form {
  id?: string;
  colaborador_id: string;
  data_inicio: string;
  situacao: SituacaoColaborador;
  cargo_id: string;
  departamento_id: string;
  jornada_id: string;
  perfil_evento_id: string;
  salario: string;
  motivo: string;
}

const formVazio = (colaborador = ''): Form => ({
  colaborador_id: colaborador, data_inicio: toISODate(new Date()), situacao: 'ativo', cargo_id: '', departamento_id: '',
  jornada_id: '', perfil_evento_id: '', salario: '', motivo: '',
});

/** Situação vigente numa data (a última que começou até ela) */
function vigenteEm(lista: ColaboradorSituacao[], colaborador: string, data: string) {
  return lista
    .filter((s) => s.colaborador_id === colaborador && s.data_inicio <= data)
    .sort((a, b) => b.data_inicio.localeCompare(a.data_inicio))[0];
}

function SituacaoModal({
  aberto,
  situacao,
  colaboradorInicial,
  dados,
  podeEditar,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  situacao: ColaboradorSituacao | null;
  colaboradorInicial: string;
  dados: SituacoesDados | null;
  podeEditar: boolean;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<Form>(formVazio());
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const todas = dados?.situacoes ?? [];
  const somenteLeitura = !podeEditar || !!situacao?.fechado;
  const colab = dados?.colaboradores.find((c) => c.id === form.colaborador_id);

  // Nova situação: parte do que vale na data (o usuário muda só o que mudou)
  const preencher = useCallback((colaborador: string, data: string, base?: Partial<Form>) => {
    const v = colaborador ? vigenteEm(todas, colaborador, data) : undefined;
    setForm({
      ...formVazio(colaborador),
      data_inicio: data,
      ...(v && {
        situacao: v.situacao === 'desligado' ? 'ativo' : v.situacao,
        cargo_id: v.cargo_id ?? '', departamento_id: v.departamento_id ?? '', jornada_id: v.jornada_id ?? '',
        perfil_evento_id: v.perfil_evento_id ?? '', salario: v.salario == null ? '' : String(v.salario),
      }),
      ...base,
    });
  }, [todas]);

  useEffect(() => {
    if (!aberto) return;
    setErro(null);
    if (situacao) {
      setForm({
        id: situacao.id, colaborador_id: situacao.colaborador_id, data_inicio: situacao.data_inicio, situacao: situacao.situacao,
        cargo_id: situacao.cargo_id ?? '', departamento_id: situacao.departamento_id ?? '', jornada_id: situacao.jornada_id ?? '',
        perfil_evento_id: situacao.perfil_evento_id ?? '', salario: situacao.salario == null ? '' : String(situacao.salario),
        motivo: situacao.motivo ?? '',
      });
    } else {
      preencher(colaboradorInicial, toISODate(new Date()));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [aberto, situacao, colaboradorInicial]);

  const set = <K extends keyof Form>(k: K, v: Form[K]) => setForm((f) => ({ ...f, [k]: v }));

  // Até quando vale: véspera da próxima situação do colaborador
  const proxima = todas
    .filter((s) => s.colaborador_id === form.colaborador_id && s.id !== form.id && s.data_inicio > form.data_inicio)
    .sort((a, b) => a.data_inicio.localeCompare(b.data_inicio))[0];

  const salvar = async () => {
    setErro(null);
    if (!form.colaborador_id) return setErro('Escolha o colaborador.');
    if (!form.data_inicio) return setErro('Informe a partir de quando a situação vale.');
    if (colab && form.data_inicio < colab.data_admissao) {
      return setErro(`A situação não pode começar antes da admissão (${dataBR(colab.data_admissao)}).`);
    }
    setSalvando(true);
    try {
      await api('api_colaborador_situacao_salvar', { p_dados: { ...form, salario: salarioParaApi(form.salario) } });
      toast(form.id ? 'Situação alterada.' : 'Situação incluída. A apuração já considera a nova situação a partir da data.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const perfis = dados?.perfis_eventos ?? [];
  const opcao = (lista: { id: string; nome: string }[], id: string, nomeAtual: string | null | undefined) => (
    <>
      {/* Item desativado depois: continua aparecendo em quem já o usava */}
      {id && !lista.some((o) => o.id === id) && <option value={id}>{nomeAtual ?? 'Atual'} (inativo)</option>}
      {lista.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
    </>
  );

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-2xl"
      titulo={situacao ? (somenteLeitura ? 'Situação' : 'Alterar situação') : 'Nova situação'}
      descricao={colab ? `${colab.nome} · matrícula ${colab.matricula} · admitido em ${dataBR(colab.data_admissao)}` : 'O que muda para o colaborador a partir de uma data.'}
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>{somenteLeitura ? 'Fechar' : 'Cancelar'}</Button>
          {!somenteLeitura && <Button onClick={salvar} loading={salvando}>Salvar situação</Button>}
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      {situacao?.fechado && (
        <p className="mb-4 flex items-center gap-2 rounded-xl bg-slate-50 p-3 text-sm text-slate-600 ring-1 ring-slate-200">
          <Lock className="h-4 w-4" /> Esta situação começa num período fechado e não pode ser alterada.
        </p>
      )}
      <fieldset disabled={somenteLeitura} className="grid gap-4 sm:grid-cols-2">
        <Field label="Colaborador" obrigatorio className="sm:col-span-2">
          <select className="input" value={form.colaborador_id} disabled={!!situacao}
            onChange={(e) => preencher(e.target.value, form.data_inicio, { motivo: form.motivo })}>
            <option value="">Selecione…</option>
            {dados?.colaboradores.map((c) => <option key={c.id} value={c.id}>{c.nome} · {c.matricula}</option>)}
          </select>
        </Field>
        <Field
          label="Vale a partir de"
          obrigatorio
          dica={situacao
            ? `A data não pode ser alterada.${situacao.primeira ? ' É a da admissão.' : ' Para outra data, lance uma nova situação e exclua esta.'}`
            : proxima
                ? `Vale até ${dataBR(vespera(proxima.data_inicio))}, véspera da próxima situação.`
                : 'Vale dessa data em diante.'}
        >
          <input type="date" className="input" value={form.data_inicio} min={colab?.data_admissao} disabled={!!situacao}
            onChange={(e) => {
              const d = e.target.value;
              if (!situacao && d && form.colaborador_id) preencher(form.colaborador_id, d, { motivo: form.motivo });
              else set('data_inicio', d);
            }} />
        </Field>
        <Field label="Situação" obrigatorio>
          <select className="input" value={form.situacao} onChange={(e) => set('situacao', e.target.value as SituacaoColaborador)}>
            {SITUACOES.map((s) => <option key={s} value={s}>{SITUACAO[s].label}</option>)}
          </select>
        </Field>
        <Field label="Cargo">
          <select className="input" value={form.cargo_id} onChange={(e) => set('cargo_id', e.target.value)}>
            <option value="">Nenhum</option>
            {opcao(dados?.cargos ?? [], form.cargo_id, situacao?.cargo)}
          </select>
        </Field>
        <Field label="Departamento">
          <select className="input" value={form.departamento_id} onChange={(e) => set('departamento_id', e.target.value)}>
            <option value="">Nenhum</option>
            {opcao(dados?.departamentos ?? [], form.departamento_id, situacao?.departamento)}
          </select>
        </Field>
        <Field label="Jornada de trabalho">
          <select className="input" value={form.jornada_id} onChange={(e) => set('jornada_id', e.target.value)}>
            <option value="">Selecione…</option>
            {opcao(dados?.jornadas ?? [], form.jornada_id, situacao?.jornada)}
          </select>
        </Field>
        <Field label="Regra de cálculo">
          <select className="input" value={form.perfil_evento_id} onChange={(e) => set('perfil_evento_id', e.target.value)}>
            {!form.perfil_evento_id && (
              <option value="">Regra padrão{perfis.find((p) => p.padrao) ? ` (${perfis.find((p) => p.padrao)!.nome})` : ''}</option>
            )}
            {opcao(perfis.map((p) => ({ id: p.id, nome: p.padrao ? `${p.nome} · padrão` : p.nome })), form.perfil_evento_id, situacao?.perfil_evento)}
          </select>
        </Field>
        <Field label="Salário (R$)">
          <input className="input tabular-nums" inputMode="decimal" value={form.salario} placeholder="0,00"
            onChange={(e) => set('salario', e.target.value.replace(/[^\d.,]/g, ''))} />
        </Field>
        <Field label="Motivo" className="sm:col-span-2">
          <input className="input" value={form.motivo} maxLength={200} placeholder="Ex.: promoção, mudança de setor, troca de turno…"
            onChange={(e) => set('motivo', e.target.value)} />
        </Field>
      </fieldset>
      <p className="mt-4 text-xs text-slate-500">
        A apuração usa a jornada e a regra de cálculo da situação vigente em cada dia; o banco de horas dos dias já
        encerrados é recalculado a partir da data.
      </p>
    </Modal>
  );
}

export default function SituacoesColaborador() {
  const toast = useToast();
  const { pode } = useAuth();
  const podeEditar = pode('situacoes_colaborador', 'editar');
  const [params] = useSearchParams();
  const [dados, setDados] = useState<SituacoesDados | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [departamento, setDepartamento] = useState('');
  const [colaboradores, setColaboradores] = useState<string[]>(() => (params.get('colaborador') ? [params.get('colaborador')!] : []));
  const [somenteVigente, setSomenteVigente] = useState(false);
  const [modal, setModal] = useState<{ aberto: boolean; situacao: ColaboradorSituacao | null; colaborador: string }>({
    aberto: false, situacao: null, colaborador: '',
  });
  const [excluir, setExcluir] = useState<ColaboradorSituacao | null>(null);
  const [excluindo, setExcluindo] = useState(false);
  // Ao entrar, pergunta qual colaborador consultar; fechando sem escolher, ficam todos
  const [escolher, setEscolher] = useState(() => !params.get('colaborador'));
  const [escolhidos, setEscolhidos] = useState<string[]>([]);

  const consultar = useCallback(async (ids = colaboradores) => {
    setCarregando(true);
    setErro(null);
    try {
      setDados(await api<SituacoesDados>('api_colaborador_situacoes', { p_colaboradores: paramColaboradores(ids) }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar as situações.');
    } finally {
      setCarregando(false);
    }
  }, [colaboradores]);

  useEffect(() => {
    consultar();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Linhas da tabela (a API já vem ordenada por nome e da mais recente para a mais antiga)
  const linhas = useMemo(() => {
    const doDepto = new Set(
      departamento ? (dados?.colaboradores ?? []).filter((c) => c.departamento_id === departamento).map((c) => c.id) : [],
    );
    return (dados?.situacoes ?? []).filter((x) =>
      (!departamento || doDepto.has(x.colaborador_id)) && (!somenteVigente || x.vigente || (x.primeira && x.futura)));
  }, [dados, departamento, somenteVigente]);
  const qtdColaboradores = useMemo(() => new Set(linhas.map((l) => l.colaborador_id)).size, [linhas]);

  const confirmarEscolha = () => {
    setEscolher(false);
    setColaboradores(escolhidos);
    if (escolhidos.length) consultar(escolhidos);
  };

  const confirmarExclusao = async () => {
    if (!excluir) return;
    setExcluindo(true);
    try {
      await api('api_colaborador_situacao_excluir', { p_id: excluir.id });
      toast('Situação excluída. Vale de novo a situação anterior.');
      setExcluir(null);
      consultar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    } finally {
      setExcluindo(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Situação do Colaborador</h2>
          <p className="mt-1 max-w-3xl text-sm text-slate-500">
            Situação, cargo, departamento, jornada, regra de cálculo e salário valem a partir de uma data, até a véspera da
            próxima situação. A primeira é a da admissão, criada com o cadastro. O desligamento é a data de desligamento, no cadastro. Os dados pessoais ficam no{' '}
            <Link to="/cadastros/colaboradores" className="font-medium text-primary-600 hover:underline">Cadastro de Colaboradores</Link>.
          </p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={() => setModal({ aberto: true, situacao: null, colaborador: colaboradores.length === 1 ? colaboradores[0] : '' })}>
            <Plus className="h-4 w-4" /> Nova situação
          </Button>
        )}
      </div>

      <section className="card p-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-6">
          <Field label="Departamento">
            <select className="input" value={departamento} onChange={(e) => { setDepartamento(e.target.value); setColaboradores([]); }}>
              <option value="">Todos</option>
              {dados?.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
            </select>
          </Field>
          <Field label="Colaborador" className="lg:col-span-3">
            <ComboboxChips opcoes={opcoesColaboradores(dados?.colaboradores, { departamento })} valor={colaboradores}
              onChange={setColaboradores} rotuloTodos="Todos os colaboradores" />
          </Field>
          <div className="flex items-end">
            <label className="flex h-10 cursor-pointer items-center gap-2 text-sm text-slate-600">
              <input type="checkbox" className="h-4 w-4 rounded border-slate-300 text-primary-600"
                checked={somenteVigente} onChange={(e) => setSomenteVigente(e.target.checked)} />
              Só a vigente hoje
            </label>
          </div>
          <div className="flex items-end">
            <Button onClick={() => consultar()} loading={carregando} className="h-10 w-full">
              <Search className="h-4 w-4" /> Consultar
            </Button>
          </div>
        </div>
        {dados?.fechado_ate && (
          <p className="mt-3 flex items-center gap-1.5 text-xs text-slate-500">
            <Lock className="h-3.5 w-3.5" /> Período fechado até {dataBR(dados.fechado_ate)}: as situações até essa data não podem ser
            alteradas; lance as novas a partir de {dataBR(toISODate(new Date(parseISODate(dados.fechado_ate).getTime() + 86_400_000)))}.
          </p>
        )}
      </section>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {dados === null ? (
        <div className="card h-64 animate-pulse" />
      ) : linhas.length === 0 ? (
        <div className="card">
          <EmptyState icon={UserCog} titulo="Nenhuma situação encontrada" descricao="Ajuste os filtros ou cadastre um colaborador." />
        </div>
      ) : (
        <section className="card overflow-hidden">
          <header className="flex flex-wrap items-center justify-between gap-2 border-b border-slate-100 px-5 py-3 text-xs text-slate-500">
            <span>{linhas.length} situação(ões) de {qtdColaboradores} colaborador(es)</span>
            <span className="flex items-center gap-1.5"><span className="h-3 w-3 rounded bg-primary-50 ring-1 ring-primary-200" /> vigente hoje</span>
          </header>
          <div className="max-h-[70vh] overflow-auto">
            <table className="w-full min-w-[1100px] text-sm">
              <thead className="sticky top-0 z-10 bg-slate-50 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-4 py-2.5">Colaborador</th>
                  <th className="px-3 py-2.5">De</th>
                  <th className="px-3 py-2.5">Até</th>
                  <th className="px-3 py-2.5">Situação</th>
                  <th className="px-3 py-2.5">Cargo</th>
                  <th className="px-3 py-2.5">Departamento</th>
                  <th className="px-3 py-2.5">Jornada</th>
                  <th className="px-3 py-2.5">Regra de cálculo</th>
                  <th className="px-3 py-2.5 text-right">Salário</th>
                  <th className="px-3 py-2.5">Motivo</th>
                  <th className="px-3 py-2.5" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {linhas.map((x, i) => {
                  const novoColaborador = i === 0 || linhas[i - 1].colaborador_id !== x.colaborador_id;
                  return (
                    <tr key={x.id} className={clsx(x.vigente && 'bg-primary-50/50', novoColaborador && i > 0 && 'border-t-2 border-slate-200')}>
                      <td className="px-4 py-2.5 align-top">
                        {novoColaborador ? (
                          <>
                            <p className="font-medium text-slate-800">{x.colaborador}</p>
                            <p className="text-xs text-slate-400">Matrícula {x.matricula}</p>
                          </>
                        ) : (
                          <span className="text-xs text-slate-300">〃</span>
                        )}
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 align-top tabular-nums text-slate-800">
                        {dataBR(x.data_inicio)}
                        <div className="mt-1 flex flex-wrap gap-1">
                          {x.primeira && <Badge tone="slate" dot={false}><CalendarClock className="mr-1 inline h-3 w-3" />Admissão</Badge>}
                          {x.fechado && <Badge tone="slate" dot={false}><Lock className="mr-1 inline h-3 w-3" />Fechado</Badge>}
                          {x.futura && <Badge tone="orange">Futura</Badge>}
                        </div>
                      </td>
                      <td className="whitespace-nowrap px-3 py-2.5 align-top tabular-nums text-slate-600">
                        {x.data_fim ? dataBR(x.data_fim) : <span className="text-slate-400">em diante</span>}
                      </td>
                      <td className="px-3 py-2.5 align-top"><Badge tone={SITUACAO[x.situacao].tone}>{SITUACAO[x.situacao].label}</Badge></td>
                      <td className="px-3 py-2.5 align-top text-slate-700">{x.cargo ?? '—'}</td>
                      <td className="px-3 py-2.5 align-top text-slate-700">{x.departamento ?? '—'}</td>
                      <td className="px-3 py-2.5 align-top text-slate-700">{x.jornada ?? '—'}</td>
                      <td className="px-3 py-2.5 align-top text-slate-700">{x.perfil_evento ?? 'Regra padrão'}</td>
                      <td className="whitespace-nowrap px-3 py-2.5 text-right align-top tabular-nums text-slate-700">{moeda(x.salario)}</td>
                      <td className="max-w-[200px] px-3 py-2.5 align-top text-xs text-slate-500">{x.motivo ?? '—'}</td>
                      <td className="px-3 py-2.5 align-top">
                        <div className="flex justify-end gap-1">
                          {podeEditar && novoColaborador && (
                            <Button variant="ghost" className="h-8 px-2" title="Nova situação para este colaborador"
                              onClick={() => setModal({ aberto: true, situacao: null, colaborador: x.colaborador_id })}>
                              <Plus className="h-4 w-4" />
                              <span className="sr-only">Nova situação</span>
                            </Button>
                          )}
                          <Button variant="ghost" className="h-8 px-2" onClick={() => setModal({ aberto: true, situacao: x, colaborador: x.colaborador_id })}
                            title={`Lançada${x.usuario ? ` por ${x.usuario}` : ''} em ${dataHoraBR(x.created_at)}${x.alterado_por ? ` · alterada por ${x.alterado_por}` : ''}`}>
                            <Pencil className="h-4 w-4" /> {podeEditar && !x.fechado ? 'Alterar' : 'Ver'}
                          </Button>
                          {podeEditar && !x.fechado && !x.primeira && (
                            <Button variant="ghost" className="h-8 px-2 text-rose-600 hover:bg-rose-50" onClick={() => setExcluir(x)}>
                              <Trash2 className="h-4 w-4" />
                              <span className="sr-only">Excluir</span>
                            </Button>
                          )}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </section>
      )}

      <Modal
        aberto={escolher}
        onFechar={() => setEscolher(false)}
        titulo="Qual colaborador deseja consultar?"
        descricao="Escolha um ou mais. Se fechar sem escolher, aparecem todos."
        rodape={
          <>
            <Button variant="secondary" onClick={() => setEscolher(false)}>Ver todos</Button>
            <Button onClick={confirmarEscolha} disabled={!escolhidos.length}>
              <Search className="h-4 w-4" /> Consultar
            </Button>
          </>
        }
      >
        <Field label="Colaborador">
          <ComboboxChips opcoes={opcoesColaboradores(dados?.colaboradores)} valor={escolhidos} onChange={setEscolhidos}
            placeholder="Buscar por nome ou matrícula…" rotuloTodos="Todos os colaboradores" />
        </Field>
        <div className="h-48" aria-hidden />
      </Modal>

      <SituacaoModal
        aberto={modal.aberto}
        situacao={modal.situacao}
        colaboradorInicial={modal.colaborador}
        dados={dados}
        podeEditar={podeEditar}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal((m) => ({ ...m, aberto: false }));
          consultar();
        }}
      />

      <Modal
        aberto={!!excluir}
        onFechar={() => setExcluir(null)}
        titulo="Excluir situação?"
        descricao={excluir ? `${excluir.colaborador}: situação de ${dataBR(excluir.data_inicio)}. A situação anterior volta a valer a partir dessa data.` : undefined}
        rodape={
          <>
            <Button variant="secondary" onClick={() => setExcluir(null)}>Cancelar</Button>
            <Button variant="accent" onClick={confirmarExclusao} loading={excluindo}>
              <Trash2 className="h-4 w-4" /> Excluir
            </Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">O banco de horas dos dias já encerrados é recalculado.</p>
      </Modal>
    </div>
  );
}
