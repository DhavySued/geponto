-- =============================================================================
-- 014 · Tipo de jornada (lista do sistema + tipos livres); o menu passa a se chamar só "Jornadas"
-- Requer: 012 (e a 013, se ainda não rodou). Re-executável. Não muda horários nem recalcula nada.
-- =============================================================================

-- Tipo de jornada (lista fixa do sistema, ver TIPOS_JORNADA em src/lib/jornada.ts): 5x2, 6x1, 12x36, ciclo livre…
-- "tipo" continua dizendo só como os dias se repetem: por semana ou por ciclo.
alter table jornadas add column if not exists modelo text;

-- Tipo de jornada deduzido dos dias, para as que não têm o tipo gravado (o que não casa vira tipo livre)
create or replace function fn_jornada_modelo(p_jornada uuid)
returns text language sql stable set search_path = public as $$
  select case
      when j.tipo = 'escala' then
        case when x.padrao = 'TF' and x.brutos = 720 then case when x.noturna then '12x36n' else '12x36d' end
             when x.padrao = 'TTTTTF'   then '5x1'
             when x.padrao = 'TTTTTTFF' then '6x2'
             when x.padrao = 'TTTTFF'   then '4x2'
             else 'ciclo_livre' end
      when x.trabalha = 0 then 'intermitente'
      when x.trabalha = 5 and x.minutos = 2640 then '5x2_44'
      when x.trabalha = 5 and x.minutos = 2400 then '5x2_40'
      when x.trabalha = 6 and x.minutos = 2640 then '6x1_44'
      when x.trabalha = 6 and x.minutos = 2160 then '6x1_36'
      else 'semanal_livre' end
    from jornadas j
   cross join lateral (
     select string_agg(case when d.folga then 'F' else 'T' end, '' order by d.dia_semana) as padrao,
            count(*) filter (where not d.folga) as trabalha,
            coalesce(sum(fn_minutos(d.entrada, d.saida)) filter (where not d.folga), 0) as brutos,
            coalesce(sum(fn_minutos(d.entrada, d.saida)
                         - coalesce(fn_minutos(d.saida_intervalo, d.retorno_intervalo), 0)) filter (where not d.folga), 0) as minutos,
            coalesce(bool_or(d.saida < d.entrada), false) as noturna
       from jornada_dias d where d.jornada_id = j.id) x
   where j.id = p_jornada;
$$;

update jornadas set modelo = fn_jornada_modelo(id) where modelo is null;

create or replace function api_jornada_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  dia jsonb;
  v_nomes text[] := array['Domingo', 'Segunda', 'Terça', 'Quarta', 'Quinta', 'Sexta', 'Sábado'];
  v_dia int;
  v_ent time; v_si time; v_ri time; v_sai time;
  v_tipo text := coalesce(fn_txt(d, 'tipo'), 'semanal');
  v_ciclo smallint := case when v_tipo = 'escala' then fn_txt(d, 'ciclo_dias')::smallint else 7 end;
  v_rotulo text;
  -- Tipo de jornada: lista fixa do sistema (a mesma de src/lib/jornada.ts). Fora da lista, é deduzido dos dias.
  v_modelo text := case when fn_txt(d, 'modelo') = any (
    case when v_tipo = 'escala' then array['12x36d', '12x36n', '5x1', '6x2', '4x2', '12x24x12x48', 'turno_ininterrupto', 'ciclo_livre']
         else array['5x2_44', '5x2_40', '6x1_44', '6x1_7h20', '6x1_36', 'bancario_30', 'parcial_30', 'parcial_26',
                    'aprendiz_30', 'estagio_30', 'estagio_20', 'intermitente', 'semanal_livre'] end) then fn_txt(d, 'modelo') end;
begin
  perform fn_auth(p_token, 'jornadas', true);

  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome da jornada.'; end if;
  if v_tipo not in ('semanal', 'escala') then raise exception 'Tipo de jornada inválido.'; end if;
  if v_tipo = 'escala' then
    if coalesce(v_ciclo, 0) not between 2 and 60 then
      raise exception 'O ciclo da jornada deve ter de 2 a 60 dias (ex.: 12x36 = 2 dias).';
    end if;
    if fn_txt(d, 'data_base') is null then
      raise exception 'Informe a data de início do ciclo (o dia 1).';
    end if;
  end if;
  if jsonb_typeof(d -> 'dias') <> 'array' or jsonb_array_length(d -> 'dias') <> v_ciclo then
    raise exception '%', case when v_tipo = 'escala' then 'Informe os horários de todos os dias do ciclo.'
                              else 'Informe os horários dos 7 dias da semana.' end;
  end if;
  if (select count(distinct (x ->> 'dia_semana')::int) from jsonb_array_elements(d -> 'dias') x
       where (x ->> 'dia_semana')::int between 0 and v_ciclo - 1) <> v_ciclo then
    raise exception 'Os dias da jornada estão incompletos ou repetidos.';
  end if;

  -- Validação dos horários
  for dia in select * from jsonb_array_elements(d -> 'dias') loop
    v_dia := (dia ->> 'dia_semana')::int;
    v_rotulo := case when v_tipo = 'escala' then 'Dia ' || (v_dia + 1) else v_nomes[v_dia + 1] end;
    continue when coalesce((dia ->> 'folga')::boolean, false);
    v_ent := fn_txt(dia, 'entrada')::time;
    v_si  := fn_txt(dia, 'saida_intervalo')::time;
    v_ri  := fn_txt(dia, 'retorno_intervalo')::time;
    v_sai := fn_txt(dia, 'saida')::time;
    if v_ent is null or v_sai is null then
      raise exception '%: informe a entrada e a saída (ou marque como folga).', v_rotulo;
    end if;
    if (v_si is null) <> (v_ri is null) then
      raise exception '%: informe a saída e o retorno do intervalo, ou deixe os dois vazios.', v_rotulo;
    end if;
    if v_si is not null and fn_minutos(v_ent, v_si) + fn_minutos(v_si, v_ri) + fn_minutos(v_ri, v_sai)
                            <> fn_minutos(v_ent, v_sai) then
      raise exception '%: os horários devem seguir a ordem entrada → intervalo → retorno → saída.', v_rotulo;
    end if;
  end loop;

  if v_id is null then
    insert into jornadas (nome, descricao, ativo, tipo, ciclo_dias, data_base, intervalo_flexivel,
                          empresa_id, todas_empresas, intervalo_pre_assinalado)
    values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'),
            coalesce((d ->> 'ativo')::boolean, true),
            v_tipo, case when v_tipo = 'escala' then v_ciclo end,
            case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
            coalesce((d ->> 'intervalo_flexivel')::boolean, false),
            fn_empresa_atual(), coalesce((d ->> 'todas_empresas')::boolean, false),
            coalesce((d ->> 'intervalo_pre_assinalado')::boolean, false))
    returning id into v_id;
  else
    update jornadas set
      nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'),
      ativo = coalesce((d ->> 'ativo')::boolean, true),
      tipo = v_tipo,
      ciclo_dias = case when v_tipo = 'escala' then v_ciclo end,
      data_base = case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
      intervalo_flexivel = coalesce((d ->> 'intervalo_flexivel')::boolean, false),
      todas_empresas = coalesce((d ->> 'todas_empresas')::boolean, todas_empresas),
      intervalo_pre_assinalado = coalesce((d ->> 'intervalo_pre_assinalado')::boolean, false),
      empresa_id = coalesce(empresa_id, fn_empresa_atual())
    where id = v_id;
    if not found then raise exception 'Jornada não encontrada.'; end if;
    delete from jornada_dias where jornada_id = v_id;
  end if;

  insert into jornada_dias (jornada_id, dia_semana, folga, entrada, saida_intervalo, retorno_intervalo, saida,
                            dia_util, recebe_vt, recebe_va)
  select v_id, (x ->> 'dia_semana')::smallint, f.folga,
         case when f.folga then null else fn_txt(x, 'entrada')::time end,
         case when f.folga then null else fn_txt(x, 'saida_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'retorno_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'saida')::time end,
         coalesce((x ->> 'dia_util')::boolean, not f.folga),
         coalesce((x ->> 'recebe_vt')::boolean, not f.folga),
         coalesce((x ->> 'recebe_va')::boolean, not f.folga)
    from jsonb_array_elements(d -> 'dias') x
   cross join lateral (select coalesce((x ->> 'folga')::boolean, false) as folga) f;

  update jornadas set modelo = coalesce(v_modelo, fn_jornada_modelo(v_id)) where id = v_id;

  -- A apuração dos dias já encerrados muda com a jornada: recalcula o banco de horas de quem a usa
  perform fn_processar_banco_horas(least(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao)),
                                   fn_hoje() - 1, c.id)
     from colaboradores c
    where c.id in (select colaborador_id from colaborador_situacoes where jornada_id = v_id);

  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    raise exception 'Já existe uma jornada com este nome.';
  when check_violation then
    raise exception 'Valores inválidos: confira o ciclo e a data de início.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Horário inválido. Use o formato HH:MM.';
end $$;

update paginas set nome = 'Jornadas' where chave = 'jornadas';

revoke execute on function fn_jornada_modelo(uuid)                          from public, anon, authenticated;

notify pgrst, 'reload schema';
