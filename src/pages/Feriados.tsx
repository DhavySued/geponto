import clsx from 'clsx';
import { AlertTriangle, CalendarHeart, ChevronLeft, ChevronRight, Pencil, Plus, Sparkles, Trash2 } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Badge, type BadgeTone } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, parseISODate } from '@/lib/format';
import { feriadosNacionais } from '@/lib/hooks';
import { api } from '@/lib/supabase';
import type { Feriado } from '@/lib/types';

const TIPOS: Record<Feriado['tipo'], { label: string; tone: BadgeTone }> = {
  nacional: { label: 'Nacional', tone: 'primary' },
  estadual: { label: 'Estadual', tone: 'blue' },
  municipal: { label: 'Municipal', tone: 'violet' },
  facultativo: { label: 'Ponto facultativo', tone: 'slate' },
};

function FeriadoModal({
  aberto,
  feriado,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  feriado: Feriado | null;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<Feriado>({ data: '', descricao: '', tipo: 'municipal' });
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setForm(feriado ?? { data: '', descricao: '', tipo: 'municipal' });
    setErro(null);
  }, [aberto, feriado]);

  const salvar = async () => {
    setErro(null);
    setSalvando(true);
    try {
      await api('api_feriado_salvar', { p_dados: form });
      toast(feriado?.id ? 'Feriado atualizado.' : 'Feriado cadastrado.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      titulo={feriado?.id ? 'Editar feriado' : 'Novo feriado'}
      descricao="No feriado ninguém tem jornada prevista; quem trabalhar recebe as horas como extra de feriado."
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button onClick={salvar} loading={salvando}>Salvar</Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field label="Data" obrigatorio>
          <input type="date" className="input" value={form.data} onChange={(e) => setForm({ ...form, data: e.target.value })} />
        </Field>
        <Field label="Abrangência" obrigatorio>
          <select className="input" value={form.tipo} onChange={(e) => setForm({ ...form, tipo: e.target.value as Feriado['tipo'] })}>
            {Object.entries(TIPOS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
          </select>
        </Field>
        <Field label="Descrição" obrigatorio className="sm:col-span-2">
          <input className="input" value={form.descricao} placeholder="Ex.: Aniversário da cidade"
            onChange={(e) => setForm({ ...form, descricao: e.target.value })} />
        </Field>
      </div>
    </Modal>
  );
}

export default function Feriados() {
  const { pode } = useAuth();
  const podeEditar = pode('feriados', 'editar');
  const toast = useToast();
  const [ano, setAno] = useState(new Date().getFullYear());
  const [feriados, setFeriados] = useState<Feriado[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState<{ aberto: boolean; feriado: Feriado | null }>({ aberto: false, feriado: null });
  const [importando, setImportando] = useState(false);

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setFeriados(await api<Feriado[]>('api_feriados_listar', { p_ano: ano }));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar feriados.');
    }
  }, [ano]);

  useEffect(() => {
    setFeriados(null);
    carregar();
  }, [carregar]);

  const excluir = async (f: Feriado) => {
    try {
      await api('api_feriado_excluir', { p_id: f.id });
      toast('Feriado excluído.');
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    }
  };

  // Cadastra os feriados nacionais do ano que ainda não existem
  const importarNacionais = async () => {
    setImportando(true);
    const existentes = new Set(feriados?.map((f) => f.data));
    const novos = feriadosNacionais(ano).filter((f) => !existentes.has(f.data));
    try {
      for (const f of novos) await api('api_feriado_salvar', { p_dados: f });
      toast(novos.length ? `${novos.length} feriado(s) nacional(is) cadastrado(s).` : 'Os feriados nacionais do ano já estão cadastrados.');
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao cadastrar feriados.', 'erro');
    } finally {
      setImportando(false);
    }
  };

  const porMes = Array.from({ length: 12 }, (_, m) => ({
    mes: m,
    itens: (feriados ?? []).filter((f) => parseISODate(f.data).getMonth() === m),
  })).filter((g) => g.itens.length > 0);

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Feriados</h2>
          <p className="mt-1 text-sm text-slate-500">Dias sem jornada prevista. Quem trabalha no feriado recebe as horas como extra de feriado.</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex items-center rounded-xl bg-white ring-1 ring-slate-200">
            <button className="rounded-l-xl p-2.5 text-slate-500 hover:bg-slate-50" onClick={() => setAno(ano - 1)} aria-label="Ano anterior">
              <ChevronLeft className="h-4 w-4" />
            </button>
            <span className="w-14 text-center text-sm font-semibold tabular-nums text-slate-800">{ano}</span>
            <button className="rounded-r-xl p-2.5 text-slate-500 hover:bg-slate-50" onClick={() => setAno(ano + 1)} aria-label="Próximo ano">
              <ChevronRight className="h-4 w-4" />
            </button>
          </div>
          {podeEditar && (
            <>
              <Button variant="secondary" onClick={importarNacionais} loading={importando}>
                <Sparkles className="h-4 w-4" /> Feriados nacionais de {ano}
              </Button>
              <Button variant="accent" onClick={() => setModal({ aberto: true, feriado: null })}>
                <Plus className="h-4 w-4" /> Novo feriado
              </Button>
            </>
          )}
        </div>
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {feriados === null ? (
        !erro && <div className="card h-64 animate-pulse" />
      ) : porMes.length === 0 ? (
        <div className="card">
          <EmptyState
            icon={CalendarHeart}
            titulo={`Nenhum feriado cadastrado em ${ano}`}
            descricao="Cadastre os feriados nacionais com um clique e inclua os estaduais e municipais da sua cidade."
          />
        </div>
      ) : (
        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
          {porMes.map((g) => (
            <section key={g.mes} className="card overflow-hidden">
              <header className="border-b border-slate-100 px-5 py-3 text-sm font-semibold capitalize text-slate-800">
                {new Date(ano, g.mes, 1).toLocaleDateString('pt-BR', { month: 'long' })}
              </header>
              <ul className="divide-y divide-slate-100">
                {g.itens.map((f) => {
                  const d = parseISODate(f.data);
                  const fds = [0, 6].includes(d.getDay());
                  return (
                    <li key={f.id} className="group flex items-center gap-3 px-5 py-3">
                      <span className={clsx('flex h-11 w-11 shrink-0 flex-col items-center justify-center rounded-xl',
                        fds ? 'bg-slate-100 text-slate-500' : 'bg-primary-50 text-primary-700')}>
                        <span className="text-base font-semibold leading-none tabular-nums">{d.getDate()}</span>
                        <span className="text-[10px] capitalize">{formatData(f.data, { weekday: 'short' }).replace('.', '')}</span>
                      </span>
                      <div className="min-w-0 flex-1">
                        <p className="truncate text-sm font-medium text-slate-800">{f.descricao}</p>
                        <Badge tone={TIPOS[f.tipo]?.tone ?? 'slate'} dot={false}>{TIPOS[f.tipo]?.label ?? f.tipo}</Badge>
                      </div>
                      {podeEditar && (
                        <div className="flex gap-1 opacity-60 transition group-hover:opacity-100">
                          <button className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-primary-600"
                            onClick={() => setModal({ aberto: true, feriado: f })} aria-label="Editar feriado">
                            <Pencil className="h-4 w-4" />
                          </button>
                          <button className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                            onClick={() => excluir(f)} aria-label="Excluir feriado">
                            <Trash2 className="h-4 w-4" />
                          </button>
                        </div>
                      )}
                    </li>
                  );
                })}
              </ul>
            </section>
          ))}
        </div>
      )}

      <FeriadoModal
        aberto={modal.aberto}
        feriado={modal.feriado}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal({ aberto: false, feriado: null });
          carregar();
        }}
      />
    </div>
  );
}
