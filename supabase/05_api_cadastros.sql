-- =============================================================================
-- GePonto — 05_api_cadastros.sql
-- API de cadastros: colaboradores, departamentos, cargos e jornadas de trabalho.
-- Execute depois de 02_functions.sql. Pode ser reexecutado.
-- =============================================================================

-- Texto do JSON sem espaços nas pontas; string vazia vira null
create or replace function fn_txt(p jsonb, k text)
returns text language sql immutable as $$
  select nullif(trim(p ->> k), '');
$$;

-- -----------------------------------------------------------------------------
-- Listas auxiliares para os formulários
-- -----------------------------------------------------------------------------
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
                                 from jornadas where ativo), '[]'::jsonb),
    'perfis_eventos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'padrao', padrao)
                                                 order by padrao desc, nome)
                                  from perfis_eventos where ativo), '[]'::jsonb),
    'gestores',      coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from colaboradores where situacao <> 'desligado'), '[]'::jsonb)
  );
end $$;

-- Cria (ou retorna o existente) departamento / cargo a partir do formulário
create or replace function api_departamento_criar(p_token text, p_nome text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  perform fn_auth(p_token, 'colaboradores', true);
  if coalesce(trim(p_nome), '') = '' then
    raise exception 'Informe o nome do departamento.';
  end if;
  insert into departamentos (nome) values (trim(p_nome))
  on conflict (nome) do update set ativo = true
  returning jsonb_build_object('id', id, 'nome', nome) into v;
  return v;
end $$;

create or replace function api_cargo_criar(p_token text, p_nome text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  perform fn_auth(p_token, 'colaboradores', true);
  if coalesce(trim(p_nome), '') = '' then
    raise exception 'Informe o nome do cargo.';
  end if;
  insert into cargos (nome) values (trim(p_nome))
  on conflict (nome) do update set ativo = true
  returning jsonb_build_object('id', id, 'nome', nome) into v;
  return v;
end $$;

-- -----------------------------------------------------------------------------
-- Colaboradores
-- -----------------------------------------------------------------------------
create or replace function api_colaboradores_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'colaboradores');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'matricula', c.matricula, 'nome', c.nome, 'cpf', c.cpf,
             'email', c.email, 'telefone', c.telefone, 'situacao', c.situacao,
             'data_admissao', c.data_admissao, 'data_desligamento', c.data_desligamento,
             'controla_ponto', c.controla_ponto, 'controle_ponto_inicio', fn_inicio_controle(c),
             'cargo', g.nome, 'departamento', d.nome, 'jornada', j.nome, 'perfil_evento', pe.nome,
             'tem_acesso', exists (select 1 from usuarios u where u.colaborador_id = c.id and u.status = 'ativo'))
           order by c.nome)
      from colaboradores c
      left join cargos g        on g.id = c.cargo_id
      left join departamentos d on d.id = c.departamento_id
      left join jornadas j      on j.id = c.jornada_id
      left join perfis_eventos pe on pe.id = c.perfil_evento_id
     where fn_visivel(c.id)
  ), '[]'::jsonb);
end $$;

create or replace function api_colaborador_obter(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  perform fn_auth(p_token, 'colaboradores');
  select to_jsonb(c) - 'created_at' - 'updated_at'
         || jsonb_build_object(
              'historico', coalesce((
                select jsonb_agg(jsonb_build_object(
                         'id', h.id, 'tipo', h.tipo, 'descricao', h.descricao,
                         'dados_anteriores', h.dados_anteriores, 'dados_novos', h.dados_novos,
                         'usuario', u.nome, 'created_at', h.created_at, 'data_vigencia', h.data_vigencia)
                       order by h.data_vigencia desc, h.created_at desc)
                  from colaborador_historico h
                  left join usuarios u on u.id = h.usuario_id
                 where h.colaborador_id = c.id), '[]'::jsonb),
              'jornadas_vigencias', coalesce((
                select jsonb_agg(jsonb_build_object(
                         'data_inicio', cj.data_inicio, 'jornada_id', cj.jornada_id, 'jornada', j.nome,
                         'data_fim', (select min(x.data_inicio) - 1 from colaborador_jornadas x
                                       where x.colaborador_id = cj.colaborador_id and x.data_inicio > cj.data_inicio))
                       order by cj.data_inicio desc)
                  from colaborador_jornadas cj
                  join jornadas j on j.id = cj.jornada_id
                 where cj.colaborador_id = c.id), '[]'::jsonb),
              'acesso', (
                select jsonb_build_object('usuario_id', u.id, 'login', u.login, 'status', u.status,
                                          'perfil', p.nome, 'ultimo_acesso', u.ultimo_acesso)
                  from usuarios u join perfis p on p.id = u.perfil_id
                 where u.colaborador_id = c.id
                 limit 1))
    into v
    from colaboradores c
   where c.id = p_id and fn_visivel(c.id);

  if v is null then
    raise exception 'Colaborador não encontrado.';
  end if;
  return v;
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
  v_vigencia date;
  v_reproc date;
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
  v_vigencia := coalesce(fn_txt(d, 'data_vigencia')::date, fn_hoje());

  -- Perfil de eventos: precisa estar ativo (um perfil inativo só fica em quem já o usava)
  if fn_txt(d, 'perfil_evento_id') is not null and not exists (
       select 1 from perfis_eventos pe
        where pe.id = fn_txt(d, 'perfil_evento_id')::uuid
          and (pe.ativo or pe.id = (select c.perfil_evento_id from colaboradores c where c.id = v_id))) then
    raise exception 'Escolha um perfil de eventos ativo.';
  end if;

  if v_controle is not null and v_controle < v_admissao then
    raise exception 'O controle de ponto não pode começar antes da admissão (%).', to_char(v_admissao, 'DD/MM/YYYY');
  end if;
  -- A vigência só importa quando muda jornada, cargo, departamento ou situação. Nas demais edições
  -- (ex.: corrigir o nome de quem ainda vai ser admitido) ela é só a data do registro no histórico.
  if v_id is not null and v_vigencia < v_admissao then
    select * into v_old from colaboradores where id = v_id;
    if v_old.jornada_id is distinct from fn_txt(d, 'jornada_id')::uuid
       or v_old.cargo_id is distinct from fn_txt(d, 'cargo_id')::uuid
       or v_old.departamento_id is distinct from fn_txt(d, 'departamento_id')::uuid
       or v_old.situacao is distinct from v_situacao then
      raise exception 'A data de vigência não pode ser anterior à admissão (%).', to_char(v_admissao, 'DD/MM/YYYY');
    end if;
    v_vigencia := v_admissao;
  end if;

  if v_situacao = 'desligado' and v_deslig is null then
    v_deslig := fn_hoje();
  elsif v_situacao <> 'desligado' then
    v_deslig := null;
  end if;

  -- Lido pelo trigger de histórico: as alterações valem a partir desta data
  perform set_config('app.data_vigencia', v_vigencia::text, true);

  if v_id is null then
    insert into colaboradores (
      matricula, nome, nome_social, cpf, pis, rg, data_nascimento, sexo, email, telefone,
      cep, logradouro, numero, complemento, bairro, cidade, uf,
      cargo_id, departamento_id, jornada_id, gestor_id, perfil_evento_id,
      data_admissao, data_desligamento, situacao, salario, observacoes,
      controla_ponto, controle_ponto_inicio)
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
      coalesce((d ->> 'controla_ponto')::boolean, true), v_controle)
    returning id into v_id;
    v_reproc := v_admissao;
  else
    if fn_txt(d, 'gestor_id')::uuid = v_id then
      raise exception 'O colaborador não pode ser gestor dele mesmo.';
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
      cargo_id = fn_txt(d, 'cargo_id')::uuid, departamento_id = fn_txt(d, 'departamento_id')::uuid,
      jornada_id = fn_txt(d, 'jornada_id')::uuid, gestor_id = fn_txt(d, 'gestor_id')::uuid,
      perfil_evento_id = coalesce(fn_txt(d, 'perfil_evento_id')::uuid, perfil_evento_id),
      data_admissao = v_admissao, data_desligamento = v_deslig,
      situacao = v_situacao, salario = fn_txt(d, 'salario')::numeric, observacoes = fn_txt(d, 'observacoes'),
      controla_ponto = coalesce((d ->> 'controla_ponto')::boolean, true),
      controle_ponto_inicio = v_controle
    where id = v_id;
    if not found then raise exception 'Colaborador não encontrado.'; end if;

    -- A jornada da admissão é a primeira vigência
    if fn_txt(d, 'jornada_id') is not null
       and not exists (select 1 from colaborador_jornadas where colaborador_id = v_id and data_inicio <= v_admissao) then
      insert into colaborador_jornadas (colaborador_id, data_inicio, jornada_id)
      values (v_id, v_admissao,
              coalesce((select jornada_id from colaborador_jornadas where colaborador_id = v_id
                         order by data_inicio limit 1), fn_txt(d, 'jornada_id')::uuid));
    end if;
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

-- Acesso do colaborador ao sistema para registrar o próprio ponto (perfil "Colaborador")
create or replace function api_colaborador_acesso_salvar(
  p_token text, p_colaborador uuid, p_login text, p_senha text default null, p_ativo boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid;
  v_perfil  text;
  v_nome    text;
begin
  perform fn_auth(p_token, 'colaboradores', true);

  select nome into v_nome from colaboradores where id = p_colaborador;
  if v_nome is null then raise exception 'Colaborador não encontrado.'; end if;
  if not fn_visivel(p_colaborador) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  if coalesce(trim(p_login), '') = '' then raise exception 'Informe o login de acesso.'; end if;
  if p_senha is not null and p_senha <> '' and length(p_senha) < 6 then
    raise exception 'A senha deve ter ao menos 6 caracteres.';
  end if;

  select u.id, p.nome into v_usuario, v_perfil
    from usuarios u join perfis p on p.id = u.perfil_id
   where u.colaborador_id = p_colaborador
   limit 1;

  if v_usuario is not null and v_perfil <> 'Colaborador' then
    raise exception 'Este colaborador usa um acesso com perfil "%". Altere-o em Usuários & Permissões.', v_perfil;
  end if;

  if v_usuario is null then
    if coalesce(p_senha, '') = '' then raise exception 'Defina uma senha para o primeiro acesso.'; end if;
    insert into usuarios (nome, login, senha_hash, perfil_id, colaborador_id, status)
    values (v_nome, trim(p_login), fn_hash_senha(p_senha),
            (select id from perfis where nome = 'Colaborador'), p_colaborador,
            case when p_ativo then 'ativo' else 'inativo' end::status_usuario)
    returning id into v_usuario;
  else
    update usuarios set
      nome = v_nome,
      login = trim(p_login),
      senha_hash = case when coalesce(p_senha, '') = '' then senha_hash else fn_hash_senha(p_senha) end,
      status = case when p_ativo then 'ativo' else 'inativo' end::status_usuario,
      tentativas_falhas = 0,
      bloqueado_ate = null
    where id = v_usuario;
    if not p_ativo or coalesce(p_senha, '') <> '' then
      delete from sessoes where usuario_id = v_usuario;   -- força novo login
    end if;
  end if;

  return jsonb_build_object('ok', true, 'usuario_id', v_usuario);
exception
  when unique_violation then
    raise exception 'O login "%" já está em uso. Escolha outro.', trim(p_login);
end $$;

-- -----------------------------------------------------------------------------
-- Jornadas de trabalho
-- -----------------------------------------------------------------------------
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
                              'entrada', to_char(jd.entrada, 'HH24:MI'),
                              'saida_intervalo', to_char(jd.saida_intervalo, 'HH24:MI'),
                              'retorno_intervalo', to_char(jd.retorno_intervalo, 'HH24:MI'),
                              'saida', to_char(jd.saida, 'HH24:MI'))
                            order by jd.dia_semana)
                       from jornada_dias jd where jd.jornada_id = j.id), '[]'::jsonb))
             order by j.ativo desc, j.nome)
      from jornadas j
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
    insert into jornadas (nome, descricao, ativo, tipo, ciclo_dias, data_base)
    values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'),
            coalesce((d ->> 'ativo')::boolean, true),
            v_tipo, case when v_tipo = 'escala' then v_ciclo end,
            case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end)
    returning id into v_id;
  else
    update jornadas set
      nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'),
      ativo = coalesce((d ->> 'ativo')::boolean, true),
      tipo = v_tipo,
      ciclo_dias = case when v_tipo = 'escala' then v_ciclo end,
      data_base = case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end
    where id = v_id;
    if not found then raise exception 'Jornada não encontrada.'; end if;
    delete from jornada_dias where jornada_id = v_id;
  end if;

  insert into jornada_dias (jornada_id, dia_semana, folga, entrada, saida_intervalo, retorno_intervalo, saida)
  select v_id, (x ->> 'dia_semana')::smallint, f.folga,
         case when f.folga then null else fn_txt(x, 'entrada')::time end,
         case when f.folga then null else fn_txt(x, 'saida_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'retorno_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'saida')::time end
    from jsonb_array_elements(d -> 'dias') x
   cross join lateral (select coalesce((x ->> 'folga')::boolean, false) as folga) f;

  -- A apuração dos dias já encerrados muda com a jornada: recalcula o banco de horas de quem a usa
  perform fn_processar_banco_horas(least(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao)),
                                   fn_hoje() - 1, c.id)
     from colaboradores c
    where c.id in (select colaborador_id from colaborador_jornadas where jornada_id = v_id);

  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    raise exception 'Já existe uma jornada com este nome.';
  when check_violation then
    raise exception 'Valores inválidos: confira o ciclo e a data de início da escala.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Horário inválido. Use o formato HH:MM.';
end $$;

create or replace function api_jornada_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_qtd int;
begin
  perform fn_auth(p_token, 'jornadas', true);
  select count(distinct colaborador_id) into v_qtd
    from (select id as colaborador_id from colaboradores where jornada_id = p_id
          union all
          select colaborador_id from colaborador_jornadas where jornada_id = p_id) x;
  if v_qtd > 0 then
    raise exception 'Esta jornada está vinculada a % colaborador(es). Ela fica no histórico deles; desative-a em vez de excluir.', v_qtd;
  end if;
  delete from jornadas where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Perfis de eventos: tolerâncias, percentual de HE por dia (domingo … sábado, feriado e folga),
-- limite de HE, adicional noturno e banco de horas. Vinculados ao colaborador.
-- -----------------------------------------------------------------------------
create or replace function api_perfis_eventos_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'perfis_eventos');
  return coalesce((
    select jsonb_agg(
             to_jsonb(p) - 'created_at' - 'updated_at'
             || jsonb_build_object(
                  'noturno_inicio', to_char(p.noturno_inicio, 'HH24:MI'),
                  'noturno_fim', to_char(p.noturno_fim, 'HH24:MI'),
                  'percentual_noturno', p.percentual_noturno::float8,
                  'he', coalesce((select jsonb_agg(jsonb_build_object('dia', h.dia, 'percentual', h.percentual::float8)
                                                   order by h.dia)
                                    from perfil_evento_he h where h.perfil_id = p.id), '[]'::jsonb),
                  'colaboradores', (select count(*) from colaboradores c
                                     where c.perfil_evento_id = p.id and c.situacao <> 'desligado'))
             order by p.ativo desc, p.padrao desc, p.nome)
      from perfis_eventos p
  ), '[]'::jsonb);
end $$;

create or replace function api_perfil_evento_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d        jsonb := p_dados;
  v_id     uuid := nullif(d ->> 'id', '')::uuid;
  v_padrao boolean := coalesce((d ->> 'padrao')::boolean, false);
  v_ativo  boolean := coalesce((d ->> 'ativo')::boolean, true);
  v_era_padrao boolean;
begin
  perform fn_auth(p_token, 'perfis_eventos', true);

  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome do perfil.'; end if;
  if jsonb_typeof(d -> 'he') <> 'array'
     or (select count(distinct (x ->> 'dia')::int) from jsonb_array_elements(d -> 'he') x
          where (x ->> 'dia')::int between 0 and 8 and fn_txt(x, 'percentual') is not null) <> 9 then
    raise exception 'Informe o percentual de hora extra de todos os dias da semana, do feriado e da folga.';
  end if;
  if coalesce(fn_txt(d, 'tolerancia_modo'), 'batida') not in ('batida', 'diaria') then
    raise exception 'Escolha a tolerância por batida ou a geral do dia.';
  end if;
  if exists (select 1 from jsonb_array_elements(d -> 'he') x
              where (x ->> 'percentual')::numeric not between 0 and 999) then
    raise exception 'O percentual de hora extra deve ficar entre 0%% e 999%%.';
  end if;
  if v_padrao and not v_ativo then
    raise exception 'O perfil padrão precisa estar ativo.';
  end if;

  select padrao into v_era_padrao from perfis_eventos where id = v_id;
  if coalesce(v_era_padrao, false) and not v_padrao then
    raise exception 'Este é o perfil padrão. Para trocar, marque outro perfil como padrão.';
  end if;
  if v_padrao then
    update perfis_eventos set padrao = false where padrao and id is distinct from v_id;
  end if;

  if v_id is null then
    insert into perfis_eventos (nome, descricao, padrao, ativo) values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'), v_padrao, v_ativo)
    returning id into v_id;
  else
    if v_era_padrao is null then raise exception 'Perfil não encontrado.'; end if;
    if not v_ativo and exists (select 1 from colaboradores where perfil_evento_id = v_id and situacao <> 'desligado') then
      raise exception 'Há colaboradores ativos com este perfil. Mude o perfil deles antes de desativá-lo.';
    end if;
  end if;

  update perfis_eventos set
    nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'), padrao = v_padrao, ativo = v_ativo,
    tolerancia_entrada_min = coalesce(fn_txt(d, 'tolerancia_entrada_min')::smallint, 5),
    tolerancia_saida_min   = coalesce(fn_txt(d, 'tolerancia_saida_min')::smallint, 5),
    tolerancia_diaria_min  = coalesce(fn_txt(d, 'tolerancia_diaria_min')::smallint, 10),
    tolerancia_modo        = coalesce(fn_txt(d, 'tolerancia_modo'), 'batida'),
    limite_he_diario_min   = coalesce(fn_txt(d, 'limite_he_diario_min')::smallint, 120),
    usa_banco_horas        = coalesce((d ->> 'usa_banco_horas')::boolean, true),
    noturno_inicio         = coalesce(fn_txt(d, 'noturno_inicio')::time, '22:00'),
    noturno_fim            = coalesce(fn_txt(d, 'noturno_fim')::time, '05:00'),
    percentual_noturno     = coalesce(fn_txt(d, 'percentual_noturno')::numeric, 20),
    hora_noturna_reduzida  = coalesce((d ->> 'hora_noturna_reduzida')::boolean, true)
  where id = v_id;

  insert into perfil_evento_he (perfil_id, dia, percentual)
  select v_id, (x ->> 'dia')::smallint, (x ->> 'percentual')::numeric
    from jsonb_array_elements(d -> 'he') x
   where (x ->> 'dia')::int between 0 and 8
  on conflict (perfil_id, dia) do update set percentual = excluded.percentual;

  perform fn_eventos_he_sincronizar();

  -- As regras valem para os dias já encerrados: recalcula o banco de horas de quem usa o perfil
  perform fn_processar_banco_horas(least(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao)),
                                   fn_hoje() - 1, c.id)
     from colaboradores c
    where c.perfil_evento_id = v_id;

  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    raise exception 'Já existe um perfil com este nome.';
  when check_violation then
    raise exception 'Valores inválidos: tolerâncias, limite e percentuais não podem ser negativos.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Horário inválido. Use o formato HH:MM.';
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Confira os números informados.';
end $$;

create or replace function api_perfil_evento_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_qtd int;
begin
  perform fn_auth(p_token, 'perfis_eventos', true);
  if exists (select 1 from perfis_eventos where id = p_id and padrao) then
    raise exception 'O perfil padrão não pode ser excluído. Marque outro perfil como padrão antes.';
  end if;
  select count(*) into v_qtd from colaboradores where perfil_evento_id = p_id;
  if v_qtd > 0 then
    raise exception 'Este perfil está vinculado a % colaborador(es). Mude o perfil deles ou desative-o em vez de excluir.', v_qtd;
  end if;
  delete from perfis_eventos where id = p_id;
  perform fn_eventos_he_sincronizar();
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
revoke execute on function fn_txt(jsonb, text) from public, anon, authenticated;

grant execute on function api_cadastros_auxiliares(text)         to anon, authenticated;
grant execute on function api_departamento_criar(text, text)     to anon, authenticated;
grant execute on function api_cargo_criar(text, text)            to anon, authenticated;
grant execute on function api_colaboradores_listar(text)         to anon, authenticated;
grant execute on function api_colaborador_obter(text, uuid)      to anon, authenticated;
grant execute on function api_colaborador_salvar(text, jsonb)    to anon, authenticated;
grant execute on function api_colaborador_acesso_salvar(text, uuid, text, text, boolean) to anon, authenticated;
grant execute on function api_jornadas_listar(text)              to anon, authenticated;
grant execute on function api_jornada_salvar(text, jsonb)        to anon, authenticated;
grant execute on function api_jornada_excluir(text, uuid)        to anon, authenticated;
grant execute on function api_perfis_eventos_listar(text)        to anon, authenticated;
grant execute on function api_perfil_evento_salvar(text, jsonb)  to anon, authenticated;
grant execute on function api_perfil_evento_excluir(text, uuid)  to anon, authenticated;

-- Atualiza o cache de funções da API do Supabase (PostgREST)
notify pgrst, 'reload schema';
