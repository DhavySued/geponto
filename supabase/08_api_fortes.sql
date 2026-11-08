-- =============================================================================
-- GePonto — 08_api_fortes.sql
-- Funções inspiradas no Fortes Ponto / Fortes Colabore:
--   • Feriados e Ocorrências (afastamentos, atestados, férias, abonos — inclusive em lote)
--   • Solicitações do colaborador (inclusão de batida e abono) com aprovação do gestor
--   • Fechamento de período (congela o ponto) com prévia de pendências
--   • Espelho de ponto, Totais do período, Exportação para a folha e Quebra de regras
--   • Importação de batidas do relógio (AFD — Portaria 1.510 e 671)
-- Execute depois de 07_api_tratamento.sql. Pode ser reexecutado.
-- =============================================================================

-- Exige permissão em pelo menos uma das páginas
create or replace function fn_auth_alguma(p_token text, p_paginas text[], p_editar boolean default false)
returns uuid language plpgsql volatile set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token);
  p text;
begin
  foreach p in array p_paginas loop
    if fn_pode(v_usuario, p, p_editar) then
      return v_usuario;
    end if;
  end loop;
  raise exception 'Acesso negado' using errcode = '42501';
end $$;

-- Colaborador do usuário logado (null quando não vinculado)
create or replace function fn_colaborador_do_usuario(p_usuario uuid)
returns uuid language sql stable set search_path = public as $$
  select colaborador_id from usuarios where id = p_usuario;
$$;

-- Substituídas por fn_visivel (abrangência do perfil), em 02_functions.sql
drop function if exists fn_no_escopo(uuid, uuid);
drop function if exists fn_gestor_escopo(uuid);

-- Listas para os filtros das telas novas
create or replace function api_filtros_auxiliares(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth_alguma(p_token, array['ocorrencias', 'solicitacoes', 'fechamento', 'espelho_ponto',
                                                   'totais_periodo', 'quebra_regras', 'feriados']);
begin
  return jsonb_build_object(
    'empresa', (select jsonb_build_object('razao_social', razao_social, 'nome_fantasia', nome_fantasia, 'cnpj', cnpj)
                  from empresa where id = 1),
    'colaboradores', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'situacao', c.situacao,
                         'departamento_id', c.departamento_id, 'cargo_id', c.cargo_id, 'jornada_id', c.jornada_id)
                         order by c.nome)
                       from colaboradores c where c.controla_ponto and fn_visivel(c.id)), '[]'::jsonb),
    'departamentos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from departamentos), '[]'::jsonb),
    'motivos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'descricao', descricao, 'aplicacao', aplicacao)
                                          order by descricao)
                           from motivos_batida where ativo), '[]'::jsonb),
    'fechado_ate', (select max(data_fim) from fechamentos));
end $$;

-- -----------------------------------------------------------------------------
-- Feriados
-- -----------------------------------------------------------------------------
create or replace function api_feriados_listar(p_token text, p_ano integer default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'feriados');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'data', data, 'descricao', descricao, 'tipo', tipo) order by data)
      from feriados
     where p_ano is null or extract(year from data) = p_ano), '[]'::jsonb);
end $$;

create or replace function api_feriado_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_id    uuid := nullif(p_dados ->> 'id', '')::uuid;
  v_data  date := fn_txt(p_dados, 'data')::date;
  v_antes date;
begin
  perform fn_auth(p_token, 'feriados', true);
  if v_data is null then raise exception 'Informe a data do feriado.'; end if;
  if fn_txt(p_dados, 'descricao') is null then raise exception 'Informe a descrição do feriado.'; end if;
  if coalesce(fn_txt(p_dados, 'tipo'), 'nacional') not in ('nacional', 'estadual', 'municipal', 'facultativo') then
    raise exception 'Abrangência inválida.';
  end if;

  if v_id is null then
    insert into feriados (data, descricao, tipo)
    values (v_data, fn_txt(p_dados, 'descricao'), coalesce(fn_txt(p_dados, 'tipo'), 'nacional'))
    returning id into v_id;
  else
    select data into v_antes from feriados where id = v_id;
    update feriados set data = v_data, descricao = fn_txt(p_dados, 'descricao'),
                        tipo = coalesce(fn_txt(p_dados, 'tipo'), 'nacional')
     where id = v_id;
    if not found then raise exception 'Feriado não encontrado.'; end if;
  end if;

  -- Feriado muda a jornada prevista do dia: recalcula o banco de horas
  if v_antes is not null and v_antes < fn_hoje() then
    perform fn_processar_banco_horas(v_antes, v_antes);
  end if;
  if v_data < fn_hoje() then
    perform fn_processar_banco_horas(v_data, v_data);
  end if;
  return jsonb_build_object('id', v_id);
exception
  when unique_violation then raise exception 'Já existe um feriado nesta data.';
end $$;

create or replace function api_feriado_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_data date;
begin
  perform fn_auth(p_token, 'feriados', true);
  delete from feriados where id = p_id returning data into v_data;
  if v_data is null then raise exception 'Feriado não encontrado.'; end if;
  if v_data < fn_hoje() then
    perform fn_processar_banco_horas(v_data, v_data);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Ocorrências (afastamentos, atestados, férias, folgas, faltas justificadas, abonos)
-- -----------------------------------------------------------------------------
create or replace function api_ocorrencias_listar(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null, p_tipo text default null)
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
       and (p_colaborador is null or c.id = p_colaborador)
       and (p_departamento is null or c.departamento_id = p_departamento)
       and (p_tipo is null or a.tipo::text = p_tipo)
       and fn_visivel(c.id)), '[]'::jsonb);
end $$;

-- Lança a mesma ocorrência para um ou vários colaboradores (lote).
-- p_dados: { id?, colaboradores: [uuid], tipo, data_inicio, data_fim, abona, minutos?, justificativa }
create or replace function api_ocorrencia_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'ocorrencias', true);
  d         jsonb := p_dados;
  v_id      uuid := nullif(d ->> 'id', '')::uuid;
  v_tipo    tipo_ausencia;
  v_ini     date := fn_txt(d, 'data_inicio')::date;
  v_fim     date := coalesce(fn_txt(d, 'data_fim')::date, fn_txt(d, 'data_inicio')::date);
  v_min     integer := nullif(fn_txt(d, 'minutos'), '')::integer;
  v_colabs  uuid[];
  v_qtd     integer := 0;
  v_conflito text;
begin
  if fn_txt(d, 'tipo') is null then raise exception 'Selecione o tipo da ocorrência.'; end if;
  v_tipo := fn_txt(d, 'tipo')::tipo_ausencia;
  if v_ini is null then raise exception 'Informe a data inicial.'; end if;
  if v_fim < v_ini then raise exception 'A data final não pode ser anterior à inicial.'; end if;
  if fn_txt(d, 'justificativa') is null then raise exception 'Informe a justificativa.'; end if;
  if v_min is not null and (v_tipo <> 'abono' or v_fim <> v_ini) then
    raise exception 'Abono em horas vale só para o tipo "Abono" e para um único dia.';
  end if;
  if v_min is not null and v_min <= 0 then raise exception 'Informe a quantidade de horas abonadas.'; end if;

  select array_agg(x::uuid) into v_colabs from jsonb_array_elements_text(case when jsonb_typeof(d -> 'colaboradores') = 'array'
                                                                    then d -> 'colaboradores' else '[]'::jsonb end) x;
  if v_id is null and coalesce(array_length(v_colabs, 1), 0) = 0 then
    raise exception 'Selecione ao menos um colaborador.';
  end if;
  if exists (select 1 from unnest(v_colabs) x where not fn_visivel(x)) then
    raise exception 'Há colaboradores fora da sua abrangência de acesso.' using errcode = '42501';
  end if;

  if v_id is not null then
    -- A edição segue a mesma regra do lançamento: dia inteiro não se sobrepõe a outra ocorrência
    if v_min is null then
      select c.nome into v_conflito
        from ausencias atual
        join ausencias a on a.colaborador_id = atual.colaborador_id and a.id <> atual.id
        join colaboradores c on c.id = a.colaborador_id
       where atual.id = v_id and a.minutos is null
         and a.data_inicio <= v_fim and a.data_fim >= v_ini
       limit 1;
      if v_conflito is not null then
        raise exception '% já tem uma ocorrência que cobre parte deste período.', v_conflito;
      end if;
    end if;
    update ausencias set tipo = v_tipo, data_inicio = v_ini, data_fim = v_fim,
                         abona = coalesce((d ->> 'abona')::boolean, true), minutos = v_min,
                         justificativa = fn_txt(d, 'justificativa'), usuario_id = v_usuario
     where id = v_id and fn_visivel(colaborador_id);
    if not found then raise exception 'Ocorrência não encontrada.'; end if;
    return jsonb_build_object('ok', true, 'qtd', 1);
  end if;

  -- Ocorrências de dia inteiro não podem se sobrepor no mesmo colaborador
  if v_min is null then
    select c.nome into v_conflito
      from ausencias a join colaboradores c on c.id = a.colaborador_id
     where a.colaborador_id = any (v_colabs) and a.minutos is null
       and a.data_inicio <= v_fim and a.data_fim >= v_ini
     limit 1;
    if v_conflito is not null then
      raise exception '% já tem uma ocorrência que cobre parte deste período.', v_conflito;
    end if;
  end if;

  insert into ausencias (colaborador_id, tipo, data_inicio, data_fim, abona, minutos, justificativa, usuario_id)
  select c, v_tipo, v_ini, v_fim, coalesce((d ->> 'abona')::boolean, true), v_min, fn_txt(d, 'justificativa'), v_usuario
    from unnest(v_colabs) c;
  get diagnostics v_qtd = row_count;
  return jsonb_build_object('ok', true, 'qtd', v_qtd);
exception
  when invalid_text_representation then raise exception 'Tipo de ocorrência inválido.';
end $$;

create or replace function api_ocorrencia_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'ocorrencias', true);
  delete from ausencias where id = p_id and fn_visivel(colaborador_id);
  if not found then raise exception 'Ocorrência não encontrada.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Solicitações (Meu Ponto → aprovação do gestor)
-- -----------------------------------------------------------------------------
create or replace function fn_solicitacao_json(s solicitacoes)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', s.id, 'colaborador_id', s.colaborador_id, 'tipo', s.tipo, 'data', s.data, 'data_fim', s.data_fim,
    'hora', to_char(s.hora, 'HH24:MI'), 'sentido', s.sentido, 'tipo_ausencia', s.tipo_ausencia,
    'minutos', s.minutos, 'motivo', (select descricao from motivos_batida where id = s.motivo_id),
    'justificativa', s.justificativa, 'status', s.status, 'resposta', s.resposta,
    'avaliador', (select nome from usuarios where id = s.avaliador_id), 'avaliado_em', s.avaliado_em,
    'created_at', s.created_at);
$$;

create or replace function api_minhas_solicitacoes(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'meu_ponto');
  v_colab   uuid := fn_colaborador_do_usuario(v_usuario);
begin
  if v_colab is null then raise exception 'Seu usuário não está vinculado a um colaborador.'; end if;
  return jsonb_build_object(
    'motivos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'descricao', descricao) order by descricao)
                           from motivos_batida where ativo and aplicacao in ('inclusao', 'ambos')), '[]'::jsonb),
    'solicitacoes', coalesce((select jsonb_agg(fn_solicitacao_json(s) order by s.created_at desc)
                                from solicitacoes s where s.colaborador_id = v_colab), '[]'::jsonb));
end $$;

-- p_dados: { tipo: 'inclusao_batida' | 'abono', data, hora?, sentido?, motivo_id?,
--            tipo_ausencia?, data_fim?, minutos?, justificativa }
create or replace function api_solicitacao_criar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'meu_ponto', true);
  v_colab   uuid := fn_colaborador_do_usuario(v_usuario);
  d         jsonb := p_dados;
  v_tipo    text := fn_txt(d, 'tipo');
  v_data    date := fn_txt(d, 'data')::date;
  v_fim     date := fn_txt(d, 'data_fim')::date;
  v_min     integer := nullif(fn_txt(d, 'minutos'), '')::integer;
  v_id      uuid;
begin
  if v_colab is null then raise exception 'Seu usuário não está vinculado a um colaborador.'; end if;
  if v_tipo not in ('inclusao_batida', 'abono') then raise exception 'Tipo de solicitação inválido.'; end if;
  if v_data is null then raise exception 'Informe a data.'; end if;
  if v_data > fn_hoje() and v_tipo = 'inclusao_batida' then
    raise exception 'Não é possível solicitar batida em data futura.';
  end if;
  if fn_txt(d, 'justificativa') is null then raise exception 'Descreva a justificativa da solicitação.'; end if;
  if fn_periodo_fechado(v_data) then
    raise exception 'O dia % está em um período fechado. Procure o RH.', to_char(v_data, 'DD/MM/YYYY');
  end if;

  if v_tipo = 'inclusao_batida' then
    if fn_txt(d, 'hora') is null then raise exception 'Informe o horário da batida.'; end if;
    if fn_txt(d, 'motivo_id') is not null then
      perform fn_motivo_valido(fn_txt(d, 'motivo_id')::uuid, 'inclusao');
    end if;
    v_fim := null;
    v_min := null;
  else
    if fn_txt(d, 'tipo_ausencia') is null then raise exception 'Selecione o tipo de abono.'; end if;
    if v_fim is not null and v_fim < v_data then raise exception 'A data final não pode ser anterior à inicial.'; end if;
    if v_min is not null and v_fim is not null and v_fim <> v_data then
      raise exception 'Abono em horas vale para um único dia.';
    end if;
  end if;

  insert into solicitacoes (colaborador_id, tipo, data, data_fim, hora, sentido, tipo_ausencia, minutos,
                            motivo_id, justificativa, usuario_id)
  values (v_colab, v_tipo, v_data, v_fim,
          case when v_tipo = 'inclusao_batida' then fn_txt(d, 'hora')::time end,
          null,   -- o colaborador não classifica a batida; quem aprova/trata é que declara
          case when v_tipo = 'abono' then fn_txt(d, 'tipo_ausencia')::tipo_ausencia end,
          v_min,
          case when v_tipo = 'inclusao_batida' then fn_txt(d, 'motivo_id')::uuid end,
          fn_txt(d, 'justificativa'), v_usuario)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
exception
  when invalid_datetime_format or datetime_field_overflow then raise exception 'Data ou hora inválida.';
  when invalid_text_representation then raise exception 'Valor inválido na solicitação.';
end $$;

create or replace function api_solicitacao_cancelar(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_usuario uuid := fn_auth(p_token, 'meu_ponto', true);
begin
  update solicitacoes set status = 'cancelada'
   where id = p_id and status = 'pendente' and colaborador_id = fn_colaborador_do_usuario(v_usuario);
  if not found then raise exception 'Só é possível cancelar solicitações pendentes suas.'; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function api_solicitacoes_listar(p_token text, p_status text default 'pendente')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'solicitacoes');
begin
  return jsonb_build_object(
    'pode_avaliar', fn_pode(v_usuario, 'solicitacoes', true),
    'pendentes', (select count(*) from solicitacoes s
                   where s.status = 'pendente' and fn_visivel(s.colaborador_id)),
    'solicitacoes', coalesce((
      select jsonb_agg(fn_solicitacao_json(s)
                       || jsonb_build_object('colaborador', c.nome, 'matricula', c.matricula, 'departamento', d.nome,
                                             'batidas_dia', fn_batidas_json(c.id, s.data),
                                             'fechado', fn_periodo_fechado(s.data))
                       order by s.created_at desc)
        from solicitacoes s
        join colaboradores c      on c.id = s.colaborador_id
        left join departamentos d on d.id = c.departamento_id
       where (coalesce(p_status, 'todas') = 'todas' or s.status = p_status)
         and fn_visivel(s.colaborador_id)
         and s.created_at > now() - interval '180 days'), '[]'::jsonb));
end $$;

create or replace function api_solicitacao_avaliar(p_token text, p_id uuid, p_aprovar boolean, p_resposta text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'solicitacoes', true);
  s         solicitacoes%rowtype;
  v_motivo  uuid;
  v_dh      timestamptz;
  v_bat     batidas%rowtype;
  v_aus     uuid;
begin
  select * into s from solicitacoes where id = p_id for update;
  if not found then raise exception 'Solicitação não encontrada.'; end if;
  if s.status <> 'pendente' then raise exception 'Esta solicitação já foi respondida.'; end if;
  if not fn_visivel(s.colaborador_id) then
    raise exception 'Você só pode avaliar solicitações da sua equipe.' using errcode = '42501';
  end if;
  if s.colaborador_id = fn_colaborador_do_usuario(v_usuario) then
    raise exception 'Você não pode aprovar a sua própria solicitação.';
  end if;
  if not p_aprovar and coalesce(trim(p_resposta), '') = '' then
    raise exception 'Informe o motivo da reprovação.';
  end if;

  if p_aprovar then
    if s.tipo = 'inclusao_batida' then
      v_motivo := coalesce(s.motivo_id, (select id from motivos_batida where descricao = 'Ajuste autorizado pelo gestor'),
                           (select id from motivos_batida where ativo and aplicacao in ('inclusao', 'ambos') limit 1));
      v_dh := (s.data + s.hora) at time zone fn_fuso();
      if exists (select 1 from batidas where colaborador_id = s.colaborador_id and status = 'valida'
                  and date_trunc('minute', data_hora) = date_trunc('minute', v_dh)) then
        raise exception 'Já existe uma batida válida neste horário. Reprove a solicitação ou ajuste pelo tratamento.';
      end if;
      insert into batidas (colaborador_id, data_hora, data_referencia, origem, justificativa, motivo_id,
                           observacao, sentido, usuario_id)
      values (s.colaborador_id, v_dh, s.data, 'manual',
              (select descricao from motivos_batida where id = v_motivo) || ' — Solicitação: ' || s.justificativa,
              v_motivo, 'Solicitação do colaborador: ' || s.justificativa, s.sentido, v_usuario)
      returning * into v_bat;
      perform fn_batida_auditar(v_bat, 'inclusao', null, v_dh, v_motivo,
                                'Aprovado a partir da solicitação do colaborador: ' || s.justificativa);
    else
      insert into ausencias (colaborador_id, tipo, data_inicio, data_fim, abona, minutos, justificativa, usuario_id)
      values (s.colaborador_id, s.tipo_ausencia, s.data, coalesce(s.data_fim, s.data), true, s.minutos,
              'Solicitação do colaborador: ' || s.justificativa, v_usuario)
      returning id into v_aus;
    end if;
  end if;

  update solicitacoes set status = case when p_aprovar then 'aprovada' else 'reprovada' end,
                          resposta = nullif(trim(p_resposta), ''), avaliador_id = v_usuario, avaliado_em = now(),
                          batida_id = v_bat.id, ausencia_id = v_aus
   where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Fechamento de período
-- -----------------------------------------------------------------------------
create or replace function api_fechamentos_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_usuario uuid := fn_auth(p_token, 'fechamento');
begin
  return jsonb_build_object(
    'pode_editar', fn_pode(v_usuario, 'fechamento', true),
    'fechamentos', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'data_inicio', f.data_inicio, 'data_fim', f.data_fim,
                                          'observacao', f.observacao, 'usuario', u.nome, 'created_at', f.created_at)
                       order by f.data_inicio desc)
        from fechamentos f left join usuarios u on u.id = f.usuario_id), '[]'::jsonb));
end $$;

-- Pendências que o DP deve tratar antes de fechar (como no Fortes: marcações ímpares,
-- faltas sem justificativa, dias sem jornada e solicitações em aberto)
create or replace function api_fechamento_previa(p_token text, p_ini date, p_fim date)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform fn_auth(p_token, 'fechamento');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;

  drop table if exists pg_temp._prev;
  create temp table _prev on commit drop as
    select a.*, c.nome, c.matricula from fn_apuracao(p_ini, least(p_fim, fn_hoje() - 1)) a
      join colaboradores c on c.id = a.colaborador_id
     where fn_visivel(c.id);

  return jsonb_build_object(
    'resumo', jsonb_build_object(
      'colaboradores', (select count(distinct colaborador_id) from pg_temp._prev),
      'inconsistentes', (select count(*) from pg_temp._prev where ocorrencia = 'inconsistente'),
      'faltas', (select count(*) from pg_temp._prev where falta),
      'sem_jornada', (select count(*) from pg_temp._prev where ocorrencia = 'sem_jornada'),
      'solicitacoes', (select count(*) from solicitacoes
                        where status = 'pendente' and data between p_ini and p_fim and fn_visivel(colaborador_id)),
      'ja_fechado', exists (select 1 from fechamentos f where f.data_inicio <= p_fim and f.data_fim >= p_ini)),
    'pendencias', coalesce((
      select jsonb_agg(jsonb_build_object('colaborador_id', colaborador_id, 'nome', nome, 'matricula', matricula,
                                          'data', data, 'ocorrencia', ocorrencia, 'qtd_batidas', qtd_batidas)
                       order by nome, data)
        from (select * from pg_temp._prev where ocorrencia in ('inconsistente', 'falta', 'sem_jornada')
               order by nome, data limit 300) x), '[]'::jsonb));
end $$;

create or replace function api_fechamento_fechar(p_token text, p_ini date, p_fim date, p_observacao text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'fechamento', true);
  v_id      uuid;
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim >= fn_hoje() then raise exception 'Só é possível fechar dias já encerrados (até ontem).'; end if;
  if exists (select 1 from fechamentos f where f.data_inicio <= p_fim and f.data_fim >= p_ini) then
    raise exception 'Parte deste período já está fechada.';
  end if;

  -- Consolida o banco de horas antes de congelar
  perform fn_processar_banco_horas(p_ini, p_fim);
  insert into fechamentos (data_inicio, data_fim, observacao, usuario_id)
  values (p_ini, p_fim, nullif(trim(p_observacao), ''), v_usuario)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function api_fechamento_reabrir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare f fechamentos%rowtype;
begin
  perform fn_auth(p_token, 'fechamento', true);
  delete from fechamentos where id = p_id returning * into f;
  if f.id is null then raise exception 'Fechamento não encontrado.'; end if;
  -- Recalcula com as regras atuais o que ficou congelado
  perform fn_processar_banco_horas(f.data_inicio, f.data_fim);
  return jsonb_build_object('ok', true);
end $$;

-- Soma das horas extras por percentual: [{p, m}, …] → [{chave, percentual, minutos}] (ordem crescente)
create or replace function fn_he_por_percentual(p_itens jsonb)
returns jsonb language sql immutable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('chave', fn_he_chave(x.p), 'percentual', x.p::float8, 'minutos', x.m)
                            order by x.p), '[]'::jsonb)
    from (select (i ->> 'p')::numeric as p, sum((i ->> 'm')::int)::int as m
            from jsonb_array_elements(coalesce(p_itens, '[]'::jsonb)) i
           group by 1) x;
$$;

-- -----------------------------------------------------------------------------
-- Espelho de ponto (Portaria 671: marcações originais e tratadas identificadas)
-- -----------------------------------------------------------------------------
create or replace function fn_espelho_colaborador(p_colaborador uuid, p_ini date, p_fim date)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  v_fim  date := least(p_fim, fn_hoje());
  v_out  jsonb;
begin
  with ap as (
    select * from fn_apuracao(p_ini, v_fim, p_colaborador)
  )
  select jsonb_build_object(
    'colaborador', (
      select jsonb_build_object('id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'cpf', c.cpf, 'pis', c.pis,
                                'admissao', c.data_admissao, 'cargo', g.nome, 'departamento', d.nome)
        from colaboradores c
        left join cargos g        on g.id = c.cargo_id
        left join departamentos d on d.id = c.departamento_id
       where c.id = p_colaborador),
    'jornadas', coalesce((
      select jsonb_agg(jsonb_build_object('nome', j.nome, 'tipo', j.tipo, 'descricao', j.descricao) order by j.nome)
        from jornadas j where j.id in (select distinct jornada_id from ap where jornada_id is not null)), '[]'::jsonb),
    'dias', coalesce((
      select jsonb_agg(jsonb_build_object(
               'data', a.data,
               'previsto', fn_horario_texto(a.jornada_id, a.data),
               'previsto_min', a.previsto_min, 'trabalhado_min', a.trabalhado_min,
               'extra_min', a.extra_min, 'debito_min', a.debito_min, 'he_percentual', a.he_percentual::float8,
               'atraso_min', a.atraso_min, 'saida_antecipada_min', a.saida_antecipada_min,
               'noturno_min', a.noturno_reduzido_min, 'abonado_min', a.abonado_min,
               'banco_horas', a.banco_horas, 'ocorrencia', a.ocorrencia,
               'observacao', coalesce(
                  (select au.justificativa from ausencias au
                    where au.colaborador_id = a.colaborador_id and a.data between au.data_inicio and au.data_fim
                    order by au.minutos nulls first limit 1),
                  (select f.descricao from feriados f where f.data = a.data)),
               'batidas', coalesce((
                  select jsonb_agg(fn_batida_json(b, m.descricao) order by b.data_hora)
                    from fn_batidas_periodo(a.data, a.data, a.colaborador_id) b
                    left join motivos_batida m on m.id = b.motivo_id), '[]'::jsonb))
             order by a.data)
        from ap a), '[]'::jsonb),
    'totais', (
      select jsonb_build_object(
               'previsto_min', coalesce(sum(previsto_min), 0),
               'trabalhado_min', coalesce(sum(trabalhado_min), 0),
               'he_min', coalesce(sum(extra_min) filter (where not banco_horas), 0),
               'he', fn_he_por_percentual(jsonb_agg(jsonb_build_object('p', he_percentual, 'm', extra_min))
                                            filter (where not banco_horas and extra_min > 0)),
               'debito_min', coalesce(sum(debito_min) filter (where not banco_horas and not falta), 0),
               'faltas', count(*) filter (where falta),
               'atraso_min', coalesce(sum(atraso_min), 0),
               'saida_antecipada_min', coalesce(sum(saida_antecipada_min), 0),
               'noturno_min', coalesce(sum(noturno_reduzido_min), 0),
               'abonado_min', coalesce(sum(abonado_min), 0))
        from ap),
    'banco_horas', (
      select jsonb_build_object(
               'anterior', coalesce(sum(minutos) filter (where data < p_ini), 0),
               'creditos', coalesce(sum(minutos) filter (where data between p_ini and p_fim and minutos > 0), 0),
               'debitos',  coalesce(sum(minutos) filter (where data between p_ini and p_fim and minutos < 0), 0),
               'saldo',    coalesce(sum(minutos) filter (where data <= p_fim), 0))
        from banco_horas where colaborador_id = p_colaborador)
  ) into v_out;
  return v_out;
end $$;

create or replace function api_espelho_ponto(
  p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'espelho_ponto');
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;
  perform fn_banco_horas_atualizar();

  return jsonb_build_object(
    'empresa', (select jsonb_build_object('razao_social', razao_social, 'nome_fantasia', nome_fantasia,
                                          'cnpj', cnpj, 'endereco', endereco) from empresa where id = 1),
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'emitido_em', now(),
    'emitido_por', (select nome from usuarios where id = v_usuario),
    'espelhos', coalesce((
      select jsonb_agg(fn_espelho_colaborador(c.id, p_ini, p_fim) order by c.nome)
        from colaboradores c
       where c.controla_ponto
         and (p_colaborador is null or c.id = p_colaborador)
         and (p_departamento is null or c.departamento_id = p_departamento)
         and fn_visivel(c.id)
         and fn_inicio_controle(c) <= p_fim
         and (c.data_desligamento is null or c.data_desligamento >= p_ini)), '[]'::jsonb));
end $$;

-- O próprio colaborador consulta o espelho dele (extrato mensal do Fortes Colabore)
create or replace function api_meu_espelho(p_token text, p_ini date, p_fim date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'meu_ponto');
  v_colab   uuid := fn_colaborador_do_usuario(v_usuario);
begin
  if v_colab is null then raise exception 'Seu usuário não está vinculado a um colaborador.'; end if;
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;
  perform fn_banco_horas_atualizar();
  return jsonb_build_object(
    'empresa', (select jsonb_build_object('razao_social', razao_social, 'nome_fantasia', nome_fantasia,
                                          'cnpj', cnpj, 'endereco', endereco) from empresa where id = 1),
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'emitido_em', now(),
    'emitido_por', (select nome from usuarios where id = v_usuario),
    'espelhos', jsonb_build_array(fn_espelho_colaborador(v_colab, p_ini, p_fim)));
end $$;

-- -----------------------------------------------------------------------------
-- Totais do período (base da exportação para a folha) e eventos da folha
-- -----------------------------------------------------------------------------
create or replace function api_totais_periodo(
  p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_departamento uuid default null)
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
     where (p_colaborador is null or c.id = p_colaborador)
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

-- Eventos das conversões do banco de horas (bancos criados antes da conversão)
insert into eventos_folha (chave, descricao, unidade, ordem) values
  ('bh_pago',       'Banco de horas convertido em pagamento', 'horas', 90),
  ('bh_descontado', 'Banco de horas convertido em desconto',  'horas', 100)
on conflict (chave) do nothing;

create or replace function api_eventos_folha_salvar(p_token text, p_eventos jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'totais_periodo', true);
  update eventos_folha e
     set codigo = fn_txt(x, 'codigo'),
         ativo = coalesce((x ->> 'ativo')::boolean, true)
    from jsonb_array_elements(p_eventos) x
   where e.chave = x ->> 'chave';
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Quebra de regras (CLT): interjornada < 11h, intervalo intrajornada insuficiente,
-- jornada acima de 10h, hora extra acima do limite diário e marcação ímpar.
-- O intervalo aceita a tolerância de entrada do perfil de eventos (ex.: 56 min com tolerância de 5 min não quebra).
-- -----------------------------------------------------------------------------
create or replace function api_quebra_regras(
  p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_departamento uuid default null)
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
             'Horas extras acima do limite diário do perfil de eventos', a.extra_min),
            ('marcacao_impar', a.ocorrencia = 'inconsistente',
             'Marcação ímpar: entrada sem saída ou saída sem entrada', null::int)
          ) q(regra, violou, detalhe, minutos)
         where q.violou
           and (p_colaborador is null or c.id = p_colaborador)
           and (p_departamento is null or c.departamento_id = p_departamento)
           and fn_visivel(c.id)
      ) r), '[]'::jsonb);
end $$;

-- Importação de batidas do relógio (AFD): removida. O ponto é registrado só pelo sistema.
drop function if exists api_importar_batidas(text, jsonb);
delete from paginas where chave = 'importar_afd';  -- as permissões da página saem junto (cascade)

-- -----------------------------------------------------------------------------
-- Permissões
-- -----------------------------------------------------------------------------
revoke execute on function fn_auth_alguma(text, text[], boolean)              from public, anon, authenticated;
revoke execute on function fn_colaborador_do_usuario(uuid)                    from public, anon, authenticated;
revoke execute on function fn_solicitacao_json(solicitacoes)                  from public, anon, authenticated;
revoke execute on function fn_espelho_colaborador(uuid, date, date)           from public, anon, authenticated;
revoke execute on function fn_he_por_percentual(jsonb)                        from public, anon, authenticated;

grant execute on function api_filtros_auxiliares(text)                                 to anon, authenticated;
grant execute on function api_feriados_listar(text, integer)                           to anon, authenticated;
grant execute on function api_feriado_salvar(text, jsonb)                              to anon, authenticated;
grant execute on function api_feriado_excluir(text, uuid)                              to anon, authenticated;
grant execute on function api_ocorrencias_listar(text, date, date, uuid, uuid, text)   to anon, authenticated;
grant execute on function api_ocorrencia_salvar(text, jsonb)                           to anon, authenticated;
grant execute on function api_ocorrencia_excluir(text, uuid)                           to anon, authenticated;
grant execute on function api_minhas_solicitacoes(text)                                to anon, authenticated;
grant execute on function api_solicitacao_criar(text, jsonb)                           to anon, authenticated;
grant execute on function api_solicitacao_cancelar(text, uuid)                         to anon, authenticated;
grant execute on function api_solicitacoes_listar(text, text)                          to anon, authenticated;
grant execute on function api_solicitacao_avaliar(text, uuid, boolean, text)           to anon, authenticated;
grant execute on function api_fechamentos_listar(text)                                 to anon, authenticated;
grant execute on function api_fechamento_previa(text, date, date)                      to anon, authenticated;
grant execute on function api_fechamento_fechar(text, date, date, text)                to anon, authenticated;
grant execute on function api_fechamento_reabrir(text, uuid)                           to anon, authenticated;
grant execute on function api_espelho_ponto(text, date, date, uuid, uuid)              to anon, authenticated;
grant execute on function api_meu_espelho(text, date, date)                            to anon, authenticated;
grant execute on function api_totais_periodo(text, date, date, uuid, uuid)             to anon, authenticated;
grant execute on function api_eventos_folha_salvar(text, jsonb)                        to anon, authenticated;
grant execute on function api_quebra_regras(text, date, date, uuid, uuid)              to anon, authenticated;

-- Atualiza o cache de funções da API do Supabase (PostgREST) para as telas enxergarem as funções novas
notify pgrst, 'reload schema';
