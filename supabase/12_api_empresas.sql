-- =============================================================================
-- GePonto — ERP de Controle de Ponto
-- 12_api_empresas.sql — Cadastro de empresas (com o local de ponto) e configurações
-- Rodar depois do 11_api_locais_batidas.sql. Pode ser executado mais de uma vez.
-- =============================================================================

-- O local de ponto agora pertence à empresa: o nome acompanha o da empresa (pode repetir)
alter table locais_ponto drop constraint if exists locais_ponto_nome_key;

-- O cadastro de locais de ponto foi para dentro do cadastro da empresa
drop function if exists api_locais_ponto_listar(text);
drop function if exists api_local_ponto_salvar(text, jsonb);
drop function if exists api_local_ponto_excluir(text, uuid);

-- -----------------------------------------------------------------------------
-- Empresas
-- -----------------------------------------------------------------------------
create or replace function api_empresas_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'empresas');
begin
  return jsonb_build_object(
    'pode_editar', fn_pode(v_usuario, 'empresas', true),
    'atual', fn_empresa_atual(),
    'usar_limitacoes_ponto', (select usar_limitacoes_ponto from empresa where id = 1),
    'empresas', coalesce((
      select jsonb_agg(to_jsonb(e) - 'created_at' - 'updated_at'
               || jsonb_build_object(
                    'colaboradores', (select count(*) from colaboradores c
                                       where c.empresa_id = e.id and c.situacao <> 'desligado'),
                    'local', (select jsonb_build_object('latitude', l.latitude::float8, 'longitude', l.longitude::float8,
                                                        'raio_m', l.raio_m, 'precisao_m', l.precisao_m)
                                from locais_ponto l where l.empresa_id = e.id and l.ativo),
                    'batidas_30d', (select count(*) from batidas b join locais_ponto l on l.id = b.local_id
                                     where l.empresa_id = e.id and b.data_referencia >= fn_hoje() - 30),
                    'fora_30d', (select count(*) from batidas b join locais_ponto l on l.id = b.local_id
                                  where l.empresa_id = e.id and b.geo_status = 'fora'
                                    and b.data_referencia >= fn_hoje() - 30))
             order by e.ativo desc, coalesce(e.nome_fantasia, e.razao_social))
        from empresas e
       where e.id in (select fn_empresas_do_usuario(v_usuario)) or not e.ativo), '[]'::jsonb));
end $$;

create or replace function api_empresa_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'empresas', true);
  d     jsonb := p_dados;
  v_id  uuid := nullif(d ->> 'id', '')::uuid;
  v_loc jsonb := case when jsonb_typeof(d -> 'local') = 'object' then d -> 'local' end;
  v_cnpj text := nullif(regexp_replace(coalesce(fn_txt(d, 'cnpj'), ''), '[^0-9]', '', 'g'), '');
  v_nome text;
begin
  if fn_txt(d, 'razao_social') is null then raise exception 'Informe a razão social.'; end if;
  if v_cnpj is not null and length(v_cnpj) <> 14 then raise exception 'O CNPJ deve ter 14 dígitos.'; end if;
  if v_id is not null and not coalesce((d ->> 'ativo')::boolean, true) then
    if v_id = fn_empresa_atual() then
      raise exception 'Você está conectado nesta empresa. Troque de empresa no topo da tela antes de inativá-la.';
    end if;
    if not exists (select 1 from empresas where ativo and id <> v_id) then
      raise exception 'É preciso ter ao menos uma empresa ativa.';
    end if;
  end if;

  if v_id is null then
    insert into empresas (razao_social, nome_fantasia, cnpj, inscricao_estadual, telefone, email,
                          cep, logradouro, numero, complemento, bairro, cidade, uf, ativo)
    values (fn_txt(d, 'razao_social'), fn_txt(d, 'nome_fantasia'), v_cnpj, fn_txt(d, 'inscricao_estadual'),
            fn_txt(d, 'telefone'), lower(fn_txt(d, 'email')),
            fn_txt(d, 'cep'), fn_txt(d, 'logradouro'), fn_txt(d, 'numero'), fn_txt(d, 'complemento'),
            fn_txt(d, 'bairro'), fn_txt(d, 'cidade'), upper(fn_txt(d, 'uf')), coalesce((d ->> 'ativo')::boolean, true))
    returning id into v_id;
    -- Quem cadastrou já tem acesso à empresa nova
    insert into usuario_empresas (usuario_id, empresa_id) values (v_usuario, v_id) on conflict do nothing;
  else
    update empresas set
      razao_social = fn_txt(d, 'razao_social'), nome_fantasia = fn_txt(d, 'nome_fantasia'), cnpj = v_cnpj,
      inscricao_estadual = fn_txt(d, 'inscricao_estadual'), telefone = fn_txt(d, 'telefone'),
      email = lower(fn_txt(d, 'email')), cep = fn_txt(d, 'cep'), logradouro = fn_txt(d, 'logradouro'),
      numero = fn_txt(d, 'numero'), complemento = fn_txt(d, 'complemento'), bairro = fn_txt(d, 'bairro'),
      cidade = fn_txt(d, 'cidade'), uf = upper(fn_txt(d, 'uf')), ativo = coalesce((d ->> 'ativo')::boolean, true)
     where id = v_id;
    if not found then raise exception 'Empresa não encontrada.'; end if;
  end if;

  -- Local de ponto da empresa (cerca virtual). Batidas já registradas mantêm a situação do momento.
  v_nome := coalesce(fn_txt(d, 'nome_fantasia'), fn_txt(d, 'razao_social'));
  if v_loc is null then
    update locais_ponto set ativo = false, nome = v_nome where empresa_id = v_id;
  else
    if fn_txt(v_loc, 'latitude') is null or fn_txt(v_loc, 'longitude') is null then
      raise exception 'Localização da empresa inválida. Busque pelo endereço ou capture estando no local.';
    end if;
    update locais_ponto set
      nome = v_nome,
      endereco = nullif(concat_ws(', ', fn_txt(d, 'logradouro'), fn_txt(d, 'numero'), fn_txt(d, 'bairro'),
                                  fn_txt(d, 'cidade')), ''),
      latitude = fn_txt(v_loc, 'latitude')::numeric, longitude = fn_txt(v_loc, 'longitude')::numeric,
      raio_m = coalesce(fn_txt(v_loc, 'raio_m')::int, 150),
      precisao_m = round(fn_txt(v_loc, 'precisao_m')::numeric)::int, ativo = true
     where empresa_id = v_id;
    if not found then
      insert into locais_ponto (empresa_id, nome, endereco, latitude, longitude, raio_m, precisao_m, ativo)
      values (v_id, v_nome,
              nullif(concat_ws(', ', fn_txt(d, 'logradouro'), fn_txt(d, 'numero'), fn_txt(d, 'bairro'), fn_txt(d, 'cidade')), ''),
              fn_txt(v_loc, 'latitude')::numeric, fn_txt(v_loc, 'longitude')::numeric,
              coalesce(fn_txt(v_loc, 'raio_m')::int, 150), round(fn_txt(v_loc, 'precisao_m')::numeric)::int, true);
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
exception
  when unique_violation then
    raise exception 'Já existe uma empresa com este CNPJ.';
  when check_violation then
    raise exception 'Confira a localização: latitude entre -90 e 90, longitude entre -180 e 180 e raio entre 10 m e 50 km.';
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Localização inválida. Busque a localização novamente.';
end $$;

create or replace function api_empresa_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'empresas', true);
  if exists (select 1 from colaboradores where empresa_id = p_id) then
    raise exception 'Esta empresa tem colaboradores cadastrados. Inative-a em vez de excluir.';
  end if;
  if exists (select 1 from batidas b join locais_ponto l on l.id = b.local_id where l.empresa_id = p_id) then
    raise exception 'Esta empresa já tem batidas registradas no local dela. Inative-a em vez de excluir.';
  end if;
  if p_id = fn_empresa_atual() then
    raise exception 'Você está conectado nesta empresa. Troque de empresa no topo da tela antes de excluí-la.';
  end if;
  if not exists (select 1 from empresas where ativo and id <> p_id) then
    raise exception 'É preciso ter ao menos uma empresa ativa.';
  end if;
  delete from empresas where id = p_id;
  if not found then raise exception 'Empresa não encontrada.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Empresas para seletores (cadastro do colaborador): as que o usuário pode acessar
create or replace function api_empresas_opcoes(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token);
begin
  return jsonb_build_object(
    'atual', fn_empresa_atual(),
    'empresas', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'nome', coalesce(e.nome_fantasia, e.razao_social))
                                           order by coalesce(e.nome_fantasia, e.razao_social))
                            from empresas e where e.id in (select fn_empresas_do_usuario(v_usuario))), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- Configurações: registro de ponto (cerca virtual)
-- -----------------------------------------------------------------------------
create or replace function api_configuracoes(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'configuracoes');
begin
  return (select jsonb_build_object(
            'pode_editar', fn_pode(v_usuario, 'configuracoes', true),
            'usar_limitacoes_ponto', e.usar_limitacoes_ponto,
            'bloquear_fora_cerca', e.bloquear_fora_cerca,
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
  update empresa set
    usar_limitacoes_ponto = coalesce((p_dados ->> 'usar_limitacoes_ponto')::boolean, usar_limitacoes_ponto),
    bloquear_fora_cerca = coalesce((p_dados ->> 'bloquear_fora_cerca')::boolean, bloquear_fora_cerca)
   where id = 1;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function api_empresas_listar(text)               to anon, authenticated;
grant execute on function api_empresa_salvar(text, jsonb)         to anon, authenticated;
grant execute on function api_empresa_excluir(text, uuid)         to anon, authenticated;
grant execute on function api_empresas_opcoes(text)               to anon, authenticated;
grant execute on function api_configuracoes(text)                 to anon, authenticated;
grant execute on function api_configuracoes_salvar(text, jsonb)   to anon, authenticated;

notify pgrst, 'reload schema';
