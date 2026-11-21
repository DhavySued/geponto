-- =============================================================================
-- GePonto: atualização 006 — Usuário master e acesso pelo CPF
-- • Um único usuário master (o administrador inicial "geponto"; sem ele, o administrador
--   mais antigo): entra pelo login ou e-mail, sempre com acesso total, não pode ser
--   excluído nem inativado
-- • Todos os demais entram só pelo CPF do colaborador vinculado ao usuário
-- ATENÇÃO: usuários sem colaborador vinculado (exceto o master) deixam de conseguir entrar
-- até serem vinculados a um colaborador em Usuários & Permissões.
-- Requer: atualização 005. Pode ser executado mais de uma vez.
-- =============================================================================

-- Usuário master: um só no sistema, sempre com acesso total, o único que entra pelo login (ou e-mail).
-- Todos os demais entram pelo CPF do colaborador vinculado. Não pode ser excluído, inativado
-- nem perder o acesso total. É o administrador inicial (99_admin.local.sql).
alter table usuarios add column if not exists master boolean not null default false;
create unique index if not exists ux_usuarios_master on usuarios ((true)) where master;
alter table usuarios drop constraint if exists usuarios_master_admin_check;
update usuarios set administrador = true where master and not administrador;
alter table usuarios add constraint usuarios_master_admin_check check (not master or administrador);

create or replace function fn_usuario_master_proteger()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.master then raise exception 'O usuário master não pode ser excluído.'; end if;
    return old;
  end if;
  if old.master and (not new.master or new.status <> 'ativo' or not new.administrador) then
    raise exception 'O usuário master não pode ser inativado nem perder o acesso total.';
  end if;
  return new;
end $$;
drop trigger if exists trg_usuarios_master on usuarios;
create trigger trg_usuarios_master before update or delete on usuarios
  for each row execute function fn_usuario_master_proteger();

-- Bases já instaladas: o master é o administrador inicial ("geponto") ou, sem ele, o administrador mais antigo
update usuarios set master = true, administrador = true, status = 'ativo'
 where id = coalesce(
         (select id from usuarios where lower(login) = 'geponto'),
         (select u.id from usuarios u join perfis p on p.id = u.perfil_id
           where (p.is_admin or u.administrador) and u.status = 'ativo' order by u.created_at limit 1))
   and not exists (select 1 from usuarios where master);

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
    'master', u.master,
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
-- -----------------------------------------------------------------------------
-- API: autenticação
-- -----------------------------------------------------------------------------
-- Confere login e senha, com bloqueio temporário após 5 falhas. Retorna JSON em vez
-- de lançar exceção para que o contador de tentativas falhas seja persistido (uma
-- exceção desfaria o UPDATE). Usada pelo login e pelo registro rápido de ponto.
-- Todos entram pelo CPF do colaborador vinculado ao usuário (com ou sem pontuação). Só o usuário
-- master entra pelo login ou e-mail.
create or replace function fn_verificar_credenciais(p_login text, p_senha text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_user  usuarios%rowtype;
  c_erro  constant text := 'CPF ou senha inválidos.';
  v_cpf   text := case when trim(coalesce(p_login, '')) ~ '^[0-9.\-\s]+$'
                       then nullif(regexp_replace(p_login, '\D', '', 'g'), '') end;
begin
  if length(v_cpf) = 11 then
    select u.* into v_user
      from usuarios u join colaboradores c on c.id = u.colaborador_id
     where not u.master and regexp_replace(c.cpf, '\D', '', 'g') = v_cpf
     limit 1;
  else
    select * into v_user
      from usuarios
     where master
       and (lower(login) = lower(trim(p_login)) or lower(email) = lower(trim(p_login)))
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
               'administrador', u.administrador, 'perfil_admin', p.is_admin, 'master', u.master,
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
  v_master  boolean := coalesce((select master from usuarios where id = nullif(d ->> 'id', '')::uuid), false);
begin
  select * into v_perfil from perfis where id = nullif(d ->> 'perfil_id', '')::uuid;
  if not found then raise exception 'Selecione o perfil de acesso.'; end if;
  -- Sem o campo (telas antigas), mantém o que o usuário já tinha
  if not d ? 'administrador' and v_id is not null then
    select administrador into v_admin from usuarios where id = v_id;
  end if;
  if v_master then
    if v_id <> v_eu then raise exception 'Só o próprio usuário master altera o cadastro dele.'; end if;
    v_admin := true;
  elsif v_colab is null then
    raise exception 'Vincule o usuário a um colaborador: o acesso ao sistema é pelo CPF dele.';
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

notify pgrst, 'reload schema';
