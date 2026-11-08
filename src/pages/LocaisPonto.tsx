import { AlertTriangle, Crosshair, ExternalLink, MapPin, Pencil, Plus, Trash2 } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { linkMapa, obterLocalizacao, textoDistancia } from '@/lib/geo';
import { api } from '@/lib/supabase';
import type { LocalPonto } from '@/lib/types';

const NOVO: LocalPonto = { nome: '', endereco: '', latitude: null, longitude: null, raio_m: 150, precisao_m: null, ativo: true };

function LocalModal({
  aberto,
  local,
  podeEditar,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  local: LocalPonto | null;
  podeEditar: boolean;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<LocalPonto>(NOVO);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [localizando, setLocalizando] = useState(false);
  const [confirmarExclusao, setConfirmarExclusao] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setForm(local ?? NOVO);
    setErro(null);
    setConfirmarExclusao(false);
  }, [aberto, local]);

  // As coordenadas vêm só do aparelho: não há campo para digitar ou colar
  const capturar = async () => {
    setLocalizando(true);
    setErro(null);
    const g = await obterLocalizacao();
    setLocalizando(false);
    if (g.p_latitude == null || g.p_longitude == null) {
      return setErro(`${g.p_geo_erro ?? 'Não foi possível obter a localização'}. Permita o acesso à localização e tente de novo.`);
    }
    setForm((f) => ({ ...f, latitude: Number(g.p_latitude!.toFixed(6)), longitude: Number(g.p_longitude!.toFixed(6)), precisao_m: g.p_precisao }));
    toast(`Localização capturada (precisão de ${textoDistancia(g.p_precisao ?? 0)}).`);
  };

  const temCoordenadas = form.latitude != null && form.longitude != null;

  const salvar = async () => {
    setErro(null);
    if (!temCoordenadas) return setErro('Capture a localização estando no local.');
    setSalvando(true);
    try {
      await api('api_local_ponto_salvar', { p_dados: form });
      toast(local?.id ? 'Local atualizado.' : 'Local cadastrado.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const excluir = async () => {
    if (!local?.id) return;
    setSalvando(true);
    try {
      await api('api_local_ponto_excluir', { p_id: local.id });
      toast('Local excluído.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao excluir.');
      setConfirmarExclusao(false);
    } finally {
      setSalvando(false);
    }
  };

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      titulo={local?.id ? 'Editar local de ponto' : 'Cadastrar local de ponto'}
      descricao="Batidas feitas além do raio ficam marcadas como “fora do local” para o RH conferir. O ponto nunca é bloqueado."
      rodape={
        !podeEditar ? (
          <Button variant="secondary" onClick={onFechar}>Fechar</Button>
        ) : (
          <div className="flex w-full flex-wrap items-center justify-between gap-2">
            <div>
              {local?.id &&
                (confirmarExclusao ? (
                  <div className="flex items-center gap-2 text-sm">
                    <span className="text-slate-600">Excluir o local?</span>
                    <Button variant="ghost" className="h-9 text-rose-600 hover:bg-rose-50" onClick={excluir} loading={salvando}>Sim, excluir</Button>
                    <Button variant="ghost" className="h-9" onClick={() => setConfirmarExclusao(false)}>Não</Button>
                  </div>
                ) : (
                  <Button variant="ghost" className="h-9 text-rose-600 hover:bg-rose-50" onClick={() => setConfirmarExclusao(true)}>
                    <Trash2 className="h-4 w-4" /> Excluir
                  </Button>
                ))}
            </div>
            <div className="flex gap-2">
              <Button variant="secondary" onClick={onFechar}>Cancelar</Button>
              <Button onClick={salvar} loading={salvando} disabled={!temCoordenadas}>Salvar</Button>
            </div>
          </div>
        )
      }
    >
      <AlertaErro mensagem={erro} />
      <fieldset disabled={!podeEditar} className="grid gap-4 sm:grid-cols-2">
        <Field label="Nome do local" obrigatorio>
          <input className="input" value={form.nome} placeholder="Ex.: Sede" autoFocus
            onChange={(e) => setForm({ ...form, nome: e.target.value })} />
        </Field>
        <Field label="Raio permitido (metros)" obrigatorio dica="Sugestão: 100 a 300 m. O GPS do celular costuma errar de 10 a 50 m.">
          <input type="number" min={10} max={50000} className="input" value={form.raio_m}
            onChange={(e) => setForm({ ...form, raio_m: e.target.value === '' ? 0 : Number(e.target.value) })} />
        </Field>
        <Field label="Endereço" className="sm:col-span-2">
          <input className="input" value={form.endereco ?? ''} placeholder="Rua, número, bairro, cidade (opcional)"
            onChange={(e) => setForm({ ...form, endereco: e.target.value })} />
        </Field>

        <div className="rounded-xl p-4 ring-1 ring-slate-200/80 sm:col-span-2">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 className="text-sm font-semibold text-slate-800">Localização do local</h3>
              <p className="text-xs text-slate-500">
                Capturada automaticamente pelo aparelho. Faça isso estando no local, de preferência pelo celular e ao ar livre
                ou perto de uma janela.
              </p>
            </div>
            <Button variant={temCoordenadas ? 'secondary' : 'primary'} className="h-9 shrink-0" onClick={capturar} loading={localizando}>
              {!localizando && <Crosshair className="h-4 w-4" />} {temCoordenadas ? 'Capturar de novo' : 'Capturar localização'}
            </Button>
          </div>
          {temCoordenadas ? (
            <div className="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
              <span className="font-mono">{form.latitude!.toFixed(6)}, {form.longitude!.toFixed(6)}</span>
              {form.precisao_m != null && <span>precisão de {textoDistancia(form.precisao_m)}</span>}
              <a href={linkMapa(form.latitude!, form.longitude!)} target="_blank" rel="noreferrer"
                className="inline-flex items-center gap-1 font-medium text-primary-700 hover:underline">
                <ExternalLink className="h-3.5 w-3.5" /> Conferir no mapa
              </a>
            </div>
          ) : (
            <p className="mt-3 rounded-lg border border-dashed border-slate-200 px-3 py-2 text-xs text-slate-400">
              Localização ainda não capturada.
            </p>
          )}
          {form.precisao_m != null && form.precisao_m > 100 && (
            <p className="mt-2 text-xs text-accent-700">
              A precisão está baixa ({textoDistancia(form.precisao_m)}). Capture de novo pelo celular, com o GPS ligado.
            </p>
          )}
        </div>

        <div className="sm:col-span-2">
          <Switch ativo={form.ativo} onChange={(v) => setForm({ ...form, ativo: v })} label="Conferir a localização das batidas"
            descricao="Desligado, as batidas continuam guardando a localização, mas não são comparadas com o local." />
        </div>
      </fieldset>
    </Modal>
  );
}

export default function LocaisPonto() {
  const { pode } = useAuth();
  const podeEditar = pode('locais_ponto', 'editar');
  const [locais, setLocais] = useState<LocalPonto[] | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState(false);

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setLocais(await api<LocalPonto[]>('api_locais_ponto_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar o local.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const local = locais?.[0] ?? null;

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Local de ponto</h2>
        <p className="mt-1 max-w-3xl text-sm text-slate-500">
          Cada batida guarda a localização do aparelho, capturada automaticamente, e é comparada com este local. Fora do raio ou sem
          localização, o ponto é registrado normalmente (Portaria 671) e fica marcado para conferência.
        </p>
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {locais === null ? (
        !erro && <div className="card h-48 animate-pulse" />
      ) : !local ? (
        <div className="card">
          <EmptyState
            icon={MapPin}
            titulo="Nenhum local cadastrado"
            descricao="Sem local, as batidas guardam a localização, mas não são conferidas por distância."
            acao={podeEditar ? (
              <Button variant="accent" onClick={() => setModal(true)}>
                <Plus className="h-4 w-4" /> Cadastrar local
              </Button>
            ) : undefined}
          />
        </div>
      ) : (
        <section className="card max-w-2xl p-6">
          <div className="flex items-start justify-between gap-3">
            <div className="flex min-w-0 items-start gap-3">
              <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-primary-600">
                <MapPin className="h-5 w-5" />
              </span>
              <div className="min-w-0">
                <p className="truncate text-lg font-semibold text-slate-900">{local.nome}</p>
                <p className="text-sm text-slate-500">{local.endereco || 'Sem endereço informado'}</p>
              </div>
            </div>
            {local.ativo ? <Badge tone="green">Conferindo</Badge> : <Badge tone="slate">Desligado</Badge>}
          </div>
          <dl className="mt-5 grid gap-3 text-sm sm:grid-cols-3">
            <div>
              <dt className="text-xs text-slate-400">Raio permitido</dt>
              <dd className="font-medium text-slate-800">{textoDistancia(local.raio_m)}</dd>
            </div>
            <div>
              <dt className="text-xs text-slate-400">Coordenadas</dt>
              <dd>
                <a href={linkMapa(local.latitude!, local.longitude!)} target="_blank" rel="noreferrer"
                  className="inline-flex items-center gap-1 font-mono text-xs text-primary-700 hover:underline">
                  {local.latitude?.toFixed(5)}, {local.longitude?.toFixed(5)} <ExternalLink className="h-3 w-3" />
                </a>
              </dd>
            </div>
            <div>
              <dt className="text-xs text-slate-400">Últimos 30 dias</dt>
              <dd className="text-slate-800">
                {local.batidas_30d ?? 0} batida(s)
                {!!local.fora_30d && <span className="font-medium text-accent-700"> · {local.fora_30d} fora do raio</span>}
              </dd>
            </div>
          </dl>
          <div className="mt-6 border-t border-slate-100 pt-4">
            <Button variant="secondary" onClick={() => setModal(true)}>
              <Pencil className="h-4 w-4" /> {podeEditar ? 'Editar local' : 'Ver detalhes'}
            </Button>
          </div>
        </section>
      )}

      <LocalModal
        aberto={modal}
        local={local}
        podeEditar={podeEditar}
        onFechar={() => setModal(false)}
        onSalvo={() => {
          setModal(false);
          carregar();
        }}
      />
    </div>
  );
}
