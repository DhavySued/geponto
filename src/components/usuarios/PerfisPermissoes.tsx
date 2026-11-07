import clsx from 'clsx';
import { Crown, Plus, ShieldCheck, Trash2, Users } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field } from '@/components/ui/Field';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { ABRANGENCIAS } from '@/lib/acesso';
import { NAVEGACAO } from '@/lib/navigation';
import { api } from '@/lib/supabase';
import type { Abrangencia, PerfilAcesso, Permissoes, UsuariosDados } from '@/lib/types';

interface Form {
  id: string | null;
  nome: string;
  descricao: string;
  abrangencia: Abrangencia;
  permissoes: Permissoes;
  is_admin: boolean;
}

const vazio: Form = { id: null, nome: '', descricao: '', abrangencia: 'proprio', permissoes: {}, is_admin: false };

const paraForm = (p: PerfilAcesso): Form => ({
  id: p.id,
  nome: p.nome,
  descricao: p.descricao ?? '',
  abrangencia: p.abrangencia,
  permissoes: p.permissoes,
  is_admin: p.is_admin,
});

export function PerfisPermissoes({ dados, onAlterado }: { dados: UsuariosDados; onAlterado: () => void }) {
  const toast = useToast();
  const { usuario, recarregar } = useAuth();
  const podeEditar = dados.pode_editar;
  const [selecionado, setSelecionado] = useState<string | null>(dados.perfis[0]?.id ?? null);
  const [form, setForm] = useState<Form>(vazio);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    setErro(null);
    const p = dados.perfis.find((x) => x.id === selecionado);
    setForm(p ? paraForm(p) : vazio);
  }, [selecionado, dados.perfis]);

  const bloqueado = form.is_admin || !podeEditar;

  const marcar = (chave: string, acao: 'visualizar' | 'editar', valor: boolean) => {
    setForm((f) => {
      const atual = f.permissoes[chave as keyof Permissoes] ?? { visualizar: false, editar: false };
      // Editar implica visualizar; tirar a visualização tira a edição
      const novo =
        acao === 'editar'
          ? { visualizar: valor || atual.visualizar, editar: valor }
          : { visualizar: valor, editar: valor && atual.editar };
      return { ...f, permissoes: { ...f.permissoes, [chave]: novo } };
    });
  };

  const marcarGrupo = (chaves: string[], acao: 'visualizar' | 'editar', valor: boolean) =>
    chaves.forEach((c) => marcar(c, acao, valor));

  const salvar = async () => {
    setErro(null);
    setSalvando(true);
    try {
      const r = await api<{ id: string }>('api_perfil_salvar', { p_dados: form });
      toast(form.id ? 'Perfil atualizado. Os usuários veem as mudanças no próximo carregamento.' : 'Perfil criado.');
      setSelecionado(r.id);
      onAlterado();
      if (form.id && form.id === usuario?.perfil.id) await recarregar();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar o perfil.');
    } finally {
      setSalvando(false);
    }
  };

  const excluir = async () => {
    if (!form.id) return;
    try {
      await api('api_perfil_excluir', { p_id: form.id });
      toast('Perfil excluído.');
      setSelecionado(dados.perfis.find((p) => p.id !== form.id)?.id ?? null);
      onAlterado();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    }
  };

  const perfilAtual = dados.perfis.find((p) => p.id === form.id);

  return (
    <div className="grid gap-6 lg:grid-cols-[280px_1fr]">
      {/* Lista de perfis */}
      <aside className="space-y-2">
        {dados.perfis.map((p) => (
          <button
            key={p.id}
            onClick={() => setSelecionado(p.id)}
            className={clsx(
              'flex w-full items-start gap-3 rounded-2xl p-3 text-left ring-1 transition',
              selecionado === p.id ? 'bg-primary-50 ring-primary-200' : 'bg-white ring-slate-200/70 hover:bg-slate-50',
            )}
          >
            <span className={clsx('mt-0.5 flex h-8 w-8 shrink-0 items-center justify-center rounded-lg',
              p.is_admin ? 'bg-accent-100 text-accent-700' : 'bg-primary-100 text-primary-700')}>
              {p.is_admin ? <Crown className="h-4 w-4" /> : <ShieldCheck className="h-4 w-4" />}
            </span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-sm font-semibold text-slate-800">{p.nome}</span>
              <span className="block text-xs text-slate-500">
                {p.is_admin ? 'Acesso total' : ABRANGENCIAS[p.abrangencia].label}
              </span>
            </span>
            <span className="flex items-center gap-1 text-xs text-slate-400" title="Usuários neste perfil">
              <Users className="h-3.5 w-3.5" /> {p.usuarios}
            </span>
          </button>
        ))}
        {podeEditar && (
          <Button variant="secondary" className="w-full" onClick={() => { setSelecionado(null); setForm(vazio); }}>
            <Plus className="h-4 w-4" /> Novo perfil
          </Button>
        )}
      </aside>

      {/* Editor */}
      <section className="card">
        <div className="space-y-5 p-5">
          <AlertaErro mensagem={erro} />
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label="Nome do perfil" obrigatorio>
              <input className="input" value={form.nome} disabled={!podeEditar}
                onChange={(e) => setForm({ ...form, nome: e.target.value })} />
            </Field>
            <Field label="Descrição">
              <input className="input" value={form.descricao} disabled={!podeEditar}
                onChange={(e) => setForm({ ...form, descricao: e.target.value })} />
            </Field>
          </div>

          {form.is_admin ? (
            <div className="flex items-start gap-3 rounded-xl bg-accent-50 px-4 py-3 text-sm text-accent-700 ring-1 ring-accent-200">
              <Crown className="mt-0.5 h-4 w-4 shrink-0" />
              O perfil Administrador tem acesso total a todas as telas e a todos os colaboradores. As permissões dele não podem ser restringidas.
            </div>
          ) : (
            <div>
              <p className="label">Quais colaboradores este perfil enxerga?</p>
              <div className="grid gap-2 sm:grid-cols-3">
                {(Object.keys(ABRANGENCIAS) as Abrangencia[]).map((a) => (
                  <button
                    key={a}
                    type="button"
                    disabled={!podeEditar}
                    onClick={() => setForm({ ...form, abrangencia: a })}
                    className={clsx(
                      'rounded-xl p-3 text-left ring-1 transition disabled:cursor-not-allowed',
                      form.abrangencia === a ? 'bg-primary-50 ring-2 ring-primary-500' : 'ring-slate-200 hover:bg-slate-50',
                    )}
                  >
                    <span className="block text-sm font-semibold text-slate-800">{ABRANGENCIAS[a].label}</span>
                    <span className="mt-0.5 block text-xs text-slate-500">{ABRANGENCIAS[a].descricao}</span>
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>

        {/* Matriz de permissões por tela */}
        <div className="border-t border-slate-100">
          <div className="grid grid-cols-[1fr_88px_88px] items-center bg-slate-50 px-5 py-2 text-[11px] font-medium uppercase tracking-wide text-slate-500">
            <span>Tela</span>
            <span className="text-center">Acessar</span>
            <span className="text-center">Alterar</span>
          </div>
          {NAVEGACAO.map((grupo) => {
            const chaves = grupo.itens.map((i) => i.chave);
            const todosVer = chaves.every((c) => form.is_admin || form.permissoes[c]?.visualizar);
            const todosEditar = chaves.every((c) => form.is_admin || form.permissoes[c]?.editar);
            return (
              <div key={grupo.titulo} className="border-t border-slate-100">
                <div className="grid grid-cols-[1fr_88px_88px] items-center px-5 py-2">
                  <span className="text-xs font-semibold text-slate-700">{grupo.titulo}</span>
                  <span className="text-center">
                    <input type="checkbox" className="h-4 w-4 rounded border-slate-300 text-primary-700" title="Marcar o grupo"
                      checked={todosVer} disabled={bloqueado} onChange={(e) => marcarGrupo(chaves, 'visualizar', e.target.checked)} />
                  </span>
                  <span className="text-center">
                    <input type="checkbox" className="h-4 w-4 rounded border-slate-300 text-primary-700" title="Marcar o grupo"
                      checked={todosEditar} disabled={bloqueado} onChange={(e) => marcarGrupo(chaves, 'editar', e.target.checked)} />
                  </span>
                </div>
                {grupo.itens.map((item) => {
                  const p = form.is_admin ? { visualizar: true, editar: true } : form.permissoes[item.chave];
                  return (
                    <div key={item.chave} className="grid grid-cols-[1fr_88px_88px] items-center px-5 py-2 hover:bg-slate-50/60">
                      <span className="flex min-w-0 items-center gap-2.5 pl-3">
                        <item.icon className="h-4 w-4 shrink-0 text-slate-400" />
                        <span className="min-w-0">
                          <span className="block truncate text-sm text-slate-700">{item.titulo}</span>
                          <span className="hidden truncate text-[11px] text-slate-400 sm:block">{item.descricao}</span>
                        </span>
                      </span>
                      <span className="text-center">
                        <input type="checkbox" className="h-4 w-4 rounded border-slate-300 text-primary-700"
                          aria-label={`Acessar ${item.titulo}`}
                          checked={!!p?.visualizar} disabled={bloqueado}
                          onChange={(e) => marcar(item.chave, 'visualizar', e.target.checked)} />
                      </span>
                      <span className="text-center">
                        <input type="checkbox" className="h-4 w-4 rounded border-slate-300 text-primary-700"
                          aria-label={`Alterar ${item.titulo}`}
                          checked={!!p?.editar} disabled={bloqueado}
                          onChange={(e) => marcar(item.chave, 'editar', e.target.checked)} />
                      </span>
                    </div>
                  );
                })}
              </div>
            );
          })}
          <p className="border-t border-slate-100 px-5 py-3 text-[11px] text-slate-400">
            Em “Meu Ponto”, “Alterar” permite registrar o ponto e enviar solicitações. Nas demais telas, permite incluir, editar e excluir.
          </p>
        </div>

        {podeEditar && (
          <footer className="flex items-center justify-between gap-2 border-t border-slate-100 bg-slate-50/60 px-5 py-4">
            {form.id && !form.is_admin ? (
              <Button variant="ghost" className="text-rose-600 hover:bg-rose-50" onClick={excluir}
                disabled={(perfilAtual?.usuarios ?? 0) > 0}
                title={(perfilAtual?.usuarios ?? 0) > 0 ? 'Mova os usuários para outro perfil antes de excluir' : undefined}>
                <Trash2 className="h-4 w-4" /> Excluir perfil
              </Button>
            ) : <span />}
            <Button onClick={salvar} loading={salvando}>{form.id ? 'Salvar alterações' : 'Criar perfil'}</Button>
          </footer>
        )}
      </section>
    </div>
  );
}
