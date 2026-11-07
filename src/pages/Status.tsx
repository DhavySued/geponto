import { Compass, ShieldAlert } from 'lucide-react';
import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';

export function AcessoNegado() {
  return (
    <div className="card">
      <EmptyState
        icon={ShieldAlert}
        titulo="Acesso não permitido"
        descricao="Seu perfil não tem permissão para esta página. Solicite acesso ao administrador do sistema."
      />
    </div>
  );
}

export function NaoEncontrada() {
  return (
    <div className="card">
      <EmptyState
        icon={Compass}
        titulo="Página não encontrada"
        descricao="O endereço acessado não existe ou foi movido."
        acao={
          <Link to="/">
            <Button variant="primary">Voltar ao início</Button>
          </Link>
        }
      />
    </div>
  );
}

export function TelaCarregando() {
  return (
    <div className="flex min-h-screen items-center justify-center">
      <div className="flex flex-col items-center gap-3">
        <div className="h-10 w-10 animate-spin rounded-full border-[3px] border-primary-100 border-t-accent-500" />
        <p className="text-sm text-slate-500">Carregando…</p>
      </div>
    </div>
  );
}
