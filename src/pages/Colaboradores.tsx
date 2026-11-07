import clsx from 'clsx';
import { AlertTriangle, ChevronRight, KeyRound, Plus, Search, Users } from 'lucide-react';
import { useCallback, useEffect, useMemo, useState } from 'react';
import { ColaboradorModal } from '@/components/colaboradores/ColaboradorModal';
import { SITUACAO, SituacaoBadge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { useAuth } from '@/contexts/AuthContext';
import { formatData, iniciais } from '@/lib/format';
import { mascaraCPF } from '@/lib/mask';
import { api } from '@/lib/supabase';
import type { ColaboradorResumo, SituacaoColaborador } from '@/lib/types';

type Filtro = 'todos' | SituacaoColaborador;
const FILTROS: Filtro[] = ['todos', 'ativo', 'ferias', 'afastado', 'desligado'];

export default function Colaboradores() {
  const { pode } = useAuth();
  const podeEditar = pode('colaboradores', 'editar');
  const [lista, setLista] = useState<ColaboradorResumo[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [filtro, setFiltro] = useState<Filtro>('ativo');
  const [busca, setBusca] = useState('');
  const [modal, setModal] = useState<{ aberto: boolean; id: string | null }>({ aberto: false, id: null });

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setLista(await api<ColaboradorResumo[]>('api_colaboradores_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar colaboradores.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const contagem = useMemo(() => {
    const c: Record<Filtro, number> = { todos: 0, ativo: 0, ferias: 0, afastado: 0, desligado: 0 };
    for (const x of lista ?? []) {
      c.todos++;
      c[x.situacao]++;
    }
    return c;
  }, [lista]);

  const filtrados = useMemo(() => {
    const termo = busca.trim().toLowerCase();
    const termoDigitos = termo.replace(/\D/g, '');
    return (lista ?? []).filter(
      (c) =>
        (filtro === 'todos' || c.situacao === filtro) &&
        (!termo ||
          c.nome.toLowerCase().includes(termo) ||
          c.matricula.toLowerCase().includes(termo) ||
          (termoDigitos.length >= 3 && c.cpf.includes(termoDigitos))),
    );
  }, [lista, filtro, busca]);

  const abrir = (id: string | null) => setModal({ aberto: true, id });

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Colaboradores</h2>
          <p className="mt-1 text-sm text-slate-500">Dados pessoais e profissionais, situação e histórico de movimentações.</p>
        </div>
        {podeEditar && (
          <Button variant="accent" onClick={() => abrir(null)}>
            <Plus className="h-4 w-4" /> Novo colaborador
          </Button>
        )}
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      <section className="card">
        <div className="flex flex-col gap-3 border-b border-slate-100 p-4 lg:flex-row lg:items-center lg:justify-between">
          <div className="-mx-1 flex gap-1 overflow-x-auto px-1">
            {FILTROS.map((f) => (
              <button
                key={f}
                onClick={() => setFiltro(f)}
                className={clsx(
                  'flex shrink-0 items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-medium transition',
                  filtro === f ? 'bg-primary-700 text-white' : 'text-slate-500 hover:bg-slate-100 hover:text-slate-700',
                )}
              >
                {f === 'todos' ? 'Todos' : SITUACAO[f].label}
                <span className={clsx('rounded-md px-1.5 text-[10px] tabular-nums', filtro === f ? 'bg-white/15' : 'bg-slate-100')}>
                  {contagem[f]}
                </span>
              </button>
            ))}
          </div>
          <div className="relative lg:w-72">
            <Search className="pointer-events-none absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-slate-400" />
            <input
              value={busca}
              onChange={(e) => setBusca(e.target.value)}
              placeholder="Buscar por nome, matrícula ou CPF"
              className="input h-9 pl-9"
            />
          </div>
        </div>

        {lista === null && !erro ? (
          <div className="space-y-3 p-5">
            {Array.from({ length: 5 }, (_, i) => (
              <div key={i} className="h-12 animate-pulse rounded-xl bg-slate-50" />
            ))}
          </div>
        ) : filtrados.length === 0 ? (
          <EmptyState
            icon={Users}
            titulo={contagem.todos === 0 ? 'Nenhum colaborador cadastrado' : 'Nenhum colaborador encontrado'}
            descricao={
              contagem.todos === 0
                ? 'Cadastre a equipe para começar a controlar o ponto. Dica: cadastre antes as jornadas de trabalho.'
                : 'Ajuste o filtro de situação ou o termo de busca.'
            }
            acao={
              contagem.todos === 0 &&
              podeEditar && (
                <Button variant="accent" onClick={() => abrir(null)}>
                  <Plus className="h-4 w-4" /> Cadastrar primeiro colaborador
                </Button>
              )
            }
          />
        ) : (
          <>
            <div className="hidden overflow-x-auto md:block">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-xs text-slate-400">
                    <th className="px-5 py-3 font-medium">Colaborador</th>
                    <th className="px-5 py-3 font-medium">Cargo / Departamento</th>
                    <th className="px-5 py-3 font-medium">Jornada</th>
                    <th className="px-5 py-3 font-medium">Admissão</th>
                    <th className="px-5 py-3 font-medium">Situação</th>
                    <th className="w-10 px-5 py-3" />
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {filtrados.map((c) => (
                    <tr key={c.id} onClick={() => abrir(c.id)} className="group cursor-pointer transition hover:bg-slate-50/70">
                      <td className="px-5 py-3">
                        <div className="flex items-center gap-3">
                          <span className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-xs font-semibold text-primary-700">
                            {iniciais(c.nome)}
                          </span>
                          <div className="min-w-0">
                            <p className="truncate font-medium text-slate-800">{c.nome}</p>
                            <p className="truncate text-xs tabular-nums text-slate-400">
                              Mat. {c.matricula} · CPF {mascaraCPF(c.cpf)}
                            </p>
                          </div>
                        </div>
                      </td>
                      <td className="px-5 py-3">
                        <p className="text-slate-700">{c.cargo ?? '—'}</p>
                        <p className="text-xs text-slate-400">{c.departamento ?? 'Sem departamento'}</p>
                      </td>
                      <td className="px-5 py-3">
                        {c.jornada ? (
                          <span className="text-slate-600">{c.jornada}</span>
                        ) : (
                          <span className="rounded-md bg-accent-50 px-2 py-0.5 text-xs font-medium text-accent-700">Sem jornada</span>
                        )}
                        <p className="mt-0.5 flex items-center gap-1 text-[11px] text-slate-400">
                          {c.controla_ponto
                            ? `Ponto desde ${formatData(c.controle_ponto_inicio, { day: '2-digit', month: '2-digit', year: '2-digit' })}`
                            : 'Ponto não controlado'}
                          {c.tem_acesso && <KeyRound className="h-3 w-3 text-primary-500" aria-label="Tem acesso ao ponto" />}
                        </p>
                      </td>
                      <td className="px-5 py-3 tabular-nums text-slate-600">
                        {formatData(c.data_admissao, { day: '2-digit', month: '2-digit', year: 'numeric' })}
                      </td>
                      <td className="px-5 py-3">
                        <SituacaoBadge situacao={c.situacao} />
                      </td>
                      <td className="px-5 py-3 text-slate-300 group-hover:text-primary-600">
                        <ChevronRight className="h-4 w-4" />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            <ul className="divide-y divide-slate-100 md:hidden">
              {filtrados.map((c) => (
                <li key={c.id}>
                  <button onClick={() => abrir(c.id)} className="flex w-full items-center gap-3 px-4 py-3.5 text-left">
                    <span className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-xs font-semibold text-primary-700">
                      {iniciais(c.nome)}
                    </span>
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-medium text-slate-800">{c.nome}</p>
                      <p className="truncate text-xs text-slate-400">
                        {c.cargo ?? 'Sem cargo'} · {c.jornada ?? 'sem jornada'}
                      </p>
                    </div>
                    <SituacaoBadge situacao={c.situacao} />
                  </button>
                </li>
              ))}
            </ul>
          </>
        )}
      </section>

      <ColaboradorModal
        aberto={modal.aberto}
        colaboradorId={modal.id}
        podeEditar={podeEditar}
        onFechar={() => setModal((m) => ({ ...m, aberto: false }))}
        onSalvo={() => {
          setModal({ aberto: false, id: null });
          carregar();
        }}
      />
    </div>
  );
}
