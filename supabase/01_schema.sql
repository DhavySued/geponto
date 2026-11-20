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

-- Jornada vigente por período (antiga: substituída pela Situação do Colaborador,
-- fica só para trazer o histórico de quem já existia)
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

-- Escalas: exceção à jornada em um dia específico do colaborador
--   trabalho → o dia tem previsão com os horários informados, mesmo que a jornada diga folga ou o dia seja feriado
--   folga    → o dia não tem previsão, mesmo que a jornada diga trabalho
create table if not exists escalas (
  id                 uuid primary key default gen_random_uuid(),
  colaborador_id     uuid not null references colaboradores(id) on delete cascade,
  data               date not null,
  tipo               text not null check (tipo in ('trabalho', 'folga')),
  entrada            time,
  saida_intervalo    time,
  retorno_intervalo  time,
  saida              time,
  observacao         text,
  usuario_id         uuid references usuarios(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (colaborador_id, data),
  check (tipo = 'folga' or (entrada is not null and saida is not null)),
  check ((saida_intervalo is null) = (retorno_intervalo is null))
);
create index if not exists ix_escalas_data on escalas (data);

-- Escala lançada: o registro com nome, período (até 30 dias), dias da semana, horários e colaboradores.
-- Gera os dias em `escalas` e fica guardada para consultar e alterar depois.
create table if not exists escala_lancamentos (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null,
  tipo               text not null check (tipo in ('trabalho', 'folga')),
  data_inicio        date not null,
  data_fim           date not null,
  dias_semana        smallint[] not null default '{0,1,2,3,4,5,6}',
  entrada            time,
  saida_intervalo    time,
  retorno_intervalo  time,
  saida              time,
  observacao         text,
  colaboradores      uuid[] not null default '{}',
  usuario_id         uuid references usuarios(id) on delete set null,   -- quem lançou
  alterado_por       uuid references usuarios(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (data_fim >= data_inicio)
);
create index if not exists ix_escala_lancamentos_periodo on escala_lancamentos (data_inicio, data_fim);

alter table escalas add column if not exists lancamento_id uuid references escala_lancamentos(id) on delete cascade;
create index if not exists ix_escalas_lancamento on escalas (lancamento_id);

-- Escalas lançadas antes do cadastro: cada lançamento antigo (mesma gravação, tipo e horários) vira um registro
do $$
declare
  r record;
  v_id uuid;
begin
  if not exists (select 1 from escalas where lancamento_id is null) then return; end if;
  -- Só o vínculo muda: sem bloqueio de período fechado nem recálculo do banco
  alter table escalas disable trigger user;
  for r in
    select e.usuario_id, e.created_at, e.tipo, e.entrada, e.saida_intervalo, e.retorno_intervalo, e.saida,
           nullif(trim(e.observacao), '') as observacao,
           min(e.data) as ini, max(e.data) as fim,
           array_agg(distinct extract(dow from e.data)::smallint order by extract(dow from e.data)::smallint) as dias,
           array_agg(distinct e.colaborador_id) as colabs
      from escalas e
     where e.lancamento_id is null
     group by 1, 2, 3, 4, 5, 6, 7, 8
  loop
    insert into escala_lancamentos (nome, tipo, data_inicio, data_fim, dias_semana, entrada, saida_intervalo,
                                    retorno_intervalo, saida, observacao, colaboradores, usuario_id, created_at, updated_at)
    values (coalesce(left(r.observacao, 80), case r.tipo when 'trabalho' then 'Escala de trabalho' else 'Escala de folga' end)
              || ' (' || to_char(r.ini, 'DD/MM') || case when r.fim > r.ini then ' a ' || to_char(r.fim, 'DD/MM') else '' end || ')',
            r.tipo, r.ini, r.fim, r.dias, r.entrada, r.saida_intervalo, r.retorno_intervalo, r.saida, r.observacao,
            r.colabs, r.usuario_id, r.created_at, r.created_at)
    returning id into v_id;
    update escalas e set lancamento_id = v_id
     where e.lancamento_id is null
       and e.usuario_id is not distinct from r.usuario_id and e.created_at = r.created_at and e.tipo = r.tipo
       and e.entrada is not distinct from r.entrada and e.saida_intervalo is not distinct from r.saida_intervalo
       and e.retorno_intervalo is not distinct from r.retorno_intervalo and e.saida is not distinct from r.saida
       and nullif(trim(e.observacao), '') is not distinct from r.observacao;
  end loop;
  alter table escalas enable trigger user;
end $$;

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

-- -----------------------------------------------------------------------------
-- Geolocalização da batida (registro pelo sistema / quiosque)
-- Local onde o colaborador deve bater o ponto (um só): centro + raio. As coordenadas são sempre
-- capturadas pelo aparelho de quem cadastra, estando no local. A batida fora do raio, ou sem
-- localização, é registrada normalmente (Portaria 671: o registro não pode ser impedido) e fica
-- marcada para o RH conferir.
-- -----------------------------------------------------------------------------
create table if not exists locais_ponto (
  id          uuid primary key default gen_random_uuid(),
  nome        text not null unique,
  endereco    text,
  latitude    numeric(9,6) not null check (latitude between -90 and 90),
  longitude   numeric(9,6) not null check (longitude between -180 and 180),
  raio_m      integer not null default 150 check (raio_m between 10 and 50000),
  precisao_m  integer,                    -- precisão do GPS na captura das coordenadas
  ativo       boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- geo_status: 'dentro' / 'fora' do local mais próximo · 'registrada' (com localização, sem local
-- cadastrado) · 'sem_localizacao' (navegador não informou) · null = não se aplica (relógio, manual…)
alter table locais_ponto add column if not exists precisao_m integer;

alter table batidas add column if not exists precisao_m  integer;
alter table batidas add column if not exists geo_status  text;
alter table batidas add column if not exists geo_erro    text;
alter table batidas add column if not exists local_id    uuid references locais_ponto(id) on delete set null;
alter table batidas add column if not exists distancia_m integer;
alter table batidas drop constraint if exists batidas_geo_status_check;
alter table batidas add constraint batidas_geo_status_check
  check (geo_status in ('dentro', 'fora', 'registrada', 'sem_localizacao'));

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
                                 or new.nsr is distinct from old.nsr
                                 -- a localização registrada com a batida também não muda
                                 or new.latitude is distinct from old.latitude
                                 or new.longitude is distinct from old.longitude
                                 or new.precisao_m is distinct from old.precisao_m
                                 or new.geo_status is distinct from old.geo_status) then
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
    -- Primeira situação: a da admissão (o desligamento fica só na data de desligamento do cadastro)
    insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                       jornada_id, perfil_evento_id, salario, motivo, usuario_id)
    values (new.id, new.data_admissao,
            case when new.situacao = 'desligado' then 'ativo' else new.situacao end,
            new.cargo_id, new.departamento_id, new.jornada_id, new.perfil_evento_id, new.salario, 'Admissão', v_usuario)
    on conflict (colaborador_id, data_inicio) do nothing;
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

-- Intervalo flexível: a saída e o retorno do intervalo não precisam bater nos horários da jornada.
-- Vale a duração (retorno − saída do intervalo previstos): o retorno esperado é a saída real + a duração.
alter table jornadas add column if not exists intervalo_flexivel     boolean not null default false;

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
  -- 'batida': tolerância de entrada/saída em cada marcação · 'diaria': só a tolerância geral do dia
  tolerancia_modo         text not null default 'batida',
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
  dia         smallint not null check (dia between 0 and 8),   -- 0 = domingo … 6 = sábado, 7 = feriado, 8 = folga
  percentual  numeric(5,2) not null check (percentual >= 0),
  primary key (perfil_id, dia)
);

-- Modo de tolerância (por batida ou geral do dia) e percentual de HE da folga (dia 8)
alter table perfis_eventos add column if not exists tolerancia_modo text not null default 'batida';
alter table perfis_eventos drop constraint if exists perfis_eventos_tolerancia_modo_check;
alter table perfis_eventos add constraint perfis_eventos_tolerancia_modo_check
  check (tolerancia_modo in ('batida', 'diaria'));
alter table perfil_evento_he drop constraint if exists perfil_evento_he_dia_check;
alter table perfil_evento_he add constraint perfil_evento_he_dia_check check (dia between 0 and 8);

-- Banco de horas com o percentual de hora extra do dia: crédito = excedente × (1 + percentual).
-- Ex.: feriado a 100% → 8h trabalhadas viram 16h no banco. Débitos continuam hora por hora.
-- Vem ligado (também nas regras que já existiam): desligue na regra para voltar ao hora por hora.
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'perfis_eventos' and column_name = 'bh_multiplicar') then
    alter table perfis_eventos add column bh_multiplicar boolean not null default true;
  end if;
end $$;

drop trigger if exists trg_escala_lancamentos_updated on escala_lancamentos;
create trigger trg_escala_lancamentos_updated before update on escala_lancamentos
  for each row execute function fn_set_updated_at();

drop trigger if exists trg_escalas_updated on escalas;
create trigger trg_escalas_updated before update on escalas
  for each row execute function fn_set_updated_at();

drop trigger if exists trg_locais_ponto_updated on locais_ponto;
create trigger trg_locais_ponto_updated before update on locais_ponto
  for each row execute function fn_set_updated_at();

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
      select v_id, d, case when d in (0, 7, 8) then r.he_dom else r.he_util end
        from generate_series(0, 8) d;

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
                   case when h.dia in (0, 7, 8) then 'he_especial' else 'he_util' end as origem,
                   case when h.dia in (0, 7, 8) then 2 else 1 end as prioridade
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

  -- Sempre existe um perfil padrão, e todo perfil tem os 9 percentuais
  if not exists (select 1 from perfis_eventos) then
    insert into perfis_eventos (nome, padrao) values ('Padrão', true);
  end if;
  if not exists (select 1 from perfis_eventos where padrao) then
    update perfis_eventos set padrao = true
     where id = (select id from perfis_eventos where ativo order by created_at, nome limit 1);
  end if;
  -- Folga (dia 8) nasce com o percentual do domingo do próprio perfil
  insert into perfil_evento_he (perfil_id, dia, percentual)
  select h.perfil_id, 8, h.percentual from perfil_evento_he h where h.dia = 0
  on conflict (perfil_id, dia) do nothing;
  insert into perfil_evento_he (perfil_id, dia, percentual)
  select p.id, d, case when d in (0, 7, 8) then 100 else 50 end
    from perfis_eventos p cross join generate_series(0, 8) d
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

-- Administrador no próprio usuário: acesso a todas as telas, empresas e colaboradores,
-- qualquer que seja o perfil
alter table usuarios add column if not exists administrador boolean not null default false;

-- -----------------------------------------------------------------------------
-- Situação do Colaborador: o que vale a partir de cada data (situação, cargo, departamento,
-- jornada, regra de cálculo e salário). A primeira é a da admissão. A apuração de cada dia
-- usa a situação vigente naquele dia; o cadastro (colaboradores) guarda a vigente hoje.
-- O desligamento não é uma situação: fica no cadastro (data de desligamento, último dia apurado).
-- -----------------------------------------------------------------------------
create table if not exists colaborador_situacoes (
  id                uuid primary key default gen_random_uuid(),
  colaborador_id    uuid not null references colaboradores(id) on delete cascade,
  data_inicio       date not null,
  situacao          situacao_colaborador not null default 'ativo',
  cargo_id          uuid references cargos(id) on delete set null,
  departamento_id   uuid references departamentos(id) on delete set null,
  jornada_id        uuid references jornadas(id),
  perfil_evento_id  uuid references perfis_eventos(id),
  salario           numeric(12,2),
  motivo            text,
  usuario_id        uuid references usuarios(id) on delete set null,
  alterado_por      uuid references usuarios(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (colaborador_id, data_inicio)
);
create index if not exists ix_situacoes_jornada on colaborador_situacoes (jornada_id);

drop trigger if exists trg_colaborador_situacoes_updated on colaborador_situacoes;
create trigger trg_colaborador_situacoes_updated before update on colaborador_situacoes
  for each row execute function fn_set_updated_at();
alter table colaborador_situacoes enable row level security;
revoke all on colaborador_situacoes from anon, authenticated;

-- Colaboradores que já existiam: uma situação na admissão e uma a cada troca de jornada já
-- registrada; a situação atual (férias, afastado) entra na data em que passou a valer.
insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                   jornada_id, perfil_evento_id, salario, motivo)
select c.id, x.d, 'ativo', c.cargo_id, c.departamento_id,
       coalesce((select cj.jornada_id from colaborador_jornadas cj
                  where cj.colaborador_id = c.id and cj.data_inicio <= x.d
                  order by cj.data_inicio desc limit 1), c.jornada_id),
       c.perfil_evento_id, c.salario,
       case when x.d = c.data_admissao then 'Admissão' else 'Troca de jornada' end
  from colaboradores c
 cross join lateral (
   select c.data_admissao as d
   union
   select cj.data_inicio from colaborador_jornadas cj
    where cj.colaborador_id = c.id and cj.data_inicio > c.data_admissao) x
 where not exists (select 1 from colaborador_situacoes s where s.colaborador_id = c.id);

insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                   jornada_id, perfil_evento_id, salario, motivo)
select c.id, x.d, c.situacao, c.cargo_id, c.departamento_id, c.jornada_id, c.perfil_evento_id, c.salario,
       case c.situacao when 'ferias' then 'Férias' else 'Afastamento' end
  from colaboradores c
 cross join lateral (
   select greatest(c.data_admissao,
            coalesce((select max(h.data_vigencia) from colaborador_historico h
                       where h.colaborador_id = c.id and h.tipo = 'situacao'), c.data_admissao)) as d) x
 where c.situacao in ('ferias', 'afastado')
   and not exists (select 1 from colaborador_situacoes s where s.colaborador_id = c.id and s.situacao <> 'ativo')
on conflict (colaborador_id, data_inicio) do update set situacao = excluded.situacao, motivo = excluded.motivo;

-- Desligamentos lançados como situação (versão anterior) voltam para a data de desligamento do cadastro
do $$
begin
  if exists (select 1 from colaborador_situacoes where situacao = 'desligado') then
    update colaboradores c set data_desligamento = coalesce(c.data_desligamento, x.d)
      from (select colaborador_id, max(data_inicio) as d from colaborador_situacoes
             where situacao = 'desligado' group by colaborador_id) x
     where x.colaborador_id = c.id;
    update colaborador_situacoes s set situacao = 'ativo'
     where s.situacao = 'desligado'
       and s.data_inicio = (select min(y.data_inicio) from colaborador_situacoes y where y.colaborador_id = s.colaborador_id);
    delete from colaborador_situacoes where situacao = 'desligado';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Justificativas de atraso, saída antecipada e falta (uma por colaborador, dia e tipo)
--   abona = false → fica registrado o motivo, mas o atraso/saída/falta continua contando
--   abona = true  → os minutos deixam de ser atraso/débito; minutos null abona tudo,
--                   minutos preenchido abona só essa quantidade (abono parcial)
-- -----------------------------------------------------------------------------
create table if not exists justificativas (
  id              uuid primary key default gen_random_uuid(),
  colaborador_id  uuid not null references colaboradores(id) on delete cascade,
  data            date not null,
  tipo            text not null check (tipo in ('atraso', 'saida_antecipada', 'falta')),
  motivo          text not null check (length(trim(motivo)) > 0),
  abona           boolean not null default false,
  minutos         integer check (minutos is null or minutos > 0),
  observacao      text,
  usuario_id      uuid references usuarios(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (colaborador_id, data, tipo)
);
create index if not exists ix_justificativas_data on justificativas (data);

drop trigger if exists trg_justificativas_updated on justificativas;
create trigger trg_justificativas_updated before update on justificativas
  for each row execute function fn_set_updated_at();

-- -----------------------------------------------------------------------------
-- Falta levada para a folha: para quem tem banco de horas, o dia de falta (sem batidas) não é
-- debitado do banco; vai para a folha como 1 dia de falta (e o DSR da semana).
-- -----------------------------------------------------------------------------
create table if not exists faltas_folha (
  colaborador_id  uuid not null references colaboradores(id) on delete cascade,
  data            date not null,
  usuario_id      uuid references usuarios(id) on delete set null,
  created_at      timestamptz not null default now(),
  primary key (colaborador_id, data)
);

-- -----------------------------------------------------------------------------
-- Empresas (clientes): várias empresas no mesmo sistema. Cada colaborador pertence a uma
-- empresa; o usuário entra numa das empresas a que tem acesso (escolhida no login) e vê só
-- os colaboradores dela. O local de ponto (cerca virtual) fica no cadastro da empresa.
-- A tabela "empresa" (linha única) segue como configurações gerais do sistema.
-- -----------------------------------------------------------------------------
create table if not exists empresas (
  id                  uuid primary key default gen_random_uuid(),
  razao_social        text not null,
  nome_fantasia       text,
  cnpj                text unique,
  inscricao_estadual  text,
  telefone            text,
  email               text,
  cep                 text,
  logradouro          text,
  numero              text,
  complemento         text,
  bairro              text,
  cidade              text,
  uf                  char(2),
  ativo               boolean not null default true,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
drop trigger if exists trg_empresas_updated on empresas;
create trigger trg_empresas_updated before update on empresas
  for each row execute function fn_set_updated_at();

-- Primeira empresa a partir dos dados gerais já cadastrados
insert into empresas (razao_social, nome_fantasia, cnpj, logradouro)
select razao_social, nome_fantasia, nullif(trim(cnpj), ''), endereco from empresa
 where id = 1 and not exists (select 1 from empresas);

-- Empresa padrão: a mais antiga ativa (usada quando nada for informado)
create or replace function fn_empresa_padrao()
returns uuid language sql stable set search_path = public as $$
  select id from empresas order by ativo desc, created_at, id limit 1;
$$;

-- Empresa da sessão (definida por fn_auth)
create or replace function fn_empresa_atual()
returns uuid language sql stable set search_path = public as $$
  select nullif(current_setting('app.empresa_id', true), '')::uuid;
$$;

-- Dados da empresa para cabeçalhos (espelho de ponto, relatórios)
create or replace function fn_empresa_json(p_empresa uuid)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
           'id', e.id, 'razao_social', e.razao_social, 'nome_fantasia', e.nome_fantasia, 'cnpj', e.cnpj,
           'endereco', nullif(concat_ws(' – ',
                         nullif(concat_ws(', ', e.logradouro, e.numero, e.complemento), ''),
                         nullif(concat_ws(', ', e.bairro, nullif(concat_ws('/', e.cidade, e.uf), '')), ''),
                         case when e.cep is not null then 'CEP ' || e.cep end), ''))
    from empresas e
   where e.id = coalesce(p_empresa, fn_empresa_atual(), fn_empresa_padrao());
$$;

alter table colaboradores add column if not exists empresa_id uuid references empresas(id);
update colaboradores set empresa_id = fn_empresa_padrao() where empresa_id is null;
create index if not exists ix_colaboradores_empresa on colaboradores (empresa_id);

-- Colaborador sem empresa informada entra na empresa da sessão (ou na padrão)
create or replace function fn_colaborador_empresa()
returns trigger language plpgsql set search_path = public as $$
begin
  new.empresa_id := coalesce(new.empresa_id, fn_empresa_atual(), fn_empresa_padrao());
  return new;
end $$;
drop trigger if exists trg_colaboradores_empresa on colaboradores;
create trigger trg_colaboradores_empresa before insert or update of empresa_id on colaboradores
  for each row execute function fn_colaborador_empresa();

-- Empresas a que o usuário tem acesso (além da empresa do próprio colaborador)
create table if not exists usuario_empresas (
  usuario_id  uuid not null references usuarios(id) on delete cascade,
  empresa_id  uuid not null references empresas(id) on delete cascade,
  primary key (usuario_id, empresa_id)
);
-- Na primeira vez, todos os usuários existentes ficam com a empresa padrão
insert into usuario_empresas (usuario_id, empresa_id)
select u.id, fn_empresa_padrao() from usuarios u
 where fn_empresa_padrao() is not null and not exists (select 1 from usuario_empresas);

alter table sessoes add column if not exists empresa_id uuid references empresas(id) on delete set null;

-- Local de ponto da empresa (um por empresa)
alter table locais_ponto add column if not exists empresa_id uuid references empresas(id) on delete cascade;
create unique index if not exists ux_locais_ponto_empresa on locais_ponto (empresa_id) where empresa_id is not null;

-- Local de ponto próprio do colaborador (ex.: home office). local_ponto_modo diz onde ele pode bater:
--   empresa → só no local da empresa · proprio → só no local dele · ambos → em qualquer um dos dois
alter table locais_ponto add column if not exists colaborador_id uuid references colaboradores(id) on delete cascade;
create unique index if not exists ux_locais_ponto_colaborador on locais_ponto (colaborador_id) where colaborador_id is not null;
alter table colaboradores add column if not exists local_ponto_modo text not null default 'empresa';
alter table colaboradores drop constraint if exists colaboradores_local_ponto_modo_check;
alter table colaboradores add constraint colaboradores_local_ponto_modo_check
  check (local_ponto_modo in ('empresa', 'proprio', 'ambos'));
update locais_ponto set empresa_id = fn_empresa_padrao()
 where id = (select id from locais_ponto order by ativo desc, created_at limit 1)
   and empresa_id is null
   and not exists (select 1 from locais_ponto where empresa_id is not null);

-- Configurações do registro de ponto (cerca virtual)
--   usar_limitacoes_ponto: compara a localização da batida com o local da empresa
--   bloquear_fora_cerca:   com limitações, impede a batida fora da cerca (ou sem localização);
--                          sem bloquear, registra e sinaliza para o RH conferir
do $$ begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'empresa' and column_name = 'usar_limitacoes_ponto') then
    alter table empresa add column usar_limitacoes_ponto boolean not null default false;
    -- Quem já tinha local de ponto cadastrado continua com a cerca (como antes: registra e sinaliza)
    update empresa set usar_limitacoes_ponto = exists (select 1 from locais_ponto where ativo);
  end if;
end $$;
alter table empresa add column if not exists bloquear_fora_cerca boolean not null default false;

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
alter table locais_ponto          enable row level security;
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
alter table escalas               enable row level security;
alter table escala_lancamentos    enable row level security;
alter table justificativas        enable row level security;
alter table faltas_folha          enable row level security;
alter table empresas              enable row level security;
alter table usuario_empresas      enable row level security;

-- -----------------------------------------------------------------------------
-- Log e auditoria: cada inclusão, alteração e exclusão nas tabelas de cadastro e movimento
-- (com os valores antes e depois só dos campos que mudaram) e os acessos ao sistema.
-- O usuário vem de app.usuario_id (fn_auth); sem ele, foi o próprio sistema (rotina automática).
-- -----------------------------------------------------------------------------
create table if not exists auditoria (
  id              bigint generated always as identity primary key,
  data_hora       timestamptz not null default now(),
  usuario_id      uuid references usuarios(id) on delete set null,
  usuario_nome    text,
  empresa_id      uuid,
  tabela          text not null,
  registro_id     text,
  acao            text not null check (acao in ('inclusao', 'alteracao', 'exclusao', 'login', 'login_falha')),
  colaborador_id  uuid,
  descricao       text,
  campos          text[],
  antes           jsonb,
  depois          jsonb
);
create index if not exists ix_auditoria_data on auditoria (data_hora desc);
create index if not exists ix_auditoria_tabela on auditoria (tabela, data_hora desc);
create index if not exists ix_auditoria_colaborador on auditoria (colaborador_id, data_hora desc) where colaborador_id is not null;
create index if not exists ix_auditoria_usuario on auditoria (usuario_id, data_hora desc);
alter table auditoria enable row level security;

create or replace function fn_auditar()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_antes  jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_depois jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_linha  jsonb := coalesce(v_depois, v_antes);
  v_ign    text[] := array['created_at', 'updated_at', 'senha_hash', 'ultimo_acesso', 'ultimo_uso', 'chave_hash', 'token_hash'];
  v_campos text[];
  v_usuario uuid := nullif(current_setting('app.usuario_id', true), '')::uuid;
begin
  -- Lançamentos automáticos do banco de horas e o registro de batidas já são o próprio histórico
  if tg_table_name = 'banco_horas' and v_linha ->> 'origem' = 'automatico' then return null; end if;
  if tg_table_name = 'batidas' and tg_op = 'INSERT' then return null; end if;

  if tg_op = 'UPDATE' then
    select array_agg(k order by k) into v_campos
      from jsonb_object_keys(v_depois) k
     where k <> all(v_ign) and v_depois -> k is distinct from v_antes -> k;
    if v_campos is null then return null; end if;   -- nada que importe mudou
    select jsonb_object_agg(k, v_antes -> k), jsonb_object_agg(k, v_depois -> k) into v_antes, v_depois
      from unnest(v_campos) k;
  else
    v_antes := v_antes - v_ign;
    v_depois := v_depois - v_ign;
  end if;

  insert into auditoria (usuario_id, usuario_nome, empresa_id, tabela, registro_id, acao, colaborador_id, descricao, campos, antes, depois)
  values (v_usuario, (select nome from usuarios where id = v_usuario),
          coalesce(nullif(current_setting('app.empresa_id', true), '')::uuid,
                   case when v_linha ? 'empresa_id' then (v_linha ->> 'empresa_id')::uuid end),
          tg_table_name, v_linha ->> 'id',
          case tg_op when 'INSERT' then 'inclusao' when 'UPDATE' then 'alteracao' else 'exclusao' end,
          case when tg_table_name = 'colaboradores' then (v_linha ->> 'id')::uuid
               when v_linha ? 'colaborador_id' then (v_linha ->> 'colaborador_id')::uuid end,
          left(coalesce(v_linha ->> 'nome', v_linha ->> 'descricao', v_linha ->> 'razao_social', v_linha ->> 'login',
                        v_linha ->> 'pagina', v_linha ->> 'data'), 200),
          v_campos, v_antes, v_depois);
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['empresa', 'empresas', 'perfis', 'perfil_permissoes', 'usuarios', 'usuario_empresas', 'departamentos', 'cargos', 'jornadas', 'jornada_dias', 'feriados', 'colaboradores', 'colaborador_situacoes', 'ausencias', 'escalas', 'escala_lancamentos', 'batidas', 'locais_ponto', 'motivos_batida', 'banco_horas', 'fechamentos', 'solicitacoes', 'eventos_folha', 'perfis_eventos', 'perfil_evento_he', 'justificativas', 'faltas_folha'] loop
    execute format('drop trigger if exists trg_auditoria on %I', t);
    execute format('create trigger trg_auditoria after insert or update or delete on %I for each row execute function fn_auditar()', t);
  end loop;
end $$;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
