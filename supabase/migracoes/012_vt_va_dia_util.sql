-- =============================================================================
-- 012 · VT e VA (tipos, jornada, situação, configuração e relatórios) e dia útil para o DSR
-- Requer: 011. Re-executável.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- VT e VA: tipos (nome, código, valor diário) e o que cada colaborador recebe, por situação.
-- tipo_vt_id / tipo_va_id vazio = não recebe.
-- -----------------------------------------------------------------------------
create table if not exists tipos_beneficio (
  id            uuid primary key default gen_random_uuid(),
  nome          text not null,
  codigo        text not null,
  tipo          text not null check (tipo in ('vt', 'va')),
  valor_diario  numeric(10,2) not null default 0 check (valor_diario >= 0),
  ativo         boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  unique (tipo, codigo)
);
alter table tipos_beneficio enable row level security;
revoke all on tipos_beneficio from anon, authenticated;
drop trigger if exists trg_tipos_beneficio_updated on tipos_beneficio;
create trigger trg_tipos_beneficio_updated before update on tipos_beneficio
  for each row execute function fn_set_updated_at();

alter table colaborador_situacoes add column if not exists tipo_vt_id uuid references tipos_beneficio(id);
alter table colaborador_situacoes add column if not exists tipo_va_id uuid references tipos_beneficio(id);

-- Por dia da jornada: dia útil (controle de DSR) e se o dia dá direito a VT e a VA.
-- Jornadas que já existiam: os dias de trabalho ficam marcados; as folgas, não.
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'jornada_dias' and column_name = 'dia_util') then
    alter table jornada_dias add column dia_util  boolean not null default true;
    alter table jornada_dias add column recebe_vt boolean not null default true;
    alter table jornada_dias add column recebe_va boolean not null default true;
    update jornada_dias set dia_util = false, recebe_vt = false, recebe_va = false where folga;
  end if;
end $$;

-- Quando o dia conta para VT/VA: 'um' turno trabalhado ou os 'dois' turnos
alter table empresa add column if not exists beneficio_turnos text not null default 'um'
  check (beneficio_turnos in ('um', 'dois'));

drop trigger if exists trg_auditoria on tipos_beneficio;
create trigger trg_auditoria after insert or update or delete on tipos_beneficio for each row execute function fn_auditar();

-- Dia útil para o DSR: o marcado na jornada; escala de trabalho no dia conta como útil
create or replace function fn_dia_util(p_jornada uuid, p_data date, p_escala text)
returns boolean language sql stable set search_path = public as $$
  select case when p_escala = 'trabalho' then true
              else coalesce((select jd.dia_util
                               from jornadas j
                               join jornada_dias jd on jd.jornada_id = j.id
                                                   and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, p_data)
                              where j.id = p_jornada), true) end;
$$;

-- Tipos de VT/VA ativos, para os formulários
create or replace function fn_tipos_beneficio_json()
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'nome', t.nome, 'codigo', t.codigo, 'tipo', t.tipo,
                                               'valor_diario', t.valor_diario) order by t.tipo, t.nome), '[]'::jsonb)
    from tipos_beneficio t where t.ativo;
$$;

-- Tipo de VT/VA informado no formulário (recebe_vt + tipo_vt_id). Sem o campo, mantém o atual.
create or replace function fn_beneficio_informado(d jsonb, p_tipo text, p_atual uuid)
returns uuid language plpgsql stable set search_path = public as $$
declare v_id uuid;
begin
  if not d ? ('recebe_' || p_tipo) then return p_atual; end if;
  if not coalesce((d ->> ('recebe_' || p_tipo))::boolean, false) then return null; end if;
  v_id := fn_txt(d, 'tipo_' || p_tipo || '_id')::uuid;
  if v_id is null then raise exception 'Escolha o tipo de % do colaborador.', upper(p_tipo); end if;
  if not exists (select 1 from tipos_beneficio where id = v_id and tipo = p_tipo and (ativo or id = p_atual)) then
    raise exception 'Escolha um tipo de % ativo.', upper(p_tipo);
  end if;
  return v_id;
end $$;

create or replace function api_cadastros_auxiliares(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'colaboradores');
  return jsonb_build_object(
    'departamentos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from departamentos where ativo), '[]'::jsonb),
    'cargos',        coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from cargos where ativo), '[]'::jsonb),
    'jornadas',      coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from jornadas where ativo and fn_da_empresa(empresa_id, todas_empresas)), '[]'::jsonb),
    'perfis_eventos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'padrao', padrao)
                                                 order by padrao desc, nome)
                                  from perfis_eventos where ativo and (padrao or fn_da_empresa(empresa_id, todas_empresas))), '[]'::jsonb),
    -- Próxima matrícula: a maior numérica + 1, com o mesmo número de dígitos
    'proxima_matricula', (select lpad((coalesce(max(matricula::numeric), 0) + 1)::text,
                                      greatest(coalesce(max(length(matricula)), 1), length((coalesce(max(matricula::numeric), 0) + 1)::text)), '0')
                            from colaboradores where matricula ~ '^[0-9]{1,15}$'),
    'gestores',      coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from colaboradores where situacao <> 'desligado'), '[]'::jsonb),
    'tipos_beneficio', fn_tipos_beneficio_json()
  );
end $$;

create or replace function fn_situacoes_json(p_colaborador uuid, p_colaboradores uuid[])
returns jsonb language sql stable set search_path = public as $$
  with s as (
    select s.*,
           lead(s.data_inicio) over w - 1 as data_fim,
           row_number() over w = 1 as primeira
      from colaborador_situacoes s
     where fn_filtro_colaborador(s.colaborador_id, p_colaborador, p_colaboradores)
    window w as (partition by s.colaborador_id order by s.data_inicio)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'colaborador_id', s.colaborador_id, 'colaborador', c.nome, 'matricula', c.matricula,
           'data_inicio', s.data_inicio, 'data_fim', s.data_fim, 'situacao', s.situacao,
           'cargo_id', s.cargo_id, 'cargo', g.nome, 'departamento_id', s.departamento_id, 'departamento', d.nome,
           'jornada_id', s.jornada_id, 'jornada', j.nome, 'perfil_evento_id', s.perfil_evento_id, 'perfil_evento', pe.nome,
           'salario', s.salario, 'motivo', s.motivo, 'primeira', s.primeira,
           'recebe_vt', s.tipo_vt_id is not null, 'tipo_vt_id', s.tipo_vt_id, 'tipo_vt', tvt.nome,
           'recebe_va', s.tipo_va_id is not null, 'tipo_va_id', s.tipo_va_id, 'tipo_va', tva.nome,
           'vigente', s.data_inicio <= fn_hoje() and (s.data_fim is null or s.data_fim >= fn_hoje()),
           'futura', s.data_inicio > fn_hoje(),
           'fechado', s.data_inicio <= coalesce(fn_fechado_ate(s.colaborador_id), '-infinity'::date),
           'usuario', u.nome, 'alterado_por', u2.nome, 'created_at', s.created_at, 'updated_at', s.updated_at)
         order by c.nome, s.data_inicio desc), '[]'::jsonb)
    from s
    join colaboradores c on c.id = s.colaborador_id
    left join cargos g          on g.id = s.cargo_id
    left join departamentos d   on d.id = s.departamento_id
    left join jornadas j        on j.id = s.jornada_id
    left join perfis_eventos pe on pe.id = s.perfil_evento_id
    left join usuarios u        on u.id = s.usuario_id
    left join usuarios u2       on u2.id = s.alterado_por
    left join tipos_beneficio tvt on tvt.id = s.tipo_vt_id
    left join tipos_beneficio tva on tva.id = s.tipo_va_id
   where fn_visivel(c.id);
$$;

create or replace function api_colaborador_situacoes(p_token text, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'situacoes_colaborador');
  return jsonb_build_object(
    'situacoes', fn_situacoes_json(null, p_colaboradores),
    'fechado_ate', fn_fechado_ate(),
    'colaboradores', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'situacao', c.situacao,
               'data_admissao', c.data_admissao, 'departamento_id', c.departamento_id,
               'cargo_id', c.cargo_id, 'jornada_id', c.jornada_id) order by c.nome)
        from colaboradores c where fn_visivel(c.id)), '[]'::jsonb),
    'cargos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                          from cargos where ativo), '[]'::jsonb),
    'departamentos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from departamentos where ativo), '[]'::jsonb),
    'jornadas', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                            from jornadas where ativo and fn_da_empresa(empresa_id, todas_empresas)), '[]'::jsonb),
    'perfis_eventos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'padrao', padrao)
                                                 order by padrao desc, nome)
                                  from perfis_eventos where ativo and (padrao or fn_da_empresa(empresa_id, todas_empresas))), '[]'::jsonb),
    'tipos_beneficio', fn_tipos_beneficio_json());
end $$;

create or replace function api_colaborador_situacao_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  v_colab uuid := nullif(d ->> 'colaborador_id', '')::uuid;
  v_old colaborador_situacoes%rowtype;
  v_data date;
  v_adm date;
  v_primeira date;
  v_fechado date;
  v_perfil uuid;
  v_jornada uuid := fn_txt(d, 'jornada_id')::uuid;
  v_vt uuid;
  v_va uuid;
  v_ant colaborador_situacoes%rowtype;
  v_usuario uuid := nullif(current_setting('app.usuario_id', true), '')::uuid;
begin
  perform fn_auth(p_token, 'situacoes_colaborador', true);
  if v_id is not null then
    select * into v_old from colaborador_situacoes where id = v_id;
    if not found then raise exception 'Situação não encontrada.'; end if;
    v_colab := v_old.colaborador_id;
  end if;
  if v_colab is null then raise exception 'Escolha o colaborador.'; end if;
  if not fn_visivel(v_colab) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  if fn_txt(d, 'data_inicio') is null then raise exception 'Informe a partir de quando a situação vale.'; end if;
  if fn_txt(d, 'situacao') = 'desligado' then
    raise exception 'O desligamento não é uma situação: informe a data de desligamento no cadastro do colaborador.';
  end if;
  v_data := fn_txt(d, 'data_inicio')::date;
  v_fechado := fn_fechado_ate(v_colab);

  select data_admissao into v_adm from colaboradores where id = v_colab;
  select min(data_inicio) into v_primeira from colaborador_situacoes where colaborador_id = v_colab;
  -- A situação da admissão é mantida pelo cadastro do colaborador
  if v_id is not null and v_old.data_inicio = v_primeira then
    raise exception 'Esta é a situação da admissão. Para alterá-la, altere no cadastro do colaborador (aba Profissional, dados da admissão).';
  end if;
  if v_data < v_adm then
    raise exception 'A situação não pode começar antes da admissão (%).', to_char(v_adm, 'DD/MM/YYYY');
  end if;
  -- A data de uma situação lançada não muda: para outra data, lance uma nova situação (e exclua esta)
  if v_id is not null and v_data <> v_old.data_inicio then
    raise exception 'A data da situação não pode ser alterada. Lance uma nova situação na data certa e exclua esta.';
  end if;
  if v_fechado is not null and (v_data <= v_fechado or v_old.data_inicio <= v_fechado) then
    raise exception 'O período até % está fechado. Lance a nova situação a partir de % ou reabra o fechamento.',
      to_char(v_fechado, 'DD/MM/YYYY'), to_char(v_fechado + 1, 'DD/MM/YYYY');
  end if;
  if exists (select 1 from colaborador_situacoes
              where colaborador_id = v_colab and data_inicio = v_data and id is distinct from v_id) then
    raise exception 'Já existe uma situação em % para este colaborador. Altere-a em vez de criar outra.',
      to_char(v_data, 'DD/MM/YYYY');
  end if;

  v_perfil := coalesce(fn_txt(d, 'perfil_evento_id')::uuid, (select id from perfis_eventos where padrao));
  if not exists (select 1 from perfis_eventos where id = v_perfil and (ativo or id = v_old.perfil_evento_id)) then
    raise exception 'Escolha uma regra de cálculo ativa.';
  end if;
  if v_jornada is not null and not exists (
       select 1 from jornadas where id = v_jornada and (ativo or id = v_old.jornada_id)) then
    raise exception 'Escolha uma jornada ativa.';
  end if;

  -- Sem os campos de VT/VA: mantém os da própria situação ou, na inclusão, os que valiam na data
  v_ant := v_old;
  if v_id is null then
    select * into v_ant from colaborador_situacoes
     where colaborador_id = v_colab and data_inicio <= v_data order by data_inicio desc limit 1;
  end if;
  v_vt := fn_beneficio_informado(d, 'vt', v_ant.tipo_vt_id);
  v_va := fn_beneficio_informado(d, 'va', v_ant.tipo_va_id);

  perform set_config('app.data_vigencia', v_data::text, true);
  if v_id is null then
    insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                       jornada_id, perfil_evento_id, salario, motivo, usuario_id, tipo_vt_id, tipo_va_id)
    values (v_colab, v_data, coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador,
            fn_txt(d, 'cargo_id')::uuid, fn_txt(d, 'departamento_id')::uuid, v_jornada, v_perfil,
            fn_txt(d, 'salario')::numeric, fn_txt(d, 'motivo'), v_usuario, v_vt, v_va)
    returning id into v_id;
  else
    update colaborador_situacoes set
           data_inicio = v_data, situacao = coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador,
           cargo_id = fn_txt(d, 'cargo_id')::uuid, departamento_id = fn_txt(d, 'departamento_id')::uuid,
           jornada_id = v_jornada, perfil_evento_id = v_perfil, salario = fn_txt(d, 'salario')::numeric,
           motivo = fn_txt(d, 'motivo'), alterado_por = v_usuario, tipo_vt_id = v_vt, tipo_va_id = v_va
     where id = v_id;
  end if;

  perform fn_colaborador_situacao_aplicar(v_colab);
  -- A apuração muda a partir da data: recalcula o banco de horas dos dias já encerrados
  perform fn_processar_banco_horas(least(v_data, coalesce(v_old.data_inicio, v_data)), fn_hoje() - 1, v_colab);
  return jsonb_build_object('id', v_id);
exception
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Data inválida.';
  when invalid_text_representation then
    raise exception 'Valor inválido. Confira o salário e as datas.';
end $$;

create or replace function api_colaborador_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  v_situacao situacao_colaborador := coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador;
  v_admissao date;
  v_deslig date;
  v_controle date;
  v_reproc date;
  v_primeira date;
  v_constraint text;
  v_old colaboradores%rowtype;
begin
  perform fn_auth(p_token, 'colaboradores', true);
  if v_id is not null and not fn_visivel(v_id) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;

  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome do colaborador.'; end if;
  if fn_txt(d, 'matricula') is null and nullif(d ->> 'id', '') is null then
    d := d || jsonb_build_object('matricula', (
      select lpad((coalesce(max(matricula::numeric), 0) + 1)::text,
                  greatest(coalesce(max(length(matricula)), 1), length((coalesce(max(matricula::numeric), 0) + 1)::text)), '0')
        from colaboradores where matricula ~ '^[0-9]{1,15}$'));
  end if;
  if fn_txt(d, 'matricula') is null then raise exception 'Informe a matrícula.'; end if;
  if not fn_cpf_valido(d ->> 'cpf') then
    raise exception 'CPF inválido. Confira os números digitados.';
  end if;
  if fn_txt(d, 'data_admissao') is null then raise exception 'Informe a data de admissão.'; end if;

  v_admissao := fn_txt(d, 'data_admissao')::date;
  v_deslig   := fn_txt(d, 'data_desligamento')::date;
  v_controle := fn_txt(d, 'controle_ponto_inicio')::date;

  -- Perfil de eventos: precisa estar ativo (um perfil inativo só fica em quem já o usava)
  if v_id is null and fn_txt(d, 'perfil_evento_id') is not null and not exists (
       select 1 from perfis_eventos pe
        where pe.id = fn_txt(d, 'perfil_evento_id')::uuid
          and (pe.ativo or pe.id = (select c.perfil_evento_id from colaboradores c where c.id = v_id))) then
    raise exception 'Escolha uma regra de cálculo ativa.';
  end if;

  if v_controle is not null and v_controle < v_admissao then
    raise exception 'O controle de ponto não pode começar antes da admissão (%).', to_char(v_admissao, 'DD/MM/YYYY');
  end if;

  -- O desligamento é a data de desligamento (não é uma situação)
  if v_situacao = 'desligado' then
    v_situacao := 'ativo';
    v_deslig := coalesce(v_deslig, fn_hoje());
  end if;

  -- Empresa do colaborador: só uma das empresas a que o usuário tem acesso
  if fn_txt(d, 'empresa_id') is not null and fn_txt(d, 'empresa_id')::uuid not in
       (select fn_empresas_do_usuario(nullif(current_setting('app.usuario_id', true), '')::uuid)) then
    raise exception 'Você não tem acesso à empresa selecionada.';
  end if;

  -- Na inclusão, situação, cargo, departamento, jornada, regra e salário viram a primeira situação
  -- (na admissão). Depois disso eles só mudam pela Situação do Colaborador, a partir de uma data.
  if v_id is null then
    insert into colaboradores (
      matricula, nome, nome_social, cpf, pis, rg, data_nascimento, sexo, email, telefone,
      cep, logradouro, numero, complemento, bairro, cidade, uf,
      cargo_id, departamento_id, jornada_id, gestor_id, perfil_evento_id,
      data_admissao, data_desligamento, situacao, salario, observacoes,
      controla_ponto, controle_ponto_inicio, empresa_id)
    values (
      fn_txt(d, 'matricula'), fn_txt(d, 'nome'), fn_txt(d, 'nome_social'),
      regexp_replace(fn_txt(d, 'cpf'), '[^0-9]', '', 'g'),
      nullif(regexp_replace(fn_txt(d, 'pis'), '[^0-9]', '', 'g'), ''), fn_txt(d, 'rg'),
      fn_txt(d, 'data_nascimento')::date, fn_txt(d, 'sexo'),
      lower(fn_txt(d, 'email')), fn_txt(d, 'telefone'),
      fn_txt(d, 'cep'), fn_txt(d, 'logradouro'), fn_txt(d, 'numero'), fn_txt(d, 'complemento'),
      fn_txt(d, 'bairro'), fn_txt(d, 'cidade'), upper(fn_txt(d, 'uf')),
      fn_txt(d, 'cargo_id')::uuid, fn_txt(d, 'departamento_id')::uuid,
      fn_txt(d, 'jornada_id')::uuid, fn_txt(d, 'gestor_id')::uuid,
      fn_txt(d, 'perfil_evento_id')::uuid,   -- vazio: o trigger usa o perfil padrão
      v_admissao, v_deslig, v_situacao,
      fn_txt(d, 'salario')::numeric, fn_txt(d, 'observacoes'),
      coalesce((d ->> 'controla_ponto')::boolean, true), v_controle,
      fn_txt(d, 'empresa_id')::uuid)   -- vazio: a empresa da sessão
    returning id into v_id;
    v_reproc := v_admissao;
    update colaborador_situacoes set
           tipo_vt_id = fn_beneficio_informado(d, 'vt', null), tipo_va_id = fn_beneficio_informado(d, 'va', null)
     where colaborador_id = v_id
       and (coalesce((d ->> 'recebe_vt')::boolean, false) or coalesce((d ->> 'recebe_va')::boolean, false));
    perform fn_colaborador_situacao_aplicar(v_id);
  else
    if fn_txt(d, 'gestor_id')::uuid = v_id then
      raise exception 'O colaborador não pode ser gestor dele mesmo.';
    end if;
    select * into v_old from colaboradores where id = v_id;
    if not found then raise exception 'Colaborador não encontrado.'; end if;

    -- A admissão mudou: a primeira situação acompanha (não pode passar das seguintes)
    if v_admissao <> v_old.data_admissao then
      select min(data_inicio) into v_primeira from colaborador_situacoes where colaborador_id = v_id;
      if exists (select 1 from colaborador_situacoes
                  where colaborador_id = v_id and data_inicio > v_primeira and data_inicio <= v_admissao) then
        raise exception 'Há situações lançadas até % (Situação do Colaborador). A admissão precisa ser anterior a elas.',
          to_char(v_admissao, 'DD/MM/YYYY');
      end if;
      perform set_config('app.data_vigencia', v_admissao::text, true);
      update colaborador_situacoes set data_inicio = v_admissao
       where colaborador_id = v_id and data_inicio = v_primeira;
    end if;

    -- Reprocessa o banco de horas desde a data mais antiga afetada
    select least(c.data_admissao, v_admissao,
                 coalesce((select min(bh.data) from banco_horas bh
                            where bh.colaborador_id = c.id and bh.origem = 'automatico'), v_admissao))
      into v_reproc
      from colaboradores c where c.id = v_id;

    update colaboradores set
      matricula = fn_txt(d, 'matricula'), nome = fn_txt(d, 'nome'), nome_social = fn_txt(d, 'nome_social'),
      cpf = regexp_replace(fn_txt(d, 'cpf'), '[^0-9]', '', 'g'),
      pis = nullif(regexp_replace(fn_txt(d, 'pis'), '[^0-9]', '', 'g'), ''), rg = fn_txt(d, 'rg'),
      data_nascimento = fn_txt(d, 'data_nascimento')::date, sexo = fn_txt(d, 'sexo'),
      email = lower(fn_txt(d, 'email')), telefone = fn_txt(d, 'telefone'),
      cep = fn_txt(d, 'cep'), logradouro = fn_txt(d, 'logradouro'), numero = fn_txt(d, 'numero'),
      complemento = fn_txt(d, 'complemento'), bairro = fn_txt(d, 'bairro'), cidade = fn_txt(d, 'cidade'),
      uf = upper(fn_txt(d, 'uf')),
      gestor_id = fn_txt(d, 'gestor_id')::uuid,
      data_admissao = v_admissao, data_desligamento = v_deslig, observacoes = fn_txt(d, 'observacoes'),
      controla_ponto = coalesce((d ->> 'controla_ponto')::boolean, true),
      controle_ponto_inicio = v_controle,
      empresa_id = coalesce(fn_txt(d, 'empresa_id')::uuid, empresa_id)
    where id = v_id;

    -- Dados da admissão (a primeira situação): só mudam aqui, no cadastro
    if jsonb_typeof(d -> 'admissao') = 'object' then
      declare
        a jsonb := d -> 'admissao';
        s colaborador_situacoes%rowtype;
        n_sit situacao_colaborador;
        n_jor uuid := fn_txt(a, 'jornada_id')::uuid;
        n_per uuid;
        n_sal numeric := fn_txt(a, 'salario')::numeric;
        n_vt uuid;
        n_va uuid;
      begin
        select * into s from colaborador_situacoes where colaborador_id = v_id order by data_inicio limit 1;
        if found then
          if fn_txt(a, 'situacao') = 'desligado' then
            raise exception 'O desligamento não é uma situação: informe a data de desligamento.';
          end if;
          n_sit := coalesce(fn_txt(a, 'situacao'), s.situacao::text)::situacao_colaborador;
          n_per := coalesce(fn_txt(a, 'perfil_evento_id')::uuid, s.perfil_evento_id);
          n_vt := fn_beneficio_informado(a, 'vt', s.tipo_vt_id);
          n_va := fn_beneficio_informado(a, 'va', s.tipo_va_id);
          if (s.situacao, s.cargo_id, s.departamento_id, s.jornada_id, s.perfil_evento_id, s.salario,
              s.tipo_vt_id, s.tipo_va_id)
             is distinct from (n_sit, fn_txt(a, 'cargo_id')::uuid, fn_txt(a, 'departamento_id')::uuid, n_jor, n_per, n_sal,
                               n_vt, n_va) then
            if s.data_inicio <= coalesce(fn_fechado_ate(v_id), '-infinity'::date) then
              raise exception 'A admissão está em um período fechado. Reabra o fechamento para alterar os dados da admissão.';
            end if;
            if n_jor is not null and n_jor is distinct from s.jornada_id
               and not exists (select 1 from jornadas where id = n_jor and ativo) then
              raise exception 'Escolha uma jornada ativa.';
            end if;
            if n_per is distinct from s.perfil_evento_id
               and not exists (select 1 from perfis_eventos where id = n_per and ativo) then
              raise exception 'Escolha uma regra de cálculo ativa.';
            end if;
            perform set_config('app.data_vigencia', s.data_inicio::text, true);
            update colaborador_situacoes set
              situacao = n_sit, cargo_id = fn_txt(a, 'cargo_id')::uuid,
              departamento_id = fn_txt(a, 'departamento_id')::uuid,
              jornada_id = n_jor, perfil_evento_id = n_per, salario = n_sal, tipo_vt_id = n_vt, tipo_va_id = n_va
             where id = s.id;
          end if;
        end if;
      end;
    end if;
    perform fn_colaborador_situacao_aplicar(v_id);
  end if;

  -- Mantém o banco de horas do colaborador coerente com jornada, controle e datas
  perform fn_processar_banco_horas(v_reproc, fn_hoje() - 1, v_id);

  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    raise exception '%', case
      when v_constraint like '%cpf%'       then 'Já existe um colaborador com este CPF.'
      when v_constraint like '%matricula%' then 'Já existe um colaborador com esta matrícula.'
      when v_constraint like '%pis%'       then 'Já existe um colaborador com este PIS.'
      else 'Registro duplicado.' end;
  when check_violation then
    raise exception 'A data de desligamento não pode ser anterior à admissão.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Data inválida. Confira as datas informadas.';
end $$;

create or replace function api_jornadas_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'jornadas');
  return coalesce((
    select jsonb_agg(
             to_jsonb(j) - 'created_at' - 'updated_at'
             || jsonb_build_object(
                  'colaboradores', (select count(*) from colaboradores c
                                     where c.jornada_id = j.id and c.situacao <> 'desligado'),
                  -- Escala: média semanal (carga do ciclo × 7 / dias do ciclo)
                  'minutos_semana', coalesce(round((
                     select sum(fn_minutos(jd.entrada, jd.saida)
                                - coalesce(fn_minutos(jd.saida_intervalo, jd.retorno_intervalo), 0))
                       from jornada_dias jd where jd.jornada_id = j.id and not jd.folga)
                     * case when j.tipo = 'escala' then 7.0 / j.ciclo_dias else 1 end), 0),
                  'dias', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'dia_semana', jd.dia_semana, 'folga', jd.folga,
                              'dia_util', jd.dia_util, 'recebe_vt', jd.recebe_vt, 'recebe_va', jd.recebe_va,
                              'entrada', to_char(jd.entrada, 'HH24:MI'),
                              'saida_intervalo', to_char(jd.saida_intervalo, 'HH24:MI'),
                              'retorno_intervalo', to_char(jd.retorno_intervalo, 'HH24:MI'),
                              'saida', to_char(jd.saida, 'HH24:MI'))
                            order by jd.dia_semana)
                       from jornada_dias jd where jd.jornada_id = j.id), '[]'::jsonb))
             order by j.ativo desc, j.nome)
      from jornadas j
     where fn_da_empresa(j.empresa_id, j.todas_empresas)
  ), '[]'::jsonb);
end $$;

create or replace function api_jornada_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  dia jsonb;
  v_nomes text[] := array['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado'];
  v_dia int;
  v_ent time; v_si time; v_ri time; v_sai time;
  v_tipo text := coalesce(fn_txt(d, 'tipo'), 'semanal');
  v_ciclo smallint := case when v_tipo = 'escala' then fn_txt(d, 'ciclo_dias')::smallint else 7 end;
  v_rotulo text;
begin
  perform fn_auth(p_token, 'jornadas', true);

  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome da jornada.'; end if;
  if v_tipo not in ('semanal', 'escala') then raise exception 'Tipo de jornada inválido.'; end if;
  if v_tipo = 'escala' then
    if coalesce(v_ciclo, 0) not between 2 and 60 then
      raise exception 'O ciclo da escala deve ter de 2 a 60 dias (ex.: 12x36 = 2 dias).';
    end if;
    if fn_txt(d, 'data_base') is null then
      raise exception 'Informe a data de início do ciclo (o dia 1 da escala).';
    end if;
  end if;
  if jsonb_typeof(d -> 'dias') <> 'array' or jsonb_array_length(d -> 'dias') <> v_ciclo then
    raise exception '%', case when v_tipo = 'escala' then 'Informe os horários de todos os dias do ciclo.'
                              else 'Informe os horários dos 7 dias da semana.' end;
  end if;
  if (select count(distinct (x ->> 'dia_semana')::int) from jsonb_array_elements(d -> 'dias') x
       where (x ->> 'dia_semana')::int between 0 and v_ciclo - 1) <> v_ciclo then
    raise exception 'Os dias da jornada estão incompletos ou repetidos.';
  end if;

  -- Validação dos horários
  for dia in select * from jsonb_array_elements(d -> 'dias') loop
    v_dia := (dia ->> 'dia_semana')::int;
    v_rotulo := case when v_tipo = 'escala' then 'Dia ' || (v_dia + 1) else v_nomes[v_dia + 1] end;
    continue when coalesce((dia ->> 'folga')::boolean, false);
    v_ent := fn_txt(dia, 'entrada')::time;
    v_si  := fn_txt(dia, 'saida_intervalo')::time;
    v_ri  := fn_txt(dia, 'retorno_intervalo')::time;
    v_sai := fn_txt(dia, 'saida')::time;
    if v_ent is null or v_sai is null then
      raise exception '%: informe a entrada e a saída (ou marque como folga).', v_rotulo;
    end if;
    if (v_si is null) <> (v_ri is null) then
      raise exception '%: informe a saída e o retorno do intervalo, ou deixe os dois vazios.', v_rotulo;
    end if;
    if v_si is not null and fn_minutos(v_ent, v_si) + fn_minutos(v_si, v_ri) + fn_minutos(v_ri, v_sai)
                            <> fn_minutos(v_ent, v_sai) then
      raise exception '%: os horários devem seguir a ordem entrada → intervalo → retorno → saída.', v_rotulo;
    end if;
  end loop;

  if v_id is null then
    insert into jornadas (nome, descricao, ativo, tipo, ciclo_dias, data_base, intervalo_flexivel,
                          empresa_id, todas_empresas, intervalo_pre_assinalado)
    values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'),
            coalesce((d ->> 'ativo')::boolean, true),
            v_tipo, case when v_tipo = 'escala' then v_ciclo end,
            case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
            coalesce((d ->> 'intervalo_flexivel')::boolean, false),
            fn_empresa_atual(), coalesce((d ->> 'todas_empresas')::boolean, false),
            coalesce((d ->> 'intervalo_pre_assinalado')::boolean, false))
    returning id into v_id;
  else
    update jornadas set
      nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'),
      ativo = coalesce((d ->> 'ativo')::boolean, true),
      tipo = v_tipo,
      ciclo_dias = case when v_tipo = 'escala' then v_ciclo end,
      data_base = case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
      intervalo_flexivel = coalesce((d ->> 'intervalo_flexivel')::boolean, false),
      todas_empresas = coalesce((d ->> 'todas_empresas')::boolean, todas_empresas),
      intervalo_pre_assinalado = coalesce((d ->> 'intervalo_pre_assinalado')::boolean, false),
      empresa_id = coalesce(empresa_id, fn_empresa_atual())
    where id = v_id;
    if not found then raise exception 'Jornada não encontrada.'; end if;
    delete from jornada_dias where jornada_id = v_id;
  end if;

  insert into jornada_dias (jornada_id, dia_semana, folga, entrada, saida_intervalo, retorno_intervalo, saida,
                            dia_util, recebe_vt, recebe_va)
  select v_id, (x ->> 'dia_semana')::smallint, f.folga,
         case when f.folga then null else fn_txt(x, 'entrada')::time end,
         case when f.folga then null else fn_txt(x, 'saida_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'retorno_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'saida')::time end,
         coalesce((x ->> 'dia_util')::boolean, not f.folga),
         coalesce((x ->> 'recebe_vt')::boolean, not f.folga),
         coalesce((x ->> 'recebe_va')::boolean, not f.folga)
    from jsonb_array_elements(d -> 'dias') x
   cross join lateral (select coalesce((x ->> 'folga')::boolean, false) as folga) f;

  -- A apuração dos dias já encerrados muda com a jornada: recalcula o banco de horas de quem a usa
  perform fn_processar_banco_horas(least(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao)),
                                   fn_hoje() - 1, c.id)
     from colaboradores c
    where c.id in (select colaborador_id from colaborador_situacoes where jornada_id = v_id);

  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    raise exception 'Já existe uma jornada com este nome.';
  when check_violation then
    raise exception 'Valores inválidos: confira o ciclo e a data de início da escala.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Horário inválido. Use o formato HH:MM.';
end $$;

-- -----------------------------------------------------------------------------
-- Tipos de VT e VA
-- -----------------------------------------------------------------------------
create or replace function api_tipos_beneficio_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'tipos_beneficio');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'descricao', t.nome, 'codigo', t.codigo, 'tipo', t.tipo, 'valor_diario', t.valor_diario,
             'ativo', t.ativo,
             'em_uso', (select count(distinct s.colaborador_id) from colaborador_situacoes s
                         where t.id in (s.tipo_vt_id, s.tipo_va_id)))
           order by t.ativo desc, t.tipo desc, t.nome)
      from tipos_beneficio t), '[]'::jsonb);
end $$;

create or replace function api_tipo_beneficio_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  v_txt text := fn_txt(d, 'valor_diario');
  v_valor numeric;
begin
  perform fn_auth(p_token, 'tipos_beneficio', true);
  if fn_txt(d, 'descricao') is null then raise exception 'Informe o nome.'; end if;
  if fn_txt(d, 'codigo') is null then raise exception 'Informe o código.'; end if;
  if coalesce(fn_txt(d, 'tipo'), '') not in ('vt', 'va') then raise exception 'Informe se é VT ou VA.'; end if;
  -- "1.234,56" → 1234.56; "12.5" segue como está
  if v_txt like '%,%' then v_txt := replace(replace(v_txt, '.', ''), ',', '.'); end if;
  if v_txt is null or v_txt !~ '^[0-9]+([.][0-9]{1,2})?$' then raise exception 'Informe o valor diário (ex.: 12,50).'; end if;
  v_valor := v_txt::numeric;
  if v_id is null then
    insert into tipos_beneficio (nome, codigo, tipo, valor_diario, ativo)
    values (fn_txt(d, 'descricao'), fn_txt(d, 'codigo'), fn_txt(d, 'tipo'), v_valor, coalesce((d ->> 'ativo')::boolean, true))
    returning id into v_id;
  else
    if exists (select 1 from tipos_beneficio where id = v_id and tipo <> fn_txt(d, 'tipo'))
       and exists (select 1 from colaborador_situacoes where v_id in (tipo_vt_id, tipo_va_id)) then
      raise exception 'Este tipo já está em uso: não dá para trocar entre VT e VA. Cadastre outro.';
    end if;
    update tipos_beneficio set nome = fn_txt(d, 'descricao'), codigo = fn_txt(d, 'codigo'), tipo = fn_txt(d, 'tipo'),
                               valor_diario = v_valor, ativo = coalesce((d ->> 'ativo')::boolean, true)
     where id = v_id;
    if not found then raise exception 'Tipo não encontrado.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
exception
  when unique_violation then raise exception 'Já existe um tipo de % com este código.', upper(fn_txt(d, 'tipo'));
  when numeric_value_out_of_range then raise exception 'Valor diário muito alto.';
end $$;

create or replace function api_tipo_beneficio_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'tipos_beneficio', true);
  if exists (select 1 from colaborador_situacoes where p_id in (tipo_vt_id, tipo_va_id)) then
    raise exception 'Este tipo já foi usado em colaboradores e não pode ser excluído. Desative-o.';
  end if;
  delete from tipos_beneficio where id = p_id;
  if not found then raise exception 'Tipo não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function api_totais_periodo(
  p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_departamento uuid default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_usuario uuid := fn_auth(p_token, 'totais_periodo');
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;
  perform fn_banco_horas_atualizar();

  drop table if exists pg_temp._tot;
  create temp table _tot on commit drop as
    select a.* from fn_apuracao(p_ini, least(p_fim, fn_hoje() - 1)) a
      join colaboradores c on c.id = a.colaborador_id
     where fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
       and (p_departamento is null or c.departamento_id = p_departamento)
       and fn_visivel(c.id);

  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim, 'apurado_ate', least(p_fim, fn_hoje() - 1)),
    'pode_editar', fn_pode(v_usuario, 'totais_periodo', true),
    'eventos', coalesce((select jsonb_agg(jsonb_build_object('chave', chave, 'descricao', descricao, 'codigo', codigo,
                                                             'unidade', unidade, 'ativo', ativo) order by ordem)
                           from eventos_folha), '[]'::jsonb),
    'colaboradores', coalesce((
      select jsonb_agg(x order by x.nome)
        from (
          select c.id, c.nome, c.matricula, d.nome as departamento, j.nome as jornada,
                 count(*) filter (where t.qtd_batidas > 0)                                          as dias_trabalhados,
                 coalesce(sum(t.previsto_min), 0)::int                                             as previsto_min,
                 coalesce(sum(t.trabalhado_min), 0)::int                                           as trabalhado_min,
                 -- Horas extras pagas (sem banco de horas), separadas pelo percentual do dia
                 coalesce(sum(t.extra_min) filter (where not t.banco_horas), 0)::int                as he_min,
                 fn_he_por_percentual(jsonb_agg(jsonb_build_object('p', t.he_percentual, 'm', t.extra_min))
                                        filter (where not t.banco_horas and t.extra_min > 0))      as he,
                 coalesce(sum(t.noturno_reduzido_min), 0)::int                                     as noturno_min,
                 count(*) filter (where t.falta)                                                    as faltas_dias,
                 coalesce(sum(t.debito_min) filter (where t.falta), 0)::int                        as faltas_min,
                 coalesce(sum(t.atraso_min), 0)::int                                               as atraso_min,
                 coalesce(sum(t.saida_antecipada_min), 0)::int                                     as saida_antecipada_min,
                 -- O que vai para a folha: só jornadas sem banco (com banco, o débito já está no saldo).
                 -- O débito do dia é repartido entre atrasos/saídas e o restante, para não ser descontado duas vezes.
                 count(*) filter (where t.falta and not t.banco_horas)                              as faltas_folha_dias,
                 coalesce(sum(t.debito_min) filter (where t.falta and not t.banco_horas), 0)::int  as faltas_folha_min,
                 coalesce(sum(least(t.atraso_min + t.saida_antecipada_min, t.debito_min))
                          filter (where not t.banco_horas and not t.falta), 0)::int                as atraso_folha_min,
                 coalesce(sum(t.debito_min - least(t.atraso_min + t.saida_antecipada_min, t.debito_min))
                          filter (where not t.banco_horas and not t.falta), 0)::int                as desconto_min,
                 -- DSR perdido: semanas (dom–sáb) com falta não justificada em dia útil da jornada
                 count(distinct date_trunc('week', t.data + 1))
                   filter (where t.falta and fn_dia_util(t.jornada_id, t.data, t.escala))            as dsr_perdidos,
                 coalesce(sum(t.banco_min) filter (where t.banco_horas), 0)::int                   as bh_periodo_min,
                 (select coalesce(sum(bh.minutos), 0) from banco_horas bh
                   where bh.colaborador_id = c.id and bh.data <= p_fim)::int                       as bh_saldo_min,
                 -- Conversões do banco de horas no período (menu Conversão do Banco de Horas)
                 (select coalesce(-sum(bh.minutos) filter (where bh.minutos < 0), 0) from banco_horas bh
                   where bh.colaborador_id = c.id and bh.tipo = 'conversao' and bh.data between p_ini and p_fim)::int as bh_pago_min,
                 (select coalesce(sum(bh.minutos) filter (where bh.minutos > 0), 0) from banco_horas bh
                   where bh.colaborador_id = c.id and bh.tipo = 'conversao' and bh.data between p_ini and p_fim)::int as bh_descontado_min,
                 count(*) filter (where t.ocorrencia = 'inconsistente')                            as inconsistencias
            from pg_temp._tot t
            join colaboradores c      on c.id = t.colaborador_id
            left join departamentos d on d.id = c.departamento_id
            left join jornadas j      on j.id = c.jornada_id
           group by c.id, c.nome, c.matricula, d.nome, j.nome
        ) x), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- Relatórios de VT e de VA: dias marcados na jornada para o benefício, por colaborador que o recebe
-- (tipo da situação vigente no dia), e se o dia conta. Conta com um turno completo ou com os dois,
-- conforme a configuração; dia previsto com um turno só precisa apenas dele. Só dias encerrados; até 92 dias.
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_beneficio(
  p_token text, p_tipo text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_ate date := least(p_fim, fn_hoje() - 1);
  v_tz  text := fn_fuso();
  v_turnos text := coalesce((select beneficio_turnos from empresa where id = 1), 'um');
  v_um  uuid := case when cardinality(p_colaboradores) = 1 then p_colaboradores[1] end;
begin
  if p_tipo is null or p_tipo not in ('vt', 'va') then raise exception 'Informe se o relatório é de VT ou de VA.'; end if;
  perform fn_auth(p_token, 'relatorio_' || p_tipo);
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 91 then raise exception 'Selecione um período de até 92 dias (três meses).'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim, 'apurado_ate', v_ate),
    'turnos', v_turnos,
    'itens', coalesce((
      with apu as materialized (
        select a.*, c.nome, c.matricula, d.nome as departamento,
               t.id as tipo_id, t.nome as tipo_nome, t.codigo, t.valor_diario
          from fn_apuracao(p_ini, v_ate, v_um) a
          join colaboradores c      on c.id = a.colaborador_id
          left join departamentos d on d.id = c.departamento_id
          join lateral (
            select s.tipo_vt_id, s.tipo_va_id from colaborador_situacoes s
             where s.colaborador_id = a.colaborador_id and s.data_inicio <= a.data
             order by s.data_inicio desc limit 1) s on true
          join tipos_beneficio t    on t.id = case p_tipo when 'vt' then s.tipo_vt_id else s.tipo_va_id end
          join jornadas j           on j.id = a.jornada_id
          join jornada_dias jd      on jd.jornada_id = j.id
                                   and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, a.data)
         where case p_tipo when 'vt' then jd.recebe_vt else jd.recebe_va end
           and fn_visivel(c.id)
           and fn_filtro_colaborador(c.id, null, p_colaboradores)
           and (p_departamento is null or c.departamento_id = p_departamento)
      ),
      bat as materialized (
        select x.colaborador_id, x.data_referencia as data,
               count(distinct x.turno) filter (where x.sentido = 'E' and x.ps = 'S' and x.pt = x.turno)::int as turnos,
               jsonb_agg(jsonb_build_object('hora', to_char(x.data_hora at time zone v_tz, 'HH24:MI'),
                                            'sentido', x.sentido, 'turno', x.turno, 'manual', x.origem = 'manual')
                         order by x.data_hora, x.id) as batidas
          from (select b.*, lead(b.sentido) over w as ps, lead(b.turno) over w as pt
                  from fn_batidas_periodo(p_ini, v_ate, v_um) b
                 where b.status = 'valida'
                window w as (partition by b.colaborador_id, b.data_referencia order by b.data_hora, b.id)) x
         group by x.colaborador_id, x.data_referencia
      ),
      dia as (
        select a.*, coalesce(b.batidas, '[]'::jsonb) as batidas,
               case when a.pre_assinalado then 2 else coalesce(b.turnos, 0) end as turnos,
               case when jd.folga or jd.entrada is null or jd.saida_intervalo is null then 1 else 2 end as turnos_previstos
          from apu a
          left join bat b on b.colaborador_id = a.colaborador_id and b.data = a.data
          left join lateral fn_jornada_dia(a.colaborador_id, a.data) jd on true
      ),
      res as (
        select x.*, x.turnos >= case when v_turnos = 'dois' then x.turnos_previstos else 1 end as computa from dia x
      )
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', g.colaborador_id, 'nome', g.nome, 'matricula', g.matricula, 'departamento', g.departamento,
               'dias_marcados', g.marcados, 'dias_computados', g.computados, 'valor_total', g.valor, 'dias', g.dias)
             order by g.nome, g.colaborador_id)
        from (
          select r.colaborador_id, r.nome, r.matricula, r.departamento,
                 count(*) as marcados, count(*) filter (where r.computa) as computados,
                 coalesce(sum(r.valor_diario) filter (where r.computa), 0) as valor,
                 jsonb_agg(jsonb_build_object(
                   'data', r.data, 'tipo', r.tipo_nome, 'codigo', r.codigo, 'valor_diario', r.valor_diario,
                   'batidas', r.batidas, 'pre_assinalado', r.pre_assinalado, 'turnos', r.turnos,
                   'turnos_previstos', r.turnos_previstos, 'trabalhado_min', r.trabalhado_min,
                   'ocorrencia', r.ocorrencia, 'escala', r.escala, 'computa', r.computa) order by r.data) as dias
            from res r
           group by r.colaborador_id, r.nome, r.matricula, r.departamento) g), '[]'::jsonb));
end $$;

create or replace function api_configuracoes(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'configuracoes');
begin
  return (select jsonb_build_object(
            'pode_editar', fn_pode(v_usuario, 'configuracoes', true),
            'usar_limitacoes_ponto', e.usar_limitacoes_ponto,
            'bloquear_fora_cerca', e.bloquear_fora_cerca,
            'beneficio_turnos', e.beneficio_turnos,
            'fuso_horario', e.fuso_horario,
            'empresas', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', x.id, 'nome', coalesce(x.nome_fantasia, x.razao_social),
                       'tem_local', exists (select 1 from locais_ponto l where l.empresa_id = x.id and l.ativo),
                       'raio_m', (select l.raio_m from locais_ponto l where l.empresa_id = x.id and l.ativo))
                     order by coalesce(x.nome_fantasia, x.razao_social))
                from empresas x where x.ativo), '[]'::jsonb))
            from empresa e where e.id = 1);
end $$;

create or replace function api_configuracoes_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'configuracoes', true);
  if coalesce(fn_txt(p_dados, 'beneficio_turnos'), 'um') not in ('um', 'dois') then
    raise exception 'Opção inválida para VT e VA.';
  end if;
  update empresa set
    usar_limitacoes_ponto = coalesce((p_dados ->> 'usar_limitacoes_ponto')::boolean, usar_limitacoes_ponto),
    bloquear_fora_cerca = coalesce((p_dados ->> 'bloquear_fora_cerca')::boolean, bloquear_fora_cerca),
    beneficio_turnos = coalesce(fn_txt(p_dados, 'beneficio_turnos'), beneficio_turnos)
   where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function api_v1_totais(p_chave text, p_inicio date, p_fim date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_empresa uuid := fn_auth_chave(p_chave);
  v_ate date;
begin
  perform fn_v1_periodo(p_inicio, p_fim);
  perform fn_banco_horas_atualizar();
  v_ate := least(p_fim, fn_hoje() - 1);
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_inicio, 'fim', p_fim, 'apurado_ate', v_ate),
    'colaboradores', coalesce((
      select jsonb_agg(x order by x.matricula)
        from (
          select c.id as colaborador_id, c.matricula, c.nome, c.cpf, c.pis,
                 count(*) filter (where a.qtd_batidas > 0)                                       as dias_trabalhados,
                 coalesce(sum(a.previsto_min), 0)::int                                          as previsto_min,
                 coalesce(sum(a.trabalhado_min), 0)::int                                        as trabalhado_min,
                 coalesce(sum(a.extra_min) filter (where not a.banco_horas), 0)::int             as horas_extras_min,
                 fn_he_por_percentual(jsonb_agg(jsonb_build_object('p', a.he_percentual, 'm', a.extra_min))
                                        filter (where not a.banco_horas and a.extra_min > 0))   as horas_extras_por_percentual,
                 coalesce(sum(a.noturno_reduzido_min), 0)::int                                  as adicional_noturno_min,
                 count(*) filter (where a.falta and not a.banco_horas)                           as faltas_dias,
                 coalesce(sum(a.debito_min) filter (where a.falta and not a.banco_horas), 0)::int as faltas_min,
                 coalesce(sum(least(a.atraso_min + a.saida_antecipada_min, a.debito_min))
                          filter (where not a.banco_horas and not a.falta), 0)::int             as atrasos_min,
                 count(distinct date_trunc('week', a.data + 1))
                   filter (where a.falta and fn_dia_util(a.jornada_id, a.data, a.escala))         as dsr_perdidos,
                 coalesce(sum(a.banco_min) filter (where a.banco_horas), 0)::int                as banco_horas_periodo_min,
                 count(*) filter (where a.ocorrencia = 'inconsistente')                         as dias_inconsistentes
            from fn_apuracao(p_inicio, v_ate) a
            join colaboradores c on c.id = a.colaborador_id
           where c.empresa_id = v_empresa
           group by c.id, c.matricula, c.nome, c.cpf, c.pis
        ) x), '[]'::jsonb));
end $$;

insert into paginas (chave, nome, grupo, ordem) values
  ('tipos_beneficio',    'Tipos de VT e VA',          'Cadastros',  48),
  ('relatorio_vt',       'Relatório de VT',           'Relatórios', 89),
  ('relatorio_va',       'Relatório de VA',           'Relatórios', 89)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

-- VT e VA: o cadastro segue as jornadas; os relatórios, os totais do período
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'tipos_beneficio', pode_visualizar, pode_editar from perfil_permissoes where pagina = 'jornadas'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, x.pagina, pode_visualizar, false
  from perfil_permissoes cross join (values ('relatorio_vt'), ('relatorio_va')) x(pagina)
 where perfil_permissoes.pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;

grant execute on function api_tipos_beneficio_listar(text)                 to anon, authenticated;
grant execute on function api_tipo_beneficio_salvar(text, jsonb)           to anon, authenticated;
grant execute on function api_tipo_beneficio_excluir(text, uuid)           to anon, authenticated;
revoke execute on function fn_dia_util(uuid, date, text)                   from public, anon, authenticated;
revoke execute on function fn_tipos_beneficio_json()                       from public, anon, authenticated;
revoke execute on function fn_beneficio_informado(jsonb, text, uuid)       from public, anon, authenticated;
grant execute on function api_relatorio_beneficio(text, text, date, date, uuid[], uuid) to anon, authenticated;

notify pgrst, 'reload schema';
