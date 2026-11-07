import { KeyRound } from 'lucide-react';
import { useEffect, useState, type FormEvent } from 'react';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { api } from '@/lib/supabase';

/**
 * Troca da própria senha. Com `obrigatorio`, aparece logo após o login de quem recebeu
 * uma senha inicial do RH e não pode ser fechado sem trocar (só saindo do sistema).
 */
export function AlterarSenhaModal({
  aberto,
  obrigatorio = false,
  onFechar,
}: {
  aberto: boolean;
  obrigatorio?: boolean;
  onFechar: () => void;
}) {
  const { recarregar, sair } = useAuth();
  const toast = useToast();
  const [atual, setAtual] = useState('');
  const [nova, setNova] = useState('');
  const [confirmacao, setConfirmacao] = useState('');
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setAtual('');
    setNova('');
    setConfirmacao('');
    setErro(null);
  }, [aberto]);

  const salvar = async (e?: FormEvent) => {
    e?.preventDefault();
    setErro(null);
    if (nova !== confirmacao) {
      setErro('A confirmação não confere com a nova senha.');
      return;
    }
    setSalvando(true);
    try {
      const r = await api<{ ok: boolean; erro?: string }>('api_alterar_senha', {
        p_senha_atual: atual,
        p_nova_senha: nova,
      });
      if (!r.ok) {
        setErro(r.erro ?? 'Não foi possível alterar a senha.');
        return;
      }
      await recarregar();
      toast('Senha alterada. As outras sessões abertas foram encerradas.');
      onFechar();
    } catch (err) {
      setErro(err instanceof Error ? err.message : 'Não foi possível alterar a senha.');
    } finally {
      setSalvando(false);
    }
  };

  return (
    <Modal
      aberto={aberto}
      onFechar={obrigatorio ? () => {} : onFechar}
      fechavel={!obrigatorio}
      titulo={obrigatorio ? 'Crie a sua senha' : 'Alterar senha'}
      descricao={
        obrigatorio
          ? 'Você entrou com a senha inicial definida pelo RH. Para continuar, cadastre uma senha pessoal.'
          : 'Use ao menos 6 caracteres. Não compartilhe a sua senha: ela é a sua assinatura no registro de ponto.'
      }
      largura="max-w-md"
      rodape={
        <>
          {obrigatorio ? (
            <Button variant="ghost" onClick={sair}>Sair</Button>
          ) : (
            <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
          )}
          <Button onClick={() => salvar()} loading={salvando}>
            <KeyRound className="h-4 w-4" />
            Salvar senha
          </Button>
        </>
      }
    >
      <AlertaErro mensagem={erro} />
      <form onSubmit={salvar} className="space-y-4">
        <Field label={obrigatorio ? 'Senha inicial (recebida do RH)' : 'Senha atual'} obrigatorio>
          <input type="password" className="input" autoComplete="current-password" autoFocus
            value={atual} onChange={(e) => setAtual(e.target.value)} />
        </Field>
        <Field label="Nova senha" obrigatorio dica="Mínimo de 6 caracteres, diferente da atual.">
          <input type="password" className="input" autoComplete="new-password"
            value={nova} onChange={(e) => setNova(e.target.value)} />
        </Field>
        <Field label="Confirme a nova senha" obrigatorio>
          <input type="password" className="input" autoComplete="new-password"
            value={confirmacao} onChange={(e) => setConfirmacao(e.target.value)} />
        </Field>
        <button type="submit" className="hidden" />
      </form>
    </Modal>
  );
}
