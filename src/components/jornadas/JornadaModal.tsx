import clsx from 'clsx';
import { CalendarDays, CopyCheck, Moon, Repeat, Trash2 } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { formatData, formatMinutos, toISODate } from '@/lib/format';
import {
  diasDoModelo,
  MODELOS_ESCALA,
  minutosDia,
  novaJornada,
  redimensionarCiclo,
  rotuloDiaJornada,
} from '@/lib/jornada';
import { api } from '@/lib/supabase';
import type { Jornada, JornadaDia, TipoJornada } from '@/lib/types';

const CAMPOS_HORARIO: { chave: keyof Pick<JornadaDia, 'entrada' | 'saida_intervalo' | 'retorno_intervalo' | 'saida'>; label: string }[] = [
  { chave: 'entrada', label: 'Entrada' },
  { chave: 'saida_intervalo', label: 'Saída intervalo' },
  { chave: 'retorno_intervalo', label: 'Retorno' },
  { chave: 'saida', label: 'Saída' },
];

const TIPOS: { valor: TipoJornada; titulo: string; descricao: string; icon: typeof CalendarDays }[] = [
  { valor: 'semanal', titulo: 'Semanal', descricao: 'Mesmo horário em cada dia da semana', icon: CalendarDays },
  { valor: 'escala', titulo: 'Escala / revezamento', descricao: '12x36, 5x1, 6x2… o ciclo se repete', icon: Repeat },
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
  // que o "1" ou o "3" no meio do caminho redimensione a escala e apague os dias preenchidos
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

  const escala = form.tipo === 'escala';
  const ciclo = escala ? (form.ciclo_dias ?? form.dias.length) : 7;

  useEffect(() => {
    setCicloTexto(String(ciclo));
  }, [ciclo]);

  const mudarTipo = (tipo: TipoJornada) => {
    if (tipo === form.tipo) return;
    if (tipo === 'escala') {
      const dias = diasDoModelo('12x36d');
      setForm((f) => ({ ...f, tipo, ciclo_dias: dias.length, data_base: f.data_base ?? toISODate(new Date()), dias }));
    } else {
      setForm((f) => ({ ...f, tipo, ciclo_dias: null, data_base: null, dias: novaJornada().dias }));
    }
  };

  const aplicarModelo = (chave: string) => {
    const dias = diasDoModelo(chave);
    setForm((f) => ({ ...f, ciclo_dias: dias.length, dias }));
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
  const ordemDias = escala ? Array.from({ length: ciclo }, (_, i) => i) : [1, 2, 3, 4, 5, 6, 0];

  const salvar = async () => {
    setErro(null);
    setSalvando(true);
    try {
      await api('api_jornada_salvar', { p_dados: { ...form, ciclo_dias: escala ? ciclo : null } });
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
      largura="max-w-4xl"
      titulo={jornada?.id ? 'Editar jornada' : 'Nova jornada de trabalho'}
      descricao="Defina a escala, as tolerâncias, as horas extras e o adicional noturno."
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
              placeholder="Observações sobre a escala (opcional)"
            />
          </Field>
        </div>

        {/* Tipo de jornada */}
        <div className="grid gap-3 sm:grid-cols-2">
          {TIPOS.map((t) => (
            <button
              key={t.valor}
              type="button"
              onClick={() => mudarTipo(t.valor)}
              className={clsx(
                'flex items-start gap-3 rounded-xl p-3.5 text-left ring-1 transition',
                form.tipo === t.valor ? 'bg-primary-50 ring-2 ring-primary-600' : 'ring-slate-200 hover:bg-slate-50',
              )}
            >
              <span
                className={clsx(
                  'flex h-9 w-9 shrink-0 items-center justify-center rounded-lg',
                  form.tipo === t.valor ? 'bg-primary-700 text-white' : 'bg-slate-100 text-slate-500',
                )}
              >
                <t.icon className="h-4 w-4" />
              </span>
              <span>
                <span className="block text-sm font-semibold text-slate-800">{t.titulo}</span>
                <span className="block text-xs text-slate-500">{t.descricao}</span>
              </span>
            </button>
          ))}
        </div>

        {escala && (
          <section className="rounded-xl bg-slate-50/70 p-4 ring-1 ring-slate-200/80">
            <div className="grid gap-4 sm:grid-cols-[1fr_140px_180px]">
              <Field label="Modelo" grupo dica="Preenche o ciclo com horários sugeridos; ajuste depois se precisar.">
                <div className="flex flex-wrap gap-1.5">
                  {MODELOS_ESCALA.map((m) => (
                    <button
                      key={m.chave}
                      type="button"
                      title={m.descricao}
                      onClick={() => aplicarModelo(m.chave)}
                      className="rounded-lg bg-white px-2.5 py-1.5 text-xs font-medium text-primary-700 ring-1 ring-slate-200 transition hover:bg-primary-50"
                    >
                      {m.nome}
                    </button>
                  ))}
                </div>
              </Field>
              <Field label="Dias do ciclo" obrigatorio>
                <input type="number" min={2} max={60} className="input" value={cicloTexto}
                  onChange={(e) => setCicloTexto(e.target.value)}
                  onBlur={() => mudarCiclo(Number(cicloTexto))}
                  onKeyDown={(e) => { if (e.key === 'Enter') mudarCiclo(Number(cicloTexto)); }} />
              </Field>
              <Field label="Dia 1 do ciclo em" obrigatorio dica="Data em que o ciclo começa">
                <input type="date" className="input" value={form.data_base ?? ''} onChange={(e) => set('data_base', e.target.value || null)} />
              </Field>
            </div>
          </section>
        )}

        {/* Horários */}
        <section>
          <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
            <div>
              <h3 className="text-sm font-semibold text-slate-800">{escala ? 'Ciclo da escala' : 'Escala semanal'}</h3>
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
            <table className="w-full min-w-[640px] text-sm">
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
                          aria-label={`${rotulo} é dia de trabalho`}
                          onClick={() =>
                            setDia(i, d.folga
                              ? { folga: false, entrada: '08:00', saida_intervalo: '12:00', retorno_intervalo: '13:00', saida: '17:00' }
                              : { folga: true })
                          }
                          className={clsx(
                            'relative inline-flex h-5 w-9 rounded-full transition',
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
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <p className="mt-2 text-[11px] text-slate-400">
            Sem intervalo? Deixe "Saída intervalo" e "Retorno" em branco. Turnos que viram a meia-noite (ex.: 22:00–06:00) são
            aceitos: as batidas da madrugada contam no dia em que o turno começou.
          </p>
        </section>

        {/* Regras */}
        <section className="grid gap-6 lg:grid-cols-2">
          <div className="rounded-xl p-4 ring-1 ring-slate-200/80">
            <h3 className="text-sm font-semibold text-slate-800">Tolerâncias</h3>
            <p className="mb-4 text-xs text-slate-500">Atrasos e variações dentro desses limites não são descontados.</p>
            <div className="grid grid-cols-3 gap-3">
              <Field label="Entrada (min)">
                <input type="number" min={0} className="input" value={form.tolerancia_entrada_min}
                  onChange={(e) => set('tolerancia_entrada_min', Number(e.target.value))} />
              </Field>
              <Field label="Saída (min)">
                <input type="number" min={0} className="input" value={form.tolerancia_saida_min}
                  onChange={(e) => set('tolerancia_saida_min', Number(e.target.value))} />
              </Field>
              <Field label="Diária (min)">
                <input type="number" min={0} className="input" value={form.tolerancia_diaria_min}
                  onChange={(e) => set('tolerancia_diaria_min', Number(e.target.value))} />
              </Field>
            </div>
            <p className="mt-2 text-[11px] text-slate-400">CLT art. 58 §1º: até 5 min por marcação e 10 min por dia.</p>
          </div>

          <div className="rounded-xl p-4 ring-1 ring-slate-200/80">
            <h3 className="text-sm font-semibold text-slate-800">Horas extras</h3>
            <p className="mb-4 text-xs text-slate-500">Adicionais pagos quando a jornada não usa banco de horas.</p>
            <div className="grid grid-cols-3 gap-3">
              <Field label="Dia útil (%)">
                <input type="number" min={0} className="input" value={form.percentual_he_dia_util}
                  onChange={(e) => set('percentual_he_dia_util', Number(e.target.value))} />
              </Field>
              <Field label="Folga/feriado (%)">
                <input type="number" min={0} className="input" value={form.percentual_he_domingo}
                  onChange={(e) => set('percentual_he_domingo', Number(e.target.value))} />
              </Field>
              <Field label="Limite/dia (min)">
                <input type="number" min={0} className="input" value={form.limite_he_diario_min}
                  onChange={(e) => set('limite_he_diario_min', Number(e.target.value))} />
              </Field>
            </div>
          </div>

          <div className="rounded-xl p-4 ring-1 ring-slate-200/80 lg:col-span-2">
            <h3 className="flex items-center gap-2 text-sm font-semibold text-slate-800">
              <Moon className="h-4 w-4 text-primary-600" /> Adicional noturno
            </h3>
            <p className="mb-4 text-xs text-slate-500">
              CLT art. 73: trabalho entre 22h e 5h, com adicional de no mínimo 20% e hora noturna de 52min30s.
            </p>
            <div className="grid gap-3 sm:grid-cols-[repeat(3,minmax(0,140px))_1fr] sm:items-end">
              <Field label="Início">
                <input type="time" className="input" value={form.noturno_inicio} onChange={(e) => set('noturno_inicio', e.target.value)} />
              </Field>
              <Field label="Fim">
                <input type="time" className="input" value={form.noturno_fim} onChange={(e) => set('noturno_fim', e.target.value)} />
              </Field>
              <Field label="Adicional (%)">
                <input type="number" min={0} className="input" value={form.percentual_noturno}
                  onChange={(e) => set('percentual_noturno', Number(e.target.value))} />
              </Field>
              <Switch
                ativo={form.hora_noturna_reduzida}
                onChange={(v) => set('hora_noturna_reduzida', v)}
                label="Hora noturna reduzida"
                descricao="Cada 52min30s noturnos contam como 1 hora."
              />
            </div>
          </div>
        </section>

        <div className="grid gap-2 sm:grid-cols-2">
          <Switch
            ativo={form.usa_banco_horas}
            onChange={(v) => set('usa_banco_horas', v)}
            label="Usa banco de horas"
            descricao="Saldos diários viram créditos/débitos no banco. Desligado: extras e faltas vão para a folha."
          />
          <Switch
            ativo={form.ativo}
            onChange={(v) => set('ativo', v)}
            label="Jornada ativa"
            descricao="Jornadas inativas não aparecem no cadastro de colaboradores."
          />
        </div>
      </fieldset>
    </Modal>
  );
}

