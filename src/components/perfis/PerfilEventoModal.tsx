import clsx from 'clsx';
import { CopyCheck, Moon, Star, Trash2 } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { DIAS_HE, novoPerfilEvento } from '@/lib/perfilEvento';
import { api } from '@/lib/supabase';
import type { PerfilEvento } from '@/lib/types';

export function PerfilEventoModal({
  aberto,
  perfil,
  podeEditar,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  perfil: PerfilEvento | null;
  podeEditar: boolean;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<PerfilEvento>(novoPerfilEvento);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [confirmarExclusao, setConfirmarExclusao] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setForm(perfil ? structuredClone(perfil) : novoPerfilEvento());
    setErro(null);
    setConfirmarExclusao(false);
  }, [aberto, perfil]);

  const set = <K extends keyof PerfilEvento>(k: K, v: PerfilEvento[K]) => setForm((f) => ({ ...f, [k]: v }));
  const percentual = (dia: number) => form.he.find((h) => h.dia === dia)?.percentual ?? 0;
  const setPercentual = (dia: number, valor: number) =>
    setForm((f) => ({ ...f, he: f.he.map((h) => (h.dia === dia ? { ...h, percentual: valor } : h)) }));
  const replicarSegunda = () => {
    const seg = percentual(1);
    setForm((f) => ({ ...f, he: f.he.map((h) => (h.dia >= 2 && h.dia <= 6 ? { ...h, percentual: seg } : h)) }));
  };

  const salvar = async () => {
    setErro(null);
    setSalvando(true);
    try {
      await api('api_perfil_evento_salvar', { p_dados: form });
      toast(perfil?.id ? 'Perfil atualizado. O cálculo dos colaboradores com este perfil foi refeito.' : 'Perfil cadastrado.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const excluir = async () => {
    if (!perfil?.id) return;
    setSalvando(true);
    try {
      await api('api_perfil_evento_excluir', { p_id: perfil.id });
      toast('Perfil excluído.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao excluir.');
      setConfirmarExclusao(false);
    } finally {
      setSalvando(false);
    }
  };

  const somenteLeitura = !podeEditar;
  const numero = (v: string) => (v === '' ? 0 : Number(v.replace(',', '.')));

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-4xl"
      titulo={perfil?.id ? 'Editar perfil de eventos' : 'Novo perfil de eventos'}
      descricao="Regras de cálculo do ponto: tolerâncias, hora extra por dia, adicional noturno e banco de horas."
      rodape={
        somenteLeitura ? (
          <Button variant="secondary" onClick={onFechar}>
            Fechar
          </Button>
        ) : (
          <div className="flex w-full flex-wrap items-center justify-between gap-2">
            <div>
              {perfil?.id &&
                !perfil.padrao &&
                (confirmarExclusao ? (
                  <div className="flex items-center gap-2 text-sm">
                    <span className="text-slate-600">Excluir este perfil?</span>
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
                Salvar perfil
              </Button>
            </div>
          </div>
        )
      }
    >
      <AlertaErro mensagem={erro} />

      <fieldset disabled={somenteLeitura} className="space-y-6">
        <div className="grid gap-4 sm:grid-cols-[1fr_1.4fr]">
          <Field label="Nome do perfil" obrigatorio>
            <input className="input" value={form.nome} onChange={(e) => set('nome', e.target.value)}
              placeholder="Ex.: Comércio — HE 60%" autoFocus />
          </Field>
          <Field label="Descrição">
            <input className="input" value={form.descricao ?? ''} onChange={(e) => set('descricao', e.target.value)}
              placeholder="Convenção coletiva, setor… (opcional)" />
          </Field>
        </div>

        {/* Horas extras por dia */}
        <section className="rounded-xl p-4 ring-1 ring-slate-200/80">
          <div className="mb-4 flex flex-wrap items-start justify-between gap-2">
            <div>
              <h3 className="text-sm font-semibold text-slate-800">Percentual de hora extra por dia</h3>
              <p className="text-xs text-slate-500">
                Vale para as horas trabalhadas além do previsto no dia. No feriado vale o percentual de "Feriado", em qualquer dia
                da semana. Cada percentual vira um evento na exportação para a folha.
              </p>
            </div>
            <Button variant="ghost" className="h-8 shrink-0 text-xs" onClick={replicarSegunda}>
              <CopyCheck className="h-3.5 w-3.5" /> Copiar segunda até sábado
            </Button>
          </div>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-8">
            {DIAS_HE.map((d) => (
              <Field key={d.dia} label={d.nome}>
                <div className="relative">
                  <input
                    type="number"
                    min={0}
                    max={999}
                    step="0.5"
                    className={clsx('input pr-7 tabular-nums', d.dia === 7 && 'bg-accent-50/60')}
                    value={percentual(d.dia)}
                    onChange={(e) => setPercentual(d.dia, numero(e.target.value))}
                  />
                  <span className="pointer-events-none absolute right-2.5 top-1/2 -translate-y-1/2 text-xs text-slate-400">%</span>
                </div>
              </Field>
            ))}
          </div>
        </section>

        <section className="grid gap-6 lg:grid-cols-2">
          <div className="rounded-xl p-4 ring-1 ring-slate-200/80">
            <h3 className="text-sm font-semibold text-slate-800">Tolerâncias</h3>
            <p className="mb-4 text-xs text-slate-500">Atrasos e variações dentro desses limites não são descontados.</p>
            <div className="grid grid-cols-3 gap-3">
              <Field label="Entrada (min)">
                <input type="number" min={0} className="input" value={form.tolerancia_entrada_min}
                  onChange={(e) => set('tolerancia_entrada_min', numero(e.target.value))} />
              </Field>
              <Field label="Saída (min)">
                <input type="number" min={0} className="input" value={form.tolerancia_saida_min}
                  onChange={(e) => set('tolerancia_saida_min', numero(e.target.value))} />
              </Field>
              <Field label="Geral do dia (min)">
                <input type="number" min={0} className="input" value={form.tolerancia_diaria_min}
                  onChange={(e) => set('tolerancia_diaria_min', numero(e.target.value))} />
              </Field>
            </div>
            <p className="mt-2 text-[11px] text-slate-400">
              Geral do dia: se a diferença entre o trabalhado e o previsto ficar dentro dela, o dia fecha sem extra e sem débito.
              CLT art. 58 §1º: até 5 min por marcação e 10 min por dia.
            </p>
          </div>

          <div className="rounded-xl p-4 ring-1 ring-slate-200/80">
            <h3 className="text-sm font-semibold text-slate-800">Banco de horas e limite</h3>
            <p className="mb-3 text-xs text-slate-500">Com banco de horas, o saldo do dia vai para o banco (hora por hora) em vez da folha.</p>
            <Switch
              ativo={form.usa_banco_horas}
              onChange={(v) => set('usa_banco_horas', v)}
              label="Usa banco de horas"
              descricao="Desligado: horas extras, faltas e atrasos vão para a folha."
            />
            <Field label="Limite de hora extra por dia (min)" className="mt-3"
              dica="Acima disso o dia aparece em Quebra de Regras (CLT art. 59: até 2h). 0 = sem limite.">
              <input type="number" min={0} className="input w-40" value={form.limite_he_diario_min}
                onChange={(e) => set('limite_he_diario_min', numero(e.target.value))} />
            </Field>
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
                  onChange={(e) => set('percentual_noturno', numero(e.target.value))} />
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
            ativo={form.padrao}
            onChange={(v) => set('padrao', v)}
            label="Perfil padrão"
            descricao="Usado por quem é cadastrado sem escolher um perfil. Só um perfil é o padrão."
          />
          <Switch
            ativo={form.ativo}
            onChange={(v) => set('ativo', v)}
            label="Perfil ativo"
            descricao="Perfis inativos não aparecem no cadastro de colaboradores."
          />
        </div>
        {perfil?.padrao && (
          <p className="flex items-center gap-1.5 text-xs text-slate-500">
            <Star className="h-3.5 w-3.5 text-accent-600" /> Para trocar o perfil padrão, marque outro perfil como padrão.
          </p>
        )}
      </fieldset>
    </Modal>
  );
}
