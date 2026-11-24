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
  v_usuario uuid := fn_auth_alguma(p_token, array['ocorrencias', 'justificativas', 'solicitacoes', 'fechamento', 'espelho_ponto',
                                                   'totais_periodo', 'quebra_regras', 'feriados', 'escalas', 'locais_batidas']);
begin
  return jsonb_build_object(
    'empresa', fn_empresa_json(null),
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
    'locais', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'ativo', ativo) order by nome)
                          from locais_ponto), '[]'::jsonb),
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
drop function if exists api_ocorrencias_listar(text, date, date, uuid, uuid, text);
drop function if exists api_ocorrencias_listar(text, date, date, uuid, uuid, text, uuid[]);
-- Afastamentos (afastamento e férias) ficam no menu Afastamentos; o resto, em Ocorrências
create or replace function fn_ausencia_grupo(p_tipo tipo_ausencia)
returns text language sql immutable as $$
  select case when p_tipo in ('afastamento', 'ferias') then 'afastamentos' else 'ocorrencias' end;
$$;

create or replace function api_ocorrencias_listar(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null, p_tipo text default null, p_colaboradores uuid[] default null,
  p_grupo text default 'ocorrencias')
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_grupo text := case when p_grupo = 'afastamentos' then 'afastamentos' else 'ocorrencias' end;
begin
  perform fn_auth(p_token, v_grupo);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula,
             'departamento', d.nome, 'tipo', a.tipo, 'data_inicio', a.data_inicio, 'data_fim', a.data_fim,
             'dias', a.data_fim - a.data_inicio + 1, 'abona', a.abona, 'minutos', a.minutos,
             'justificativa', a.justificativa, 'usuario', u.nome, 'created_at', a.created_at,
             'licenca_id', a.licenca_id, 'licenca', (select tl.descricao from tipos_licenca tl where tl.id = a.licenca_id),
             'fechado', exists (select 1 from fechamentos f
                                 where f.data_inicio <= a.data_fim and f.data_fim >= a.data_inicio
                                   and fn_fechamento_da_empresa(f.empresa_id, a.colaborador_id)))
           order by a.data_inicio desc, c.nome)
      from ausencias a
      join colaboradores c      on c.id = a.colaborador_id
      left join departamentos d on d.id = c.departamento_id
      left join usuarios u      on u.id = a.usuario_id
     where a.data_inicio <= p_fim and a.data_fim >= p_ini
       and fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
       and (p_departamento is null or c.departamento_id = p_departamento)
       and (p_tipo is null or a.tipo::text = p_tipo)
       and fn_ausencia_grupo(a.tipo) = v_grupo
       and fn_visivel(c.id)), '[]'::jsonb);
end $$;

-- Lança a mesma ocorrência para um ou vários colaboradores (lote).
-- p_dados: { id?, colaboradores: [uuid], tipo, data_inicio, data_fim, abona, minutos?, justificativa }
create or replace function api_ocorrencia_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, case when p_dados ->> 'grupo' = 'afastamentos' then 'afastamentos' else 'ocorrencias' end, true);
  d         jsonb := p_dados;
  v_licenca uuid := nullif(d ->> 'licenca_id', '')::uuid;
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
  if fn_ausencia_grupo(v_tipo) <> coalesce(nullif(d ->> 'grupo', ''), 'ocorrencias') then
    raise exception '%', case when fn_ausencia_grupo(v_tipo) = 'afastamentos'
                              then 'Afastamentos e férias são lançados no menu Afastamentos.'
                              else 'Este tipo é lançado no menu Ocorrências.' end;
  end if;
  if v_id is not null and (select fn_ausencia_grupo(tipo) from ausencias where id = v_id) is distinct from fn_ausencia_grupo(v_tipo) then
    raise exception 'Não é possível trocar uma ocorrência por um afastamento (ou o contrário). Exclua e lance de novo.';
  end if;
  if v_tipo = 'afastamento' then
    if v_licenca is null then raise exception 'Escolha o tipo de licença do afastamento.'; end if;
    if not exists (select 1 from tipos_licenca where id = v_licenca
                     and (ativo or id = (select licenca_id from ausencias where id = v_id))) then
      raise exception 'Escolha um tipo de licença ativo.';
    end if;
  else
    v_licenca := null;
  end if;
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
    update ausencias set tipo = v_tipo, data_inicio = v_ini, data_fim = v_fim, licenca_id = v_licenca,
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

  insert into ausencias (colaborador_id, tipo, data_inicio, data_fim, abona, minutos, justificativa, usuario_id, licenca_id)
  select c, v_tipo, v_ini, v_fim, coalesce((d ->> 'abona')::boolean, true), v_min, fn_txt(d, 'justificativa'), v_usuario, v_licenca
    from unnest(v_colabs) c;
  get diagnostics v_qtd = row_count;
  return jsonb_build_object('ok', true, 'qtd', v_qtd);
exception
  when invalid_text_representation then raise exception 'Tipo de ocorrência inválido.';
end $$;

create or replace function api_ocorrencia_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, coalesce((select fn_ausencia_grupo(tipo) from ausencias where id = p_id), 'ocorrencias'), true);
  delete from ausencias where id = p_id and fn_visivel(colaborador_id);
  if not found then raise exception 'Ocorrência não encontrada.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- Tipos de licença (afastamentos) e motivos de batida: criar, alterar, desativar e excluir
-- (não exclui o que já foi lançado: nesse caso, desative)
-- -----------------------------------------------------------------------------
create or replace function api_tipos_licenca_listar(p_token text, p_ativos boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, case when p_ativos then 'afastamentos' else 'tipos_licenca' end);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', t.id, 'descricao', t.descricao, 'abona', t.abona, 'ativo', t.ativo,
                                        'em_uso', (select count(*) from ausencias a where a.licenca_id = t.id))
                     order by t.ativo desc, t.descricao)
      from tipos_licenca t where t.ativo or not p_ativos), '[]'::jsonb);
end $$;

create or replace function api_tipo_licenca_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
begin
  perform fn_auth(p_token, 'tipos_licenca', true);
  if fn_txt(d, 'descricao') is null then raise exception 'Informe a descrição do tipo de licença.'; end if;
  if v_id is null then
    insert into tipos_licenca (descricao, abona, ativo)
    values (fn_txt(d, 'descricao'), coalesce((d ->> 'abona')::boolean, true), coalesce((d ->> 'ativo')::boolean, true))
    returning id into v_id;
  else
    update tipos_licenca set descricao = fn_txt(d, 'descricao'), abona = coalesce((d ->> 'abona')::boolean, true),
                             ativo = coalesce((d ->> 'ativo')::boolean, true)
     where id = v_id;
    if not found then raise exception 'Tipo de licença não encontrado.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
exception when unique_violation then
  raise exception 'Já existe um tipo de licença com esta descrição.';
end $$;

create or replace function api_tipo_licenca_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_qtd int;
begin
  perform fn_auth(p_token, 'tipos_licenca', true);
  select count(*) into v_qtd from ausencias where licenca_id = p_id;
  if v_qtd > 0 then
    raise exception 'Este tipo de licença já foi usado em % afastamento(s) e não pode ser excluído. Desative-o para que não apareça mais.', v_qtd;
  end if;
  delete from tipos_licenca where id = p_id;
  if not found then raise exception 'Tipo de licença não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Quantas vezes o motivo foi usado (batidas, ajustes e solicitações)
create or replace function fn_motivo_em_uso(p_id uuid)
returns integer language sql stable set search_path = public as $$
  select ((select count(*) from batidas where motivo_id = p_id)
        + (select count(*) from batida_ajustes where motivo_id = p_id)
        + (select count(*) from solicitacoes where motivo_id = p_id))::int;
$$;

create or replace function api_motivos_batida_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'motivos_batida');
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', m.id, 'descricao', m.descricao, 'aplicacao', m.aplicacao, 'ativo', m.ativo,
                                        'em_uso', fn_motivo_em_uso(m.id))
                     order by m.ativo desc, m.descricao)
      from motivos_batida m), '[]'::jsonb);
end $$;

create or replace function api_motivo_batida_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  v_apl text := coalesce(fn_txt(d, 'aplicacao'), 'ambos');
begin
  perform fn_auth(p_token, 'motivos_batida', true);
  if fn_txt(d, 'descricao') is null then raise exception 'Informe a descrição do motivo.'; end if;
  if v_apl not in ('inclusao', 'desconsideracao', 'ambos') then raise exception 'Escolha onde o motivo é usado.'; end if;
  if v_id is null then
    insert into motivos_batida (descricao, aplicacao, ativo)
    values (fn_txt(d, 'descricao'), v_apl, coalesce((d ->> 'ativo')::boolean, true))
    returning id into v_id;
  else
    update motivos_batida set descricao = fn_txt(d, 'descricao'), aplicacao = v_apl,
                              ativo = coalesce((d ->> 'ativo')::boolean, true)
     where id = v_id;
    if not found then raise exception 'Motivo não encontrado.'; end if;
  end if;
  return jsonb_build_object('id', v_id);
exception when unique_violation then
  raise exception 'Já existe um motivo com esta descrição.';
end $$;

create or replace function api_motivo_batida_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_qtd int;
begin
  perform fn_auth(p_token, 'motivos_batida', true);
  v_qtd := fn_motivo_em_uso(p_id);
  if v_qtd > 0 then
    raise exception 'Este motivo já foi usado em % lançamento(s) e não pode ser excluído. Desative-o para que não apareça mais.', v_qtd;
  end if;
  delete from motivos_batida where id = p_id;
  if not found then raise exception 'Motivo não encontrado.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- -----------------------------------------------------------------------------
-- AFD — Arquivo Fonte de Dados do REP-P (Portaria MTP 671/2021, Anexo I, leiaute 003)
--   tipo 1: cabeçalho (302 posições, com CRC-16/KERMIT)
--   tipo 7: marcação de ponto do REP-P (137 posições, com hash SHA-256 encadeado)
--   tipo 9: trailer (64 posições)
-- Entram só as marcações registradas pelo sistema (com NSR). As batidas incluídas no tratamento não
-- são marcações do REP e não entram; as desconsideradas entram (o registro original não muda).
-- -----------------------------------------------------------------------------

-- Texto só com caracteres imprimíveis ASCII (sem acentos), cortado/completado à direita com espaços
create or replace function fn_afd_txt(p text, p_tam integer)
returns text language sql immutable as $$
  select rpad(left(regexp_replace(
           translate(coalesce(p, ''), 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑºª',
                                      'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCNoa'),
           '[^ -~]', ' ', 'g'), p_tam), p_tam, ' ');
$$;

-- Número à esquerda com zeros
create or replace function fn_afd_num(p text, p_tam integer)
returns text language sql immutable as $$
  select lpad(right(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'), p_tam), p_tam, '0');
$$;

-- Data e hora no formato AAAA-MM-ddThh:mm:ss-ZZZZ, no fuso do sistema
create or replace function fn_afd_dh(p timestamptz, p_segundos boolean default false)
returns text language sql stable set search_path = public as $$
  select to_char(p at time zone fn_fuso(), case when p_segundos then 'YYYY-MM-DD"T"HH24:MI:SS' else 'YYYY-MM-DD"T"HH24:MI:"00"' end)
         || case when o < interval '0' then '-' else '+' end
         || to_char(justify_hours(abs(extract(epoch from o))::int * interval '1 second'), 'HH24MI')
    from (select (p at time zone fn_fuso()) - (p at time zone 'UTC') as o) x;
$$;

-- CRC-16/KERMIT (polinômio 0x1021 refletido, início 0) em 4 dígitos hexadecimais maiúsculos
create or replace function fn_crc16_kermit(p text)
returns text language plpgsql immutable as $$
declare
  v_crc integer := 0;
  v_b   bytea := convert_to(p, 'UTF8');
  i integer; k integer;
begin
  for i in 0 .. length(v_b) - 1 loop
    v_crc := v_crc # get_byte(v_b, i);
    for k in 1 .. 8 loop
      if (v_crc & 1) = 1 then v_crc := (v_crc >> 1) # 33800;   -- 0x8408
      else v_crc := v_crc >> 1; end if;
    end loop;
  end loop;
  return upper(lpad(to_hex(v_crc), 4, '0'));
end $$;

-- p_dados: { inpi?: nº de registro do programa no INPI, desenvolvedor_doc?: CNPJ/CPF do desenvolvedor }
create or replace function api_afd_gerar(p_token text, p_ini date, p_fim date, p_dados jsonb default '{}'::jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_emp   empresas%rowtype;
  v_cab   text;
  v_lin   text;
  v_hash  text := '';
  v_out   text[] := '{}';
  v_qtd7  integer := 0;
  v_dev   text := regexp_replace(coalesce(p_dados ->> 'desenvolvedor_doc', ''), '[^0-9]', '', 'g');
  r       record;
  v_crlf  text := chr(13) || chr(10);
begin
  perform fn_auth(p_token, 'afd');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 366 then raise exception 'Selecione um período de até 1 ano.'; end if;
  select * into v_emp from empresas where id = fn_empresa_atual();
  if v_emp.id is null then select * into v_emp from empresas order by created_at limit 1; end if;
  if v_emp.id is null or coalesce(v_emp.cnpj, '') = '' then
    raise exception 'Informe o CNPJ da empresa (Configurações › Empresas) para gerar o AFD.';
  end if;

  v_cab := '000000000' || '1' || case when length(regexp_replace(v_emp.cnpj, '[^0-9]', '', 'g')) = 11 then '2' else '1' end
        || fn_afd_num(v_emp.cnpj, 14)
        || fn_afd_num('', 14)                                  -- CNO / CAEPF
        || fn_afd_txt(v_emp.razao_social, 150)
        || fn_afd_num(p_dados ->> 'inpi', 17)                  -- nº de registro do REP-P no INPI
        || to_char(p_ini, 'YYYY-MM-DD') || to_char(p_fim, 'YYYY-MM-DD')
        || fn_afd_dh(now())
        || '003'
        || case when length(v_dev) = 11 then '2' else '1' end
        || fn_afd_num(v_dev, 14)
        || fn_afd_txt('', 30);                                 -- modelo: em branco no REP-P
  v_out := v_out || (v_cab || fn_crc16_kermit(v_cab));

  for r in
    select b.nsr, b.data_hora, b.created_at, b.origem, c.cpf
      from batidas b
      join colaboradores c on c.id = b.colaborador_id
     where b.nsr is not null
       and b.origem <> 'manual'
       and (b.data_hora at time zone fn_fuso())::date between p_ini and p_fim
       and (fn_empresa_atual() is null or c.empresa_id = fn_empresa_atual())
     order by b.nsr
  loop
    v_lin := fn_afd_num(r.nsr::text, 9) || '7' || fn_afd_dh(r.data_hora) || fn_afd_num(r.cpf, 12)
          || fn_afd_dh(r.created_at, true)
          || case r.origem when 'mobile' then '01' when 'web' then '02' when 'relogio' then '04' else '05' end
          || '0';                                               -- marcação online
    v_hash := encode(digest(v_lin || v_hash, 'sha256'), 'hex');
    v_out := v_out || (v_lin || v_hash);
    v_qtd7 := v_qtd7 + 1;
  end loop;

  v_out := v_out || ('999999999' || repeat('000000000', 5) || fn_afd_num(v_qtd7::text, 9) || '9');
  return jsonb_build_object(
    'nome_arquivo', 'AFD' || fn_afd_num(p_dados ->> 'inpi', 17) || fn_afd_num(v_emp.cnpj, 14) || 'REP_P.txt',
    'conteudo', array_to_string(v_out, v_crlf) || v_crlf,
    'marcacoes', v_qtd7,
    'empresa', coalesce(v_emp.nome_fantasia, v_emp.razao_social));
end $$;

-- -----------------------------------------------------------------------------
-- Escalas: previsão de trabalho ou folga em dias específicos, fora do padrão da jornada
--   trabalho → o dia passa a ter previsão normal (mesmo em folga da jornada); no feriado, a previsão vale
--              e todo o tempo trabalhado é hora extra de feriado (dobro)
--   folga    → o dia fica sem previsão (mesmo sendo dia de trabalho na jornada)
-- -----------------------------------------------------------------------------

-- Grade do período: por colaborador e dia, o padrão da jornada, o feriado e a escala lançada
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
                                      'id', e.id, 'tipo', e.tipo, 'lancamento_id', e.lancamento_id,
                                      'nome', (select l.nome from escala_lancamentos l where l.id = e.lancamento_id),
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

-- As escalas são lançadas como um registro (escala_lancamentos) com nome, período de até 30 dias,
-- dias da semana, horários e colaboradores. O registro fica guardado e pode ser alterado ou excluído.
drop function if exists api_escala_salvar(text, jsonb);
drop function if exists api_escala_excluir(text, jsonb);

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
    'fechado', exists (select 1 from escalas e where e.lancamento_id = l.id and fn_periodo_fechado(e.data, e.colaborador_id)),
    'lancado_por', (select nome from usuarios where id = l.usuario_id), 'lancado_em', l.created_at,
    'alterado_por', (select nome from usuarios where id = l.alterado_por),
    'alterado_em', case when l.updated_at > l.created_at + interval '1 second' then l.updated_at end);
$$;

-- Escalas lançadas que alcançam o período (com algum colaborador visível ao usuário)
create or replace function api_escalas_lancamentos(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_busca text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'escalas');
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  return jsonb_build_object(
    'pode_editar', fn_pode(v_usuario, 'escalas', true),
    'escalas', coalesce((
      select jsonb_agg(fn_escala_lancamento_json(l) order by l.data_inicio desc, l.nome)
        from escala_lancamentos l
       where l.data_inicio <= p_fim and l.data_fim >= p_ini
         and exists (select 1 from unnest(l.colaboradores) x where fn_visivel(x)
                        and (p_colaboradores is null or cardinality(p_colaboradores) = 0 or x = any(p_colaboradores)))
         and (coalesce(trim(p_busca), '') = '' or l.nome ilike '%' || trim(p_busca) || '%'
              or l.observacao ilike '%' || trim(p_busca) || '%')), '[]'::jsonb));
end $$;

create or replace function api_escala_lancamento(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  l escala_lancamentos;
begin
  perform fn_auth(p_token, 'escalas');
  select * into l from escala_lancamentos where id = p_id;
  if l.id is null then raise exception 'Escala não encontrada.'; end if;
  return fn_escala_lancamento_json(l);
end $$;

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

-- Exclui a escala: os dias voltam ao padrão da jornada
create or replace function api_escala_lancamento_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  l escala_lancamentos;
begin
  perform fn_auth(p_token, 'escalas', true);
  select * into l from escala_lancamentos where id = p_id for update;
  if l.id is null then raise exception 'Escala não encontrada.'; end if;
  if exists (select 1 from unnest(l.colaboradores) x where not fn_visivel(x)) then
    raise exception 'A escala tem colaboradores fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  if exists (select 1 from escalas e where e.lancamento_id = p_id and fn_periodo_fechado(e.data, e.colaborador_id)) then
    raise exception 'A escala alcança um período fechado. Reabra o período para excluí-la.';
  end if;
  delete from escala_lancamentos where id = p_id;   -- os dias saem junto (on delete cascade)
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
  if fn_periodo_fechado(v_data, v_colab) then
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
                                             'fechado', fn_periodo_fechado(s.data, s.colaborador_id))
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
        from fechamentos f left join usuarios u on u.id = f.usuario_id
       where f.empresa_id is null or fn_empresa_atual() is null or f.empresa_id = fn_empresa_atual()), '[]'::jsonb));
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
     where fn_visivel(c.id) and (fn_empresa_atual() is null or c.empresa_id = fn_empresa_atual());

  return jsonb_build_object(
    'resumo', jsonb_build_object(
      'colaboradores', (select count(distinct colaborador_id) from pg_temp._prev),
      'inconsistentes', (select count(*) from pg_temp._prev where ocorrencia = 'inconsistente'),
      'faltas', (select count(*) from pg_temp._prev where falta),
      'sem_jornada', (select count(*) from pg_temp._prev where ocorrencia = 'sem_jornada'),
      'solicitacoes', (select count(*) from solicitacoes
                        where status = 'pendente' and data between p_ini and p_fim and fn_visivel(colaborador_id)),
      'ja_fechado', exists (select 1 from fechamentos f where f.data_inicio <= p_fim and f.data_fim >= p_ini
                               and fn_fechamento_da_empresa(f.empresa_id, null))),
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
  if exists (select 1 from fechamentos f where f.data_inicio <= p_fim and f.data_fim >= p_ini
              and fn_fechamento_da_empresa(f.empresa_id, null)) then
    raise exception 'Parte deste período já está fechada nesta empresa.';
  end if;

  -- Consolida o banco de horas antes de congelar
  perform fn_processar_banco_horas(p_ini, p_fim);
  insert into fechamentos (data_inicio, data_fim, observacao, usuario_id, empresa_id)
  values (p_ini, p_fim, nullif(trim(p_observacao), ''), v_usuario, fn_empresa_atual())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function api_fechamento_reabrir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare f fechamentos%rowtype;
begin
  perform fn_auth(p_token, 'fechamento', true);
  delete from fechamentos where id = p_id
     and (empresa_id is null or fn_empresa_atual() is null or empresa_id = fn_empresa_atual())
  returning * into f;
  if f.id is null then raise exception 'Fechamento não encontrado nesta empresa.'; end if;
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
               'previsto', fn_horario_dia(a.colaborador_id, a.data),
               'escala', a.escala,
               'previsto_min', a.previsto_min, 'trabalhado_min', a.trabalhado_min,
               'extra_min', a.extra_min, 'debito_min', a.debito_min, 'he_percentual', a.he_percentual::float8,
               'atraso_min', a.atraso_min, 'saida_antecipada_min', a.saida_antecipada_min,
               'noturno_min', a.noturno_reduzido_min, 'abonado_min', a.abonado_min,
               'banco_horas', a.banco_horas, 'ocorrencia', a.ocorrencia, 'pre_assinalado', a.pre_assinalado,
               'observacao', coalesce(
                  (select au.justificativa from ausencias au
                    where au.colaborador_id = a.colaborador_id and a.data between au.data_inicio and au.data_fim
                    order by au.minutos nulls first limit 1),
                  (select es.observacao from escalas es
                    where es.colaborador_id = a.colaborador_id and es.data = a.data),
                  (select f.descricao from feriados f where f.data = a.data and a.feriado)),
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
    'empresa', fn_empresa_json((select empresa_id from colaboradores where id = v_colab)),
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'emitido_em', now(),
    'emitido_por', (select nome from usuarios where id = v_usuario),
    'espelhos', jsonb_build_array(fn_espelho_colaborador(v_colab, p_ini, p_fim)));
end $$;

-- -----------------------------------------------------------------------------
-- Totais do período (base da exportação para a folha) e eventos da folha
-- -----------------------------------------------------------------------------
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
                 -- DSR perdido: semanas (dom–sáb) com falta não justificada em dia útil da jornada
                 count(distinct date_trunc('week', t.data + 1))
                   filter (where t.falta and fn_dia_util(t.jornada_id, t.data, t.escala))            as dsr_perdidos,
                 coalesce(sum(t.banco_min) filter (where t.banco_horas), 0)::int                   as bh_periodo_min,
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
revoke execute on function fn_motivo_em_uso(uuid)                             from public, anon, authenticated;
revoke execute on function fn_crc16_kermit(text)                              from public, anon, authenticated;
revoke execute on function fn_afd_dh(timestamptz, boolean)                    from public, anon, authenticated;
revoke execute on function fn_afd_txt(text, integer)                          from public, anon, authenticated;
revoke execute on function fn_afd_num(text, integer)                          from public, anon, authenticated;

grant execute on function api_filtros_auxiliares(text)                                 to anon, authenticated;
grant execute on function api_feriados_listar(text, integer)                           to anon, authenticated;
grant execute on function api_feriado_salvar(text, jsonb)                              to anon, authenticated;
grant execute on function api_feriado_excluir(text, uuid)                              to anon, authenticated;
grant execute on function api_ocorrencias_listar(text, date, date, uuid, uuid, text, uuid[], text) to anon, authenticated;
grant execute on function api_tipos_licenca_listar(text, boolean)                     to anon, authenticated;
grant execute on function api_tipo_licenca_salvar(text, jsonb)                        to anon, authenticated;
grant execute on function api_tipo_licenca_excluir(text, uuid)                        to anon, authenticated;
grant execute on function api_motivos_batida_listar(text)                             to anon, authenticated;
grant execute on function api_motivo_batida_salvar(text, jsonb)                       to anon, authenticated;
grant execute on function api_motivo_batida_excluir(text, uuid)                       to anon, authenticated;
grant execute on function api_afd_gerar(text, date, date, jsonb)                       to anon, authenticated;
grant execute on function api_ocorrencia_salvar(text, jsonb)                           to anon, authenticated;
grant execute on function api_ocorrencia_excluir(text, uuid)                           to anon, authenticated;
grant execute on function api_escalas_grade(text, date, date, uuid, uuid, uuid[])              to anon, authenticated;
grant execute on function api_escalas_lancamentos(text, date, date, uuid[], text)         to anon, authenticated;
grant execute on function api_escala_lancamento(text, uuid)                              to anon, authenticated;
grant execute on function api_escala_lancamento_salvar(text, jsonb)                      to anon, authenticated;
grant execute on function api_escala_lancamento_excluir(text, uuid)                      to anon, authenticated;
grant execute on function api_minhas_solicitacoes(text)                              to anon, authenticated;
grant execute on function api_solicitacao_criar(text, jsonb)                           to anon, authenticated;
grant execute on function api_solicitacao_cancelar(text, uuid)                         to anon, authenticated;
grant execute on function api_solicitacoes_listar(text, text)                          to anon, authenticated;
grant execute on function api_solicitacao_avaliar(text, uuid, boolean, text)           to anon, authenticated;
grant execute on function api_fechamentos_listar(text)                                 to anon, authenticated;
grant execute on function api_fechamento_previa(text, date, date)                      to anon, authenticated;
grant execute on function api_fechamento_fechar(text, date, date, text)                to anon, authenticated;
grant execute on function api_fechamento_reabrir(text, uuid)                           to anon, authenticated;
grant execute on function api_espelho_ponto(text, date, date, uuid, uuid, uuid[])              to anon, authenticated;
grant execute on function api_meu_espelho(text, date, date)                            to anon, authenticated;
grant execute on function api_totais_periodo(text, date, date, uuid, uuid, uuid[])             to anon, authenticated;
grant execute on function api_eventos_folha_salvar(text, jsonb)                        to anon, authenticated;
grant execute on function api_quebra_regras(text, date, date, uuid, uuid, uuid[])              to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Relatório de Banco de Horas: por colaborador, saldo anterior, créditos e débitos do período
-- (automáticos), ajustes manuais, conversões (pagamento/desconto) e saldo final
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_banco_horas(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_banco_horas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 366 then raise exception 'Selecione um período de até 1 ano.'; end if;
  perform fn_banco_horas_atualizar();
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'itens', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.nome)
        from (
          select c.id as colaborador_id, c.nome, c.matricula, d.nome as departamento, g.nome as cargo,
                 coalesce(sum(b.minutos) filter (where b.data < p_ini), 0)::int as saldo_anterior,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos > 0), 0)::int as creditos,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos < 0), 0)::int as debitos,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.origem = 'manual' and b.tipo::text <> 'conversao'), 0)::int as ajustes,
                 coalesce(sum(b.minutos) filter (where b.data between p_ini and p_fim and b.tipo::text = 'conversao'), 0)::int as conversoes,
                 coalesce(sum(b.minutos) filter (where b.data <= p_fim), 0)::int as saldo_final,
                 count(*) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos > 0)::int as dias_credito,
                 count(*) filter (where b.data between p_ini and p_fim and b.origem = 'automatico' and b.minutos < 0)::int as dias_debito
            from colaboradores c
            left join departamentos d on d.id = c.departamento_id
            left join cargos g        on g.id = c.cargo_id
            left join banco_horas b   on b.colaborador_id = c.id and b.data <= p_fim
           where fn_visivel(c.id)
             and fn_filtro_colaborador(c.id, null, p_colaboradores)
             and (p_departamento is null or c.departamento_id = p_departamento)
           group by c.id, c.nome, c.matricula, d.nome, g.nome
          having count(b.id) > 0
              or (c.controla_ponto and coalesce(c.data_desligamento, p_ini) >= p_ini)
        ) x), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- Detalhamento do Banco de Horas: por colaborador, dia a dia, as batidas, o previsto, o trabalhado,
-- o que entrou no banco (apuração, ajustes e conversões) e o saldo acumulado. Até 92 dias.
-- Os valores do banco vêm dos lançamentos gravados: fecham com o Resumo, inclusive em períodos fechados.
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_banco_horas_detalhe(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_ate date := least(p_fim, fn_banco_ate());
  v_tz  text := fn_fuso();
  v_um  uuid := case when cardinality(p_colaboradores) = 1 then p_colaboradores[1] end;
begin
  perform fn_auth(p_token, 'relatorio_banco_horas_detalhe');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 91 then raise exception 'Selecione um período de até 92 dias (três meses).'; end if;
  perform fn_banco_horas_atualizar();
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim, 'apurado_ate', v_ate),
    'itens', coalesce((
      with col as materialized (
        select c.id, c.nome, c.matricula, d.nome as departamento, g.nome as cargo,
               coalesce((select sum(b.minutos) from banco_horas b
                          where b.colaborador_id = c.id and b.data < p_ini), 0)::int as saldo_anterior
          from colaboradores c
          left join departamentos d on d.id = c.departamento_id
          left join cargos g        on g.id = c.cargo_id
         where fn_visivel(c.id)
           and fn_filtro_colaborador(c.id, null, p_colaboradores)
           and (p_departamento is null or c.departamento_id = p_departamento)
           and (exists (select 1 from banco_horas b where b.colaborador_id = c.id and b.data <= p_fim)
                or (c.controla_ponto and coalesce(c.data_desligamento, p_ini) >= p_ini))
      ),
      apu as materialized (
        select a.* from fn_apuracao(p_ini, v_ate, v_um) a join col on col.id = a.colaborador_id
      ),
      bat as materialized (
        select b.colaborador_id, b.data_referencia as data,
               jsonb_agg(jsonb_build_object(
                 'hora', to_char(b.data_hora at time zone v_tz, 'HH24:MI'),
                 'sentido', b.sentido, 'turno', b.turno, 'manual', b.origem = 'manual')
                 order by b.data_hora, b.id) as batidas
          from fn_batidas_periodo(p_ini, v_ate, v_um) b
          join col on col.id = b.colaborador_id
         where b.status = 'valida'
         group by b.colaborador_id, b.data_referencia
      ),
      lan as materialized (
        select b.colaborador_id, b.data,
               coalesce(sum(b.minutos) filter (where b.origem = 'automatico'), 0)::int as banco_min,
               max(b.descricao) filter (where b.origem = 'automatico') as descricao,
               coalesce(jsonb_agg(jsonb_build_object('tipo', b.tipo, 'minutos', b.minutos, 'descricao', b.descricao)
                                  order by b.created_at, b.id) filter (where b.origem <> 'automatico'), '[]'::jsonb) as manuais,
               sum(b.minutos)::int as total
          from banco_horas b
          join col on col.id = b.colaborador_id
         where b.data between p_ini and p_fim
         group by b.colaborador_id, b.data
      ),
      chave as (
        select colaborador_id, data from apu
         where previsto_min > 0 or qtd_batidas > 0 or ocorrencia like 'ausencia:%'
        union select colaborador_id, data from lan
        union select colaborador_id, data from bat
      ),
      dia as (
        select k.colaborador_id, k.data, a.previsto_min, a.trabalhado_min, a.saldo_min, a.ocorrencia,
               coalesce(a.pre_assinalado, false) as pre_assinalado, a.escala, coalesce(a.fechado, false) as fechado,
               a.banco_horas, bat.batidas, l.descricao, l.manuais,
               coalesce(l.banco_min, 0) as banco_min,
               col.saldo_anterior
                 + sum(coalesce(l.total, 0)) over (partition by k.colaborador_id order by k.data) as saldo_acumulado
          from chave k
          join col        on col.id = k.colaborador_id
          left join apu a on a.colaborador_id = k.colaborador_id and a.data = k.data
          left join bat   on bat.colaborador_id = k.colaborador_id and bat.data = k.data
          left join lan l on l.colaborador_id = k.colaborador_id and l.data = k.data
      ),
      dias as (
        select x.colaborador_id,
               jsonb_agg(jsonb_build_object(
                 'data', x.data, 'horario', fn_horario_dia(x.colaborador_id, x.data),
                 'feriado', (select f.descricao from feriados f where f.data = x.data),
                 'escala', x.escala, 'ocorrencia', x.ocorrencia, 'batidas', coalesce(x.batidas, '[]'::jsonb),
                 'pre_assinalado', x.pre_assinalado, 'previsto_min', x.previsto_min,
                 'trabalhado_min', x.trabalhado_min, 'saldo_min', x.saldo_min,
                 'banco_horas', x.banco_horas, 'banco_min', x.banco_min,
                 'descricao', x.descricao, 'lancamentos', coalesce(x.manuais, '[]'::jsonb),
                 'saldo_acumulado', x.saldo_acumulado, 'fechado', x.fechado) order by x.data) as dias
          from dia x
         group by x.colaborador_id
      )
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', col.id, 'nome', col.nome, 'matricula', col.matricula,
               'departamento', col.departamento, 'cargo', col.cargo, 'saldo_anterior', col.saldo_anterior,
               'saldo_final', col.saldo_anterior
                 + coalesce((select sum(l.total) from lan l where l.colaborador_id = col.id), 0),
               'dias', coalesce(dias.dias, '[]'::jsonb)) order by col.nome, col.id)
        from col left join dias on dias.colaborador_id = col.id), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- Relatórios de VT e de VA: dias marcados na jornada para o benefício, por colaborador que o recebe
-- (tipo da situação vigente no dia), e se o dia conta. Conta com um turno completo ou com os dois,
-- conforme a configuração; dia previsto com um turno só precisa apenas dele. Só dias encerrados; até 92 dias.
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_beneficio(
  p_token text, p_tipo text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_ate date := least(p_fim, fn_hoje() - 1);
  v_tz  text := fn_fuso();
  v_turnos text := coalesce((select beneficio_turnos from empresa where id = 1), 'um');
  v_um  uuid := case when cardinality(p_colaboradores) = 1 then p_colaboradores[1] end;
begin
  if p_tipo is null or p_tipo not in ('vt', 'va') then raise exception 'Informe se o relatório é de VT ou de VA.'; end if;
  perform fn_auth(p_token, 'relatorio_' || p_tipo);
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 91 then raise exception 'Selecione um período de até 92 dias (três meses).'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim, 'apurado_ate', v_ate),
    'turnos', v_turnos,
    'itens', coalesce((
      with apu as materialized (
        select a.*, c.nome, c.matricula, d.nome as departamento,
               t.id as tipo_id, t.nome as tipo_nome, t.codigo, t.valor_diario
          from fn_apuracao(p_ini, v_ate, v_um) a
          join colaboradores c      on c.id = a.colaborador_id
          left join departamentos d on d.id = c.departamento_id
          join lateral (
            select s.tipo_vt_id, s.tipo_va_id from colaborador_situacoes s
             where s.colaborador_id = a.colaborador_id and s.data_inicio <= a.data
             order by s.data_inicio desc limit 1) s on true
          join tipos_beneficio t    on t.id = case p_tipo when 'vt' then s.tipo_vt_id else s.tipo_va_id end
          join jornadas j           on j.id = a.jornada_id
          join jornada_dias jd      on jd.jornada_id = j.id
                                   and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, a.data)
         where case p_tipo when 'vt' then jd.recebe_vt else jd.recebe_va end
           and fn_visivel(c.id)
           and fn_filtro_colaborador(c.id, null, p_colaboradores)
           and (p_departamento is null or c.departamento_id = p_departamento)
      ),
      bat as materialized (
        select x.colaborador_id, x.data_referencia as data,
               count(distinct x.turno) filter (where x.sentido = 'E' and x.ps = 'S' and x.pt = x.turno)::int as turnos,
               jsonb_agg(jsonb_build_object('hora', to_char(x.data_hora at time zone v_tz, 'HH24:MI'),
                                            'sentido', x.sentido, 'turno', x.turno, 'manual', x.origem = 'manual')
                         order by x.data_hora, x.id) as batidas
          from (select b.*, lead(b.sentido) over w as ps, lead(b.turno) over w as pt
                  from fn_batidas_periodo(p_ini, v_ate, v_um) b
                 where b.status = 'valida'
                window w as (partition by b.colaborador_id, b.data_referencia order by b.data_hora, b.id)) x
         group by x.colaborador_id, x.data_referencia
      ),
      dia as (
        select a.*, coalesce(b.batidas, '[]'::jsonb) as batidas,
               case when a.pre_assinalado then 2 else coalesce(b.turnos, 0) end as turnos,
               case when jd.folga or jd.entrada is null or jd.saida_intervalo is null then 1 else 2 end as turnos_previstos
          from apu a
          left join bat b on b.colaborador_id = a.colaborador_id and b.data = a.data
          left join lateral fn_jornada_dia(a.colaborador_id, a.data) jd on true
      ),
      res as (
        select x.*, x.turnos >= case when v_turnos = 'dois' then x.turnos_previstos else 1 end as computa from dia x
      )
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', g.colaborador_id, 'nome', g.nome, 'matricula', g.matricula, 'departamento', g.departamento,
               'dias_marcados', g.marcados, 'dias_computados', g.computados, 'valor_total', g.valor, 'dias', g.dias)
             order by g.nome, g.colaborador_id)
        from (
          select r.colaborador_id, r.nome, r.matricula, r.departamento,
                 count(*) as marcados, count(*) filter (where r.computa) as computados,
                 coalesce(sum(r.valor_diario) filter (where r.computa), 0) as valor,
                 jsonb_agg(jsonb_build_object(
                   'data', r.data, 'tipo', r.tipo_nome, 'codigo', r.codigo, 'valor_diario', r.valor_diario,
                   'batidas', r.batidas, 'pre_assinalado', r.pre_assinalado, 'turnos', r.turnos,
                   'turnos_previstos', r.turnos_previstos, 'trabalhado_min', r.trabalhado_min,
                   'ocorrencia', r.ocorrencia, 'escala', r.escala, 'computa', r.computa) order by r.data) as dias
            from res r
           group by r.colaborador_id, r.nome, r.matricula, r.departamento) g), '[]'::jsonb));
end $$;

-- -----------------------------------------------------------------------------
-- Relatório de Escalas: cada dia com escala (trabalho ou folga) no período, com o nome da
-- escala, o horário, se era feriado e o que foi realizado (trabalhado, saldo e ocorrência)
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_escalas(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null,
  p_departamento uuid default null, p_tipo text default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_escalas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 92 then raise exception 'Selecione um período de até 3 meses.'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', d.nome,
               'data', e.data, 'tipo', e.tipo, 'escala', l.nome,
               'entrada', to_char(e.entrada, 'HH24:MI'), 'saida_intervalo', to_char(e.saida_intervalo, 'HH24:MI'),
               'retorno_intervalo', to_char(e.retorno_intervalo, 'HH24:MI'), 'saida', to_char(e.saida, 'HH24:MI'),
               'feriado', f.descricao,
               'previsto_min', a.previsto_min, 'trabalhado_min', a.trabalhado_min, 'saldo_min', a.saldo_min,
               'qtd_batidas', a.qtd_batidas, 'falta', a.falta, 'he_percentual', a.he_percentual,
               'realizado', e.data < fn_hoje())
             order by c.nome, e.data)
        from escalas e
        join colaboradores c            on c.id = e.colaborador_id
        left join departamentos d       on d.id = c.departamento_id
        left join escala_lancamentos l  on l.id = e.lancamento_id
        left join feriados f            on f.data = e.data
        left join fn_apuracao(p_ini, p_fim) a on a.colaborador_id = e.colaborador_id and a.data = e.data
       where e.data between p_ini and p_fim
         and fn_visivel(c.id)
         and fn_filtro_colaborador(c.id, null, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)
         and (p_tipo is null or e.tipo = p_tipo)), '[]'::jsonb));
end $$;

-- Adicional noturno: dias com horas na faixa noturna da regra de cálculo (até 31 dias por consulta)
create or replace function api_relatorio_noturno(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_noturno');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 30 then raise exception 'Selecione um período de até 31 dias (um mês).'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', d.nome,
               'data', a.data, 'horario', fn_horario_dia(c.id, a.data),
               'trabalhado_min', a.trabalhado_min, 'noturno_min', a.noturno_min,
               'noturno_reduzido_min', a.noturno_reduzido_min,
               'percentual', coalesce(pe.percentual_noturno, 20)::float8,
               'faixa', to_char(coalesce(pe.noturno_inicio, '22:00'), 'HH24:MI') || '–' || to_char(coalesce(pe.noturno_fim, '05:00'), 'HH24:MI'),
               'reduzida', coalesce(pe.hora_noturna_reduzida, true))
             order by c.nome, a.data)
        from fn_apuracao(p_ini, least(p_fim, fn_hoje())) a
        join colaboradores c          on c.id = a.colaborador_id
        left join departamentos d     on d.id = c.departamento_id
        left join perfis_eventos pe   on pe.id = fn_perfil_vigente(c.id, a.data)
       where a.noturno_min > 0
         and fn_visivel(c.id)
         and (fn_empresa_atual() is null or c.empresa_id = fn_empresa_atual())
         and fn_filtro_colaborador(c.id, null, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)), '[]'::jsonb));
end $$;

-- Folgas: dias de folga da jornada, da escala ou lançados como ocorrência, e se houve trabalho (até 31 dias)
create or replace function api_relatorio_folgas(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_folgas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 30 then raise exception 'Selecione um período de até 31 dias (um mês).'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', d.nome,
               'data', a.data,
               'origem', case when a.ocorrencia = 'ausencia:folga' then 'ocorrencia'
                              when jd.escala = 'folga' then 'escala' else 'jornada' end,
               'feriado', f.descricao,
               'trabalhou', a.qtd_batidas > 0, 'trabalhado_min', a.trabalhado_min, 'extra_min', a.extra_min,
               'he_percentual', a.he_percentual::float8,
               'realizado', a.data < fn_hoje())
             order by c.nome, a.data)
        from fn_apuracao(p_ini, p_fim) a
        join colaboradores c        on c.id = a.colaborador_id
        left join departamentos d   on d.id = c.departamento_id
        left join feriados f        on f.data = a.data
        left join lateral fn_jornada_dia(c.id, a.data) jd on true
       where (a.ocorrencia = 'ausencia:folga' or (coalesce(jd.folga, false) and a.jornada_id is not null))
         and fn_visivel(c.id)
         and (fn_empresa_atual() is null or c.empresa_id = fn_empresa_atual())
         and fn_filtro_colaborador(c.id, null, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)), '[]'::jsonb));
end $$;

-- Dados cadastrais dos colaboradores (a tela escolhe as colunas).
-- p_situacao: 'ativos' (sem desligamento até hoje) · 'desligados' · null (todos)
create or replace function api_relatorio_colaboradores(
  p_token text, p_situacao text default 'ativos', p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_colaboradores');
  return jsonb_build_object('itens', coalesce((
    select jsonb_agg(jsonb_build_object(
             'colaborador_id', c.id, 'matricula', c.matricula, 'nome', c.nome, 'nome_social', c.nome_social,
             'cpf', c.cpf, 'pis', c.pis, 'rg', c.rg, 'data_nascimento', c.data_nascimento, 'sexo', c.sexo,
             'email', c.email, 'telefone', c.telefone,
             'cep', c.cep, 'logradouro', c.logradouro, 'numero', c.numero, 'complemento', c.complemento,
             'bairro', c.bairro, 'cidade', c.cidade, 'uf', c.uf,
             'empresa', coalesce(e.nome_fantasia, e.razao_social),
             'cargo', g.nome, 'cbo', g.cbo, 'departamento', d.nome, 'jornada', j.nome,
             'regra', pe.nome, 'gestor', ge.nome,
             'data_admissao', c.data_admissao, 'data_desligamento', c.data_desligamento,
             'situacao', case when c.data_desligamento <= fn_hoje() then 'desligado' else c.situacao::text end,
             'salario', c.salario::float8,
             'controla_ponto', c.controla_ponto, 'controle_ponto_inicio', c.controle_ponto_inicio,
             'local_ponto_modo', c.local_ponto_modo,
             'usuario', (select u.login from usuarios u where u.colaborador_id = c.id limit 1),
             'observacoes', c.observacoes)
           order by c.nome)
      from colaboradores c
      left join empresas e        on e.id = c.empresa_id
      left join cargos g          on g.id = c.cargo_id
      left join departamentos d   on d.id = c.departamento_id
      left join jornadas j        on j.id = c.jornada_id
      left join perfis_eventos pe on pe.id = c.perfil_evento_id
      left join colaboradores ge  on ge.id = c.gestor_id
     where fn_visivel(c.id)
       and (fn_empresa_atual() is null or c.empresa_id = fn_empresa_atual())
       and fn_filtro_colaborador(c.id, null, p_colaboradores)
       and (p_departamento is null or c.departamento_id = p_departamento)
       and (p_situacao is null
            or (p_situacao = 'ativos'     and (c.data_desligamento is null or c.data_desligamento > fn_hoje()))
            or (p_situacao = 'desligados' and c.data_desligamento <= fn_hoje()))), '[]'::jsonb));
end $$;

-- Faltas: dias previstos, encerrados e sem batidas (até 92 dias). Inclui as abonadas por justificativa;
-- os dias cobertos por ocorrência ou afastamento que abona (férias, atestado…) não são falta.
-- situacao: 'injustificada' (sem justificativa) · 'justificada' (com motivo, sem abono) · 'abonada'
create or replace function api_relatorio_faltas(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_faltas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 91 then raise exception 'Selecione um período de até 92 dias (três meses).'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim),
    'itens', coalesce((
      select jsonb_agg(jsonb_build_object(
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', d.nome,
               'data', a.data, 'horario', fn_horario_dia(c.id, a.data), 'previsto_min', a.previsto_min,
               'situacao', case when not a.falta then 'abonada'
                                when j.id is not null or au.id is not null then 'justificada'
                                else 'injustificada' end,
               'motivo', coalesce(j.motivo, au.motivo),
               'abonado_min', case when a.falta then 0 else a.abono_justificativa_min end,
               'folha', a.falta_folha or (a.falta and not a.banco_horas),
               'fechado', a.fechado)
             order by c.nome, a.data)
        from fn_apuracao(p_ini, least(p_fim, fn_hoje() - 1)) a
        join colaboradores c      on c.id = a.colaborador_id
        left join departamentos d on d.id = c.departamento_id
        left join justificativas j on j.colaborador_id = a.colaborador_id and j.data = a.data and j.tipo = 'falta'
        left join lateral (
          select x.id, coalesce(tl.descricao, initcap(replace(x.tipo::text, '_', ' ')))
                       || coalesce(' — ' || nullif(trim(x.justificativa), ''), '') as motivo
            from ausencias x
            left join tipos_licenca tl on tl.id = x.licenca_id
           where x.colaborador_id = a.colaborador_id and a.data between x.data_inicio and x.data_fim
           order by x.minutos nulls first
           limit 1) au on true
       where (a.falta or (a.falta_bruta and a.abono_justificativa_min > 0))
         and fn_visivel(c.id)
         and (fn_empresa_atual() is null or c.empresa_id = fn_empresa_atual())
         and fn_filtro_colaborador(c.id, null, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)), '[]'::jsonb));
end $$;

-- Assiduidade: por colaborador, dias previstos, faltas, atrasos e saídas antecipadas no período
-- (só dias já encerrados; até 92 dias)
create or replace function api_relatorio_assiduidade(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'relatorio_assiduidade');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 91 then raise exception 'Selecione um período de até 92 dias (três meses).'; end if;
  return jsonb_build_object(
    'periodo', jsonb_build_object('inicio', p_ini, 'fim', p_fim, 'apurado_ate', least(p_fim, fn_hoje() - 1)),
    'itens', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.colaborador)
        from (
          select c.id as colaborador_id, c.nome as colaborador, c.matricula, d.nome as departamento,
                 count(*) filter (where a.previsto_min > 0)                        as dias_previstos,
                 count(*) filter (where a.previsto_min > 0 and a.qtd_batidas > 0)   as dias_trabalhados,
                 count(*) filter (where a.falta)                                    as faltas,
                 count(*) filter (where a.falta_bruta and not a.falta
                                    and a.abono_justificativa_min > 0)              as faltas_abonadas,
                 count(*) filter (where a.previsto_min > 0 and a.qtd_batidas = 0 and not a.falta
                                    and a.ocorrencia like 'ausencia:%')             as dias_ausencia,
                 count(*) filter (where a.atraso_min > 0)                           as atrasos,
                 coalesce(sum(a.atraso_min), 0)                                     as atraso_min,
                 count(*) filter (where a.saida_antecipada_min > 0)                 as saidas_antecipadas,
                 coalesce(sum(a.saida_antecipada_min), 0)                           as saida_antecipada_min,
                 count(*) filter (where a.falta or a.atraso_min > 0 or a.saida_antecipada_min > 0)
                                                                                    as dias_com_ocorrencia
            from fn_apuracao(p_ini, least(p_fim, fn_hoje() - 1)) a
            join colaboradores c      on c.id = a.colaborador_id
            left join departamentos d on d.id = c.departamento_id
           where fn_visivel(c.id)
             and (fn_empresa_atual() is null or c.empresa_id = fn_empresa_atual())
             and fn_filtro_colaborador(c.id, null, p_colaboradores)
             and (p_departamento is null or c.departamento_id = p_departamento)
           group by c.id, c.nome, c.matricula, d.nome) x), '[]'::jsonb));
end $$;

grant execute on function api_relatorio_noturno(text, date, date, uuid[], uuid)         to anon, authenticated;
grant execute on function api_relatorio_colaboradores(text, text, uuid[], uuid)       to anon, authenticated;
grant execute on function api_relatorio_faltas(text, date, date, uuid[], uuid)          to anon, authenticated;
grant execute on function api_relatorio_assiduidade(text, date, date, uuid[], uuid)     to anon, authenticated;
grant execute on function api_relatorio_folgas(text, date, date, uuid[], uuid)          to anon, authenticated;
grant execute on function api_relatorio_banco_horas(text, date, date, uuid[], uuid)     to anon, authenticated;
grant execute on function api_relatorio_banco_horas_detalhe(text, date, date, uuid[], uuid) to anon, authenticated;
grant execute on function api_relatorio_beneficio(text, text, date, date, uuid[], uuid) to anon, authenticated;
grant execute on function api_relatorio_escalas(text, date, date, uuid[], uuid, text)    to anon, authenticated;

-- Atualiza o cache de funções da API do Supabase (PostgREST) para as telas enxergarem as funções novas
notify pgrst, 'reload schema';
