import clsx from 'clsx';
import { AlertTriangle, CopyCheck, SlidersHorizontal, Trash2 } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { formatData, formatMinutos, toISODate } from '@/lib/format';
import {
  diasDoTipo,
  GRUPOS_TIPO_JORNADA,
  TIPOS_JORNADA,
  tipoDaJornada,
  minutosDia,
  novaJornada,
  redimensionarCiclo,
  rotuloDiaJornada,
} from '@/lib/jornada';
import { api } from '@/lib/api';
import type { Jornada, JornadaDia } from '@/lib/types';

const CAMPOS_HORARIO: { chave: keyof Pick<JornadaDia, 'entrada' | 'saida_intervalo' | 'retorno_intervalo' | 'saida'>; label: string }[] = [
  { chave: 'entrada', label: 'Entrada' },
  { chave: 'saida_intervalo', label: 'Saída intervalo' },
  { chave: 'retorno_intervalo', label: 'Retorno' },
  { chave: 'saida', label: 'Saída' },
];

/** Próximas datas em que cada dia do ciclo cai (ajuda a conferir a data base). */
function proximasDatas(dataBase: string | null, ciclo: number, dia: number): string | null {
  if (!dataBase) return null;
  const base = new Date(`${dataBase}T00:00:00`);
  const hoje = new Date();
  hoje.setHours(0, 0, 0, 0);
  const diff = Math.floor((hoje.getTime() - base.getTime()) / 86400000);
  const indiceHoje = ((diff % ciclo) + ciclo) % ciclo;
  const delta = (dia - indiceHoje + ciclo) % ciclo;
  const d = new Date(hoje);
  d.setDate(d.getDate() + delta);
  return formatData(toISODate(d), { weekday: 'short', day: '2-digit', month: '2-digit' }).replace('.', '');
}

/** Opções de cada dia, além do horário */
const OPCOES_DIA: { chave: 'dia_util' | 'recebe_vt' | 'recebe_va'; label: string; dica: string }[] = [
  { chave: 'dia_util', label: 'Dia útil', dica: 'Falta em dia útil desconta o DSR da semana' },
  { chave: 'recebe_vt', label: 'VT', dica: 'Trabalhando neste dia, recebe vale-transporte' },
  { chave: 'recebe_va', label: 'VA', dica: 'Trabalhando neste dia, recebe vale-alimentação' },
];

export function JornadaModal({
  aberto,
  jornada,
  podeEditar,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  jornada: Jornada | null;
  podeEditar: boolean;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<Jornada>(novaJornada);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [confirmarExclusao, setConfirmarExclusao] = useState(false);
  // Texto digitado no ciclo: só é aplicado ao sair do campo, para dar para digitar "12" ou "30" sem
  // que o "1" ou o "3" no meio do caminho redimensione o ciclo e apague os dias preenchidos
  const [cicloTexto, setCicloTexto] = useState('');

  useEffect(() => {
    if (!aberto) return;
    setForm(jornada ? structuredClone(jornada) : novaJornada());
    setErro(null);
    setConfirmarExclusao(false);
  }, [aberto, jornada]);

  const set = <K extends keyof Jornada>(k: K, v: Jornada[K]) => setForm((f) => ({ ...f, [k]: v }));
  const setDia = (dia: number, patch: Partial<JornadaDia>) =>
    setForm((f) => ({ ...f, dias: f.dias.map((d) => (d.dia_semana === dia ? { ...d, ...patch } : d)) }));

  const tipo = tipoDaJornada(form);
  const escala = form.tipo === 'escala';
  // Nos tipos de revezamento o ciclo e as folgas fazem parte do tipo; só o Ciclo livre os muda
  const travado = escala && !tipo.livre;
  const ciclo = escala ? (form.ciclo_dias ?? form.dias.length) : 7;

  useEffect(() => {
    setCicloTexto(String(ciclo));
  }, [ciclo]);

  const mudarTipo = (chave: string) => {
    const t = TIPOS_JORNADA.find((x) => x.chave === chave);
    if (!t) return;
    // Para o livre da mesma repetição, os horários já preenchidos continuam
    const dias = t.livre && t.repete === form.tipo ? form.dias : diasDoTipo(t);
    setForm((f) => ({
      ...f,
      modelo: t.chave,
      tipo: t.repete,
      dias,
      ciclo_dias: t.repete === 'escala' ? dias.length : null,
      data_base: t.repete === 'escala' ? (f.data_base ?? toISODate(new Date())) : null,
    }));
  };

  const mudarCiclo = (n: number) => {
    const valor = Math.max(2, Math.min(60, n || 2));
    setCicloTexto(String(valor));
    setForm((f) => ({ ...f, ciclo_dias: valor, dias: redimensionarCiclo(f.dias, valor) }));
  };

  const replicarSegunda = () => {
    const seg = form.dias.find((d) => d.dia_semana === 1);
    if (!seg) return;
    setForm((f) => ({
      ...f,
      dias: f.dias.map((d) => (d.dia_semana >= 2 && d.dia_semana <= 5 ? { ...seg, dia_semana: d.dia_semana } : d)),
    }));
  };

  const totalCiclo = form.dias.reduce((s, d) => s + minutosDia(d), 0);
  const mediaSemanal = escala ? Math.round((totalCiclo * 7) / ciclo) : totalCiclo;
  const diasTrabalho = form.dias.filter((d) => !d.folga).length;
  const avisos: string[] = [];
  if (tipo.limiteSemana && mediaSemanal > tipo.limiteSemana) {
    avisos.push(`Os horários somam ${formatMinutos(mediaSemanal)} por semana, acima das ${formatMinutos(tipo.limiteSemana)} deste tipo.`);
  }
  if (!tipo.livre && !escala && diasTrabalho !== tipo.dias.filter((d) => !d.folga).length) {
    avisos.push(`Este tipo tem ${tipo.dias.filter((d) => !d.folga).length} dia(s) de trabalho por semana e há ${diasTrabalho} marcado(s).`);
  }
  const ordemDias = escala ? Array.from({ length: ciclo }, (_, i) => i) : [1, 2, 3, 4, 5, 6, 0];

  const salvar = async () => {
    setErro(null);
    setSalvando(true);
    try {
      await api('api_jornada_salvar', { p_dados: { ...form, modelo: tipo.chave, ciclo_dias: escala ? ciclo : null } });
      toast(jornada?.id ? 'Jornada atualizada.' : 'Jornada cadastrada.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const excluir = async () => {
    if (!jornada?.id) return;
    setSalvando(true);
    try {
      await api('api_jornada_excluir', { p_id: jornada.id });
      toast('Jornada excluída.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao excluir.');
      setConfirmarExclusao(false);
    } finally {
      setSalvando(false);
    }
  };

  const somenteLeitura = !podeEditar;

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-5xl"
      titulo={jornada?.id ? 'Editar jornada' : 'Nova jornada de trabalho'}
      descricao="Escolha o tipo e defina os horários."
      rodape={
        somenteLeitura ? (
          <Button variant="secondary" onClick={onFechar}>
            Fechar
          </Button>
        ) : (
          <div className="flex w-full flex-wrap items-center justify-between gap-2">
            <div>
              {jornada?.id &&
                (confirmarExclusao ? (
                  <div className="flex items-center gap-2 text-sm">
                    <span className="text-slate-600">Excluir esta jornada?</span>
                    <Button variant="ghost" className="h-9 text-rose-600 hover:bg-rose-50" onClick={excluir} loading={salvando}>
                      Sim, excluir
                    </Button>
                    <Button variant="ghost" className="h-9" onClick={() => setConfirmarExclusao(false)}>
                      Não
                    </Button>
                  </div>
                ) : (
                  <Button variant="ghost" className="h-9 text-rose-600 hover:bg-rose-50" onClick={() => setConfirmarExclusao(true)}>
                    <Trash2 className="h-4 w-4" /> Excluir
                  </Button>
                ))}
            </div>
            <div className="flex gap-2">
              <Button variant="secondary" onClick={onFechar}>
                Cancelar
              </Button>
              <Button variant="primary" onClick={salvar} loading={salvando}>
                Salvar jornada
              </Button>
            </div>
          </div>
        )
      }
    >
      <AlertaErro mensagem={erro} />

      <fieldset disabled={somenteLeitura} className="space-y-6">
        <div className="grid gap-4 sm:grid-cols-[1fr_1.4fr]">
          <Field label="Nome da jornada" obrigatorio>
            <input
              className="input"
              value={form.nome}
              onChange={(e) => set('nome', e.target.value)}
              placeholder="Ex.: Administrativo 44h"
              autoFocus
            />
          </Field>
          <Field label="Descrição">
            <input
              className="input"
              value={form.descricao ?? ''}
              onChange={(e) => set('descricao', e.target.value)}
              placeholder="Observações (opcional)"
            />
          </Field>
        </div>

        <section className="space-y-3 rounded-xl bg-slate-50/70 p-4 ring-1 ring-slate-200/80">
          <div className={clsx('grid gap-4', escala && 'sm:grid-cols-[1fr_140px_180px]')}>
            <Field label="Tipo de jornada" obrigatorio>
              <select className="input" value={tipo.chave} onChange={(e) => mudarTipo(e.target.value)}>
                {GRUPOS_TIPO_JORNADA.map((g) => (
                  <optgroup key={g} label={g}>
                    {TIPOS_JORNADA.filter((t) => t.grupo === g).map((t) => <option key={t.chave} value={t.chave}>{t.nome}</option>)}
                  </optgroup>
                ))}
              </select>
            </Field>
            {escala && (
              <>
                <Field label="Dias do ciclo" obrigatorio>
                  <input type="number" min={2} max={60} className="input" value={cicloTexto} disabled={travado}
                    onChange={(e) => setCicloTexto(e.target.value)}
                    onBlur={() => mudarCiclo(Number(cicloTexto))}
                    onKeyDown={(e) => { if (e.key === 'Enter') mudarCiclo(Number(cicloTexto)); }} />
                </Field>
                <Field label="Dia 1 do ciclo em" obrigatorio dica="Data em que o ciclo começa">
                  <input type="date" className="input" value={form.data_base ?? ''} onChange={(e) => set('data_base', e.target.value || null)} />
                </Field>
              </>
            )}
          </div>
          <p className="text-xs text-slate-500">
            {tipo.descricao}
            {tipo.base && <span className="block text-slate-400">Base legal: {tipo.base}</span>}
            {!somenteLeitura && <span className="block text-slate-400">Trocar o tipo preenche os horários sugeridos; ajuste depois se precisar.</span>}
          </p>
          {avisos.map((a) => (
            <p key={a} className="flex items-start gap-2 rounded-lg bg-amber-50 p-2.5 text-xs text-amber-800 ring-1 ring-amber-200">
              <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0" /> {a}
            </p>
          ))}
        </section>

        {/* Horários */}
        <section>
          <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
            <div>
              <h3 className="text-sm font-semibold text-slate-800">{escala ? 'Horários do ciclo' : 'Horários da semana'}</h3>
              <p className="text-xs text-slate-500">
                {escala ? (
                  <>
                    Total do ciclo: <strong className="font-semibold text-primary-700">{formatMinutos(totalCiclo)}</strong> · média de{' '}
                    <strong className="font-semibold text-primary-700">{formatMinutos(mediaSemanal)}</strong> por semana
                  </>
                ) : (
                  <>
                    Total previsto: <strong className="font-semibold text-primary-700">{formatMinutos(totalCiclo)}</strong> por semana
                  </>
                )}
              </p>
            </div>
            {!somenteLeitura && !escala && (
              <button
                type="button"
                onClick={replicarSegunda}
                className="flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-xs font-medium text-primary-600 transition hover:bg-primary-50"
              >
                <CopyCheck className="h-3.5 w-3.5" /> Copiar segunda para terça–sexta
              </button>
            )}
          </div>

          <div className="max-h-[360px] overflow-auto rounded-xl ring-1 ring-slate-200/80">
            <table className="w-full min-w-[820px] text-sm">
              <thead className="sticky top-0 bg-slate-50 text-xs text-slate-500">
                <tr>
                  <th className="px-3 py-2.5 text-left font-medium">Dia</th>
                  <th className="px-3 py-2.5 text-left font-medium">Trabalha?</th>
                  {CAMPOS_HORARIO.map((c) => (
                    <th key={c.chave} className="px-2 py-2.5 text-left font-medium">
                      {c.label}
                    </th>
                  ))}
                  <th className="px-3 py-2.5 text-right font-medium">Horas</th>
                  {OPCOES_DIA.map((o) => (
                    <th key={o.chave} className="whitespace-nowrap px-2 py-2.5 text-center font-medium" title={o.dica}>{o.label}</th>
                  ))}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {ordemDias.map((i) => {
                  const d = form.dias.find((x) => x.dia_semana === i);
                  if (!d) return null;
                  const rotulo = rotuloDiaJornada(form, i);
                  const proxima = escala ? proximasDatas(form.data_base, ciclo, i) : null;
                  return (
                    <tr key={i} className={clsx(d.folga && 'bg-slate-50/60')}>
                      <td className="px-3 py-2">
                        <span className="font-medium text-slate-700">{rotulo}</span>
                        {proxima && <span className="block text-[10px] capitalize text-slate-400">próx. {proxima}</span>}
                      </td>
                      <td className="px-3 py-2">
                        <button
                          type="button"
                          role="switch"
                          aria-checked={!d.folga}
                          disabled={travado}
                          title={travado ? 'Definido pelo tipo de jornada. Para mudar, use o Ciclo livre.' : undefined}
                          aria-label={`${rotulo} é dia de trabalho`}
                          onClick={() =>
                            setDia(i, d.folga
                              ? { folga: false, dia_util: true, recebe_vt: true, recebe_va: true, entrada: '08:00', saida_intervalo: '12:00', retorno_intervalo: '13:00', saida: '17:00' }
                              : { folga: true, dia_util: false, recebe_vt: false, recebe_va: false })
                          }
                          className={clsx(
                            'relative inline-flex h-5 w-9 rounded-full transition disabled:cursor-not-allowed disabled:opacity-50',
                            d.folga ? 'bg-slate-200' : 'bg-primary-700',
                          )}
                        >
                          <span
                            className={clsx(
                              'absolute top-0.5 h-4 w-4 rounded-full bg-white shadow transition-all',
                              d.folga ? 'left-0.5' : 'left-[18px]',
                            )}
                          />
                        </button>
                      </td>
                      {d.folga ? (
                        <td colSpan={4} className="px-2 py-2 text-xs text-slate-400">
                          Folga / descanso
                        </td>
                      ) : (
                        CAMPOS_HORARIO.map((c) => (
                          <td key={c.chave} className="px-2 py-2">
                            <input
                              type="time"
                              value={d[c.chave] ?? ''}
                              onChange={(e) => setDia(i, { [c.chave]: e.target.value || null })}
                              className="input h-9 w-[110px] px-2 tabular-nums"
                              aria-label={`${rotulo} — ${c.label}`}
                            />
                          </td>
                        ))
                      )}
                      <td className="px-3 py-2 text-right font-medium tabular-nums text-slate-700">
                        {d.folga ? '—' : formatMinutos(minutosDia(d))}
                      </td>
                      {OPCOES_DIA.map((o) => (
                        <td key={o.chave} className="px-2 py-2 text-center">
                          <input type="checkbox" className="h-4 w-4 accent-primary-700" checked={d[o.chave] ?? !d.folga}
                            aria-label={`${rotulo} — ${o.label}`} title={o.dica}
                            onChange={(e) => setDia(i, { [o.chave]: e.target.checked })} />
                        </td>
                      ))}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <p className="mt-2 text-[11px] text-slate-400">
            Sem intervalo? Deixe "Saída intervalo" e "Retorno" em branco. Turnos que viram a meia-noite (ex.: 22:00–06:00) são
            aceitos: as batidas da madrugada contam no dia em que o turno começou. Dia útil vale para o DSR; VT e VA marcam os
            dias que contam nos relatórios quando trabalhados (inclusive folgas, se marcadas).
          </p>
        </section>

        <Switch
          ativo={form.intervalo_flexivel}
          onChange={(v) => set('intervalo_flexivel', v)}
          label="Intervalo flexível"
          descricao={
            form.intervalo_flexivel
              ? 'O colaborador sai para o intervalo quando quiser: vale a duração (retorno − saída do intervalo acima). O retorno esperado é a saída real + essa duração.'
              : 'A saída e o retorno do intervalo são comparados com os horários fixos acima.'
          }
        />

        <Switch
          ativo={form.intervalo_pre_assinalado}
          onChange={(v) => set('intervalo_pre_assinalado', v)}
          label="Intervalo pré-assinalado (Portaria 671)"
          descricao="Quando o colaborador não bater a saída e o retorno do intervalo, o sistema considera o intervalo previsto (as marcações aparecem como pré-assinaladas no espelho)."
        />

        <Switch
          ativo={form.todas_empresas}
          onChange={(v) => set('todas_empresas', v)}
          label="Mostrar em todas as empresas"
          descricao="Desligado: a jornada só aparece na empresa em que foi cadastrada."
        />

        <div className="grid gap-3 sm:grid-cols-2 sm:items-center">
          <Switch
            ativo={form.ativo}
            onChange={(v) => set('ativo', v)}
            label="Jornada ativa"
            descricao="Jornadas inativas não aparecem no cadastro de colaboradores."
          />
          <p className="flex items-start gap-2 rounded-xl bg-slate-50 p-3 text-xs text-slate-500 ring-1 ring-slate-200/80">
            <SlidersHorizontal className="mt-0.5 h-3.5 w-3.5 shrink-0 text-primary-600" />
            Tolerâncias, percentuais de hora extra, adicional noturno e banco de horas ficam na regra de cálculo de cada
            colaborador (Cadastros › Regras de Cálculo).
          </p>
        </div>
      </fieldset>
    </Modal>
  );
}

