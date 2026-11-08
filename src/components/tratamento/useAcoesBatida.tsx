import clsx from 'clsx';
import {
  ArrowDownToLine,
  ArrowUpFromLine,
  Ban,
  CalendarClock,
  History,
  MapPin,
  Pencil,
  Plus,
  RotateCcw,
  Shuffle,
  Trash2,
} from 'lucide-react';
import { useCallback, useEffect, useState, type MouseEvent } from 'react';
import { Button } from '@/components/ui/Button';
import type { ItemMenu, MenuAberto } from '@/components/ui/ContextMenu';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { formatData, parseISODate, toISODate } from '@/lib/format';
import { linkMapa } from '@/lib/geo';
import { CLASSIFICACOES, rotuloMarcacao } from '@/lib/ponto';
import { api } from '@/lib/supabase';
import type { BatidaTratamento, HistoricoBatida, Sentido, TratamentoAux } from '@/lib/types';
import { STATUS_BATIDA } from './BatidaChip';

type ModalAberto =
  | { tipo: 'incluir'; colaboradorId: string | null; data: string }
  | { tipo: 'editar'; batida: BatidaTratamento }
  | { tipo: 'desconsiderar'; batida: BatidaTratamento }
  | { tipo: 'excluir'; batida: BatidaTratamento }
  | { tipo: 'data_referencia'; batida: BatidaTratamento }
  | { tipo: 'historico'; batida: BatidaTratamento }
  | null;

const dataBR = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });
const somarDias = (iso: string, n: number) => {
  const d = parseISODate(iso);
  d.setDate(d.getDate() + n);
  return toISODate(d);
};

const ACOES_HISTORICO: Record<string, string> = {
  inclusao: 'Incluída',
  alteracao: 'Editada',
  exclusao: 'Excluída',
  desconsideracao: 'Desconsiderada',
  reconsideracao: 'Reconsiderada',
  sentido: 'Sentido declarado',
  data_referencia: 'Data de referência alterada',
};

/**
 * Ações de tratamento de batidas, compartilhadas pelas telas de Tratamento e de Consulta.
 * Regras (validadas também no banco):
 *   Incluída → editar, apagar · Original → desconsiderar · ambas → sentido e data de referência.
 */
export function useAcoesBatida(aux: TratamentoAux | null, onAlterado: () => void) {
  const toast = useToast();
  const [menu, setMenu] = useState<MenuAberto | null>(null);
  const [modal, setModal] = useState<ModalAberto>(null);
  const podeEditar = !!aux?.pode_editar;

  const executar = useCallback(
    async (fn: string, args: Record<string, unknown>, sucesso: string, avisarErro = true) => {
      try {
        await api(fn, args);
        toast(sucesso);
        onAlterado();
        return null;
      } catch (e) {
        const msg = e instanceof Error ? e.message : 'Não foi possível concluir a ação.';
        if (avisarErro) toast(msg, 'erro');
        return msg;
      }
    },
    [toast, onAlterado],
  );

  const nomeColab = (id: string) => aux?.colaboradores.find((c) => c.id === id)?.nome ?? '';

  const abrirMenuBatida = (e: MouseEvent, b: BatidaTratamento) => {
    const itens: ItemMenu[] = [];
    if (podeEditar) {
      if (b.status === 'incluida') {
        itens.push(
          { label: 'Editar batida', icon: Pencil, onClick: () => setModal({ tipo: 'editar', batida: b }) },
          { label: 'Apagar batida', icon: Trash2, perigo: true, onClick: () => setModal({ tipo: 'excluir', batida: b }) },
        );
      } else if (b.status === 'original') {
        itens.push({ label: 'Desconsiderar…', icon: Ban, perigo: true, onClick: () => setModal({ tipo: 'desconsiderar', batida: b }) });
      } else {
        itens.push({
          label: 'Reconsiderar batida',
          icon: RotateCcw,
          onClick: () => executar('api_batida_reconsiderar', { p_id: b.id }, 'Batida reconsiderada.'),
        });
      }
      if (b.status !== 'desconsiderada') {
        const classificar = (s: Sentido | null, t: number | null) =>
          executar('api_batida_classificar', { p_id: b.id, p_sentido: s, p_turno: t },
            s ? `Batida classificada como ${rotuloMarcacao(s, t).toLowerCase()}.` : 'Classificação automática restaurada.');
        const declarada = !!(b.sentido_declarado || b.turno_declarado);
        itens.push(
          { tipo: 'separador' },
          { tipo: 'titulo', label: 'Classificar batida' },
          ...CLASSIFICACOES.map((c) => ({
            label: rotuloMarcacao(c.sentido, c.turno),
            icon: c.sentido === 'E' ? ArrowDownToLine : ArrowUpFromLine,
            marcado: declarada && b.sentido === c.sentido && b.turno === c.turno,
            onClick: () => classificar(c.sentido, c.turno),
          })),
          { label: 'Automático (pela sequência)', icon: Shuffle, marcado: !declarada, onClick: () => classificar(null, null) },
          { tipo: 'separador' },
          { label: 'Alterar data de referência…', icon: CalendarClock, onClick: () => setModal({ tipo: 'data_referencia', batida: b }) },
        );
      }
      itens.push({ tipo: 'separador' });
    }
    if (b.latitude != null && b.longitude != null) {
      const { latitude, longitude } = b;
      itens.push({ label: 'Ver localização no mapa', icon: MapPin, onClick: () => window.open(linkMapa(latitude, longitude), '_blank', 'noopener') });
    }
    itens.push({ label: 'Histórico de ajustes', icon: History, onClick: () => setModal({ tipo: 'historico', batida: b }) });
    setMenu({
      x: e.clientX,
      y: e.clientY,
      titulo: `${b.hora} · ${dataBR(b.data)} · ${STATUS_BATIDA[b.status].label}`,
      itens,
    });
  };

  const abrirMenuDia = (e: MouseEvent, colaboradorId: string, data: string) => {
    e.preventDefault();
    if (!podeEditar) return;
    setMenu({
      x: e.clientX,
      y: e.clientY,
      titulo: `${nomeColab(colaboradorId)} · ${formatData(data, { weekday: 'short', day: '2-digit', month: '2-digit' })}`,
      itens: [{ label: 'Incluir batida…', icon: Plus, onClick: () => setModal({ tipo: 'incluir', colaboradorId, data }) }],
    });
  };

  const incluir = (colaboradorId: string | null = null, data = toISODate(new Date())) =>
    setModal({ tipo: 'incluir', colaboradorId, data });

  const fechar = () => setModal(null);
  const concluir = fechar;

  const modais = (
    <>
      {(modal?.tipo === 'incluir' || modal?.tipo === 'editar') && aux && (
        <BatidaFormModal
          aux={aux}
          modo={modal.tipo}
          batida={modal.tipo === 'editar' ? modal.batida : null}
          colaboradorId={modal.tipo === 'incluir' ? modal.colaboradorId : modal.batida.colaborador_id}
          data={modal.tipo === 'incluir' ? modal.data : modal.batida.data}
          onFechar={fechar}
          onSalvar={async (args) => {
            const erro = modal.tipo === 'incluir'
              ? await executar('api_batida_incluir', args, 'Batida incluída.', false)
              : await executar('api_batida_editar', { p_id: modal.batida.id, ...args }, 'Batida alterada.', false);
            if (!erro) concluir();
            return erro;
          }}
        />
      )}
      {modal?.tipo === 'desconsiderar' && aux && (
        <DesconsiderarModal
          aux={aux}
          batida={modal.batida}
          nome={nomeColab(modal.batida.colaborador_id)}
          onFechar={fechar}
          onConfirmar={async (motivo, obs) => {
            const erro = await executar('api_batida_desconsiderar',
              { p_id: modal.batida.id, p_motivo: motivo, p_observacao: obs }, 'Batida desconsiderada.', false);
            if (!erro) concluir();
            return erro;
          }}
        />
      )}
      {modal?.tipo === 'excluir' && (
        <ExcluirModal
          batida={modal.batida}
          nome={nomeColab(modal.batida.colaborador_id)}
          onFechar={fechar}
          onConfirmar={async (obs) => {
            const erro = await executar('api_batida_excluir', { p_id: modal.batida.id, p_observacao: obs }, 'Batida apagada.', false);
            if (!erro) concluir();
            return erro;
          }}
        />
      )}
      {modal?.tipo === 'data_referencia' && (
        <DataReferenciaModal
          batida={modal.batida}
          onFechar={fechar}
          onConfirmar={async (data) => {
            const erro = await executar('api_batida_data_referencia', { p_id: modal.batida.id, p_data: data },
              `Batida atribuída ao dia ${dataBR(data)}.`, false);
            if (!erro) concluir();
            return erro;
          }}
        />
      )}
      {modal?.tipo === 'historico' && <HistoricoModal batida={modal.batida} onFechar={fechar} />}
    </>
  );

  const fecharMenu = useCallback(() => setMenu(null), []);

  return { menu, fecharMenu, abrirMenuBatida, abrirMenuDia, incluir, modais };
}

// ---------------------------------------------------------------------------
// Modais
// ---------------------------------------------------------------------------
function BatidaFormModal({
  aux,
  modo,
  batida,
  colaboradorId,
  data,
  onFechar,
  onSalvar,
}: {
  aux: TratamentoAux;
  modo: 'incluir' | 'editar';
  batida: BatidaTratamento | null;
  colaboradorId: string | null;
  data: string;
  onFechar: () => void;
  onSalvar: (args: Record<string, unknown>) => Promise<string | null>;
}) {
  const [colab, setColab] = useState(colaboradorId ?? '');
  const [dia, setDia] = useState(data);
  const [hora, setHora] = useState(batida?.hora ?? '');
  const [motivo, setMotivo] = useState(batida?.motivo_id ?? '');
  const [obs, setObs] = useState(batida?.observacao ?? '');
  const [ref, setRef] = useState<'mesmo' | 'anterior'>('mesmo');
  const [classificacao, setClassificacao] = useState(''); // '' = automático; senão "E1", "S2"…
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const motivos = aux.motivos.filter((m) => m.aplicacao !== 'desconsideracao');

  const salvar = async () => {
    if (!colab) return setErro('Selecione o empregado.');
    if (!dia || !hora) return setErro('Informe a data e a hora.');
    if (!motivo) return setErro('Selecione o motivo da inclusão.');
    setErro(null);
    setSalvando(true);
    const args: Record<string, unknown> =
      modo === 'incluir'
        ? {
            p_colaborador: colab, p_data: dia, p_hora: hora, p_motivo: motivo, p_observacao: obs || null,
            p_data_referencia: ref === 'anterior' ? somarDias(dia, -1) : null,
            p_sentido: classificacao ? classificacao[0] : null,
            p_turno: classificacao ? Number(classificacao.slice(1)) : null,
          }
        : { p_data: dia, p_hora: hora, p_motivo: motivo, p_observacao: obs || null };
    const falha = await onSalvar(args);
    setSalvando(false);
    if (falha) setErro(falha);
  };

  return (
    <Modal
      aberto
      onFechar={onFechar}
      titulo={modo === 'incluir' ? 'Incluir batida' : 'Editar batida incluída'}
      descricao={modo === 'incluir' ? 'A batida fica marcada como incluída (azul) e registrada na auditoria.' : 'Somente batidas incluídas podem ser editadas.'}
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button onClick={salvar} loading={salvando}>{modo === 'incluir' ? 'Incluir' : 'Salvar'}</Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Empregado" obrigatorio className="sm:col-span-2">
          <select className="input" value={colab} onChange={(e) => setColab(e.target.value)} disabled={modo === 'editar' || !!colaboradorId}>
            <option value="">Selecione…</option>
            {aux.colaboradores.map((c) => <option key={c.id} value={c.id}>{c.nome} · {c.matricula}</option>)}
          </select>
        </Field>
        <Field label="Data" obrigatorio>
          <input type="date" className="input" value={dia} max={toISODate(new Date())} onChange={(e) => setDia(e.target.value)} />
        </Field>
        <Field label="Hora" obrigatorio>
          <input type="time" className="input tabular-nums" value={hora} onChange={(e) => setHora(e.target.value)} autoFocus />
        </Field>
        <Field label="Motivo da inclusão" obrigatorio className="sm:col-span-2">
          <select className="input" value={motivo} onChange={(e) => setMotivo(e.target.value)}>
            <option value="">Selecione…</option>
            {motivos.map((m) => <option key={m.id} value={m.id}>{m.descricao}</option>)}
          </select>
        </Field>
        <Field label="Observação" className="sm:col-span-2">
          <textarea className="input h-20 py-2" value={obs} onChange={(e) => setObs(e.target.value)} placeholder="Opcional" />
        </Field>
        {modo === 'incluir' && (
          <details className="rounded-xl p-3 ring-1 ring-slate-200/80 sm:col-span-2">
            <summary className="cursor-pointer text-xs font-medium text-slate-600">Ajustes avançados (classificação e dia de referência)</summary>
            <div className="mt-3 grid gap-4 sm:grid-cols-2">
              <Field label="Classificação">
                <select className="input" value={classificacao} onChange={(e) => setClassificacao(e.target.value)}>
                  <option value="">Automática (pela sequência)</option>
                  {CLASSIFICACOES.map((c) => (
                    <option key={c.sentido + c.turno} value={c.sentido + c.turno}>{rotuloMarcacao(c.sentido, c.turno)}</option>
                  ))}
                </select>
              </Field>
              <Field label="Pertence ao dia" dica="Use “dia anterior” para a saída de um turno que virou a noite.">
                <select className="input" value={ref} onChange={(e) => setRef(e.target.value as 'mesmo' | 'anterior')}>
                  <option value="mesmo">Dia da batida</option>
                  <option value="anterior">Dia anterior</option>
                </select>
              </Field>
            </div>
          </details>
        )}
      </div>
    </Modal>
  );
}

function ResumoBatida({ batida, nome }: { batida: BatidaTratamento; nome?: string }) {
  const st = STATUS_BATIDA[batida.status];
  return (
    <div className="mb-4 flex items-center gap-3 rounded-xl bg-slate-50 p-3 text-sm">
      <span className={clsx('h-2.5 w-2.5 rounded-full', st.ponto)} />
      <div className="min-w-0">
        {nome && <p className="truncate font-medium text-slate-800">{nome}</p>}
        <p className="text-slate-600">
          <strong className={clsx('tabular-nums', st.texto)}>{batida.hora}</strong> de {dataBR(batida.data)} · {st.label}
        </p>
      </div>
    </div>
  );
}

function DesconsiderarModal({
  aux,
  batida,
  nome,
  onFechar,
  onConfirmar,
}: {
  aux: TratamentoAux;
  batida: BatidaTratamento;
  nome: string;
  onFechar: () => void;
  onConfirmar: (motivo: string, obs: string | null) => Promise<string | null>;
}) {
  const [motivo, setMotivo] = useState('');
  const [obs, setObs] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  const confirmar = async () => {
    if (!motivo) return setErro('Selecione o motivo da desconsideração.');
    setSalvando(true);
    const falha = await onConfirmar(motivo, obs || null);
    setSalvando(false);
    if (falha) setErro(falha);
  };

  return (
    <Modal
      aberto
      onFechar={onFechar}
      titulo="Desconsiderar batida"
      descricao="A batida original continua gravada, mas deixa de contar na apuração (fica em vermelho)."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button variant="primary" className="bg-rose-600 hover:bg-rose-700" onClick={confirmar} loading={salvando}>Desconsiderar</Button>
        </>
      }
    >
      <ResumoBatida batida={batida} nome={nome} />
      <AlertaErro mensagem={erro} />
      <div className="space-y-4">
        <Field label="Motivo" obrigatorio>
          <select className="input" value={motivo} onChange={(e) => setMotivo(e.target.value)} autoFocus>
            <option value="">Selecione…</option>
            {aux.motivos.filter((m) => m.aplicacao !== 'inclusao').map((m) => <option key={m.id} value={m.id}>{m.descricao}</option>)}
          </select>
        </Field>
        <Field label="Observação">
          <textarea className="input h-20 py-2" value={obs} onChange={(e) => setObs(e.target.value)} placeholder="Opcional" />
        </Field>
      </div>
    </Modal>
  );
}

function ExcluirModal({
  batida,
  nome,
  onFechar,
  onConfirmar,
}: {
  batida: BatidaTratamento;
  nome: string;
  onFechar: () => void;
  onConfirmar: (obs: string | null) => Promise<string | null>;
}) {
  const [obs, setObs] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  return (
    <Modal
      aberto
      onFechar={onFechar}
      titulo="Apagar batida incluída"
      descricao="A batida sai da apuração. Uma cópia fica registrada na auditoria."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button
            className="bg-rose-600 hover:bg-rose-700"
            loading={salvando}
            onClick={async () => {
              setSalvando(true);
              const falha = await onConfirmar(obs || null);
              setSalvando(false);
              if (falha) setErro(falha);
            }}
          >
            Apagar
          </Button>
        </>
      }
    >
      <ResumoBatida batida={batida} nome={nome} />
      <AlertaErro mensagem={erro} />
      <Field label="Observação">
        <textarea className="input h-20 py-2" value={obs} onChange={(e) => setObs(e.target.value)} placeholder="Opcional" />
      </Field>
    </Modal>
  );
}

function DataReferenciaModal({
  batida,
  onFechar,
  onConfirmar,
}: {
  batida: BatidaTratamento;
  onFechar: () => void;
  onConfirmar: (data: string) => Promise<string | null>;
}) {
  const opcoes = [
    { data: somarDias(batida.data, -1), label: 'Dia anterior', dica: 'Saída de um turno que começou na véspera' },
    { data: batida.data, label: 'Dia da batida', dica: 'Padrão' },
    { data: somarDias(batida.data, 1), label: 'Dia seguinte', dica: 'Entrada antecipada do turno do dia seguinte' },
  ];
  const [sel, setSel] = useState(batida.data_referencia);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  return (
    <Modal
      aberto
      onFechar={onFechar}
      titulo="Alterar data de referência"
      descricao="Define a qual dia de trabalho a batida pertence na apuração."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button
            loading={salvando}
            disabled={sel === batida.data_referencia}
            onClick={async () => {
              setSalvando(true);
              const falha = await onConfirmar(sel);
              setSalvando(false);
              if (falha) setErro(falha);
            }}
          >
            Aplicar
          </Button>
        </>
      }
    >
      <ResumoBatida batida={batida} />
      <AlertaErro mensagem={erro} />
      <div className="space-y-2">
        {opcoes.map((o) => (
          <label
            key={o.data}
            className={clsx(
              'flex cursor-pointer items-center gap-3 rounded-xl p-3 ring-1 ring-inset transition',
              sel === o.data ? 'bg-primary-50 ring-primary-300' : 'ring-slate-200 hover:bg-slate-50',
            )}
          >
            <input type="radio" name="ref" checked={sel === o.data} onChange={() => setSel(o.data)} className="accent-primary-700" />
            <div className="flex-1">
              <p className="text-sm font-medium text-slate-800">
                {o.label} · <span className="capitalize">{formatData(o.data, { weekday: 'short', day: '2-digit', month: '2-digit' })}</span>
              </p>
              <p className="text-xs text-slate-500">{o.dica}</p>
            </div>
          </label>
        ))}
      </div>
    </Modal>
  );
}

function HistoricoModal({ batida, onFechar }: { batida: BatidaTratamento; onFechar: () => void }) {
  const [itens, setItens] = useState<HistoricoBatida[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);

  useEffect(() => {
    api<HistoricoBatida[]>('api_batida_historico', { p_id: batida.id })
      .then(setItens)
      .catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar.'));
  }, [batida.id]);

  const hora = (s: string | null) =>
    s ? new Date(s).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' }) : '—';

  return (
    <Modal aberto onFechar={onFechar} titulo="Histórico de ajustes" rodape={<Button variant="secondary" onClick={onFechar}>Fechar</Button>}>
      <ResumoBatida batida={batida} />
      <AlertaErro mensagem={erro} />
      {!itens ? (
        <div className="h-24 animate-pulse rounded-xl bg-slate-50" />
      ) : itens.length === 0 ? (
        <p className="py-6 text-center text-sm text-slate-400">
          Nenhum ajuste registrado. {batida.status === 'original' && 'Esta é a batida original, como foi capturada.'}
        </p>
      ) : (
        <ol className="relative space-y-4 border-l border-slate-200 pl-5">
          {itens.map((h, i) => (
            <li key={i} className="relative">
              <span className="absolute -left-[25px] top-1.5 h-2.5 w-2.5 rounded-full bg-primary-600 ring-4 ring-white" />
              <p className="text-sm font-medium text-slate-800">{ACOES_HISTORICO[h.acao] ?? h.acao}</p>
              <p className="text-xs text-slate-500">
                {h.acao === 'alteracao' && `${hora(h.valor_anterior)} → ${hora(h.valor_novo)} · `}
                {h.acao === 'sentido' && `${String(h.dados?.de ?? 'automático')} → ${String(h.dados?.para ?? 'automático')} · `}
                {h.acao === 'data_referencia' && `${dataBR(String(h.dados?.de))} → ${dataBR(String(h.dados?.para))} · `}
                {h.motivo && `${h.motivo} · `}
                {h.justificativa}
              </p>
              <p className="text-[11px] text-slate-400">
                {hora(h.created_at)}{h.usuario && ` · por ${h.usuario}`}
              </p>
            </li>
          ))}
        </ol>
      )}
    </Modal>
  );
}
