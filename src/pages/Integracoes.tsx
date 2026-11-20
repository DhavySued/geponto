import clsx from 'clsx';
import { AlertTriangle, Check, Copy, KeyRound, Plug, Plus, ShieldOff } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { api } from '@/lib/api';
import type { ChaveApi, EscopoChave, IntegracoesDados } from '@/lib/types';

/** Endereço público do gateway REST (api-gateway/), mostrado nos exemplos */
const URL_API = ((import.meta.env.VITE_API_PUBLICA_URL as string | undefined) ?? '').replace(/\/+$/, '') || 'https://SUA-API';

const ESCOPOS: { valor: EscopoChave; titulo: string; descricao: string }[] = [
  { valor: 'leitura', titulo: 'Leitura', descricao: 'Colaboradores, batidas, totais do período (folha) e saldos do banco de horas.' },
  { valor: 'batidas', titulo: 'Importar batidas', descricao: 'Enviar batidas de relógios/REP ou de outros apps. As originais nunca são alteradas.' },
];

const dataHora = (s: string | null) =>
  s ? new Date(s).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';

function BotaoCopiar({ texto, rotulo = 'Copiar' }: { texto: string; rotulo?: string }) {
  const [copiado, setCopiado] = useState(false);
  return (
    <Button
      type="button"
      variant="secondary"
      onClick={async () => {
        try {
          await navigator.clipboard.writeText(texto);
          setCopiado(true);
          window.setTimeout(() => setCopiado(false), 2000);
        } catch {
          /* sem permissão de área de transferência: o texto continua visível para copiar à mão */
        }
      }}
    >
      {copiado ? <Check className="h-4 w-4 text-emerald-600" /> : <Copy className="h-4 w-4" />} {copiado ? 'Copiado' : rotulo}
    </Button>
  );
}

function NovaChaveModal({ aberto, onFechar, onCriada }: { aberto: boolean; onFechar: () => void; onCriada: () => void }) {
  const [nome, setNome] = useState('');
  const [escopos, setEscopos] = useState<EscopoChave[]>(['leitura']);
  const [chave, setChave] = useState<string | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    if (aberto) {
      setNome('');
      setEscopos(['leitura']);
      setChave(null);
      setErro(null);
    }
  }, [aberto]);

  const criar = async () => {
    setSalvando(true);
    try {
      setErro(null);
      const r = await api<{ id: string; chave: string }>('api_chave_criar', { p_nome: nome, p_escopos: escopos });
      setChave(r.chave);
      onCriada();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao criar a chave.');
    } finally {
      setSalvando(false);
    }
  };

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      fechavel={!chave}
      titulo={chave ? 'Chave criada' : 'Nova chave de API'}
      descricao={chave ? undefined : 'Uma chave para cada sistema integrado facilita revogar só o que for preciso.'}
      rodape={
        <div className="flex justify-end gap-2">
          {chave ? (
            <Button onClick={onFechar}>Já guardei a chave</Button>
          ) : (
            <>
              <Button variant="ghost" onClick={onFechar}>Cancelar</Button>
              <Button onClick={criar} loading={salvando} disabled={!nome.trim() || !escopos.length}>
                <KeyRound className="h-4 w-4" /> Criar chave
              </Button>
            </>
          )}
        </div>
      }
    >
      {chave ? (
        <div className="space-y-4">
          <div className="flex gap-2 rounded-xl bg-amber-50 p-3 text-sm text-amber-800 ring-1 ring-amber-200">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
            Copie e guarde a chave agora: por segurança ela não será mostrada de novo.
          </div>
          <code className="block break-all rounded-xl bg-slate-900 p-3 font-mono text-sm text-emerald-300">{chave}</code>
          <div className="flex justify-end">
            <BotaoCopiar texto={chave} rotulo="Copiar chave" />
          </div>
        </div>
      ) : (
        <form
          className="space-y-4"
          onSubmit={(e) => {
            e.preventDefault();
            if (nome.trim() && escopos.length) criar();
          }}
        >
          <Field label="Nome" obrigatorio dica="Para identificar quem usa a chave. Ex.: Folha de pagamento, Relógio da recepção.">
            <input className="input" value={nome} onChange={(e) => setNome(e.target.value)} maxLength={80} autoFocus />
          </Field>
          <Field label="Permissões" grupo>
            <div className="space-y-2">
              {ESCOPOS.map((s) => {
                const marcado = escopos.includes(s.valor);
                return (
                  <label
                    key={s.valor}
                    className={clsx('flex cursor-pointer items-start gap-3 rounded-xl p-3 ring-1 transition',
                      marcado ? 'bg-primary-50/60 ring-primary-300' : 'ring-slate-200 hover:bg-slate-50')}
                  >
                    <input
                      type="checkbox"
                      className="mt-0.5 h-4 w-4 rounded border-slate-300 text-primary-600"
                      checked={marcado}
                      onChange={() => setEscopos((v) => (marcado ? v.filter((x) => x !== s.valor) : [...v, s.valor]))}
                    />
                    <span>
                      <span className="block text-sm font-medium text-slate-800">{s.titulo}</span>
                      <span className="block text-xs text-slate-500">{s.descricao}</span>
                    </span>
                  </label>
                );
              })}
            </div>
          </Field>
          <AlertaErro mensagem={erro} />
          <button type="submit" className="hidden" />
        </form>
      )}
    </Modal>
  );
}

export default function Integracoes() {
  const toast = useToast();
  const [dados, setDados] = useState<IntegracoesDados | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [novaAberta, setNovaAberta] = useState(false);
  const [revogar, setRevogar] = useState<ChaveApi | null>(null);
  const [revogando, setRevogando] = useState(false);

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setDados(await api<IntegracoesDados>('api_chaves_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar as chaves.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const confirmarRevogacao = async () => {
    if (!revogar) return;
    setRevogando(true);
    try {
      await api('api_chave_revogar', { p_id: revogar.id });
      toast('Chave revogada. Os sistemas que a usavam perderam o acesso.');
      setRevogar(null);
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao revogar.', 'erro');
    } finally {
      setRevogando(false);
    }
  };

  const exemplo = `curl ${URL_API}/v1/batidas?inicio=2026-11-01&fim=2026-11-30 \\\n  -H "Authorization: Bearer gp_SUA_CHAVE"`;

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Integrações (API)</h2>
          <p className="mt-1 text-sm text-slate-500">
            Chaves para outros sistemas (relógios de ponto, folha de pagamento, ERP, BI) acessarem os dados
            {dados?.empresa ? ` de ${dados.empresa.nome_fantasia || dados.empresa.razao_social}` : ''}.
          </p>
        </div>
        {dados?.pode_editar && (
          <Button onClick={() => setNovaAberta(true)}>
            <Plus className="h-4 w-4" /> Nova chave
          </Button>
        )}
      </div>

      <AlertaErro mensagem={erro} />

      <div className="card overflow-hidden">
        {dados && dados.chaves.length === 0 ? (
          <EmptyState icon={KeyRound} titulo="Nenhuma chave criada" descricao="Crie uma chave para cada sistema que vai se integrar ao GePonto." />
        ) : (
          <ul className="divide-y divide-slate-100">
            {dados?.chaves.map((k) => (
              <li key={k.id} className={clsx('flex flex-wrap items-center gap-x-4 gap-y-2 px-5 py-4', !k.ativo && 'opacity-60')}>
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-primary-700">
                  <KeyRound className="h-5 w-5" />
                </div>
                <div className="min-w-0 flex-1">
                  <p className="flex flex-wrap items-center gap-2 font-medium text-slate-800">
                    {k.nome}
                    {k.ativo ? <Badge tone="green">Ativa</Badge> : <Badge tone="slate">Revogada</Badge>}
                    {k.escopos.map((e) => (
                      <Badge key={e} tone="primary" dot={false}>{ESCOPOS.find((s) => s.valor === e)?.titulo ?? e}</Badge>
                    ))}
                  </p>
                  <p className="mt-0.5 text-xs text-slate-500">
                    <code className="font-mono">{k.prefixo}…</code> · criada em {dataHora(k.criada_em)}
                    {k.criado_por ? ` por ${k.criado_por}` : ''} · último uso: {dataHora(k.ultimo_uso)}
                    {k.revogada_em ? ` · revogada em ${dataHora(k.revogada_em)}` : ''}
                  </p>
                </div>
                {k.ativo && dados.pode_editar && (
                  <Button variant="ghost" onClick={() => setRevogar(k)}>
                    <ShieldOff className="h-4 w-4" /> Revogar
                  </Button>
                )}
              </li>
            ))}
          </ul>
        )}
      </div>

      <div className="card space-y-3 p-5">
        <h3 className="flex items-center gap-2 font-semibold text-slate-800">
          <Plug className="h-4 w-4 text-primary-600" /> Como usar
        </h3>
        <p className="text-sm text-slate-600">
          Envie a chave no cabeçalho <code className="rounded bg-slate-100 px-1 font-mono text-xs">Authorization: Bearer</code>.
          Rotas: <code className="font-mono text-xs">GET /v1/colaboradores</code>, <code className="font-mono text-xs">GET /v1/batidas</code>,{' '}
          <code className="font-mono text-xs">POST /v1/batidas</code>, <code className="font-mono text-xs">GET /v1/totais</code>,{' '}
          <code className="font-mono text-xs">GET /v1/banco-horas</code> e <code className="font-mono text-xs">GET /v1/empresa</code>.
          A documentação completa fica em <code className="font-mono text-xs">{URL_API}/docs</code>.
        </p>
        <pre className="overflow-x-auto rounded-xl bg-slate-900 p-3 font-mono text-xs leading-relaxed text-slate-100">{exemplo}</pre>
        <p className="text-xs text-slate-400">
          Cada chave só enxerga os colaboradores desta empresa. Se uma chave vazar, revogue e crie outra.
        </p>
      </div>

      <NovaChaveModal aberto={novaAberta} onFechar={() => setNovaAberta(false)} onCriada={carregar} />

      <Modal
        aberto={!!revogar}
        onFechar={() => setRevogar(null)}
        titulo="Revogar chave?"
        descricao={revogar ? `Os sistemas que usam “${revogar.nome}” perdem o acesso na hora. Não dá para desfazer.` : undefined}
        rodape={
          <div className="flex justify-end gap-2">
            <Button variant="ghost" onClick={() => setRevogar(null)}>Cancelar</Button>
            <Button variant="accent" onClick={confirmarRevogacao} loading={revogando}>
              <ShieldOff className="h-4 w-4" /> Revogar
            </Button>
          </div>
        }
      >
        <p className="text-sm text-slate-600">Para continuar integrando, crie uma nova chave e atualize o sistema que usava esta.</p>
      </Modal>
    </div>
  );
}
