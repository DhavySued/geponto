-- =============================================================================
-- 015 · Feriado aparece como "Feriado", sem horário previsto (a não ser com escala de trabalho)
-- Requer: 014. Re-executável. Só exibição: não muda saldos.
-- =============================================================================

-- Feriado valendo para o colaborador no dia: não há previsão, a não ser com escala de trabalho lançada
create or replace function fn_feriado_dia(p_colaborador uuid, p_data date)
returns boolean language sql stable set search_path = public as $$
  select exists (select 1 from feriados f where f.data = p_data)
     and not exists (select 1 from escalas e where e.colaborador_id = p_colaborador and e.data = p_data and e.tipo = 'trabalho');
$$;

create or replace function fn_horario_dia(p_colaborador uuid, p_data date)
returns text language sql stable set search_path = public as $$
  select case when fn_feriado_dia(p_colaborador, p_data) then 'Feriado'
              when jd.folga or jd.entrada is null then null
              when jd.saida_intervalo is null
                then to_char(jd.entrada, 'HH24:MI') || '–' || to_char(jd.saida, 'HH24:MI')
              when jd.intervalo_flexivel
                then to_char(jd.entrada, 'HH24:MI') || '–' || to_char(jd.saida, 'HH24:MI')
                     || ' · intervalo flexível de ' || fn_minutos_texto(fn_minutos(jd.saida_intervalo, jd.retorno_intervalo))
              else to_char(jd.entrada, 'HH24:MI') || '–' || to_char(jd.saida_intervalo, 'HH24:MI')
                   || ' · ' || to_char(jd.retorno_intervalo, 'HH24:MI') || '–' || to_char(jd.saida, 'HH24:MI')
         end
    from fn_jornada_dia(p_colaborador, p_data) jd;
$$;

create or replace function api_dashboard(p_token text, p_ini date default null, p_fim date default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_hoje  date := fn_hoje();
  v_ini   date := coalesce(p_ini, date_trunc('month', fn_hoje())::date);
  v_fim   date := least(coalesce(p_fim, fn_hoje()), fn_hoje());
  v_agora time := (now() at time zone fn_fuso())::time;
  v_out   jsonb;
begin
  perform fn_auth(p_token, 'dashboard');
  perform fn_banco_horas_atualizar();

  if v_ini > v_fim then
    v_ini := v_fim;
  end if;

  drop table if exists pg_temp._ap;
  create temp table _ap on commit drop as
    select a.* from fn_apuracao(least(v_ini, v_hoje), greatest(v_fim, v_hoje)) a
      join colaboradores c on c.id = a.colaborador_id
     where c.situacao <> 'desligado' and fn_visivel(c.id);

  select jsonb_build_object(
    'periodo', jsonb_build_object('inicio', v_ini, 'fim', v_fim, 'hoje', v_hoje),

    'resumo', jsonb_build_object(
      'situacoes', (
        select jsonb_build_object(
          'ativo',     count(*) filter (where situacao = 'ativo'),
          'afastado',  count(*) filter (where situacao = 'afastado'),
          'ferias',    count(*) filter (where situacao = 'ferias'),
          'desligado', count(*) filter (where situacao = 'desligado'))
        from colaboradores where fn_visivel(id)),
      'hoje', (
        select jsonb_build_object(
          'previstos',  count(*) filter (where previsto_min > 0),
          'presentes',  count(*) filter (where qtd_batidas > 0),
          'ausentes',   count(*) filter (where previsto_min > 0 and qtd_batidas = 0),
          'atrasados',  count(*) filter (where atraso_min > 0),
          'batidas',    coalesce(sum(qtd_batidas), 0))
        from pg_temp._ap where data = v_hoje),
      'periodo', (
        select jsonb_build_object(
          'dias_previstos',  count(*) filter (where previsto_min > 0 and data < v_hoje),
          'faltas',          count(*) filter (where falta),
          'atrasos',         count(*) filter (where atraso_min > 0),
          'minutos_atraso',  coalesce(sum(atraso_min), 0),
          'absenteismo_pct', round(100.0 * count(*) filter (where falta)
                               / nullif(count(*) filter (where previsto_min > 0 and data < v_hoje), 0), 1))
        from pg_temp._ap where data between v_ini and v_fim),
      'banco_horas', (
        select jsonb_build_object(
          'saldo_positivo',  coalesce(sum(saldo) filter (where saldo > 0), 0),
          'saldo_negativo',  coalesce(sum(saldo) filter (where saldo < 0), 0),
          'qtd_positivos',   count(*) filter (where saldo > 0),
          'qtd_negativos',   count(*) filter (where saldo < 0))
        from (select sum(bh.minutos) as saldo
                from banco_horas bh
                join colaboradores c on c.id = bh.colaborador_id and c.situacao <> 'desligado'
               where bh.data <= v_fim and fn_visivel(c.id)
               group by bh.colaborador_id) s)
    ),

    'banco_horas', coalesce((
      select jsonb_agg(x order by x.saldo_minutos desc, x.nome)
        from (
          select c.id, c.nome, c.matricula, d.nome as departamento,
                 coalesce(sum(bh.minutos), 0)::int as saldo_minutos
            from colaboradores c
            left join departamentos d on d.id = c.departamento_id
            left join banco_horas bh  on bh.colaborador_id = c.id and bh.data <= v_fim
           where c.situacao <> 'desligado' and fn_visivel(c.id)
           group by c.id, c.nome, c.matricula, d.nome
        ) x), '[]'::jsonb),

    'absenteismo_diario', coalesce((
      select jsonb_agg(jsonb_build_object(
               'data', data, 'faltas', faltas, 'atrasos', atrasos, 'previstos', previstos) order by data)
        from (
          select data,
                 count(*) filter (where falta)          as faltas,
                 count(*) filter (where atraso_min > 0) as atrasos,
                 count(*) filter (where previsto_min > 0) as previstos
            from pg_temp._ap
           where data between v_ini and v_fim
           group by data
        ) g), '[]'::jsonb),

    'ranking_atrasos', coalesce((
      select jsonb_agg(r order by r.minutos desc)
        from (
          select c.id, c.nome, d.nome as departamento,
                 count(*) filter (where a.atraso_min > 0) as ocorrencias,
                 sum(a.atraso_min)::int as minutos,
                 count(*) filter (where a.falta) as faltas
            from pg_temp._ap a
            join colaboradores c on c.id = a.colaborador_id
            left join departamentos d on d.id = c.departamento_id
           where a.data between v_ini and v_fim
           group by c.id, c.nome, d.nome
          having sum(a.atraso_min) > 0 or count(*) filter (where a.falta) > 0
           order by sum(a.atraso_min) desc
           limit 5
        ) r), '[]'::jsonb),

    'registros_hoje', coalesce((
      select jsonb_agg(t order by t.ordem, t.nome)
        from (
          select c.id, c.nome, c.matricula, c.situacao,
                 d.nome as departamento, cg.nome as cargo,
                 a.feriado,
                 case when not a.feriado then to_char(jd.entrada, 'HH24:MI') end as entrada_prevista,
                 -- Marcações previstas do dia (E1, S1, E2, S2); no intervalo flexível, só a duração
                 case when a.previsto_min > 0 and jd.entrada is not null then
                   (select coalesce(jsonb_agg(jsonb_build_object('sigla', v.sigla, 'hora', to_char(v.hora, 'HH24:MI'))
                                              order by v.o), '[]'::jsonb)
                      from (values (1, 'E1', jd.entrada),
                                   (2, 'S1', case when not jd.intervalo_flexivel then jd.saida_intervalo end),
                                   (3, 'E2', case when not jd.intervalo_flexivel then jd.retorno_intervalo end),
                                   (4, case when jd.saida_intervalo is null then 'S1' else 'S2' end, jd.saida)) v(o, sigla, hora)
                     where v.hora is not null)
                 end as previstas,
                 case when jd.intervalo_flexivel and not a.feriado then fn_minutos(jd.saida_intervalo, jd.retorno_intervalo) end
                   as intervalo_flexivel_min,
                 a.atraso_min,
                 -- Saldo do banco de horas até hoje (lançamentos automáticos e manuais)
                 (select coalesce(sum(bh.minutos), 0)::int from banco_horas bh
                   where bh.colaborador_id = c.id and bh.data <= v_hoje) as saldo_banco_min,
                 a.banco_horas as usa_banco,
                 fn_batidas_json(c.id, v_hoje) as batidas,   -- definida em 06_api_ponto.sql
                 st.status,
                 case st.status
                   when 'ausente' then 0 when 'em_jornada' then 1 when 'em_intervalo' then 2
                   when 'aguardando' then 3 when 'finalizado' then 4 else 5 end as ordem
            from colaboradores c
            join pg_temp._ap a        on a.colaborador_id = c.id and a.data = v_hoje
            left join departamentos d on d.id = c.departamento_id
            left join cargos cg       on cg.id = c.cargo_id
            left join lateral fn_jornada_dia(c.id, v_hoje) jd on true
            cross join lateral (
              select case
                when c.situacao in ('ferias', 'afastado') then c.situacao::text
                when a.ocorrencia like 'ausencia:%' then 'ausencia'
                when a.previsto_min = 0 and a.qtd_batidas = 0 then 'folga'
                when a.qtd_batidas = 0 and v_agora > jd.entrada + make_interval(mins => coalesce(
                       (select case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min
                                    else pe.tolerancia_entrada_min end
                          from perfis_eventos pe where pe.id = c.perfil_evento_id), 0))
                  then 'ausente'
                when a.qtd_batidas = 0 then 'aguardando'
                when a.ultimo_sentido = 'E' then 'em_jornada'
                when a.qtd_batidas < case when jd.saida_intervalo is null then 2 else 4 end then 'em_intervalo'
                else 'finalizado' end as status
            ) st
           where c.situacao <> 'desligado'
        ) t), '[]'::jsonb)
  ) into v_out;

  return v_out;
end $$;

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
                 'feriado', case when fn_feriado_dia(c.id, v_hoje)
                                 then (select f.descricao from feriados f where f.data = v_hoje) end,
                 'folga', jd.folga,
                 'entrada', to_char(jd.entrada, 'HH24:MI'),
                 'saida_intervalo', to_char(jd.saida_intervalo, 'HH24:MI'),
                 'retorno_intervalo', to_char(jd.retorno_intervalo, 'HH24:MI'),
                 'saida', to_char(jd.saida, 'HH24:MI'),
                 'intervalo_flexivel', jd.intervalo_flexivel,
                 'intervalo_min', fn_minutos(jd.saida_intervalo, jd.retorno_intervalo))
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

revoke execute on function fn_feriado_dia(uuid, date) from public, anon, authenticated;

notify pgrst, 'reload schema';
