-- =============================================================================
-- GePonto — 02_functions.sql
-- Autenticação própria, apuração de ponto e API (RPC) consumida pelo front-end.
--
-- Convenção:
--   fn_*  → funções internas (sem permissão de execução para anon)
--   api_* → endpoints chamados via supabase.rpc(); recebem p_token e validam
--           sessão + permissão de página antes de qualquer leitura/gravação.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Utilitários
-- -----------------------------------------------------------------------------
create or replace function fn_fuso()
returns text language sql stable set search_path = public as $$
  select coalesce((select fuso_horario from empresa where id = 1), 'America/Sao_Paulo');
$$;

create or replace function fn_hoje()
returns date language sql stable set search_path = public as $$
  select (now() at time zone fn_fuso())::date;
$$;

-- Minutos entre dois horários (atravessa a meia-noite quando b < a)
create or replace function fn_minutos(a time, b time)
returns integer language sql immutable as $$
  select case
    when a is null or b is null then null
    when b >= a then (extract(epoch from b - a) / 60)::int
    else (extract(epoch from (b - a) + interval '24 hours') / 60)::int
  end;
$$;

create or replace function fn_hash_senha(p_senha text)
returns text language sql volatile set search_path = public, extensions as $$
  select extensions.crypt(p_senha, extensions.gen_salt('bf', 10));
$$;

create or replace function fn_hash_token(p_token text)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(extensions.digest(p_token, 'sha256'), 'hex');
$$;

-- -----------------------------------------------------------------------------
-- Sessão e permissões
-- -----------------------------------------------------------------------------
create or replace function fn_usuario_payload(p_usuario uuid)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', u.id,
    'nome', u.nome,
    'login', u.login,
    'colaborador_id', u.colaborador_id,
    'email', u.email,
    'trocar_senha', u.trocar_senha,
    'perfil', jsonb_build_object('id', p.id, 'nome', p.nome, 'is_admin', p.is_admin,
                                 'abrangencia', case when p.is_admin then 'todos' else p.abrangencia end),
    'permissoes', coalesce((
      select jsonb_object_agg(pg.chave, jsonb_build_object(
               'visualizar', p.is_admin or coalesce(pp.pode_visualizar, false),
               'editar',     p.is_admin or coalesce(pp.pode_editar, false)))
      from paginas pg
      left join perfil_permissoes pp on pp.pagina = pg.chave and pp.perfil_id = p.id
    ), '{}'::jsonb)
  )
  from usuarios u
  join perfis p on p.id = u.perfil_id
  where u.id = p_usuario;
$$;

-- Valida o token, verifica a permissão da página e registra o usuário corrente
-- (app.usuario_id) para auditoria nos triggers. Retorna o id do usuário.
create or replace function fn_auth(p_token text, p_pagina text default null, p_editar boolean default false)
returns uuid language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_usuario uuid;
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
  returning s.usuario_id into v_usuario;

  if v_usuario is null then
    raise exception 'Sessão inválida ou expirada' using errcode = '28000';
  end if;

  if p_pagina is not null then
    select p.is_admin into v_admin
      from usuarios u join perfis p on p.id = u.perfil_id
     where u.id = v_usuario;

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
  return v_usuario;
end $$;

-- Colaborador visível para o usuário corrente (app.usuario_id, definido por fn_auth),
-- conforme a abrangência do perfil: todos, equipe (ele e subordinados diretos) ou próprio.
create or replace function fn_visivel(p_colaborador uuid)
returns boolean language sql stable set search_path = public as $$
  select coalesce((
    select case
             when p.is_admin or p.abrangencia = 'todos' then true
             when u.colaborador_id is null then false
             when p_colaborador = u.colaborador_id then true
             when p.abrangencia = 'equipe' then
               exists (select 1 from colaboradores c where c.id = p_colaborador and c.gestor_id = u.colaborador_id)
             else false end
      from usuarios u join perfis p on p.id = u.perfil_id
     where u.id = nullif(current_setting('app.usuario_id', true), '')::uuid), false);
$$;

-- -----------------------------------------------------------------------------
-- API: autenticação
-- -----------------------------------------------------------------------------
-- Confere login e senha, com bloqueio temporário após 5 falhas. Retorna JSON em vez
-- de lançar exceção para que o contador de tentativas falhas seja persistido (uma
-- exceção desfaria o UPDATE). Usada pelo login e pelo registro rápido de ponto.
create or replace function fn_verificar_credenciais(p_login text, p_senha text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_user  usuarios%rowtype;
  c_erro  constant text := 'Usuário ou senha inválidos.';
begin
  select * into v_user
    from usuarios
   where lower(login) = lower(trim(p_login))
      or lower(email) = lower(trim(p_login))
   limit 1;

  if not found then
    perform extensions.crypt(coalesce(p_senha, ''), extensions.gen_salt('bf', 10)); -- tempo constante
    return jsonb_build_object('ok', false, 'erro', c_erro);
  end if;

  if v_user.bloqueado_ate is not null and v_user.bloqueado_ate > now() then
    return jsonb_build_object('ok', false,
      'erro', 'Acesso temporariamente bloqueado por excesso de tentativas. Tente novamente em alguns minutos.');
  end if;

  if v_user.senha_hash <> extensions.crypt(coalesce(p_senha, ''), v_user.senha_hash) then
    update usuarios
       set tentativas_falhas = case when bloqueado_ate is not null then 1 else tentativas_falhas + 1 end,
           bloqueado_ate = case when bloqueado_ate is null and tentativas_falhas + 1 >= 5
                                then now() + interval '15 minutes' end
     where id = v_user.id;
    return jsonb_build_object('ok', false, 'erro', c_erro);
  end if;

  if v_user.status <> 'ativo' then
    return jsonb_build_object('ok', false, 'erro', 'Usuário inativo ou bloqueado. Procure o administrador.');
  end if;

  update usuarios set tentativas_falhas = 0, bloqueado_ate = null where id = v_user.id;
  return jsonb_build_object('ok', true, 'usuario_id', v_user.id);
end $$;

create or replace function api_login(p_login text, p_senha text, p_user_agent text default null)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_cred    jsonb;
  v_usuario uuid;
  v_token   text;
  v_exp     timestamptz := now() + interval '12 hours';
begin
  delete from sessoes where expira_em < now();

  v_cred := fn_verificar_credenciais(p_login, p_senha);
  if not (v_cred ->> 'ok')::boolean then
    return v_cred;
  end if;
  v_usuario := (v_cred ->> 'usuario_id')::uuid;

  update usuarios set ultimo_acesso = now() where id = v_usuario;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into sessoes (usuario_id, token_hash, expira_em, user_agent)
  values (v_usuario, fn_hash_token(v_token), v_exp, left(p_user_agent, 300));

  return jsonb_build_object('ok', true, 'token', v_token, 'expira_em', v_exp,
                            'usuario', fn_usuario_payload(v_usuario));
end $$;

create or replace function api_sessao(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  return fn_usuario_payload(fn_auth(p_token));
end $$;

create or replace function api_logout(p_token text)
returns void language sql volatile security definer set search_path = public as $$
  delete from sessoes where token_hash = fn_hash_token(coalesce(p_token, ''));
$$;

create or replace function api_alterar_senha(p_token text, p_senha_atual text, p_nova_senha text)
returns jsonb language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  v_usuario uuid := fn_auth(p_token);
  v_hash text;
begin
  select senha_hash into v_hash from usuarios where id = v_usuario;
  if v_hash <> extensions.crypt(coalesce(p_senha_atual, ''), v_hash) then
    return jsonb_build_object('ok', false, 'erro', 'Senha atual incorreta.');
  end if;
  if length(coalesce(p_nova_senha, '')) < 6 then
    return jsonb_build_object('ok', false, 'erro', 'A nova senha deve ter ao menos 6 caracteres.');
  end if;
  if p_nova_senha = p_senha_atual then
    return jsonb_build_object('ok', false, 'erro', 'A nova senha deve ser diferente da atual.');
  end if;
  update usuarios set senha_hash = fn_hash_senha(p_nova_senha), trocar_senha = false where id = v_usuario;
  -- encerra as demais sessões do usuário
  delete from sessoes where usuario_id = v_usuario and token_hash <> fn_hash_token(p_token);
  return jsonb_build_object('ok', true);
end $$;

-- Keep-alive (GitHub Actions). Faz uma leitura real no banco.
create or replace function api_ping()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('ok', true, 'ts', now(), 'empresa', (select count(*) from empresa));
$$;

-- -----------------------------------------------------------------------------
-- Apuração diária
-- Uma linha por colaborador/dia com jornada prevista, horas trabalhadas,
-- atraso, saldo (já aplicada a tolerância diária) e ocorrência.
-- Considera apenas colaboradores com ponto controlado, a partir da data de
-- início do controle, e usa a jornada vigente em cada dia (colaborador_jornadas).
-- -----------------------------------------------------------------------------

-- Jornada válida para o colaborador em uma data
create or replace function fn_jornada_vigente(p_colaborador uuid, p_data date)
returns uuid language sql stable set search_path = public as $$
  select coalesce(
    (select cj.jornada_id
       from colaborador_jornadas cj
      where cj.colaborador_id = p_colaborador and cj.data_inicio <= p_data
      order by cj.data_inicio desc
      limit 1),
    (select c.jornada_id from colaboradores c where c.id = p_colaborador));
$$;

-- Primeiro dia em que o ponto do colaborador é apurado
create or replace function fn_inicio_controle(c colaboradores)
returns date language sql immutable as $$
  select greatest(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao));
$$;

-- Índice do dia na jornada: dia da semana (semanal) ou dia do ciclo (escala)
create or replace function fn_jornada_indice(p_tipo text, p_ciclo smallint, p_base date, p_data date)
returns smallint language sql immutable as $$
  select case when p_tipo = 'escala'
              then (((p_data - p_base) % p_ciclo) + p_ciclo) % p_ciclo
              else extract(dow from p_data) end::smallint;
$$;

-- Horário previsto do colaborador em uma data (jornada vigente + escala)
drop function if exists fn_jornada_dia(uuid, date);
create function fn_jornada_dia(p_colaborador uuid, p_data date)
returns table (jornada_id uuid, folga boolean, entrada time, saida_intervalo time, retorno_intervalo time, saida time)
language sql stable set search_path = public as $$
  select j.id, coalesce(jd.folga, true), jd.entrada, jd.saida_intervalo, jd.retorno_intervalo, jd.saida
    from jornadas j
    left join jornada_dias jd on jd.jornada_id = j.id
                             and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, p_data)
   where j.id = fn_jornada_vigente(p_colaborador, p_data);
$$;

-- Horário previsto em texto: "08:00–12:00 · 13:00–17:00" (null = folga)
create or replace function fn_horario_texto(p_jornada uuid, p_data date)
returns text language sql stable set search_path = public as $$
  select case when jd.folga or jd.entrada is null then null
              when jd.saida_intervalo is null
                then to_char(jd.entrada, 'HH24:MI') || '–' || to_char(jd.saida, 'HH24:MI')
              else to_char(jd.entrada, 'HH24:MI') || '–' || to_char(jd.saida_intervalo, 'HH24:MI')
                   || ' · ' || to_char(jd.retorno_intervalo, 'HH24:MI') || '–' || to_char(jd.saida, 'HH24:MI')
         end
    from jornadas j
    join jornada_dias jd on jd.jornada_id = j.id
                        and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, p_data)
   where j.id = p_jornada;
$$;

-- Minutos de relógio dentro da faixa noturna (padrão 22:00–05:00) entre dois instantes locais
create or replace function fn_minutos_noturnos(p_ini timestamp, p_fim timestamp, p_n_ini time, p_n_fim time)
returns integer language sql immutable as $$
  select coalesce(sum(greatest(0, extract(epoch from least(p_fim, w.f) - greatest(p_ini, w.i)) / 60)), 0)::int
    from generate_series(p_ini::date - 1, p_fim::date, interval '1 day') g(d)
   cross join lateral (
     select g.d::date + p_n_ini as i,
            case when p_n_fim <= p_n_ini then g.d::date + 1 + p_n_fim else g.d::date + p_n_fim end as f
   ) w
   where p_ini is not null and p_fim is not null and p_fim > p_ini;
$$;

-- Dia dentro de um período fechado?
create or replace function fn_periodo_fechado(p_data date)
returns boolean language sql stable set search_path = public as $$
  select exists (select 1 from fechamentos f where p_data between f.data_inicio and f.data_fim);
$$;

-- Aloca as batidas do dia nas marcações previstas (E1, S1, E2, S2) pela proximidade do horário,
-- mantendo a ordem: cada batida vai para a marcação prevista mais próxima entre as que ainda cabem
-- (as seguintes precisam de lugar depois dela). Devolve o índice da marcação de cada batida, ou null
-- quando não há previsão ou há mais batidas que marcações previstas.
-- Ex.: previsto 08–12 · 13–17 e uma única batida às 13:10 → E2 (e não E1).
create or replace function fn_alocar_marcacoes(p_batidas timestamp[], p_previstas timestamp[])
returns integer[] language plpgsql immutable as $$
declare
  n      integer := coalesce(array_length(p_batidas, 1), 0);
  m      integer := coalesce(array_length(p_previstas, 1), 0);
  r      integer[] := '{}';
  ant    integer := 0;
  melhor integer;
  menor  numeric;
  d      numeric;
begin
  if n = 0 or m = 0 or n > m then
    return null;
  end if;
  for i in 1 .. n loop
    melhor := null;
    for j in ant + 1 .. m - (n - i) loop
      d := abs(extract(epoch from p_batidas[i] - p_previstas[j]));
      if melhor is null or d < menor then
        melhor := j;
        menor := d;
      end if;
    end loop;
    r := r || melhor;
    ant := melhor;
  end loop;
  return r;
end $$;

-- Batidas do período com a classificação efetiva de cada uma. As desconsideradas ficam fora da sequência.
--   1. RH classificou alguma batida do dia → vale a classificação; as demais seguem a sequência a partir dela
--   2. sem classificação e com horário previsto → cada batida vai para a marcação prevista mais próxima
--      (fn_alocar_marcacoes)
--   3. sem previsão (folga, sem jornada) ou mais batidas que marcações → alternância: 1ª = entrada,
--      2ª = saída…, e cada entrada abre o turno seguinte
-- O colaborador nunca escolhe: ele só registra; quem trata o ponto classifica. A apuração usa esta mesma sequência.
drop function if exists fn_batidas_periodo(date, date, uuid);
create function fn_batidas_periodo(p_ini date, p_fim date, p_colaborador uuid default null)
returns table (
  id uuid, colaborador_id uuid, data_hora timestamptz, data_referencia date, origem origem_batida,
  status status_batida, nsr bigint, motivo_id uuid, observacao text, sentido_declarado text, sentido text,
  turno_declarado integer, turno integer
)
language sql stable set search_path = public as $$
  with base as (
    select b.*
      from batidas b
     where b.data_referencia between p_ini and p_fim
       and (p_colaborador is null or b.colaborador_id = p_colaborador)
  ),
  -- grupos: cada batida com sentido (ou turno) declarado abre um grupo que segue até a próxima declarada
  n as (
    select v.*,
           count(v.sentido) over w as g_sent,
           count(v.turno)   over w as g_turno
      from base v
     where v.status = 'valida'
    window w as (partition by v.colaborador_id, v.data_referencia order by v.data_hora, v.id)
  ),
  s as (
    select n.*,
           case
             when g_sent = 0 then
               case when (row_number() over gs) % 2 = 1 then 'E' else 'S' end
             when (row_number() over gs) % 2 = 1 then (first_value(n.sentido) over gs)::text
             when (first_value(n.sentido) over gs) = 'E' then 'S'
             else 'E' end as sent
      from n
    window gs as (partition by n.colaborador_id, n.data_referencia, n.g_sent order by n.data_hora, n.id)
  ),
  t as (
    select s.*,
           (count(*) filter (where s.sent = 'E') over gt)::integer as e_cum,
           (first_value(s.turno) over gt)::integer                 as t0,
           first_value(s.sent) over gt                             as sent0
      from s
    window gt as (partition by s.colaborador_id, s.data_referencia, s.g_turno order by s.data_hora, s.id
                  rows between unbounded preceding and current row)
  ),
  -- Dias sem nenhuma classificação do RH: candidatos à alocação pela proximidade
  dia as (
    select t.colaborador_id, t.data_referencia,
           array_agg(t.id order by t.data_hora, t.id) as ids,
           array_agg(t.data_hora at time zone fn_fuso() order by t.data_hora, t.id) as horas
      from t
     group by t.colaborador_id, t.data_referencia
    having count(t.sentido) = 0 and count(t.turno) = 0
  ),
  -- Marcações previstas do dia, em ordem (virada de meia-noite vai para o dia seguinte)
  prev as (
    select d.*, pv.horas_prev, pv.sentidos, pv.turnos
      from dia d
     cross join lateral fn_jornada_dia(d.colaborador_id, d.data_referencia) jd
     cross join lateral (
       select array_agg(d.data_referencia + v.h
                        + case when v.h < jd.entrada then interval '1 day' else interval '0' end order by v.o) as horas_prev,
              array_agg(v.s order by v.o) as sentidos,
              array_agg(v.t order by v.o) as turnos
         from (values (1, 'E', 1, jd.entrada),
                      (2, 'S', 1, coalesce(jd.saida_intervalo, jd.saida)),
                      (3, 'E', 2, jd.retorno_intervalo),
                      (4, 'S', 2, case when jd.saida_intervalo is not null then jd.saida end)) v(o, s, t, h)
        where v.h is not null
     ) pv
     where not coalesce(jd.folga, true) and jd.entrada is not null
  ),
  aloc as (
    select u.id, p.sentidos[p.idx[u.k]] as sent, p.turnos[p.idx[u.k]] as tur
      from (select prev.*, fn_alocar_marcacoes(prev.horas, prev.horas_prev) as idx from prev) p
     cross join lateral unnest(p.ids) with ordinality u(id, k)
     where p.idx is not null
  )
  select t.id, t.colaborador_id, t.data_hora, t.data_referencia, t.origem, t.status, t.nsr,
         t.motivo_id, t.observacao, t.sentido::text,
         coalesce(al.sent, t.sent),
         t.turno::integer,
         coalesce(al.tur,
                  case when t.g_turno = 0 then greatest(1, t.e_cum)
                       else t.t0 + t.e_cum - case when t.sent0 = 'E' then 1 else 0 end end)
    from t
    left join aloc al on al.id = t.id
  union all
  select v.id, v.colaborador_id, v.data_hora, v.data_referencia, v.origem, v.status, v.nsr,
         v.motivo_id, v.observacao, v.sentido::text, v.sentido::text, v.turno::integer, v.turno::integer
    from base v
   where v.status <> 'valida';
$$;

drop function if exists fn_apuracao(date, date, uuid);
create function fn_apuracao(p_ini date, p_fim date, p_colaborador uuid default null)
returns table (
  colaborador_id        uuid,
  data                  date,
  previsto_min          integer,
  trabalhado_min        integer,
  atraso_min            integer,
  saldo_min             integer,
  qtd_batidas           integer,
  primeira_batida       time,
  falta                 boolean,
  ocorrencia            text,
  jornada_id            uuid,
  impar                 boolean,   -- há entrada sem saída (ou saída sem entrada)
  ultimo_sentido        text,      -- sentido efetivo da última batida do dia ('E' / 'S')
  saida_antecipada_min  integer,   -- saiu antes do previsto além da tolerância de saída
  abonado_min           integer,   -- abono parcial efetivamente aplicado
  extra_min             integer,   -- saldo positivo (hora extra / crédito)
  debito_min            integer,   -- saldo negativo em módulo (horas faltantes / débito)
  he_percentual         numeric,   -- percentual de HE do dia, pelo perfil de eventos (dia da semana ou feriado)
  noturno_min           integer,   -- minutos de relógio na faixa noturna
  noturno_reduzido_min  integer,   -- com a hora noturna reduzida (52min30s), quando aplicável
  intervalo_min         integer,   -- descanso intrajornada realizado
  interjornada_min      integer,   -- descanso desde a última batida do dia anterior trabalhado
  banco_horas           boolean,   -- o saldo do dia vai para o banco de horas (senão: HE/desconto)
  feriado               boolean,
  fechado               boolean    -- dia dentro de um período fechado
)
language sql stable set search_path = public as $$
with cfg as (
  select fn_fuso() as tz, fn_hoje() as hoje
),
dias as (
  select c.id as colaborador_id, d::date as data, fn_jornada_vigente(c.id, d::date) as jornada_id,
         c.perfil_evento_id as perfil_id
    from colaboradores c
   cross join generate_series(p_ini, p_fim, interval '1 day') d
   where (p_colaborador is null or c.id = p_colaborador)
     and c.controla_ponto
     and fn_inicio_controle(c) <= d::date
     and (c.data_desligamento is null or c.data_desligamento >= d::date)
),
base as (
  select dd.colaborador_id, dd.data, dd.jornada_id,
         jd.folga, jd.entrada, jd.saida, jd.saida_intervalo, jd.retorno_intervalo,
         pe.tolerancia_entrada_min, pe.tolerancia_saida_min, pe.tolerancia_diaria_min,
         pe.hora_noturna_reduzida,
         coalesce(pe.usa_banco_horas, false) as usa_bh,
         coalesce(ph.percentual, 50) as he_percentual,
         (f.id is not null) as feriado,
         a.tipo as ausencia_tipo,
         coalesce(a.abona, false) as abona,
         coalesce(ap.minutos, 0) as abono_parcial
    from dias dd
    left join jornadas j      on j.id = dd.jornada_id
    left join jornada_dias jd on jd.jornada_id = dd.jornada_id
                             and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, dd.data)
    left join feriados f      on f.data = dd.data
    left join perfis_eventos pe on pe.id = dd.perfil_id
    left join perfil_evento_he ph on ph.perfil_id = dd.perfil_id
                                 and ph.dia = case when f.id is not null then 7 else extract(dow from dd.data)::int end
    left join lateral (
      select au.tipo, au.abona
        from ausencias au
       where au.colaborador_id = dd.colaborador_id
         and dd.data between au.data_inicio and au.data_fim
         and au.minutos is null
       order by au.abona desc
       limit 1
    ) a on true
    left join lateral (
      select sum(au.minutos)::int as minutos
        from ausencias au
       where au.colaborador_id = dd.colaborador_id
         and dd.data between au.data_inicio and au.data_fim
         and au.minutos is not null and au.abona
    ) ap on true
),
-- Sentido efetivo de cada batida (fn_batidas_periodo: declarado pelo RH ou sequência automática).
-- Inclui o dia anterior ao período para calcular a interjornada do primeiro dia.
seq as (
  select x.*,
         lead(x.sent)      over w2 as prox_sent,
         lead(x.tur)       over w2 as prox_tur,
         lead(x.data_hora) over w2 as prox
    from (
      select bt.colaborador_id, bt.data_referencia, bt.data_hora, bt.sentido as sent, bt.turno as tur
        from fn_batidas_periodo(p_ini - 1, p_fim, p_colaborador) bt
       where bt.status = 'valida'
    ) x
  window w2 as (partition by x.colaborador_id, x.data_referencia order by x.data_hora)
),
-- Pares entrada → saída do mesmo turno (turno só conta com as duas), com o descanso desde o par anterior
pares as (
  select p.*, p.ini - lag(p.fim) over (partition by p.colaborador_id, p.data_referencia order by p.ini) as pausa
    from (
      select s.colaborador_id, s.data_referencia, s.data_hora as ini, s.prox as fim, s.tur
        from seq s
       where s.sent = 'E' and s.prox_sent = 'S' and s.prox_tur = s.tur
    ) p
),
marc as (
  select s.colaborador_id, s.data_referencia as data,
         count(*)::int as qtd,
         min(s.data_hora) as primeira_ts,
         max(s.data_hora) as ultima_ts,
         (array_agg(s.sent order by s.data_hora desc))[1] as ultimo_sentido,
         (array_agg(s.tur order by s.data_hora))[1] as primeiro_tur
    from seq s
   group by s.colaborador_id, s.data_referencia
),
marc_pares as (
  select p.colaborador_id, p.data_referencia as data,
         count(*)::int as pares,
         min(p.ini) as primeiro_ini,
         (array_agg(p.tur order by p.ini))[1] as primeiro_tur,
         sum(extract(epoch from p.fim - p.ini) / 60)::int as trabalhado,
         sum(fn_minutos_noturnos(p.ini at time zone cfg.tz, p.fim at time zone cfg.tz,
                                 coalesce(pe.noturno_inicio, '22:00'), coalesce(pe.noturno_fim, '05:00')))::int as noturno,
         (sum(extract(epoch from p.pausa) / 60))::int as pausa
    from pares p
   cross join cfg
    left join colaboradores co  on co.id = p.colaborador_id
    left join perfis_eventos pe on pe.id = co.perfil_evento_id
   group by p.colaborador_id, p.data_referencia
),
marc_inter as (
  select m.*, lag(m.ultima_ts) over (partition by m.colaborador_id order by m.data) as ultima_anterior
    from marc m
),
calc as (
  select bs.*,
         case when bs.jornada_id is null or coalesce(bs.folga, true) or bs.feriado or bs.abona then 0
              else fn_minutos(bs.entrada, bs.saida)
                   - coalesce(fn_minutos(bs.saida_intervalo, bs.retorno_intervalo), 0)
         end as previsto,
         coalesce(mp.trabalhado, 0) as trabalhado,
         coalesce(m.qtd, 0) as qtd,
         coalesce(mp.pares, 0) as pares,
         coalesce(mp.noturno, 0) as noturno,
         mp.pausa,
         m.ultimo_sentido,
         (m.primeira_ts at time zone cfg.tz) as primeira,
         -- Turno só conta com entrada e saída: o atraso vem da entrada do primeiro turno completo
         -- (no dia em andamento, um turno aberto ainda conta)
         coalesce(mp.primeiro_ini at time zone cfg.tz,
                  case when bs.data >= cfg.hoje then m.primeira_ts at time zone cfg.tz end) as primeira_turno,
         -- Entrada prevista do turno em que a primeira entrada caiu (2º turno → retorno do intervalo).
         -- No dia em andamento vale também o turno ainda aberto; retorno depois da meia-noite é no dia seguinte.
         case when coalesce(mp.primeiro_tur, case when bs.data >= cfg.hoje then m.primeiro_tur end) = 2
                   and bs.retorno_intervalo is not null
              then bs.data + bs.retorno_intervalo
                   + case when bs.retorno_intervalo < bs.entrada then interval '1 day' else interval '0' end
              else bs.data + bs.entrada end as entrada_turno,
         (m.ultima_ts at time zone cfg.tz) as ultima,
         (extract(epoch from m.primeira_ts - m.ultima_anterior) / 60)::int as interjornada,
         (bs.data >= cfg.hoje) as em_andamento,
         fn_periodo_fechado(bs.data) as fechado
    from base bs
   cross join cfg
    left join marc_inter m  on m.colaborador_id = bs.colaborador_id and m.data = bs.data
    left join marc_pares mp on mp.colaborador_id = bs.colaborador_id and mp.data = bs.data
),
res as (
  select c.*,
         least(c.abono_parcial, greatest(c.previsto - c.trabalhado, 0)) as abonado,
         case when c.previsto > 0 and c.primeira_turno is not null
                   and extract(epoch from c.primeira_turno - c.entrada_turno) / 60 > c.tolerancia_entrada_min
              then (extract(epoch from c.primeira_turno - c.entrada_turno) / 60)::int
              else 0 end as atraso,
         case when c.previsto > 0 and c.qtd > 0 and c.qtd = 2 * c.pares and not c.em_andamento
                   and extract(epoch from (c.data + c.saida + case when c.saida <= c.entrada then interval '1 day'
                                                                    else interval '0' end) - c.ultima) / 60
                       > c.tolerancia_saida_min
              then (extract(epoch from (c.data + c.saida + case when c.saida <= c.entrada then interval '1 day'
                                                                else interval '0' end) - c.ultima) / 60)::int
              else 0 end as antecipada
    from calc c
),
fin as (
  select r.*,
         (r.previsto > 0 and r.qtd = 0 and not r.em_andamento and r.abonado < r.previsto) as e_falta,
         -- Turno incompleto (entrada sem saída ou vice-versa) não soma horas: o previsto dele vira débito
         case when r.em_andamento then 0
              when abs(r.trabalhado + r.abonado - r.previsto) <= coalesce(r.tolerancia_diaria_min, 0) then 0
              else r.trabalhado + r.abonado - r.previsto end as saldo
    from res r
)
select f.colaborador_id,
       f.data,
       f.previsto,
       f.trabalhado,
       f.atraso,
       f.saldo,
       f.qtd,
       f.primeira::time,
       f.e_falta,
       case when f.jornada_id is null          then 'sem_jornada'
            when f.ausencia_tipo is not null   then 'ausencia:' || f.ausencia_tipo
            when f.feriado and f.qtd = 0       then 'feriado'
            when coalesce(f.folga, true) and f.qtd = 0 then 'folga'
            when f.em_andamento                then 'em_andamento'
            when f.e_falta                     then 'falta'
            when f.qtd <> 2 * f.pares          then 'inconsistente'
            when f.atraso > 0                  then 'atraso'
            when f.antecipada > 0              then 'saida_antecipada'
            when f.saldo > 0                   then 'hora_extra'
            else 'normal' end,
       f.jornada_id,
       f.qtd <> 2 * f.pares,
       f.ultimo_sentido,
       f.antecipada,
       f.abonado,
       greatest(f.saldo, 0),
       greatest(-f.saldo, 0),
       f.he_percentual,
       f.noturno,
       case when coalesce(f.hora_noturna_reduzida, true) then round(f.noturno * 60 / 52.5)::int else f.noturno end,
       case when f.pares > 1 then f.pausa end,
       f.interjornada,
       f.usa_bh,
       f.feriado,
       f.fechado
  from fin f;
$$;

-- -----------------------------------------------------------------------------
-- Banco de horas automático
-- Cada dia encerrado gera um lançamento 'automatico' com o saldo apurado.
-- Idempotente: substitui os lançamentos automáticos do período (e do colaborador).
-- -----------------------------------------------------------------------------
drop function if exists fn_processar_banco_horas(date, date);
create or replace function fn_processar_banco_horas(p_ini date, p_fim date, p_colaborador uuid default null)
returns integer language plpgsql volatile set search_path = public as $$
declare
  v_fim date := least(p_fim, fn_hoje() - 1);
  v_qtd integer;
begin
  if p_ini > v_fim then
    return 0;
  end if;

  -- Dias de períodos fechados ficam congelados: não são apagados nem recalculados
  delete from banco_horas
   where origem = 'automatico'
     and data between p_ini and v_fim
     and (p_colaborador is null or colaborador_id = p_colaborador)
     and not fn_periodo_fechado(data);

  insert into banco_horas (colaborador_id, data, tipo, origem, minutos, descricao, usuario_id)
  select a.colaborador_id, a.data,
         case when a.saldo_min > 0 then 'credito' else 'debito' end::tipo_lancamento_bh,
         'automatico', a.saldo_min,
         case when a.falta then 'Falta não justificada'
              when a.saldo_min > 0 then 'Horas excedentes'
              else 'Horas não trabalhadas' end,
         nullif(current_setting('app.usuario_id', true), '')::uuid
    from fn_apuracao(p_ini, v_fim, p_colaborador) a
   where a.saldo_min <> 0 and a.banco_horas and not a.fechado;

  get diagnostics v_qtd = row_count;
  return v_qtd;
end $$;

-- Processa os dias encerrados desde a última execução. Chamado pelas APIs
-- (dashboard, banco de horas, meu ponto), então o saldo está sempre em dia.
create or replace function fn_banco_horas_atualizar()
returns void language plpgsql volatile set search_path = public as $$
declare
  v_ate   date;
  v_ontem date := fn_hoje() - 1;
begin
  select banco_horas_processado_ate into v_ate from empresa where id = 1 for update;
  if v_ate is null then
    select min(fn_inicio_controle(c)) - 1 into v_ate from colaboradores c;
  end if;
  if v_ate is null or v_ate < v_ontem then
    if v_ate is not null then
      perform fn_processar_banco_horas(v_ate + 1, v_ontem);
    end if;
    update empresa set banco_horas_processado_ate = v_ontem where id = 1;
  end if;
end $$;

-- Batida incluída/alterada/removida em dia já encerrado → recalcula aquele dia
create or replace function fn_batidas_reprocessar()
returns trigger language plpgsql as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.data_referencia < fn_hoje() then
    perform fn_processar_banco_horas(old.data_referencia, old.data_referencia, old.colaborador_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.data_referencia < fn_hoje()
     and (tg_op = 'INSERT' or new.data_referencia is distinct from old.data_referencia
          or new.colaborador_id is distinct from old.colaborador_id
          or new.status is distinct from old.status or new.data_hora is distinct from old.data_hora
          or new.sentido is distinct from old.sentido) then
    perform fn_processar_banco_horas(new.data_referencia, new.data_referencia, new.colaborador_id);
  end if;
  return null;
end $$;

drop trigger if exists trg_batidas_reprocessar on batidas;
create trigger trg_batidas_reprocessar after insert or update or delete on batidas
  for each row execute function fn_batidas_reprocessar();

-- Ausência lançada/alterada → recalcula o período afetado
create or replace function fn_ausencias_reprocessar()
returns trigger language plpgsql as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform fn_processar_banco_horas(old.data_inicio, old.data_fim, old.colaborador_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') then
    perform fn_processar_banco_horas(new.data_inicio, new.data_fim, new.colaborador_id);
  end if;
  return null;
end $$;

drop trigger if exists trg_ausencias_reprocessar on ausencias;
create trigger trg_ausencias_reprocessar after insert or update or delete on ausencias
  for each row execute function fn_ausencias_reprocessar();

-- -----------------------------------------------------------------------------
-- Fechamento de período: bloqueia alterações no ponto de dias fechados
-- (vale para qualquer caminho de escrita, não só para a API). A exclusão em cascata
-- de um colaborador removido continua permitida.
-- -----------------------------------------------------------------------------
create or replace function fn_bloquear_periodo_fechado()
returns trigger language plpgsql as $$
declare
  v_ini date;
  v_fim date;
begin
  if tg_op = 'DELETE' and not exists (select 1 from colaboradores where id = old.colaborador_id) then
    return old;
  end if;
  if tg_table_name = 'batidas' then
    if tg_op <> 'INSERT' and fn_periodo_fechado(old.data_referencia)
       or tg_op <> 'DELETE' and fn_periodo_fechado(new.data_referencia) then
      raise exception 'O dia % está em um período fechado. Reabra o período para alterar as batidas.',
        to_char(coalesce(new.data_referencia, old.data_referencia), 'DD/MM/YYYY');
    end if;
  elsif tg_table_name = 'ausencias' then
    if tg_op <> 'INSERT' then v_ini := old.data_inicio; v_fim := old.data_fim; end if;
    if tg_op <> 'DELETE' then
      v_ini := least(v_ini, new.data_inicio);
      v_fim := greatest(v_fim, new.data_fim);
    end if;
    if exists (select 1 from fechamentos f where f.data_inicio <= v_fim and f.data_fim >= v_ini) then
      raise exception 'O período da ocorrência alcança um período fechado. Reabra o período para alterá-la.';
    end if;
  elsif tg_table_name = 'banco_horas' then
    -- Os automáticos já pulam os dias fechados em fn_processar_banco_horas
    if (case when tg_op = 'DELETE' then old.origem else new.origem end) = 'automatico' then
      return coalesce(new, old);
    end if;
    if tg_op <> 'INSERT' and fn_periodo_fechado(old.data)
       or tg_op <> 'DELETE' and fn_periodo_fechado(new.data) then
      raise exception 'O dia % está em um período fechado.', to_char(coalesce(new.data, old.data), 'DD/MM/YYYY');
    end if;
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_batidas_fechamento on batidas;
create trigger trg_batidas_fechamento before insert or update or delete on batidas
  for each row execute function fn_bloquear_periodo_fechado();

drop trigger if exists trg_ausencias_fechamento on ausencias;
create trigger trg_ausencias_fechamento before insert or update or delete on ausencias
  for each row execute function fn_bloquear_periodo_fechado();

drop trigger if exists trg_banco_horas_fechamento on banco_horas;
create trigger trg_banco_horas_fechamento before insert or update or delete on banco_horas
  for each row execute function fn_bloquear_periodo_fechado();

create or replace function api_processar_banco_horas(p_token text, p_ini date, p_fim date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'banco_horas', true);
  return jsonb_build_object('ok', true, 'lancamentos', fn_processar_banco_horas(p_ini, p_fim));
end $$;

-- -----------------------------------------------------------------------------
-- API: Dashboard
-- -----------------------------------------------------------------------------
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
                 to_char(jd.entrada, 'HH24:MI') as entrada_prevista,
                 a.atraso_min,
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
                       (select pe.tolerancia_entrada_min from perfis_eventos pe where pe.id = c.perfil_evento_id), 0))
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

-- -----------------------------------------------------------------------------
-- Eventos da folha de horas extras: um por percentual usado nos perfis de eventos
--   50 → 'he_50' ("Horas extras 50%"), 62.5 → 'he_62_5' ("Horas extras 62,5%")
-- -----------------------------------------------------------------------------
create or replace function fn_he_chave(p numeric)
returns text language sql immutable as $$
  select 'he_' || replace(trim_scale(p)::text, '.', '_');
$$;

create or replace function fn_eventos_he_sincronizar()
returns void language sql volatile set search_path = public as $$
  insert into eventos_folha (chave, descricao, unidade, ordem)
  select distinct fn_he_chave(h.percentual),
         'Horas extras ' || replace(trim_scale(h.percentual)::text, '.', ',') || '%',
         'horas', least(29, 10 + round(h.percentual / 10))::smallint
    from perfil_evento_he h
  on conflict (chave) do nothing;
  -- Percentual que deixou de ser usado e não tem código cadastrado sai da lista
  delete from eventos_folha e
   where e.chave like 'he\_%' and e.codigo is null
     and not exists (select 1 from perfil_evento_he h where fn_he_chave(h.percentual) = e.chave);
$$;

-- -----------------------------------------------------------------------------
-- Permissões de execução
-- Somente as funções api_* ficam expostas à chave pública.
-- -----------------------------------------------------------------------------
-- Fecha as funções internas (fn_* e demais) sem tocar nas api_* já liberadas pelos
-- scripts 05–09, para que reexecutar este arquivo sozinho não tire o acesso a elas.
do $$
declare f regprocedure;
begin
  for f in
    select p.oid::regprocedure
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname not like 'api\_%'
       and p.prokind = 'f'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')  -- funções de extensões
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

grant execute on function api_ping()                                   to anon, authenticated;
grant execute on function api_login(text, text, text)                  to anon, authenticated;
grant execute on function api_sessao(text)                             to anon, authenticated;
grant execute on function api_logout(text)                             to anon, authenticated;
grant execute on function api_alterar_senha(text, text, text)          to anon, authenticated;
grant execute on function api_dashboard(text, date, date)              to anon, authenticated;
grant execute on function api_processar_banco_horas(text, date, date)  to anon, authenticated;

-- Regras de apuração podem ter mudado: o banco de horas automático é recalculado desde o início
-- na próxima abertura do dashboard, do Banco de Horas ou do Meu Ponto (dias fechados ficam como estão).
update empresa set banco_horas_processado_ate = null where id = 1;

-- Atualiza o cache de funções da API do Supabase (PostgREST)
notify pgrst, 'reload schema';
