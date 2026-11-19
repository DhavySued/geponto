-- =============================================================================
-- GePonto — ERP de Controle de Ponto
-- 11_api_locais_batidas.sql — Endereço da localização das batidas e relatório de locais
-- Rodar depois do 10_api_justificativas.sql. Pode ser executado mais de uma vez.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Endereços das coordenadas (rua, número, bairro, cidade e UF). O navegador descobre o endereço
-- (OpenStreetMap) uma vez e guarda aqui; as coordenadas são arredondadas em 4 casas (~11 m),
-- então batidas no mesmo lugar reaproveitam o endereço.
-- -----------------------------------------------------------------------------
create table if not exists enderecos_geo (
  lat         numeric(8,4) not null,
  lng         numeric(8,4) not null,
  rua         text,
  numero      text,
  bairro      text,
  cidade      text,
  uf          text,
  cep         text,
  created_at  timestamptz not null default now(),
  primary key (lat, lng)
);
alter table enderecos_geo enable row level security;

create or replace function fn_endereco_json(p_lat numeric, p_lng numeric)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object('rua', e.rua, 'numero', e.numero, 'bairro', e.bairro,
                            'cidade', e.cidade, 'uf', e.uf, 'cep', e.cep)
    from enderecos_geo e
   where e.lat = round(p_lat, 4) and e.lng = round(p_lng, 4);
$$;

-- Endereços já conhecidos de uma lista de coordenadas: p_coords = [[lat, lng], ...]
create or replace function api_enderecos_geo(p_token text, p_coords jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token);
  return coalesce((
    -- Devolve as coordenadas como vieram, para o navegador achar cada uma no seu cache
    select jsonb_agg(jsonb_build_object('lat', x.lat, 'lng', x.lng, 'rua', e.rua, 'numero', e.numero,
                                        'bairro', e.bairro, 'cidade', e.cidade, 'uf', e.uf, 'cep', e.cep))
      from (select (c ->> 0)::float8 as lat, (c ->> 1)::float8 as lng
              from jsonb_array_elements(coalesce(p_coords, '[]'::jsonb)) c
             limit 500) x
      join enderecos_geo e on e.lat = round(x.lat::numeric, 4) and e.lng = round(x.lng::numeric, 4)), '[]'::jsonb);
end $$;

-- Guarda o endereço encontrado para a coordenada
create or replace function api_endereco_geo_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_lat numeric := round(fn_txt(p_dados, 'lat')::numeric, 4);
  v_lng numeric := round(fn_txt(p_dados, 'lng')::numeric, 4);
begin
  perform fn_auth(p_token);
  if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'Coordenadas inválidas.';
  end if;
  insert into enderecos_geo (lat, lng, rua, numero, bairro, cidade, uf, cep)
  values (v_lat, v_lng, left(fn_txt(p_dados, 'rua'), 200), left(fn_txt(p_dados, 'numero'), 20),
          left(fn_txt(p_dados, 'bairro'), 120), left(fn_txt(p_dados, 'cidade'), 120),
          left(fn_txt(p_dados, 'uf'), 40), left(fn_txt(p_dados, 'cep'), 12))
  on conflict (lat, lng) do update
    set rua = excluded.rua, numero = excluded.numero, bairro = excluded.bairro,
        cidade = excluded.cidade, uf = excluded.uf, cep = excluded.cep;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Relatório: locais das batidas (registradas pelo sistema, com ou sem localização)
--   p_local: local de ponto mais próximo · p_situacao: dentro, fora, registrada, sem_localizacao
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_locais_batidas(
  p_token text, p_ini date, p_fim date, p_local uuid default null, p_situacao text default null,
  p_colaborador uuid default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'locais_batidas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 92 then raise exception 'Selecione um período de até 3 meses.'; end if;

  return jsonb_build_object(
    'itens', coalesce((
      select jsonb_agg(x order by x.data_hora desc)
        from (
          select b.id, b.data_hora, b.data_referencia as data,
                 to_char(b.data_hora at time zone fn_fuso(), 'HH24:MI') as hora,
                 b.origem, b.geo_status, b.geo_erro,
                 b.latitude::float8 as latitude, b.longitude::float8 as longitude,
                 b.precisao_m, b.distancia_m, l.nome as local,
                 c.id as colaborador_id, c.nome, c.matricula, d.nome as departamento,
                 case when b.latitude is not null then fn_endereco_json(b.latitude, b.longitude) end as endereco
            from batidas b
            join colaboradores c      on c.id = b.colaborador_id
            left join departamentos d on d.id = c.departamento_id
            left join locais_ponto l  on l.id = b.local_id
           where b.data_referencia between p_ini and p_fim
             and b.status = 'valida'
             and b.geo_status is not null
             and (p_local is null or b.local_id = p_local)
             and (p_situacao is null or b.geo_status = p_situacao)
             and (p_colaborador is null or c.id = p_colaborador)
             and (p_departamento is null or c.departamento_id = p_departamento)
             and fn_visivel(c.id)
           limit 5000
        ) x), '[]'::jsonb));
end $$;

grant execute on function api_enderecos_geo(text, jsonb)                                         to anon, authenticated;
grant execute on function api_endereco_geo_salvar(text, jsonb)                                   to anon, authenticated;
grant execute on function api_relatorio_locais_batidas(text, date, date, uuid, text, uuid, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
