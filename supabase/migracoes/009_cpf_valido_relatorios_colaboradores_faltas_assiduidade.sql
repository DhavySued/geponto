-- =============================================================================
-- GePonto: atualização 009
-- • CPF do colaborador: confere os dígitos verificadores ao salvar o cadastro
-- • Relatório de Colaboradores: dados cadastrais com colunas à escolha
-- • Listagem de Faltas e Listagem de Assiduidade
-- Requer: atualização 008. Pode ser executado mais de uma vez.
-- =============================================================================

-- [02_functions]
-- CPF válido: 11 dígitos, não todos iguais e com os dois dígitos verificadores corretos
create or replace function fn_cpf_valido(p_cpf text)
returns boolean language plpgsql immutable set search_path = public as $$
declare
  d text := regexp_replace(coalesce(p_cpf, ''), '\D', '', 'g');
  s integer;
  r integer;
begin
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0;
  for i in 1..9 loop s := s + substr(d, i, 1)::integer * (11 - i); end loop;
  r := (s * 10) % 11;
  if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::integer then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substr(d, i, 1)::integer * (12 - i); end loop;
  r := (s * 10) % 11;
  if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::integer;
end $$;

-- [05_api_cadastros]
create or replace function api_colaborador_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  v_situacao situacao_colaborador := coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador;
  v_admissao date;
  v_deslig date;
  v_controle date;
  v_reproc date;
  v_primeira date;
  v_constraint text;
  v_old colaboradores%rowtype;
begin
  perform fn_auth(p_token, 'colaboradores', true);
  if v_id is not null and not fn_visivel(v_id) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;

  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome do colaborador.'; end if;
  if fn_txt(d, 'matricula') is null and nullif(d ->> 'id', '') is null then
    d := d || jsonb_build_object('matricula', (
      select lpad((coalesce(max(matricula::numeric), 0) + 1)::text,
                  greatest(coalesce(max(length(matricula)), 1), length((coalesce(max(matricula::numeric), 0) + 1)::text)), '0')
        from colaboradores where matricula ~ '^[0-9]{1,15}$'));
  end if;
  if fn_txt(d, 'matricula') is null then raise exception 'Informe a matrícula.'; end if;
  if not fn_cpf_valido(d ->> 'cpf') then
    raise exception 'CPF inválido. Confira os números digitados.';
  end if;
  if fn_txt(d, 'data_admissao') is null then raise exception 'Informe a data de admissão.'; end if;

  v_admissao := fn_txt(d, 'data_admissao')::date;
  v_deslig   := fn_txt(d, 'data_desligamento')::date;
  v_controle := fn_txt(d, 'controle_ponto_inicio')::date;

  -- Perfil de eventos: precisa estar ativo (um perfil inativo só fica em quem já o usava)
  if v_id is null and fn_txt(d, 'perfil_evento_id') is not null and not exists (
       select 1 from perfis_eventos pe
        where pe.id = fn_txt(d, 'perfil_evento_id')::uuid
          and (pe.ativo or pe.id = (select c.perfil_evento_id from colaboradores c where c.id = v_id))) then
    raise exception 'Escolha uma regra de cálculo ativa.';
  end if;

  if v_controle is not null and v_controle < v_admissao then
    raise exception 'O controle de ponto não pode começar antes da admissão (%).', to_char(v_admissao, 'DD/MM/YYYY');
  end if;

  -- O desligamento é a data de desligamento (não é uma situação)
  if v_situacao = 'desligado' then
    v_situacao := 'ativo';
    v_deslig := coalesce(v_deslig, fn_hoje());
  end if;

  -- Empresa do colaborador: só uma das empresas a que o usuário tem acesso
  if fn_txt(d, 'empresa_id') is not null and fn_txt(d, 'empresa_id')::uuid not in
       (select fn_empresas_do_usuario(nullif(current_setting('app.usuario_id', true), '')::uuid)) then
    raise exception 'Você não tem acesso à empresa selecionada.';
  end if;

  -- Na inclusão, situação, cargo, departamento, jornada, regra e salário viram a primeira situação
  -- (na admissão). Depois disso eles só mudam pela Situação do Colaborador, a partir de uma data.
  if v_id is null then
    insert into colaboradores (
      matricula, nome, nome_social, cpf, pis, rg, data_nascimento, sexo, email, telefone,
      cep, logradouro, numero, complemento, bairro, cidade, uf,
      cargo_id, departamento_id, jornada_id, gestor_id, perfil_evento_id,
      data_admissao, data_desligamento, situacao, salario, observacoes,
      controla_ponto, controle_ponto_inicio, empresa_id)
    values (
      fn_txt(d, 'matricula'), fn_txt(d, 'nome'), fn_txt(d, 'nome_social'),
      regexp_replace(fn_txt(d, 'cpf'), '[^0-9]', '', 'g'),
      nullif(regexp_replace(fn_txt(d, 'pis'), '[^0-9]', '', 'g'), ''), fn_txt(d, 'rg'),
      fn_txt(d, 'data_nascimento')::date, fn_txt(d, 'sexo'),
      lower(fn_txt(d, 'email')), fn_txt(d, 'telefone'),
      fn_txt(d, 'cep'), fn_txt(d, 'logradouro'), fn_txt(d, 'numero'), fn_txt(d, 'complemento'),
      fn_txt(d, 'bairro'), fn_txt(d, 'cidade'), upper(fn_txt(d, 'uf')),
      fn_txt(d, 'cargo_id')::uuid, fn_txt(d, 'departamento_id')::uuid,
      fn_txt(d, 'jornada_id')::uuid, fn_txt(d, 'gestor_id')::uuid,
      fn_txt(d, 'perfil_evento_id')::uuid,   -- vazio: o trigger usa o perfil padrão
      v_admissao, v_deslig, v_situacao,
      fn_txt(d, 'salario')::numeric, fn_txt(d, 'observacoes'),
      coalesce((d ->> 'controla_ponto')::boolean, true), v_controle,
      fn_txt(d, 'empresa_id')::uuid)   -- vazio: a empresa da sessão
    returning id into v_id;
    v_reproc := v_admissao;
    perform fn_colaborador_situacao_aplicar(v_id);
  else
    if fn_txt(d, 'gestor_id')::uuid = v_id then
      raise exception 'O colaborador não pode ser gestor dele mesmo.';
    end if;
    select * into v_old from colaboradores where id = v_id;
    if not found then raise exception 'Colaborador não encontrado.'; end if;

    -- A admissão mudou: a primeira situação acompanha (não pode passar das seguintes)
    if v_admissao <> v_old.data_admissao then
      select min(data_inicio) into v_primeira from colaborador_situacoes where colaborador_id = v_id;
      if exists (select 1 from colaborador_situacoes
                  where colaborador_id = v_id and data_inicio > v_primeira and data_inicio <= v_admissao) then
        raise exception 'Há situações lançadas até % (Situação do Colaborador). A admissão precisa ser anterior a elas.',
          to_char(v_admissao, 'DD/MM/YYYY');
      end if;
      perform set_config('app.data_vigencia', v_admissao::text, true);
      update colaborador_situacoes set data_inicio = v_admissao
       where colaborador_id = v_id and data_inicio = v_primeira;
    end if;

    -- Reprocessa o banco de horas desde a data mais antiga afetada
    select least(c.data_admissao, v_admissao,
                 coalesce((select min(bh.data) from banco_horas bh
                            where bh.colaborador_id = c.id and bh.origem = 'automatico'), v_admissao))
      into v_reproc
      from colaboradores c where c.id = v_id;

    update colaboradores set
      matricula = fn_txt(d, 'matricula'), nome = fn_txt(d, 'nome'), nome_social = fn_txt(d, 'nome_social'),
      cpf = regexp_replace(fn_txt(d, 'cpf'), '[^0-9]', '', 'g'),
      pis = nullif(regexp_replace(fn_txt(d, 'pis'), '[^0-9]', '', 'g'), ''), rg = fn_txt(d, 'rg'),
      data_nascimento = fn_txt(d, 'data_nascimento')::date, sexo = fn_txt(d, 'sexo'),
      email = lower(fn_txt(d, 'email')), telefone = fn_txt(d, 'telefone'),
      cep = fn_txt(d, 'cep'), logradouro = fn_txt(d, 'logradouro'), numero = fn_txt(d, 'numero'),
      complemento = fn_txt(d, 'complemento'), bairro = fn_txt(d, 'bairro'), cidade = fn_txt(d, 'cidade'),
      uf = upper(fn_txt(d, 'uf')),
      gestor_id = fn_txt(d, 'gestor_id')::uuid,
      data_admissao = v_admissao, data_desligamento = v_deslig, observacoes = fn_txt(d, 'observacoes'),
      controla_ponto = coalesce((d ->> 'controla_ponto')::boolean, true),
      controle_ponto_inicio = v_controle,
      empresa_id = coalesce(fn_txt(d, 'empresa_id')::uuid, empresa_id)
    where id = v_id;

    -- Dados da admissão (a primeira situação): só mudam aqui, no cadastro
    if jsonb_typeof(d -> 'admissao') = 'object' then
      declare
        a jsonb := d -> 'admissao';
        s colaborador_situacoes%rowtype;
        n_sit situacao_colaborador;
        n_jor uuid := fn_txt(a, 'jornada_id')::uuid;
        n_per uuid;
        n_sal numeric := fn_txt(a, 'salario')::numeric;
      begin
        select * into s from colaborador_situacoes where colaborador_id = v_id order by data_inicio limit 1;
        if found then
          if fn_txt(a, 'situacao') = 'desligado' then
            raise exception 'O desligamento não é uma situação: informe a data de desligamento.';
          end if;
          n_sit := coalesce(fn_txt(a, 'situacao'), s.situacao::text)::situacao_colaborador;
          n_per := coalesce(fn_txt(a, 'perfil_evento_id')::uuid, s.perfil_evento_id);
          if (s.situacao, s.cargo_id, s.departamento_id, s.jornada_id, s.perfil_evento_id, s.salario)
             is distinct from (n_sit, fn_txt(a, 'cargo_id')::uuid, fn_txt(a, 'departamento_id')::uuid, n_jor, n_per, n_sal) then
            if s.data_inicio <= coalesce(fn_fechado_ate(v_id), '-infinity'::date) then
              raise exception 'A admissão está em um período fechado. Reabra o fechamento para alterar os dados da admissão.';
            end if;
            if n_jor is not null and n_jor is distinct from s.jornada_id
               and not exists (select 1 from jornadas where id = n_jor and ativo) then
              raise exception 'Escolha uma jornada ativa.';
            end if;
            if n_per is distinct from s.perfil_evento_id
               and not exists (select 1 from perfis_eventos where id = n_per and ativo) then
              raise exception 'Escolha uma regra de cálculo ativa.';
            end if;
            perform set_config('app.data_vigencia', s.data_inicio::text, true);
            update colaborador_situacoes set
              situacao = n_sit, cargo_id = fn_txt(a, 'cargo_id')::uuid,
              departamento_id = fn_txt(a, 'departamento_id')::uuid,
              jornada_id = n_jor, perfil_evento_id = n_per, salario = n_sal
             where id = s.id;
          end if;
        end if;
      end;
    end if;
    perform fn_colaborador_situacao_aplicar(v_id);
  end if;

  -- Mantém o banco de horas do colaborador coerente com jornada, controle e datas
  perform fn_processar_banco_horas(v_reproc, fn_hoje() - 1, v_id);

  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    raise exception '%', case
      when v_constraint like '%cpf%'       then 'Já existe um colaborador com este CPF.'
      when v_constraint like '%matricula%' then 'Já existe um colaborador com esta matrícula.'
      when v_constraint like '%pis%'       then 'Já existe um colaborador com este PIS.'
      else 'Registro duplicado.' end;
  when check_violation then
    raise exception 'A data de desligamento não pode ser anterior à admissão.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Data inválida. Confira as datas informadas.';
end $$;

-- [08_api_fortes]
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

-- [03_seed] Páginas novas e permissões
insert into paginas (chave, nome, grupo, ordem) values
  ('relatorio_faltas',   'Listagem de Faltas',        'Relatórios', 89),
  ('relatorio_assiduidade', 'Listagem de Assiduidade', 'Relatórios', 89),
  ('relatorio_colaboradores', 'Relatório de Colaboradores', 'Relatórios', 89)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

-- Listagens de faltas e de assiduidade: quem vê os totais do período; dados cadastrais: quem vê os colaboradores
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_faltas', pode_visualizar, false from perfil_permissoes where pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_assiduidade', pode_visualizar, false from perfil_permissoes where pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_colaboradores', pode_visualizar, false from perfil_permissoes where pagina = 'colaboradores'
on conflict (perfil_id, pagina) do nothing;

revoke execute on function fn_cpf_valido(text) from public, anon, authenticated;
grant execute on function api_relatorio_colaboradores(text, text, uuid[], uuid)       to anon, authenticated;
grant execute on function api_relatorio_faltas(text, date, date, uuid[], uuid)          to anon, authenticated;
grant execute on function api_relatorio_assiduidade(text, date, date, uuid[], uuid)     to anon, authenticated;

notify pgrst, 'reload schema';
