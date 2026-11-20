-- =============================================================================
-- GePonto — 09_api_usuarios.sql
--   • Usuários & Permissões: usuários, perfis, matriz de permissões por página e
--     abrangência dos dados (todos / equipe / somente o próprio colaborador)
--   • Geração de acessos em lote para os colaboradores (senha inicial + troca obrigatória)
--   • Dashboard pessoal do colaborador
--   • Registro rápido de ponto na tela de login (login + senha, sem abrir sessão)
-- Execute depois de 08_api_fortes.sql. Pode ser reexecutado.
-- =============================================================================

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

-- Só um administrador mexe em quem é (ou passaria a ser) administrador. Sem esta regra, quem tem
-- apenas "editar usuários" poderia redefinir a senha do administrador ou criar outro para si.
drop function if exists fn_exigir_admin_para(uuid, uuid, uuid);
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

create or replace function api_usuario_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_eu uuid := fn_auth(p_token, 'usuarios', true);
begin
  if p_id = v_eu then raise exception 'Você não pode excluir o próprio usuário.'; end if;
  perform fn_exigir_admin_para(v_eu, p_id);
  delete from usuarios where id = p_id;
  if not found then raise exception 'Usuário não encontrado.'; end if;
  perform fn_exigir_admin_ativo();
  return jsonb_build_object('ok', true);
end $$;

-- Encerra todas as sessões abertas do usuário (ex.: celular perdido)
create or replace function api_usuario_desconectar(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_eu uuid := fn_auth(p_token, 'usuarios', true);
begin
  perform fn_exigir_admin_para(v_eu, p_id);
  delete from sessoes where usuario_id = p_id and (p_id <> v_eu or token_hash <> fn_hash_token(p_token));
  return jsonb_build_object('ok', true);
end $$;

-- Cria acessos para colaboradores que ainda não têm usuário.
-- Login = matrícula (ou CPF, conforme p_login); senha inicial comum, com troca obrigatória.
create or replace function api_acessos_gerar(
  p_token text, p_colaboradores uuid[], p_senha text, p_perfil uuid default null, p_login text default 'matricula')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_perfil  uuid;
  c         colaboradores%rowtype;
  v_login   text;
  v_criados jsonb := '[]'::jsonb;
  v_ignorados jsonb := '[]'::jsonb;
begin
  perform fn_auth(p_token, 'usuarios', true);
  if length(coalesce(p_senha, '')) < 6 then raise exception 'A senha inicial deve ter ao menos 6 caracteres.'; end if;
  if coalesce(array_length(p_colaboradores, 1), 0) = 0 then raise exception 'Selecione ao menos um colaborador.'; end if;
  v_perfil := coalesce(p_perfil, (select id from perfis where nome = 'Colaborador'));
  if not exists (select 1 from perfis where id = v_perfil and not is_admin) then
    raise exception 'Selecione um perfil válido (o perfil Administrador não pode ser atribuído em lote).';
  end if;

  for c in select * from colaboradores where id = any (p_colaboradores) order by nome loop
    v_login := case when p_login = 'cpf' then regexp_replace(c.cpf, '\D', '', 'g') else trim(c.matricula) end;
    if exists (select 1 from usuarios where colaborador_id = c.id) then
      v_ignorados := v_ignorados || jsonb_build_object('nome', c.nome, 'motivo', 'já tem acesso');
    elsif c.situacao = 'desligado' then
      v_ignorados := v_ignorados || jsonb_build_object('nome', c.nome, 'motivo', 'desligado');
    elsif exists (select 1 from usuarios where lower(login) = lower(v_login)) then
      v_ignorados := v_ignorados || jsonb_build_object('nome', c.nome, 'motivo', 'login "' || v_login || '" já usado');
    else
      insert into usuarios (nome, login, email, senha_hash, perfil_id, colaborador_id, status, trocar_senha)
      values (c.nome, v_login,
              case when c.email is not null and not exists (select 1 from usuarios where lower(email) = lower(c.email))
                   then c.email end,
              fn_hash_senha(p_senha), v_perfil, c.id, 'ativo', true);
      v_criados := v_criados || jsonb_build_object('nome', c.nome, 'login', v_login);
    end if;
  end loop;

  return jsonb_build_object('criados', v_criados, 'ignorados', v_ignorados);
end $$;

-- -----------------------------------------------------------------------------
-- Perfis e permissões
-- p_dados: { id?, nome, descricao?, abrangencia, permissoes: { pagina: { visualizar, editar } } }
-- -----------------------------------------------------------------------------
create or replace function api_perfil_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_eu     uuid := fn_auth(p_token, 'usuarios', true);
  d        jsonb := p_dados;
  v_id     uuid := nullif(d ->> 'id', '')::uuid;
  v_admin  boolean := false;
  v_abr    text := coalesce(fn_txt(d, 'abrangencia'), 'todos');
begin
  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome do perfil.'; end if;
  if v_abr not in ('todos', 'equipe', 'proprio') then raise exception 'Abrangência inválida.'; end if;

  if v_id is null then
    insert into perfis (nome, descricao, abrangencia)
    values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'), v_abr)
    returning id into v_id;
  else
    select is_admin into v_admin from perfis where id = v_id;
    if not found then raise exception 'Perfil não encontrado.'; end if;
    if v_admin then
      perform fn_exigir_admin_para(v_eu, null, v_id);
    end if;
    -- Quem altera as próprias permissões poderia se trancar fora desta tela
    if not v_admin and exists (select 1 from usuarios where id = v_eu and perfil_id = v_id)
       and not coalesce((d -> 'permissoes' -> 'usuarios' ->> 'editar')::boolean, false) then
      raise exception 'Você não pode retirar do seu próprio perfil a permissão de editar Usuários & Permissões.';
    end if;
    update perfis set nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'),
                      abrangencia = case when is_admin then 'todos' else v_abr end
     where id = v_id;
  end if;

  -- O Administrador tem acesso total; a matriz dele não é gravada
  if not v_admin then
    delete from perfil_permissoes where perfil_id = v_id;
    insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
    select v_id, pg.chave,
           coalesce((x.value ->> 'visualizar')::boolean, false) or coalesce((x.value ->> 'editar')::boolean, false),
           coalesce((x.value ->> 'editar')::boolean, false)
      from jsonb_each(case when jsonb_typeof(d -> 'permissoes') = 'object' then d -> 'permissoes' else '{}'::jsonb end) x
      join paginas pg on pg.chave = x.key
     where coalesce((x.value ->> 'visualizar')::boolean, false) or coalesce((x.value ->> 'editar')::boolean, false);

    -- Perfis restritos sem colaborador vinculado não enxergariam nada
    if v_abr <> 'todos' and exists (select 1 from usuarios where perfil_id = v_id and colaborador_id is null) then
      raise exception 'Há usuários neste perfil sem colaborador vinculado. Vincule-os antes de restringir a abrangência.';
    end if;
  end if;

  -- Usuários do perfil recarregam as permissões no próximo acesso
  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then raise exception 'Já existe um perfil com o nome "%".', fn_txt(d, 'nome');
end $$;

create or replace function api_perfil_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'usuarios', true);
  if exists (select 1 from perfis where id = p_id and is_admin) then
    raise exception 'O perfil Administrador não pode ser excluído.';
  end if;
  if exists (select 1 from usuarios where perfil_id = p_id) then
    raise exception 'Há usuários neste perfil. Mova-os para outro perfil antes de excluir.';
  end if;
  delete from perfis where id = p_id;
  if not found then raise exception 'Perfil não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Dashboard pessoal (perfis com abrangência "somente o próprio")
-- -----------------------------------------------------------------------------
create or replace function api_meu_dashboard(p_token text, p_ini date default null, p_fim date default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'dashboard');
  v_hoje    date := fn_hoje();
  v_ini     date := coalesce(p_ini, date_trunc('month', fn_hoje())::date);
  v_fim     date := least(coalesce(p_fim, fn_hoje()), fn_hoje());
  c         colaboradores%rowtype;
begin
  select col.* into c from colaboradores col join usuarios u on u.colaborador_id = col.id where u.id = v_usuario;
  if not found then
    return jsonb_build_object('vinculado', false);
  end if;
  if v_ini > v_fim then v_ini := v_fim; end if;
  if v_fim - v_ini > 92 then raise exception 'Selecione um período de até 3 meses.'; end if;
  perform fn_banco_horas_atualizar();

  drop table if exists pg_temp._meu;
  create temp table _meu on commit drop as
    select * from fn_apuracao(v_ini, v_fim, c.id);

  return jsonb_build_object(
    'vinculado', true,
    'periodo', jsonb_build_object('inicio', v_ini, 'fim', v_fim, 'hoje', v_hoje),
    'colaborador', jsonb_build_object(
      'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'situacao', c.situacao,
      'cargo', (select nome from cargos where id = c.cargo_id),
      'departamento', (select nome from departamentos where id = c.departamento_id),
      'jornada', (select nome from jornadas where id = fn_jornada_vigente(c.id, v_hoje)),
      'horario_hoje', fn_horario_dia(c.id, v_hoje)),
    'resumo', (
      select jsonb_build_object(
        'dias_previstos',   count(*) filter (where previsto_min > 0 and data < v_hoje),
        'dias_trabalhados', count(*) filter (where qtd_batidas > 0),
        'previsto_min',     coalesce(sum(previsto_min) filter (where data < v_hoje), 0),
        'trabalhado_min',   coalesce(sum(trabalhado_min), 0),
        'extra_min',        coalesce(sum(extra_min) filter (where data < v_hoje), 0),
        'debito_min',       coalesce(sum(debito_min) filter (where data < v_hoje), 0),
        'faltas',           count(*) filter (where falta),
        'atrasos',          count(*) filter (where atraso_min > 0),
        'minutos_atraso',   coalesce(sum(atraso_min), 0),
        'noturno_min',      coalesce(sum(noturno_min), 0),
        'inconsistencias',  count(*) filter (where impar and data < v_hoje))
      from pg_temp._meu),
    'banco_horas', (
      select jsonb_build_object(
        'saldo',    coalesce(sum(minutos), 0),
        'anterior', coalesce(sum(minutos) filter (where data < v_ini), 0),
        'periodo',  coalesce(sum(minutos) filter (where data between v_ini and v_fim), 0))
      from banco_horas where colaborador_id = c.id),
    'hoje', jsonb_build_object(
      'batidas', fn_batidas_json(c.id, v_hoje),
      'previsto_min', coalesce((select previsto_min from pg_temp._meu where data = v_hoje), 0),
      'trabalhado_min', fn_trabalhado_ao_vivo(c.id, v_hoje, (select trabalhado_min from pg_temp._meu where data = v_hoje))),
    'dias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'data', a.data, 'previsto_min', a.previsto_min, 'trabalhado_min', a.trabalhado_min,
               'saldo_min', a.saldo_min, 'atraso_min', a.atraso_min, 'falta', a.falta,
               'ocorrencia', a.ocorrencia, 'impar', a.impar, 'feriado', a.feriado,
               'batidas', fn_batidas_json(c.id, a.data)) order by a.data desc)
        from pg_temp._meu a), '[]'::jsonb),
    'solicitacoes_pendentes', (select count(*) from solicitacoes where colaborador_id = c.id and status = 'pendente'),
    'pode_registrar', fn_pode(v_usuario, 'meu_ponto', true) and fn_motivo_bloqueio_ponto(c) is null
  );
end $$;

-- -----------------------------------------------------------------------------
-- Registro rápido de ponto (tela de login / quiosque): confere login e senha e
-- registra a batida do próprio colaborador, sem abrir sessão no sistema.
-- -----------------------------------------------------------------------------
drop function if exists api_registrar_ponto_rapido(text, text, text);
drop function if exists api_registrar_ponto_rapido(text, text, text, numeric, numeric, numeric, text);
create or replace function api_registrar_ponto_rapido(
  p_login text, p_senha text, p_user_agent text default null,
  p_latitude numeric default null, p_longitude numeric default null,
  p_precisao numeric default null, p_geo_erro text default null, p_empresa uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_cred    jsonb;
  v_emp     jsonb;
  v_usuario uuid;
begin
  v_cred := fn_verificar_credenciais(p_login, p_senha);
  if not (v_cred ->> 'ok')::boolean then
    return v_cred;
  end if;
  v_usuario := (v_cred ->> 'usuario_id')::uuid;

  if not fn_pode(v_usuario, 'meu_ponto', true) then
    return jsonb_build_object('ok', false, 'erro', 'Seu perfil não tem permissão para registrar ponto.');
  end if;
  if not exists (select 1 from usuarios where id = v_usuario and colaborador_id is not null) then
    return jsonb_build_object('ok', false, 'erro', 'Seu usuário não está vinculado a um colaborador.');
  end if;

  -- Empresa onde o ponto é batido (a cerca virtual é a dela)
  v_emp := fn_escolher_empresa(v_usuario, p_empresa);
  if not (v_emp ->> 'ok')::boolean then
    return v_emp;
  end if;

  perform set_config('app.usuario_id', v_usuario::text, true);   -- auditoria
  perform set_config('app.empresa_id', v_emp ->> 'empresa_id', true);
  begin
    return fn_registrar_batida(v_usuario, 'web', p_latitude, p_longitude, p_precisao, p_geo_erro)
           || jsonb_build_object('ok', true);
  exception when raise_exception then
    return jsonb_build_object('ok', false, 'erro', sqlerrm);
  end;
end $$;

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
revoke execute on function fn_exigir_admin_ativo()                      from public, anon, authenticated;
revoke execute on function fn_exigir_admin_para(uuid, uuid, uuid, boolean) from public, anon, authenticated;
revoke execute on function fn_usuario_admin(uuid)                       from public, anon, authenticated;
revoke execute on function fn_visivel(uuid)                             from public, anon, authenticated;
revoke execute on function fn_verificar_credenciais(text, text)         from public, anon, authenticated;

grant execute on function api_usuarios_listar(text)                     to anon, authenticated;
grant execute on function api_usuario_salvar(text, jsonb)               to anon, authenticated;
grant execute on function api_usuario_excluir(text, uuid)               to anon, authenticated;
grant execute on function api_usuario_desconectar(text, uuid)           to anon, authenticated;
grant execute on function api_acessos_gerar(text, uuid[], text, uuid, text) to anon, authenticated;
grant execute on function api_perfil_salvar(text, jsonb)                to anon, authenticated;
grant execute on function api_perfil_excluir(text, uuid)                to anon, authenticated;
grant execute on function api_meu_dashboard(text, date, date)           to anon, authenticated;
grant execute on function api_registrar_ponto_rapido(text, text, text, numeric, numeric, numeric, text, uuid) to anon, authenticated;

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

grant execute on function api_auditoria_listar(text, date, date, text, text, uuid, uuid, text, integer) to anon, authenticated;

-- Atualiza o cache de funções da API do Supabase (PostgREST)
notify pgrst, 'reload schema';
