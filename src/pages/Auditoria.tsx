import clsx from 'clsx';
import { AlertTriangle, ChevronDown, ChevronRight, ScrollText, Search } from 'lucide-react';
import { Fragment, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { ComboboxChips } from '@/components/ui/ComboboxChips';
import { EmptyState } from '@/components/ui/EmptyState';
import { Field } from '@/components/ui/Field';
import { api } from '@/lib/api';
import { toISODate } from '@/lib/format';
import { opcoesColaboradores, useFiltrosAux } from '@/lib/hooks';
import type { AcaoAuditoria, AuditoriaConsulta, AuditoriaItem } from '@/lib/types';

export const TABELAS_AUDITORIA: Record<string, string> = {
  acesso: 'Acesso ao sistema',
  empresa: 'Configuração do ponto',
  empresas: 'Empresas',
  perfis: 'Perfis de acesso',
  perfil_permissoes: 'Permissões do perfil',
  usuarios: 'Usuários',
  usuario_empresas: 'Empresas do usuário',
  departamentos: 'Departamentos',
  cargos: 'Cargos',
  jornadas: 'Jornadas',
  jornada_dias: 'Dias da jornada',
  tipos_beneficio: 'Tipos de VT e VA',
  feriados: 'Feriados',
  colaboradores: 'Colaboradores',
  colaborador_situacoes: 'Situação do colaborador',
  ausencias: 'Ocorrências e afastamentos',
  escalas: 'Escalas (dias)',
  escala_lancamentos: 'Escalas',
  batidas: 'Batidas',
  locais_ponto: 'Locais de ponto',
  motivos_batida: 'Motivos de batida',
  banco_horas: 'Banco de horas (manual)',
  fechamentos: 'Fechamento de período',
  solicitacoes: 'Solicitações',
  eventos_folha: 'Eventos da folha',
  perfis_eventos: 'Regras de cálculo',
  perfil_evento_he: 'Faixas de hora extra',
  justificativas: 'Justificativas',
  faltas_folha: 'Faltas para a folha',
  chaves_api: 'Chaves de API',
};

const ACOES: Record<AcaoAuditoria, { label: string; tone: 'green' | 'orange' | 'red' | 'slate' | 'blue' }> = {
  inclusao: { label: 'Inclusão', tone: 'green' },
  alteracao: { label: 'Alteração', tone: 'blue' },
  exclusao: { label: 'Exclusão', tone: 'red' },
  login: { label: 'Entrou', tone: 'slate' },
  login_falha: { label: 'Acesso recusado', tone: 'orange' },
};

const valor = (v: unknown) =>
  v === null || v === undefined || v === '' ? '—' : typeof v === 'boolean' ? (v ? 'Sim' : 'Não') : typeof v === 'object' ? JSON.stringify(v) : String(v);
const rotuloCampo = (k: string) => k.replace(/_id$/, '').replace(/_/g, ' ');
const dataHora = (iso: string) =>
  new Date(iso).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });

function Detalhe({ i }: { i: AuditoriaItem }) {
  const chaves = i.acao === 'alteracao' ? i.campos ?? [] : Object.keys(i.depois ?? i.antes ?? {}).filter((k) => k !== 'id');
  if (!chaves.length) return <p className="text-xs text-slate-400">Sem detalhes.</p>;
  return (
    <table className="w-full text-xs">
      <thead>
        <tr className="text-left text-slate-400">
          <th className="py-1 pr-4 font-medium">Campo</th>
          {i.acao !== 'inclusao' && i.antes && <th className="py-1 pr-4 font-medium">{i.acao === 'alteracao' ? 'Antes' : 'Valor'}</th>}
          {i.acao !== 'exclusao' && i.depois && <th className="py-1 font-medium">{i.acao === 'alteracao' ? 'Depois' : 'Valor'}</th>}
        </tr>
      </thead>
      <tbody>
        {chaves.map((k) => (
          <tr key={k} className="align-top">
            <td className="py-1 pr-4 capitalize text-slate-500">{rotuloCampo(k)}</td>
            {i.acao !== 'inclusao' && i.antes && <td className={clsx('max-w-[360px] break-words py-1 pr-4', i.acao === 'alteracao' ? 'text-rose-600 line-through decoration-rose-300' : 'text-slate-700')}>{valor(i.antes[k])}</td>}
            {i.acao !== 'exclusao' && i.depois && <td className={clsx('max-w-[360px] break-words py-1', i.acao === 'alteracao' ? 'font-medium text-emerald-700' : 'text-slate-700')}>{valor(i.depois[k])}</td>}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export default function Auditoria() {
  const { aux, erro: erroAux } = useFiltrosAux();
  const hoje = new Date();
  const [periodo, setPeriodo] = useState({ ini: toISODate(new Date(hoje.getFullYear(), hoje.getMonth(), hoje.getDate() - 7)), fim: toISODate(hoje) });
  const [filtros, setFiltros] = useState({ tabela: '', acao: '' as AcaoAuditoria | '', usuario: '', colaboradores: [] as string[], busca: '' });
  const [dados, setDados] = useState<AuditoriaConsulta | null>(null);
  const [abertos, setAbertos] = useState<Set<number>>(new Set());
  const [erro, setErro] = useState<string | null>(null);
  const [carregando, setCarregando] = useState(false);

  const consultar = async () => {
    setCarregando(true);
    try {
      setErro(null);
      setDados(await api<AuditoriaConsulta>('api_auditoria_listar', {
        p_ini: periodo.ini,
        p_fim: periodo.fim,
        p_tabela: filtros.tabela || null,
        p_acao: filtros.acao || null,
        p_usuario: filtros.usuario || null,
        p_colaborador: filtros.colaboradores[0] ?? null,
        p_busca: filtros.busca.trim() || null,
      }));
      setAbertos(new Set());
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao consultar.');
    } finally {
      setCarregando(false);
    }
  };

  const alternar = (id: number) => setAbertos((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });
  const itens = dados?.itens ?? [];

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Log e auditoria</h2>
        <p className="mt-1 text-sm text-slate-500">
          Quem incluiu, alterou ou excluiu cada informação, com o valor anterior e o novo, e os acessos ao sistema. Clique numa linha para ver o detalhe.
        </p>
      </div>

      <section className="card p-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="O que">
            <select className="input" value={filtros.tabela} onChange={(e) => setFiltros((f) => ({ ...f, tabela: e.target.value }))}>
              <option value="">Tudo</option>
              {Object.entries(TABELAS_AUDITORIA).sort((a, b) => a[1].localeCompare(b[1])).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </select>
          </Field>
          <Field label="Ação">
            <select className="input" value={filtros.acao} onChange={(e) => setFiltros((f) => ({ ...f, acao: e.target.value as AcaoAuditoria | '' }))}>
              <option value="">Todas</option>
              {Object.entries(ACOES).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}
            </select>
          </Field>
          <Field label="Usuário">
            <select className="input" value={filtros.usuario} onChange={(e) => setFiltros((f) => ({ ...f, usuario: e.target.value }))}>
              <option value="">Todos</option>
              {dados?.usuarios.map((u) => <option key={u.id} value={u.id}>{u.nome}</option>)}
            </select>
          </Field>
          <Field label="Colaborador afetado">
            <ComboboxChips opcoes={opcoesColaboradores(aux?.colaboradores, { departamento: '' })} valor={filtros.colaboradores}
              onChange={(v) => setFiltros((f) => ({ ...f, colaboradores: v.slice(-1) }))} rotuloTodos="Todos" />
          </Field>
          <Field label="Contém o texto">
            <input className="input" value={filtros.busca} placeholder="Ex.: nome, CPF, valor…" onChange={(e) => setFiltros((f) => ({ ...f, busca: e.target.value }))}
              onKeyDown={(e) => e.key === 'Enter' && consultar()} />
          </Field>
          <div className="flex items-end">
            <Button onClick={consultar} loading={carregando} className="w-full"><Search className="h-4 w-4" /> Consultar</Button>
          </div>
        </div>
      </section>

      {(erro || erroAux) && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro ?? erroAux}
        </div>
      )}

      {dados === null ? (
        <div className="card"><EmptyState icon={ScrollText} titulo="Escolha os filtros e clique em Consultar" descricao="O registro começa a partir da instalação desta atualização." /></div>
      ) : itens.length === 0 ? (
        <div className="card"><EmptyState icon={ScrollText} titulo="Nada registrado" descricao="Não há registros com esses filtros." /></div>
      ) : (
        <>
          {itens.length >= dados.limite && (
            <p className="text-xs text-amber-700">Mostrando os {dados.limite} registros mais recentes. Refine os filtros para ver os anteriores.</p>
          )}
          <div className="card overflow-x-auto">
            <table className="w-full min-w-[860px] text-sm">
              <thead>
                <tr className="bg-slate-50/70 text-left text-xs text-slate-400">
                  <th className="w-8 px-2 py-2.5" />
                  <th className="px-4 py-2.5 font-medium">Data e hora</th>
                  <th className="px-4 py-2.5 font-medium">Usuário</th>
                  <th className="px-4 py-2.5 font-medium">Ação</th>
                  <th className="px-4 py-2.5 font-medium">O que</th>
                  <th className="px-4 py-2.5 font-medium">Registro</th>
                  <th className="px-4 py-2.5 font-medium">Campos alterados</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {itens.map((i) => {
                  const aberto = abertos.has(i.id);
                  const a = ACOES[i.acao];
                  return (
                    <Fragment key={i.id}>
                      <tr onClick={() => alternar(i.id)} className={clsx('cursor-pointer align-top hover:bg-slate-50', aberto && 'bg-slate-50')}>
                        <td className="px-2 py-2.5 text-slate-400">{aberto ? <ChevronDown className="h-4 w-4" /> : <ChevronRight className="h-4 w-4" />}</td>
                        <td className="whitespace-nowrap px-4 py-2.5 tabular-nums text-slate-600">{dataHora(i.data_hora)}</td>
                        <td className="px-4 py-2.5 text-slate-700">{i.usuario ?? <span className="text-slate-400">Desconhecido</span>}</td>
                        <td className="px-4 py-2.5"><Badge tone={a.tone} dot={false}>{a.label}</Badge></td>
                        <td className="px-4 py-2.5 text-slate-600">{TABELAS_AUDITORIA[i.tabela] ?? i.tabela}</td>
                        <td className="max-w-[260px] px-4 py-2.5">
                          <p className="truncate text-slate-700">{i.descricao ?? '—'}</p>
                          {i.colaborador && i.colaborador !== i.descricao && <p className="truncate text-xs text-slate-400">{i.colaborador}</p>}
                        </td>
                        <td className="max-w-[260px] px-4 py-2.5 text-xs capitalize text-slate-500">
                          {i.campos?.length ? i.campos.map(rotuloCampo).join(', ') : '—'}
                        </td>
                      </tr>
                      {aberto && (
                        <tr className="bg-slate-50/60">
                          <td />
                          <td colSpan={6} className="px-4 pb-4 pt-1"><Detalhe i={i} /></td>
                        </tr>
                      )}
                    </Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
