import { CheckCircle2, Copy } from 'lucide-react';
import { useEffect, useMemo, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { api } from '@/lib/supabase';
import type { ResultadoAcessos, UsuariosDados } from '@/lib/types';

/** Cria de uma vez o login de cada colaborador que ainda não tem acesso. */
export function GerarAcessosModal({
  aberto,
  dados,
  onFechar,
  onGerado,
}: {
  aberto: boolean;
  dados: UsuariosDados;
  onFechar: () => void;
  onGerado: () => void;
}) {
  const toast = useToast();
  const semAcesso = useMemo(() => dados.colaboradores.filter((c) => !c.usuario_id), [dados.colaboradores]);
  const [selecionados, setSelecionados] = useState<Set<string>>(new Set());
  const [modoLogin, setModoLogin] = useState<'matricula' | 'cpf'>('matricula');
  const [senha, setSenha] = useState('');
  const [perfil, setPerfil] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [gerando, setGerando] = useState(false);
  const [resultado, setResultado] = useState<ResultadoAcessos | null>(null);

  useEffect(() => {
    if (!aberto) return;
    setSelecionados(new Set(semAcesso.map((c) => c.id)));
    setSenha('');
    setErro(null);
    setResultado(null);
    setPerfil(dados.perfis.find((p) => p.nome === 'Colaborador')?.id ?? '');
    // Só ao abrir: depois de gerar, a lista recarrega e o resultado precisa continuar na tela
  }, [aberto]);

  const alternar = (id: string) =>
    setSelecionados((s) => {
      const n = new Set(s);
      if (n.has(id)) n.delete(id);
      else n.add(id);
      return n;
    });

  const gerar = async () => {
    setErro(null);
    setGerando(true);
    try {
      const r = await api<ResultadoAcessos>('api_acessos_gerar', {
        p_colaboradores: [...selecionados],
        p_senha: senha,
        p_perfil: perfil || null,
        p_login: modoLogin,
      });
      setResultado(r);
      onGerado();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao gerar os acessos.');
    } finally {
      setGerando(false);
    }
  };

  const copiar = async () => {
    if (!resultado) return;
    const texto = ['Colaborador;Login;Senha inicial', ...resultado.criados.map((c) => `${c.nome};${c.login};${senha}`)].join('\n');
    try {
      await navigator.clipboard.writeText(texto);
      toast('Lista copiada. Cole numa planilha para entregar aos colaboradores.');
    } catch {
      toast('Não foi possível copiar.', 'erro');
    }
  };

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      titulo="Gerar acessos dos colaboradores"
      descricao="Cada colaborador recebe um login próprio e cria a sua senha pessoal no primeiro acesso."
      largura="max-w-2xl"
      rodape={
        resultado ? (
          <>
            {resultado.criados.length > 0 && (
              <Button variant="secondary" onClick={copiar}><Copy className="h-4 w-4" /> Copiar lista</Button>
            )}
            <Button onClick={onFechar}>Concluir</Button>
          </>
        ) : (
          <>
            <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
            <Button onClick={gerar} loading={gerando} disabled={selecionados.size === 0}>
              Gerar {selecionados.size} acesso(s)
            </Button>
          </>
        )
      }
    >
      <AlertaErro mensagem={erro} />
      {resultado ? (
        <div className="space-y-4">
          <div className="flex items-center gap-3 rounded-xl bg-emerald-50 px-4 py-3 text-sm text-emerald-800 ring-1 ring-emerald-200">
            <CheckCircle2 className="h-5 w-5 shrink-0" />
            {resultado.criados.length} acesso(s) criado(s). Entregue o login e a senha inicial a cada colaborador.
          </div>
          {resultado.criados.length > 0 && (
            <div className="max-h-64 overflow-y-auto rounded-xl ring-1 ring-slate-200">
              <table className="w-full text-sm">
                <thead className="sticky top-0 bg-slate-50 text-left text-xs text-slate-500">
                  <tr><th className="px-4 py-2 font-medium">Colaborador</th><th className="px-4 py-2 font-medium">Login</th></tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {resultado.criados.map((c) => (
                    <tr key={c.login}><td className="px-4 py-2 text-slate-700">{c.nome}</td><td className="px-4 py-2 font-mono text-slate-900">{c.login}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          {resultado.ignorados.length > 0 && (
            <div className="text-xs text-slate-500">
              <p className="mb-1 font-medium text-slate-600">Não gerados:</p>
              <ul className="list-inside list-disc space-y-0.5">
                {resultado.ignorados.map((i) => <li key={i.nome}>{i.nome} — {i.motivo}</li>)}
              </ul>
            </div>
          )}
        </div>
      ) : semAcesso.length === 0 ? (
        <p className="rounded-xl bg-slate-50 px-4 py-6 text-center text-sm text-slate-500">
          Todos os colaboradores ativos já têm acesso ao sistema.
        </p>
      ) : (
        <div className="space-y-4">
          <div className="grid gap-4 sm:grid-cols-3">
            <Field label="Login" obrigatorio>
              <select className="input" value={modoLogin} onChange={(e) => setModoLogin(e.target.value as 'matricula' | 'cpf')}>
                <option value="matricula">Matrícula</option>
                <option value="cpf">CPF (só números)</option>
              </select>
            </Field>
            <Field label="Senha inicial" obrigatorio dica="Igual para todos; troca obrigatória.">
              <input className="input" value={senha} onChange={(e) => setSenha(e.target.value)} autoComplete="new-password" />
            </Field>
            <Field label="Perfil" obrigatorio>
              <select className="input" value={perfil} onChange={(e) => setPerfil(e.target.value)}>
                {dados.perfis.filter((p) => !p.is_admin).map((p) => <option key={p.id} value={p.id}>{p.nome}</option>)}
              </select>
            </Field>
          </div>
          <div className="rounded-xl ring-1 ring-slate-200">
            <label className="flex items-center gap-3 border-b border-slate-100 bg-slate-50 px-4 py-2 text-xs font-medium text-slate-600">
              <input
                type="checkbox"
                className="h-4 w-4 rounded border-slate-300 text-primary-700"
                checked={selecionados.size === semAcesso.length}
                onChange={(e) => setSelecionados(new Set(e.target.checked ? semAcesso.map((c) => c.id) : []))}
              />
              {semAcesso.length} colaborador(es) sem acesso
            </label>
            <ul className="max-h-60 divide-y divide-slate-100 overflow-y-auto">
              {semAcesso.map((c) => (
                <li key={c.id}>
                  <label className="flex cursor-pointer items-center gap-3 px-4 py-2 text-sm hover:bg-slate-50">
                    <input type="checkbox" className="h-4 w-4 rounded border-slate-300 text-primary-700"
                      checked={selecionados.has(c.id)} onChange={() => alternar(c.id)} />
                    <span className="flex-1 truncate text-slate-700">{c.nome}</span>
                    <span className="font-mono text-xs text-slate-400">
                      {modoLogin === 'cpf' ? c.cpf.replace(/\D/g, '') : c.matricula}
                    </span>
                  </label>
                </li>
              ))}
            </ul>
          </div>
        </div>
      )}
    </Modal>
  );
}
