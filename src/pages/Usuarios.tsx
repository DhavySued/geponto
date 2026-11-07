import clsx from 'clsx';
import { AlertTriangle, KeyRound, LogOut, Pencil, Search, ShieldCheck, Trash2, UserPlus, Users, Wand2 } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { GerarAcessosModal } from '@/components/usuarios/GerarAcessosModal';
import { PerfisPermissoes } from '@/components/usuarios/PerfisPermissoes';
import { UsuarioModal } from '@/components/usuarios/UsuarioModal';
import { ABRANGENCIAS, STATUS_USUARIO } from '@/lib/acesso';
import { iniciais } from '@/lib/format';
import { api } from '@/lib/supabase';
import type { UsuarioSistema, UsuariosDados } from '@/lib/types';

type Aba = 'usuarios' | 'perfis';

function ultimoAcesso(s: string | null) {
  if (!s) return 'Nunca acessou';
  return new Date(s).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: '2-digit', hour: '2-digit', minute: '2-digit' });
}

export default function Usuarios() {
  const toast = useToast();
  const [aba, setAba] = useState<Aba>('usuarios');
  const [dados, setDados] = useState<UsuariosDados | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [busca, setBusca] = useState('');
  const [filtroPerfil, setFiltroPerfil] = useState('');
  const [filtroStatus, setFiltroStatus] = useState('');
  const [modal, setModal] = useState<{ aberto: boolean; usuario: UsuarioSistema | null }>({ aberto: false, usuario: null });
  const [gerar, setGerar] = useState(false);
  const [excluindo, setExcluindo] = useState<UsuarioSistema | null>(null);

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setDados(await api<UsuariosDados>('api_usuarios_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar os usuários.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const lista = useMemo(() => {
    const q = busca.trim().toLowerCase();
    return (dados?.usuarios ?? []).filter(
      (u) =>
        (!q || [u.nome, u.login, u.email, u.colaborador, u.matricula].some((x) => x?.toLowerCase().includes(q))) &&
        (!filtroPerfil || u.perfil_id === filtroPerfil) &&
        (!filtroStatus || (filtroStatus === 'trocar' ? u.trocar_senha : u.status === filtroStatus)),
    );
  }, [dados, busca, filtroPerfil, filtroStatus]);

  const semAcesso = dados?.colaboradores.filter((c) => !c.usuario_id).length ?? 0;

  const desconectar = async (u: UsuarioSistema) => {
    try {
      await api('api_usuario_desconectar', { p_id: u.id });
      toast(`Sessões de ${u.nome} encerradas.`);
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao desconectar.', 'erro');
    }
  };

  const excluir = async () => {
    if (!excluindo) return;
    try {
      await api('api_usuario_excluir', { p_id: excluindo.id });
      toast('Usuário excluído.');
      setExcluindo(null);
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao excluir.', 'erro');
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Usuários & Permissões</h2>
          <p className="mt-1 text-sm text-slate-500">
            Cada colaborador entra com o próprio login, registra somente o próprio ponto e vê apenas o que o perfil permite.
          </p>
        </div>
        {dados?.pode_editar && aba === 'usuarios' && (
          <div className="flex flex-wrap gap-2">
            <Button variant="secondary" onClick={() => setGerar(true)}>
              <Wand2 className="h-4 w-4" /> Gerar acessos{semAcesso > 0 ? ` (${semAcesso})` : ''}
            </Button>
            <Button variant="accent" onClick={() => setModal({ aberto: true, usuario: null })}>
              <UserPlus className="h-4 w-4" /> Novo usuário
            </Button>
          </div>
        )}
      </div>

      <div className="flex w-fit rounded-xl bg-white p-1 shadow-soft ring-1 ring-slate-200/70">
        {([
          ['usuarios', 'Usuários', Users],
          ['perfis', 'Perfis e permissões', ShieldCheck],
        ] as const).map(([k, label, Icon]) => (
          <button
            key={k}
            onClick={() => setAba(k)}
            className={clsx(
              'flex items-center gap-2 rounded-lg px-3.5 py-1.5 text-sm font-medium transition',
              aba === k ? 'bg-primary-700 text-white' : 'text-slate-500 hover:text-slate-800',
            )}
          >
            <Icon className="h-4 w-4" /> {label}
          </button>
        ))}
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {!dados ? (
        !erro && <div className="card h-72 animate-pulse" />
      ) : aba === 'perfis' ? (
        <PerfisPermissoes dados={dados} onAlterado={carregar} />
      ) : (
        <section className="card overflow-hidden">
          <div className="flex flex-col gap-3 border-b border-slate-100 p-4 sm:flex-row">
            <div className="relative flex-1">
              <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
              <input className="input pl-9" placeholder="Buscar por nome, login, matrícula ou e-mail" value={busca}
                onChange={(e) => setBusca(e.target.value)} />
            </div>
            <select className="input sm:w-48" value={filtroPerfil} onChange={(e) => setFiltroPerfil(e.target.value)}>
              <option value="">Todos os perfis</option>
              {dados.perfis.map((p) => <option key={p.id} value={p.id}>{p.nome}</option>)}
            </select>
            <select className="input sm:w-48" value={filtroStatus} onChange={(e) => setFiltroStatus(e.target.value)}>
              <option value="">Todas as situações</option>
              {Object.entries(STATUS_USUARIO).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
              <option value="trocar">Aguardando 1º acesso</option>
            </select>
          </div>

          {lista.length === 0 ? (
            <EmptyState icon={Users} titulo="Nenhum usuário encontrado" descricao="Ajuste a busca ou os filtros." compacto />
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[860px] text-sm">
                <thead className="bg-slate-50/70 text-left text-xs text-slate-500">
                  <tr>
                    <th className="px-5 py-2.5 font-medium">Usuário</th>
                    <th className="px-3 py-2.5 font-medium">Colaborador vinculado</th>
                    <th className="px-3 py-2.5 font-medium">Perfil</th>
                    <th className="px-3 py-2.5 font-medium">Situação</th>
                    <th className="px-3 py-2.5 font-medium">Último acesso</th>
                    <th className="w-32 px-5 py-2.5" />
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {lista.map((u) => (
                    <tr key={u.id} className="group hover:bg-slate-50/60">
                      <td className="px-5 py-3">
                        <div className="flex items-center gap-3">
                          <span className={clsx('flex h-9 w-9 shrink-0 items-center justify-center rounded-lg text-xs font-semibold',
                            u.is_admin ? 'bg-accent-100 text-accent-700' : 'bg-primary-50 text-primary-700')}>
                            {iniciais(u.nome)}
                          </span>
                          <div className="min-w-0">
                            <p className="truncate font-medium text-slate-800">
                              {u.nome}
                              {u.id === dados.eu && <span className="ml-1.5 text-xs font-normal text-slate-400">(você)</span>}
                            </p>
                            <p className="truncate font-mono text-xs text-slate-400">{u.login}</p>
                          </div>
                        </div>
                      </td>
                      <td className="px-3 py-3 text-slate-600">
                        {u.colaborador ? (
                          <>
                            <p className="truncate">{u.colaborador}</p>
                            <p className="text-xs text-slate-400">mat. {u.matricula}</p>
                          </>
                        ) : (
                          <span className="text-xs text-slate-400">Sem vínculo</span>
                        )}
                      </td>
                      <td className="px-3 py-3">
                        <p className="font-medium text-slate-700">{u.perfil}</p>
                        <p className="text-xs text-slate-400">{u.is_admin ? 'Acesso total' : ABRANGENCIAS[u.abrangencia].label}</p>
                      </td>
                      <td className="px-3 py-3">
                        <div className="flex flex-col items-start gap-1">
                          <Badge tone={u.bloqueado ? 'red' : STATUS_USUARIO[u.status].tone}>
                            {u.bloqueado ? 'Bloqueado (tentativas)' : STATUS_USUARIO[u.status].label}
                          </Badge>
                          {u.trocar_senha && (
                            <span className="flex items-center gap-1 text-[11px] text-accent-700">
                              <KeyRound className="h-3 w-3" /> Aguardando 1º acesso
                            </span>
                          )}
                        </div>
                      </td>
                      <td className="px-3 py-3 text-xs text-slate-500">
                        {ultimoAcesso(u.ultimo_acesso)}
                        {u.sessoes > 0 && <p className="text-emerald-600">{u.sessoes} sessão(ões) aberta(s)</p>}
                      </td>
                      <td className="px-5 py-3">
                        {dados.pode_editar && (
                          <div className="flex justify-end gap-1 opacity-70 transition group-hover:opacity-100">
                            <button className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-primary-600"
                              title="Editar acesso" aria-label="Editar acesso" onClick={() => setModal({ aberto: true, usuario: u })}>
                              <Pencil className="h-4 w-4" />
                            </button>
                            {u.sessoes > 0 && u.id !== dados.eu && (
                              <button className="rounded-lg p-1.5 text-slate-400 hover:bg-slate-100 hover:text-primary-600"
                                title="Encerrar sessões abertas" aria-label="Encerrar sessões" onClick={() => desconectar(u)}>
                                <LogOut className="h-4 w-4" />
                              </button>
                            )}
                            {u.id !== dados.eu && (
                              <button className="rounded-lg p-1.5 text-slate-400 hover:bg-rose-50 hover:text-rose-600"
                                title="Excluir usuário" aria-label="Excluir usuário" onClick={() => setExcluindo(u)}>
                                <Trash2 className="h-4 w-4" />
                              </button>
                            )}
                          </div>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      )}

      {dados && (
        <>
          <UsuarioModal
            aberto={modal.aberto}
            usuario={modal.usuario}
            dados={dados}
            onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
            onSalvo={() => {
              setModal({ aberto: false, usuario: null });
              carregar();
            }}
          />
          <GerarAcessosModal aberto={gerar} dados={dados} onFechar={() => setGerar(false)} onGerado={carregar} />
        </>
      )}

      <Modal
        aberto={!!excluindo}
        onFechar={() => setExcluindo(null)}
        titulo="Excluir usuário"
        largura="max-w-md"
        rodape={
          <>
            <Button variant="secondary" onClick={() => setExcluindo(null)}>Cancelar</Button>
            <Button className="bg-rose-600 hover:bg-rose-700" onClick={excluir}>Excluir</Button>
          </>
        }
      >
        <p className="text-sm text-slate-600">
          O acesso de <strong>{excluindo?.nome}</strong> será removido. As batidas e o histórico do colaborador são mantidos.
          Para apenas suspender o acesso, edite o usuário e marque a situação como <em>Inativo</em>.
        </p>
      </Modal>
    </div>
  );
}
