import { useEffect, useMemo, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { api } from '@/lib/api';
import { toISODate } from '@/lib/format';
import type { TratamentoAux } from '@/lib/types';

interface Resultado {
  dias: number;
  batidas: number;
  simulado: boolean;
  pulados: Record<'com_batidas' | 'sem_previsao' | 'feriado' | 'ausencia' | 'fechado' | 'futuro', number>;
}

const PULOS: Record<keyof Resultado['pulados'], string> = {
  com_batidas: 'já tinham batidas',
  sem_previsao: 'folga ou sem jornada',
  feriado: 'feriado',
  ausencia: 'ocorrência/afastamento',
  fechado: 'período fechado',
  futuro: 'fora do controle ou ainda não encerrados',
};

const ontem = () => { const d = new Date(); d.setDate(d.getDate() - 1); return toISODate(d); };

/**
 * Inclusão de batidas em lote: o sistema lança as marcações previstas da jornada (ou da escala) nos dias
 * sem nenhuma batida, variando cada horário aleatoriamente em até X minutos.
 */
export function BatidasLoteModal({ aberto, aux, onFechar, onSalvo }: {
  aberto: boolean;
  aux: TratamentoAux;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState({ ini: ontem(), fim: ontem(), variacao: 5, motivo: '', observacao: '', colaboradores: [] as string[] });
  const [busca, setBusca] = useState('');
  const [depto, setDepto] = useState('');
  const [previa, setPrevia] = useState<Resultado | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const motivos = aux.motivos.filter((m) => m.aplicacao !== 'desconsideracao');

  useEffect(() => {
    if (!aberto) return;
    setErro(null);
    setPrevia(null);
    setForm((f) => ({ ...f, colaboradores: [], motivo: f.motivo || motivos[0]?.id || '' }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [aberto]);

  const visiveis = useMemo(() => aux.colaboradores.filter((c) =>
    c.situacao !== 'desligado' && (!depto || c.departamento_id === depto)
    && (!busca || `${c.nome} ${c.matricula}`.toLowerCase().includes(busca.toLowerCase()))), [aux, depto, busca]);
  const sel = new Set(form.colaboradores);
  const todos = visiveis.length > 0 && visiveis.every((c) => sel.has(c.id));
  const set = <K extends keyof typeof form>(k: K, v: (typeof form)[K]) => { setForm((f) => ({ ...f, [k]: v })); setPrevia(null); };

  const enviar = async (simular: boolean) => {
    setErro(null);
    if (!form.colaboradores.length) return setErro('Selecione ao menos um colaborador.');
    if (!form.motivo) return setErro('Escolha o motivo da inclusão.');
    setSalvando(true);
    try {
      const r = await api<Resultado>('api_batidas_lote', {
        p_dados: {
          colaboradores: form.colaboradores, data_inicio: form.ini, data_fim: form.fim,
          variacao_min: form.variacao, motivo_id: form.motivo, observacao: form.observacao, simular,
        },
      });
      if (simular) setPrevia(r);
      else {
        toast(`${r.batidas} batida(s) incluída(s) em ${r.dias} dia(s).`);
        onSalvo();
      }
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao incluir.');
    } finally {
      setSalvando(false);
    }
  };

  const pulados = previa ? Object.entries(previa.pulados).filter(([, v]) => v > 0) : [];

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-4xl"
      titulo="Incluir batidas em lote"
      descricao="Lança as marcações previstas da jornada nos dias sem nenhuma batida, com variação aleatória de horário."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button variant="secondary" onClick={() => enviar(true)} loading={salvando && !previa}>Pré-visualizar</Button>
          <Button onClick={() => enviar(false)} loading={salvando && !!previa} disabled={!previa || previa.batidas === 0}>
            Incluir {previa ? `${previa.batidas} batida(s)` : ''}
          </Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className="grid gap-6 lg:grid-cols-[1fr_1.1fr]">
        <section>
          <div className="mb-2 flex items-center justify-between">
            <span className="label mb-0">Colaboradores <span className="text-accent-600">*</span></span>
            <span className="text-xs text-slate-500">{form.colaboradores.length} selecionado(s)</span>
          </div>
          <div className="mb-2 grid grid-cols-2 gap-2">
            <input className="input h-9" placeholder="Buscar…" value={busca} onChange={(e) => setBusca(e.target.value)} />
            <select className="input h-9" value={depto} onChange={(e) => setDepto(e.target.value)}>
              <option value="">Todos os departamentos</option>
              {aux.departamentos.map((d) => <option key={d.id} value={d.id}>{d.nome}</option>)}
            </select>
          </div>
          <div className="max-h-80 overflow-y-auto rounded-xl ring-1 ring-slate-200">
            <label className="flex cursor-pointer items-center gap-3 border-b border-slate-100 bg-slate-50 px-3 py-2 text-xs font-medium text-slate-600">
              <input type="checkbox" checked={todos} className="h-4 w-4 accent-primary-700"
                onChange={() => set('colaboradores', todos
                  ? form.colaboradores.filter((id) => !visiveis.some((c) => c.id === id))
                  : Array.from(new Set([...form.colaboradores, ...visiveis.map((c) => c.id)])))} />
              Selecionar todos ({visiveis.length})
            </label>
            {visiveis.map((c) => (
              <label key={c.id} className="flex cursor-pointer items-center gap-3 px-3 py-2 text-sm hover:bg-slate-50">
                <input type="checkbox" checked={sel.has(c.id)} className="h-4 w-4 accent-primary-700"
                  onChange={() => set('colaboradores', sel.has(c.id) ? form.colaboradores.filter((x) => x !== c.id) : [...form.colaboradores, c.id])} />
                <span className="min-w-0 flex-1 truncate text-slate-700">{c.nome}</span>
                <span className="text-xs tabular-nums text-slate-400">{c.matricula}</span>
              </label>
            ))}
            {visiveis.length === 0 && <p className="px-3 py-6 text-center text-xs text-slate-400">Nenhum colaborador.</p>}
          </div>
        </section>

        <section className="space-y-4">
          <div className="grid grid-cols-2 gap-3">
            <Field label="De" obrigatorio>
              <input type="date" className="input" value={form.ini} max={ontem()}
                onChange={(e) => e.target.value && setForm((f) => ({ ...f, ini: e.target.value, fim: f.fim < e.target.value ? e.target.value : f.fim }))} />
            </Field>
            <Field label="Até" obrigatorio dica="Até 31 dias, só dias encerrados.">
              <input type="date" className="input" value={form.fim} min={form.ini} max={ontem()} onChange={(e) => e.target.value && set('fim', e.target.value)} />
            </Field>
          </div>
          <Field label="Variação dos horários" dica={form.variacao
            ? `Cada batida fica até ${form.variacao} min antes ou depois do previsto, sorteado pelo sistema.`
            : 'Sem variação: as batidas ficam exatamente no horário previsto.'}>
            <select className="input" value={form.variacao} onChange={(e) => set('variacao', Number(e.target.value))}>
              {[0, 1, 2, 3, 5, 7, 10, 15].map((v) => <option key={v} value={v}>{v === 0 ? 'Sem variação' : `± ${v} minuto(s)`}</option>)}
            </select>
          </Field>
          <Field label="Motivo" obrigatorio>
            <select className="input" value={form.motivo} onChange={(e) => set('motivo', e.target.value)}>
              <option value="">Selecione…</option>
              {motivos.map((m) => <option key={m.id} value={m.id}>{m.descricao}</option>)}
            </select>
          </Field>
          <Field label="Observação">
            <input className="input" value={form.observacao} placeholder="Ex.: relógio parado de 03 a 07" onChange={(e) => set('observacao', e.target.value)} />
          </Field>
          <p className="rounded-xl bg-amber-50 p-3 text-xs text-amber-800 ring-1 ring-amber-200">
            Entram só os dias <strong>sem nenhuma batida</strong>. Folgas, feriados, dias com ocorrência ou afastamento e períodos
            fechados ficam de fora. As batidas ficam marcadas como incluídas no tratamento (espelho e auditoria).
          </p>
          {previa && (
            <div className="rounded-xl bg-primary-50/60 p-3 text-sm text-primary-900 ring-1 ring-primary-100">
              <p className="font-medium">{previa.batidas} batida(s) em {previa.dias} dia(s).</p>
              {pulados.length > 0 && (
                <p className="mt-1 text-xs text-primary-800/80">
                  Dias pulados: {pulados.map(([k, v]) => `${v} ${PULOS[k as keyof Resultado['pulados']]}`).join(' · ')}.
                </p>
              )}
            </div>
          )}
        </section>
      </div>
    </Modal>
  );
}
