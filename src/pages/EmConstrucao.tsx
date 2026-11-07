import { Construction } from 'lucide-react';
import { EmptyState } from '@/components/ui/EmptyState';
import type { NavItem } from '@/lib/navigation';

/** Placeholder dos módulos ainda não implementados — mantém a navegação completa. */
export default function EmConstrucao({ pagina }: { pagina: NavItem }) {
  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">{pagina.titulo}</h2>
        <p className="mt-1 text-sm text-slate-500">{pagina.descricao}</p>
      </div>
      <div className="card">
        <EmptyState
          icon={Construction}
          titulo="Módulo em desenvolvimento"
          descricao="A estrutura de navegação e as permissões desta página já estão prontas. A interface será entregue na próxima etapa."
        />
      </div>
    </div>
  );
}
