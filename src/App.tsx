import type { ReactNode } from 'react';
import { BrowserRouter, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { AppLayout } from '@/components/layout/AppLayout';
import { ToastProvider } from '@/components/ui/Toast';
import { AuthProvider, useAuth } from '@/contexts/AuthContext';
import { TODAS_PAGINAS } from '@/lib/navigation';
import type { PaginaChave } from '@/lib/types';
import BancoHoras from '@/pages/BancoHoras';
import ConversaoBancoHoras from '@/pages/ConversaoBancoHoras';
import Colaboradores from '@/pages/Colaboradores';
import ConsultaBatidas from '@/pages/ConsultaBatidas';
import Dashboard from '@/pages/Dashboard';
import EmConstrucao from '@/pages/EmConstrucao';
import EspelhoPonto from '@/pages/EspelhoPonto';
import Fechamento from '@/pages/Fechamento';
import Feriados from '@/pages/Feriados';
import Jornadas from '@/pages/Jornadas';
import Login from '@/pages/Login';
import MeuPonto from '@/pages/MeuPonto';
import Ocorrencias from '@/pages/Ocorrencias';
import QuebraRegras from '@/pages/QuebraRegras';
import TotaisPeriodo from '@/pages/TotaisPeriodo';
import TratamentoBatidas from '@/pages/TratamentoBatidas';
import Usuarios from '@/pages/Usuarios';
import { AcessoNegado, NaoEncontrada, TelaCarregando } from '@/pages/Status';

/** Exige sessão válida; redireciona ao login guardando a rota de origem. */
function Protegido({ children }: { children: ReactNode }) {
  const { usuario, carregando } = useAuth();
  const location = useLocation();
  if (carregando) return <TelaCarregando />;
  if (!usuario) return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  return <>{children}</>;
}

/** Exige permissão de visualização na página (a API valida novamente no banco). */
function ComPermissao({ pagina, children }: { pagina: PaginaChave; children: ReactNode }) {
  const { pode, usuario } = useAuth();
  if (pode(pagina)) return <>{children}</>;
  // Sem acesso ao dashboard (ex.: perfil Colaborador): vai para a primeira página permitida
  if (pagina === 'dashboard') {
    const destino = TODAS_PAGINAS.find(
      (p) => pode(p.chave) && (p.chave !== 'meu_ponto' || !!usuario?.colaborador_id),
    );
    if (destino) return <Navigate to={destino.path} replace />;
  }
  return <AcessoNegado />;
}

// Páginas já implementadas; as demais usam o placeholder <EmConstrucao />
const PAGINAS: Partial<Record<PaginaChave, () => JSX.Element>> = {
  dashboard: Dashboard,
  colaboradores: Colaboradores,
  jornadas: Jornadas,
  meu_ponto: MeuPonto,
  banco_horas: BancoHoras,
  banco_horas_conversao: ConversaoBancoHoras,
  consulta_batidas: ConsultaBatidas,
  lancamento_manual: TratamentoBatidas,
  feriados: Feriados,
  ocorrencias: Ocorrencias,
  fechamento: Fechamento,
  espelho_ponto: EspelhoPonto,
  totais_periodo: TotaisPeriodo,
  quebra_regras: QuebraRegras,
  usuarios: Usuarios,
};

export default function App() {
  return (
    <AuthProvider>
      <ToastProvider>
        <BrowserRouter basename={import.meta.env.BASE_URL.replace(/\/$/, '')}>
          <Routes>
            <Route path="/login" element={<Login />} />
            <Route
              element={
                <Protegido>
                  <AppLayout />
                </Protegido>
              }
            >
              {TODAS_PAGINAS.map((p) => {
                const Componente = PAGINAS[p.chave];
                return (
                  <Route
                    key={p.chave}
                    path={p.path}
                    element={
                      <ComPermissao pagina={p.chave}>
                        {Componente ? <Componente /> : <EmConstrucao pagina={p} />}
                      </ComPermissao>
                    }
                  />
                );
              })}
              <Route path="*" element={<NaoEncontrada />} />
            </Route>
          </Routes>
        </BrowserRouter>
      </ToastProvider>
    </AuthProvider>
  );
}
