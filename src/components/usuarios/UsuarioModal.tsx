import { useEffect, useMemo, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { ABRANGENCIAS, STATUS_USUARIO } from '@/lib/acesso';
import { api } from '@/lib/supabase';
import type { StatusUsuario, UsuarioSistema, UsuariosDados } from '@/lib/types';

interface Form {
  nome: string;
  login: string;
  email: string;
  perfil_id: string;
  colaborador_id: string;
  status: StatusUsuario;
  senha: string;
  trocar_senha: boolean;
}

export function UsuarioModal({
  aberto,
  usuario,
  dados,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  usuario: UsuarioSistema | null;
  dados: UsuariosDados;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<Form | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const proprio = usuario?.id === dados.eu;

  useEffect(() => {
    if (!aberto) return;
    setErro(null);
    const perfilColaborador = dados.perfis.find((p) => p.nome === 'Colaborador') ?? dados.perfis.find((p) => !p.is_admin);
    setForm(
      usuario
        ? {
            nome: usuario.nome,
            login: usuario.login,
            email: usuario.email ?? '',
            perfil_id: usuario.perfil_id,
            colaborador_id: usuario.colaborador_id ?? '',
            status: usuario.status,
            senha: '',
            trocar_senha: true,
          }
        : {
            nome: '',
            login: '',
            email: '',
            perfil_id: perfilColaborador?.id ?? '',
            colaborador_id: '',
            status: 'ativo',
            senha: '',
            trocar_senha: true,
          },
    );
  }, [aberto, usuario, dados]);

  // Colaboradores livres + o já vinculado a este usuário
  const colaboradores = useMemo(
    () => dados.colaboradores.filter((c) => !c.usuario_id || c.usuario_id === usuario?.id),
    [dados.colaboradores, usuario],
  );

  if (!form) return null;
  const perfil = dados.perfis.find((p) => p.id === form.perfil_id);
  const exigeColaborador = !!perfil && !perfil.is_admin && perfil.abrangencia !== 'todos';

  const escolherColaborador = (id: string) => {
    const c = dados.colaboradores.find((x) => x.id === id);
    setForm({
      ...form,
      colaborador_id: id,
      // Ao vincular, sugere nome, login (matrícula) e e-mail do cadastro
      nome: c && (!form.nome || !usuario) ? c.nome : form.nome,
      login: c && !form.login ? c.matricula : form.login,
      email: c && !form.email ? (c.email ?? '') : form.email,
    });
  };

  const salvar = async () => {
    setErro(null);
    setSalvando(true);
    try {
      await api('api_usuario_salvar', {
        p_dados: { ...form, id: usuario?.id ?? null, colaborador_id: form.colaborador_id || null },
      });
      toast(usuario ? 'Usuário atualizado.' : 'Usuário criado.');
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
      titulo={usuario ? `Editar acesso — ${usuario.nome}` : 'Novo usuário'}
      descricao="Cada colaborador tem o próprio login e só registra o próprio ponto."
      largura="max-w-2xl"
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          <Button onClick={salvar} loading={salvando}>Salvar</Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <div className="grid gap-4 sm:grid-cols-2">
        <Field
          label="Colaborador vinculado"
          obrigatorio={exigeColaborador}
          className="sm:col-span-2"
          dica="O ponto registrado por este login é sempre o deste colaborador."
        >
          <select className="input" value={form.colaborador_id} onChange={(e) => escolherColaborador(e.target.value)}>
            <option value="">— Sem vínculo (usuário administrativo) —</option>
            {colaboradores.map((c) => (
              <option key={c.id} value={c.id}>
                {c.nome} · mat. {c.matricula}{c.departamento ? ` · ${c.departamento}` : ''}
              </option>
            ))}
          </select>
        </Field>
        <Field label="Nome" obrigatorio>
          <input className="input" value={form.nome} onChange={(e) => setForm({ ...form, nome: e.target.value })} />
        </Field>
        <Field label="Login" obrigatorio dica="Sugestão: a matrícula do colaborador.">
          <input className="input" value={form.login} autoComplete="off"
            onChange={(e) => setForm({ ...form, login: e.target.value.replace(/\s/g, '') })} />
        </Field>
        <Field label="E-mail" dica="Também pode ser usado para entrar.">
          <input type="email" className="input" value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} />
        </Field>
        <Field label="Situação" obrigatorio>
          <select className="input" value={form.status} disabled={proprio}
            onChange={(e) => setForm({ ...form, status: e.target.value as StatusUsuario })}>
            {Object.entries(STATUS_USUARIO).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
          </select>
        </Field>
        <Field label="Perfil de acesso" obrigatorio className="sm:col-span-2"
          dica={perfil ? (perfil.is_admin ? 'Acesso total a todas as telas e colaboradores.' : ABRANGENCIAS[perfil.abrangencia].descricao) : undefined}>
          <select className="input" value={form.perfil_id} disabled={proprio}
            onChange={(e) => setForm({ ...form, perfil_id: e.target.value })}>
            {dados.perfis.map((p) => (
              <option key={p.id} value={p.id}>
                {p.nome} — {p.is_admin ? 'acesso total' : ABRANGENCIAS[p.abrangencia].label.toLowerCase()}
              </option>
            ))}
          </select>
        </Field>
        <Field
          label={usuario ? 'Redefinir senha' : 'Senha inicial'}
          obrigatorio={!usuario}
          dica={usuario ? 'Deixe em branco para manter a senha atual.' : 'Mínimo de 6 caracteres.'}
        >
          <input type="text" className="input" value={form.senha} autoComplete="new-password"
            onChange={(e) => setForm({ ...form, senha: e.target.value })} />
        </Field>
        <div className="flex items-end">
          {(form.senha || !usuario) && (
            <Switch
              ativo={form.trocar_senha}
              onChange={(v) => setForm({ ...form, trocar_senha: v })}
              label="Exigir troca no 1º acesso"
              descricao="O usuário cria a própria senha ao entrar."
            />
          )}
        </div>
      </div>
      {proprio && (
        <p className="mt-4 rounded-xl bg-slate-50 px-4 py-3 text-xs text-slate-500">
          Este é o seu usuário: o perfil e a situação não podem ser alterados por você.
        </p>
      )}
    </Modal>
  );
}
