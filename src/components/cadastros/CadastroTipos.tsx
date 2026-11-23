import { AlertTriangle, Pencil, Plus, Trash2, type LucideIcon } from 'lucide-react';
import { useCallback, useEffect, useState, type ReactNode } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { api } from '@/lib/api';
import type { PaginaChave } from '@/lib/types';

/** Item de um cadastro simples de tipos (descrição, ativo e quantas vezes foi usado) */
export interface ItemTipo {
  id?: string;
  descricao: string;
  ativo: boolean;
  em_uso?: number;
  [campo: string]: unknown;
}

/**
 * Cadastro de tipos (tipos de licença, motivos de batida…): criar, alterar, desativar e excluir.
 * O banco não deixa excluir o que já foi lançado; nesse caso, o tipo pode ser desativado.
 */
export function CadastroTipos<T extends ItemTipo>({
  pagina, titulo, descricao, icon, nomeItem, rpc, novo, colunas, campos,
}: {
  pagina: PaginaChave;
  titulo: string;
  descricao: string;
  icon: LucideIcon;
  /** "tipo de licença", "motivo" */
  nomeItem: string;
  rpc: { listar: string; salvar: string; excluir: string };
  novo: () => T;
  /** Colunas extras da tabela */
  colunas?: { titulo: string; valor: (i: T) => ReactNode }[];
  /** Campos extras do formulário */
  campos?: (form: T, set: (k: string, v: unknown) => void) => ReactNode;
}) {
  const { pode } = useAuth();
  const podeEditar = pode(pagina, 'editar');
  const toast = useToast();
  const [lista, setLista] = useState<T[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState<T | null>(null);
  const [erroModal, setErroModal] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [excluindo, setExcluindo] = useState<string | null>(null);

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setLista(await api<T[]>(rpc.listar));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar.');
    }
  }, [rpc.listar]);
  useEffect(() => { carregar(); }, [carregar]);

  const set = (k: string, v: unknown) => setModal((m) => (m ? { ...m, [k]: v } : m));

  const salvar = async () => {
    if (!modal) return;
    setErroModal(null);
    setSalvando(true);
    try {
      const dados: Record<string, unknown> = { ...modal };
      delete dados.em_uso;
      await api(rpc.salvar, { p_dados: dados });
      toast(modal.id ? 'Alteração salva.' : `${nomeItem[0].toUpperCase()}${nomeItem.slice(1)} cadastrado.`);
      setModal(null);
      carregar();
    } catch (e) {
      setErroModal(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const excluir = async (i: T) => {
    try {
      await api(rpc.excluir, { p_id: i.id });
      toast('Excluído.');
      setExcluindo(null);
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
      setExcluindo(null);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">{titulo}</h2>
          <p className="mt-1 text-sm text-slate-500">{descricao}</p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={() => { setErroModal(null); setModal(novo()); }}>
            <Plus className="h-4 w-4" /> Novo {nomeItem}
          </Button>
        )}
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {lista === null ? (
        <div className="card h-64 animate-pulse" />
      ) : lista.length === 0 ? (
        <div className="card"><EmptyState icon={icon} titulo={`Nenhum ${nomeItem} cadastrado`} descricao={`Clique em "Novo ${nomeItem}" para cadastrar.`} /></div>
      ) : (
        <div className="card overflow-x-auto">
          <table className="w-full min-w-[640px] text-sm">
            <thead>
              <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                <th className="px-5 py-2.5 font-medium">Descrição</th>
                {colunas?.map((c) => <th key={c.titulo} className="px-5 py-2.5 font-medium">{c.titulo}</th>)}
                <th className="px-5 py-2.5 font-medium">Lançamentos</th>
                <th className="px-5 py-2.5 font-medium">Situação</th>
                <th className="w-28 px-3 py-2.5" />
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {lista.map((i) => (
                <tr key={i.id} className="group hover:bg-primary-50/30">
                  <td className="px-5 py-3 font-medium text-slate-800">{i.descricao}</td>
                  {colunas?.map((c) => <td key={c.titulo} className="px-5 py-3 text-slate-600">{c.valor(i)}</td>)}
                  <td className="px-5 py-3 tabular-nums text-slate-500">{i.em_uso || '—'}</td>
                  <td className="px-5 py-3">
                    <Badge tone={i.ativo ? 'green' : 'slate'} dot={false}>{i.ativo ? 'Ativo' : 'Inativo'}</Badge>
                  </td>
                  <td className="px-3 py-3 text-right">
                    {podeEditar && (excluindo === i.id ? (
                      <span className="flex items-center justify-end gap-1 text-xs">
                        <button className="rounded-lg px-2 py-1 font-medium text-rose-600 hover:bg-rose-50" onClick={() => excluir(i)}>Excluir</button>
                        <button className="rounded-lg px-2 py-1 text-slate-500 hover:bg-slate-100" onClick={() => setExcluindo(null)}>Não</button>
                      </span>
                    ) : (
                      <span className="flex justify-end gap-1 opacity-60 transition group-hover:opacity-100">
                        <button className="rounded-lg p-1.5 text-slate-400 hover:bg-white hover:text-primary-600" aria-label="Alterar"
                          onClick={() => { setErroModal(null); setModal({ ...i }); }}>
                          <Pencil className="h-4 w-4" />
                        </button>
                        <button
                          className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600 disabled:cursor-not-allowed disabled:opacity-30"
                          aria-label="Excluir"
                          disabled={!!i.em_uso}
                          title={i.em_uso ? 'Já foi lançado: não pode ser excluído. Desative-o.' : 'Excluir'}
                          onClick={() => setExcluindo(i.id ?? null)}>
                          <Trash2 className="h-4 w-4" />
                        </button>
                      </span>
                    ))}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <Modal
        aberto={!!modal}
        onFechar={() => setModal(null)}
        titulo={modal?.id ? `Alterar ${nomeItem}` : `Novo ${nomeItem}`}
        rodape={
          <>
            <Button variant="secondary" onClick={() => setModal(null)}>Cancelar</Button>
            {podeEditar && <Button onClick={salvar} loading={salvando}>Salvar</Button>}
          </>
        }
      >
        {modal && (
          <fieldset disabled={!podeEditar} className="space-y-4">
            <AlertaErro mensagem={erroModal} />
            <Field label="Descrição" obrigatorio>
              <input className="input" value={modal.descricao} autoFocus onChange={(e) => set('descricao', e.target.value)} />
            </Field>
            {campos?.(modal, set)}
            <Switch ativo={modal.ativo} onChange={(v) => set('ativo', v)} label="Ativo"
              descricao="Inativos não aparecem para novos lançamentos, mas continuam nos já feitos." />
          </fieldset>
        )}
      </Modal>
    </div>
  );
}
