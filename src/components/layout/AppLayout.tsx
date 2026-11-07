import { useState } from 'react';
import { Outlet } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { AlterarSenhaModal } from './AlterarSenhaModal';
import { MenuSuperior } from './MenuSuperior';

export function AppLayout() {
  const [alterarSenha, setAlterarSenha] = useState(false);
  const { usuario } = useAuth();

  return (
    <div className="min-h-screen">
      <MenuSuperior onAlterarSenha={() => setAlterarSenha(true)} />
      <AlterarSenhaModal
        aberto={alterarSenha || !!usuario?.trocar_senha}
        obrigatorio={!!usuario?.trocar_senha}
        onFechar={() => setAlterarSenha(false)}
      />
      <main className="mx-auto w-full max-w-[1440px] px-4 py-6 sm:px-6 lg:px-8 lg:py-8 print:max-w-none print:p-0">
        <Outlet />
      </main>
    </div>
  );
}
