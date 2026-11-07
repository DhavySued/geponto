-- =============================================================================
-- GePonto — 04_dados_demo.sql (OPCIONAL)
-- Popula colaboradores e ~5 semanas de batidas para visualizar o Dashboard.
-- Para remover:  delete from colaboradores where observacoes = '[DEMO]';
-- =============================================================================

-- Jornadas de exemplo
insert into jornadas (nome, descricao) values
  ('Administrativa 44h', 'Seg a Qui 08:00–18:00, Sex 08:00–17:00, intervalo 12:00–13:00'),
  ('Comercial 40h',      'Seg a Sex 08:00–17:00, intervalo 12:00–13:00')
on conflict (nome) do nothing;

insert into jornada_dias (jornada_id, dia_semana, folga, entrada, saida_intervalo, retorno_intervalo, saida)
select j.id, d.dia, d.folga, d.ent::time, d.si::time, d.ri::time, d.sai::time
  from jornadas j
  join (values
    ('Administrativa 44h', 0, true,  null,    null,    null,    null),
    ('Administrativa 44h', 1, false, '08:00', '12:00', '13:00', '18:00'),
    ('Administrativa 44h', 2, false, '08:00', '12:00', '13:00', '18:00'),
    ('Administrativa 44h', 3, false, '08:00', '12:00', '13:00', '18:00'),
    ('Administrativa 44h', 4, false, '08:00', '12:00', '13:00', '18:00'),
    ('Administrativa 44h', 5, false, '08:00', '12:00', '13:00', '17:00'),
    ('Administrativa 44h', 6, true,  null,    null,    null,    null),
    ('Comercial 40h',      0, true,  null,    null,    null,    null),
    ('Comercial 40h',      1, false, '08:00', '12:00', '13:00', '17:00'),
    ('Comercial 40h',      2, false, '08:00', '12:00', '13:00', '17:00'),
    ('Comercial 40h',      3, false, '08:00', '12:00', '13:00', '17:00'),
    ('Comercial 40h',      4, false, '08:00', '12:00', '13:00', '17:00'),
    ('Comercial 40h',      5, false, '08:00', '12:00', '13:00', '17:00'),
    ('Comercial 40h',      6, true,  null,    null,    null,    null)
  ) as d(jornada, dia, folga, ent, si, ri, sai) on d.jornada = j.nome
on conflict (jornada_id, dia_semana) do nothing;

insert into departamentos (nome) values
  ('Administrativo'), ('Comercial'), ('Operações'), ('Tecnologia')
on conflict (nome) do nothing;

insert into cargos (nome) values
  ('Analista Administrativo'), ('Assistente Comercial'), ('Supervisor de Operações'),
  ('Operador'), ('Desenvolvedor'), ('Coordenador Comercial')
on conflict (nome) do nothing;

insert into colaboradores (matricula, nome, cpf, email, cargo_id, departamento_id, jornada_id,
                           data_admissao, situacao, observacoes, controle_ponto_inicio)
select x.matricula, x.nome, x.cpf, x.email,
       (select id from cargos where nome = x.cargo),
       (select id from departamentos where nome = x.depto),
       (select id from jornadas where nome = x.jornada),
       x.admissao::date, x.situacao::situacao_colaborador, '[DEMO]', fn_hoje() - 34
  from (values
    ('1001', 'Ana Beatriz Souza',   '111.111.111-11', 'ana.souza@exemplo.com',    'Analista Administrativo', 'Administrativo', 'Administrativa 44h', '2022-03-01', 'ativo'),
    ('1002', 'Bruno Carvalho',      '222.222.222-22', 'bruno.carvalho@exemplo.com','Assistente Comercial',   'Comercial',      'Comercial 40h',      '2023-07-10', 'ativo'),
    ('1003', 'Camila Ferreira',     '333.333.333-33', 'camila.f@exemplo.com',     'Supervisor de Operações', 'Operações',      'Administrativa 44h', '2021-01-18', 'ativo'),
    ('1004', 'Diego Martins',       '444.444.444-44', 'diego.m@exemplo.com',      'Operador',                'Operações',      'Administrativa 44h', '2024-02-05', 'ativo'),
    ('1005', 'Eduarda Lima',        '555.555.555-55', 'eduarda.lima@exemplo.com', 'Desenvolvedor',           'Tecnologia',     'Comercial 40h',      '2023-11-20', 'ativo'),
    ('1006', 'Felipe Rocha',        '666.666.666-66', 'felipe.rocha@exemplo.com', 'Operador',                'Operações',      'Administrativa 44h', '2025-04-14', 'ativo'),
    ('1007', 'Gabriela Nunes',      '777.777.777-77', 'gabriela.n@exemplo.com',   'Coordenador Comercial',   'Comercial',      'Comercial 40h',      '2020-08-03', 'ativo'),
    ('1008', 'Henrique Alves',      '888.888.888-88', 'henrique.a@exemplo.com',   'Desenvolvedor',           'Tecnologia',     'Comercial 40h',      '2024-09-09', 'ativo'),
    ('1009', 'Isabela Torres',      '999.999.999-99', 'isabela.t@exemplo.com',    'Analista Administrativo', 'Administrativo', 'Administrativa 44h', '2022-06-27', 'ferias'),
    ('1010', 'João Pedro Ribeiro',  '101.010.101-01', 'joao.r@exemplo.com',       'Operador',                'Operações',      'Administrativa 44h', '2023-03-13', 'afastado')
  ) as x(matricula, nome, cpf, email, cargo, depto, jornada, admissao, situacao)
on conflict (matricula) do nothing;

-- Férias e afastamento cobrindo o período atual
insert into ausencias (colaborador_id, tipo, data_inicio, data_fim, justificativa)
select c.id, 'ferias', fn_hoje() - 10, fn_hoje() + 19, 'Férias regulamentares'
  from colaboradores c where c.matricula = '1009'
   and not exists (select 1 from ausencias a where a.colaborador_id = c.id);
insert into ausencias (colaborador_id, tipo, data_inicio, data_fim, justificativa)
select c.id, 'afastamento', fn_hoje() - 6, fn_hoje() + 8, 'Atestado médico (INSS)'
  from colaboradores c where c.matricula = '1010'
   and not exists (select 1 from ausencias a where a.colaborador_id = c.id);

-- Batidas simuladas: atrasos ocasionais, ~5% de faltas, horas extras variáveis
do $$
declare
  v_tz    text := fn_fuso();
  v_hoje  date := fn_hoje();
  v_agora timestamptz := now();
  c record;
  jd record;
  d date;
  v_ent int; v_si int; v_ri int; v_sai int;
  v_marcas timestamptz[];
  m timestamptz;
begin
  perform setseed(0.42);

  for c in select * from colaboradores where observacoes = '[DEMO]' loop
    if exists (select 1 from batidas b where b.colaborador_id = c.id) then
      continue;
    end if;

    for d in select g::date from generate_series(v_hoje - 34, v_hoje, interval '1 day') g loop
      select * into jd from jornada_dias where jornada_id = c.jornada_id and dia_semana = extract(dow from d);
      continue when not found or jd.folga;
      continue when exists (select 1 from feriados f where f.data = d);
      continue when exists (select 1 from ausencias a where a.colaborador_id = c.id and d between a.data_inicio and a.data_fim);
      continue when d < v_hoje and random() < 0.05;            -- falta

      v_ent := case when random() < 0.15 then 8 + (random() * 32)::int    -- atraso
                    else -12 + (random() * 15)::int end;
      v_si  := -4 + (random() * 8)::int;
      v_ri  := -3 + (random() * 8)::int;
      v_sai := case when random() < 0.30 then 15 + (random() * 75)::int   -- hora extra
                    else -8 + (random() * 18)::int end;

      v_marcas := array[
        ((d + jd.entrada)           + make_interval(mins => v_ent)) at time zone v_tz,
        ((d + jd.saida_intervalo)   + make_interval(mins => v_si))  at time zone v_tz,
        ((d + jd.retorno_intervalo) + make_interval(mins => v_ri))  at time zone v_tz,
        ((d + jd.saida)             + make_interval(mins => v_sai)) at time zone v_tz
      ];

      foreach m in array v_marcas loop
        exit when m > v_agora;
        insert into batidas (colaborador_id, data_hora, origem, nsr)
        values (c.id, m, case when random() < 0.85 then 'relogio' else 'mobile' end::origem_batida,
                (extract(epoch from m))::bigint);
      end loop;
    end loop;
  end loop;

  perform fn_processar_banco_horas(v_hoje - 34, v_hoje - 1);
end $$;
