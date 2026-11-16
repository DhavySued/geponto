-- =============================================================================
-- GePonto — 10_api_justificativas.sql
-- Justificativas de atraso, saída antecipada e falta:
--   • lista os atrasos, saídas antecipadas e faltas do período (apurados pelo ponto),
--     com a justificativa de cada um quando houver;
--   • justifica um ou vários de uma vez — só registrando o motivo ou abonando
--     (tudo ou alguns minutos). O abono tira os minutos do atraso/saída e cobre o débito do dia.
-- Execute depois de 08_api_fortes.sql. Pode ser reexecutado.
-- =============================================================================

-- p_situacao: null (todas) · 'pendentes' (sem justificativa) · 'justificadas' · 'abonadas'
create or replace function api_justificativas_listar(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null, p_situacao text default null)
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
     where (p_colaborador is null or c.id = p_colaborador)
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

-- Justifica um ou vários eventos com o mesmo motivo. Substitui a justificativa já existente.
-- p_dados: { itens: [{ colaborador_id, data, tipo }], motivo, abona, minutos?, observacao? }
--   minutos (só para um evento): abona apenas essa quantidade; vazio abona tudo
create or replace function api_justificativa_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'justificativas', true);
  d         jsonb := p_dados;
  v_itens   jsonb := case when jsonb_typeof(p_dados -> 'itens') = 'array' then p_dados -> 'itens' else '[]'::jsonb end;
  v_abona   boolean := coalesce((p_dados ->> 'abona')::boolean, false);
  v_min     integer := nullif(fn_txt(p_dados, 'minutos'), '')::integer;
  v_qtd     integer;
begin
  if jsonb_array_length(v_itens) = 0 then raise exception 'Selecione ao menos um atraso, saída ou falta.'; end if;
  if fn_txt(d, 'motivo') is null then raise exception 'Informe o motivo da justificativa.'; end if;
  if v_min is not null and not v_abona then v_min := null; end if;
  if v_min is not null and v_min <= 0 then raise exception 'Informe quanto tempo abonar.'; end if;
  if v_min is not null and jsonb_array_length(v_itens) > 1 then
    raise exception 'Abono de parte do tempo vale para um item por vez. Em lote, o abono é do tempo todo.';
  end if;
  if exists (select 1 from jsonb_array_elements(v_itens) i
              where coalesce(i ->> 'tipo', '') not in ('atraso', 'saida_antecipada', 'falta')) then
    raise exception 'Tipo de justificativa inválido.';
  end if;
  if exists (select 1 from jsonb_array_elements(v_itens) i where (i ->> 'data')::date > fn_hoje()) then
    raise exception 'Não dá para justificar um dia que ainda não aconteceu. Para ausências futuras, use Ocorrências.';
  end if;
  if exists (select 1 from jsonb_array_elements(v_itens) i
              where not exists (select 1 from colaboradores c where c.id = (i ->> 'colaborador_id')::uuid)
                 or not fn_visivel((i ->> 'colaborador_id')::uuid)) then
    raise exception 'Há colaboradores fora da sua abrangência de acesso.' using errcode = '42501';
  end if;

  insert into justificativas (colaborador_id, data, tipo, motivo, abona, minutos, observacao, usuario_id)
  select distinct on ((i ->> 'colaborador_id')::uuid, (i ->> 'data')::date, i ->> 'tipo')
         (i ->> 'colaborador_id')::uuid, (i ->> 'data')::date, i ->> 'tipo',
         fn_txt(d, 'motivo'), v_abona, v_min, fn_txt(d, 'observacao'), v_usuario
    from jsonb_array_elements(v_itens) i
  on conflict (colaborador_id, data, tipo) do update
     set motivo = excluded.motivo, abona = excluded.abona, minutos = excluded.minutos,
         observacao = excluded.observacao, usuario_id = excluded.usuario_id;
  get diagnostics v_qtd = row_count;
  return jsonb_build_object('ok', true, 'qtd', v_qtd);
exception
  when invalid_text_representation or invalid_datetime_format then
    raise exception 'Dados da justificativa inválidos.';
end $$;

create or replace function api_justificativa_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'justificativas', true);
  delete from justificativas where id = p_id and fn_visivel(colaborador_id);
  if not found then raise exception 'Justificativa não encontrada.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
grant execute on function api_justificativas_listar(text, date, date, uuid, uuid, text) to anon, authenticated;
grant execute on function api_justificativa_salvar(text, jsonb)                         to anon, authenticated;
grant execute on function api_justificativa_excluir(text, uuid)                         to anon, authenticated;

notify pgrst, 'reload schema';
