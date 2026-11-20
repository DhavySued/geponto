-- =============================================================================
-- GePonto: atualização 005
-- • Chave "Administrador: acesso a tudo" no cadastro do usuário
-- • Local de ponto próprio do colaborador (home office): empresa, próprio ou os dois
-- • Relatórios de Banco de Horas e de Escalas
-- • Log e auditoria (inclusões, alterações, exclusões e acessos)
-- • Login também pelo CPF do colaborador vinculado ao usuário
-- Requer: atualização 004. Pode ser executado mais de uma vez.
-- =============================================================================

-- Estrutura -------------------------------------------------------------------
alter table usuarios add column if not exists administrador boolean not null default false;

-- Local de ponto próprio do colaborador (ex.: home office). local_ponto_modo diz onde ele pode bater:
--   empresa → só no local da empresa · proprio → só no local dele · ambos → em qualquer um dos dois
alter table locais_ponto add column if not exists colaborador_id uuid references colaboradores(id) on delete cascade;
create unique index if not exists ux_locais_ponto_colaborador on locais_ponto (colaborador_id) where colaborador_id is not null;
alter table colaboradores add column if not exists local_ponto_modo text not null default 'empresa';
alter table colaboradores drop constraint if exists colaboradores_local_ponto_modo_check;
alter table colaboradores add constraint colaboradores_local_ponto_modo_check
  check (local_ponto_modo in ('empresa', 'proprio', 'ambos'));

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

create or replace function fn_usuario_admin(p_usuario uuid)
returns boolean language sql stable set search_path = public as $$
  select coalesce((select p.is_admin or u.administrador
                     from usuarios u join perfis p on p.id = u.perfil_id
                    where u.id = p_usuario), false);
$$;

-- O 4º parâmetro (novo administrador) mudou a assinatura
drop function if exists fn_exigir_admin_para(uuid, uuid, uuid);

-- Funções alteradas ou novas ---------------------------------------------------
-- [02_functions]
-- Empresas ativas a que o usuário tem acesso: todas para o administrador; para os demais,
-- as vinculadas no cadastro do usuário mais a empresa do colaborador dele.
create or replace function fn_empresas_do_usuario(p_usuario uuid)
returns setof uuid language sql stable set search_path = public as $$
  select e.id
    from empresas e
   where e.ativo
     and (fn_usuario_admin(p_usuario)
          or e.id in (select ue.empresa_id from usuario_empresas ue where ue.usuario_id = p_usuario)
          or e.id in (select c.empresa_id from usuarios u join colaboradores c on c.id = u.colaborador_id
                       where u.id = p_usuario));
$$;

-- [02_functions]
create or replace function fn_usuario_payload(p_usuario uuid)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', u.id,
    'nome', u.nome,
    'login', u.login,
    'colaborador_id', u.colaborador_id,
    'email', u.email,
    'trocar_senha', u.trocar_senha,
    'administrador', u.administrador,
    'perfil', jsonb_build_object('id', p.id, 'nome', p.nome, 'is_admin', p.is_admin or u.administrador,
                                 'abrangencia', case when p.is_admin or u.administrador then 'todos' else p.abrangencia end),
    -- Empresa da sessão e as empresas a que o usuário tem acesso
    'empresa', (select jsonb_build_object('id', e.id, 'nome', coalesce(e.nome_fantasia, e.razao_social),
                                          'razao_social', e.razao_social, 'cnpj', e.cnpj)
                  from empresas e where e.id = fn_empresa_atual()),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', coalesce(e.nome_fantasia, e.razao_social))
                                           order by coalesce(e.nome_fantasia, e.razao_social))
                            from empresas e where e.id in (select fn_empresas_do_usuario(u.id))), '[]'::jsonb),
    'permissoes', coalesce((
      select jsonb_object_agg(pg.chave, jsonb_build_object(
               'visualizar', p.is_admin or u.administrador or coalesce(pp.pode_visualizar, false),
               'editar',     p.is_admin or u.administrador or coalesce(pp.pode_editar, false)))
      from paginas pg
      left join perfil_permissoes pp on pp.pagina = pg.chave and pp.perfil_id = p.id
    ), '{}'::jsonb)
  )
  from usuarios u
  join perfis p on p.id = u.perfil_id
  where u.id = p_usuario;
$$;

-- [02_functions]
-- Valida o token, verifica a permissão da página e registra o usuário corrente
-- (app.usuario_id) para auditoria nos triggers. Retorna o id do usuário.
create or replace function fn_auth(p_token text, p_pagina text default null, p_editar boolean default false)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_usuario uuid;
  v_empresa uuid;
  v_admin   boolean;
  v_ok      boolean;
begin
  update sessoes s
     set ultimo_uso = now(),
         expira_em  = greatest(s.expira_em, now() + interval '12 hours')
    from usuarios u
   where s.token_hash = fn_hash_token(coalesce(p_token, ''))
     and s.expira_em > now()
     and u.id = s.usuario_id
     and u.status = 'ativo'
  returning s.usuario_id, s.empresa_id into v_usuario, v_empresa;

  if v_usuario is null then
    raise exception 'Sessão inválida ou expirada' using errcode = '28000';
  end if;

  if p_pagina is not null then
    v_admin := fn_usuario_admin(v_usuario);

    if not v_admin then
      select case when p_editar then pp.pode_editar else pp.pode_visualizar end into v_ok
        from usuarios u
        join perfil_permissoes pp on pp.perfil_id = u.perfil_id and pp.pagina = p_pagina
       where u.id = v_usuario;

      if not coalesce(v_ok, false) then
        raise exception 'Acesso negado à página %', p_pagina using errcode = '42501';
      end if;
    end if;
  end if;

  perform set_config('app.usuario_id', v_usuario::text, true);
  perform set_config('app.empresa_id', coalesce(v_empresa::text, ''), true);
  return v_usuario;
end $$;

-- [02_functions]
-- Colaborador visível para o usuário corrente (app.usuario_id, definido por fn_auth),
-- conforme a abrangência do perfil: todos, equipe (ele e subordinados diretos) ou próprio.
-- Com uma empresa na sessão, só os colaboradores dela (o próprio colaborador, sempre).
create or replace function fn_visivel(p_colaborador uuid)
returns boolean language sql stable set search_path = public as $$
  select coalesce((
    select case
             when p_colaborador = u.colaborador_id then true
             when fn_empresa_atual() is not null
                  and not exists (select 1 from colaboradores c
                                   where c.id = p_colaborador and c.empresa_id = fn_empresa_atual()) then false
             when p.is_admin or u.administrador or p.abrangencia = 'todos' then true
             when u.colaborador_id is null then false
             when p.abrangencia = 'equipe' then
               exists (select 1 from colaboradores c where c.id = p_colaborador and c.gestor_id = u.colaborador_id)
             else false end
      from usuarios u join perfis p on p.id = u.perfil_id
     where u.id = nullif(current_setting('app.usuario_id', true), '')::uuid), false);
$$;

-- [02_functions]
-- -----------------------------------------------------------------------------
-- API: autenticação
-- -----------------------------------------------------------------------------
-- Confere login e senha, com bloqueio temporário após 5 falhas. Retorna JSON em vez
-- de lançar exceção para que o contador de tentativas falhas seja persistido (uma
-- exceção desfaria o UPDATE). Usada pelo login e pelo registro rápido de ponto.
-- Entra com o login, o e-mail ou o CPF do colaborador vinculado ao usuário (com ou sem pontuação).
create or replace function fn_verificar_credenciais(p_login text, p_senha text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_user  usuarios%rowtype;
  c_erro  constant text := 'Usuário ou senha inválidos.';
  v_cpf   text := case when trim(coalesce(p_login, '')) ~ '^[0-9.\-\s]+$'
                       then nullif(regexp_replace(p_login, '\D', '', 'g'), '') end;
begin
  select * into v_user
    from usuarios
   where lower(login) = lower(trim(p_login))
      or lower(email) = lower(trim(p_login))
   limit 1;

  if not found and length(v_cpf) = 11 then
    select u.* into v_user
      from usuarios u join colaboradores c on c.id = u.colaborador_id
     where regexp_replace(c.cpf, '\D', '', 'g') = v_cpf
     limit 1;
  end if;

  if not found then
    perform extensions.crypt(coalesce(p_senha, ''), extensions.gen_salt('bf', 10)); -- tempo constante
    return jsonb_build_object('ok', false, 'erro', c_erro);
  end if;

  if v_user.bloqueado_ate is not null and v_user.bloqueado_ate > now() then
    return jsonb_build_object('ok', false,
      'erro', 'Acesso temporariamente bloqueado por excesso de tentativas. Tente novamente em alguns minutos.');
  end if;

  if v_user.senha_hash <> extensions.crypt(coalesce(p_senha, ''), v_user.senha_hash) then
    update usuarios
       set tentativas_falhas = case when bloqueado_ate is not null then 1 else tentativas_falhas + 1 end,
           bloqueado_ate = case when bloqueado_ate is null and tentativas_falhas + 1 >= 5
                                then now() + interval '15 minutes' end
     where id = v_user.id;
    return jsonb_build_object('ok', false, 'erro', c_erro);
  end if;

  if v_user.status <> 'ativo' then
    return jsonb_build_object('ok', false, 'erro', 'Usuário inativo ou bloqueado. Procure o administrador.');
  end if;

  update usuarios set tentativas_falhas = 0, bloqueado_ate = null where id = v_user.id;
  return jsonb_build_object('ok', true, 'usuario_id', v_user.id);
end $$;

-- [02_functions]
create or replace function api_login(p_login text, p_senha text, p_user_agent text default null, p_empresa uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_cred    jsonb;
  v_emp     jsonb;
  v_usuario uuid;
  v_token   text;
  v_exp     timestamptz := now() + interval '12 hours';
begin
  delete from sessoes where expira_em < now();

  v_cred := fn_verificar_credenciais(p_login, p_senha);
  if not (v_cred ->> 'ok')::boolean then
    insert into auditoria (usuario_id, usuario_nome, tabela, acao, descricao, depois)
    select u.id, u.nome, 'acesso', 'login_falha',
           case when trim(coalesce(p_login, '')) ~ '^[0-9.\-\s]+$' and length(regexp_replace(p_login, '\D', '', 'g')) = 11
                then 'CPF ' || left(regexp_replace(p_login, '\D', '', 'g'), 3) || '.***.***-' || right(regexp_replace(p_login, '\D', '', 'g'), 2)
                else left(lower(trim(coalesce(p_login, ''))), 120) end,
           jsonb_build_object('motivo', v_cred ->> 'erro', 'navegador', left(p_user_agent, 300))
      from (select 1) x left join usuarios u on lower(u.login) = lower(trim(coalesce(p_login, '')));
    return v_cred;
  end if;
  v_usuario := (v_cred ->> 'usuario_id')::uuid;

  v_emp := fn_escolher_empresa(v_usuario, p_empresa);
  if not (v_emp ->> 'ok')::boolean then
    return v_emp;
  end if;

  update usuarios set ultimo_acesso = now() where id = v_usuario;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into sessoes (usuario_id, token_hash, expira_em, user_agent, empresa_id)
  values (v_usuario, fn_hash_token(v_token), v_exp, left(p_user_agent, 300), (v_emp ->> 'empresa_id')::uuid);
  perform set_config('app.empresa_id', v_emp ->> 'empresa_id', true);
  insert into auditoria (usuario_id, usuario_nome, empresa_id, tabela, acao, descricao, depois)
  select v_usuario, nome, (v_emp ->> 'empresa_id')::uuid, 'acesso', 'login', login,
         jsonb_build_object('navegador', left(p_user_agent, 300))
    from usuarios where id = v_usuario;

  return jsonb_build_object('ok', true, 'token', v_token, 'expira_em', v_exp,
                            'usuario', fn_usuario_payload(v_usuario));
end $$;

-- [05_api_cadastros]
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
              'situacoes', fn_situacoes_json(c.id, null),
              'local_ponto', (select jsonb_build_object('latitude', l.latitude, 'longitude', l.longitude, 'raio_m', l.raio_m,
                                                        'precisao_m', l.precisao_m, 'endereco', l.endereco)
                                from locais_ponto l where l.colaborador_id = c.id and l.ativo),
              'local_empresa', (select jsonb_build_object('nome', l.nome, 'raio_m', l.raio_m,
                                                          'ativo', coalesce((select usar_limitacoes_ponto from empresa where id = 1), false))
                                  from locais_ponto l where l.ativo and l.empresa_id = c.empresa_id),
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

-- [05_api_cadastros]
-- Onde o colaborador pode bater o ponto: local da empresa, local próprio (home office) ou os dois.
-- p_dados: { modo, latitude?, longitude?, raio_m?, precisao_m?, endereco? }
create or replace function api_colaborador_local_salvar(p_token text, p_colaborador uuid, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_modo text := coalesce(fn_txt(d, 'modo'), 'empresa');
  v_nome text;
  v_lat numeric := fn_txt(d, 'latitude')::numeric;
  v_lng numeric := fn_txt(d, 'longitude')::numeric;
begin
  perform fn_auth(p_token, 'colaboradores', true);
  select nome into v_nome from colaboradores where id = p_colaborador;
  if v_nome is null then raise exception 'Colaborador não encontrado.'; end if;
  if not fn_visivel(p_colaborador) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  if v_modo not in ('empresa', 'proprio', 'ambos') then raise exception 'Escolha onde o colaborador pode bater o ponto.'; end if;

  if v_modo = 'empresa' then
    -- O local próprio fica guardado (as batidas antigas apontam para ele), só deixa de valer
    update locais_ponto set ativo = false where colaborador_id = p_colaborador;
  else
    if v_lat is null or v_lng is null then
      raise exception 'Informe a localização do local próprio (capture no local, busque pelo endereço ou digite as coordenadas).';
    end if;
    insert into locais_ponto (colaborador_id, nome, endereco, latitude, longitude, raio_m, precisao_m, ativo)
    values (p_colaborador, 'Local próprio · ' || v_nome, fn_txt(d, 'endereco'), round(v_lat, 6), round(v_lng, 6),
            coalesce(fn_txt(d, 'raio_m')::int, 150), round(fn_txt(d, 'precisao_m')::numeric)::int, true)
    on conflict (colaborador_id) where colaborador_id is not null do update set
      nome = excluded.nome, endereco = excluded.endereco, latitude = excluded.latitude, longitude = excluded.longitude,
      raio_m = excluded.raio_m, precisao_m = excluded.precisao_m, ativo = true;
  end if;
  update colaboradores set local_ponto_modo = v_modo where id = p_colaborador;
  return jsonb_build_object('ok', true);
exception
  when check_violation or numeric_value_out_of_range then
    raise exception 'Confira a localização: latitude entre -90 e 90, longitude entre -180 e 180 e raio entre 10 m e 50 km.';
  when invalid_text_representation then
    raise exception 'Coordenadas inválidas. Use números com ponto, ex.: -3.731862.';
end $$;

-- [06_api_ponto]
create or replace function fn_registrar_batida(
  p_usuario uuid, p_origem origem_batida default 'web',
  p_latitude numeric default null, p_longitude numeric default null,
  p_precisao numeric default null, p_geo_erro text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := p_usuario;
  c         colaboradores%rowtype;
  v_motivo  text;
  v_bat     batidas%rowtype;
  v_seq     integer;
  v_tipo    text;
  v_lat     numeric := case when p_latitude between -90 and 90 and p_longitude between -180 and 180
                            then round(p_latitude, 6) end;
  v_lng     numeric := case when p_latitude between -90 and 90 and p_longitude between -180 and 180
                            then round(p_longitude, 6) end;
  v_local   uuid;
  v_raio    integer;
  v_dist    integer;
  v_status  text;
  v_cfg     empresa%rowtype;
begin
  select col.* into c
    from colaboradores col join usuarios u on u.colaborador_id = col.id
   where u.id = v_usuario
     for update of col;   -- serializa cliques simultâneos do mesmo colaborador
  if not found then
    raise exception 'Seu usuário não está vinculado a um colaborador.';
  end if;

  v_motivo := fn_motivo_bloqueio_ponto(c);
  if v_motivo is not null then
    raise exception '%', v_motivo;
  end if;

  if exists (select 1 from batidas
              where colaborador_id = c.id and status = 'valida'
                and data_hora > now() - interval '1 minute') then
    raise exception 'Você já registrou o ponto há menos de 1 minuto.';
  end if;

  -- Cerca virtual: os locais aceitos para o colaborador são o da empresa da sessão (ou da empresa
  -- dele, com as limitações ligadas) e/ou o local próprio dele (home office), conforme local_ponto_modo.
  -- Vale o local em que ele está (ou o mais perto, se estiver fora de todos).
  select * into v_cfg from empresa where id = 1;
  select l.id, l.raio_m, fn_distancia_m(v_lat, v_lng, l.latitude, l.longitude)
    into v_local, v_raio, v_dist
    from locais_ponto l
   where l.ativo
     and ((c.local_ponto_modo in ('empresa', 'ambos') and coalesce(v_cfg.usar_limitacoes_ponto, false)
           and l.empresa_id = coalesce(fn_empresa_atual(), c.empresa_id))
       or (c.local_ponto_modo in ('proprio', 'ambos') and l.colaborador_id = c.id))
   order by fn_distancia_m(v_lat, v_lng, l.latitude, l.longitude) - l.raio_m nulls last
   limit 1;
  if v_lat is null then
    v_status := 'sem_localizacao';
    v_dist := null;
  elsif v_local is null then
    v_status := 'registrada';
  else
    v_status := case when v_dist <= v_raio then 'dentro' else 'fora' end;
  end if;
  if v_local is not null and v_cfg.bloquear_fora_cerca then
    if v_status = 'sem_localizacao' then
      raise exception 'Não foi possível obter a sua localização (%). Esta empresa só aceita o registro de ponto no local de trabalho: permita o acesso à localização e tente de novo.',
        lower(coalesce(nullif(trim(p_geo_erro), ''), 'localização não informada'));
    elsif v_status = 'fora' then
      raise exception 'Você está a % do local de trabalho (limite de % m). Esta empresa só aceita o registro de ponto dentro da área permitida.',
        case when v_dist < 1000 then v_dist || ' m' else replace(round(v_dist / 1000.0, 1)::text, '.', ',') || ' km' end, v_raio;
    end if;
  end if;

  insert into batidas (colaborador_id, data_hora, origem, nsr, usuario_id,
                       latitude, longitude, precisao_m, geo_status, geo_erro, local_id, distancia_m)
  values (c.id, now(), p_origem, nextval('seq_nsr'), v_usuario,
          v_lat, v_lng, case when v_lat is not null then least(round(p_precisao), 1000000)::int end, v_status,
          case when v_lat is null then left(coalesce(nullif(trim(p_geo_erro), ''), 'Localização não informada'), 200) end,
          v_local, v_dist)
  returning * into v_bat;

  select count(*) into v_seq
    from batidas
   where colaborador_id = c.id and data_referencia = v_bat.data_referencia and status = 'valida';
  select fn_rotulo_batida(p.sentido, p.turno) into v_tipo
    from fn_batidas_periodo(v_bat.data_referencia, v_bat.data_referencia, c.id) p
   where p.id = v_bat.id;

  return jsonb_build_object(
    'ok', true,
    'data', v_bat.data_referencia,
    'hora', to_char(v_bat.data_hora at time zone fn_fuso(), 'HH24:MI:SS'),
    'nsr', v_bat.nsr,
    'sequencia', v_seq,
    'tipo', v_tipo,
    'colaborador', c.nome,
    'matricula', c.matricula,
    'situacao_dia', fn_situacao_dia_batida(c, v_bat.data_referencia)) || fn_batida_geo_json(v_bat.id);
end $$;

-- [07_api_tratamento]
-- Permissão sem lançar exceção (para APIs que aceitam mais de uma página)
create or replace function fn_pode(p_usuario uuid, p_pagina text, p_editar boolean default false)
returns boolean language sql stable set search_path = public as $$
  select coalesce((
    select p.is_admin or u.administrador or coalesce(case when p_editar then pp.pode_editar else pp.pode_visualizar end, false)
      from usuarios u
      join perfis p on p.id = u.perfil_id
      left join perfil_permissoes pp on pp.perfil_id = p.id and pp.pagina = p_pagina
     where u.id = p_usuario), false);
$$;

-- [08_api_fortes]
-- -----------------------------------------------------------------------------
-- Relatório de Banco de Horas: por colaborador, saldo anterior, créditos e débitos do período
-- (automáticos), ajustes manuais, conversões (pagamento/desconto) e saldo final
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_banco_horas(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_banco_horas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 366 then raise exception 'Selecione um período de até 1 ano.'; end if;
  perform fn_banco_horas_atualizar();
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'itens', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.nome)
        from (
          select c.id as colaborador_id, c.nome, c.matricula, d.nome as departamento, g.nome as cargo,
                 coalesce(sum(b.minutos) filter (where b.data < p_ini), 0)::int as saldo_anterior,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos > 0), 0)::int as creditos,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos < 0), 0)::int as debitos,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.origem = 'manual' and b.tipo::text <> 'conversao'), 0)::int as ajustes,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.tipo::text = 'conversao'), 0)::int as conversoes,
                 coalesce(sum(b.minutos) filter (where b.data <= p_fim), 0)::int as saldo_final,
                 count(*) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos > 0)::int as dias_credito,
                 count(*) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos < 0)::int as dias_debito
            from colaboradores c
            left join departamentos d on d.id = c.departamento_id
            left join cargos g        on g.id = c.cargo_id
            left join banco_horas b   on b.colaborador_id = c.id and b.data <= p_fim
           where fn_visivel(c.id)
             and fn_filtro_colaborador(c.id, null, p_colaboradores)
             and (p_departamento is null or c.departamento_id = p_departamento)
           group by c.id, c.nome, c.matricula, d.nome, g.nome
          having count(b.id) > 0
              or (c.controla_ponto and coalesce(c.data_desligamento, p_ini) >= p_ini)
        ) x), '[]'::jsonb));
end $$;

-- [08_api_fortes]
-- -----------------------------------------------------------------------------
-- Relatório de Escalas: cada dia com escala (trabalho ou folga) no período, com o nome da
-- escala, o horário, se era feriado e o que foi realizado (trabalhado, saldo e ocorrência)
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_escalas(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null,
  p_departamento uuid default null, p_tipo text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_escalas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 92 then raise exception 'Selecione um período de até 3 meses.'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', d.nome,
               'data', e.data, 'tipo', e.tipo, 'escala', l.nome,
               'entrada', to_char(e.entrada, 'HH24:MI'), 'saida_intervalo', to_char(e.saida_intervalo, 'HH24:MI'),
               'retorno_intervalo', to_char(e.retorno_intervalo, 'HH24:MI'), 'saida', to_char(e.saida, 'HH24:MI'),
               'feriado', f.descricao,
               'previsto_min', a.previsto_min, 'trabalhado_min', a.trabalhado_min, 'saldo_min', a.saldo_min,
               'qtd_batidas', a.qtd_batidas, 'falta', a.falta, 'he_percentual', a.he_percentual,
               'realizado', e.data < fn_hoje())
             order by c.nome, e.data)
        from escalas e
        join colaboradores c            on c.id = e.colaborador_id
        left join departamentos d       on d.id = c.departamento_id
        left join escala_lancamentos l  on l.id = e.lancamento_id
        left join feriados f            on f.data = e.data
        left join fn_apuracao(p_ini, p_fim) a on a.colaborador_id = e.colaborador_id and a.data = e.data
       where e.data between p_ini and p_fim
         and fn_visivel(c.id)
         and fn_filtro_colaborador(c.id, null, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)
         and (p_tipo is null or e.tipo = p_tipo)), '[]'::jsonb));
end $$;

-- [09_api_usuarios]
-- -----------------------------------------------------------------------------
-- Leitura
-- -----------------------------------------------------------------------------
create or replace function api_usuarios_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_usuario uuid := fn_auth(p_token, 'usuarios');
begin
  return jsonb_build_object(
    'pode_editar', fn_pode(v_usuario, 'usuarios', true),
    'eu', v_usuario,
    'usuarios', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', u.id, 'nome', u.nome, 'login', u.login, 'email', u.email, 'status', u.status,
               'perfil_id', u.perfil_id, 'perfil', p.nome, 'is_admin', p.is_admin or u.administrador, 'abrangencia', p.abrangencia,
               'administrador', u.administrador, 'perfil_admin', p.is_admin,
               'colaborador_id', u.colaborador_id, 'colaborador', c.nome, 'matricula', c.matricula,
               'empresas', coalesce((select jsonb_agg(ue.empresa_id) from usuario_empresas ue where ue.usuario_id = u.id), '[]'::jsonb),
               'empresa_colaborador', (select coalesce(e.nome_fantasia, e.razao_social) from empresas e where e.id = c.empresa_id),
               'ultimo_acesso', u.ultimo_acesso, 'trocar_senha', u.trocar_senha,
               'bloqueado', u.bloqueado_ate is not null and u.bloqueado_ate > now(),
               'sessoes', (select count(*) from sessoes s where s.usuario_id = u.id and s.expira_em > now()),
               'created_at', u.created_at)
             order by u.nome)
        from usuarios u
        join perfis p             on p.id = u.perfil_id
        left join colaboradores c on c.id = u.colaborador_id), '[]'::jsonb),
    'perfis', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'nome', p.nome, 'descricao', p.descricao, 'is_admin', p.is_admin,
               'abrangencia', p.abrangencia,
               'usuarios', (select count(*) from usuarios u where u.perfil_id = p.id),
               'permissoes', coalesce((
                 select jsonb_object_agg(pp.pagina, jsonb_build_object(
                          'visualizar', pp.pode_visualizar, 'editar', pp.pode_editar))
                   from perfil_permissoes pp where pp.perfil_id = p.id), '{}'::jsonb))
             order by p.is_admin desc, p.nome)
        from perfis p), '[]'::jsonb),
    'paginas', coalesce((select jsonb_agg(jsonb_build_object('chave', chave, 'nome', nome, 'grupo', grupo)
                                          order by ordem) from paginas), '[]'::jsonb),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', coalesce(e.nome_fantasia, e.razao_social),
                                                              'ativo', e.ativo)
                                           order by coalesce(e.nome_fantasia, e.razao_social))
                            from empresas e), '[]'::jsonb),
    'colaboradores', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'cpf', c.cpf, 'email', c.email,
               'situacao', c.situacao, 'departamento', d.nome,
               'usuario_id', (select u.id from usuarios u where u.colaborador_id = c.id limit 1))
             order by c.nome)
        from colaboradores c
        left join departamentos d on d.id = c.departamento_id
       where c.situacao <> 'desligado'), '[]'::jsonb));
end $$;

-- [09_api_usuarios]
-- -----------------------------------------------------------------------------
-- Usuários
-- -----------------------------------------------------------------------------
-- Garante que o sistema nunca fique sem um administrador ativo
create or replace function fn_exigir_admin_ativo()
returns void language plpgsql stable set search_path = public as $$
begin
  if not exists (select 1 from usuarios u join perfis p on p.id = u.perfil_id
                  where (p.is_admin or u.administrador) and u.status = 'ativo') then
    raise exception 'O sistema precisa ter ao menos um administrador ativo.';
  end if;
end $$;

-- [09_api_usuarios]
create or replace function fn_exigir_admin_para(p_eu uuid, p_alvo uuid, p_novo_perfil uuid default null,
                                                p_novo_admin boolean default false)
returns void language plpgsql stable set search_path = public as $$
begin
  if fn_usuario_admin(p_eu) then
    return;
  end if;
  if fn_usuario_admin(p_alvo) or coalesce(p_novo_admin, false)
     or exists (select 1 from perfis p where p.id = p_novo_perfil and p.is_admin) then
    raise exception 'Somente um administrador pode alterar acessos de administrador.' using errcode = '42501';
  end if;
end $$;

-- [09_api_usuarios]
-- p_dados: { id?, nome, login, email?, perfil_id, colaborador_id?, status, senha?, trocar_senha? }
create or replace function api_usuario_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_eu      uuid := fn_auth(p_token, 'usuarios', true);
  d         jsonb := p_dados;
  v_id      uuid := nullif(d ->> 'id', '')::uuid;
  v_old     usuarios%rowtype;
  v_perfil  perfis%rowtype;
  v_colab   uuid := nullif(d ->> 'colaborador_id', '')::uuid;
  v_senha   text := nullif(d ->> 'senha', '');
  v_status  status_usuario := coalesce(fn_txt(d, 'status'), 'ativo')::status_usuario;
  v_nome    text := fn_txt(d, 'nome');
  v_login   text := fn_txt(d, 'login');
  v_admin   boolean := coalesce((d ->> 'administrador')::boolean, false);
begin
  select * into v_perfil from perfis where id = nullif(d ->> 'perfil_id', '')::uuid;
  if not found then raise exception 'Selecione o perfil de acesso.'; end if;
  -- Sem o campo (telas antigas), mantém o que o usuário já tinha
  if not d ? 'administrador' and v_id is not null then
    select administrador into v_admin from usuarios where id = v_id;
  end if;
  perform fn_exigir_admin_para(v_eu, v_id, v_perfil.id, v_admin);
  if v_id = v_eu and v_admin is distinct from (select administrador from usuarios where id = v_id) then
    raise exception 'Você não pode alterar o próprio acesso de administrador.';
  end if;
  if v_colab is not null and v_nome is null then
    select nome into v_nome from colaboradores where id = v_colab;
  end if;
  if v_nome is null then raise exception 'Informe o nome do usuário.'; end if;
  if v_login is null then raise exception 'Informe o login.'; end if;
  if v_login ~ '\s' then raise exception 'O login não pode ter espaços.'; end if;
  if v_senha is not null and length(v_senha) < 6 then
    raise exception 'A senha deve ter ao menos 6 caracteres.';
  end if;
  if not v_perfil.is_admin and not v_admin and v_perfil.abrangencia <> 'todos' and v_colab is null then
    raise exception 'O perfil "%" mostra apenas os dados do próprio colaborador%. Vincule o usuário a um colaborador.',
      v_perfil.nome, case when v_perfil.abrangencia = 'equipe' then ' e da equipe dele' else '' end;
  end if;
  if v_colab is not null and exists (select 1 from usuarios where colaborador_id = v_colab
                                                              and id is distinct from v_id) then
    raise exception 'Este colaborador já tem um usuário de acesso.';
  end if;
  -- Empresas de acesso: obrigatórias para quem não é administrador nem tem colaborador vinculado
  if d ? 'empresas' and not v_perfil.is_admin and not v_admin and v_colab is null
     and jsonb_array_length(coalesce(d -> 'empresas', '[]'::jsonb)) = 0 then
    raise exception 'Selecione ao menos uma empresa que o usuário poderá acessar.';
  end if;

  if v_id is null then
    if v_senha is null then raise exception 'Defina a senha inicial do usuário.'; end if;
    insert into usuarios (nome, login, email, senha_hash, perfil_id, colaborador_id, status, trocar_senha, administrador)
    values (v_nome, v_login, fn_txt(d, 'email'), fn_hash_senha(v_senha), v_perfil.id, v_colab, v_status,
            coalesce((d ->> 'trocar_senha')::boolean, true), v_admin)
    returning id into v_id;
  else
    select * into v_old from usuarios where id = v_id for update;
    if not found then raise exception 'Usuário não encontrado.'; end if;
    if v_id = v_eu and (v_old.perfil_id <> v_perfil.id or v_status <> 'ativo' or v_old.administrador <> v_admin) then
      raise exception 'Você não pode alterar o próprio perfil, o próprio acesso de administrador nem inativar o próprio acesso.';
    end if;

    update usuarios set
      nome = v_nome,
      login = v_login,
      email = fn_txt(d, 'email'),
      perfil_id = v_perfil.id,
      administrador = v_admin,
      colaborador_id = v_colab,
      status = v_status,
      senha_hash = coalesce(fn_hash_senha(v_senha), senha_hash),
      trocar_senha = case when v_senha is not null then coalesce((d ->> 'trocar_senha')::boolean, true)
                          else trocar_senha end,
      tentativas_falhas = case when v_status = 'ativo' then 0 else tentativas_falhas end,
      bloqueado_ate = case when v_status = 'ativo' then null else bloqueado_ate end
    where id = v_id;

    -- Senha nova, inativação ou troca de perfil derrubam as sessões abertas (exceto a minha)
    if v_senha is not null or v_status <> 'ativo' or v_old.perfil_id <> v_perfil.id or v_old.administrador <> v_admin
       or v_old.colaborador_id is distinct from v_colab then
      delete from sessoes where usuario_id = v_id and (v_id <> v_eu or token_hash <> fn_hash_token(p_token));
    end if;
  end if;

  if d ? 'empresas' then
    delete from usuario_empresas ue
     where ue.usuario_id = v_id
       and ue.empresa_id not in (select (x #>> '{}')::uuid from jsonb_array_elements(d -> 'empresas') x);
    insert into usuario_empresas (usuario_id, empresa_id)
    select v_id, (x #>> '{}')::uuid from jsonb_array_elements(d -> 'empresas') x
    on conflict do nothing;
    -- Sessões abertas numa empresa que deixou de ter acesso são encerradas
    delete from sessoes s where s.usuario_id = v_id and s.empresa_id is not null
       and s.empresa_id not in (select fn_empresas_do_usuario(v_id));
  end if;

  perform fn_exigir_admin_ativo();
  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then
    raise exception 'O login "%" (ou o e-mail) já está em uso por outro usuário.', v_login;
  when invalid_text_representation then
    raise exception 'Situação do usuário inválida.';
end $$;

-- [09_api_usuarios]
-- -----------------------------------------------------------------------------
-- Log e auditoria: consulta (mais recentes primeiro). Da empresa da sessão, mais os registros
-- sem empresa (acessos e cadastros gerais).
-- -----------------------------------------------------------------------------
create or replace function api_auditoria_listar(
  p_token text, p_ini date, p_fim date, p_tabela text default null, p_acao text default null,
  p_usuario uuid default null, p_colaborador uuid default null, p_busca text default null, p_limite integer default 500)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_tz  text := fn_fuso();
  v_emp uuid;
  v_lim integer := least(greatest(coalesce(p_limite, 500), 1), 2000);
  v_busca text := nullif(lower(trim(coalesce(p_busca, ''))), '');
begin
  perform fn_auth(p_token, 'auditoria');
  v_emp := fn_empresa_atual();
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 366 then raise exception 'Selecione um período de até 1 ano.'; end if;
  return jsonb_build_object(
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'data_hora', a.data_hora, 'usuario_id', a.usuario_id,
               'usuario', coalesce(a.usuario_nome, case when a.acao = 'login_falha' then null else 'Sistema' end),
               'tabela', a.tabela, 'registro_id', a.registro_id, 'acao', a.acao,
               'colaborador_id', a.colaborador_id, 'colaborador', c.nome,
               'descricao', a.descricao, 'campos', a.campos, 'antes', a.antes, 'depois', a.depois)
             order by a.data_hora desc, a.id desc)
        from (select a.* from auditoria a
               where a.data_hora >= (p_ini::timestamp at time zone v_tz)
                 and a.data_hora <  ((p_fim + 1)::timestamp at time zone v_tz)
                 and (v_emp is null or a.empresa_id is null or a.empresa_id = v_emp)
                 and (p_tabela is null or a.tabela = p_tabela)
                 and (p_acao is null or a.acao = p_acao)
                 and (p_usuario is null or a.usuario_id = p_usuario)
                 and (p_colaborador is null or a.colaborador_id = p_colaborador)
                 and (v_busca is null or lower(coalesce(a.descricao, '') || ' ' || coalesce(a.usuario_nome, '') || ' '
                                                || coalesce(a.antes::text, '') || ' ' || coalesce(a.depois::text, '')) like '%' || v_busca || '%')
               order by a.data_hora desc, a.id desc
               limit v_lim) a
        left join colaboradores c on c.id = a.colaborador_id), '[]'::jsonb),
    'limite', v_lim,
    'usuarios', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome) from usuarios), '[]'::jsonb),
    'tabelas', coalesce((select jsonb_agg(distinct tabela) from auditoria), '[]'::jsonb));
end $$;

-- Auditoria: gatilhos nas tabelas ------------------------------------------------
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
drop trigger if exists trg_auditoria on chaves_api;
create trigger trg_auditoria after insert or update or delete on chaves_api for each row execute function fn_auditar();

-- Páginas novas ------------------------------------------------------------------
insert into paginas (chave, nome, grupo, ordem) values
  ('relatorio_banco_horas', 'Relatório de Banco de Horas', 'Relatórios', 87),
  ('relatorio_escalas',  'Relatório de Escalas',      'Relatórios', 88),
  ('auditoria',          'Log e Auditoria',           'Configurações', 96)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

-- Relatórios de Banco de Horas e de Escalas: quem vê o banco de horas / as escalas vê o relatório
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_banco_horas', pode_visualizar, false from perfil_permissoes where pagina = 'banco_horas'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_escalas', pode_visualizar, false from perfil_permissoes where pagina = 'escalas'
on conflict (perfil_id, pagina) do nothing;

-- Permissões de execução ---------------------------------------------------------
revoke execute on function fn_usuario_admin(uuid) from public, anon, authenticated;
grant execute on function api_colaborador_local_salvar(text, uuid, jsonb)  to anon, authenticated;
grant execute on function api_relatorio_banco_horas(text, date, date, uuid[], uuid)     to anon, authenticated;
grant execute on function api_relatorio_escalas(text, date, date, uuid[], uuid, text)    to anon, authenticated;
revoke execute on function fn_exigir_admin_para(uuid, uuid, uuid, boolean) from public, anon, authenticated;
grant execute on function api_auditoria_listar(text, date, date, text, text, uuid, uuid, text, integer) to anon, authenticated;

notify pgrst, 'reload schema';
