-- =============================================================================
-- GePonto — 06_api_ponto.sql
-- Meu Ponto (registro pelo próprio colaborador), Acompanhamento de Batidas
-- e Banco de Horas. Execute depois de 05_api_cadastros.sql. Pode ser reexecutado.
-- =============================================================================

-- Motivo que impede o colaborador de registrar ponto (null = pode registrar).
-- Folga, feriado e falta de controle de ponto NÃO impedem: a batida é registrada e classificada
-- (fn_situacao_dia_batida) como "em dia de folga", "em feriado" ou "não controlada".
create or replace function fn_motivo_bloqueio_ponto(c colaboradores)
returns text language sql stable set search_path = public as $$
  select case
    when c.situacao = 'desligado'    then 'Colaborador desligado.'
    when c.situacao = 'ferias'       then 'Você está de férias. Bom descanso!'
    when c.situacao = 'afastado'     then 'Você está afastado. Fale com o RH se precisar registrar o ponto.'
  end;
$$;

-- Como fica a batida no dia: 'nao_controlada' (colaborador sem controle de ponto, ou antes do início
-- do controle — não entra na apuração), 'feriado', 'folga' ou null (dia normal de trabalho)
create or replace function fn_situacao_dia_batida(c colaboradores, p_data date)
returns text language sql stable set search_path = public as $$
  select case
    when not c.controla_ponto or fn_inicio_controle(c) > p_data then 'nao_controlada'
    when exists (select 1 from feriados f where f.data = p_data)
         and not exists (select 1 from escalas e where e.colaborador_id = c.id and e.data = p_data and e.tipo = 'trabalho')
      then 'feriado'
    when (select jd.folga from fn_jornada_dia(c.id, p_data) jd) then 'folga'
  end;
$$;

-- fn_batidas_periodo (sentido e turno efetivos de cada batida) fica em 02_functions.sql

-- "Entrada do 1º turno", "Saída do 2º turno"…
create or replace function fn_rotulo_batida(p_sentido text, p_turno integer)
returns text language sql immutable as $$
  select case when p_sentido = 'S' then 'Saída' else 'Entrada' end || ' do ' || coalesce(p_turno, 1) || 'º turno';
$$;

-- Geolocalização de uma batida, como JSON (vazio quando a batida não tem)
create or replace function fn_batida_geo_json(p_batida uuid)
returns jsonb language sql stable set search_path = public as $$
  select coalesce((
    select jsonb_build_object(
             'geo_status', b.geo_status,
             'geo_erro', b.geo_erro,
             'latitude', b.latitude::float8,
             'longitude', b.longitude::float8,
             'precisao_m', b.precisao_m,
             'distancia_m', b.distancia_m,
             'local', l.nome)
      from batidas b
      left join locais_ponto l on l.id = b.local_id
     where b.id = p_batida and b.geo_status is not null), '{}'::jsonb);
$$;

-- Batidas válidas de um colaborador em um dia, como JSON (com a classificação de cada uma)
create or replace function fn_batidas_json(p_colaborador uuid, p_data date)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', b.id,
           'hora', to_char(b.data_hora at time zone fn_fuso(), 'HH24:MI'),
           'origem', b.origem,
           'nsr', b.nsr,
           'sentido', b.sentido,
           'turno', b.turno) || fn_batida_geo_json(b.id) order by b.data_hora), '[]'::jsonb)
    from fn_batidas_periodo(p_data, p_data, p_colaborador) b
   where b.status = 'valida';
$$;

-- Minutos trabalhados no dia, contando o período em aberto (última batida = entrada) até agora
create or replace function fn_trabalhado_ao_vivo(p_colaborador uuid, p_data date, p_base integer)
returns integer language sql stable set search_path = public as $$
  with dia as (
    select b.data_hora, b.sentido as sent
      from fn_batidas_periodo(p_data, p_data, p_colaborador) b
     where b.status = 'valida'
  )
  select coalesce(p_base, 0) + coalesce((
    select case when p_data = fn_hoje() and u.sent = 'E'
                then (extract(epoch from now() - u.data_hora) / 60)::int else 0 end
      from dia u order by u.data_hora desc limit 1), 0);
$$;

-- -----------------------------------------------------------------------------
-- Meu Ponto
-- -----------------------------------------------------------------------------
create or replace function api_meu_ponto(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'meu_ponto');
  v_hoje    date := fn_hoje();
  c         colaboradores%rowtype;
  v_jornada uuid;
  v_prev    integer;
  v_trab    integer;
  v_qtd     integer;
begin
  select col.* into c
    from colaboradores col join usuarios u on u.colaborador_id = col.id
   where u.id = v_usuario;
  if not found then
    return jsonb_build_object('vinculado', false);
  end if;

  perform fn_banco_horas_atualizar();
  v_jornada := fn_jornada_vigente(c.id, v_hoje);

  select a.previsto_min, a.trabalhado_min into v_prev, v_trab
    from fn_apuracao(v_hoje, v_hoje, c.id) a;
  select count(*) into v_qtd
    from batidas where colaborador_id = c.id and data_referencia = v_hoje and status = 'valida';

  return jsonb_build_object(
    'vinculado', true,
    'agora', now(),
    'colaborador', jsonb_build_object(
      'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'situacao', c.situacao,
      'cargo', (select nome from cargos where id = c.cargo_id),
      'departamento', (select nome from departamentos where id = c.departamento_id),
      'jornada', (select nome from jornadas where id = v_jornada),
      'controle_ponto_inicio', fn_inicio_controle(c)),
    'situacao_dia', fn_situacao_dia_batida(c, v_hoje),
    'pode_registrar', fn_motivo_bloqueio_ponto(c) is null,
    'motivo', fn_motivo_bloqueio_ponto(c),
    'hoje', jsonb_build_object(
      'data', v_hoje,
      'previsto_min', coalesce(v_prev, 0),
      'trabalhado_min', fn_trabalhado_ao_vivo(c.id, v_hoje, v_trab),
      'qtd_batidas', v_qtd,
      'batidas', fn_batidas_json(c.id, v_hoje),
      'jornada_dia', (
        select jsonb_build_object(
                 'folga', jd.folga,
                 'entrada', to_char(jd.entrada, 'HH24:MI'),
                 'saida_intervalo', to_char(jd.saida_intervalo, 'HH24:MI'),
                 'retorno_intervalo', to_char(jd.retorno_intervalo, 'HH24:MI'),
                 'saida', to_char(jd.saida, 'HH24:MI'))
          from fn_jornada_dia(c.id, v_hoje) jd
         where jd.jornada_id is not null)),
    'saldo_banco_min', (select coalesce(sum(minutos), 0) from banco_horas where colaborador_id = c.id),
    'ultimos_dias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'data', a.data, 'previsto_min', a.previsto_min, 'trabalhado_min', a.trabalhado_min,
               'saldo_min', a.saldo_min, 'atraso_min', a.atraso_min, 'ocorrencia', a.ocorrencia,
               'batidas', fn_batidas_json(c.id, a.data)) order by a.data desc)
        from fn_apuracao(greatest(v_hoje - 7, fn_inicio_controle(c)), v_hoje - 1, c.id) a), '[]'::jsonb)
  );
end $$;

-- Registra a batida do colaborador vinculado ao usuário, com o horário do servidor
-- (nunca do navegador). Ninguém registra ponto em nome de outro por aqui.
-- A localização é guardada com a batida e comparada com o local de ponto mais próximo.
-- Sem localização ou fora do raio a batida é registrada mesmo assim (Portaria 671), só fica marcada.
drop function if exists fn_registrar_batida(uuid, origem_batida);
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

  if v_lat is null then
    v_status := 'sem_localizacao';
  else
    select l.id, l.raio_m, fn_distancia_m(v_lat, v_lng, l.latitude, l.longitude)
      into v_local, v_raio, v_dist
      from locais_ponto l
     where l.ativo
     order by 3
     limit 1;
    v_status := case when v_local is null then 'registrada'
                     when v_dist <= v_raio then 'dentro'
                     else 'fora' end;
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

drop function if exists api_registrar_ponto(text);
create or replace function api_registrar_ponto(
  p_token text, p_latitude numeric default null, p_longitude numeric default null,
  p_precisao numeric default null, p_geo_erro text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  return fn_registrar_batida(fn_auth(p_token, 'meu_ponto', true), 'web',
                             p_latitude, p_longitude, p_precisao, p_geo_erro);
end $$;

-- -----------------------------------------------------------------------------
-- Local de ponto (cerca virtual): um só, com coordenadas capturadas pelo aparelho
-- -----------------------------------------------------------------------------
create or replace function api_locais_ponto_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'locais_ponto');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', l.id, 'nome', l.nome, 'endereco', l.endereco,
             'latitude', l.latitude::float8, 'longitude', l.longitude::float8,
             'raio_m', l.raio_m, 'precisao_m', l.precisao_m, 'ativo', l.ativo,
             'batidas_30d', (select count(*) from batidas b
                              where b.local_id = l.id and b.data_referencia >= fn_hoje() - 30),
             'fora_30d', (select count(*) from batidas b
                           where b.local_id = l.id and b.geo_status = 'fora' and b.data_referencia >= fn_hoje() - 30))
           order by l.ativo desc, l.nome)
      from locais_ponto l), '[]'::jsonb);
end $$;

create or replace function api_local_ponto_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d    jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
begin
  perform fn_auth(p_token, 'locais_ponto', true);
  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome do local.'; end if;
  if fn_txt(d, 'latitude') is null or fn_txt(d, 'longitude') is null then
    raise exception 'Capture a localização do local estando nele (botão “Capturar localização”).';
  end if;

  if v_id is null then
    if exists (select 1 from locais_ponto) then
      raise exception 'Já existe um local de ponto cadastrado. Edite o local existente.';
    end if;
    insert into locais_ponto (nome, endereco, latitude, longitude, raio_m, precisao_m, ativo)
    values (fn_txt(d, 'nome'), fn_txt(d, 'endereco'), fn_txt(d, 'latitude')::numeric, fn_txt(d, 'longitude')::numeric,
            coalesce(fn_txt(d, 'raio_m')::int, 150), round(fn_txt(d, 'precisao_m')::numeric)::int,
            coalesce((d ->> 'ativo')::boolean, true))
    returning id into v_id;
  else
    update locais_ponto set
      nome = fn_txt(d, 'nome'), endereco = fn_txt(d, 'endereco'),
      latitude = fn_txt(d, 'latitude')::numeric, longitude = fn_txt(d, 'longitude')::numeric,
      raio_m = coalesce(fn_txt(d, 'raio_m')::int, 150), precisao_m = round(fn_txt(d, 'precisao_m')::numeric)::int,
      ativo = coalesce((d ->> 'ativo')::boolean, true)
     where id = v_id;
    if not found then raise exception 'Local não encontrado.'; end if;
  end if;
  -- Batidas já registradas mantêm a situação calculada no momento da marcação
  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    raise exception 'Já existe um local com este nome.';
  when check_violation then
    raise exception 'Confira os valores: latitude entre -90 e 90, longitude entre -180 e 180 e raio entre 10 m e 50 km.';
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Localização inválida. Capture a localização novamente.';
end $$;

create or replace function api_local_ponto_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'locais_ponto', true);
  if exists (select 1 from batidas where local_id = p_id) then
    raise exception 'Este local já tem batidas registradas. Desative-o em vez de excluir.';
  end if;
  delete from locais_ponto where id = p_id;
  if not found then raise exception 'Local não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Acompanhamento de batidas
-- -----------------------------------------------------------------------------
create or replace function api_batidas_dia(p_token text, p_data date default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_hoje  date := fn_hoje();
  v_data  date := least(coalesce(p_data, fn_hoje()), fn_hoje());
  v_agora time := (now() at time zone fn_fuso())::time;
begin
  perform fn_auth(p_token, 'batidas');

  return jsonb_build_object(
    'data', v_data,
    'hoje', v_hoje,
    'colaboradores', coalesce((
      select jsonb_agg(t order by t.ordem, t.nome)
        from (
          select c.id, c.nome, c.matricula, c.situacao,
                 d.nome as departamento, j.nome as jornada,
                 fn_horario_dia(c.id, v_data) as horario_previsto,
                 a.previsto_min,
                 fn_trabalhado_ao_vivo(c.id, v_data, a.trabalhado_min) as trabalhado_min,
                 a.atraso_min, a.saldo_min, a.ocorrencia,
                 fn_batidas_json(c.id, v_data) as batidas,
                 st.status,
                 case st.status
                   when 'inconsistente' then 0 when 'ausente' then 1 when 'em_jornada' then 2
                   when 'em_intervalo' then 3 when 'aguardando' then 4 when 'finalizado' then 5 else 6 end as ordem
            from fn_apuracao(v_data, v_data) a
            join colaboradores c      on c.id = a.colaborador_id
            left join departamentos d on d.id = c.departamento_id
            left join jornadas j      on j.id = a.jornada_id
            left join perfis_eventos pe on pe.id = c.perfil_evento_id
            left join lateral fn_jornada_dia(c.id, v_data) jd on true
            cross join lateral (
              select case
                when c.situacao in ('ferias', 'afastado') and a.qtd_batidas = 0 then c.situacao::text
                when a.ocorrencia like 'ausencia:%' and a.qtd_batidas = 0 then 'ausencia'
                when a.previsto_min = 0 and a.qtd_batidas = 0 then 'folga'
                when v_data < v_hoje then
                  case when a.qtd_batidas = 0 then 'ausente'
                       when a.impar then 'inconsistente'
                       else 'finalizado' end
                when a.qtd_batidas = 0 and v_agora > jd.entrada + make_interval(mins => coalesce(
                       case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else pe.tolerancia_entrada_min end, 0))
                  then 'ausente'
                when a.qtd_batidas = 0 then 'aguardando'
                when a.ultimo_sentido = 'E' then 'em_jornada'
                when a.qtd_batidas < case when jd.saida_intervalo is null then 2 else 4 end then 'em_intervalo'
                else 'finalizado' end as status
            ) st
           where (c.situacao <> 'desligado' or c.data_desligamento >= v_data)
             and fn_visivel(c.id)
        ) t), '[]'::jsonb),
    'ultimas', coalesce((
      select jsonb_agg(u order by u.data_hora desc)
        from (
          select b.id, b.data_hora, c.nome, b.origem, b.nsr,
                 to_char(b.data_hora at time zone fn_fuso(), 'HH24:MI') as hora
            from batidas b
            join colaboradores c on c.id = b.colaborador_id
           where b.data_referencia = v_data and b.status = 'valida' and fn_visivel(c.id)
           order by b.data_hora desc
           limit 20
        ) u), '[]'::jsonb)
  );
end $$;

-- -----------------------------------------------------------------------------
-- Banco de horas
-- -----------------------------------------------------------------------------
create or replace function api_banco_horas_resumo(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'banco_horas');
  perform fn_banco_horas_atualizar();

  return coalesce((
    select jsonb_agg(r order by r.nome)
      from (
        select c.id, c.nome, c.matricula, c.situacao, d.nome as departamento, j.nome as jornada,
               coalesce(sum(bh.minutos) filter (where bh.minutos > 0), 0)::int as creditos,
               coalesce(sum(bh.minutos) filter (where bh.minutos < 0), 0)::int as debitos,
               coalesce(sum(bh.minutos), 0)::int as saldo,
               max(bh.data) as ultimo_lancamento
          from colaboradores c
          left join departamentos d on d.id = c.departamento_id
          left join jornadas j      on j.id = c.jornada_id
          left join banco_horas bh  on bh.colaborador_id = c.id
         where fn_visivel(c.id)
         group by c.id, c.nome, c.matricula, c.situacao, d.nome, j.nome
        having c.situacao <> 'desligado' or count(bh.id) > 0
      ) r), '[]'::jsonb);
end $$;

create or replace function api_banco_horas_extrato(p_token text, p_colaborador uuid, p_ini date, p_fim date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_anterior integer;
begin
  perform fn_auth(p_token, 'banco_horas');
  if not fn_visivel(p_colaborador) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  perform fn_banco_horas_atualizar();

  select coalesce(sum(minutos), 0) into v_anterior
    from banco_horas where colaborador_id = p_colaborador and data < p_ini;

  return jsonb_build_object(
    'saldo_anterior', v_anterior,
    'saldo_final', v_anterior + coalesce((select sum(minutos) from banco_horas
                                           where colaborador_id = p_colaborador and data between p_ini and p_fim), 0),
    'lancamentos', coalesce((
      select jsonb_agg(l order by l.data, l.created_at)
        from (
          select bh.id, bh.data, bh.tipo, bh.origem, bh.minutos, bh.descricao, bh.created_at,
                 u.nome as usuario,
                 v_anterior + sum(bh.minutos) over (order by bh.data, bh.created_at, bh.id) as saldo
            from banco_horas bh
            left join usuarios u on u.id = bh.usuario_id
           where bh.colaborador_id = p_colaborador and bh.data between p_ini and p_fim
        ) l), '[]'::jsonb));
end $$;

create or replace function api_banco_horas_lancar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'banco_horas', true);
  v_tipo    tipo_lancamento_bh;
  v_min     integer;
  v_id      uuid;
begin
  if fn_txt(p_dados, 'colaborador_id') is null then raise exception 'Selecione o colaborador.'; end if;
  if not fn_visivel(fn_txt(p_dados, 'colaborador_id')::uuid) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  if fn_txt(p_dados, 'data') is null then raise exception 'Informe a data do lançamento.'; end if;
  if fn_txt(p_dados, 'descricao') is null then raise exception 'Informe a justificativa do lançamento.'; end if;

  v_tipo := fn_txt(p_dados, 'tipo')::tipo_lancamento_bh;
  if v_tipo::text = 'conversao' then
    raise exception 'Use o menu Conversão do Banco de Horas para converter o saldo.';
  end if;
  v_min  := (p_dados ->> 'minutos')::integer;
  if coalesce(v_min, 0) = 0 then raise exception 'Informe a quantidade de horas.'; end if;

  -- Crédito soma; débito e compensação subtraem; ajuste respeita o sinal informado
  v_min := case v_tipo
             when 'credito' then abs(v_min)
             when 'ajuste'  then v_min
             else -abs(v_min) end;

  insert into banco_horas (colaborador_id, data, tipo, origem, minutos, descricao, usuario_id)
  values (fn_txt(p_dados, 'colaborador_id')::uuid, fn_txt(p_dados, 'data')::date, v_tipo, 'manual',
          v_min, fn_txt(p_dados, 'descricao'), v_usuario)
  returning id into v_id;

  return jsonb_build_object('id', v_id);
end $$;

create or replace function api_banco_horas_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'banco_horas', true);
  -- A conversão tem permissão própria: só sai pelo estorno (api_banco_horas_conversao_estornar)
  if exists (select 1 from banco_horas where id = p_id and tipo = 'conversao') then
    raise exception 'Conversões não são excluídas aqui. Use "Estornar" em Conversão do Banco de Horas.';
  end if;
  delete from banco_horas where id = p_id and origem = 'manual' and fn_visivel(colaborador_id);
  if not found then
    raise exception 'Apenas lançamentos manuais podem ser excluídos. Os automáticos vêm das batidas.';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- Banco de horas detalhado por dia (relatório da tela Banco de Horas): para cada colaborador, cada dia
-- com previsão ou movimento, com todas as marcações previstas (E1, S1, E2, S2) e o realizado.
-- Só turno completo (entrada e saída) soma horas; turno que não fechou entra com o previsto dele como débito.
--   linhas  → marcação prevista e/ou batida realizada, com o que ela gerou:
--             turno completo com previsão → entrada: previsto − realizado · saída: realizado − previsto
--             turno completo sem previsão (folga, feriado, turno extra) → a saída gera o turno inteiro
--   turnos  → previsto e trabalhado de cada turno; incompleto → gerou = −previsto do turno
--   saldo_dia → o que a apuração mandou para o banco (ou para a folha), já com a tolerância diária
--   acumulado → saldo do banco ao fim do dia
create or replace function api_banco_horas_detalhe(p_token text, p_ini date, p_fim date, p_colaborador uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_tz text := fn_fuso();
begin
  perform fn_auth(p_token, 'banco_horas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;
  if p_colaborador is not null and not fn_visivel(p_colaborador) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  perform fn_banco_horas_atualizar();

  drop table if exists pg_temp._bh_col;
  create temp table _bh_col on commit drop as
    select c.id, c.nome, c.matricula, d.nome as departamento, j.nome as jornada
      from colaboradores c
      left join departamentos d on d.id = c.departamento_id
      left join jornadas j      on j.id = c.jornada_id
     where (p_colaborador is null or c.id = p_colaborador)
       and fn_visivel(c.id)
       and (c.situacao <> 'desligado' or exists (select 1 from banco_horas bh where bh.colaborador_id = c.id
                                                   and bh.data between p_ini and p_fim))
       and (c.controla_ponto or exists (select 1 from banco_horas bh where bh.colaborador_id = c.id));

  drop table if exists pg_temp._bh_ap;
  create temp table _bh_ap on commit drop as
    select a.* from fn_apuracao(p_ini, p_fim, p_colaborador) a where a.colaborador_id in (select id from _bh_col);

  -- Batidas válidas, com o instante local (minuto cheio)
  drop table if exists pg_temp._bh_bat;
  create temp table _bh_bat on commit drop as
    select b.id, b.colaborador_id, b.data_referencia as data, b.sentido, b.turno, b.origem, b.data_hora,
           date_trunc('minute', b.data_hora at time zone v_tz) as local
      from fn_batidas_periodo(p_ini, p_fim, p_colaborador) b
     where b.colaborador_id in (select id from _bh_col) and b.status = 'valida';

  -- Marcações previstas dos dias com previsão (feriado, folga e abono não têm)
  drop table if exists pg_temp._bh_prev;
  create temp table _bh_prev on commit drop as
    select a.colaborador_id, a.data, v.sentido, v.turno, v.hora,
           a.data + v.hora + case when v.hora < jd.entrada then interval '1 day' else interval '0' end as ts
      from _bh_ap a
     cross join lateral fn_jornada_dia(a.colaborador_id, a.data) jd
     cross join lateral (values ('E', 1, jd.entrada),
                                ('S', 1, coalesce(jd.saida_intervalo, jd.saida)),
                                ('E', 2, jd.retorno_intervalo),
                                ('S', 2, case when jd.saida_intervalo is not null then jd.saida end)) v(sentido, turno, hora)
     where a.previsto_min > 0 and v.hora is not null;

  -- Turnos do dia: previsto, realizado e se fechou (entrada e saída)
  drop table if exists pg_temp._bh_tur;
  create temp table _bh_tur on commit drop as
    select k.colaborador_id, k.data, k.turno,
           coalesce((extract(epoch from ps.ts - pe.ts) / 60)::int, 0) as previsto_min,
           be.local as e_real, bs.local as s_real,
           (be.local is not null and bs.local is not null) as completo,
           coalesce((extract(epoch from bs.local - be.local) / 60)::int, 0) as trabalhado_min,
           pe.ts as e_prev, ps.ts as s_prev
      from (select colaborador_id, data, turno from _bh_prev
            union
            select colaborador_id, data, turno from _bh_bat) k
      left join _bh_prev pe on pe.colaborador_id = k.colaborador_id and pe.data = k.data and pe.turno = k.turno and pe.sentido = 'E'
      left join _bh_prev ps on ps.colaborador_id = k.colaborador_id and ps.data = k.data and ps.turno = k.turno and ps.sentido = 'S'
      left join lateral (select min(b.local) as local from _bh_bat b
                          where b.colaborador_id = k.colaborador_id and b.data = k.data
                            and b.turno = k.turno and b.sentido = 'E') be on true
      left join lateral (select min(b.local) as local from _bh_bat b
                          where b.colaborador_id = k.colaborador_id and b.data = k.data
                            and b.turno = k.turno and b.sentido = 'S') bs on true;

  -- Linhas do dia: cada marcação prevista com a batida correspondente, mais as batidas sem previsão
  drop table if exists pg_temp._bh_lin;
  create temp table _bh_lin on commit drop as
    select coalesce(p.colaborador_id, b.colaborador_id) as colaborador_id, coalesce(p.data, b.data) as data,
           coalesce(p.turno, b.turno) as turno, coalesce(p.sentido, b.sentido) as sentido,
           p.hora as previsto, b.id as batida_id, b.local, b.origem,
           coalesce(b.local, p.ts) as ordem
      from _bh_prev p
      full join _bh_bat b on b.colaborador_id = p.colaborador_id and b.data = p.data
                         and b.turno = p.turno and b.sentido = p.sentido;

  drop table if exists pg_temp._bh_mov;
  create temp table _bh_mov on commit drop as
    select bh.colaborador_id, bh.data, sum(bh.minutos)::int as minutos
      from banco_horas bh
     where bh.colaborador_id in (select id from _bh_col) and bh.data between p_ini and p_fim
     group by bh.colaborador_id, bh.data;

  return coalesce((
    select jsonb_agg(col order by col ->> 'nome')
      from (
        select jsonb_build_object(
                 'id', c.id, 'nome', c.nome, 'matricula', c.matricula,
                 'departamento', c.departamento, 'jornada', c.jornada,
                 'saldo_anterior', s.anterior,
                 'creditos', coalesce((select sum(minutos) from banco_horas where colaborador_id = c.id
                                        and data between p_ini and p_fim and minutos > 0), 0),
                 'debitos', coalesce((select sum(minutos) from banco_horas where colaborador_id = c.id
                                       and data between p_ini and p_fim and minutos < 0), 0),
                 'saldo_final', s.anterior + coalesce((select sum(minutos) from _bh_mov where colaborador_id = c.id), 0),
                 'dias', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'data', a.data,
                            'horario_previsto', case when a.previsto_min > 0 then fn_horario_dia(a.colaborador_id, a.data) end,
                            'ocorrencia', a.ocorrencia,
                            'previsto_min', a.previsto_min,
                            'trabalhado_min', a.trabalhado_min,
                            'saldo_dia', a.saldo_min,
                            'vai_para_banco', a.banco_horas,
                            'banco_dia', coalesce(mv.minutos, 0),
                            'acumulado', s.anterior + coalesce((select sum(m2.minutos) from _bh_mov m2
                                                                 where m2.colaborador_id = c.id and m2.data <= a.data), 0),
                            'linhas', coalesce((
                              select jsonb_agg(jsonb_build_object(
                                       'turno', l.turno, 'sentido', l.sentido,
                                       'previsto', to_char(l.previsto, 'HH24:MI'),
                                       'hora', to_char(l.local, 'HH24:MI'),
                                       'origem', l.origem,
                                       'gerou_min', case
                                          when not t.completo or l.local is null then null
                                          when t.e_prev is not null and t.s_prev is not null then
                                            case when l.sentido = 'E' then (extract(epoch from t.e_prev - l.local) / 60)::int
                                                 else (extract(epoch from l.local - t.s_prev) / 60)::int end
                                          when l.sentido = 'S' then t.trabalhado_min
                                       end)
                                       order by l.turno, l.sentido, l.ordem)
                                from _bh_lin l
                                join _bh_tur t on t.colaborador_id = l.colaborador_id and t.data = l.data and t.turno = l.turno
                               where l.colaborador_id = c.id and l.data = a.data), '[]'::jsonb),
                            'turnos', coalesce((
                              select jsonb_agg(jsonb_build_object(
                                       'turno', t.turno, 'previsto_min', t.previsto_min,
                                       'trabalhado_min', case when t.completo then t.trabalhado_min else 0 end,
                                       'completo', t.completo,
                                       'gerou_min', case when t.completo then t.trabalhado_min else 0 end - t.previsto_min)
                                       order by t.turno)
                                from _bh_tur t
                               where t.colaborador_id = c.id and t.data = a.data), '[]'::jsonb),
                            'lancamentos', coalesce((
                              select jsonb_agg(jsonb_build_object('id', l.id, 'tipo', l.tipo, 'minutos', l.minutos,
                                                                  'descricao', l.descricao, 'usuario', u.nome)
                                               order by l.created_at)
                                from banco_horas l
                                left join usuarios u on u.id = l.usuario_id
                               where l.colaborador_id = c.id and l.data = a.data and l.origem = 'manual'), '[]'::jsonb))
                          order by a.data)
                     from _bh_ap a
                     left join _bh_mov mv on mv.colaborador_id = a.colaborador_id and mv.data = a.data
                    where a.colaborador_id = c.id
                      and (a.previsto_min > 0 or a.qtd_batidas > 0 or a.saldo_min <> 0 or mv.minutos is not null
                           or a.ocorrencia like 'ausencia:%')), '[]'::jsonb)
               ) as col
          from _bh_col c
         cross join lateral (
           select coalesce(sum(bh.minutos), 0)::int as anterior
             from banco_horas bh where bh.colaborador_id = c.id and bh.data < p_ini
         ) s
      ) x), '[]'::jsonb);
end $$;

-- -----------------------------------------------------------------------------
-- Conversão do saldo do banco de horas (menu próprio, como no Fortes Ponto).
-- Leva o saldo até a data para a folha: positivo → horas extras pagas; negativo → desconto.
-- Cada conversão é um lançamento 'conversao' de sinal oposto ao convertido, que zera
-- (ou reduz, com limite) o saldo. Pode ser estornada no histórico de conversões.
--   p_converter: 'positivo' | 'negativo' | 'ambos'
--   p_limite_min: máximo convertido por colaborador (null = saldo inteiro)
--   p_simular: só calcula a prévia, sem gravar
-- -----------------------------------------------------------------------------
insert into paginas (chave, nome, grupo, ordem)
values ('banco_horas_conversao', 'Conversão do Banco de Horas', 'Movimentos', 62)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select p.id, 'banco_horas_conversao', true, true from perfis p where p.nome = 'RH'
on conflict (perfil_id, pagina) do nothing;

create or replace function api_banco_horas_converter(
  p_token text, p_data date, p_converter text, p_colaboradores uuid[] default null,
  p_limite_min integer default null, p_descricao text default null, p_simular boolean default true)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'banco_horas_conversao', not coalesce(p_simular, true));
  v_itens   jsonb;
begin
  if p_data is null then raise exception 'Informe a data da conversão.'; end if;
  if p_data > fn_hoje() then raise exception 'A data da conversão não pode ser futura.'; end if;
  if coalesce(p_converter, '') not in ('positivo', 'negativo', 'ambos') then
    raise exception 'Escolha qual saldo converter.';
  end if;
  if p_limite_min is not null and p_limite_min <= 0 then
    raise exception 'O limite de horas deve ser maior que zero.';
  end if;
  perform fn_banco_horas_atualizar();

  drop table if exists pg_temp._conv;
  create temp table _conv on commit drop as
    select r.*, -r.convertido as lancamento
      from (
        select s.*,
               case when s.saldo > 0 and p_converter in ('positivo', 'ambos')
                      then least(s.saldo, coalesce(p_limite_min, s.saldo))
                    when s.saldo < 0 and p_converter in ('negativo', 'ambos')
                      then -least(-s.saldo, coalesce(p_limite_min, -s.saldo))
                    else 0 end as convertido
          from (
            select c.id, c.nome, c.matricula,
                   coalesce((select sum(bh.minutos) from banco_horas bh
                              where bh.colaborador_id = c.id and bh.data <= p_data), 0)::int as saldo
              from colaboradores c
             where (p_colaboradores is null or c.id = any(p_colaboradores))
               and fn_visivel(c.id)
          ) s
      ) r;

  if not coalesce(p_simular, true) then
    if not exists (select 1 from _conv where convertido <> 0) then
      raise exception 'Nenhum saldo para converter com essas opções.';
    end if;
    insert into banco_horas (colaborador_id, data, tipo, origem, minutos, descricao, usuario_id)
    select v.id, p_data, 'conversao', 'manual', v.lancamento,
           coalesce(nullif(trim(p_descricao), ''),
                    case when v.convertido > 0 then 'Conversão do saldo em pagamento de horas extras'
                         else 'Conversão do saldo em desconto' end),
           v_usuario
      from _conv v
     where v.convertido <> 0;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', v.id, 'nome', v.nome, 'matricula', v.matricula, 'saldo', v.saldo,
           'convertido', v.convertido, 'saldo_final', v.saldo - v.convertido) order by v.nome), '[]'::jsonb)
    into v_itens
    from _conv v
   where v.saldo <> 0;

  return jsonb_build_object(
    'gravado', not coalesce(p_simular, true),
    'itens', v_itens,
    'pago_min', (select coalesce(sum(convertido) filter (where convertido > 0), 0) from _conv),
    'descontado_min', (select coalesce(-sum(convertido) filter (where convertido < 0), 0) from _conv));
end $$;

-- Histórico das conversões no período
create or replace function api_banco_horas_conversoes(p_token text, p_ini date, p_fim date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'banco_horas_conversao');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', bh.id, 'data', bh.data, 'colaborador_id', c.id, 'nome', c.nome, 'matricula', c.matricula,
             'convertido', -bh.minutos, 'descricao', bh.descricao, 'usuario', u.nome, 'created_at', bh.created_at)
             order by bh.data desc, bh.created_at desc, c.nome)
      from banco_horas bh
      join colaboradores c  on c.id = bh.colaborador_id
      left join usuarios u  on u.id = bh.usuario_id
     where bh.tipo = 'conversao'
       and bh.data between p_ini and p_fim
       and fn_visivel(c.id)), '[]'::jsonb);
end $$;

-- Estorno de uma conversão (exclui o lançamento; o saldo volta ao que era)
create or replace function api_banco_horas_conversao_estornar(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'banco_horas_conversao', true);
  delete from banco_horas where id = p_id and tipo = 'conversao' and fn_visivel(colaborador_id);
  if not found then raise exception 'Conversão não encontrada.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
revoke execute on function fn_motivo_bloqueio_ponto(colaboradores)      from public, anon, authenticated;
revoke execute on function fn_situacao_dia_batida(colaboradores, date)  from public, anon, authenticated;
revoke execute on function fn_batidas_json(uuid, date)                  from public, anon, authenticated;
revoke execute on function fn_batida_geo_json(uuid)                     from public, anon, authenticated;
revoke execute on function fn_distancia_m(numeric, numeric, numeric, numeric) from public, anon, authenticated;
revoke execute on function fn_batidas_periodo(date, date, uuid)         from public, anon, authenticated;
revoke execute on function fn_rotulo_batida(text, integer)              from public, anon, authenticated;

-- Hora oficial (servidor, fuso da empresa) para os relógios das telas de registro
create or replace function api_hora_oficial()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('agora', now(), 'fuso', fn_fuso());
$$;
grant execute on function api_hora_oficial()                            to anon, authenticated;
revoke execute on function fn_trabalhado_ao_vivo(uuid, date, integer)   from public, anon, authenticated;
revoke execute on function fn_jornada_vigente(uuid, date)               from public, anon, authenticated;
revoke execute on function fn_inicio_controle(colaboradores)            from public, anon, authenticated;
revoke execute on function fn_apuracao(date, date, uuid)                from public, anon, authenticated;
revoke execute on function fn_processar_banco_horas(date, date, uuid)   from public, anon, authenticated;
revoke execute on function fn_banco_horas_atualizar()                   from public, anon, authenticated;

grant execute on function api_meu_ponto(text)                           to anon, authenticated;
revoke execute on function fn_registrar_batida(uuid, origem_batida, numeric, numeric, numeric, text) from public, anon, authenticated;
grant execute on function api_registrar_ponto(text, numeric, numeric, numeric, text) to anon, authenticated;
grant execute on function api_locais_ponto_listar(text)                 to anon, authenticated;
grant execute on function api_local_ponto_salvar(text, jsonb)           to anon, authenticated;
grant execute on function api_local_ponto_excluir(text, uuid)           to anon, authenticated;
grant execute on function api_batidas_dia(text, date)                   to anon, authenticated;
grant execute on function api_banco_horas_resumo(text)                  to anon, authenticated;
grant execute on function api_banco_horas_extrato(text, uuid, date, date) to anon, authenticated;
grant execute on function api_banco_horas_lancar(text, jsonb)           to anon, authenticated;
grant execute on function api_banco_horas_excluir(text, uuid)           to anon, authenticated;
grant execute on function api_banco_horas_detalhe(text, date, date, uuid) to anon, authenticated;
grant execute on function api_banco_horas_converter(text, date, text, uuid[], integer, text, boolean) to anon, authenticated;
grant execute on function api_banco_horas_conversoes(text, date, date) to anon, authenticated;
grant execute on function api_banco_horas_conversao_estornar(text, uuid) to anon, authenticated;

-- Atualiza o cache de funções da API do Supabase (PostgREST)
notify pgrst, 'reload schema';
