import clsx from 'clsx';
import { AlertTriangle, CalendarClock, Pencil, Plus, Users } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { JornadaModal } from '@/components/jornadas/JornadaModal';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { useAuth } from '@/contexts/AuthContext';
import { formatMinutos } from '@/lib/format';
import { DIAS_CURTOS, horarioTexto, resumoEscala } from '@/lib/jornada';
import { api } from '@/lib/supabase';
import type { Jornada } from '@/lib/types';

function JornadaCard({ j, onAbrir }: { j: Jornada; onAbrir: () => void }) {
  const ehEscala = j.tipo === 'escala';
  const escala = ehEscala
    ? j.dias.filter((d) => !d.folga).slice(0, 3).map((d) => ({ dias: `Dia ${d.dia_semana + 1}`, horario: horarioTexto(d) }))
    : resumoEscala(j.dias);
  return (
    <button
      onClick={onAbrir}
      className={clsx(
        'card group flex flex-col p-5 text-left transition hover:-translate-y-0.5 hover:shadow-lg',
        !j.ativo && 'opacity-70',
      )}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-[15px] font-semibold text-slate-900">{j.nome}</p>
          {j.descricao && <p className="mt-0.5 line-clamp-1 text-xs text-slate-500">{j.descricao}</p>}
        </div>
        <div className="flex shrink-0 gap-1.5">
          {ehEscala && <Badge tone="violet" dot={false}>Escala {j.dias.length}d</Badge>}
          {j.ativo ? <Badge tone="green">Ativa</Badge> : <Badge tone="slate">Inativa</Badge>}
        </div>
      </div>

      <div className="mt-4 flex items-end gap-2">
        <p className="text-2xl font-semibold tracking-tight text-primary-700">{formatMinutos(j.minutos_semana ?? 0)}</p>
        <p className="pb-1 text-xs text-slate-400">{ehEscala ? 'média por semana' : 'por semana'}</p>
      </div>

      {/* Dias da semana ou do ciclo */}
      {ehEscala ? (
        <div className="mt-4 flex gap-1">
          {[...j.dias].sort((a, b) => a.dia_semana - b.dia_semana).slice(0, 14).map((d) => (
            <span
              key={d.dia_semana}
              className={clsx(
                'flex h-7 flex-1 items-center justify-center rounded-md text-[10px] font-medium',
                d.folga ? 'bg-slate-100 text-slate-400' : 'bg-primary-700 text-white',
              )}
              title={d.folga ? 'Folga' : horarioTexto(d)}
            >
              {d.dia_semana + 1}
            </span>
          ))}
        </div>
      ) : (
        <div className="mt-4 flex gap-1">
          {[1, 2, 3, 4, 5, 6, 0].map((i) => {
            const d = j.dias.find((x) => x.dia_semana === i);
            const trabalha = d && !d.folga;
            return (
              <span
                key={i}
                className={clsx(
                  'flex h-7 flex-1 items-center justify-center rounded-md text-[10px] font-medium',
                  trabalha ? 'bg-primary-700 text-white' : 'bg-slate-100 text-slate-400',
                )}
                title={trabalha ? `${d!.entrada}–${d!.saida}` : 'Folga'}
              >
                {DIAS_CURTOS[i].slice(0, 3)}
              </span>
            );
          })}
        </div>
      )}

      <ul className="mt-4 space-y-1.5 text-xs">
        {escala.length === 0 ? (
          <li className="text-slate-400">Nenhum dia de trabalho definido</li>
        ) : (
          escala.map((e) => (
            <li key={e.dias} className="flex gap-2">
              <span className="w-16 shrink-0 font-medium text-slate-600">{e.dias}</span>
              <span className="tabular-nums text-slate-500">{e.horario}</span>
            </li>
          ))
        )}
      </ul>

      <div className="mt-5 flex items-center justify-between border-t border-slate-100 pt-4 text-xs text-slate-500">
        <span className="flex items-center gap-1.5">
          <Users className="h-3.5 w-3.5" />
          {j.colaboradores ?? 0} colaborador{j.colaboradores === 1 ? '' : 'es'}
        </span>
        <span className="flex items-center gap-2">
          <span>Tol. {j.tolerancia_entrada_min}min</span>
          <span>HE {Number(j.percentual_he_dia_util)}%</span>
          <Pencil className="h-3.5 w-3.5 text-slate-300 transition group-hover:text-primary-600" />
        </span>
      </div>
    </button>
  );
}

export default function Jornadas() {
  const { pode } = useAuth();
  const podeEditar = pode('jornadas', 'editar');
  const [jornadas, setJornadas] = useState<Jornada[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState<{ aberto: boolean; jornada: Jornada | null }>({ aberto: false, jornada: null });

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setJornadas(await api<Jornada[]>('api_jornadas_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar jornadas.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const novo = () => setModal({ aberto: true, jornada: null });

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Jornadas e escalas</h2>
          <p className="mt-1 text-sm text-slate-500">Jornadas semanais e escalas de revezamento (12x36, 5x1, 6x2…), tolerâncias, horas extras e adicional noturno.</p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={novo}>
            <Plus className="h-4 w-4" /> Nova jornada
          </Button>
        )}
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {jornadas === null && !erro ? (
        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
          {Array.from({ length: 3 }, (_, i) => (
            <div key={i} className="card h-64 animate-pulse" />
          ))}
        </div>
      ) : jornadas && jornadas.length === 0 ? (
        <div className="card">
          <EmptyState
            icon={CalendarClock}
            titulo="Nenhuma jornada cadastrada"
            descricao="Cadastre as escalas de trabalho da empresa. Depois é só vincular cada colaborador à sua jornada."
            acao={
              podeEditar && (
                <Button variant="accent" onClick={novo}>
                  <Plus className="h-4 w-4" /> Cadastrar primeira jornada
                </Button>
              )
            }
          />
        </div>
      ) : (
        <div className="grid gap-5 md:grid-cols-2 xl:grid-cols-3">
          {jornadas?.map((j) => (
            <JornadaCard key={j.id} j={j} onAbrir={() => setModal({ aberto: true, jornada: j })} />
          ))}
        </div>
      )}

      <JornadaModal
        aberto={modal.aberto}
        jornada={modal.jornada}
        podeEditar={podeEditar}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal({ aberto: false, jornada: null });
          carregar();
        }}
      />
    </div>
  );
}
