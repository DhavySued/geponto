import clsx from 'clsx';
import { AlertTriangle, ArrowRightLeft, Filter, Hourglass, Plus, FileDown, Search, Trash2 } from 'lucide-react';
import { useNavigate } from 'react-router-dom';
import { Fragment, useCallback, useEffect, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, formatMinutos, horasParaMinutos, toISODate } from '@/lib/format';
import { ORIGEM_BATIDA, ocorrencia, rotuloMarcacao, siglaMarcacao } from '@/lib/ponto';
import { gerarPdfBancoHoras } from '@/lib/pdfBancoHoras';
import { api } from '@/lib/supabase';
import type { BancoHorasDetalhe, BancoHorasDia, BancoHorasResumo, TipoLancamento } from '@/lib/types';

const TIPOS: Record<TipoLancamento, { label: string; descricao: string }> = {
  credito: { label: 'Crédito', descricao: 'Soma horas ao saldo' },
  debito: { label: 'Débito', descricao: 'Desconta horas do saldo' },
  compensacao: { label: 'Compensação', descricao: 'Folga ou saída antecipada usando o saldo' },
  ajuste: { label: 'Ajuste', descricao: 'Correção positiva ou negativa' },
  conversao: { label: 'Conversão', descricao: 'Saldo convertido em pagamento ou desconto' },
};

// A conversão tem menu próprio (Conversão do Banco de Horas)
const TIPOS_MANUAIS: TipoLancamento[] = ['credito', 'debito', 'compensacao', 'ajuste'];

const primeiroDoMes = () => {
  const d = new Date();
  return toISODate(new Date(d.getFullYear(), d.getMonth(), 1));
};

function LancamentoModal({
  aberto,
  colaboradores,
  colaboradorInicial,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  colaboradores: BancoHorasResumo[];
  colaboradorInicial: string | null;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [colab, setColab] = useState('');
  const [dataL, setDataL] = useState(toISODate(new Date()));
  const [tipo, setTipo] = useState<TipoLancamento>('credito');
  const [horas, setHoras] = useState('');
  const [negativo, setNegativo] = useState(false);
  const [descricao, setDescricao] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setColab(colaboradorInicial ?? '');
    setDataL(toISODate(new Date()));
    setTipo('credito');
    setHoras('');
    setNegativo(false);
    setDescricao('');
    setErro(null);
  }, [aberto, colaboradorInicial]);

  const salvar = async () => {
    const min = horasParaMinutos(horas);
    if (!colab) return setErro('Selecione o colaborador.');
    if (min <= 0) return setErro('Informe a quantidade de horas (ex.: 2:30).');
    if (!descricao.trim()) return setErro('Informe a justificativa.');
    setSalvando(true);
    setErro(null);
    try {
      await api('api_banco_horas_lancar', {
        p_dados: { colaborador_id: colab, data: dataL, tipo, minutos: tipo === 'ajuste' && negativo ? -min : min, descricao },
      });
      toast('Lançamento registrado.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao lançar.');
    } finally {
      setSalvando(false);
    }
  };

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      titulo="Novo lançamento no banco de horas"
      descricao="Lançamentos manuais ficam registrados com o seu usuário."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button onClick={salvar} loading={salvando}>Lançar</Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Colaborador" obrigatorio className="sm:col-span-2">
          <select className="input" value={colab} onChange={(e) => setColab(e.target.value)}>
            <option value="">Selecione…</option>
            {colaboradores.map((c) => <option key={c.id} value={c.id}>{c.nome}</option>)}
          </select>
        </Field>
        <Field label="Tipo" obrigatorio grupo className="sm:col-span-2">
          <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
            {TIPOS_MANUAIS.map((t) => (
              <button
                key={t}
                type="button"
                onClick={() => setTipo(t)}
                className={clsx(
                  'rounded-xl px-3 py-2 text-sm font-medium ring-1 ring-inset transition',
                  tipo === t ? 'bg-primary-700 text-white ring-primary-700' : 'text-slate-600 ring-slate-200 hover:bg-slate-50',
                )}
              >
                {TIPOS[t].label}
              </button>
            ))}
          </div>
          <span className="mt-1.5 block text-[11px] text-slate-400">{TIPOS[tipo].descricao}</span>
        </Field>
        <Field label="Data" obrigatorio>
          <input type="date" className="input" value={dataL} onChange={(e) => setDataL(e.target.value)} />
        </Field>
        <Field label="Horas (h:mm)" obrigatorio grupo>
          <div className="flex gap-2">
            {tipo === 'ajuste' && (
              <button
                type="button"
                onClick={() => setNegativo((v) => !v)}
                className="h-10 w-10 shrink-0 rounded-xl text-lg font-semibold ring-1 ring-inset ring-slate-200 hover:bg-slate-50"
                aria-label={negativo ? 'Ajuste negativo' : 'Ajuste positivo'}
              >
                {negativo ? '−' : '+'}
              </button>
            )}
            <input
              className="input tabular-nums"
              inputMode="numeric"
              placeholder="2:30"
              value={horas}
              onChange={(e) => setHoras(e.target.value.replace(/[^\d:]/g, '').slice(0, 6))}
            />
          </div>
        </Field>
        <Field label="Justificativa" obrigatorio className="sm:col-span-2">
          <textarea className="input h-20 py-2" value={descricao} onChange={(e) => setDescricao(e.target.value)}
            placeholder="Ex.: Folga compensatória do dia 15/10" />
        </Field>
      </div>
    </Modal>
  );
}

const dataBR = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });

/** Minutos com sinal; zero em cinza */
function Min({ min, className }: { min: number | null; className?: string }) {
  if (min == null) return <span className={clsx('text-slate-300', className)}>—</span>;
  if (min === 0) return <span className={clsx('tabular-nums text-slate-400', className)}>0h00</span>;
  return (
    <span className={clsx('font-semibold tabular-nums', min > 0 ? 'text-primary-600' : 'text-accent-700', className)}>
      {formatMinutos(min, true)}
    </span>
  );
}

/** Observações do saldo do dia */
function notaDoDia(d: BancoHorasDia): string | null {
  const soma = (d.turnos ?? []).reduce((s, t) => s + t.gerou_min, 0);
  const partes: string[] = [];
  if (d.ocorrencia === 'em_andamento') partes.push('Dia em andamento: o saldo é apurado no fim do dia');
  else if (d.saldo_dia === 0 && soma !== 0) partes.push('Dentro da tolerância diária');
  if (d.saldo_dia !== 0 && !d.vai_para_banco) partes.push('Saldo vai para a folha (jornada sem banco de horas)');
  if (d.lancamentos?.length) partes.push('Saldo inclui os lançamentos manuais do dia');
  return partes.join(' · ') || null;
}

interface FiltroBH {
  ini: string;
  fim: string;
  colaborador: string;
}

function FiltroModal({
  aberto,
  colaboradores,
  inicial,
  carregando,
  erro,
  onFechar,
  onAplicar,
}: {
  aberto: boolean;
  colaboradores: BancoHorasResumo[];
  inicial: FiltroBH;
  carregando: boolean;
  erro: string | null;
  onFechar: () => void;
  onAplicar: (f: FiltroBH) => void;
}) {
  const [f, setF] = useState(inicial);
  const [busca, setBusca] = useState('');

  useEffect(() => {
    if (aberto) {
      setF(inicial);
      setBusca('');
    }
    // Reinicia o formulário só quando o popup abre
  }, [aberto]);

  const termo = busca.trim().toLowerCase();
  const lista = colaboradores.filter((c) => !termo || c.nome.toLowerCase().includes(termo) || c.matricula.toLowerCase().includes(termo));
  const hoje = toISODate(new Date());
  const atalhos: [string, () => FiltroBH][] = [
    ['Este mês', () => ({ ...f, ini: primeiroDoMes(), fim: hoje })],
    ['Mês passado', () => {
      const d = new Date();
      return { ...f, ini: toISODate(new Date(d.getFullYear(), d.getMonth() - 1, 1)), fim: toISODate(new Date(d.getFullYear(), d.getMonth(), 0)) };
    }],
    ['Últimos 7 dias', () => {
      const d = new Date();
      d.setDate(d.getDate() - 6);
      return { ...f, ini: toISODate(d), fim: hoje };
    }],
  ];

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      titulo="Consultar banco de horas"
      descricao="Escolha o período e o colaborador (ou todos)."
      rodape={
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onFechar}>Cancelar</Button>
          <Button onClick={() => onAplicar(f)} loading={carregando}>
            <Search className="h-4 w-4" /> Consultar
          </Button>
        </div>
      }
    >
      <form
        className="space-y-4"
        onSubmit={(e) => {
          e.preventDefault();
          onAplicar(f);
        }}
      >
        <Field label="Colaborador">
          <input className="input mb-2" placeholder="Buscar por nome ou matrícula…" value={busca} onChange={(e) => setBusca(e.target.value)} />
          <select className="input" value={f.colaborador} onChange={(e) => setF({ ...f, colaborador: e.target.value })}>
            <option value="">Todos os colaboradores</option>
            {lista.map((c) => <option key={c.id} value={c.id}>{c.nome} · {c.matricula}</option>)}
          </select>
        </Field>
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label="Data inicial">
            <input type="date" className="input" value={f.ini} max={f.fim} onChange={(e) => e.target.value && setF({ ...f, ini: e.target.value })} />
          </Field>
          <Field label="Data final">
            <input type="date" className="input" value={f.fim} min={f.ini} max={hoje} onChange={(e) => e.target.value && setF({ ...f, fim: e.target.value })} />
          </Field>
        </div>
        <div className="flex flex-wrap gap-2 text-xs">
          {atalhos.map(([label, fn]) => (
            <button
              key={label}
              type="button"
              onClick={() => setF(fn())}
              className="rounded-full bg-slate-100 px-3 py-1 font-medium text-slate-600 transition hover:bg-primary-50 hover:text-primary-700"
            >
              {label}
            </button>
          ))}
        </div>
        {erro && (
          <div className="flex items-center gap-2 rounded-xl bg-rose-50 p-3 text-sm text-rose-700 ring-1 ring-rose-200">
            <AlertTriangle className="h-4 w-4 shrink-0" /> {erro}
          </div>
        )}
        <button type="submit" className="hidden" />
      </form>
    </Modal>
  );
}

/** Seção do dia no relatório: tarja com o dia, todas as marcações (previsto × realizado), o resultado
 *  de cada turno e o saldo. Turno que não fechou não soma horas: o previsto dele vira débito. */
function SecaoDia({
  dia,
  podeEditar,
  onExcluir,
}: {
  dia: BancoHorasDia;
  podeEditar: boolean;
  onExcluir: (id: string) => void;
}) {
  const oc = ocorrencia(dia.ocorrencia);
  const nota = notaDoDia(dia);
  const lancamentos = dia.lancamentos ?? [];
  const lancado = lancamentos.reduce((s, l) => s + l.minutos, 0);
  const hoje = dia.ocorrencia === 'em_andamento';
  const turnos = (dia.turnos ?? []).map((t) => ({ ...t, linhas: (dia.linhas ?? []).filter((l) => l.turno === t.turno) }));
  const th = 'border-b border-slate-200 px-3 py-1.5 font-medium';
  const td = 'border-b border-slate-100 px-3 py-1.5';

  return (
    <section className="break-inside-avoid overflow-hidden rounded-lg ring-1 ring-slate-200">
      {/* Tarja do dia */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 bg-slate-700 px-4 py-2 text-white">
        <span className="text-sm font-semibold">
          <span className="capitalize">{formatData(dia.data, { weekday: 'long' })}</span>
          <span className="mx-1.5 text-white/40">·</span>
          <span className="tabular-nums">{dataBR(dia.data)}</span>
        </span>
        <span className="text-xs tabular-nums text-white/70">{dia.horario_previsto ?? 'Sem horário previsto'}</span>
        <span className="ml-auto rounded-full bg-white/15 px-2.5 py-0.5 text-[11px] font-medium">{oc.label}</span>
      </div>

      <table className="w-full border-collapse text-xs">
        <thead>
          <tr className="bg-slate-50 text-left text-[10px] uppercase tracking-wide text-slate-500">
            <th className={th}>Marcação</th>
            <th className={clsx(th, 'text-center')}>Previsto</th>
            <th className={clsx(th, 'text-center')}>Realizado</th>
            <th className={th}>Origem</th>
            <th className={clsx(th, 'text-right')}>Gerou</th>
          </tr>
        </thead>
        <tbody>
          {turnos.length === 0 && lancamentos.length === 0 && (
            <tr>
              <td colSpan={5} className={clsx(td, 'py-3 text-center text-slate-400')}>
                {dia.ocorrencia.startsWith('ausencia:') ? `${oc.label} — sem marcações previstas` : 'Sem marcações'}
              </td>
            </tr>
          )}
          {turnos.map((t) => (
            <Fragment key={t.turno}>
              {t.linhas.map((l) => (
                <tr key={`${l.turno}${l.sentido}${l.hora ?? ''}`}>
                  <td className={td}>
                    <span className="mr-1.5 rounded bg-slate-100 px-1 text-[10px] font-bold text-slate-600">{siglaMarcacao(l.sentido, l.turno)}</span>
                    <span className="text-slate-600">{rotuloMarcacao(l.sentido, l.turno)}</span>
                  </td>
                  <td className={clsx(td, 'text-center tabular-nums text-slate-500')}>{l.previsto ?? '—'}</td>
                  <td className={clsx(td, 'text-center tabular-nums')}>
                    {l.hora ? (
                      <span className="font-semibold text-slate-800">{l.hora}</span>
                    ) : (
                      <span className={clsx('font-medium', hoje ? 'text-slate-400' : 'text-rose-600')}>{hoje ? 'Aguardando' : 'Não realizada'}</span>
                    )}
                  </td>
                  <td className={clsx(td, 'text-slate-500')}>{l.origem ? (ORIGEM_BATIDA[l.origem] ?? l.origem) : '—'}</td>
                  <td className={clsx(td, 'text-right')}>{t.completo ? <Min min={l.gerou_min} /> : <span className="text-slate-300">—</span>}</td>
                </tr>
              ))}
              <tr className={t.completo || hoje ? 'bg-slate-50/60' : 'bg-rose-50/60'}>
                <td colSpan={4} className={clsx(td, 'text-[11px]', t.completo || hoje ? 'text-slate-500' : 'font-medium text-rose-700')}>
                  {t.turno}º turno {t.completo ? 'completo' : hoje ? 'em andamento' : 'não fechado — não computado; o previsto vira débito'}
                  <span className="ml-2 font-normal tabular-nums text-slate-400">
                    previsto {formatMinutos(t.previsto_min)} · trabalhado {formatMinutos(t.trabalhado_min)}
                  </span>
                </td>
                <td className={clsx(td, 'text-right')}>{hoje && !t.completo ? <span className="text-slate-300">—</span> : <Min min={t.gerou_min} />}</td>
              </tr>
            </Fragment>
          ))}
          {lancamentos.map((l) => (
            <tr key={l.id} className="bg-violet-50/50">
              <td colSpan={4} className={clsx(td, 'text-slate-600')} title={l.usuario ? `por ${l.usuario}` : undefined}>
                <span className="font-medium">Lançamento: {TIPOS[l.tipo].label}</span>
                {l.descricao && <span className="ml-1 text-slate-400">· {l.descricao}</span>}
              </td>
              <td className={clsx(td, 'whitespace-nowrap text-right')}>
                <Min min={l.minutos} />
                {podeEditar && l.tipo !== 'conversao' && (
                  <button onClick={() => onExcluir(l.id)} className="ml-1.5 align-middle text-slate-300 hover:text-rose-600 print:hidden" aria-label="Excluir lançamento">
                    <Trash2 className="inline h-3 w-3" />
                  </button>
                )}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="grid grid-cols-2 gap-x-6 gap-y-1 bg-slate-50 px-4 py-2 text-xs sm:grid-cols-4">
        <div className="flex justify-between gap-2"><span className="text-slate-500">Previsto</span><span className="tabular-nums text-slate-700">{formatMinutos(dia.previsto_min)}</span></div>
        <div className="flex justify-between gap-2"><span className="text-slate-500">Trabalhado</span><span className="tabular-nums text-slate-700">{formatMinutos(dia.trabalhado_min)}</span></div>
        <div className="flex justify-between gap-2">
          <span className="font-semibold text-slate-700">Saldo do dia</span>
          <Min min={dia.saldo_dia + lancado} />
        </div>
        <div className="flex justify-between gap-2"><span className="text-slate-500">Acumulado</span><Min min={dia.acumulado} /></div>
        {nota && <p className="col-span-full text-[11px] text-slate-400">{nota}</p>}
      </div>
    </section>
  );
}

export default function BancoHoras() {
  const { pode } = useAuth();
  const toast = useToast();
  const navigate = useNavigate();
  const podeEditar = pode('banco_horas', 'editar');
  const [lista, setLista] = useState<BancoHorasResumo[]>([]);
  const [filtro, setFiltro] = useState<FiltroBH | null>(null);
  const [filtroAberto, setFiltroAberto] = useState(true);
  const [dados, setDados] = useState<BancoHorasDetalhe[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [lancamento, setLancamento] = useState<{ aberto: boolean; colaborador: string | null }>({ aberto: false, colaborador: null });
  const [excluir, setExcluir] = useState<string | null>(null);
  const [gerandoPdf, setGerandoPdf] = useState(false);

  useEffect(() => {
    api<BancoHorasResumo[]>('api_banco_horas_resumo')
      .then(setLista)
      .catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar os colaboradores.'));
  }, []);

  const consultar = useCallback(async (f: FiltroBH) => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(
        await api<BancoHorasDetalhe[]>('api_banco_horas_detalhe', {
          p_ini: f.ini,
          p_fim: f.fim,
          p_colaborador: f.colaborador || null,
        }),
      );
      return true;
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar o banco de horas.');
      return false;
    } finally {
      setCarregando(false);
    }
  }, []);

  const aplicar = async (f: FiltroBH) => {
    setFiltro(f);
    if (await consultar(f)) setFiltroAberto(false);
  };
  const recarregar = () => filtro && consultar(filtro);

  const confirmarExclusao = async () => {
    if (!excluir) return;
    try {
      await api('api_banco_horas_excluir', { p_id: excluir });
      toast('Lançamento excluído.');
      recarregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    } finally {
      setExcluir(null);
    }
  };

  const baixarPdf = async () => {
    if (!dados || !filtro) return;
    setGerandoPdf(true);
    try {
      await gerarPdfBancoHoras(dados, filtro);
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Não foi possível gerar o PDF.', 'erro');
    } finally {
      setGerandoPdf(false);
    }
  };

  const nomeColaborador = lista.find((c) => c.id === filtro?.colaborador)?.nome;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Banco de horas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Relatório dia a dia: previsto e realizado de cada marcação, o resultado de cada turno e o saldo. Turno que não fechou não é computado e o previsto dele vira débito.
          </p>
        </div>
        <div className="flex shrink-0 flex-wrap gap-2 print:hidden">
          {pode('banco_horas_conversao') && (
            <Button variant="secondary" onClick={() => navigate('/movimentos/conversao-banco-horas')}>
              <ArrowRightLeft className="h-4 w-4" /> Converter saldo
            </Button>
          )}
          {podeEditar && (
            <Button variant="secondary" onClick={() => setLancamento({ aberto: true, colaborador: filtro?.colaborador || null })} disabled={!lista.length}>
              <Plus className="h-4 w-4" /> Novo lançamento
            </Button>
          )}
          {dados && dados.length > 0 && (
            <Button variant="secondary" onClick={baixarPdf} loading={gerandoPdf}>
              <FileDown className="h-4 w-4" /> Gerar PDF
            </Button>
          )}
          <Button onClick={() => setFiltroAberto(true)}>
            <Filter className="h-4 w-4" /> Filtrar
          </Button>
        </div>
      </div>

      {filtro && (
        <div className="card flex flex-wrap items-center gap-x-6 gap-y-2 px-5 py-3 text-sm">
          <span className="text-slate-500">
            Colaborador: <strong className="font-medium text-slate-800">{nomeColaborador ?? 'Todos'}</strong>
          </span>
          <span className="text-slate-500">
            Período: <strong className="font-medium tabular-nums text-slate-800">{dataBR(filtro.ini)} a {dataBR(filtro.fim)}</strong>
          </span>
          <button onClick={() => setFiltroAberto(true)} className="ml-auto text-sm font-medium text-primary-600 hover:text-primary-700 print:hidden">
            Alterar filtro
          </button>
        </div>
      )}

      {erro && !filtroAberto && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {!filtro ? (
        <div className="card">
          <EmptyState
            icon={Hourglass}
            titulo="Selecione o período e o colaborador"
            descricao="O banco de horas é mostrado dia a dia para o filtro escolhido."
            acao={<Button onClick={() => setFiltroAberto(true)}><Filter className="h-4 w-4" /> Filtrar</Button>}
          />
        </div>
      ) : dados === null ? (
        <div className="card h-64 animate-pulse" />
      ) : dados.length === 0 ? (
        <div className="card">
          <EmptyState icon={Hourglass} titulo="Nenhum colaborador encontrado" descricao="Não há colaboradores com ponto controlado para o filtro." />
        </div>
      ) : (
        dados.map((c) => (
          <article key={c.id} className="card break-before-page space-y-3 overflow-hidden p-0 print:shadow-none print:ring-0">
            {/* Tarja do colaborador */}
            <header className="flex flex-wrap items-center gap-x-6 gap-y-3 bg-primary-700 px-5 py-3 text-white">
              <div className="min-w-0 flex-1">
                <p className="truncate text-base font-semibold">{c.nome}</p>
                <p className="truncate text-xs text-white/70">
                  Mat. {c.matricula}
                  {c.departamento && ` · ${c.departamento}`}
                  {c.jornada && ` · ${c.jornada}`}
                </p>
              </div>
              {[
                ['Saldo anterior', c.saldo_anterior],
                ['Créditos', c.creditos],
                ['Débitos', c.debitos],
                ['Saldo final', c.saldo_final],
              ].map(([label, v]) => (
                <div key={label as string} className="text-right">
                  <p className="text-[11px] text-white/60">{label}</p>
                  <p className={clsx('font-semibold tabular-nums', label === 'Saldo final' ? 'text-lg' : 'text-sm')}>
                    {formatMinutos(v as number, true)}
                  </p>
                </div>
              ))}
            </header>
            {c.dias.length === 0 ? (
              <p className="px-5 pb-5 text-center text-sm text-slate-400">Sem dias com previsão ou movimento no período.</p>
            ) : (
              <div className="space-y-3 px-4 pb-4">
                {c.dias.map((d) => (
                  <SecaoDia key={d.data} dia={d} podeEditar={podeEditar} onExcluir={setExcluir} />
                ))}
              </div>
            )}
          </article>
        ))
      )}

      <FiltroModal
        aberto={filtroAberto}
        colaboradores={lista}
        inicial={filtro ?? { ini: primeiroDoMes(), fim: toISODate(new Date()), colaborador: '' }}
        carregando={carregando}
        erro={filtroAberto ? erro : null}
        onFechar={() => setFiltroAberto(false)}
        onAplicar={aplicar}
      />
      <LancamentoModal
        aberto={lancamento.aberto}
        colaboradores={lista}
        colaboradorInicial={lancamento.colaborador}
        onFechar={() => setLancamento((l) => ({ ...l, aberto: false }))}
        onSalvo={() => {
          setLancamento({ aberto: false, colaborador: null });
          recarregar();
        }}
      />
      <Modal
        aberto={!!excluir}
        onFechar={() => setExcluir(null)}
        titulo="Excluir lançamento"
        descricao="As horas deste lançamento manual saem do banco de horas."
        rodape={
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setExcluir(null)}>Cancelar</Button>
            <Button onClick={confirmarExclusao}>Excluir</Button>
          </div>
        }
      >
        <p className="text-sm text-slate-600">Lançamentos automáticos vêm das batidas e não podem ser excluídos; para corrigi-los, ajuste as batidas.</p>
      </Modal>
    </div>
  );
}
