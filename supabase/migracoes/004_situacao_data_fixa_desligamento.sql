-- =============================================================================
-- GePonto: atualização 004 — Situação do Colaborador
-- • A data de uma situação lançada não pode ser alterada
-- • O desligamento não é uma situação: fica na data de desligamento do cadastro
-- Requer: atualização 003. Pode ser executado mais de uma vez.
-- =============================================================================

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

-- Leva ao cadastro a situação vigente hoje (situação, cargo, departamento, jornada, regra e salário).
-- Passada a data de desligamento do cadastro, a situação é "desligado".
create or replace function fn_colaborador_situacao_aplicar(p_colaborador uuid)
returns void language plpgsql volatile set search_path = public as $$
declare
  s colaborador_situacoes%rowtype;
  v_sit situacao_colaborador;
begin
  select * into s from colaborador_situacoes
   where colaborador_id = p_colaborador and data_inicio <= fn_hoje()
   order by data_inicio desc limit 1;
  if not found then   -- admissão futura: vale a primeira
    select * into s from colaborador_situacoes where colaborador_id = p_colaborador order by data_inicio limit 1;
    if not found then return; end if;
  end if;
  select case when c.data_desligamento < fn_hoje() then 'desligado'::situacao_colaborador else s.situacao end
    into v_sit from colaboradores c where c.id = p_colaborador;

  perform set_config('app.data_vigencia', s.data_inicio::text, true);
  update colaboradores c set
         situacao = v_sit, cargo_id = s.cargo_id, departamento_id = s.departamento_id,
         jornada_id = s.jornada_id, perfil_evento_id = coalesce(s.perfil_evento_id, c.perfil_evento_id),
         salario = s.salario
   where c.id = p_colaborador
     and (c.situacao, c.cargo_id, c.departamento_id, c.jornada_id, c.perfil_evento_id, c.salario)
         is distinct from
         (v_sit, s.cargo_id, s.departamento_id, s.jornada_id, coalesce(s.perfil_evento_id, c.perfil_evento_id), s.salario);
end $$;

create or replace function fn_banco_horas_atualizar()
returns void language plpgsql volatile set search_path = public as $$
declare
  v_ate   date;
  v_ontem date := fn_hoje() - 1;
begin
  select banco_horas_processado_ate into v_ate from empresa where id = 1 for update;
  if v_ate is null then
    select min(fn_inicio_controle(c)) - 1 into v_ate from colaboradores c;
  end if;
  if v_ate is null or v_ate < v_ontem then
    -- Situações que passaram a valer desde a última execução vão para o cadastro
    perform fn_colaborador_situacao_aplicar(x.colaborador_id)
       from (select s.colaborador_id from colaborador_situacoes s
              where s.data_inicio > coalesce(v_ate, '-infinity'::date) and s.data_inicio <= fn_hoje()
             union   -- e quem passou da data de desligamento
             select c.id from colaboradores c
              where c.data_desligamento >= coalesce(v_ate, '-infinity'::date) and c.data_desligamento < fn_hoje()) x;
    if v_ate is not null then
      perform fn_processar_banco_horas(v_ate + 1, v_ontem);
    end if;
    update empresa set banco_horas_processado_ate = v_ontem where id = 1;
  end if;
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
  if fn_txt(d, 'matricula') is null then raise exception 'Informe a matrícula.'; end if;
  if length(regexp_replace(coalesce(d ->> 'cpf', ''), '[^0-9]', '', 'g')) <> 11 then
    raise exception 'Informe um CPF válido (11 dígitos).';
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

-- Inclui ou altera uma situação. Vale da data informada até a véspera da seguinte.
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
  v_fechado date := fn_fechado_ate();
  v_perfil uuid;
  v_jornada uuid := fn_txt(d, 'jornada_id')::uuid;
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

  select data_admissao into v_adm from colaboradores where id = v_colab;
  select min(data_inicio) into v_primeira from colaborador_situacoes where colaborador_id = v_colab;
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

  perform set_config('app.data_vigencia', v_data::text, true);
  if v_id is null then
    insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                       jornada_id, perfil_evento_id, salario, motivo, usuario_id)
    values (v_colab, v_data, coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador,
            fn_txt(d, 'cargo_id')::uuid, fn_txt(d, 'departamento_id')::uuid, v_jornada, v_perfil,
            fn_txt(d, 'salario')::numeric, fn_txt(d, 'motivo'), v_usuario)
    returning id into v_id;
  else
    update colaborador_situacoes set
           data_inicio = v_data, situacao = coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador,
           cargo_id = fn_txt(d, 'cargo_id')::uuid, departamento_id = fn_txt(d, 'departamento_id')::uuid,
           jornada_id = v_jornada, perfil_evento_id = v_perfil, salario = fn_txt(d, 'salario')::numeric,
           motivo = fn_txt(d, 'motivo'), alterado_por = v_usuario
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


-- O cadastro passa a refletir a situação vigente hoje (e o desligamento pela data)
select fn_colaborador_situacao_aplicar(id) from colaboradores;

notify pgrst, 'reload schema';
