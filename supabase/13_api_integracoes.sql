-- =============================================================================
-- GePonto: API de integrações (v1)
-- Para sistemas de terceiros: relógios/REP, folha de pagamento, ERPs, BI.
--
-- Acesso por chave de API (não por login): cada chave pertence a UMA empresa, enxerga só os
-- colaboradores dela e tem escopos:
--   leitura  → colaboradores, batidas, totais do período e saldos do banco de horas
--   batidas  → importar batidas (origem "importacao"); as originais nunca são alteradas
-- A chave é mostrada uma única vez ao ser criada; o banco guarda só o hash (SHA-256).
--
-- As funções api_v1_* recebem a chave em p_chave. O gateway REST (pasta api-gateway/)
-- expõe essas funções como /v1/... com "Authorization: Bearer <chave>" (docs/api/openapi.yaml).
-- Script re-executável.
-- =============================================================================

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
drop trigger if exists trg_auditoria on chaves_api;
create trigger trg_auditoria after insert or update or delete on chaves_api for each row execute function fn_auditar();
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
                 coalesce(sum(a.banco_min) filter (where a.banco_horas), 0)::int                as banco_horas_periodo_min,
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
