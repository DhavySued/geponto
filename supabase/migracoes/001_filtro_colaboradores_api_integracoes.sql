-- =============================================================================
-- GePonto: atualização 001
-- Filtro de vários colaboradores nas pesquisas + API de integrações (chaves de acesso, v1)
-- Requer: atualização de várias empresas (empresas, configurações) já aplicada.
-- Pode ser executado mais de uma vez.
-- =============================================================================

-- ---------- Filtro de vários colaboradores ----------
-- Filtro de colaborador das pesquisas: um (p_um) e/ou vários (p_varios). Vazio = todos.
create or replace function fn_filtro_colaborador(p_id uuid, p_um uuid, p_varios uuid[])
returns boolean language sql immutable as $$
  select (p_um is null or p_id = p_um)
     and (p_varios is null or cardinality(p_varios) = 0 or p_id = any(p_varios));
$$;

drop function if exists api_banco_horas_detalhe(text, date, date, uuid);
create or replace function api_banco_horas_detalhe(p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_colaboradores uuid[] default null)
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
     where fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
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

  -- Marcações previstas dos dias com previsão (feriado, folga e abono não têm).
  -- Intervalo flexível: a saída para o intervalo prevista é a real, e o retorno previsto é ela + a duração.
  drop table if exists pg_temp._bh_prev;
  create temp table _bh_prev on commit drop as
    select x.colaborador_id, x.data, x.sentido, x.turno,
           case when x.flex and x.s1 is not null then x.ts_flex::time else x.hora end as hora,
           case when x.flex and x.s1 is not null then x.ts_flex else x.ts end as ts
      from (
    select a.colaborador_id, a.data, v.sentido, v.turno, v.hora,
           a.data + v.hora + case when v.hora < jd.entrada then interval '1 day' else interval '0' end as ts,
           (jd.intervalo_flexivel and (v.sentido, v.turno) in (('S', 1), ('E', 2))) as flex,
           s1.local as s1,
           s1.local + case when v.sentido = 'E'
                           then make_interval(mins => fn_minutos(jd.saida_intervalo, jd.retorno_intervalo))
                           else interval '0' end as ts_flex
      from _bh_ap a
     cross join lateral fn_jornada_dia(a.colaborador_id, a.data) jd
      left join lateral (select min(b.local) as local from _bh_bat b
                          where jd.intervalo_flexivel and b.colaborador_id = a.colaborador_id and b.data = a.data
                            and b.sentido = 'S' and b.turno = 1) s1 on true
     cross join lateral (values ('E', 1, jd.entrada),
                                ('S', 1, coalesce(jd.saida_intervalo, jd.saida)),
                                ('E', 2, jd.retorno_intervalo),
                                ('S', 2, case when jd.saida_intervalo is not null then jd.saida end)) v(sentido, turno, hora)
     where a.previsto_min > 0 and v.hora is not null
      ) x;

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
                            'falta', a.falta,
                            'falta_folha', a.falta_folha,
                            'fechado', a.fechado,
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
grant execute on function api_banco_horas_detalhe(text, date, date, uuid, uuid[]) to anon, authenticated;

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
        left join perfis_eventos pe on pe.id = c.perfil_evento_id
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
       where not coalesce(d.folga, true) and d.entrada is not null and m.hora is not null
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
grant execute on function api_consulta_batidas(text, date, date, uuid, uuid, uuid, uuid, uuid[])    to anon, authenticated;

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
grant execute on function api_tratamento_batidas(text, date, date, uuid, uuid, text, uuid[])        to anon, authenticated;

drop function if exists api_escalas_grade(text, date, date, uuid, uuid);
create or replace function api_escalas_grade(
  p_token text, p_ini date, p_fim date, p_departamento uuid default null, p_colaborador uuid default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'escalas');
  if p_ini is null or p_fim is null or p_fim < p_ini then
    raise exception 'Informe um período válido.';
  end if;
  if p_fim - p_ini > 62 then
    raise exception 'Selecione um período de até 2 meses.';
  end if;

  return jsonb_build_object(
    'feriados', coalesce((select jsonb_agg(jsonb_build_object('data', f.data, 'descricao', f.descricao) order by f.data)
                            from feriados f where f.data between p_ini and p_fim), '[]'::jsonb),
    'fechado_ate', (select max(data_fim) from fechamentos),
    'colaboradores', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'departamento', d.nome,
               'jornada', (select j.nome from jornadas j where j.id = fn_jornada_vigente(c.id, p_fim)),
               'inicio', fn_inicio_controle(c), 'desligamento', c.data_desligamento,
               'dias', (
                 select jsonb_agg(jsonb_build_object(
                          'data', g::date,
                          -- padrão da jornada no dia (sem a escala)
                          'jornada_folga', coalesce(jd.folga, true),
                          'entrada', to_char(jd.entrada, 'HH24:MI'),
                          'saida_intervalo', to_char(jd.saida_intervalo, 'HH24:MI'),
                          'retorno_intervalo', to_char(jd.retorno_intervalo, 'HH24:MI'),
                          'saida', to_char(jd.saida, 'HH24:MI'),
                          'escala', case when e.id is not null then jsonb_build_object(
                                      'id', e.id, 'tipo', e.tipo,
                                      'entrada', to_char(e.entrada, 'HH24:MI'),
                                      'saida_intervalo', to_char(e.saida_intervalo, 'HH24:MI'),
                                      'retorno_intervalo', to_char(e.retorno_intervalo, 'HH24:MI'),
                                      'saida', to_char(e.saida, 'HH24:MI'),
                                      'observacao', e.observacao, 'usuario', u.nome) end)
                        order by g)
                   from generate_series(p_ini, p_fim, interval '1 day') g
                   left join jornadas j      on j.id = fn_jornada_vigente(c.id, g::date)
                   left join jornada_dias jd on jd.jornada_id = j.id
                                            and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, g::date)
                   left join escalas e       on e.colaborador_id = c.id and e.data = g::date
                   left join usuarios u      on u.id = e.usuario_id))
             order by c.nome)
        from colaboradores c
        left join departamentos d on d.id = c.departamento_id
       where c.controla_ponto
         and fn_visivel(c.id)
         and (c.data_desligamento is null or c.data_desligamento >= p_ini)
         and (p_departamento is null or c.departamento_id = p_departamento)
         and fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)), '[]'::jsonb));
end $$;
grant execute on function api_escalas_grade(text, date, date, uuid, uuid, uuid[])              to anon, authenticated;

drop function if exists api_espelho_ponto(text, date, date, uuid, uuid);
create or replace function api_espelho_ponto(
  p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_departamento uuid default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'espelho_ponto');
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;
  perform fn_banco_horas_atualizar();

  return jsonb_build_object(
    'empresa', fn_empresa_json(null),
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'emitido_em', now(),
    'emitido_por', (select nome from usuarios where id = v_usuario),
    'espelhos', coalesce((
      select jsonb_agg(fn_espelho_colaborador(c.id, p_ini, p_fim) order by c.nome)
        from colaboradores c
       where c.controla_ponto
         and fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)
         and fn_visivel(c.id)
         and fn_inicio_controle(c) <= p_fim
         and (c.data_desligamento is null or c.data_desligamento >= p_ini)), '[]'::jsonb));
end $$;
grant execute on function api_espelho_ponto(text, date, date, uuid, uuid, uuid[])              to anon, authenticated;

drop function if exists api_ocorrencias_listar(text, date, date, uuid, uuid, text);
create or replace function api_ocorrencias_listar(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null, p_tipo text default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'ocorrencias');
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula,
             'departamento', d.nome, 'tipo', a.tipo, 'data_inicio', a.data_inicio, 'data_fim', a.data_fim,
             'dias', a.data_fim - a.data_inicio + 1, 'abona', a.abona, 'minutos', a.minutos,
             'justificativa', a.justificativa, 'usuario', u.nome, 'created_at', a.created_at,
             'fechado', exists (select 1 from fechamentos f
                                 where f.data_inicio <= a.data_fim and f.data_fim >= a.data_inicio))
           order by a.data_inicio desc, c.nome)
      from ausencias a
      join colaboradores c      on c.id = a.colaborador_id
      left join departamentos d on d.id = c.departamento_id
      left join usuarios u      on u.id = a.usuario_id
     where a.data_inicio <= p_fim and a.data_fim >= p_ini
       and fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
       and (p_departamento is null or c.departamento_id = p_departamento)
       and (p_tipo is null or a.tipo::text = p_tipo)
       and fn_visivel(c.id)), '[]'::jsonb);
end $$;
grant execute on function api_ocorrencias_listar(text, date, date, uuid, uuid, text, uuid[])   to anon, authenticated;

drop function if exists api_quebra_regras(text, date, date, uuid, uuid);
create or replace function api_quebra_regras(
  p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_departamento uuid default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'quebra_regras');
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;

  return coalesce((
    select jsonb_agg(r order by r.nome, r.data, r.regra)
      from (
        select c.id as colaborador_id, c.nome, c.matricula, d.nome as departamento, a.data, q.regra, q.detalhe,
               q.minutos
          from fn_apuracao(p_ini, least(p_fim, fn_hoje() - 1)) a
          join colaboradores c      on c.id = a.colaborador_id
          left join departamentos d on d.id = c.departamento_id
          left join perfis_eventos j on j.id = c.perfil_evento_id   -- tolerâncias e limite de HE do perfil
          cross join lateral (values
            ('interjornada', a.interjornada_min is not null and a.qtd_batidas > 0 and a.interjornada_min < 660,
             'Descanso entre jornadas abaixo de 11h (CLT art. 66)', a.interjornada_min),
            ('intrajornada', a.trabalhado_min > 360 and coalesce(a.intervalo_min, 0) < 60 - coalesce(j.tolerancia_entrada_min, 0),
             'Jornada acima de 6h com intervalo menor que 1h (CLT art. 71)', coalesce(a.intervalo_min, 0)),
            ('intrajornada', a.trabalhado_min > 240 and a.trabalhado_min <= 360
                             and coalesce(a.intervalo_min, 0) < 15 - least(coalesce(j.tolerancia_entrada_min, 0), 5),
             'Jornada de 4h a 6h com intervalo menor que 15min (CLT art. 71 §1º)', coalesce(a.intervalo_min, 0)),
            -- Escalas com jornada prevista acima de 10h (12x36, CLT art. 59-A) só quebram se excederem o previsto
            ('jornada_maxima', a.trabalhado_min > greatest(600, a.previsto_min + coalesce(j.tolerancia_diaria_min, 0)),
             'Mais de 10h trabalhadas no dia (CLT art. 59)', a.trabalhado_min),
            ('limite_he', j.limite_he_diario_min > 0 and a.extra_min > j.limite_he_diario_min,
             'Horas extras acima do limite diário da regra de cálculo', a.extra_min),
            ('marcacao_impar', a.ocorrencia = 'inconsistente',
             'Marcação ímpar: entrada sem saída ou saída sem entrada', null::int)
          ) q(regra, violou, detalhe, minutos)
         where q.violou
           and fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
           and (p_departamento is null or c.departamento_id = p_departamento)
           and fn_visivel(c.id)
        union all
        -- Geolocalização: batida fora do raio do local de ponto ou sem localização (inclui hoje)
        select c.id, c.nome, c.matricula, d.nome, b.data_referencia,
               case b.geo_status when 'fora' then 'fora_local' else 'sem_localizacao' end,
               'Batida das ' || to_char(b.data_hora at time zone fn_fuso(), 'HH24:MI') ||
               case b.geo_status
                 when 'fora' then ' a ' || case when b.distancia_m < 1000 then b.distancia_m || ' m'
                                                else replace(to_char(b.distancia_m / 1000.0, 'FM9990.0'), '.', ',') || ' km' end
                                  || ' de ' || coalesce(l.nome, 'local de ponto')
                 else ' sem localização' || coalesce(' (' || lower(b.geo_erro) || ')', '') end,
               null::int
          from batidas b
          join colaboradores c      on c.id = b.colaborador_id
          left join departamentos d on d.id = c.departamento_id
          left join locais_ponto l  on l.id = b.local_id
         where b.data_referencia between p_ini and least(p_fim, fn_hoje())
           and b.status = 'valida'
           and b.geo_status in ('fora', 'sem_localizacao')
           and fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
           and (p_departamento is null or c.departamento_id = p_departamento)
           and fn_visivel(c.id)
      ) r), '[]'::jsonb);
end $$;
grant execute on function api_quebra_regras(text, date, date, uuid, uuid, uuid[])              to anon, authenticated;

drop function if exists api_totais_periodo(text, date, date, uuid, uuid);
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
                 -- DSR perdido: semanas (dom–sáb) com falta não justificada
                 count(distinct date_trunc('week', t.data + 1)) filter (where t.falta)            as dsr_perdidos,
                 coalesce(sum(t.saldo_min) filter (where t.banco_horas), 0)::int                   as bh_periodo_min,
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
grant execute on function api_totais_periodo(text, date, date, uuid, uuid, uuid[])             to anon, authenticated;

drop function if exists api_justificativas_listar(text, date, date, uuid, uuid, text);
create or replace function api_justificativas_listar(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null, p_situacao text default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_fim    date;
  v_itens  jsonb;
begin
  perform fn_auth(p_token, 'justificativas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 92 then raise exception 'Selecione um período de até 3 meses.'; end if;
  v_fim := least(p_fim, fn_hoje());

  drop table if exists pg_temp._jus_col;
  create temp table _jus_col on commit drop as
    select c.id, c.nome, c.matricula, d.nome as departamento
      from colaboradores c
      left join departamentos d on d.id = c.departamento_id
     where fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
       and (p_departamento is null or c.departamento_id = p_departamento)
       and fn_visivel(c.id);

  drop table if exists pg_temp._jus_ap;
  create temp table _jus_ap on commit drop as
    select a.colaborador_id, a.data, a.previsto_min, a.primeira_batida, a.fechado,
           a.atraso_bruto_min, a.saida_antecipada_bruta_min, a.falta_bruta
      from fn_apuracao(p_ini, greatest(v_fim, p_ini), p_colaborador) a
     where a.colaborador_id in (select id from _jus_col)
       and a.data <= v_fim;

  with ev as (
    select colaborador_id, data, 'atraso'::text as tipo, atraso_bruto_min as minutos, primeira_batida as hora, fechado
      from _jus_ap where atraso_bruto_min > 0
    union all
    select colaborador_id, data, 'saida_antecipada', saida_antecipada_bruta_min, null::time, fechado
      from _jus_ap where saida_antecipada_bruta_min > 0
    union all
    select colaborador_id, data, 'falta', previsto_min, null::time, fechado
      from _jus_ap where falta_bruta
  ),
  jus as (
    select j.* from justificativas j
     where j.data between p_ini and p_fim and j.colaborador_id in (select id from _jus_col)
  ),
  x as (
    select coalesce(ev.colaborador_id, j.colaborador_id) as colaborador_id,
           coalesce(ev.data, j.data) as data,
           coalesce(ev.tipo, j.tipo) as tipo,
           ev.minutos, ev.hora,
           ev.tipo is not null as ocorreu,
           coalesce(ev.fechado, fn_periodo_fechado(j.data)) as fechado,
           j.id as justificativa_id, j.motivo, j.abona, j.minutos as minutos_abono, j.observacao,
           j.usuario_id, j.updated_at
      from ev
      full join jus j on j.colaborador_id = ev.colaborador_id and j.data = ev.data and j.tipo = ev.tipo
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'colaborador_id', x.colaborador_id, 'colaborador', c.nome, 'matricula', c.matricula,
           'departamento', c.departamento, 'data', x.data, 'tipo', x.tipo,
           'minutos', coalesce(x.minutos, 0), 'hora', to_char(x.hora, 'HH24:MI'),
           'ocorreu', x.ocorreu, 'fechado', x.fechado,
           'justificativa', case when x.justificativa_id is null then null else jsonb_build_object(
              'id', x.justificativa_id, 'motivo', x.motivo, 'abona', x.abona, 'minutos', x.minutos_abono,
              'observacao', x.observacao, 'usuario', u.nome, 'atualizado_em', x.updated_at,
              'minutos_abonados', case when x.abona and x.ocorreu
                                       then least(coalesce(x.minutos_abono, x.minutos), x.minutos) else 0 end) end)
         order by x.data desc, c.nome, x.tipo), '[]'::jsonb)
    into v_itens
    from x
    join _jus_col c      on c.id = x.colaborador_id
    left join usuarios u on u.id = x.usuario_id
   where p_situacao is null
      or (p_situacao = 'pendentes'    and x.justificativa_id is null)
      or (p_situacao = 'justificadas' and x.justificativa_id is not null)
      or (p_situacao = 'abonadas'     and x.abona);

  return jsonb_build_object(
    'itens', v_itens,
    -- Motivos já usados (os mais frequentes primeiro), como sugestão na tela
    'motivos', coalesce((
      select jsonb_agg(m.motivo order by m.qtd desc, m.motivo)
        from (select motivo, count(*) as qtd from justificativas group by motivo
               order by count(*) desc, motivo limit 30) m), '[]'::jsonb));
end $$;
grant execute on function api_justificativas_listar(text, date, date, uuid, uuid, text, uuid[]) to anon, authenticated;

drop function if exists api_relatorio_locais_batidas(text, date, date, uuid, text, uuid, uuid);
create or replace function api_relatorio_locais_batidas(
  p_token text, p_ini date, p_fim date, p_local uuid default null, p_situacao text default null,
  p_colaborador uuid default null, p_departamento uuid default null, p_colaboradores uuid[] default null)
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
             and fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
             and (p_departamento is null or c.departamento_id = p_departamento)
             and fn_visivel(c.id)
           limit 5000
        ) x), '[]'::jsonb));
end $$;
grant execute on function api_relatorio_locais_batidas(text, date, date, uuid, text, uuid, uuid, uuid[]) to anon, authenticated;

-- ---------- Página Integrações (API) ----------
insert into paginas (chave, nome, grupo, ordem) values ('integracoes', 'Integrações (API)', 'Configurações', 94)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select p.id, 'integracoes', true, true from perfis p where p.nome = 'RH'
on conflict (perfil_id, pagina) do nothing;

-- ---------- API de integrações ----------
create table if not exists chaves_api (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  prefixo      text not null,                 -- início da chave, para identificar na lista
  chave_hash   text not null unique,
  empresa_id   uuid not null references empresas(id) on delete cascade,
  escopos      text[] not null default '{leitura}'
               check (escopos <@ array['leitura', 'batidas']::text[] and cardinality(escopos) > 0),
  ativo        boolean not null default true,
  ultimo_uso   timestamptz,
  criado_por   uuid references usuarios(id) on delete set null,
  created_at   timestamptz not null default now(),
  revogada_em  timestamptz
);
create index if not exists ix_chaves_api_empresa on chaves_api (empresa_id);

alter table chaves_api enable row level security;
revoke all on chaves_api from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Autenticação por chave: devolve a empresa e fixa app.empresa_id
-- -----------------------------------------------------------------------------
create or replace function fn_auth_chave(p_chave text, p_escopo text default 'leitura')
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_empresa uuid;
  v_escopos text[];
begin
  update chaves_api k
     set ultimo_uso = now()
    from empresas e
   where k.chave_hash = fn_hash_token(coalesce(p_chave, ''))
     and k.ativo
     and e.id = k.empresa_id
     and e.ativo
  returning k.empresa_id, k.escopos into v_empresa, v_escopos;

  if v_empresa is null then
    raise exception 'Chave de API inválida ou revogada.' using errcode = '28000';
  end if;
  if not (p_escopo = any(v_escopos)) then
    raise exception 'A chave não tem o escopo "%".', p_escopo using errcode = '42501';
  end if;

  perform set_config('app.empresa_id', v_empresa::text, true);
  return v_empresa;
end $$;

-- Período das consultas: obrigatório e de até 62 dias
create or replace function fn_v1_periodo(p_ini date, p_fim date)
returns void language plpgsql immutable as $$
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then
    raise exception 'Informe um período válido (inicio e fim, AAAA-MM-DD).' using errcode = '22023';
  end if;
  if p_fim - p_ini > 62 then
    raise exception 'O período máximo é de 62 dias.' using errcode = '22023';
  end if;
end $$;

-- Localiza o colaborador da empresa por id, matrícula, CPF ou PIS (só dígitos para CPF/PIS)
create or replace function fn_v1_colaborador(p_empresa uuid, p_item jsonb)
returns uuid language sql stable set search_path = public as $$
  select c.id from colaboradores c
   where c.empresa_id = p_empresa
     and (
       (p_item ? 'colaborador_id' and c.id::text = p_item ->> 'colaborador_id')
       or (p_item ? 'matricula' and c.matricula = trim(p_item ->> 'matricula'))
       or (p_item ? 'cpf' and regexp_replace(c.cpf, '\D', '', 'g') = regexp_replace(p_item ->> 'cpf', '\D', '', 'g'))
       or (p_item ? 'pis' and regexp_replace(coalesce(c.pis, ''), '\D', '', 'g') = regexp_replace(p_item ->> 'pis', '\D', '', 'g'))
     )
   limit 1;
$$;

-- -----------------------------------------------------------------------------
-- v1: leitura
-- -----------------------------------------------------------------------------
create or replace function api_v1_empresa(p_chave text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  return fn_empresa_json(fn_auth_chave(p_chave));
end $$;

create or replace function api_v1_colaboradores(
  p_chave text, p_situacao text default null, p_alterados_desde timestamptz default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_empresa uuid := fn_auth_chave(p_chave);
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'matricula', c.matricula, 'nome', c.nome, 'nome_social', c.nome_social,
             'cpf', c.cpf, 'pis', c.pis, 'email', c.email,
             'cargo', cg.nome, 'departamento', d.nome, 'jornada', j.nome,
             'data_admissao', c.data_admissao, 'data_desligamento', c.data_desligamento,
             'situacao', c.situacao, 'atualizado_em', c.updated_at)
           order by c.nome)
      from colaboradores c
      left join cargos cg       on cg.id = c.cargo_id
      left join departamentos d on d.id = c.departamento_id
      left join jornadas j      on j.id = c.jornada_id
     where c.empresa_id = v_empresa
       and (p_situacao is null or c.situacao::text = p_situacao)
       and (p_alterados_desde is null or c.updated_at >= p_alterados_desde)), '[]'::jsonb);
end $$;

create or replace function api_v1_batidas(
  p_chave text, p_inicio date, p_fim date, p_colaborador uuid default null, p_matricula text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_empresa uuid := fn_auth_chave(p_chave);
begin
  perform fn_v1_periodo(p_inicio, p_fim);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', b.id, 'colaborador_id', c.id, 'matricula', c.matricula, 'cpf', c.cpf, 'pis', c.pis,
             'data_hora', b.data_hora, 'data_referencia', b.data_referencia,
             'origem', b.origem, 'status', b.status, 'nsr', b.nsr,
             'latitude', b.latitude, 'longitude', b.longitude)
           order by c.matricula, b.data_hora)
      from batidas b
      join colaboradores c on c.id = b.colaborador_id
     where c.empresa_id = v_empresa
       and b.data_referencia between p_inicio and p_fim
       and (p_colaborador is null or c.id = p_colaborador)
       and (p_matricula is null or c.matricula = p_matricula)), '[]'::jsonb);
end $$;

-- Totais apurados por colaborador (o que vai para a folha), até ontem
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
                 count(distinct date_trunc('week', a.data + 1)) filter (where a.falta)         as dsr_perdidos,
                 coalesce(sum(a.saldo_min) filter (where a.banco_horas), 0)::int                as banco_horas_periodo_min,
                 count(*) filter (where a.ocorrencia = 'inconsistente')                         as dias_inconsistentes
            from fn_apuracao(p_inicio, v_ate) a
            join colaboradores c on c.id = a.colaborador_id
           where c.empresa_id = v_empresa
           group by c.id, c.matricula, c.nome, c.cpf, c.pis
        ) x), '[]'::jsonb));
end $$;

-- Saldo do banco de horas de cada colaborador em uma data (padrão: hoje)
create or replace function api_v1_banco_horas(p_chave text, p_data date default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_empresa uuid := fn_auth_chave(p_chave);
  v_data date := coalesce(p_data, fn_hoje());
begin
  perform fn_banco_horas_atualizar();
  return jsonb_build_object(
    'data', v_data,
    'colaboradores', coalesce((
      select jsonb_agg(jsonb_build_object('colaborador_id', c.id, 'matricula', c.matricula, 'nome', c.nome,
                                          'saldo_min', coalesce(s.saldo, 0)) order by c.matricula)
        from colaboradores c
        left join lateral (select sum(bh.minutos)::int saldo from banco_horas bh
                            where bh.colaborador_id = c.id and bh.data <= v_data) s on true
       where c.empresa_id = v_empresa and c.situacao <> 'desligado'), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- v1: importação de batidas (relógio/REP, app de terceiros)
-- Cada item: { matricula | cpf | pis | colaborador_id, data_hora (ISO 8601 com fuso), nsr?, latitude?, longitude? }
-- Repetidas (mesmo colaborador e horário, ou mesmo NSR) são ignoradas: reenviar é seguro.
-- -----------------------------------------------------------------------------
create or replace function api_v1_batidas_importar(p_chave text, p_batidas jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_empresa uuid := fn_auth_chave(p_chave, 'batidas');
  v_item jsonb;
  v_i int := 0;
  v_colab uuid;
  v_hora timestamptz;
  v_nsr bigint;
  v_importadas int := 0;
  v_repetidas int := 0;
  v_erros jsonb := '[]'::jsonb;
begin
  if jsonb_typeof(p_batidas) <> 'array' then
    raise exception 'Envie uma lista de batidas.' using errcode = '22023';
  end if;
  if jsonb_array_length(p_batidas) > 5000 then
    raise exception 'Envie no máximo 5000 batidas por chamada.' using errcode = '22023';
  end if;

  for v_item in select * from jsonb_array_elements(p_batidas) loop
    v_i := v_i + 1;
    begin
      v_colab := fn_v1_colaborador(v_empresa, v_item);
      if v_colab is null then
        raise exception 'Colaborador não encontrado nesta empresa.';
      end if;
      v_hora := (v_item ->> 'data_hora')::timestamptz;
      if v_hora is null then raise exception 'Informe data_hora.'; end if;
      if v_hora > now() + interval '5 minutes' then raise exception 'Batida no futuro.'; end if;
      v_nsr := nullif(v_item ->> 'nsr', '')::bigint;

      if exists (select 1 from batidas b
                  where b.colaborador_id = v_colab
                    and (b.data_hora = v_hora or (v_nsr is not null and b.nsr = v_nsr))) then
        v_repetidas := v_repetidas + 1;
        continue;
      end if;

      insert into batidas (colaborador_id, data_hora, origem, nsr, latitude, longitude)
      values (v_colab, v_hora, 'importacao', v_nsr,
              nullif(v_item ->> 'latitude', '')::numeric, nullif(v_item ->> 'longitude', '')::numeric);
      v_importadas := v_importadas + 1;
    exception when others then
      v_erros := v_erros || jsonb_build_object('indice', v_i - 1, 'erro', sqlerrm);
    end;
  end loop;

  return jsonb_build_object('recebidas', v_i, 'importadas', v_importadas, 'repetidas', v_repetidas, 'erros', v_erros);
end $$;

-- -----------------------------------------------------------------------------
-- Gestão das chaves (tela Configurações › Integrações)
-- -----------------------------------------------------------------------------
create or replace function api_chaves_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'integracoes');
  v_empresa uuid := coalesce(fn_empresa_atual(), fn_empresa_padrao());
begin
  return jsonb_build_object(
    'pode_editar', fn_pode(v_usuario, 'integracoes', true),
    'empresa', fn_empresa_json(v_empresa),
    'chaves', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', k.id, 'nome', k.nome, 'prefixo', k.prefixo, 'escopos', k.escopos, 'ativo', k.ativo,
               'ultimo_uso', k.ultimo_uso, 'criada_em', k.created_at, 'revogada_em', k.revogada_em,
               'criado_por', u.nome)
             order by k.ativo desc, k.created_at desc)
        from chaves_api k left join usuarios u on u.id = k.criado_por
       where k.empresa_id = v_empresa), '[]'::jsonb));
end $$;

create or replace function api_chave_criar(p_token text, p_nome text, p_escopos text[])
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_usuario uuid := fn_auth(p_token, 'integracoes', true);
  v_empresa uuid := coalesce(fn_empresa_atual(), fn_empresa_padrao());
  v_chave text := 'gp_' || encode(extensions.gen_random_bytes(24), 'hex');
  v_id uuid;
begin
  if coalesce(trim(p_nome), '') = '' then raise exception 'Dê um nome à chave (ex.: Folha de pagamento).'; end if;
  if p_escopos is null or cardinality(p_escopos) = 0 then raise exception 'Escolha ao menos uma permissão.'; end if;
  if not (p_escopos <@ array['leitura', 'batidas']) then raise exception 'Permissão inválida.'; end if;

  insert into chaves_api (nome, prefixo, chave_hash, empresa_id, escopos, criado_por)
  values (trim(p_nome), left(v_chave, 10), fn_hash_token(v_chave), v_empresa,
          array(select distinct unnest(p_escopos) order by 1), v_usuario)
  returning id into v_id;

  -- A chave completa só aparece aqui
  return jsonb_build_object('id', v_id, 'chave', v_chave);
end $$;

create or replace function api_chave_revogar(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'integracoes', true);
  update chaves_api set ativo = false, revogada_em = now()
   where id = p_id and empresa_id = coalesce(fn_empresa_atual(), fn_empresa_padrao()) and ativo;
  if not found then raise exception 'Chave não encontrada.'; end if;
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function fn_auth_chave(text, text)       from public, anon, authenticated;
revoke execute on function fn_v1_colaborador(uuid, jsonb)  from public, anon, authenticated;

grant execute on function api_v1_empresa(text)                                   to anon, authenticated;
grant execute on function api_v1_colaboradores(text, text, timestamptz)          to anon, authenticated;
grant execute on function api_v1_batidas(text, date, date, uuid, text)           to anon, authenticated;
grant execute on function api_v1_totais(text, date, date)                        to anon, authenticated;
grant execute on function api_v1_banco_horas(text, date)                         to anon, authenticated;
grant execute on function api_v1_batidas_importar(text, jsonb)                   to anon, authenticated;
grant execute on function api_chaves_listar(text)                                to anon, authenticated;
grant execute on function api_chave_criar(text, text, text[])                    to anon, authenticated;
grant execute on function api_chave_revogar(text, uuid)                          to anon, authenticated;

notify pgrst, 'reload schema';
