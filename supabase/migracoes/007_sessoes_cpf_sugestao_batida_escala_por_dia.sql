-- =============================================================================
-- GePonto: atualização 007
-- • Sessões abertas antes do acesso pelo CPF: quem não tem colaborador vinculado (exceto o
--   master) perde a sessão e precisa entrar de novo, pelo CPF
-- • Inclusão de batida já sugere o horário previsto da marcação que falta
-- • Escala: horário próprio para cada dia do período (ou folga em dias específicos)
-- Requer: atualização 006. Pode ser executado mais de uma vez.
-- =============================================================================

alter table escala_lancamentos add column if not exists horarios jsonb not null default '{}'::jsonb;

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
     and (u.master or u.colaborador_id is not null)   -- só o master entra sem colaborador (CPF)
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

-- [07_api_tratamento]
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

-- [08_api_fortes]
-- Confere um horário de escala de trabalho (entrada e saída obrigatórias, intervalo completo e por dentro)
create or replace function fn_escala_validar_horario(p_ent time, p_si time, p_ri time, p_sai time, p_quando text default '')
returns void language plpgsql immutable as $$
begin
  if p_ent is null or p_sai is null then raise exception 'Informe a entrada e a saída%.', p_quando; end if;
  if (p_si is null) <> (p_ri is null) then
    raise exception 'Informe a saída e o retorno do intervalo (ou deixe os dois em branco)%.', p_quando;
  end if;
  if p_ent = p_sai then raise exception 'A entrada e a saída não podem ser iguais%.', p_quando; end if;
  if p_si is not null and
     (fn_minutos(p_ent, p_si) + fn_minutos(p_si, p_ri) + fn_minutos(p_ri, p_sai) <> fn_minutos(p_ent, p_sai)
      or p_si = p_ent or p_ri = p_si or p_sai = p_ri) then
    raise exception 'Os horários do intervalo precisam ficar entre a entrada e a saída%.', p_quando;
  end if;
end $$;

-- [08_api_fortes]
create or replace function fn_escala_lancamento_json(l escala_lancamentos)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', l.id, 'nome', l.nome, 'tipo', l.tipo, 'data_inicio', l.data_inicio, 'data_fim', l.data_fim,
    'dias_semana', to_jsonb(l.dias_semana),
    'entrada', to_char(l.entrada, 'HH24:MI'), 'saida_intervalo', to_char(l.saida_intervalo, 'HH24:MI'),
    'retorno_intervalo', to_char(l.retorno_intervalo, 'HH24:MI'), 'saida', to_char(l.saida, 'HH24:MI'),
    'observacao', l.observacao, 'horarios', l.horarios,
    'colaboradores', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'matricula', c.matricula)
                                                order by c.nome)
                                 from colaboradores c where c.id = any(l.colaboradores) and fn_visivel(c.id)), '[]'::jsonb),
    'dias', (select count(*) from escalas e where e.lancamento_id = l.id),
    'fechado', exists (select 1 from escalas e where e.lancamento_id = l.id and fn_periodo_fechado(e.data)),
    'lancado_por', (select nome from usuarios where id = l.usuario_id), 'lancado_em', l.created_at,
    'alterado_por', (select nome from usuarios where id = l.alterado_por),
    'alterado_em', case when l.updated_at > l.created_at + interval '1 second' then l.updated_at end);
$$;

-- [08_api_fortes]
-- Cria ou altera uma escala.
-- p_dados: { id?, nome, tipo: 'trabalho'|'folga', data_inicio, data_fim, dias_semana: [0..6], colaboradores: [uuid],
--            entrada?, saida_intervalo?, retorno_intervalo?, saida?, observacao?,
--            horarios?: { "AAAA-MM-DD": { tipo, entrada?, saida_intervalo?, retorno_intervalo?, saida? } } }
create or replace function api_escala_lancamento_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'escalas', true);
  d         jsonb := p_dados;
  v_id      uuid := nullif(fn_txt(d, 'id'), '')::uuid;
  v_antigo  escala_lancamentos;
  v_nome    text := left(trim(coalesce(fn_txt(d, 'nome'), '')), 120);
  v_tipo    text := fn_txt(d, 'tipo');
  v_ini     date := fn_txt(d, 'data_inicio')::date;
  v_fim     date := fn_txt(d, 'data_fim')::date;
  v_dias    smallint[];
  v_colabs  uuid[];
  v_ent     time;
  v_si      time;
  v_ri      time;
  v_sai     time;
  v_datas   date[];
  v_conf    record;
  v_qtd     integer;
  v_hor     jsonb := '{}'::jsonb;
  v_dia     record;
begin
  if v_nome = '' then raise exception 'Dê um nome à escala (ex.: Plantão do feriado de novembro).'; end if;
  if v_tipo is null or v_tipo not in ('trabalho', 'folga') then raise exception 'Escolha se é escala de trabalho ou de folga.'; end if;
  if v_ini is null or v_fim is null or v_fim < v_ini then raise exception 'Informe o período da escala.'; end if;
  if v_fim - v_ini > 29 then raise exception 'A escala pode ter no máximo 30 dias. Para um período maior, lance outra escala.'; end if;

  select array_agg(distinct x::smallint order by x::smallint) into v_dias
    from jsonb_array_elements_text(case when jsonb_typeof(d -> 'dias_semana') = 'array' then d -> 'dias_semana' else '[]' end) x
   where x::int between 0 and 6;
  if coalesce(array_length(v_dias, 1), 0) = 0 then raise exception 'Marque ao menos um dia da semana.'; end if;

  select array_agg(distinct x::uuid) into v_colabs
    from jsonb_array_elements_text(case when jsonb_typeof(d -> 'colaboradores') = 'array' then d -> 'colaboradores' else '[]' end) x;
  if coalesce(array_length(v_colabs, 1), 0) = 0 then raise exception 'Selecione ao menos um colaborador.'; end if;
  if exists (select 1 from unnest(v_colabs) x where not fn_visivel(x)) then
    raise exception 'Há colaboradores fora da sua abrangência de acesso.' using errcode = '42501';
  end if;

  if v_id is not null then
    select * into v_antigo from escala_lancamentos where id = v_id for update;
    if v_antigo.id is null then raise exception 'Escala não encontrada.'; end if;
    -- Quem está na escala e fora da abrangência de quem altera continua nela
    v_colabs := array(select distinct x from unnest(v_colabs || array(
                  select y from unnest(v_antigo.colaboradores) y where not fn_visivel(y))) x);
  end if;

  select array_agg(g::date order by g) into v_datas
    from generate_series(v_ini, v_fim, interval '1 day') g
   where extract(dow from g)::smallint = any(v_dias);
  if v_datas is null then raise exception 'Nenhum dia do período cai nos dias da semana marcados.'; end if;

  -- Horário próprio de cada dia (só dos dias da escala; cada um conferido)
  for v_dia in
    select k::date as data, x.value as h
      from jsonb_each(case when jsonb_typeof(d -> 'horarios') = 'object' then d -> 'horarios' else '{}' end) x(k, value)
     where k::date = any(v_datas)
     order by k
  loop
    if coalesce(v_dia.h ->> 'tipo', 'trabalho') = 'folga' then
      v_hor := v_hor || jsonb_build_object(v_dia.data::text, jsonb_build_object('tipo', 'folga'));
    else
      perform fn_escala_validar_horario(fn_txt(v_dia.h, 'entrada')::time, fn_txt(v_dia.h, 'saida_intervalo')::time,
                                        fn_txt(v_dia.h, 'retorno_intervalo')::time, fn_txt(v_dia.h, 'saida')::time,
                                        ' em ' || to_char(v_dia.data, 'DD/MM/YYYY'));
      v_hor := v_hor || jsonb_build_object(v_dia.data::text, jsonb_build_object(
        'tipo', 'trabalho',
        'entrada', to_char(fn_txt(v_dia.h, 'entrada')::time, 'HH24:MI'),
        'saida_intervalo', to_char(fn_txt(v_dia.h, 'saida_intervalo')::time, 'HH24:MI'),
        'retorno_intervalo', to_char(fn_txt(v_dia.h, 'retorno_intervalo')::time, 'HH24:MI'),
        'saida', to_char(fn_txt(v_dia.h, 'saida')::time, 'HH24:MI')));
    end if;
  end loop;

  -- O horário da escala é o padrão: obrigatório se algum dia de trabalho ficar sem horário próprio
  if v_tipo = 'trabalho' then
    v_ent := fn_txt(d, 'entrada')::time;
    v_si  := fn_txt(d, 'saida_intervalo')::time;
    v_ri  := fn_txt(d, 'retorno_intervalo')::time;
    v_sai := fn_txt(d, 'saida')::time;
    if v_ent is not null or v_sai is not null
       or exists (select 1 from unnest(v_datas) dt where not v_hor ? dt::text) then
      perform fn_escala_validar_horario(v_ent, v_si, v_ri, v_sai, ' da escala de trabalho');
    end if;
  end if;

  -- Um colaborador só pode estar em uma escala por dia: avisa qual escala já ocupa o dia
  select c.nome as colaborador, e.data, l.nome as escala into v_conf
    from escalas e
    join colaboradores c on c.id = e.colaborador_id
    left join escala_lancamentos l on l.id = e.lancamento_id
   where e.colaborador_id = any(v_colabs) and e.data = any(v_datas)
     and e.lancamento_id is distinct from v_id
   order by e.data, c.nome
   limit 1;
  if v_conf.colaborador is not null then
    raise exception '% já está na escala "%" em %. Altere aquela escala ou escolha outro período.',
      v_conf.colaborador, coalesce(v_conf.escala, 'sem nome'), to_char(v_conf.data, 'DD/MM/YYYY');
  end if;

  if v_id is null then
    insert into escala_lancamentos (nome, tipo, data_inicio, data_fim, dias_semana, entrada, saida_intervalo,
                                    retorno_intervalo, saida, observacao, colaboradores, usuario_id, horarios)
    values (v_nome, v_tipo, v_ini, v_fim, v_dias, v_ent, v_si, v_ri, v_sai, nullif(trim(fn_txt(d, 'observacao')), ''),
            v_colabs, v_usuario, v_hor)
    returning id into v_id;
  else
    update escala_lancamentos
       set nome = v_nome, tipo = v_tipo, data_inicio = v_ini, data_fim = v_fim, dias_semana = v_dias,
           entrada = v_ent, saida_intervalo = v_si, retorno_intervalo = v_ri, saida = v_sai,
           observacao = nullif(trim(fn_txt(d, 'observacao')), ''), colaboradores = v_colabs, alterado_por = v_usuario,
           horarios = v_hor
     where id = v_id;
    -- Dias que saíram da escala (o trigger de fechamento impede mexer em período fechado)
    delete from escalas e
     where e.lancamento_id = v_id
       and not (e.colaborador_id = any(v_colabs) and e.data = any(v_datas));
  end if;

  insert into escalas (colaborador_id, data, tipo, entrada, saida_intervalo, retorno_intervalo, saida, observacao,
                       usuario_id, lancamento_id)
  select c, dt,
         coalesce(h ->> 'tipo', v_tipo),
         case when h is not null then (h ->> 'entrada')::time else v_ent end,
         case when h is not null then (h ->> 'saida_intervalo')::time else v_si end,
         case when h is not null then (h ->> 'retorno_intervalo')::time else v_ri end,
         case when h is not null then (h ->> 'saida')::time else v_sai end,
         v_nome, v_usuario, v_id
    from unnest(v_colabs) c cross join unnest(v_datas) dt
    left join lateral (select v_hor -> dt::text as h) hh on true
  on conflict (colaborador_id, data) do update
     set tipo = excluded.tipo, entrada = excluded.entrada, saida_intervalo = excluded.saida_intervalo,
         retorno_intervalo = excluded.retorno_intervalo, saida = excluded.saida, observacao = excluded.observacao,
         usuario_id = excluded.usuario_id, lancamento_id = excluded.lancamento_id
   where escalas.tipo is distinct from excluded.tipo or escalas.entrada is distinct from excluded.entrada
      or escalas.saida_intervalo is distinct from excluded.saida_intervalo
      or escalas.retorno_intervalo is distinct from excluded.retorno_intervalo
      or escalas.saida is distinct from excluded.saida or escalas.observacao is distinct from excluded.observacao;
  get diagnostics v_qtd = row_count;
  return jsonb_build_object('ok', true, 'id', v_id, 'dias', (select count(*) from escalas where lancamento_id = v_id));
exception
  when invalid_datetime_format or datetime_field_overflow then raise exception 'Horário ou data inválida.';
  when invalid_text_representation then raise exception 'Dados inválidos.';
end $$;

grant execute on function api_batida_sugestao(text, uuid, date) to anon, authenticated;

notify pgrst, 'reload schema';
