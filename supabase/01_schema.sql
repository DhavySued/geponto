-- =============================================================================
-- GePonto — ERP de Controle de Ponto
-- 01_schema.sql — Tipos, tabelas, índices e triggers
--
-- Execute no SQL Editor do Supabase na ordem:
--   01_schema.sql → 02_functions.sql → 03_seed.sql → (opcional) 04_dados_demo.sql
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- Tipos enumerados
-- -----------------------------------------------------------------------------
do $$ begin
  create type situacao_colaborador as enum ('ativo', 'afastado', 'desligado', 'ferias');
exception when duplicate_object then null; end $$;

do $$ begin
  create type status_usuario as enum ('ativo', 'inativo', 'bloqueado');
exception when duplicate_object then null; end $$;

do $$ begin
  create type origem_batida as enum ('relogio', 'web', 'mobile', 'manual', 'importacao');
exception when duplicate_object then null; end $$;

do $$ begin
  create type status_batida as enum ('valida', 'desconsiderada');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_lancamento_bh as enum ('credito', 'debito', 'compensacao', 'ajuste');
exception when duplicate_object then null; end $$;
-- Conversão do saldo em pagamento/desconto (menu Conversão do Banco de Horas)
alter type tipo_lancamento_bh add value if not exists 'conversao';

do $$ begin
  create type origem_lancamento_bh as enum ('automatico', 'manual');
exception when duplicate_object then null; end $$;

do $$ begin
  create type tipo_ausencia as enum ('falta_justificada', 'atestado', 'ferias', 'folga', 'afastamento', 'abono');
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- Função utilitária: updated_at automático
-- -----------------------------------------------------------------------------
create or replace function fn_set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- -----------------------------------------------------------------------------
-- Empresa / configurações gerais (linha única)
-- -----------------------------------------------------------------------------
create table if not exists empresa (
  id             smallint primary key default 1 check (id = 1),
  razao_social   text not null,
  nome_fantasia  text,
  cnpj           text,
  endereco       text,
  fuso_horario   text not null default 'America/Sao_Paulo',
  logo_url       text,
  updated_at     timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Segurança: páginas, perfis, permissões, usuários e sessões
-- (autenticação própria — NÃO usa Supabase Auth)
-- -----------------------------------------------------------------------------
create table if not exists paginas (
  chave   text primary key,             -- ex.: 'colaboradores'
  nome    text not null,
  grupo   text not null,                -- Dashboard | Cadastros | Movimentos | Relatórios
  ordem   smallint not null default 0
);

create table if not exists perfis (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null unique,
  descricao   text,
  is_admin    boolean not null default false,   -- acesso irrestrito
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Abrangência dos dados que o perfil enxerga:
--   todos   → todos os colaboradores
--   equipe  → o próprio colaborador vinculado e seus subordinados diretos (gestor_id)
--   proprio → somente o colaborador vinculado ao usuário
-- Bancos antigos recebem a coluna com os padrões dos perfis-semente.
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'perfis' and column_name = 'abrangencia') then
    alter table perfis add column abrangencia text not null default 'todos'
      constraint perfis_abrangencia_check check (abrangencia in ('todos', 'equipe', 'proprio'));
    update perfis set abrangencia = 'equipe'  where nome = 'Gestor';
    update perfis set abrangencia = 'proprio' where nome = 'Colaborador';
  end if;
end $$;

create table if not exists perfil_permissoes (
  perfil_id        uuid not null references perfis(id) on delete cascade,
  pagina           text not null references paginas(chave) on delete cascade,
  pode_visualizar  boolean not null default true,
  pode_editar      boolean not null default false,
  primary key (perfil_id, pagina)
);

create table if not exists usuarios (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null,
  login              text not null,
  email              text,
  senha_hash         text not null,           -- bcrypt via pgcrypto (crypt + gen_salt('bf'))
  perfil_id          uuid not null references perfis(id),
  colaborador_id     uuid,                    -- FK adicionada após criar colaboradores
  status             status_usuario not null default 'ativo',
  tentativas_falhas  smallint not null default 0,
  bloqueado_ate      timestamptz,
  ultimo_acesso      timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
-- Obriga a troca da senha no próximo acesso (senha inicial definida pelo RH)
alter table usuarios add column if not exists trocar_senha boolean not null default false;
create unique index if not exists ux_usuarios_login on usuarios (lower(login));
create unique index if not exists ux_usuarios_email on usuarios (lower(email)) where email is not null;

create table if not exists sessoes (
  id          uuid primary key default gen_random_uuid(),
  usuario_id  uuid not null references usuarios(id) on delete cascade,
  token_hash  text not null unique,           -- sha256 do token; o token em si nunca é salvo
  expira_em   timestamptz not null,
  user_agent  text,
  created_at  timestamptz not null default now(),
  ultimo_uso  timestamptz not null default now()
);
create index if not exists ix_sessoes_usuario on sessoes (usuario_id);
create index if not exists ix_sessoes_expira on sessoes (expira_em);

-- -----------------------------------------------------------------------------
-- Estrutura organizacional
-- -----------------------------------------------------------------------------
create table if not exists departamentos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null unique,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists cargos (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null unique,
  cbo         text,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Jornadas de trabalho
-- -----------------------------------------------------------------------------
create table if not exists jornadas (
  id                       uuid primary key default gen_random_uuid(),
  nome                     text not null unique,
  descricao                text,
  -- Só horários e escala. Tolerâncias, horas extras, adicional noturno e banco de horas
  -- ficam no perfil de eventos do colaborador (tabela perfis_eventos).
  ativo                    boolean not null default true,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);

create table if not exists jornada_dias (
  jornada_id          uuid not null references jornadas(id) on delete cascade,
  dia_semana          smallint not null check (dia_semana between 0 and 6),  -- 0 = domingo
  folga               boolean not null default false,
  entrada             time,
  saida_intervalo     time,
  retorno_intervalo   time,
  saida               time,
  primary key (jornada_id, dia_semana),
  check (folga or (entrada is not null and saida is not null)),
  check ((saida_intervalo is null) = (retorno_intervalo is null))
);

create table if not exists feriados (
  id          uuid primary key default gen_random_uuid(),
  data        date not null unique,
  descricao   text not null,
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Colaboradores
-- -----------------------------------------------------------------------------
create table if not exists colaboradores (
  id                  uuid primary key default gen_random_uuid(),
  matricula           text not null unique,
  nome                text not null,
  nome_social         text,
  cpf                 text not null unique,
  pis                 text unique,
  rg                  text,
  data_nascimento     date,
  sexo                char(1) check (sexo in ('M', 'F', 'O')),
  email               text,
  telefone            text,
  cep                 text,
  logradouro          text,
  numero              text,
  complemento         text,
  bairro              text,
  cidade              text,
  uf                  char(2),
  cargo_id            uuid references cargos(id),
  departamento_id     uuid references departamentos(id),
  jornada_id          uuid references jornadas(id),
  gestor_id           uuid references colaboradores(id),
  data_admissao       date not null,
  data_desligamento   date,
  situacao            situacao_colaborador not null default 'ativo',
  salario             numeric(12,2),
  foto_url            text,
  observacoes         text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (data_desligamento is null or data_desligamento >= data_admissao)
);
create index if not exists ix_colaboradores_situacao on colaboradores (situacao);
create index if not exists ix_colaboradores_departamento on colaboradores (departamento_id);

do $$ begin
  alter table usuarios
    add constraint fk_usuarios_colaborador foreign key (colaborador_id)
    references colaboradores(id) on delete set null;
exception when duplicate_object then null; end $$;

create table if not exists colaborador_historico (
  id                uuid primary key default gen_random_uuid(),
  colaborador_id    uuid not null references colaboradores(id) on delete cascade,
  tipo              text not null,       -- admissao | situacao | cargo | departamento | jornada | cadastro
  descricao         text not null,
  dados_anteriores  jsonb,
  dados_novos       jsonb,
  usuario_id        uuid references usuarios(id) on delete set null,
  created_at        timestamptz not null default now()
);
create index if not exists ix_hist_colaborador on colaborador_historico (colaborador_id, created_at desc);

-- Controle de ponto: o colaborador pode ter o ponto controlado só a partir de uma data
alter table colaboradores add column if not exists controla_ponto boolean not null default true;
do $$ begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'colaboradores'
                    and column_name = 'controle_ponto_inicio') then
    alter table colaboradores add column controle_ponto_inicio date;
    -- Colaboradores cadastrados antes desta coluna existir passam a ser apurados a partir
    -- da primeira batida (ou de hoje), para não gerar faltas retroativas desde a admissão.
    -- (Só em atualização: numa instalação nova ainda não há colaboradores nem a tabela de batidas.)
    if exists (select 1 from colaboradores) then
      update colaboradores c
         set controle_ponto_inicio = greatest(c.data_admissao, coalesce(
               (select min(b.data_referencia) from batidas b where b.colaborador_id = c.id),
               (now() at time zone coalesce((select fuso_horario from empresa where id = 1), 'America/Sao_Paulo'))::date));
    end if;
  end if;
end $$;

-- Data de vigência de cada alteração registrada no histórico
alter table colaborador_historico add column if not exists data_vigencia date;
update colaborador_historico set data_vigencia = created_at::date where data_vigencia is null;
alter table colaborador_historico alter column data_vigencia set default current_date;
alter table colaborador_historico alter column data_vigencia set not null;

-- Jornada vigente por período: a apuração de cada dia usa a jornada válida naquela data
create table if not exists colaborador_jornadas (
  colaborador_id  uuid not null references colaboradores(id) on delete cascade,
  data_inicio     date not null,
  jornada_id      uuid not null references jornadas(id),
  usuario_id      uuid references usuarios(id) on delete set null,
  created_at      timestamptz not null default now(),
  primary key (colaborador_id, data_inicio)
);

insert into colaborador_jornadas (colaborador_id, data_inicio, jornada_id)
select c.id, c.data_admissao, c.jornada_id
  from colaboradores c
 where c.jornada_id is not null
   and not exists (select 1 from colaborador_jornadas cj where cj.colaborador_id = c.id);

-- Até que dia o banco de horas automático já foi processado
alter table empresa add column if not exists banco_horas_processado_ate date;

-- Número sequencial das marcações feitas pelo sistema (NSR)
create sequence if not exists seq_nsr;

-- Ausências / afastamentos / férias (abonam a jornada prevista do período)
create table if not exists ausencias (
  id              uuid primary key default gen_random_uuid(),
  colaborador_id  uuid not null references colaboradores(id) on delete cascade,
  tipo            tipo_ausencia not null,
  data_inicio     date not null,
  data_fim        date not null,
  abona           boolean not null default true,
  justificativa   text,
  anexo_url       text,
  usuario_id      uuid references usuarios(id) on delete set null,
  created_at      timestamptz not null default now(),
  check (data_fim >= data_inicio)
);
create index if not exists ix_ausencias_periodo on ausencias (colaborador_id, data_inicio, data_fim);

-- -----------------------------------------------------------------------------
-- Batidas (marcações de ponto)
-- -----------------------------------------------------------------------------
create table if not exists batidas (
  id               uuid primary key default gen_random_uuid(),
  colaborador_id   uuid not null references colaboradores(id) on delete cascade,
  data_hora        timestamptz not null,
  data_referencia  date not null,         -- dia de apuração (preenchido por trigger)
  origem           origem_batida not null default 'relogio',
  status           status_batida not null default 'valida',
  nsr              bigint,                -- nº sequencial do REP (Portaria 671)
  latitude         numeric(9,6),
  longitude        numeric(9,6),
  justificativa    text,                  -- obrigatória para origem manual
  usuario_id       uuid references usuarios(id) on delete set null,
  created_at       timestamptz not null default now(),
  check (origem <> 'manual' or coalesce(length(trim(justificativa)), 0) > 0)
);
create index if not exists ix_batidas_colab_dia on batidas (colaborador_id, data_referencia, data_hora);
create index if not exists ix_batidas_dia on batidas (data_referencia);

-- Auditoria de ajustes manuais (inclusão / alteração / desconsideração)
create table if not exists batida_ajustes (
  id               uuid primary key default gen_random_uuid(),
  batida_id        uuid references batidas(id) on delete set null,
  colaborador_id   uuid not null references colaboradores(id) on delete cascade,
  acao             text not null check (acao in ('inclusao', 'alteracao', 'desconsideracao')),
  valor_anterior   timestamptz,
  valor_novo       timestamptz,
  justificativa    text not null,
  usuario_id       uuid references usuarios(id) on delete set null,
  created_at       timestamptz not null default now()
);
create index if not exists ix_ajustes_colab on batida_ajustes (colaborador_id, created_at desc);

-- -----------------------------------------------------------------------------
-- Tratamento de batidas
--   Original       → origem <> 'manual' (relógio/REP, sistema, celular, importação)
--   Incluída       → origem = 'manual'
--   Desconsiderada → status = 'desconsiderada' (fica no banco, fora da apuração)
-- -----------------------------------------------------------------------------
create table if not exists motivos_batida (
  id          uuid primary key default gen_random_uuid(),
  descricao   text not null unique,
  aplicacao   text not null default 'ambos' check (aplicacao in ('inclusao', 'desconsideracao', 'ambos')),
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);

alter table batidas add column if not exists motivo_id  uuid references motivos_batida(id);
alter table batidas add column if not exists observacao text;
-- Sentido declarado manualmente (E = entrada, S = saída). Nulo = alternância automática.
alter table batidas add column if not exists sentido    char(1) check (sentido in ('E', 'S'));
-- Turno declarado pelo RH (1º, 2º, 3º…). Nulo = calculado pela sequência de entradas do dia.
alter table batidas add column if not exists turno      smallint check (turno between 1 and 9);

alter table batida_ajustes add column if not exists motivo_id uuid references motivos_batida(id) on delete set null;
alter table batida_ajustes add column if not exists dados     jsonb;
alter table batida_ajustes alter column justificativa drop not null;
alter table batida_ajustes drop constraint if exists batida_ajustes_acao_check;
alter table batida_ajustes add constraint batida_ajustes_acao_check
  check (acao in ('inclusao', 'alteracao', 'exclusao', 'desconsideracao', 'reconsideracao', 'sentido', 'data_referencia'));

-- -----------------------------------------------------------------------------
-- Banco de horas (lançamentos; saldo = soma de minutos)
-- -----------------------------------------------------------------------------
create table if not exists banco_horas (
  id               uuid primary key default gen_random_uuid(),
  colaborador_id   uuid not null references colaboradores(id) on delete cascade,
  data             date not null,
  tipo             tipo_lancamento_bh not null,
  origem           origem_lancamento_bh not null default 'manual',
  minutos          integer not null,      -- positivo = crédito, negativo = débito
  descricao        text,
  usuario_id       uuid references usuarios(id) on delete set null,
  created_at       timestamptz not null default now(),
  check (minutos <> 0),
  check (tipo <> 'credito' or minutos > 0),
  check (tipo not in ('debito', 'compensacao') or minutos < 0)
);
create index if not exists ix_bh_colab_data on banco_horas (colaborador_id, data);
-- Um lançamento automático por colaborador/dia (reprocessamento idempotente)
create unique index if not exists ux_bh_automatico on banco_horas (colaborador_id, data) where origem = 'automatico';

-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------
drop trigger if exists trg_perfis_updated on perfis;
create trigger trg_perfis_updated before update on perfis
  for each row execute function fn_set_updated_at();

drop trigger if exists trg_usuarios_updated on usuarios;
create trigger trg_usuarios_updated before update on usuarios
  for each row execute function fn_set_updated_at();

drop trigger if exists trg_jornadas_updated on jornadas;
create trigger trg_jornadas_updated before update on jornadas
  for each row execute function fn_set_updated_at();

drop trigger if exists trg_colaboradores_updated on colaboradores;
create trigger trg_colaboradores_updated before update on colaboradores
  for each row execute function fn_set_updated_at();

-- Data de referência da batida no fuso da empresa.
-- Virada de turno: se a jornada do dia anterior atravessa a meia-noite (ex.: 22:00–06:00
-- ou 12x36 noturna) e a batida acontece até 4h depois da saída prevista, ela pertence
-- ao dia em que o turno começou. fn_jornada_dia é definida em 02_functions.sql.
create or replace function fn_batida_data_referencia()
returns trigger language plpgsql as $$
declare
  v_tz    text := coalesce((select fuso_horario from empresa where id = 1), 'America/Sao_Paulo');
  v_local timestamp;
  v_ontem record;
begin
  if tg_op = 'INSERT' and new.data_referencia is null
     or tg_op = 'UPDATE' and new.data_hora is distinct from old.data_hora then
    v_local := new.data_hora at time zone v_tz;
    new.data_referencia := v_local::date;

    select * into v_ontem from fn_jornada_dia(new.colaborador_id, v_local::date - 1);
    if found and not coalesce(v_ontem.folga, true) and v_ontem.saida < v_ontem.entrada
       and v_local::time <= v_ontem.saida + interval '4 hours'
       and v_local::time < v_ontem.entrada then
      new.data_referencia := v_local::date - 1;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_batidas_data_ref on batidas;
create trigger trg_batidas_data_ref before insert or update on batidas
  for each row execute function fn_batida_data_referencia();

-- Regra de integridade das batidas originais, garantida no banco (vale para qualquer
-- caminho de escrita, não só para a API):
--   • batida original nunca é excluída nem tem horário/colaborador alterados;
--   • só pode ser desconsiderada, ter o sentido declarado ou a data de referência alterada.
create or replace function fn_batida_proteger()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    -- Exclusão em cascata (colaborador removido) é permitida: o colaborador já não existe
    if old.origem <> 'manual' and exists (select 1 from colaboradores where id = old.colaborador_id) then
      raise exception 'Batidas originais não podem ser excluídas. Use "Desconsiderar".';
    end if;
    return old;
  end if;

  if new.origem is distinct from old.origem then
    raise exception 'A origem de uma batida não pode ser alterada.';
  end if;
  if old.origem <> 'manual' and (new.data_hora is distinct from old.data_hora
                                 or new.colaborador_id is distinct from old.colaborador_id
                                 or new.nsr is distinct from old.nsr) then
    raise exception 'Batidas originais não podem ser editadas. É possível apenas desconsiderar, declarar o sentido ou alterar a data de referência.';
  end if;
  return new;
end $$;

drop trigger if exists trg_batidas_proteger on batidas;
create trigger trg_batidas_proteger before update or delete on batidas
  for each row execute function fn_batida_proteger();

-- Histórico automático do colaborador e vigência de jornada.
-- As funções api_* informam via set_config:
--   app.usuario_id     → usuário responsável pela alteração
--   app.data_vigencia  → data a partir da qual a alteração vale (padrão: hoje)
create or replace function fn_colaborador_historico()
returns trigger language plpgsql as $$
declare
  v_usuario  uuid := nullif(current_setting('app.usuario_id', true), '')::uuid;
  v_vigencia date := coalesce(nullif(current_setting('app.data_vigencia', true), '')::date, current_date);
  v_old jsonb;
  v_new jsonb;
  v_diff_old jsonb := '{}'::jsonb;
  v_diff_new jsonb := '{}'::jsonb;
  k text;
begin
  if tg_op = 'INSERT' then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'admissao', 'Colaborador admitido em ' || to_char(new.data_admissao, 'DD/MM/YYYY'),
            to_jsonb(new) - 'created_at' - 'updated_at', v_usuario, new.data_admissao);
    if new.jornada_id is not null then
      insert into colaborador_jornadas (colaborador_id, data_inicio, jornada_id, usuario_id)
      values (new.id, new.data_admissao, new.jornada_id, v_usuario)
      on conflict (colaborador_id, data_inicio) do update set jornada_id = excluded.jornada_id;
    end if;
    return new;
  end if;

  v_old := to_jsonb(old) - 'updated_at' - 'created_at';
  v_new := to_jsonb(new) - 'updated_at' - 'created_at';
  for k in select jsonb_object_keys(v_new) loop
    if v_old -> k is distinct from v_new -> k then
      v_diff_old := v_diff_old || jsonb_build_object(k, v_old -> k);
      v_diff_new := v_diff_new || jsonb_build_object(k, v_new -> k);
    end if;
  end loop;

  if v_diff_new = '{}'::jsonb then
    return new;
  end if;

  if new.situacao is distinct from old.situacao then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'situacao', 'Situação alterada de ' || old.situacao || ' para ' || new.situacao,
            jsonb_build_object('situacao', old.situacao), jsonb_build_object('situacao', new.situacao),
            v_usuario, v_vigencia);
  end if;
  if new.cargo_id is distinct from old.cargo_id then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'cargo', 'Mudança de cargo',
            jsonb_build_object('cargo', (select nome from cargos where id = old.cargo_id)),
            jsonb_build_object('cargo', (select nome from cargos where id = new.cargo_id)), v_usuario, v_vigencia);
  end if;
  if new.departamento_id is distinct from old.departamento_id then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'departamento', 'Transferência de departamento',
            jsonb_build_object('departamento', (select nome from departamentos where id = old.departamento_id)),
            jsonb_build_object('departamento', (select nome from departamentos where id = new.departamento_id)),
            v_usuario, v_vigencia);
  end if;
  if new.jornada_id is distinct from old.jornada_id then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'jornada', 'Alteração de jornada de trabalho',
            jsonb_build_object('jornada', (select nome from jornadas where id = old.jornada_id)),
            jsonb_build_object('jornada', (select nome from jornadas where id = new.jornada_id)), v_usuario, v_vigencia);

    -- A nova jornada vale a partir da vigência; programações posteriores são substituídas
    delete from colaborador_jornadas where colaborador_id = new.id and data_inicio > v_vigencia;
    if new.jornada_id is null then
      delete from colaborador_jornadas where colaborador_id = new.id and data_inicio = v_vigencia;
    else
      insert into colaborador_jornadas (colaborador_id, data_inicio, jornada_id, usuario_id)
      values (new.id, v_vigencia, new.jornada_id, v_usuario)
      on conflict (colaborador_id, data_inicio) do update
        set jornada_id = excluded.jornada_id, usuario_id = excluded.usuario_id, created_at = now();
    end if;
  end if;

  if to_jsonb(new) ? 'perfil_evento_id' and v_old -> 'perfil_evento_id' is distinct from v_new -> 'perfil_evento_id' then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'perfil_evento', 'Mudança de perfil de eventos',
            jsonb_build_object('perfil', (select nome from perfis_eventos where id = (v_old ->> 'perfil_evento_id')::uuid)),
            jsonb_build_object('perfil', (select nome from perfis_eventos where id = (v_new ->> 'perfil_evento_id')::uuid)),
            v_usuario, v_vigencia);
  end if;

  -- Demais campos cadastrais
  v_diff_new := v_diff_new - 'situacao' - 'cargo_id' - 'departamento_id' - 'jornada_id' - 'perfil_evento_id';
  v_diff_old := v_diff_old - 'situacao' - 'cargo_id' - 'departamento_id' - 'jornada_id' - 'perfil_evento_id';
  if v_diff_new <> '{}'::jsonb then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'cadastro', 'Dados cadastrais atualizados', v_diff_old, v_diff_new, v_usuario, v_vigencia);
  end if;

  return new;
end $$;

drop trigger if exists trg_colaboradores_historico on colaboradores;
create trigger trg_colaboradores_historico after insert or update on colaboradores
  for each row execute function fn_colaborador_historico();

-- -----------------------------------------------------------------------------
-- Escalas (padrão Fortes Ponto)
--   tipo = 'semanal' → jornada_dias.dia_semana é o dia da semana (0 = domingo)
--   tipo = 'escala'  → jornada_dias.dia_semana é o dia do ciclo (0 … ciclo_dias-1),
--                      contado a partir de data_base (ex.: 12x36 = ciclo de 2 dias)
-- -----------------------------------------------------------------------------
alter table jornadas add column if not exists tipo                   text not null default 'semanal';
alter table jornadas add column if not exists ciclo_dias             smallint;
alter table jornadas add column if not exists data_base              date;

alter table jornadas drop constraint if exists jornadas_tipo_check;
alter table jornadas add constraint jornadas_tipo_check check (
  tipo = 'semanal' or (tipo = 'escala' and ciclo_dias between 2 and 60 and data_base is not null));

alter table jornada_dias drop constraint if exists jornada_dias_dia_semana_check;
alter table jornada_dias add constraint jornada_dias_dia_semana_check check (dia_semana between 0 and 59);

-- Abrangência do feriado (informativa) e abono parcial em minutos
alter table feriados add column if not exists tipo text not null default 'nacional';
alter table ausencias add column if not exists minutos integer check (minutos is null or minutos > 0);

-- Ocorrência que não abona (ex.: falta não justificada lançada pelo RH) continua contando como falta.
-- Abono parcial: tipo 'abono' com minutos preenchidos — abona só essa quantidade no dia.

-- -----------------------------------------------------------------------------
-- Fechamento de período: depois de fechado, o ponto do período fica congelado
-- (batidas, ocorrências e lançamentos manuais do banco de horas não mudam mais).
-- -----------------------------------------------------------------------------
create table if not exists fechamentos (
  id           uuid primary key default gen_random_uuid(),
  data_inicio  date not null,
  data_fim     date not null,
  observacao   text,
  usuario_id   uuid references usuarios(id) on delete set null,
  created_at   timestamptz not null default now(),
  check (data_fim >= data_inicio)
);

-- -----------------------------------------------------------------------------
-- Solicitações do colaborador (estilo Fortes Colabore) com aprovação do gestor
--   inclusao_batida → vira uma batida incluída (manual) com o motivo informado
--   abono           → vira uma ocorrência (ausência que abona) no dia ou período
-- -----------------------------------------------------------------------------
create table if not exists solicitacoes (
  id              uuid primary key default gen_random_uuid(),
  colaborador_id  uuid not null references colaboradores(id) on delete cascade,
  tipo            text not null check (tipo in ('inclusao_batida', 'abono')),
  data            date not null,
  data_fim        date,
  hora            time,
  sentido         char(1) check (sentido in ('E', 'S')),
  tipo_ausencia   tipo_ausencia,
  minutos         integer check (minutos is null or minutos > 0),
  motivo_id       uuid references motivos_batida(id),
  justificativa   text not null,
  status          text not null default 'pendente'
                  check (status in ('pendente', 'aprovada', 'reprovada', 'cancelada')),
  resposta        text,
  avaliador_id    uuid references usuarios(id) on delete set null,
  avaliado_em     timestamptz,
  batida_id       uuid references batidas(id) on delete set null,
  ausencia_id     uuid references ausencias(id) on delete set null,
  usuario_id      uuid references usuarios(id) on delete set null,
  created_at      timestamptz not null default now(),
  check (tipo <> 'inclusao_batida' or hora is not null),
  check (tipo <> 'abono' or tipo_ausencia is not null),
  check (data_fim is null or data_fim >= data)
);
create index if not exists ix_solicitacoes_status on solicitacoes (status, created_at desc);
create index if not exists ix_solicitacoes_colab on solicitacoes (colaborador_id, created_at desc);

-- -----------------------------------------------------------------------------
-- Eventos da folha de pagamento: código de cada verba no sistema de folha,
-- usado na exportação dos totais do período (layout configurável).
-- -----------------------------------------------------------------------------
create table if not exists eventos_folha (
  chave      text primary key,
  descricao  text not null,
  codigo     text,
  unidade    text not null default 'horas' check (unidade in ('horas', 'dias')),
  ativo      boolean not null default true,
  ordem      smallint not null default 0
);

-- -----------------------------------------------------------------------------
-- Perfil de eventos (padrão Fortes Ponto): regras de cálculo do ponto, separadas da jornada.
--   • tolerâncias de entrada, de saída e geral do dia;
--   • percentual de hora extra por dia (0 = domingo … 6 = sábado, 7 = feriado);
--   • limite diário de horas extras, adicional noturno e uso do banco de horas.
-- Cada colaborador tem um perfil; o perfil marcado como padrão vale para quem não informar outro.
-- Cada percentual de HE vira um evento da folha (eventos_folha.chave = 'he_<percentual>').
-- -----------------------------------------------------------------------------
create table if not exists perfis_eventos (
  id                      uuid primary key default gen_random_uuid(),
  nome                    text not null unique,
  descricao               text,
  padrao                  boolean not null default false,
  -- CLT art. 58 §1º: até 5 min por marcação, máx. 10 min/dia
  tolerancia_entrada_min  smallint not null default 5  check (tolerancia_entrada_min >= 0),
  tolerancia_saida_min    smallint not null default 5  check (tolerancia_saida_min >= 0),
  tolerancia_diaria_min   smallint not null default 10 check (tolerancia_diaria_min >= 0),
  limite_he_diario_min    smallint not null default 120 check (limite_he_diario_min >= 0),
  usa_banco_horas         boolean not null default true,
  noturno_inicio          time not null default '22:00',
  noturno_fim             time not null default '05:00',
  percentual_noturno      numeric(5,2) not null default 20 check (percentual_noturno >= 0),
  hora_noturna_reduzida   boolean not null default true,
  ativo                   boolean not null default true,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);
create unique index if not exists ux_perfis_eventos_padrao on perfis_eventos (padrao) where padrao;

create table if not exists perfil_evento_he (
  perfil_id   uuid not null references perfis_eventos(id) on delete cascade,
  dia         smallint not null check (dia between 0 and 7),   -- 0 = domingo … 6 = sábado, 7 = feriado
  percentual  numeric(5,2) not null check (percentual >= 0),
  primary key (perfil_id, dia)
);

drop trigger if exists trg_perfis_eventos_updated on perfis_eventos;
create trigger trg_perfis_eventos_updated before update on perfis_eventos
  for each row execute function fn_set_updated_at();

alter table colaboradores add column if not exists perfil_evento_id uuid references perfis_eventos(id);

-- Migração: as regras que ficavam na jornada viram perfis (um por combinação de regras).
-- O perfil das jornadas com mais colaboradores vira o "Padrão". Cada colaborador recebe o perfil
-- da jornada atual. Os códigos dos eventos "HE dia útil" e "HE folga/feriado" passam para os
-- eventos dos percentuais correspondentes. Roda uma vez: depois as colunas saem da jornada.
do $$
declare
  r          record;
  v_id       uuid;
  v_primeiro boolean := true;
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'jornadas' and column_name = 'tolerancia_entrada_min') then
    alter table colaboradores disable trigger trg_colaboradores_historico;

    for r in
      select j.tolerancia_entrada_min as tol_e, j.tolerancia_saida_min as tol_s, j.tolerancia_diaria_min as tol_d,
             j.percentual_he_dia_util as he_util, j.percentual_he_domingo as he_dom, j.limite_he_diario_min as lim,
             j.usa_banco_horas as bh, j.noturno_inicio as not_ini, j.noturno_fim as not_fim,
             j.percentual_noturno as not_pct, j.hora_noturna_reduzida as not_red,
             array_agg(distinct j.id) as ids, min(j.nome) as nome, count(c.id) as qtd
        from jornadas j
        left join colaboradores c on c.jornada_id = j.id
       group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
       order by count(c.id) desc, min(j.nome)
    loop
      insert into perfis_eventos (nome, padrao, tolerancia_entrada_min, tolerancia_saida_min, tolerancia_diaria_min,
                                  limite_he_diario_min, usa_banco_horas, noturno_inicio, noturno_fim,
                                  percentual_noturno, hora_noturna_reduzida)
      values (case when v_primeiro then 'Padrão' else 'Regras de ' || r.nome end, v_primeiro,
              r.tol_e, r.tol_s, r.tol_d, r.lim, r.bh, r.not_ini, r.not_fim, r.not_pct, r.not_red)
      returning id into v_id;

      insert into perfil_evento_he (perfil_id, dia, percentual)
      select v_id, d, case when d in (0, 7) then r.he_dom else r.he_util end
        from generate_series(0, 7) d;

      update colaboradores set perfil_evento_id = v_id
       where jornada_id = any(r.ids) and perfil_evento_id is null;
      v_primeiro := false;
    end loop;

    -- Códigos da folha: "HE dia útil" → percentual de segunda a sábado; "HE folga/feriado" → domingo/feriado
    insert into eventos_folha (chave, descricao, codigo, unidade, ativo, ordem)
    select distinct on (k.chave) k.chave, k.descricao, e.codigo, 'horas', coalesce(e.ativo, true), k.ordem
      from (select 'he_' || replace(trim_scale(h.percentual)::text, '.', '_') as chave,
                   'Horas extras ' || replace(trim_scale(h.percentual)::text, '.', ',') || '%' as descricao,
                   least(29, 10 + round(h.percentual / 10))::smallint as ordem,
                   case when h.dia in (0, 7) then 'he_especial' else 'he_util' end as origem,
                   case when h.dia in (0, 7) then 2 else 1 end as prioridade
              from perfil_evento_he h) k
      left join eventos_folha e on e.chave = k.origem
     order by k.chave, (e.codigo is null), k.prioridade
    on conflict (chave) do nothing;

    alter table jornadas
      drop column tolerancia_entrada_min, drop column tolerancia_saida_min, drop column tolerancia_diaria_min,
      drop column percentual_he_dia_util, drop column percentual_he_domingo, drop column limite_he_diario_min,
      drop column usa_banco_horas, drop column noturno_inicio, drop column noturno_fim,
      drop column percentual_noturno, drop column hora_noturna_reduzida;

    alter table colaboradores enable trigger trg_colaboradores_historico;
  end if;

  -- Sempre existe um perfil padrão, e todo perfil tem os 8 percentuais
  if not exists (select 1 from perfis_eventos) then
    insert into perfis_eventos (nome, padrao) values ('Padrão', true);
  end if;
  if not exists (select 1 from perfis_eventos where padrao) then
    update perfis_eventos set padrao = true
     where id = (select id from perfis_eventos where ativo order by created_at, nome limit 1);
  end if;
  insert into perfil_evento_he (perfil_id, dia, percentual)
  select p.id, d, case when d in (0, 7) then 100 else 50 end
    from perfis_eventos p cross join generate_series(0, 7) d
  on conflict (perfil_id, dia) do nothing;

  alter table colaboradores disable trigger trg_colaboradores_historico;
  update colaboradores set perfil_evento_id = (select id from perfis_eventos where padrao)
   where perfil_evento_id is null;
  alter table colaboradores enable trigger trg_colaboradores_historico;
end $$;

-- Eventos de HE antigos (substituídos por um evento por percentual)
delete from eventos_folha where chave in ('he_util', 'he_especial');

-- Colaborador cadastrado sem perfil recebe o perfil padrão
create or replace function fn_colaborador_perfil_padrao()
returns trigger language plpgsql as $$
begin
  if new.perfil_evento_id is null then
    new.perfil_evento_id := (select id from perfis_eventos where padrao);
  end if;
  return new;
end $$;

drop trigger if exists trg_colaboradores_perfil on colaboradores;
create trigger trg_colaboradores_perfil before insert or update of perfil_evento_id on colaboradores
  for each row execute function fn_colaborador_perfil_padrao();

alter table colaboradores alter column perfil_evento_id set not null;

-- -----------------------------------------------------------------------------
-- Row Level Security
-- RLS ligado em TODAS as tabelas e nenhuma policy para anon/authenticated:
-- a chave pública não lê nem grava tabelas diretamente. Todo acesso passa
-- pelas funções api_* (SECURITY DEFINER) que validam a sessão e o perfil.
-- -----------------------------------------------------------------------------
alter table empresa               enable row level security;
alter table paginas               enable row level security;
alter table perfis                enable row level security;
alter table perfil_permissoes     enable row level security;
alter table usuarios              enable row level security;
alter table sessoes               enable row level security;
alter table departamentos         enable row level security;
alter table cargos                enable row level security;
alter table jornadas              enable row level security;
alter table jornada_dias          enable row level security;
alter table feriados              enable row level security;
alter table colaboradores         enable row level security;
alter table colaborador_historico enable row level security;
alter table colaborador_jornadas  enable row level security;
alter table ausencias             enable row level security;
alter table batidas               enable row level security;
alter table batida_ajustes        enable row level security;
alter table motivos_batida        enable row level security;
alter table banco_horas           enable row level security;
alter table fechamentos           enable row level security;
alter table solicitacoes          enable row level security;
alter table eventos_folha         enable row level security;
alter table perfis_eventos        enable row level security;
alter table perfil_evento_he      enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
