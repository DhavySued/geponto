-- =============================================================================
-- GePonto — 07_api_tratamento.sql
-- Tratamento de batidas (individual) e Consulta de batidas com ajustes rápidos.
-- Execute depois de 06_api_ponto.sql. Pode ser reexecutado.
--
-- Regras (também garantidas pelo trigger fn_batida_proteger em 01_schema.sql):
--   • Incluída (origem manual): pode ser editada e excluída.
--   • Original (relógio, sistema, celular, importação): nunca é excluída nem editada;
--     pode ser desconsiderada (com motivo), ter o sentido declarado ou a data de
--     referência alterada (reclassificação).
--   • Toda ação fica em batida_ajustes (quem, quando, antes/depois, motivo).
-- =============================================================================

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

-- Leitura: Tratamento de Batidas ou Consulta de Batidas
create or replace function fn_auth_tratamento_leitura(p_token text)
returns uuid language plpgsql volatile set search_path = public as $$
declare v_usuario uuid := fn_auth(p_token);
begin
  if not (fn_pode(v_usuario, 'lancamento_manual') or fn_pode(v_usuario, 'consulta_batidas')) then
    raise exception 'Acesso negado ao tratamento de batidas' using errcode = '42501';
  end if;
  return v_usuario;
end $$;

-- Batida de colaborador fora da abrangência do usuário → acesso negado
create or replace function fn_exigir_visivel(p_colaborador uuid)
returns void language plpgsql stable set search_path = public as $$
begin
  if not fn_visivel(p_colaborador) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
end $$;

create or replace function fn_status_batida(p_origem origem_batida, p_status status_batida)
returns text language sql immutable as $$
  select case when p_status = 'desconsiderada' then 'desconsiderada'
              when p_origem = 'manual' then 'incluida'
              else 'original' end;
$$;

-- fn_batidas_periodo (sentido e turno efetivos de cada batida) fica em 06_api_ponto.sql

create or replace function fn_batida_json(b record, p_motivo text)
returns jsonb language plpgsql stable set search_path = public as $$
begin
  return jsonb_build_object(
    'id', b.id,
    'colaborador_id', b.colaborador_id,
    'data_hora', b.data_hora,
    'data', (b.data_hora at time zone fn_fuso())::date,
    'hora', to_char(b.data_hora at time zone fn_fuso(), 'HH24:MI'),
    'data_referencia', b.data_referencia,
    'origem', b.origem,
    'status', fn_status_batida(b.origem, b.status),
    'sentido', b.sentido,
    'sentido_declarado', b.sentido_declarado,
    'turno', b.turno,
    'turno_declarado', b.turno_declarado,
    'nsr', b.nsr,
    'motivo_id', b.motivo_id,
    'motivo', p_motivo,
    'observacao', b.observacao) || fn_batida_geo_json(b.id);
end $$;

create or replace function fn_batida_auditar(
  p_batida batidas, p_acao text, p_anterior timestamptz, p_novo timestamptz,
  p_motivo uuid, p_justificativa text, p_dados jsonb default null)
returns void language sql volatile set search_path = public as $$
  insert into batida_ajustes (batida_id, colaborador_id, acao, valor_anterior, valor_novo,
                              justificativa, usuario_id, motivo_id, dados)
  values (case when p_acao = 'exclusao' then null else p_batida.id end, p_batida.colaborador_id, p_acao,
          p_anterior, p_novo, p_justificativa,
          nullif(current_setting('app.usuario_id', true), '')::uuid, p_motivo, p_dados);
$$;

-- Valida um motivo para a aplicação ('inclusao' ou 'desconsideracao') e devolve a descrição
create or replace function fn_motivo_valido(p_motivo uuid, p_aplicacao text)
returns text language plpgsql stable set search_path = public as $$
declare v text;
begin
  if p_motivo is null then
    raise exception 'Selecione o motivo.';
  end if;
  select descricao into v from motivos_batida
   where id = p_motivo and ativo and aplicacao in (p_aplicacao, 'ambos');
  if v is null then
    raise exception 'Motivo inválido para esta operação.';
  end if;
  return v;
end $$;

-- Converte data + hora local da empresa em timestamptz
create or replace function fn_data_hora_local(p_data date, p_hora text)
returns timestamptz language plpgsql stable set search_path = public as $$
begin
  if p_data is null or coalesce(trim(p_hora), '') = '' then
    raise exception 'Informe a data e a hora da batida.';
  end if;
  return (p_data + p_hora::time) at time zone fn_fuso();
exception
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Hora inválida. Use o formato HH:MM.';
end $$;

-- -----------------------------------------------------------------------------
-- Leitura
-- -----------------------------------------------------------------------------
create or replace function api_tratamento_auxiliares(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_usuario uuid := fn_auth_tratamento_leitura(p_token);
begin
  return jsonb_build_object(
    'pode_editar', fn_pode(v_usuario, 'lancamento_manual', true),
    'estabelecimentos', (select jsonb_agg(jsonb_build_object('id', id::text,
                                  'nome', coalesce(nome_fantasia, razao_social)))
                           from empresas where id = coalesce(fn_empresa_atual(), fn_empresa_padrao())),
    'colaboradores', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'situacao', c.situacao,
                         'departamento_id', c.departamento_id, 'cargo_id', c.cargo_id, 'jornada_id', c.jornada_id)
                         order by c.nome) from colaboradores c where fn_visivel(c.id)), '[]'::jsonb),
    'departamentos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from departamentos), '[]'::jsonb),
    'cargos',        coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from cargos), '[]'::jsonb),
    'jornadas',      coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from jornadas where fn_da_empresa(empresa_id, todas_empresas)), '[]'::jsonb),
    'motivos',       coalesce((select jsonb_agg(jsonb_build_object('id', id, 'descricao', descricao,
                                                                   'aplicacao', aplicacao) order by descricao)
                                 from motivos_batida where ativo), '[]'::jsonb));
end $$;

-- Tela de Tratamento Individual: lista de batidas com filtros
drop function if exists api_tratamento_batidas(text, date, date, uuid, uuid, text);
create or replace function api_tratamento_batidas(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null, p_status text default 'todas', p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth_tratamento_leitura(p_token);
  if p_ini is null or p_fim is null or p_fim < p_ini then
    raise exception 'Informe um período válido.';
  end if;
  if p_fim - p_ini > 92 then
    raise exception 'Selecione um período de até 3 meses.';
  end if;

  return coalesce((
    select jsonb_agg(fn_batida_json(b, m.descricao)
                     || jsonb_build_object('colaborador', c.nome, 'matricula', c.matricula, 'departamento', d.nome)
                     order by c.nome, b.data_hora)
      from fn_batidas_periodo(p_ini, p_fim, p_colaborador) b
      join colaboradores c      on c.id = b.colaborador_id
      left join departamentos d on d.id = c.departamento_id
      left join motivos_batida m on m.id = b.motivo_id
     where (p_departamento is null or c.departamento_id = p_departamento)
       and fn_filtro_colaborador(c.id, null, p_colaboradores)
       and (coalesce(p_status, 'todas') = 'todas' or fn_status_batida(b.origem, b.status) = p_status)
       and fn_visivel(c.id)
  ), '[]'::jsonb);
end $$;

-- Consulta de batidas: uma linha por batida e uma por marcação prevista que não foi batida.
-- A marcação (E1, S1, E2, S2) é a classificação efetiva de fn_batidas_periodo e define o horário previsto:
--   E1 → entrada · S1 → saída para o intervalo (ou saída, sem intervalo) · E2 → retorno · S2 → saída
-- Situação das batidas (tolerâncias da jornada: entrada para as entradas, saída para as saídas):
--   feriado · folga · ausencia (afastamento, férias, atestado…) · sem_jornada · fora_jornada (sem horário previsto)
--   precisa (no minuto previsto) · entrada_tolerancia / saida_tolerancia (diferente, mas dentro da tolerância)
--   turno_incompleto (batida sem o par entrada/saída do turno: não é apurada) · turno_aberto (hoje, aguardando a saída)
--   entrada: atraso (depois do previsto) · antecipada (antes do previsto)
--   saída:   saida_antecipada (antes do previsto) · apos_previsto (depois do previsto)
-- Marcações previstas sem batida (dias de trabalho, fora feriados e ausências):
--   nao_registrada (o horário já passou) · pendente (ainda vai acontecer)
drop function if exists api_consulta_batidas(text, date, date, uuid, uuid, uuid, uuid);
create or replace function api_consulta_batidas(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null,
  p_cargo uuid default null, p_jornada uuid default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_tz    text := fn_fuso();
  v_agora timestamp := now() at time zone fn_fuso();
begin
  perform fn_auth_tratamento_leitura(p_token);
  if p_ini is null or p_fim is null or p_fim < p_ini then
    raise exception 'Informe um período válido.';
  end if;
  if p_fim - p_ini > 62 then
    raise exception 'Selecione um período de até 2 meses.';
  end if;

  return coalesce((
    with colab as (
      select c.*, d.nome as departamento
        from colaboradores c
        left join departamentos d on d.id = c.departamento_id
       where fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)
         and (p_cargo        is null or c.cargo_id = p_cargo)
         and (p_jornada      is null or c.jornada_id = p_jornada)
         and fn_visivel(c.id)
    ),
    -- Jornada de cada colaborador em cada dia do período (só quem tem o ponto controlado;
    -- as batidas de quem não tem aparecem como "não controladas", sem previsão)
    dia as (
      select c.id as colaborador_id, g::date as data, jd.*, j.nome as jornada,
             -- tolerância por batida, ou a geral do dia quando o perfil usa só ela
             case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else pe.tolerancia_entrada_min end as tol_e,
             case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else pe.tolerancia_saida_min end as tol_s,
             -- escala de trabalho no feriado: para o colaborador o dia é normal
             (f.id is not null and jd.escala is distinct from 'trabalho') as feriado, a.tipo as ausencia,
             fn_horario_dia(c.id, g::date) as horario_previsto,
             -- Observação do dia: ausência registrada (férias, afastamento…) ou feriado
             case a.tipo
               when 'ferias'            then 'Empregado de férias'
               when 'afastamento'       then 'Empregado afastado'
               when 'atestado'          then 'Empregado com atestado médico'
               when 'falta_justificada' then 'Falta justificada'
               when 'folga'             then 'Folga concedida'
               when 'abono'             then 'Dia abonado'
               else case when f.id is not null and jd.escala is distinct from 'trabalho' then 'Feriado: ' || f.descricao end
             end as obs_dia
        from colab c
       cross join generate_series(greatest(p_ini, c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao)),
                                  least(p_fim, coalesce(c.data_desligamento, p_fim)), interval '1 day') g
        left join lateral fn_jornada_dia(c.id, g::date) jd on true
        left join jornadas j on j.id = jd.jornada_id
        left join perfis_eventos pe on pe.id = fn_perfil_vigente(c.id, g::date)
        left join feriados f on f.data = g::date
        left join lateral (
          select au.tipo
            from ausencias au
           where au.colaborador_id = c.id
             and g::date between au.data_inicio and au.data_fim
             and au.minutos is null
           order by au.abona desc
           limit 1
        ) a on true
       where c.controla_ponto
    ),
    -- Marcações previstas do dia (E1, S1, E2, S2), com o instante local previsto.
    -- Intervalo flexível: S1 e E2 não têm horário fixo (flex) e só ficam "não registradas" depois da saída prevista.
    prev as (
      select d.colaborador_id, d.data, m.sentido, m.turno, m.hora,
             d.data + m.hora + case when m.hora < d.entrada then interval '1 day' else interval '0' end as ts,
             (d.intervalo_flexivel and (m.sentido, m.turno) in (('S', 1), ('E', 2))) as flex,
             d.data + d.saida + case when d.saida <= d.entrada then interval '1 day' else interval '0' end as ts_saida
        from dia d
       cross join lateral (values
         ('E', 1, d.entrada),
         ('S', 1, coalesce(d.saida_intervalo, d.saida)),
         ('E', 2, d.retorno_intervalo),
         ('S', 2, case when d.saida_intervalo is not null then d.saida end)
       ) m(sentido, turno, hora)
       where not coalesce(d.folga, true) and not d.feriado and d.entrada is not null and m.hora is not null
    ),
    bat as (
      select b.*, (b.data_hora at time zone v_tz) as local
        from fn_batidas_periodo(p_ini, p_fim, p_colaborador) b
       where b.colaborador_id in (select id from colab)
         and b.status = 'valida'   -- desconsideradas não aparecem na consulta (ficam no Tratamento de Batidas)
    ),
    linhas as (
      -- Batidas
      select c.nome, b.local as ordem,
             fn_batida_json(b, m.descricao) || jsonb_build_object(
               'tipo', 'batida',
               'colaborador', c.nome, 'matricula', c.matricula, 'departamento', c.departamento,
               'jornada', d.jornada, 'horario_previsto', d.horario_previsto,
               'previsto', case when pv.flex and p.hora is null then 'Flexível' else to_char(p.hora, 'HH24:MI') end,
               'diferenca_min', p.dif,
               'ausencia', d.ausencia,
               'obs_dia', d.obs_dia,
               'situacao',
                 case when b.status <> 'valida'  then 'desconsiderada'
                      -- Sem controle de ponto (ou antes do início do controle): registrada, mas não apurada
                      when not c.controla_ponto
                        or b.data_referencia < greatest(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao))
                        then 'nao_controlada'
                      -- Feriado e folga aparecem sempre (mesmo com o turno aberto ou incompleto)
                      when d.jornada_id is not null and d.feriado then 'feriado'
                      when d.jornada_id is not null and d.ausencia is null
                           and (coalesce(d.folga, true) or d.entrada is null) then 'folga'
                      -- Turno só existe com entrada e saída: batida sem o par não é apurada
                      when not par.tem and b.sentido = 'E' and b.data_referencia >= fn_hoje() then 'turno_aberto'
                      when not par.tem           then 'turno_incompleto'
                      when d.jornada_id is null  then 'sem_jornada'
                      when d.ausencia is not null then 'ausencia'
                      -- Intervalo flexível: a saída vale em qualquer horário; o retorno é comparado com a duração
                      when pv.flex and b.sentido = 'S' then 'intervalo_flexivel'
                      when pv.flex and p.hora is null then 'intervalo_flexivel'
                      when pv.flex and p.dif >  d.tol_e then 'intervalo_excedido'
                      when pv.flex and p.dif < -d.tol_e then 'intervalo_reduzido'
                      when p.hora is null        then 'fora_jornada'
                      when p.dif = 0             then 'precisa'
                      when b.sentido = 'E' and p.dif >  d.tol_e then 'atraso'
                      when b.sentido = 'E' and p.dif < -d.tol_e then 'antecipada'
                      when b.sentido = 'E'                       then 'entrada_tolerancia'
                      when p.dif < -d.tol_s                      then 'saida_antecipada'
                      when p.dif >  d.tol_s                      then 'apos_previsto'
                      else 'saida_tolerancia' end) as linha
        from bat b
        join colab c               on c.id = b.colaborador_id
        left join dia d            on d.colaborador_id = b.colaborador_id and d.data = b.data_referencia
        left join motivos_batida m on m.id = b.motivo_id
        left join prev pv          on b.status = 'valida' and pv.colaborador_id = b.colaborador_id
                                  and pv.data = b.data_referencia and pv.sentido = b.sentido and pv.turno = b.turno
        -- par do turno: a saída da entrada (ou a entrada da saída)
        cross join lateral (
          select exists (select 1 from bat o
                          where o.status = 'valida' and o.id <> b.id
                            and o.colaborador_id = b.colaborador_id and o.data_referencia = b.data_referencia
                            and o.turno = b.turno and o.sentido <> b.sentido) as tem
        ) par
        -- Intervalo flexível: retorno previsto = saída real para o intervalo (S1) + a duração do intervalo
        left join lateral (
          select min(date_trunc('minute', o.local))
                 + make_interval(mins => fn_minutos(d.saida_intervalo, d.retorno_intervalo)) as ts
            from bat o
           where pv.flex and b.sentido = 'E' and b.turno = 2
             and o.colaborador_id = b.colaborador_id and o.data_referencia = b.data_referencia
             and o.sentido = 'S' and o.turno = 1
        ) rf on true
        -- horário previsto da marcação e a diferença (em minutos) da batida para ele
        cross join lateral (
          select case when pv.flex then rf.ts::time else pv.hora end as hora,
                 (extract(epoch from date_trunc('minute', b.local)
                                     - case when pv.flex then rf.ts else pv.ts end) / 60)::int as dif
        ) p
      union all
      -- Marcações previstas sem batida válida correspondente
      select c.nome, pv.ts,
             jsonb_build_object(
               'tipo', 'prevista',
               'id', c.id || ':' || pv.data || ':' || pv.sentido || pv.turno,
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', c.departamento,
               'data', pv.data, 'data_referencia', pv.data,
               'jornada', d.jornada, 'horario_previsto', d.horario_previsto,
               'sentido', pv.sentido, 'turno', pv.turno,
               'previsto', case when pv.flex then 'Flexível' else to_char(pv.hora, 'HH24:MI') end,
               'obs_dia', d.obs_dia,
               'situacao', case when (case when pv.flex then pv.ts_saida else pv.ts end) > v_agora then 'pendente'
                                else 'nao_registrada' end)
        from prev pv
        join colab c on c.id = pv.colaborador_id
        join dia d   on d.colaborador_id = pv.colaborador_id and d.data = pv.data
       where not d.feriado and d.ausencia is null
         and not exists (select 1 from bat b
                          where b.status = 'valida' and b.colaborador_id = pv.colaborador_id
                            and b.data_referencia = pv.data and b.sentido = pv.sentido and b.turno = pv.turno)
      union all
      -- Dias de ausência (férias, afastamento…) ou feriado sem batidas: uma linha com a observação
      select c.nome, d.data::timestamp,
             jsonb_build_object(
               'tipo', 'dia',
               'id', c.id || ':' || d.data,
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', c.departamento,
               'data', d.data, 'data_referencia', d.data,
               'jornada', d.jornada, 'horario_previsto', d.horario_previsto,
               'ausencia', d.ausencia,
               'obs_dia', d.obs_dia,
               'situacao', case when d.ausencia is not null then 'dia_ausencia' else 'dia_feriado' end)
        from dia d
        join colab c on c.id = d.colaborador_id
       where d.obs_dia is not null
         and not exists (select 1 from bat b
                          where b.status = 'valida' and b.colaborador_id = d.colaborador_id and b.data_referencia = d.data)
    )
    select jsonb_agg(l.linha order by l.nome, l.linha ->> 'colaborador_id', l.linha ->> 'data_referencia', l.ordem)
      from linhas l
  ), '[]'::jsonb);
end $$;

create or replace function api_batida_historico(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth_tratamento_leitura(p_token);
  perform fn_exigir_visivel((select colaborador_id from batidas where id = p_id));
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'acao', a.acao, 'valor_anterior', a.valor_anterior, 'valor_novo', a.valor_novo,
             'justificativa', a.justificativa, 'motivo', m.descricao, 'dados', a.dados,
             'usuario', u.nome, 'created_at', a.created_at) order by a.created_at desc)
      from batida_ajustes a
      left join usuarios u       on u.id = a.usuario_id
      left join motivos_batida m on m.id = a.motivo_id
     where a.batida_id = p_id), '[]'::jsonb);
end $$;

-- -----------------------------------------------------------------------------
-- Ações
-- -----------------------------------------------------------------------------
drop function if exists api_batida_incluir(text, uuid, date, text, uuid, text, date, text);
-- Marcações previstas do dia (E1, S1, E2, S2) com a batida que já ocupa cada uma, e a sugestão
-- para a inclusão: a primeira marcação prevista ainda sem batida. Intervalo flexível: o retorno
-- previsto é a saída real para o intervalo + a duração do intervalo.
create or replace function api_batida_sugestao(p_token text, p_colaborador uuid, p_data date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_tz  text := fn_fuso();
  jd    record;
  v_prev jsonb := '[]'::jsonb;
  v_sug  jsonb;
  v_s1   time;
  r      record;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  if p_colaborador is null or p_data is null then return jsonb_build_object('previstas', '[]'::jsonb, 'sugestao', null); end if;
  perform fn_exigir_visivel(p_colaborador);
  select * into jd from fn_jornada_dia(p_colaborador, p_data);
  if not found or coalesce(jd.folga, true) or jd.entrada is null then
    return jsonb_build_object('previstas', '[]'::jsonb, 'sugestao', null,
                              'folga', coalesce(jd.folga, true));
  end if;
  -- Feriado sem escala de trabalho: nada previsto para sugerir
  if fn_feriado_dia(p_colaborador, p_data) then
    return jsonb_build_object('previstas', '[]'::jsonb, 'sugestao', null, 'folga', false, 'feriado', true);
  end if;

  drop table if exists pg_temp._sug_bat;
  create temp table _sug_bat on commit drop as
    select b.sentido, b.turno, to_char(b.data_hora at time zone v_tz, 'HH24:MI') as hora
      from fn_batidas_periodo(p_data, p_data, p_colaborador) b
     where b.status = 'valida' and b.data_referencia = p_data;
  select min(hora)::time into v_s1 from _sug_bat where sentido = 'S' and turno = 1;

  for r in
    select v.o, v.s, v.t,
           case when v.s = 'E' and v.t = 2 and jd.intervalo_flexivel and v_s1 is not null
                then v_s1 + (jd.retorno_intervalo - jd.saida_intervalo) else v.h end as h
      from (values (1, 'E', 1, jd.entrada),
                   (2, 'S', 1, coalesce(jd.saida_intervalo, jd.saida)),
                   (3, 'E', 2, jd.retorno_intervalo),
                   (4, 'S', 2, case when jd.saida_intervalo is not null then jd.saida end)) v(o, s, t, h)
     where v.h is not null
     order by v.o
  loop
    v_prev := v_prev || jsonb_build_object(
      'sigla', r.s || r.t, 'hora', to_char(r.h, 'HH24:MI'),
      'batida', (select min(hora) from _sug_bat b where b.sentido = r.s and b.turno = r.t));
    if v_sug is null and not exists (select 1 from _sug_bat b where b.sentido = r.s and b.turno = r.t) then
      v_sug := jsonb_build_object('sigla', r.s || r.t, 'hora', to_char(r.h, 'HH24:MI'));
    end if;
  end loop;
  return jsonb_build_object('previstas', v_prev, 'sugestao', v_sug, 'folga', false);
end $$;

create or replace function api_batida_incluir(
  p_token text, p_colaborador uuid, p_data date, p_hora text, p_motivo uuid,
  p_observacao text default null, p_data_referencia date default null, p_sentido text default null,
  p_turno integer default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_motivo text;
  v_dh     timestamptz;
  v_bat    batidas%rowtype;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  if not exists (select 1 from colaboradores where id = p_colaborador) then
    raise exception 'Selecione o empregado.';
  end if;
  perform fn_exigir_visivel(p_colaborador);
  v_motivo := fn_motivo_valido(p_motivo, 'inclusao');
  v_dh := fn_data_hora_local(p_data, p_hora);

  if v_dh > now() + interval '1 minute' then
    raise exception 'Não é possível incluir batida em horário futuro.';
  end if;
  if p_data_referencia is not null and abs(p_data_referencia - p_data) > 1 then
    raise exception 'A data de referência deve ser o dia da batida, o anterior ou o seguinte.';
  end if;
  if coalesce(p_sentido, 'E') not in ('E', 'S') then
    raise exception 'Sentido inválido.';
  end if;
  if p_turno is not null and (p_turno not between 1 and 9 or p_sentido is null) then
    raise exception 'Classificação inválida.';
  end if;
  if exists (select 1 from batidas where colaborador_id = p_colaborador and status = 'valida'
              and date_trunc('minute', data_hora) = date_trunc('minute', v_dh)) then
    raise exception 'Já existe uma batida válida deste empregado neste horário.';
  end if;

  insert into batidas (colaborador_id, data_hora, data_referencia, origem, justificativa,
                       motivo_id, observacao, sentido, turno, usuario_id)
  values (p_colaborador, v_dh, p_data_referencia, 'manual',
          v_motivo || coalesce(' — ' || nullif(trim(p_observacao), ''), ''),
          p_motivo, nullif(trim(p_observacao), ''), p_sentido, p_turno,
          nullif(current_setting('app.usuario_id', true), '')::uuid)
  returning * into v_bat;

  perform fn_batida_auditar(v_bat, 'inclusao', null, v_dh, p_motivo, nullif(trim(p_observacao), ''));
  return jsonb_build_object('id', v_bat.id);
end $$;

-- Inclusão de batidas em lote: para cada colaborador e dia do período sem nenhuma batida, inclui as
-- marcações previstas da jornada (ou da escala do dia) com uma variação aleatória de até X minutos,
-- para que as batidas não fiquem idênticas ao horário previsto. Pula folgas, feriados, dias com
-- ocorrência/afastamento de dia inteiro, períodos fechados e horários futuros.
-- p_dados: { colaboradores: [uuid], data_inicio, data_fim, variacao_min, motivo_id, observacao?, simular? }
create or replace function api_batidas_lote(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d        jsonb := p_dados;
  v_ini    date := fn_txt(d, 'data_inicio')::date;
  v_fim    date := fn_txt(d, 'data_fim')::date;
  v_var    integer := coalesce(fn_txt(d, 'variacao_min')::integer, 0);
  v_motivo uuid := nullif(d ->> 'motivo_id', '')::uuid;
  v_simular boolean := coalesce((d ->> 'simular')::boolean, false);
  v_obs    text := nullif(trim(coalesce(d ->> 'observacao', '')), '');
  v_txt    text;
  v_colabs uuid[];
  c        uuid;
  v_dia    date;
  jd       record;
  m        record;
  v_dh     timestamptz;
  v_ant    timestamptz;
  v_bat    batidas%rowtype;
  v_dias   integer := 0;
  v_qtd    integer := 0;
  v_pulos  jsonb := jsonb_build_object('com_batidas', 0, 'sem_previsao', 0, 'feriado', 0, 'ausencia', 0, 'fechado', 0, 'futuro', 0);
  v_motivo_pulo text;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  if v_ini is null or v_fim is null or v_fim < v_ini then raise exception 'Informe um período válido.'; end if;
  if v_fim - v_ini > 30 then raise exception 'Selecione um período de até 31 dias.'; end if;
  if v_fim >= fn_hoje() then v_fim := fn_hoje(); end if;
  if v_var not between 0 and 30 then raise exception 'A variação deve ficar entre 0 e 30 minutos.'; end if;
  v_txt := fn_motivo_valido(v_motivo, 'inclusao');
  select array_agg(distinct x::uuid) into v_colabs
    from jsonb_array_elements_text(case when jsonb_typeof(d -> 'colaboradores') = 'array' then d -> 'colaboradores' else '[]'::jsonb end) x;
  if coalesce(array_length(v_colabs, 1), 0) = 0 then raise exception 'Selecione ao menos um colaborador.'; end if;
  foreach c in array v_colabs loop perform fn_exigir_visivel(c); end loop;

  foreach c in array v_colabs loop
    for v_dia in select g::date from generate_series(v_ini, v_fim, interval '1 day') g loop
      v_motivo_pulo := null;
      select * into jd from fn_jornada_dia(c, v_dia);
      if exists (select 1 from batidas b where b.colaborador_id = c and b.data_referencia = v_dia and b.status = 'valida') then
        v_motivo_pulo := 'com_batidas';
      elsif not found or coalesce(jd.folga, true) or jd.entrada is null or jd.saida is null then
        v_motivo_pulo := 'sem_previsao';
      elsif jd.escala is distinct from 'trabalho' and exists (select 1 from feriados f where f.data = v_dia) then
        v_motivo_pulo := 'feriado';
      elsif exists (select 1 from ausencias a where a.colaborador_id = c and v_dia between a.data_inicio and a.data_fim
                       and a.minutos is null) then
        v_motivo_pulo := 'ausencia';
      elsif fn_periodo_fechado(v_dia, c) then
        v_motivo_pulo := 'fechado';
      elsif fn_data_hora_local(v_dia + case when jd.saida <= jd.entrada then 1 else 0 end, to_char(jd.saida, 'HH24:MI'))
            + make_interval(mins => v_var) > now()
            or exists (select 1 from colaboradores x where x.id = c
                         and (v_dia < fn_inicio_controle(x) or (x.data_desligamento is not null and v_dia > x.data_desligamento))) then
        v_motivo_pulo := 'futuro';
      end if;
      if v_motivo_pulo is not null then
        v_pulos := jsonb_set(v_pulos, array[v_motivo_pulo], to_jsonb((v_pulos ->> v_motivo_pulo)::int + 1));
        continue;
      end if;

      v_dias := v_dias + 1;
      v_ant := null;
      for m in
        select v.o, v.s, v.t, v.h
          from (values (1, 'E', 1, jd.entrada),
                       (2, 'S', 1, coalesce(jd.saida_intervalo, jd.saida)),
                       (3, 'E', 2, jd.retorno_intervalo),
                       (4, 'S', 2, case when jd.saida_intervalo is not null then jd.saida end)) v(o, s, t, h)
         where v.h is not null
         order by v.o
      loop
        v_dh := fn_data_hora_local(v_dia + case when m.h < jd.entrada then 1 else 0 end, to_char(m.h, 'HH24:MI'))
                + make_interval(mins => round((random() * 2 - 1) * v_var)::int);
        -- Mantém a ordem das marcações (a variação não inverte saída e retorno)
        if v_ant is not null and v_dh <= v_ant then v_dh := v_ant + interval '1 minute'; end if;
        v_ant := v_dh;
        v_qtd := v_qtd + 1;
        if not v_simular then
          insert into batidas (colaborador_id, data_hora, data_referencia, origem, justificativa,
                               motivo_id, observacao, usuario_id)
          values (c, v_dh, v_dia, 'manual', v_txt || ' — Inclusão em lote' || coalesce(' — ' || v_obs, ''),
                  v_motivo, coalesce(v_obs, 'Inclusão em lote'), nullif(current_setting('app.usuario_id', true), '')::uuid)
          returning * into v_bat;
          perform fn_batida_auditar(v_bat, 'inclusao', null, v_dh, v_motivo, coalesce(v_obs, 'Inclusão em lote'));
        end if;
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('dias', v_dias, 'batidas', v_qtd, 'pulados', v_pulos, 'simulado', v_simular);
end $$;

create or replace function api_batida_editar(
  p_token text, p_id uuid, p_data date, p_hora text, p_motivo uuid, p_observacao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_old    batidas%rowtype;
  v_new    batidas%rowtype;
  v_motivo text;
  v_dh     timestamptz;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  select * into v_old from batidas where id = p_id for update;
  if not found then raise exception 'Batida não encontrada.'; end if;
  perform fn_exigir_visivel(v_old.colaborador_id);
  if v_old.origem <> 'manual' then
    raise exception 'Batidas originais não podem ser editadas. Use "Desconsiderar" ou os ajustes de sentido e data de referência.';
  end if;

  v_motivo := fn_motivo_valido(p_motivo, 'inclusao');
  v_dh := fn_data_hora_local(p_data, p_hora);
  if v_dh > now() + interval '1 minute' then
    raise exception 'Não é possível lançar batida em horário futuro.';
  end if;
  if exists (select 1 from batidas where colaborador_id = v_old.colaborador_id and status = 'valida'
              and id <> p_id and date_trunc('minute', data_hora) = date_trunc('minute', v_dh)) then
    raise exception 'Já existe uma batida válida deste empregado neste horário.';
  end if;

  update batidas set
    data_hora = v_dh,
    motivo_id = p_motivo,
    observacao = nullif(trim(p_observacao), ''),
    justificativa = v_motivo || coalesce(' — ' || nullif(trim(p_observacao), ''), '')
  where id = p_id
  returning * into v_new;

  perform fn_batida_auditar(v_new, 'alteracao', v_old.data_hora, v_dh, p_motivo, nullif(trim(p_observacao), ''));
  return jsonb_build_object('id', p_id);
end $$;

create or replace function api_batida_excluir(p_token text, p_id uuid, p_observacao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_old batidas%rowtype;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  select * into v_old from batidas where id = p_id for update;
  if not found then raise exception 'Batida não encontrada.'; end if;
  perform fn_exigir_visivel(v_old.colaborador_id);
  if v_old.origem <> 'manual' then
    raise exception 'Batidas originais não podem ser excluídas. Use "Desconsiderar".';
  end if;

  perform fn_batida_auditar(v_old, 'exclusao', v_old.data_hora, null, v_old.motivo_id,
                            nullif(trim(p_observacao), ''), to_jsonb(v_old));
  delete from batidas where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function api_batida_desconsiderar(p_token text, p_id uuid, p_motivo uuid default null, p_observacao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_old    batidas%rowtype;
  v_new    batidas%rowtype;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  perform fn_motivo_valido(p_motivo, 'desconsideracao');
  select * into v_old from batidas where id = p_id for update;
  if not found then raise exception 'Batida não encontrada.'; end if;
  perform fn_exigir_visivel(v_old.colaborador_id);
  if v_old.status = 'desconsiderada' then raise exception 'Esta batida já está desconsiderada.'; end if;

  update batidas set status = 'desconsiderada', motivo_id = p_motivo,
                     observacao = nullif(trim(p_observacao), '')
   where id = p_id
  returning * into v_new;

  perform fn_batida_auditar(v_new, 'desconsideracao', v_old.data_hora, null, p_motivo, nullif(trim(p_observacao), ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function api_batida_reconsiderar(p_token text, p_id uuid, p_observacao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_new batidas%rowtype;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  update batidas set status = 'valida' where id = p_id and status = 'desconsiderada' and fn_visivel(colaborador_id)
  returning * into v_new;
  if not found then raise exception 'A batida não está desconsiderada.'; end if;

  perform fn_batida_auditar(v_new, 'reconsideracao', null, v_new.data_hora, null, nullif(trim(p_observacao), ''));
  return jsonb_build_object('ok', true);
end $$;

-- Declarar sentido: 'E' (entrada), 'S' (saída) ou null (volta à alternância automática)
create or replace function api_batida_sentido(p_token text, p_id uuid, p_sentido text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_old batidas%rowtype;
  v_new batidas%rowtype;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  if p_sentido is not null and p_sentido not in ('E', 'S') then
    raise exception 'Sentido inválido.';
  end if;
  select * into v_old from batidas where id = p_id for update;
  if not found then raise exception 'Batida não encontrada.'; end if;

  perform fn_exigir_visivel(v_old.colaborador_id);
  update batidas set sentido = p_sentido where id = p_id returning * into v_new;
  perform fn_batida_auditar(v_new, 'sentido', null, null, null, null,
                            jsonb_build_object('de', v_old.sentido, 'para', p_sentido));
  return jsonb_build_object('ok', true);
end $$;

-- Classifica a batida: entrada/saída e turno (1º, 2º, 3º…). Nulos = volta ao automático.
-- Só quem trata o ponto pode classificar; o colaborador apenas registra.
create or replace function api_batida_classificar(p_token text, p_id uuid, p_sentido text, p_turno integer)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_old batidas%rowtype;
  v_new batidas%rowtype;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  if p_sentido is not null and p_sentido not in ('E', 'S') then raise exception 'Sentido inválido.'; end if;
  if p_turno is not null and (p_turno not between 1 and 9 or p_sentido is null) then
    raise exception 'Classificação inválida.';
  end if;
  select * into v_old from batidas where id = p_id for update;
  if not found then raise exception 'Batida não encontrada.'; end if;
  perform fn_exigir_visivel(v_old.colaborador_id);
  if v_old.status = 'desconsiderada' then raise exception 'Batidas desconsideradas não são classificadas.'; end if;

  update batidas set sentido = p_sentido, turno = p_turno where id = p_id returning * into v_new;
  perform fn_batida_auditar(v_new, 'sentido', null, null, null, null, jsonb_build_object(
    'de',   case when v_old.sentido is null then null
                 when v_old.turno is null then case v_old.sentido when 'E' then 'Entrada' else 'Saída' end
                 else fn_rotulo_batida(v_old.sentido, v_old.turno) end,
    'para', case when p_sentido is null then null else fn_rotulo_batida(p_sentido, p_turno) end));
  return jsonb_build_object('ok', true);
end $$;

-- Reatribui a batida a outro dia de trabalho (ex.: turno que vira a noite)
create or replace function api_batida_data_referencia(p_token text, p_id uuid, p_data date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_old batidas%rowtype;
  v_new batidas%rowtype;
  v_dia date;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  select * into v_old from batidas where id = p_id for update;
  if not found then raise exception 'Batida não encontrada.'; end if;

  perform fn_exigir_visivel(v_old.colaborador_id);
  v_dia := (v_old.data_hora at time zone fn_fuso())::date;
  if p_data is null or abs(p_data - v_dia) > 1 then
    raise exception 'A data de referência deve ser o dia da batida, o anterior ou o seguinte.';
  end if;

  update batidas set data_referencia = p_data where id = p_id returning * into v_new;
  perform fn_batida_auditar(v_new, 'data_referencia', null, null, null, null,
                            jsonb_build_object('de', v_old.data_referencia, 'para', p_data));
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
revoke execute on function fn_pode(uuid, text, boolean)                       from public, anon, authenticated;
revoke execute on function fn_auth_tratamento_leitura(text)                   from public, anon, authenticated;
revoke execute on function fn_exigir_visivel(uuid)                            from public, anon, authenticated;
revoke execute on function fn_status_batida(origem_batida, status_batida)     from public, anon, authenticated;
revoke execute on function fn_batidas_periodo(date, date, uuid)               from public, anon, authenticated;
revoke execute on function fn_batida_json(record, text)                       from public, anon, authenticated;
revoke execute on function fn_batida_auditar(batidas, text, timestamptz, timestamptz, uuid, text, jsonb)
                                                                              from public, anon, authenticated;
revoke execute on function fn_motivo_valido(uuid, text)                       from public, anon, authenticated;
revoke execute on function fn_data_hora_local(date, text)                     from public, anon, authenticated;

grant execute on function api_tratamento_auxiliares(text)                                   to anon, authenticated;
grant execute on function api_tratamento_batidas(text, date, date, uuid, uuid, text, uuid[])        to anon, authenticated;
grant execute on function api_consulta_batidas(text, date, date, uuid, uuid, uuid, uuid, uuid[])    to anon, authenticated;
grant execute on function api_batida_historico(text, uuid)                                  to anon, authenticated;
grant execute on function api_batida_incluir(text, uuid, date, text, uuid, text, date, text, integer) to anon, authenticated;
grant execute on function api_batida_sugestao(text, uuid, date) to anon, authenticated;
grant execute on function api_batidas_lote(text, jsonb)          to anon, authenticated;
grant execute on function api_batida_classificar(text, uuid, text, integer)                  to anon, authenticated;
grant execute on function api_batida_editar(text, uuid, date, text, uuid, text)             to anon, authenticated;
grant execute on function api_batida_excluir(text, uuid, text)                              to anon, authenticated;
grant execute on function api_batida_desconsiderar(text, uuid, uuid, text)                  to anon, authenticated;
grant execute on function api_batida_reconsiderar(text, uuid, text)                         to anon, authenticated;
grant execute on function api_batida_sentido(text, uuid, text)                              to anon, authenticated;
grant execute on function api_batida_data_referencia(text, uuid, date)                      to anon, authenticated;

-- Atualiza o cache de funções da API do Supabase (PostgREST)
notify pgrst, 'reload schema';
