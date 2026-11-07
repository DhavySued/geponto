import clsx from 'clsx';
import { AlertTriangle, ArrowRightLeft, History, Undo2 } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, formatMinutos, horasParaMinutos, toISODate } from '@/lib/format';
import { api } from '@/lib/supabase';
import type { ConversaoBH, ConversaoBHHistorico } from '@/lib/types';

type Converter = 'positivo' | 'negativo' | 'ambos';

const OPCOES: Record<Converter, { label: string; descricao: string }> = {
  positivo: { label: 'Saldo positivo', descricao: 'Horas a favor do colaborador viram horas extras pagas na folha' },
  negativo: { label: 'Saldo negativo', descricao: 'Horas devidas pelo colaborador viram desconto na folha' },
  ambos: { label: 'Positivo e negativo', descricao: 'Paga quem tem crédito e desconta quem tem débito' },
};

const dataBR = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });
const primeiroDoMes = () => {
  const d = new Date();
  return toISODate(new Date(d.getFullYear(), d.getMonth(), 1));
};

function Horas({ min }: { min: number }) {
  if (min === 0) return <span className="tabular-nums text-slate-300">0h00</span>;
  return (
    <span className={clsx('font-semibold tabular-nums', min > 0 ? 'text-primary-600' : 'text-accent-700')}>
      {formatMinutos(min, true)}
    </span>
  );
}

export default function ConversaoBancoHoras() {
  const { pode } = useAuth();
  const toast = useToast();
  const podeEditar = pode('banco_horas_conversao', 'editar');

  const [data, setData] = useState(toISODate(new Date()));
  const [converter, setConverter] = useState<Converter>('positivo');
  const [limite, setLimite] = useState('');
  const [descricao, setDescricao] = useState('');
  const [previa, setPrevia] = useState<ConversaoBH | null>(null);
  const [selecionados, setSelecionados] = useState<Set<string>>(new Set());
  const [erro, setErro] = useState<string | null>(null);
  const [confirmar, setConfirmar] = useState(false);
  const [gravando, setGravando] = useState(false);

  const [hist, setHist] = useState({ ini: primeiroDoMes(), fim: toISODate(new Date()) });
  const [historico, setHistorico] = useState<ConversaoBHHistorico[] | null>(null);
  const [estornar, setEstornar] = useState<ConversaoBHHistorico | null>(null);

  const limiteMin = limite.trim() ? horasParaMinutos(limite) : null;
  const limiteInvalido = limite.trim() !== '' && !limiteMin;

  const simular = useCallback(async () => {
    if (limiteInvalido) return;
    try {
      setErro(null);
      const r = await api<ConversaoBH>('api_banco_horas_converter', {
        p_data: data,
        p_converter: converter,
        p_limite_min: limiteMin,
        p_simular: true,
      });
      setPrevia(r);
      setSelecionados(new Set(r.itens.filter((i) => i.convertido !== 0).map((i) => i.id)));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao calcular a prévia.');
    }
  }, [data, converter, limiteMin, limiteInvalido]);

  const carregarHistorico = useCallback(async () => {
    try {
      setHistorico(await api<ConversaoBHHistorico[]>('api_banco_horas_conversoes', { p_ini: hist.ini, p_fim: hist.fim }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar o histórico.');
    }
  }, [hist]);

  useEffect(() => {
    simular();
  }, [simular]);

  useEffect(() => {
    carregarHistorico();
  }, [carregarHistorico]);

  const itens = previa?.itens ?? [];
  const totais = useMemo(() => {
    const sel = itens.filter((i) => selecionados.has(i.id));
    return {
      qtd: sel.filter((i) => i.convertido !== 0).length,
      pago: sel.reduce((s, i) => s + Math.max(i.convertido, 0), 0),
      descontado: sel.reduce((s, i) => s + Math.max(-i.convertido, 0), 0),
    };
  }, [itens, selecionados]);

  const conversiveis = itens.filter((i) => i.convertido !== 0);
  const todosMarcados = conversiveis.length > 0 && conversiveis.every((i) => selecionados.has(i.id));
  const alternar = (id: string) =>
    setSelecionados((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  const gravar = async () => {
    setGravando(true);
    try {
      const r = await api<ConversaoBH>('api_banco_horas_converter', {
        p_data: data,
        p_converter: converter,
        p_colaboradores: [...selecionados],
        p_limite_min: limiteMin,
        p_descricao: descricao || null,
        p_simular: false,
      });
      const partes = [
        r.pago_min ? `${formatMinutos(r.pago_min)} em pagamento` : null,
        r.descontado_min ? `${formatMinutos(r.descontado_min)} em desconto` : null,
      ].filter(Boolean);
      toast(`Saldo convertido: ${partes.join(' e ')}.`);
      setConfirmar(false);
      setDescricao('');
      simular();
      carregarHistorico();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao converter.');
      setConfirmar(false);
    } finally {
      setGravando(false);
    }
  };

  const confirmarEstorno = async () => {
    if (!estornar) return;
    try {
      await api('api_banco_horas_conversao_estornar', { p_id: estornar.id });
      toast('Conversão estornada. O saldo voltou ao banco de horas.');
      setEstornar(null);
      simular();
      carregarHistorico();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao estornar.');
      setEstornar(null);
    }
  };

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Conversão do banco de horas</h2>
        <p className="mt-1 text-sm text-slate-500">
          Converte o saldo em pagamento de horas extras ou em desconto na folha. O valor sai do banco de horas e vai para os
          eventos “Banco de horas convertido” em Totais e Exportação p/ Folha.
        </p>
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4 shrink-0" /> {erro}
        </div>
      )}

      <section className="card space-y-5 p-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Field label="Saldo até a data" dica="Data do lançamento da conversão">
            <input type="date" className="input" value={data} max={toISODate(new Date())} onChange={(e) => e.target.value && setData(e.target.value)} />
          </Field>
          <Field label="O que converter" grupo className="sm:col-span-2">
            <div className="grid grid-cols-3 gap-2">
              {(Object.keys(OPCOES) as Converter[]).map((o) => (
                <button
                  key={o}
                  type="button"
                  onClick={() => setConverter(o)}
                  className={clsx(
                    'rounded-xl px-3 py-2 text-sm font-medium ring-1 ring-inset transition',
                    converter === o ? 'bg-primary-700 text-white ring-primary-700' : 'text-slate-600 ring-slate-200 hover:bg-slate-50',
                  )}
                >
                  {OPCOES[o].label}
                </button>
              ))}
            </div>
            <span className="mt-1.5 block text-[11px] text-slate-400">{OPCOES[converter].descricao}</span>
          </Field>
          <Field label="Limite por colaborador" dica={limiteInvalido ? 'Use o formato HH:MM' : 'Vazio = converte o saldo inteiro'}>
            <input className={clsx('input', limiteInvalido && 'ring-rose-300')} placeholder="Ex.: 10:00" value={limite} onChange={(e) => setLimite(e.target.value)} />
          </Field>
        </div>

        {previa === null ? (
          <div className="h-40 animate-pulse rounded-xl bg-slate-50" />
        ) : itens.length === 0 ? (
          <EmptyState icon={ArrowRightLeft} titulo="Nenhum saldo no banco de horas" descricao="Ninguém tem saldo até a data escolhida." compacto />
        ) : (
          <div className="overflow-x-auto rounded-xl ring-1 ring-slate-100">
            <table className="w-full min-w-[640px] text-sm">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="w-10 px-4 py-2.5">
                    <input
                      type="checkbox"
                      aria-label="Marcar todos"
                      checked={todosMarcados}
                      disabled={!podeEditar || conversiveis.length === 0}
                      onChange={() => setSelecionados(todosMarcados ? new Set() : new Set(conversiveis.map((i) => i.id)))}
                    />
                  </th>
                  <th className="px-4 py-2.5 font-medium">Colaborador</th>
                  <th className="px-4 py-2.5 text-right font-medium">Saldo atual</th>
                  <th className="px-4 py-2.5 text-right font-medium">Converter</th>
                  <th className="px-4 py-2.5 font-medium">Vai para a folha como</th>
                  <th className="px-4 py-2.5 text-right font-medium">Saldo após</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {itens.map((i) => {
                  const marcado = selecionados.has(i.id) && i.convertido !== 0;
                  return (
                    <tr key={i.id} className={clsx(!marcado && 'text-slate-400')}>
                      <td className="px-4 py-2.5">
                        <input
                          type="checkbox"
                          aria-label={`Converter ${i.nome}`}
                          checked={marcado}
                          disabled={!podeEditar || i.convertido === 0}
                          onChange={() => alternar(i.id)}
                        />
                      </td>
                      <td className="px-4 py-2.5">
                        <p className={clsx('font-medium', marcado ? 'text-slate-800' : 'text-slate-500')}>{i.nome}</p>
                        <p className="text-xs text-slate-400">Mat. {i.matricula}</p>
                      </td>
                      <td className="px-4 py-2.5 text-right"><Horas min={i.saldo} /></td>
                      <td className="px-4 py-2.5 text-right tabular-nums">
                        {i.convertido === 0 ? <span className="text-slate-300">—</span> : formatMinutos(Math.abs(i.convertido))}
                      </td>
                      <td className="px-4 py-2.5">
                        {i.convertido > 0 ? (
                          <Badge tone="violet" dot={false}>Pagamento de horas extras</Badge>
                        ) : i.convertido < 0 ? (
                          <Badge tone="orange" dot={false}>Desconto</Badge>
                        ) : (
                          <span className="text-xs text-slate-300">Fora desta conversão</span>
                        )}
                      </td>
                      <td className="px-4 py-2.5 text-right"><Horas min={marcado ? i.saldo_final : i.saldo} /></td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}

        {podeEditar && (
          <div className="flex flex-col gap-4 border-t border-slate-100 pt-4 lg:flex-row lg:items-end">
            <Field label="Justificativa" className="flex-1">
              <input
                className="input"
                placeholder="Ex.: Pagamento do banco de horas de outubro"
                value={descricao}
                onChange={(e) => setDescricao(e.target.value)}
              />
            </Field>
            <div className="flex items-center gap-4">
              <div className="text-right text-xs text-slate-500">
                {totais.pago > 0 && <p>Pagamento: <strong className="tabular-nums text-violet-700">{formatMinutos(totais.pago)}</strong></p>}
                {totais.descontado > 0 && <p>Desconto: <strong className="tabular-nums text-accent-700">{formatMinutos(totais.descontado)}</strong></p>}
              </div>
              <Button onClick={() => setConfirmar(true)} disabled={totais.qtd === 0 || limiteInvalido}>
                <ArrowRightLeft className="h-4 w-4" /> Converter {totais.qtd > 0 && `(${totais.qtd})`}
              </Button>
            </div>
          </div>
        )}
      </section>

      <section className="card overflow-hidden">
        <header className="flex flex-wrap items-end gap-4 border-b border-slate-100 px-5 py-4">
          <div className="flex-1">
            <h3 className="flex items-center gap-2 text-[15px] font-semibold text-slate-900">
              <History className="h-4 w-4 text-slate-400" /> Conversões realizadas
            </h3>
            <p className="text-xs text-slate-500">Estornar devolve as horas ao banco de horas do colaborador.</p>
          </div>
          <Field label="De">
            <input type="date" className="input h-9" value={hist.ini} max={hist.fim} onChange={(e) => e.target.value && setHist((h) => ({ ...h, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input h-9" value={hist.fim} min={hist.ini} onChange={(e) => e.target.value && setHist((h) => ({ ...h, fim: e.target.value }))} />
          </Field>
        </header>
        {historico === null ? (
          <div className="h-32 animate-pulse" />
        ) : historico.length === 0 ? (
          <EmptyState icon={History} titulo="Nenhuma conversão no período" compacto />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[720px] text-sm">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="px-5 py-2.5 font-medium">Data</th>
                  <th className="px-5 py-2.5 font-medium">Colaborador</th>
                  <th className="px-5 py-2.5 text-right font-medium">Horas</th>
                  <th className="px-5 py-2.5 font-medium">Tipo</th>
                  <th className="px-5 py-2.5 font-medium">Justificativa</th>
                  <th className="w-24 px-5 py-2.5" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {historico.map((h) => (
                  <tr key={h.id}>
                    <td className="whitespace-nowrap px-5 py-2.5 tabular-nums text-slate-600">{dataBR(h.data)}</td>
                    <td className="px-5 py-2.5">
                      <p className="font-medium text-slate-800">{h.nome}</p>
                      <p className="text-xs text-slate-400">Mat. {h.matricula}</p>
                    </td>
                    <td className="px-5 py-2.5 text-right tabular-nums text-slate-700">{formatMinutos(Math.abs(h.convertido))}</td>
                    <td className="px-5 py-2.5">
                      {h.convertido > 0 ? <Badge tone="violet" dot={false}>Pagamento</Badge> : <Badge tone="orange" dot={false}>Desconto</Badge>}
                    </td>
                    <td className="px-5 py-2.5 text-xs text-slate-500">
                      {h.descricao}
                      {h.usuario && <p className="text-slate-400">por {h.usuario}</p>}
                    </td>
                    <td className="px-5 py-2.5 text-right">
                      {podeEditar && (
                        <button onClick={() => setEstornar(h)} className="inline-flex items-center gap-1 text-xs font-medium text-rose-600 hover:underline">
                          <Undo2 className="h-3.5 w-3.5" /> Estornar
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <Modal
        aberto={confirmar}
        onFechar={() => setConfirmar(false)}
        titulo="Confirmar conversão"
        descricao={`Saldo até ${dataBR(data)} de ${totais.qtd} colaborador(es).`}
        rodape={
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setConfirmar(false)}>Cancelar</Button>
            <Button onClick={gravar} loading={gravando}>Converter</Button>
          </div>
        }
      >
        <ul className="space-y-2 text-sm text-slate-600">
          {totais.pago > 0 && (
            <li><strong className="tabular-nums text-violet-700">{formatMinutos(totais.pago)}</strong> saem do banco e serão pagas como horas extras.</li>
          )}
          {totais.descontado > 0 && (
            <li><strong className="tabular-nums text-accent-700">{formatMinutos(totais.descontado)}</strong> devidas serão descontadas na folha e o débito sai do banco.</li>
          )}
          <li className="text-xs text-slate-400">Se precisar desfazer, use “Estornar” no histórico.</li>
        </ul>
      </Modal>

      <Modal
        aberto={!!estornar}
        onFechar={() => setEstornar(null)}
        titulo="Estornar conversão"
        descricao={estornar ? `${estornar.nome} · ${dataBR(estornar.data)}` : undefined}
        rodape={
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setEstornar(null)}>Cancelar</Button>
            <Button onClick={confirmarEstorno}>Estornar</Button>
          </div>
        }
      >
        <p className="text-sm text-slate-600">
          {estornar && formatMinutos(Math.abs(estornar.convertido))} voltam para o banco de horas e deixam de ir para a folha.
        </p>
      </Modal>
    </div>
  );
}
