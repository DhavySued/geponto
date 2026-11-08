import clsx from 'clsx';
import { AlertTriangle, Pencil, Plus, SlidersHorizontal, Users } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { PerfilEventoModal } from '@/components/perfis/PerfilEventoModal';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { useAuth } from '@/contexts/AuthContext';
import { DIAS_HE, textoPercentual } from '@/lib/perfilEvento';
import { api } from '@/lib/supabase';
import type { PerfilEvento } from '@/lib/types';

function PerfilCard({ p, onAbrir }: { p: PerfilEvento; onAbrir: () => void }) {
  const pct = (dia: number) => p.he.find((h) => h.dia === dia)?.percentual ?? 0;
  return (
    <button
      onClick={onAbrir}
      className={clsx('card group flex flex-col p-5 text-left transition hover:-translate-y-0.5 hover:shadow-lg', !p.ativo && 'opacity-70')}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-[15px] font-semibold text-slate-900">{p.nome}</p>
          {p.descricao && <p className="mt-0.5 line-clamp-1 text-xs text-slate-500">{p.descricao}</p>}
        </div>
        <div className="flex shrink-0 gap-1.5">
          {p.padrao && <Badge tone="orange" dot={false}>Padrão</Badge>}
          {p.ativo ? <Badge tone="green">Ativo</Badge> : <Badge tone="slate">Inativo</Badge>}
        </div>
      </div>

      <p className="mt-4 text-[11px] font-medium uppercase tracking-wide text-slate-400">Hora extra</p>
      <div className="mt-1.5 grid grid-cols-8 gap-1">
        {DIAS_HE.map((d) => (
          <span
            key={d.dia}
            title={`${d.nome}: ${textoPercentual(pct(d.dia))}`}
            className={clsx(
              'flex flex-col items-center rounded-md py-1 text-[10px]',
              pct(d.dia) >= 100 ? 'bg-primary-700 text-white' : 'bg-primary-50 text-primary-800',
            )}
          >
            <span className="opacity-70">{d.curto}</span>
            <span className="font-semibold tabular-nums">{Number(pct(d.dia))}</span>
          </span>
        ))}
      </div>

      <ul className="mt-4 space-y-1 text-xs text-slate-500">
        <li>
          Tolerância: entrada {p.tolerancia_entrada_min} min · saída {p.tolerancia_saida_min} min · geral {p.tolerancia_diaria_min} min
        </li>
        <li>
          {p.usa_banco_horas ? 'Banco de horas' : 'Sem banco de horas (extras e faltas na folha)'}
          {p.limite_he_diario_min > 0 && ` · limite de HE ${p.limite_he_diario_min} min/dia`}
        </li>
        <li>
          Noturno {p.noturno_inicio}–{p.noturno_fim} · {textoPercentual(p.percentual_noturno)}
          {p.hora_noturna_reduzida && ' · hora reduzida'}
        </li>
      </ul>

      <div className="mt-5 flex items-center justify-between border-t border-slate-100 pt-4 text-xs text-slate-500">
        <span className="flex items-center gap-1.5">
          <Users className="h-3.5 w-3.5" />
          {p.colaboradores ?? 0} colaborador{p.colaboradores === 1 ? '' : 'es'}
        </span>
        <Pencil className="h-3.5 w-3.5 text-slate-300 transition group-hover:text-primary-600" />
      </div>
    </button>
  );
}

export default function PerfisEventos() {
  const { pode } = useAuth();
  const podeEditar = pode('perfis_eventos', 'editar');
  const [perfis, setPerfis] = useState<PerfilEvento[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState<{ aberto: boolean; perfil: PerfilEvento | null }>({ aberto: false, perfil: null });

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setPerfis(await api<PerfilEvento[]>('api_perfis_eventos_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar os perfis.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const novo = () => setModal({ aberto: true, perfil: null });

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Perfis de eventos</h2>
          <p className="mt-1 text-sm text-slate-500">
            Regras de cálculo do ponto de cada colaborador: tolerâncias, percentual de hora extra por dia, adicional noturno e banco de horas.
          </p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={novo}>
            <Plus className="h-4 w-4" /> Novo perfil
          </Button>
        )}
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {perfis === null && !erro ? (
        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
          {Array.from({ length: 3 }, (_, i) => (
            <div key={i} className="card h-64 animate-pulse" />
          ))}
        </div>
      ) : perfis && perfis.length === 0 ? (
        <div className="card">
          <EmptyState icon={SlidersHorizontal} titulo="Nenhum perfil cadastrado" descricao="Cadastre as regras de cálculo e vincule cada colaborador a um perfil." />
        </div>
      ) : (
        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
          {perfis?.map((p) => (
            <PerfilCard key={p.id} p={p} onAbrir={() => setModal({ aberto: true, perfil: p })} />
          ))}
        </div>
      )}

      <PerfilEventoModal
        aberto={modal.aberto}
        perfil={modal.perfil}
        podeEditar={podeEditar}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal({ aberto: false, perfil: null });
          carregar();
        }}
      />
    </div>
  );
}
