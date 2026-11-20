import clsx from 'clsx';
import { AlertTriangle, Building2, Crosshair, ExternalLink, MapPin, MapPinOff, Pencil, Plus, Search, Trash2 } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Badge } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { EmptyState } from '@/components/ui/EmptyState';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { buscarCep, localizarEndereco } from '@/lib/enderecos';
import { linkMapa, obterLocalizacao, textoDistancia } from '@/lib/geo';
import { mascaraCEP, mascaraCNPJ, mascaraTelefone } from '@/lib/mask';
import { api } from '@/lib/api';
import type { Empresa, EmpresasDados } from '@/lib/types';

const UFS = ['AC', 'AL', 'AM', 'AP', 'BA', 'CE', 'DF', 'ES', 'GO', 'MA', 'MG', 'MS', 'MT', 'PA', 'PB', 'PE', 'PI', 'PR', 'RJ', 'RN', 'RO', 'RR', 'RS', 'SC', 'SE', 'SP', 'TO'];

const NOVA: Empresa = {
  razao_social: '', nome_fantasia: '', cnpj: '', inscricao_estadual: '', telefone: '', email: '',
  cep: '', logradouro: '', numero: '', complemento: '', bairro: '', cidade: '', uf: '', ativo: true, local: null,
};

/** Endereço em uma linha */
function enderecoTexto(e: Empresa): string | null {
  const rua = [e.logradouro, e.numero].filter(Boolean).join(', ');
  const cidade = [e.cidade, e.uf].filter(Boolean).join('/');
  return [rua, e.bairro, cidade].filter(Boolean).join(' – ') || null;
}

/** Origem da localização mostrada no formulário */
type OrigemLocal = 'gps' | 'endereco_exato' | 'endereco_aprox' | 'salva';

function EmpresaModal({
  aberto,
  empresa,
  podeEditar,
  usarLimitacoes,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  empresa: Empresa | null;
  podeEditar: boolean;
  usarLimitacoes: boolean;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [form, setForm] = useState<Empresa>(NOVA);
  const [origem, setOrigem] = useState<OrigemLocal | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const [buscando, setBuscando] = useState<'cep' | 'endereco' | 'gps' | null>(null);
  const [confirmarExclusao, setConfirmarExclusao] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    const e = empresa ?? NOVA;
    setForm({ ...NOVA, ...e, cnpj: mascaraCNPJ(e.cnpj ?? ''), cep: mascaraCEP(e.cep ?? ''), telefone: mascaraTelefone(e.telefone ?? '') });
    setOrigem(e.local ? 'salva' : null);
    setErro(null);
    setConfirmarExclusao(false);
  }, [aberto, empresa]);

  const set = <K extends keyof Empresa>(k: K, v: Empresa[K]) => setForm((f) => ({ ...f, [k]: v }));

  // CEP completo → preenche rua, bairro, cidade e UF
  const aoMudarCep = async (v: string) => {
    const cep = mascaraCEP(v);
    set('cep', cep);
    if (cep.replace(/\D/g, '').length !== 8) return;
    setBuscando('cep');
    try {
      const r = await buscarCep(cep);
      if (r) setForm((f) => ({ ...f, logradouro: r.logradouro || f.logradouro, bairro: r.bairro || f.bairro, cidade: r.cidade || f.cidade, uf: r.uf || f.uf }));
    } catch {
      /* sem rede: o usuário digita */
    } finally {
      setBuscando(null);
    }
  };

  const raio = form.local?.raio_m ?? 150;

  const localizarPeloEndereco = async () => {
    setErro(null);
    if (!form.logradouro && !form.cep) return setErro('Preencha o endereço (ou o CEP) para buscar a localização.');
    setBuscando('endereco');
    try {
      const r = await localizarEndereco(form);
      if (!r) return setErro('Endereço não encontrado no mapa. Confira os dados ou capture a localização estando na empresa.');
      setForm((f) => ({ ...f, local: { latitude: r.lat, longitude: r.lng, raio_m: raio, precisao_m: null } }));
      setOrigem(r.exato ? 'endereco_exato' : 'endereco_aprox');
    } catch {
      setErro('Não foi possível consultar o mapa agora. Tente de novo ou capture a localização estando na empresa.');
    } finally {
      setBuscando(null);
    }
  };

  const capturarGps = async () => {
    setErro(null);
    setBuscando('gps');
    const g = await obterLocalizacao();
    setBuscando(null);
    if (g.p_latitude == null || g.p_longitude == null) {
      return setErro(`${g.p_geo_erro ?? 'Não foi possível obter a localização'}. Permita o acesso à localização e tente de novo.`);
    }
    setForm((f) => ({
      ...f,
      local: { latitude: Number(g.p_latitude!.toFixed(6)), longitude: Number(g.p_longitude!.toFixed(6)), raio_m: raio, precisao_m: g.p_precisao },
    }));
    setOrigem('gps');
    toast(`Localização capturada (precisão de ${textoDistancia(g.p_precisao ?? 0)}).`);
  };

  const salvar = async () => {
    setErro(null);
    if (!form.razao_social.trim()) return setErro('Informe a razão social.');
    setSalvando(true);
    try {
      await api('api_empresa_salvar', { p_dados: form });
      toast(empresa?.id ? 'Empresa atualizada.' : 'Empresa cadastrada.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const excluir = async () => {
    if (!empresa?.id) return;
    setSalvando(true);
    try {
      await api('api_empresa_excluir', { p_id: empresa.id });
      toast('Empresa excluída.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao excluir.');
      setConfirmarExclusao(false);
    } finally {
      setSalvando(false);
    }
  };

  const l = form.local;

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-3xl"
      titulo={empresa?.id ? 'Editar empresa' : 'Cadastrar empresa'}
      rodape={
        !podeEditar ? (
          <Button variant="secondary" onClick={onFechar}>Fechar</Button>
        ) : (
          <div className="flex w-full flex-wrap items-center justify-between gap-2">
            <div>
              {empresa?.id &&
                (confirmarExclusao ? (
                  <div className="flex items-center gap-2 text-sm">
                    <span className="text-slate-600">Excluir a empresa?</span>
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
              <Button onClick={salvar} loading={salvando}>Salvar</Button>
            </div>
          </div>
        )
      }
    >
      <AlertaErro mensagem={erro} />
      <fieldset disabled={!podeEditar} className="space-y-6">
        <section className="grid gap-4 sm:grid-cols-2">
          <Field label="Razão social" obrigatorio className="sm:col-span-2">
            <input className="input" value={form.razao_social} autoFocus onChange={(e) => set('razao_social', e.target.value)} />
          </Field>
          <Field label="Nome fantasia" dica="É o nome que aparece no topo da tela e no login.">
            <input className="input" value={form.nome_fantasia ?? ''} onChange={(e) => set('nome_fantasia', e.target.value)} />
          </Field>
          <Field label="CNPJ">
            <input className="input tabular-nums" inputMode="numeric" placeholder="00.000.000/0000-00" value={form.cnpj ?? ''}
              onChange={(e) => set('cnpj', mascaraCNPJ(e.target.value))} />
          </Field>
          <Field label="Inscrição estadual">
            <input className="input" value={form.inscricao_estadual ?? ''} onChange={(e) => set('inscricao_estadual', e.target.value)} />
          </Field>
          <Field label="Telefone">
            <input className="input tabular-nums" inputMode="tel" value={form.telefone ?? ''} onChange={(e) => set('telefone', mascaraTelefone(e.target.value))} />
          </Field>
          <Field label="E-mail" className="sm:col-span-2">
            <input className="input" type="email" value={form.email ?? ''} onChange={(e) => set('email', e.target.value)} />
          </Field>
        </section>

        <section>
          <h3 className="mb-3 text-sm font-semibold text-slate-800">Endereço</h3>
          <div className="grid gap-4 sm:grid-cols-6">
            <Field label="CEP" className="sm:col-span-2" dica={buscando === 'cep' ? 'Buscando o endereço…' : 'Preenche a rua, o bairro e a cidade.'}>
              <input className="input tabular-nums" inputMode="numeric" placeholder="00000-000" value={form.cep ?? ''} onChange={(e) => aoMudarCep(e.target.value)} />
            </Field>
            <Field label="Rua" className="sm:col-span-4">
              <input className="input" value={form.logradouro ?? ''} onChange={(e) => set('logradouro', e.target.value)} />
            </Field>
            <Field label="Número" className="sm:col-span-2">
              <input className="input" value={form.numero ?? ''} onChange={(e) => set('numero', e.target.value)} />
            </Field>
            <Field label="Complemento" className="sm:col-span-4">
              <input className="input" value={form.complemento ?? ''} onChange={(e) => set('complemento', e.target.value)} />
            </Field>
            <Field label="Bairro" className="sm:col-span-2">
              <input className="input" value={form.bairro ?? ''} onChange={(e) => set('bairro', e.target.value)} />
            </Field>
            <Field label="Cidade" className="sm:col-span-3">
              <input className="input" value={form.cidade ?? ''} onChange={(e) => set('cidade', e.target.value)} />
            </Field>
            <Field label="UF" className="sm:col-span-1">
              <select className="input" value={form.uf ?? ''} onChange={(e) => set('uf', e.target.value)}>
                <option value="" />
                {UFS.map((u) => <option key={u} value={u}>{u}</option>)}
              </select>
            </Field>
          </div>
        </section>

        <section className="rounded-xl p-4 ring-1 ring-slate-200/80">
          <div className="flex flex-wrap items-start justify-between gap-3">
            <div className="max-w-md">
              <h3 className="text-sm font-semibold text-slate-800">Local de ponto</h3>
              <p className="text-xs text-slate-500">
                Ponto de referência e raio permitido para as batidas desta empresa (cerca virtual).
                {!usarLimitacoes && ' As limitações estão desligadas em Configurações › Registro de Ponto: a localização fica guardada, mas não é conferida.'}
              </p>
            </div>
            <div className="flex flex-wrap gap-2">
              <Button variant="secondary" className="h-9" onClick={localizarPeloEndereco} loading={buscando === 'endereco'}>
                {buscando !== 'endereco' && <Search className="h-4 w-4" />} Buscar pelo endereço
              </Button>
              <Button variant="secondary" className="h-9" onClick={capturarGps} loading={buscando === 'gps'}>
                {buscando !== 'gps' && <Crosshair className="h-4 w-4" />} Usar minha localização
              </Button>
            </div>
          </div>

          {l ? (
            <div className="mt-3 space-y-3">
              <div className="flex flex-wrap items-center gap-x-4 gap-y-1 rounded-lg bg-slate-50 px-3 py-2 text-xs text-slate-600">
                <span className="font-mono">{l.latitude.toFixed(6)}, {l.longitude.toFixed(6)}</span>
                {l.precisao_m != null && <span>precisão do GPS de {textoDistancia(l.precisao_m)}</span>}
                <a href={linkMapa(l.latitude, l.longitude)} target="_blank" rel="noreferrer"
                  className="inline-flex items-center gap-1 font-medium text-primary-700 hover:underline">
                  <ExternalLink className="h-3.5 w-3.5" /> Conferir no mapa
                </a>
                {podeEditar && (
                  <button type="button" onClick={() => { set('local', null); setOrigem(null); }} className="ml-auto text-slate-400 hover:text-rose-600">
                    Remover local
                  </button>
                )}
              </div>
              {origem === 'endereco_aprox' && (
                <p className="text-xs text-accent-700">
                  O mapa achou só a rua (ou o CEP), não o número: a posição é aproximada. Confira no mapa ou, para precisão total,
                  use “Usar minha localização” estando na empresa.
                </p>
              )}
              {origem === 'endereco_exato' && (
                <p className="text-xs text-slate-500">Localização encontrada pelo endereço. Confira no mapa se o ponto está na porta da empresa.</p>
              )}
              {origem === 'gps' && l.precisao_m != null && l.precisao_m > 100 && (
                <p className="text-xs text-accent-700">A precisão está baixa ({textoDistancia(l.precisao_m)}). Capture de novo pelo celular, com o GPS ligado.</p>
              )}
              <Field label="Raio permitido (metros)" dica="Sugestão: 100 a 300 m. O GPS do celular costuma errar de 10 a 50 m." className="max-w-xs">
                <input type="number" min={10} max={50000} className="input" value={l.raio_m}
                  onChange={(e) => set('local', { ...l, raio_m: e.target.value === '' ? 0 : Number(e.target.value) })} />
              </Field>
            </div>
          ) : (
            <p className="mt-3 rounded-lg border border-dashed border-slate-200 px-3 py-2 text-xs text-slate-400">
              Sem local de ponto. Busque pelo endereço ou capture a localização estando na empresa.
            </p>
          )}
        </section>

        {empresa?.id && (
          <Switch ativo={form.ativo} onChange={(v) => set('ativo', v)} label="Empresa ativa"
            descricao="Empresas inativas não aparecem no login nem no seletor do topo." />
        )}
      </fieldset>
    </Modal>
  );
}

export default function Empresas() {
  const { usuario, recarregar } = useAuth();
  const [dados, setDados] = useState<EmpresasDados | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [modal, setModal] = useState<{ aberto: boolean; empresa: Empresa | null }>({ aberto: false, empresa: null });

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      setDados(await api<EmpresasDados>('api_empresas_listar'));
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar as empresas.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Empresas</h2>
          <p className="mt-1 text-sm text-slate-500">
            Empresas atendidas pelo sistema. Cada colaborador pertence a uma empresa, e o usuário escolhe no login em qual delas vai trabalhar.
          </p>
        </div>
        {dados?.pode_editar && (
          <Button onClick={() => setModal({ aberto: true, empresa: null })}>
            <Plus className="h-4 w-4" /> Nova empresa
          </Button>
        )}
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {dados === null && !erro ? (
        <div className="grid gap-4 md:grid-cols-2">
          {[0, 1].map((i) => <div key={i} className="card h-40 animate-pulse" />)}
        </div>
      ) : dados && dados.empresas.length === 0 ? (
        <div className="card">
          <EmptyState icon={Building2} titulo="Nenhuma empresa cadastrada" />
        </div>
      ) : (
        <div className="grid gap-4 md:grid-cols-2">
          {dados?.empresas.map((e) => (
            <article key={e.id} className={clsx('card flex flex-col gap-4 p-5', !e.ativo && 'opacity-60')}>
              <div className="flex items-start justify-between gap-3">
                <div className="flex min-w-0 items-start gap-3">
                  <span className="flex h-11 w-11 shrink-0 items-center justify-center rounded-xl bg-primary-50 text-primary-700">
                    <Building2 className="h-5 w-5" />
                  </span>
                  <div className="min-w-0">
                    <p className="truncate font-semibold text-slate-900">{e.nome_fantasia || e.razao_social}</p>
                    {e.nome_fantasia && <p className="truncate text-xs text-slate-500">{e.razao_social}</p>}
                    <p className="text-xs tabular-nums text-slate-400">{e.cnpj ? `CNPJ ${mascaraCNPJ(e.cnpj)}` : 'CNPJ não informado'}</p>
                  </div>
                </div>
                <div className="flex shrink-0 flex-col items-end gap-1">
                  {e.id === usuario?.empresa?.id && <Badge tone="primary" dot={false}>Conectado</Badge>}
                  {!e.ativo && <Badge tone="slate" dot={false}>Inativa</Badge>}
                </div>
              </div>

              <div className="space-y-1.5 text-xs text-slate-600">
                <p>{enderecoTexto(e) ?? <span className="text-slate-400">Endereço não informado</span>}</p>
                {e.local ? (
                  <a href={linkMapa(e.local.latitude, e.local.longitude)} target="_blank" rel="noreferrer"
                    className="inline-flex items-center gap-1.5 font-medium text-primary-700 hover:underline">
                    <MapPin className="h-3.5 w-3.5" /> Local de ponto · raio de {textoDistancia(e.local.raio_m)}
                  </a>
                ) : (
                  <p className="inline-flex items-center gap-1.5 text-accent-700"><MapPinOff className="h-3.5 w-3.5" /> Sem local de ponto</p>
                )}
              </div>

              <div className="mt-auto flex items-center justify-between gap-3 border-t border-slate-100 pt-3 text-xs text-slate-500">
                <span>
                  {e.colaboradores ?? 0} colaborador(es)
                  {!!e.batidas_30d && ` · ${e.batidas_30d} batidas em 30 dias`}
                  {!!e.fora_30d && <span className="text-accent-700"> ({e.fora_30d} fora do local)</span>}
                </span>
                <Button variant="ghost" className="h-8" onClick={() => setModal({ aberto: true, empresa: e })}>
                  <Pencil className="h-3.5 w-3.5" /> {dados?.pode_editar ? 'Editar' : 'Ver'}
                </Button>
              </div>
            </article>
          ))}
        </div>
      )}

      <EmpresaModal
        aberto={modal.aberto}
        empresa={modal.empresa}
        podeEditar={!!dados?.pode_editar}
        usarLimitacoes={!!dados?.usar_limitacoes_ponto}
        onFechar={() => setModal({ aberto: false, empresa: null })}
        onSalvo={() => {
          setModal({ aberto: false, empresa: null });
          carregar();
          recarregar().catch(() => undefined);
        }}
      />
    </div>
  );
}
