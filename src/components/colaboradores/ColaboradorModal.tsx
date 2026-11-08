import clsx from 'clsx';
import { CalendarClock, History, KeyRound, Loader2, Plus } from 'lucide-react';
import { useEffect, useState, type ReactNode } from 'react';
import { Link } from 'react-router-dom';
import { SITUACAO } from '@/components/ui/Badge';
import { Button } from '@/components/ui/Button';
import { AlertaErro, Field, Switch } from '@/components/ui/Field';
import { Modal } from '@/components/ui/Modal';
import { useToast } from '@/components/ui/Toast';
import { formatData, toISODate } from '@/lib/format';
import { mascaraCEP, mascaraCPF, mascaraPIS, mascaraTelefone } from '@/lib/mask';
import { api } from '@/lib/supabase';
import type {
  AcessoColaborador,
  CadastrosAuxiliares,
  Colaborador,
  HistoricoItem,
  JornadaVigencia,
  Opcao,
  SituacaoColaborador,
} from '@/lib/types';

const UFS = 'AC AL AP AM BA CE DF ES GO MA MT MS MG PA PB PR PE PI RJ RN RS RO RR SC SP SE TO'.split(' ');

type Aba = 'pessoais' | 'profissional' | 'endereco' | 'acesso' | 'historico';

// Alterações que valem a partir de uma data (vigência) e entram no histórico
const CAMPOS_COM_VIGENCIA = ['jornada_id', 'cargo_id', 'departamento_id', 'situacao'] as const;

function vazio(): Colaborador {
  return {
    matricula: '', nome: '', nome_social: '', cpf: '', pis: '', rg: '', data_nascimento: '', sexo: '',
    email: '', telefone: '', cep: '', logradouro: '', numero: '', complemento: '', bairro: '', cidade: '', uf: '',
    cargo_id: '', departamento_id: '', jornada_id: '', perfil_evento_id: '', gestor_id: '',
    data_admissao: '', data_desligamento: '', situacao: 'ativo', salario: '', observacoes: '',
    // Novo colaborador: controle começa hoje, para não gerar faltas desde uma admissão antiga
    controla_ponto: true, controle_ponto_inicio: toISODate(new Date()), data_vigencia: toISODate(new Date()),
  };
}

/** Converte o registro do banco (com nulls) para o formulário (strings), aplicando máscaras. */
function doBanco(r: Record<string, unknown>): Colaborador {
  const base = vazio();
  const out: Record<string, unknown> = { ...base };
  for (const k of Object.keys(base)) out[k] = r[k] == null ? '' : String(r[k]);
  out.id = r.id;
  out.historico = r.historico;
  out.jornadas_vigencias = r.jornadas_vigencias;
  out.acesso = r.acesso;
  out.controla_ponto = r.controla_ponto !== false;
  out.data_vigencia = toISODate(new Date());
  out.cpf = mascaraCPF(String(out.cpf));
  out.pis = mascaraPIS(String(out.pis));
  out.telefone = mascaraTelefone(String(out.telefone));
  out.cep = mascaraCEP(String(out.cep));
  return out as unknown as Colaborador;
}

/** Select com criação rápida de um novo item (departamento / cargo). */
function SelectComCriacao({
  label,
  valor,
  opcoes,
  onChange,
  onCriar,
}: {
  label: string;
  valor: string;
  opcoes: Opcao[];
  onChange: (id: string) => void;
  onCriar: (nome: string) => Promise<void>;
}) {
  const [criando, setCriando] = useState(false);
  const [nome, setNome] = useState('');
  const [salvando, setSalvando] = useState(false);

  const confirmar = async () => {
    if (!nome.trim()) return;
    setSalvando(true);
    try {
      await onCriar(nome.trim());
      setCriando(false);
      setNome('');
    } finally {
      setSalvando(false);
    }
  };

  return (
    <div>
      <div className="mb-1.5 flex items-center justify-between">
        <span className="label mb-0">{label}</span>
        {!criando && (
          <button type="button" onClick={() => setCriando(true)} className="flex items-center gap-0.5 text-[11px] font-medium text-primary-600 hover:text-primary-800">
            <Plus className="h-3 w-3" /> Novo
          </button>
        )}
      </div>
      {criando ? (
        <div className="flex gap-1.5">
          <input
            className="input"
            autoFocus
            value={nome}
            placeholder={`Nome do ${label.toLowerCase()}`}
            onChange={(e) => setNome(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') { e.preventDefault(); confirmar(); }
              if (e.key === 'Escape') { e.stopPropagation(); setCriando(false); }
            }}
          />
          <Button type="button" className="h-10 px-3" onClick={confirmar} loading={salvando}>Criar</Button>
          <Button type="button" variant="ghost" className="h-10 px-2" onClick={() => setCriando(false)}>✕</Button>
        </div>
      ) : (
        <select className="input" value={valor} onChange={(e) => onChange(e.target.value)} aria-label={label}>
          <option value="">Selecione…</option>
          {opcoes.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
        </select>
      )}
    </div>
  );
}

function Historico({ itens }: { itens: HistoricoItem[] }) {
  if (itens.length === 0) return <p className="py-8 text-center text-sm text-slate-400">Sem movimentações registradas.</p>;
  const cor: Record<string, string> = {
    admissao: 'bg-emerald-500', situacao: 'bg-accent-500', cargo: 'bg-primary-600',
    departamento: 'bg-sky-500', jornada: 'bg-violet-500', perfil_evento: 'bg-amber-500', cadastro: 'bg-slate-400',
  };
  return (
    <ol className="relative space-y-5 border-l border-slate-200 pl-6">
      {itens.map((h) => (
        <li key={h.id} className="relative">
          <span className={clsx('absolute -left-[29px] top-1 h-3 w-3 rounded-full ring-4 ring-white', cor[h.tipo] ?? 'bg-slate-400')} />
          <p className="text-sm font-medium text-slate-800">{h.descricao}</p>
          {h.tipo !== 'admissao' && h.dados_novos && (
            <div className="mt-1 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-500">
              {Object.keys(h.dados_novos).map((k) => (
                <span key={k}>
                  <span className="text-slate-400">{k.replace(/_id$/, '').replace(/_/g, ' ')}:</span>{' '}
                  <span className="line-through decoration-slate-300">{String(h.dados_anteriores?.[k] ?? '—')}</span>
                  {' → '}
                  <span className="font-medium text-slate-700">{String(h.dados_novos?.[k] ?? '—')}</span>
                </span>
              ))}
            </div>
          )}
          <p className="mt-1 text-[11px] text-slate-400">
            <span className="mr-1.5 rounded-md bg-primary-50 px-1.5 py-0.5 font-medium text-primary-700">
              Vigência {formatData(h.data_vigencia, { day: '2-digit', month: '2-digit', year: 'numeric' })}
            </span>
            registrado em {new Date(h.created_at).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}
            {h.usuario && ` · por ${h.usuario}`}
          </p>
        </li>
      ))}
    </ol>
  );
}

function VigenciasJornada({ itens }: { itens: JornadaVigencia[] }) {
  if (itens.length === 0) return null;
  const dt = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });
  return (
    <div className="rounded-xl bg-slate-50 p-3 sm:col-span-2">
      <p className="mb-2 flex items-center gap-1.5 text-xs font-medium text-slate-600">
        <CalendarClock className="h-3.5 w-3.5" /> Jornadas por período
      </p>
      <ul className="space-y-1 text-xs">
        {itens.map((v) => (
          <li key={v.data_inicio} className="flex justify-between gap-3">
            <span className="font-medium text-slate-700">{v.jornada}</span>
            <span className="tabular-nums text-slate-500">
              {dt(v.data_inicio)} → {v.data_fim ? dt(v.data_fim) : 'atual'}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

function AcessoPonto({
  colaboradorId,
  matricula,
  acesso,
  podeEditar,
  onSalvo,
}: {
  colaboradorId: string;
  matricula: string;
  acesso: AcessoColaborador | null | undefined;
  podeEditar: boolean;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [login, setLogin] = useState(acesso?.login ?? matricula);
  const [senha, setSenha] = useState('');
  const [ativo, setAtivo] = useState(acesso ? acesso.status === 'ativo' : true);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);
  const outroPerfil = acesso && acesso.perfil !== 'Colaborador';

  const salvar = async () => {
    setErro(null);
    if (!acesso && senha.length < 6) return setErro('Defina uma senha com ao menos 6 caracteres.');
    setSalvando(true);
    try {
      await api('api_colaborador_acesso_salvar', {
        p_colaborador: colaboradorId, p_login: login, p_senha: senha || null, p_ativo: ativo,
      });
      toast(acesso ? 'Acesso atualizado.' : 'Acesso criado. O colaborador já pode bater o ponto.');
      setSenha('');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar o acesso.');
    } finally {
      setSalvando(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex items-start gap-3 rounded-xl bg-primary-50/60 p-4 text-sm text-primary-900">
        <KeyRound className="mt-0.5 h-4 w-4 shrink-0 text-primary-600" />
        <p>
          Com este acesso, o colaborador entra no GePonto com login e senha próprios e vê apenas a tela
          <strong className="font-semibold"> Registrar ponto</strong>, onde faz as marcações e acompanha o banco de horas.
        </p>
      </div>

      <AlertaErro mensagem={erro} />

      {outroPerfil ? (
        <p className="text-sm text-slate-600">
          Este colaborador usa o login <strong>{acesso.login}</strong> com perfil <strong>{acesso.perfil}</strong>.
          Altere-o em Usuários &amp; Permissões.
        </p>
      ) : (
        <fieldset disabled={!podeEditar} className="grid gap-4 sm:grid-cols-2">
          <Field label="Login" obrigatorio dica="Sugestão: a matrícula do colaborador.">
            <input className="input" value={login} onChange={(e) => setLogin(e.target.value)} autoComplete="off" />
          </Field>
          <Field label={acesso ? 'Nova senha' : 'Senha'} obrigatorio={!acesso}
            dica={acesso ? 'Deixe em branco para manter a senha atual.' : 'Mínimo de 6 caracteres.'}>
            <input type="password" className="input" value={senha} onChange={(e) => setSenha(e.target.value)} autoComplete="new-password" />
          </Field>
          <div className="sm:col-span-2">
            <Switch ativo={ativo} onChange={setAtivo} label="Acesso liberado" descricao="Desative para bloquear o login do colaborador." />
          </div>
          {acesso?.ultimo_acesso && (
            <p className="text-xs text-slate-400 sm:col-span-2">
              Último acesso em {new Date(acesso.ultimo_acesso).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}
            </p>
          )}
          {podeEditar && (
            <div className="sm:col-span-2">
              <Button onClick={salvar} loading={salvando}>{acesso ? 'Salvar acesso' : 'Criar acesso'}</Button>
            </div>
          )}
        </fieldset>
      )}
    </div>
  );
}

function Grid({ children }: { children: ReactNode }) {
  return <div className="grid gap-4 sm:grid-cols-2">{children}</div>;
}

export function ColaboradorModal({
  aberto,
  colaboradorId,
  podeEditar,
  onFechar,
  onSalvo,
}: {
  aberto: boolean;
  colaboradorId: string | null;
  podeEditar: boolean;
  onFechar: () => void;
  onSalvo: () => void;
}) {
  const toast = useToast();
  const [aba, setAba] = useState<Aba>('pessoais');
  const [form, setForm] = useState<Colaborador>(vazio);
  const [aux, setAux] = useState<CadastrosAuxiliares | null>(null);
  const [carregando, setCarregando] = useState(false);
  const [salvando, setSalvando] = useState(false);
  const [erro, setErro] = useState<string | null>(null);
  const [original, setOriginal] = useState<Colaborador | null>(null);
  const [tentouSalvar, setTentouSalvar] = useState(false);

  useEffect(() => {
    if (!aberto) return;
    setAba('pessoais');
    setErro(null);
    setTentouSalvar(false);
    setCarregando(true);
    Promise.all([
      api<CadastrosAuxiliares>('api_cadastros_auxiliares'),
      colaboradorId ? api<Record<string, unknown>>('api_colaborador_obter', { p_id: colaboradorId }) : Promise.resolve(null),
    ])
      .then(([a, c]) => {
        setAux(a);
        const f = c ? doBanco(c) : vazio();
        setForm(f);
        setOriginal(c ? f : null);
      })
      .catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar.'))
      .finally(() => setCarregando(false));
  }, [aberto, colaboradorId]);

  const set = <K extends keyof Colaborador>(k: K, v: Colaborador[K]) => setForm((f) => ({ ...f, [k]: v }));

  // Recarrega só o acesso depois de criá-lo/alterá-lo, sem perder o que está sendo editado
  const recarregarAcesso = async () => {
    if (!form.id) return;
    const c = await api<Record<string, unknown>>('api_colaborador_obter', { p_id: form.id });
    setForm((f) => ({ ...f, acesso: c.acesso as AcessoColaborador | null }));
  };

  const alterouComVigencia = !!original && CAMPOS_COM_VIGENCIA.some((k) => form[k] !== original[k]);
  const perfisEventos = aux?.perfis_eventos ?? [];
  const admissaoInvalida = tentouSalvar && !form.data_admissao;

  const criarAuxiliar = (tipo: 'departamentos' | 'cargos', campo: 'departamento_id' | 'cargo_id') => async (nome: string) => {
    try {
      const novo = await api<Opcao>(tipo === 'departamentos' ? 'api_departamento_criar' : 'api_cargo_criar', { p_nome: nome });
      setAux((a) => a && {
        ...a,
        [tipo]: [...a[tipo].filter((o) => o.id !== novo.id), novo].sort((x, y) => x.nome.localeCompare(y.nome)),
      });
      set(campo, novo.id);
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao criar.');
    }
  };

  const salvar = async () => {
    setErro(null);
    setTentouSalvar(true);
    // Leva o usuário à aba do primeiro campo obrigatório vazio
    if (!form.nome.trim() || !form.matricula.trim() || form.cpf.replace(/\D/g, '').length !== 11) {
      setAba('pessoais');
      setErro('Preencha nome, matrícula e um CPF válido.');
      return;
    }
    if (!form.data_admissao) {
      setAba('profissional');
      setErro('A data de admissão é obrigatória.');
      return;
    }
    if (form.controla_ponto && form.controle_ponto_inicio && form.controle_ponto_inicio < form.data_admissao) {
      setAba('profissional');
      setErro('O controle de ponto não pode começar antes da admissão.');
      return;
    }
    if (alterouComVigencia && (!form.data_vigencia || form.data_vigencia < form.data_admissao)) {
      setAba('profissional');
      setErro('Informe uma data de vigência igual ou posterior à admissão.');
      return;
    }
    setSalvando(true);
    try {
      const dados: Partial<Colaborador> = { ...form };
      delete dados.historico;
      delete dados.jornadas_vigencias;
      delete dados.acesso;
      // "1.234,56" e "2.500" → formato brasileiro; "2500.00" (vindo do banco) segue como está
      const salario = form.salario.includes(',')
        ? form.salario.replace(/\./g, '').replace(',', '.')
        : /^\d{1,3}(\.\d{3})+$/.test(form.salario)
          ? form.salario.replace(/\./g, '')
          : form.salario;
      await api('api_colaborador_salvar', { p_dados: { ...dados, salario } });
      toast(form.id ? 'Colaborador atualizado.' : 'Colaborador cadastrado.');
      onSalvo();
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao salvar.');
    } finally {
      setSalvando(false);
    }
  };

  const abas: { chave: Aba; label: string }[] = [
    { chave: 'pessoais', label: 'Dados pessoais' },
    { chave: 'profissional', label: 'Profissional' },
    { chave: 'endereco', label: 'Endereço' },
    ...(form.id
      ? [
          { chave: 'acesso' as Aba, label: 'Acesso ao ponto' },
          { chave: 'historico' as Aba, label: 'Histórico' },
        ]
      : []),
  ];

  return (
    <Modal
      aberto={aberto}
      onFechar={onFechar}
      largura="max-w-3xl"
      titulo={colaboradorId ? form.nome || 'Colaborador' : 'Novo colaborador'}
      descricao={colaboradorId ? `Matrícula ${form.matricula}` : 'Preencha os dados pessoais e profissionais.'}
      rodape={
        <>
          <Button variant="secondary" onClick={onFechar}>{podeEditar ? 'Cancelar' : 'Fechar'}</Button>
          {podeEditar && aba !== 'historico' && aba !== 'acesso' && (
            <Button onClick={salvar} loading={salvando} disabled={carregando}>Salvar colaborador</Button>
          )}
        </>
      }
    >
      <div className="-mt-1 mb-5 flex gap-1 overflow-x-auto border-b border-slate-100">
        {abas.map((a) => (
          <button
            key={a.chave}
            type="button"
            onClick={() => setAba(a.chave)}
            className={clsx(
              'flex shrink-0 items-center gap-1.5 border-b-2 px-3 pb-2.5 text-sm font-medium transition',
              aba === a.chave ? 'border-accent-500 text-primary-700' : 'border-transparent text-slate-500 hover:text-slate-700',
            )}
          >
            {a.chave === 'historico' && <History className="h-3.5 w-3.5" />}
            {a.chave === 'acesso' && <KeyRound className="h-3.5 w-3.5" />}
            {a.label}
          </button>
        ))}
      </div>

      <AlertaErro mensagem={erro} />

      {carregando ? (
        <div className="flex justify-center py-16"><Loader2 className="h-6 w-6 animate-spin text-primary-400" /></div>
      ) : (
        <fieldset disabled={!podeEditar}>
          {aba === 'pessoais' && (
            <Grid>
              <Field label="Nome completo" obrigatorio className="sm:col-span-2">
                <input className="input" value={form.nome} onChange={(e) => set('nome', e.target.value)} autoFocus />
              </Field>
              <Field label="Matrícula" obrigatorio>
                <input className="input" value={form.matricula} onChange={(e) => set('matricula', e.target.value)} />
              </Field>
              <Field label="Nome social">
                <input className="input" value={form.nome_social} onChange={(e) => set('nome_social', e.target.value)} />
              </Field>
              <Field label="CPF" obrigatorio>
                <input className="input tabular-nums" inputMode="numeric" value={form.cpf}
                  onChange={(e) => set('cpf', mascaraCPF(e.target.value))} placeholder="000.000.000-00" />
              </Field>
              <Field label="PIS / NIS">
                <input className="input tabular-nums" inputMode="numeric" value={form.pis}
                  onChange={(e) => set('pis', mascaraPIS(e.target.value))} placeholder="000.00000.00-0" />
              </Field>
              <Field label="RG">
                <input className="input" value={form.rg} onChange={(e) => set('rg', e.target.value)} />
              </Field>
              <Field label="Data de nascimento">
                <input type="date" className="input" value={form.data_nascimento} onChange={(e) => set('data_nascimento', e.target.value)} />
              </Field>
              <Field label="Sexo">
                <select className="input" value={form.sexo} onChange={(e) => set('sexo', e.target.value)}>
                  <option value="">Não informado</option>
                  <option value="F">Feminino</option>
                  <option value="M">Masculino</option>
                  <option value="O">Outro</option>
                </select>
              </Field>
              <Field label="Telefone">
                <input className="input tabular-nums" inputMode="tel" value={form.telefone}
                  onChange={(e) => set('telefone', mascaraTelefone(e.target.value))} placeholder="(00) 00000-0000" />
              </Field>
              <Field label="E-mail" className="sm:col-span-2">
                <input type="email" className="input" value={form.email} onChange={(e) => set('email', e.target.value)} />
              </Field>
            </Grid>
          )}

          {aba === 'profissional' && aux && (
            <Grid>
              <Field label="Data de admissão" obrigatorio>
                <input
                  type="date"
                  className={clsx('input', admissaoInvalida && 'border-rose-400 ring-4 ring-rose-100')}
                  value={form.data_admissao}
                  onChange={(e) => {
                    const adm = e.target.value;
                    // O controle de ponto nunca começa antes da admissão
                    setForm((f) => ({
                      ...f,
                      data_admissao: adm,
                      controle_ponto_inicio:
                        adm && f.controle_ponto_inicio && f.controle_ponto_inicio < adm ? adm : f.controle_ponto_inicio,
                    }));
                  }}
                  aria-invalid={admissaoInvalida}
                />
                {admissaoInvalida && <span className="mt-1 block text-[11px] font-medium text-rose-600">Campo obrigatório</span>}
              </Field>
              <Field label="Situação">
                <select className="input" value={form.situacao} onChange={(e) => set('situacao', e.target.value as SituacaoColaborador)}>
                  {(Object.keys(SITUACAO) as SituacaoColaborador[]).map((s) => <option key={s} value={s}>{SITUACAO[s].label}</option>)}
                </select>
              </Field>

              {/* Controle de ponto */}
              <div className="rounded-xl p-3 ring-1 ring-slate-200/80 sm:col-span-2">
                <div className="grid items-center gap-3 sm:grid-cols-[1fr_200px]">
                  <Switch
                    ativo={form.controla_ponto}
                    onChange={(v) => set('controla_ponto', v)}
                    label="Controlar ponto"
                    descricao="Apura batidas, faltas, atrasos e banco de horas deste colaborador."
                  />
                  {form.controla_ponto && (
                    <Field label="Controlar ponto a partir de" dica={!form.controle_ponto_inicio ? 'Em branco: desde a admissão.' : undefined}>
                      <input
                        type="date"
                        className="input"
                        value={form.controle_ponto_inicio}
                        min={form.data_admissao || undefined}
                        onChange={(e) => set('controle_ponto_inicio', e.target.value)}
                      />
                    </Field>
                  )}
                </div>
              </div>

              <SelectComCriacao label="Cargo" valor={form.cargo_id} opcoes={aux.cargos}
                onChange={(v) => set('cargo_id', v)} onCriar={criarAuxiliar('cargos', 'cargo_id')} />
              <SelectComCriacao label="Departamento" valor={form.departamento_id} opcoes={aux.departamentos}
                onChange={(v) => set('departamento_id', v)} onCriar={criarAuxiliar('departamentos', 'departamento_id')} />
              <Field
                label="Jornada de trabalho"
                dica={aux.jornadas.length === 0 && (
                  <>Nenhuma jornada ativa. <Link to="/cadastros/jornadas" className="font-medium text-primary-600 underline" onClick={onFechar}>Cadastre uma jornada</Link>.</>
                )}
              >
                <select className="input" value={form.jornada_id} onChange={(e) => set('jornada_id', e.target.value)}>
                  <option value="">Selecione…</option>
                  {/* Jornada que foi desativada depois: continua aparecendo para quem já a usa */}
                  {form.jornada_id && !aux.jornadas.some((o) => o.id === form.jornada_id) && (
                    <option value={form.jornada_id}>
                      {form.jornadas_vigencias?.find((v) => v.jornada_id === form.jornada_id)?.jornada ?? 'Jornada atual'} (inativa)
                    </option>
                  )}
                  {aux.jornadas.map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
                </select>
              </Field>
              <Field
                label="Perfil de eventos"
                dica="Tolerâncias, percentual de hora extra por dia, adicional noturno e banco de horas."
              >
                <select className="input" value={form.perfil_evento_id} onChange={(e) => set('perfil_evento_id', e.target.value)}>
                  {!form.perfil_evento_id && (
                    <option value="">
                      Perfil padrão{perfisEventos.find((p) => p.padrao) ? ` (${perfisEventos.find((p) => p.padrao)!.nome})` : ''}
                    </option>
                  )}
                  {/* Perfil desativado depois: continua aparecendo para quem já o usa */}
                  {form.perfil_evento_id && !perfisEventos.some((o) => o.id === form.perfil_evento_id) && (
                    <option value={form.perfil_evento_id}>Perfil atual (inativo)</option>
                  )}
                  {perfisEventos.map((o) => <option key={o.id} value={o.id}>{o.nome}{o.padrao ? ' · padrão' : ''}</option>)}
                </select>
              </Field>
              <Field label="Gestor imediato">
                <select className="input" value={form.gestor_id} onChange={(e) => set('gestor_id', e.target.value)}>
                  <option value="">Nenhum</option>
                  {aux.gestores.filter((g) => g.id !== form.id).map((o) => <option key={o.id} value={o.id}>{o.nome}</option>)}
                </select>
              </Field>

              {/* Vigência: só aparece quando jornada, cargo, departamento ou situação mudam */}
              {alterouComVigencia && (
                <div className="rounded-xl bg-accent-50 p-3 ring-1 ring-accent-200 sm:col-span-2">
                  <div className="grid items-end gap-3 sm:grid-cols-[1fr_200px]">
                    <p className="text-sm text-accent-900">
                      <strong className="font-semibold">A partir de quando vale esta alteração?</strong>
                      <span className="mt-0.5 block text-xs text-accent-800/80">
                        {form.jornada_id !== original?.jornada_id
                          ? 'A nova jornada é aplicada na apuração a partir desta data; os dias anteriores continuam com a jornada antiga.'
                          : 'A data fica registrada no histórico do colaborador.'}
                      </span>
                    </p>
                    <Field label="Vigência" obrigatorio>
                      <input type="date" className="input" value={form.data_vigencia} min={form.data_admissao || undefined}
                        onChange={(e) => set('data_vigencia', e.target.value)} />
                    </Field>
                  </div>
                </div>
              )}
              <VigenciasJornada itens={form.jornadas_vigencias ?? []} />

              {form.situacao === 'desligado' && (
                <Field label="Data de desligamento" dica="Se ficar em branco, será usada a data de hoje.">
                  <input type="date" className="input" value={form.data_desligamento} min={form.data_admissao}
                    onChange={(e) => set('data_desligamento', e.target.value)} />
                </Field>
              )}
              <Field label="Salário (R$)">
                <input className="input tabular-nums" inputMode="decimal" value={form.salario}
                  onChange={(e) => set('salario', e.target.value.replace(/[^\d.,]/g, ''))} placeholder="0,00" />
              </Field>
              <Field label="Observações" className="sm:col-span-2">
                <textarea className="input h-24 py-2" value={form.observacoes} onChange={(e) => set('observacoes', e.target.value)} />
              </Field>
            </Grid>
          )}

          {aba === 'endereco' && (
            <Grid>
              <Field label="CEP">
                <input className="input tabular-nums" inputMode="numeric" value={form.cep}
                  onChange={(e) => set('cep', mascaraCEP(e.target.value))} placeholder="00000-000" />
              </Field>
              <div className="hidden sm:block" />
              <Field label="Logradouro" className="sm:col-span-2">
                <input className="input" value={form.logradouro} onChange={(e) => set('logradouro', e.target.value)} />
              </Field>
              <Field label="Número">
                <input className="input" value={form.numero} onChange={(e) => set('numero', e.target.value)} />
              </Field>
              <Field label="Complemento">
                <input className="input" value={form.complemento} onChange={(e) => set('complemento', e.target.value)} />
              </Field>
              <Field label="Bairro">
                <input className="input" value={form.bairro} onChange={(e) => set('bairro', e.target.value)} />
              </Field>
              <div className="grid grid-cols-[1fr_96px] gap-3">
                <Field label="Cidade">
                  <input className="input" value={form.cidade} onChange={(e) => set('cidade', e.target.value)} />
                </Field>
                <Field label="UF">
                  <select className="input" value={form.uf} onChange={(e) => set('uf', e.target.value)}>
                    <option value="">—</option>
                    {UFS.map((u) => <option key={u}>{u}</option>)}
                  </select>
                </Field>
              </div>
            </Grid>
          )}

          {aba === 'historico' && <Historico itens={form.historico ?? []} />}
        </fieldset>
      )}

      {!carregando && aba === 'acesso' && form.id && (
        <AcessoPonto
          colaboradorId={form.id}
          matricula={form.matricula}
          acesso={form.acesso}
          podeEditar={podeEditar}
          onSalvo={recarregarAcesso}
        />
      )}

      {form.id && aba !== 'historico' && aba !== 'acesso' && !carregando && (
        <p className="mt-5 text-[11px] text-slate-400">
          Admitido em {form.data_admissao ? formatData(form.data_admissao, { dateStyle: 'long' }) : '—'}. Alterações ficam registradas no histórico.
        </p>
      )}
    </Modal>
  );
}
