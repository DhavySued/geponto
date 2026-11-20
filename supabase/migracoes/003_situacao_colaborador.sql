-- =============================================================================
-- GePonto: atualização 003 — Situação do Colaborador
-- • Situação, cargo, departamento, jornada, regra de cálculo e salário valem a partir de uma data
-- • A primeira situação é a da admissão; a apuração de cada dia usa a situação vigente naquele dia
-- • Os colaboradores existentes ganham as situações a partir do histórico de jornadas e da situação atual
-- Requer: atualização 002. Pode ser executado mais de uma vez.
-- =============================================================================

-- ---------- Cadastro das situações (e situações dos colaboradores existentes) ----------
-- -----------------------------------------------------------------------------
-- Situação do Colaborador: o que vale a partir de cada data (situação, cargo, departamento,
-- jornada, regra de cálculo e salário). A primeira é a da admissão. A apuração de cada dia
-- usa a situação vigente naquele dia; o cadastro (colaboradores) guarda a vigente hoje.
-- Situação "desligado": a data é a do desligamento (último dia apurado).
-- -----------------------------------------------------------------------------
create table if not exists colaborador_situacoes (
  id                uuid primary key default gen_random_uuid(),
  colaborador_id    uuid not null references colaboradores(id) on delete cascade,
  data_inicio       date not null,
  situacao          situacao_colaborador not null default 'ativo',
  cargo_id          uuid references cargos(id) on delete set null,
  departamento_id   uuid references departamentos(id) on delete set null,
  jornada_id        uuid references jornadas(id),
  perfil_evento_id  uuid references perfis_eventos(id),
  salario           numeric(12,2),
  motivo            text,
  usuario_id        uuid references usuarios(id) on delete set null,
  alterado_por      uuid references usuarios(id) on delete set null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (colaborador_id, data_inicio)
);
create index if not exists ix_situacoes_jornada on colaborador_situacoes (jornada_id);

drop trigger if exists trg_colaborador_situacoes_updated on colaborador_situacoes;
create trigger trg_colaborador_situacoes_updated before update on colaborador_situacoes
  for each row execute function fn_set_updated_at();
alter table colaborador_situacoes enable row level security;
revoke all on colaborador_situacoes from anon, authenticated;

-- Colaboradores que já existiam: uma situação na admissão e uma a cada troca de jornada já
-- registrada; a situação atual (desligado, férias, afastado) entra na data em que passou a valer.
insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                   jornada_id, perfil_evento_id, salario, motivo)
select c.id, x.d, 'ativo', c.cargo_id, c.departamento_id,
       coalesce((select cj.jornada_id from colaborador_jornadas cj
                  where cj.colaborador_id = c.id and cj.data_inicio <= x.d
                  order by cj.data_inicio desc limit 1), c.jornada_id),
       c.perfil_evento_id, c.salario,
       case when x.d = c.data_admissao then 'Admissão' else 'Troca de jornada' end
  from colaboradores c
 cross join lateral (
   select c.data_admissao as d
   union
   select cj.data_inicio from colaborador_jornadas cj
    where cj.colaborador_id = c.id and cj.data_inicio > c.data_admissao) x
 where not exists (select 1 from colaborador_situacoes s where s.colaborador_id = c.id);

insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                   jornada_id, perfil_evento_id, salario, motivo)
select c.id, x.d, c.situacao, c.cargo_id, c.departamento_id, c.jornada_id, c.perfil_evento_id, c.salario,
       case c.situacao when 'desligado' then 'Desligamento' when 'ferias' then 'Férias' else 'Afastamento' end
  from colaboradores c
 cross join lateral (
   select greatest(c.data_admissao,
            case when c.situacao = 'desligado' then coalesce(c.data_desligamento, c.data_admissao)
                 else coalesce((select max(h.data_vigencia) from colaborador_historico h
                                 where h.colaborador_id = c.id and h.tipo = 'situacao'), c.data_admissao) end) as d) x
 where c.situacao <> 'ativo'
   and not exists (select 1 from colaborador_situacoes s where s.colaborador_id = c.id and s.situacao <> 'ativo')
on conflict (colaborador_id, data_inicio) do update set situacao = excluded.situacao, motivo = excluded.motivo;

-- ---------- Cadastro do colaborador: a admissão cria a primeira situação ----------
create or replace function fn_colaborador_historico()
returns trigger language plpgsql as $$
declare
  v_usuario  uuid := nullif(current_setting('app.usuario_id', true), '')::uuid;
  v_vigencia date := coalesce(nullif(current_setting('app.data_vigencia', true), '')::date, current_date);
  v_old jsonb;
  v_new jsonb;
  v_diff_old jsonb := '{}'::jsonb;
  v_diff_new jsonb := '{}'::jsonb;
  k text;
begin
  if tg_op = 'INSERT' then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'admissao', 'Colaborador admitido em ' || to_char(new.data_admissao, 'DD/MM/YYYY'),
            to_jsonb(new) - 'created_at' - 'updated_at', v_usuario, new.data_admissao);
    -- Primeira situação: a da admissão (e o desligamento, se o colaborador já entra desligado)
    insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                       jornada_id, perfil_evento_id, salario, motivo, usuario_id)
    values (new.id, new.data_admissao,
            case when new.situacao = 'desligado' and coalesce(new.data_desligamento, new.data_admissao) > new.data_admissao
                 then 'ativo' else new.situacao end,
            new.cargo_id, new.departamento_id, new.jornada_id, new.perfil_evento_id, new.salario, 'Admissão', v_usuario)
    on conflict (colaborador_id, data_inicio) do nothing;
    if new.situacao = 'desligado' and coalesce(new.data_desligamento, new.data_admissao) > new.data_admissao then
      insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                         jornada_id, perfil_evento_id, salario, motivo, usuario_id)
      values (new.id, new.data_desligamento, 'desligado', new.cargo_id, new.departamento_id, new.jornada_id,
              new.perfil_evento_id, new.salario, 'Desligamento', v_usuario)
      on conflict (colaborador_id, data_inicio) do nothing;
    end if;
    return new;
  end if;

  v_old := to_jsonb(old) - 'updated_at' - 'created_at';
  v_new := to_jsonb(new) - 'updated_at' - 'created_at';
  for k in select jsonb_object_keys(v_new) loop
    if v_old -> k is distinct from v_new -> k then
      v_diff_old := v_diff_old || jsonb_build_object(k, v_old -> k);
      v_diff_new := v_diff_new || jsonb_build_object(k, v_new -> k);
    end if;
  end loop;

  if v_diff_new = '{}'::jsonb then
    return new;
  end if;

  if new.situacao is distinct from old.situacao then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'situacao', 'Situação alterada de ' || old.situacao || ' para ' || new.situacao,
            jsonb_build_object('situacao', old.situacao), jsonb_build_object('situacao', new.situacao),
            v_usuario, v_vigencia);
  end if;
  if new.cargo_id is distinct from old.cargo_id then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'cargo', 'Mudança de cargo',
            jsonb_build_object('cargo', (select nome from cargos where id = old.cargo_id)),
            jsonb_build_object('cargo', (select nome from cargos where id = new.cargo_id)), v_usuario, v_vigencia);
  end if;
  if new.departamento_id is distinct from old.departamento_id then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'departamento', 'Transferência de departamento',
            jsonb_build_object('departamento', (select nome from departamentos where id = old.departamento_id)),
            jsonb_build_object('departamento', (select nome from departamentos where id = new.departamento_id)),
            v_usuario, v_vigencia);
  end if;
  if new.jornada_id is distinct from old.jornada_id then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'jornada', 'Alteração de jornada de trabalho',
            jsonb_build_object('jornada', (select nome from jornadas where id = old.jornada_id)),
            jsonb_build_object('jornada', (select nome from jornadas where id = new.jornada_id)), v_usuario, v_vigencia);

  end if;

  if to_jsonb(new) ? 'perfil_evento_id' and v_old -> 'perfil_evento_id' is distinct from v_new -> 'perfil_evento_id' then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'perfil_evento', 'Mudança de perfil de eventos',
            jsonb_build_object('perfil', (select nome from perfis_eventos where id = (v_old ->> 'perfil_evento_id')::uuid)),
            jsonb_build_object('perfil', (select nome from perfis_eventos where id = (v_new ->> 'perfil_evento_id')::uuid)),
            v_usuario, v_vigencia);
  end if;

  -- Demais campos cadastrais
  v_diff_new := v_diff_new - 'situacao' - 'cargo_id' - 'departamento_id' - 'jornada_id' - 'perfil_evento_id';
  v_diff_old := v_diff_old - 'situacao' - 'cargo_id' - 'departamento_id' - 'jornada_id' - 'perfil_evento_id';
  if v_diff_new <> '{}'::jsonb then
    insert into colaborador_historico (colaborador_id, tipo, descricao, dados_anteriores, dados_novos, usuario_id, data_vigencia)
    values (new.id, 'cadastro', 'Dados cadastrais atualizados', v_diff_old, v_diff_new, v_usuario, v_vigencia);
  end if;

  return new;
end $$;

-- ---------- Jornada e regra de cálculo do dia vêm da situação ----------
-- Jornada válida para o colaborador em uma data (a da situação vigente naquele dia)
create or replace function fn_jornada_vigente(p_colaborador uuid, p_data date)
returns uuid language sql stable set search_path = public as $$
  select v.jornada_id
    from (select s.jornada_id, 0 as ordem, s.data_inicio
            from colaborador_situacoes s
           where s.colaborador_id = p_colaborador and s.data_inicio <= p_data
          union all
          select c.jornada_id, 1, null from colaboradores c where c.id = p_colaborador) v
   order by v.ordem, v.data_inicio desc
   limit 1;
$$;

-- Regra de cálculo válida para o colaborador em uma data
create or replace function fn_perfil_vigente(p_colaborador uuid, p_data date)
returns uuid language sql stable set search_path = public as $$
  select coalesce(
    (select s.perfil_evento_id from colaborador_situacoes s
      where s.colaborador_id = p_colaborador and s.data_inicio <= p_data
      order by s.data_inicio desc limit 1),
    (select c.perfil_evento_id from colaboradores c where c.id = p_colaborador));
$$;

-- Leva ao cadastro a situação vigente hoje (situação, cargo, departamento, jornada, regra e salário)
-- e a data de desligamento (a última situação, se for "desligado")
create or replace function fn_colaborador_situacao_aplicar(p_colaborador uuid)
returns void language plpgsql volatile set search_path = public as $$
declare
  s colaborador_situacoes%rowtype;
  v_ultima colaborador_situacoes%rowtype;
  v_deslig date;
begin
  select * into s from colaborador_situacoes
   where colaborador_id = p_colaborador and data_inicio <= fn_hoje()
   order by data_inicio desc limit 1;
  if not found then   -- admissão futura: vale a primeira
    select * into s from colaborador_situacoes where colaborador_id = p_colaborador order by data_inicio limit 1;
    if not found then return; end if;
  end if;
  select * into v_ultima from colaborador_situacoes
   where colaborador_id = p_colaborador order by data_inicio desc limit 1;
  v_deslig := case when v_ultima.situacao = 'desligado' then v_ultima.data_inicio end;

  perform set_config('app.data_vigencia', s.data_inicio::text, true);
  update colaboradores c set
         situacao = s.situacao, cargo_id = s.cargo_id, departamento_id = s.departamento_id,
         jornada_id = s.jornada_id, perfil_evento_id = coalesce(s.perfil_evento_id, c.perfil_evento_id),
         salario = s.salario, data_desligamento = v_deslig
   where c.id = p_colaborador
     and (c.situacao, c.cargo_id, c.departamento_id, c.jornada_id, c.perfil_evento_id, c.salario, c.data_desligamento)
         is distinct from
         (s.situacao, s.cargo_id, s.departamento_id, s.jornada_id, coalesce(s.perfil_evento_id, c.perfil_evento_id),
          s.salario, v_deslig);
end $$;

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
  he_percentual         numeric,   -- percentual de HE do dia, pelo perfil de eventos (feriado, folga ou dia da semana)
  noturno_min           integer,   -- minutos de relógio na faixa noturna
  noturno_reduzido_min  integer,   -- com a hora noturna reduzida (52min30s), quando aplicável
  intervalo_min         integer,   -- descanso intrajornada realizado
  interjornada_min      integer,   -- descanso desde a última batida do dia anterior trabalhado
  banco_horas           boolean,   -- o saldo do dia vai para o banco de horas (senão: HE/desconto)
  feriado               boolean,   -- feriado valendo para o colaborador (escala de trabalho no dia anula)
  fechado               boolean,   -- dia dentro de um período fechado
  escala                text,      -- escala do dia: 'trabalho', 'folga' ou null (segue a jornada)
  -- Antes das justificativas que abonam (atraso_min / saida_antecipada_min já vêm sem os minutos abonados)
  atraso_bruto_min            integer,
  saida_antecipada_bruta_min  integer,
  falta_bruta                 boolean,   -- dia previsto, encerrado e sem batidas (antes de qualquer abono)
  abono_justificativa_min     integer,   -- minutos abonados por justificativas (atraso, saída e falta)
  falta_folha                 boolean,   -- falta levada para a folha (não debitada do banco de horas)
  banco_min                   integer    -- o que vai para o banco: saldo, com o crédito multiplicado pelo percentual de HE
)
language sql stable set search_path = public as $$
with cfg as (
  select fn_fuso() as tz, fn_hoje() as hoje
),
dias as (
  -- Jornada e regra de cálculo da situação vigente em cada dia
  select c.id as colaborador_id, d::date as data,
         case when s.data_inicio is not null then s.jornada_id else c.jornada_id end as jornada_id,
         coalesce(s.perfil_evento_id, c.perfil_evento_id) as perfil_id
    from colaboradores c
   cross join generate_series(p_ini, p_fim, interval '1 day') d
    left join lateral (
      select x.data_inicio, x.jornada_id, x.perfil_evento_id, x.situacao
        from colaborador_situacoes x
       where x.colaborador_id = c.id and x.data_inicio <= d::date
       order by x.data_inicio desc
       limit 1) s on true
   where (p_colaborador is null or c.id = p_colaborador)
     and c.controla_ponto
     and fn_inicio_controle(c) <= d::date
     and (c.data_desligamento is null or c.data_desligamento >= d::date)
     -- depois de um desligamento (e até uma readmissão) o dia não é apurado
     and not coalesce(s.situacao = 'desligado' and s.data_inicio < d::date, false)
),
base as (
  -- A escala do dia (tabela escalas) substitui o dia da jornada: 'trabalho' cria a previsão com os
  -- horários dela, mesmo em folga ou feriado (o feriado deixa de valer para o colaborador nesse dia);
  -- 'folga' zera a previsão.
  select dd.colaborador_id, dd.data, dd.jornada_id,
         case when e.id is not null then e.tipo = 'folga' else jd.folga end as folga,
         case when e.id is not null then e.entrada else jd.entrada end as entrada,
         case when e.id is not null then e.saida else jd.saida end as saida,
         case when e.id is not null then e.saida_intervalo else jd.saida_intervalo end as saida_intervalo,
         case when e.id is not null then e.retorno_intervalo else jd.retorno_intervalo end as retorno_intervalo,
         e.tipo as escala,
         coalesce(j.intervalo_flexivel, false)
           and (case when e.id is not null then e.saida_intervalo else jd.saida_intervalo end) is not null
           as intervalo_flexivel,
         -- Modo de tolerância do perfil: 'batida' usa entrada/saída em cada marcação (a marcação dentro
         -- dela conta como o horário previsto); 'diaria' usa só a geral do dia, sobre o saldo e como
         -- limite para apontar atraso/saída antecipada.
         coalesce(pe.tolerancia_modo, 'batida') as tolerancia_modo,
         case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else pe.tolerancia_entrada_min end
           as tolerancia_entrada_min,
         case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else pe.tolerancia_saida_min end
           as tolerancia_saida_min,
         case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else 0 end as tolerancia_diaria_min,
         pe.hora_noturna_reduzida,
         coalesce(pe.usa_banco_horas, false) as usa_bh,
         coalesce(pe.bh_multiplicar, false) as bh_multiplicar,
         coalesce(ph.percentual, 50) as he_percentual,
         (f.id is not null and e.tipo is distinct from 'trabalho') as feriado,
         -- Escalado para trabalhar no feriado: a previsão da escala vale (faltar é falta), mas todo o tempo
         -- trabalhado é hora extra com o percentual de Feriado — pago em dobro (Súmula 146 do TST)
         (f.id is not null and e.tipo = 'trabalho') as feriado_escalado,
         a.tipo as ausencia_tipo,
         coalesce(a.abona, false) as abona,
         coalesce(ap.minutos, 0) as abono_parcial,
         -- Justificativas que abonam (minutos null = abona tudo)
         ja.id is not null as ja_abona, ja.minutos as ja_min,
         js.id is not null as js_abona, js.minutos as js_min,
         jf.id is not null as jf_abona, jf.minutos as jf_min,
         ff.colaborador_id is not null as falta_folha_marcada
    from dias dd
    left join jornadas j      on j.id = dd.jornada_id
    left join jornada_dias jd on jd.jornada_id = dd.jornada_id
                             and jd.dia_semana = fn_jornada_indice(j.tipo, j.ciclo_dias, j.data_base, dd.data)
    left join escalas e       on e.colaborador_id = dd.colaborador_id and e.data = dd.data
    left join feriados f      on f.data = dd.data
    left join perfis_eventos pe on pe.id = dd.perfil_id
    left join perfil_evento_he ph on ph.perfil_id = dd.perfil_id
                                 and ph.dia = case when f.id is not null then 7
                                                   when coalesce(case when e.id is not null then e.tipo = 'folga'
                                                                      else jd.folga end, true) then 8
                                                   else extract(dow from dd.data)::int end
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
    left join justificativas ja on ja.colaborador_id = dd.colaborador_id and ja.data = dd.data
                               and ja.tipo = 'atraso' and ja.abona
    left join justificativas js on js.colaborador_id = dd.colaborador_id and js.data = dd.data
                               and js.tipo = 'saida_antecipada' and js.abona
    left join justificativas jf on jf.colaborador_id = dd.colaborador_id and jf.data = dd.data
                               and jf.tipo = 'falta' and jf.abona
    left join faltas_folha ff   on ff.colaborador_id = dd.colaborador_id and ff.data = dd.data
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
-- Tolerância por batida: a marcação dentro da tolerância do horário previsto conta como o próprio
-- horário previsto (E1 entrada · S1 saída p/ intervalo ou saída · E2 retorno · S2 saída).
-- Intervalo flexível: a saída para o intervalo (S1) vale como foi batida, e o retorno (E2) previsto é
-- a saída real + a duração do intervalo — dentro da tolerância de entrada, o intervalo conta como o previsto.
pares_aj as (
  select p.*,
         case when pv.e is not null and abs(extract(epoch from p.ini - pv.e) / 60) <= bs.tolerancia_entrada_min
              then pv.e
              when p.tur = 2 and bs.intervalo_flexivel and bs.tolerancia_modo = 'batida' and p.pausa is not null
                   and abs(extract(epoch from p.pausa) / 60 - fn_minutos(bs.saida_intervalo, bs.retorno_intervalo))
                       <= bs.tolerancia_entrada_min
              then p.ini - p.pausa + make_interval(mins => fn_minutos(bs.saida_intervalo, bs.retorno_intervalo))
              else p.ini end as ini_aj,
         case when pv.s is not null and abs(extract(epoch from p.fim - pv.s) / 60) <= bs.tolerancia_saida_min
              then pv.s else p.fim end as fim_aj
    from pares p
   cross join cfg
    left join base bs on bs.colaborador_id = p.colaborador_id and bs.data = p.data_referencia
    left join lateral (
      select (bs.data + h.e + case when h.e < bs.entrada then interval '1 day' else interval '0' end) at time zone cfg.tz as e,
             (bs.data + h.s + case when h.s <= bs.entrada then interval '1 day' else interval '0' end) at time zone cfg.tz as s
        from (select case p.tur when 1 then bs.entrada
                                when 2 then case when not bs.intervalo_flexivel then bs.retorno_intervalo end end as e,
                     case p.tur when 1 then case when bs.intervalo_flexivel then null
                                                 else coalesce(bs.saida_intervalo, bs.saida) end
                                when 2 then case when bs.saida_intervalo is not null then bs.saida end end as s) h
       where bs.tolerancia_modo = 'batida' and not coalesce(bs.folga, true) and not bs.feriado
         and bs.entrada is not null
    ) pv on true
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
         sum(extract(epoch from greatest(p.fim_aj - p.ini_aj, interval '0')) / 60)::int as trabalhado,
         sum(fn_minutos_noturnos(p.ini at time zone cfg.tz, p.fim at time zone cfg.tz,
                                 coalesce(pe.noturno_inicio, '22:00'), coalesce(pe.noturno_fim, '05:00')))::int as noturno,
         (sum(extract(epoch from p.pausa) / 60))::int as pausa
    from pares_aj p
   cross join cfg
    left join perfis_eventos pe on pe.id = fn_perfil_vigente(p.colaborador_id, p.data_referencia)
   group by p.colaborador_id, p.data_referencia
),
marc_inter as (
  select m.*, lag(m.ultima_ts) over (partition by m.colaborador_id order by m.data) as ultima_anterior
    from marc m
),
calc as (
  select bs.*,
         case when (bs.jornada_id is null and bs.escala is null) or coalesce(bs.folga, true) or bs.feriado or bs.abona then 0
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
res0 as (
  select c.*,
         (c.previsto > 0 and c.qtd = 0 and not c.em_andamento) as falta_bruta,
         case when c.previsto > 0 and c.primeira_turno is not null
                   and extract(epoch from c.primeira_turno - c.entrada_turno) / 60 > c.tolerancia_entrada_min
              then (extract(epoch from c.primeira_turno - c.entrada_turno) / 60)::int
              else 0 end as atraso_bruto,
         case when c.previsto > 0 and c.qtd > 0 and c.qtd = 2 * c.pares and not c.em_andamento
                   and extract(epoch from (c.data + c.saida + case when c.saida <= c.entrada then interval '1 day'
                                                                    else interval '0' end) - c.ultima) / 60
                       > c.tolerancia_saida_min
              then (extract(epoch from (c.data + c.saida + case when c.saida <= c.entrada then interval '1 day'
                                                                else interval '0' end) - c.ultima) / 60)::int
              else 0 end as antecipada_bruta
    from calc c
),
-- Justificativa que abona: tira os minutos do atraso/saída antecipada e cobre o débito do dia
res1 as (
  select r.*,
         case when r.ja_abona then least(coalesce(r.ja_min, r.atraso_bruto), r.atraso_bruto) else 0 end as abono_atraso,
         case when r.js_abona then least(coalesce(r.js_min, r.antecipada_bruta), r.antecipada_bruta) else 0 end
           as abono_antecipada,
         case when r.jf_abona and r.falta_bruta then least(coalesce(r.jf_min, r.previsto), r.previsto) else 0 end
           as abono_falta
    from res0 r
),
res as (
  select r.*,
         least(r.abono_parcial + r.abono_atraso + r.abono_antecipada + r.abono_falta,
               greatest(r.previsto - r.trabalhado, 0)) as abonado,
         r.atraso_bruto - r.abono_atraso as atraso,
         r.antecipada_bruta - r.abono_antecipada as antecipada
    from res1 r
),
fin as (
  select r.*,
         (r.previsto > 0 and r.qtd = 0 and not r.em_andamento and r.abonado < r.previsto) as e_falta,
         -- Turno incompleto (entrada sem saída ou vice-versa) não soma horas: o previsto dele vira débito
         case when r.em_andamento then 0
              when r.feriado_escalado and r.qtd > 0 then r.trabalhado
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
       case when f.jornada_id is null and f.escala is null then 'sem_jornada'
            when f.ausencia_tipo is not null   then 'ausencia:' || f.ausencia_tipo
            when f.feriado and f.qtd = 0       then 'feriado'
            when coalesce(f.folga, true) and f.qtd = 0 then 'folga'
            when f.em_andamento                then 'em_andamento'
            when f.e_falta                     then 'falta'
            when f.abono_falta > 0             then 'falta_abonada'
            when f.qtd <> 2 * f.pares          then 'inconsistente'
            when f.atraso > 0                  then 'atraso'
            when f.antecipada > 0              then 'saida_antecipada'
            when f.saldo > 0                   then 'hora_extra'
            when f.abono_atraso > 0            then 'atraso_abonado'
            when f.abono_antecipada > 0        then 'saida_antecipada_abonada'
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
       -- Falta levada para a folha: o dia sai do banco (vai para a folha como falta)
       f.usa_bh and not (f.falta_folha_marcada and f.e_falta),
       f.feriado,
       f.fechado,
       f.escala,
       f.atraso_bruto,
       f.antecipada_bruta,
       f.falta_bruta,
       f.abono_atraso + f.abono_antecipada + f.abono_falta,
       f.falta_folha_marcada and f.e_falta,
       case when not (f.usa_bh and not (f.falta_folha_marcada and f.e_falta)) then 0
            when f.saldo > 0 and f.bh_multiplicar then round(f.saldo * (1 + coalesce(f.he_percentual, 0) / 100.0))::int
            else f.saldo end
  from fin f;
$$;
revoke execute on function fn_apuracao(date, date, uuid)                from public, anon, authenticated;

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
    -- Situações que passaram a valer desde a última execução vão para o cadastro
    perform fn_colaborador_situacao_aplicar(x.colaborador_id)
       from (select distinct s.colaborador_id from colaborador_situacoes s
              where s.data_inicio > coalesce(v_ate, '-infinity'::date) and s.data_inicio <= fn_hoje()) x;
    if v_ate is not null then
      perform fn_processar_banco_horas(v_ate + 1, v_ontem);
    end if;
    update empresa set banco_horas_processado_ate = v_ontem where id = 1;
  end if;
end $$;

-- ---------- API ----------
-- -----------------------------------------------------------------------------
-- Situação do Colaborador
-- -----------------------------------------------------------------------------
-- Último dia de período fechado (as situações até ele ficam travadas)
create or replace function fn_fechado_ate()
returns date language sql stable set search_path = public as $$
  select max(data_fim) from fechamentos;
$$;

-- Situações (de um colaborador ou de uma lista), da mais recente para a mais antiga
create or replace function fn_situacoes_json(p_colaborador uuid, p_colaboradores uuid[])
returns jsonb language sql stable set search_path = public as $$
  with s as (
    select s.*,
           lead(s.data_inicio) over w - 1 as data_fim,
           row_number() over w = 1 as primeira
      from colaborador_situacoes s
     where fn_filtro_colaborador(s.colaborador_id, p_colaborador, p_colaboradores)
    window w as (partition by s.colaborador_id order by s.data_inicio)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'colaborador_id', s.colaborador_id, 'colaborador', c.nome, 'matricula', c.matricula,
           'data_inicio', s.data_inicio, 'data_fim', s.data_fim, 'situacao', s.situacao,
           'cargo_id', s.cargo_id, 'cargo', g.nome, 'departamento_id', s.departamento_id, 'departamento', d.nome,
           'jornada_id', s.jornada_id, 'jornada', j.nome, 'perfil_evento_id', s.perfil_evento_id, 'perfil_evento', pe.nome,
           'salario', s.salario, 'motivo', s.motivo, 'primeira', s.primeira,
           'vigente', s.data_inicio <= fn_hoje() and (s.data_fim is null or s.data_fim >= fn_hoje()),
           'futura', s.data_inicio > fn_hoje(),
           'fechado', s.data_inicio <= coalesce(fn_fechado_ate(), '-infinity'::date),
           'usuario', u.nome, 'alterado_por', u2.nome, 'created_at', s.created_at, 'updated_at', s.updated_at)
         order by c.nome, s.data_inicio desc), '[]'::jsonb)
    from s
    join colaboradores c on c.id = s.colaborador_id
    left join cargos g          on g.id = s.cargo_id
    left join departamentos d   on d.id = s.departamento_id
    left join jornadas j        on j.id = s.jornada_id
    left join perfis_eventos pe on pe.id = s.perfil_evento_id
    left join usuarios u        on u.id = s.usuario_id
    left join usuarios u2       on u2.id = s.alterado_por
   where fn_visivel(c.id);
$$;

-- Tela Situação do Colaborador: situações filtradas e as listas para o formulário
create or replace function api_colaborador_situacoes(p_token text, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'situacoes_colaborador');
  return jsonb_build_object(
    'situacoes', fn_situacoes_json(null, p_colaboradores),
    'fechado_ate', fn_fechado_ate(),
    'colaboradores', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'situacao', c.situacao,
               'data_admissao', c.data_admissao, 'departamento_id', c.departamento_id,
               'cargo_id', c.cargo_id, 'jornada_id', c.jornada_id) order by c.nome)
        from colaboradores c where fn_visivel(c.id)), '[]'::jsonb),
    'cargos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                          from cargos where ativo), '[]'::jsonb),
    'departamentos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from departamentos where ativo), '[]'::jsonb),
    'jornadas', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                            from jornadas where ativo), '[]'::jsonb),
    'perfis_eventos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'padrao', padrao)
                                                 order by padrao desc, nome)
                                  from perfis_eventos where ativo), '[]'::jsonb));
end $$;

-- Inclui ou altera uma situação. Vale da data informada até a véspera da seguinte.
create or replace function api_colaborador_situacao_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d jsonb := p_dados;
  v_id uuid := nullif(d ->> 'id', '')::uuid;
  v_colab uuid := nullif(d ->> 'colaborador_id', '')::uuid;
  v_old colaborador_situacoes%rowtype;
  v_data date;
  v_adm date;
  v_primeira date;
  v_fechado date := fn_fechado_ate();
  v_perfil uuid;
  v_jornada uuid := fn_txt(d, 'jornada_id')::uuid;
  v_usuario uuid := nullif(current_setting('app.usuario_id', true), '')::uuid;
begin
  perform fn_auth(p_token, 'situacoes_colaborador', true);
  if v_id is not null then
    select * into v_old from colaborador_situacoes where id = v_id;
    if not found then raise exception 'Situação não encontrada.'; end if;
    v_colab := v_old.colaborador_id;
  end if;
  if v_colab is null then raise exception 'Escolha o colaborador.'; end if;
  if not fn_visivel(v_colab) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  if fn_txt(d, 'data_inicio') is null then raise exception 'Informe a partir de quando a situação vale.'; end if;
  v_data := fn_txt(d, 'data_inicio')::date;

  select data_admissao into v_adm from colaboradores where id = v_colab;
  select min(data_inicio) into v_primeira from colaborador_situacoes where colaborador_id = v_colab;
  if v_data < v_adm then
    raise exception 'A situação não pode começar antes da admissão (%).', to_char(v_adm, 'DD/MM/YYYY');
  end if;
  if v_id is not null and v_old.data_inicio = v_primeira and v_data <> v_old.data_inicio then
    raise exception 'A primeira situação começa na admissão. Para mudar a data, altere a admissão no cadastro do colaborador.';
  end if;
  if v_fechado is not null and (v_data <= v_fechado or v_old.data_inicio <= v_fechado) then
    raise exception 'O período até % está fechado. Lance a nova situação a partir de % ou reabra o fechamento.',
      to_char(v_fechado, 'DD/MM/YYYY'), to_char(v_fechado + 1, 'DD/MM/YYYY');
  end if;
  if exists (select 1 from colaborador_situacoes
              where colaborador_id = v_colab and data_inicio = v_data and id is distinct from v_id) then
    raise exception 'Já existe uma situação em % para este colaborador. Altere-a em vez de criar outra.',
      to_char(v_data, 'DD/MM/YYYY');
  end if;

  v_perfil := coalesce(fn_txt(d, 'perfil_evento_id')::uuid, (select id from perfis_eventos where padrao));
  if not exists (select 1 from perfis_eventos where id = v_perfil and (ativo or id = v_old.perfil_evento_id)) then
    raise exception 'Escolha uma regra de cálculo ativa.';
  end if;
  if v_jornada is not null and not exists (
       select 1 from jornadas where id = v_jornada and (ativo or id = v_old.jornada_id)) then
    raise exception 'Escolha uma jornada ativa.';
  end if;

  perform set_config('app.data_vigencia', v_data::text, true);
  if v_id is null then
    insert into colaborador_situacoes (colaborador_id, data_inicio, situacao, cargo_id, departamento_id,
                                       jornada_id, perfil_evento_id, salario, motivo, usuario_id)
    values (v_colab, v_data, coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador,
            fn_txt(d, 'cargo_id')::uuid, fn_txt(d, 'departamento_id')::uuid, v_jornada, v_perfil,
            fn_txt(d, 'salario')::numeric, fn_txt(d, 'motivo'), v_usuario)
    returning id into v_id;
  else
    update colaborador_situacoes set
           data_inicio = v_data, situacao = coalesce(fn_txt(d, 'situacao'), 'ativo')::situacao_colaborador,
           cargo_id = fn_txt(d, 'cargo_id')::uuid, departamento_id = fn_txt(d, 'departamento_id')::uuid,
           jornada_id = v_jornada, perfil_evento_id = v_perfil, salario = fn_txt(d, 'salario')::numeric,
           motivo = fn_txt(d, 'motivo'), alterado_por = v_usuario
     where id = v_id;
  end if;

  perform fn_colaborador_situacao_aplicar(v_colab);
  -- A apuração muda a partir da data: recalcula o banco de horas dos dias já encerrados
  perform fn_processar_banco_horas(least(v_data, coalesce(v_old.data_inicio, v_data)), fn_hoje() - 1, v_colab);
  return jsonb_build_object('id', v_id);
exception
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Data inválida.';
  when invalid_text_representation then
    raise exception 'Valor inválido. Confira o salário e as datas.';
end $$;

create or replace function api_colaborador_situacao_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_old colaborador_situacoes%rowtype;
  v_fechado date := fn_fechado_ate();
begin
  perform fn_auth(p_token, 'situacoes_colaborador', true);
  select * into v_old from colaborador_situacoes where id = p_id;
  if not found then raise exception 'Situação não encontrada.'; end if;
  if not fn_visivel(v_old.colaborador_id) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  if v_old.data_inicio = (select min(data_inicio) from colaborador_situacoes where colaborador_id = v_old.colaborador_id) then
    raise exception 'A situação da admissão não pode ser excluída. Altere-a, se precisar.';
  end if;
  if v_fechado is not null and v_old.data_inicio <= v_fechado then
    raise exception 'O período até % está fechado. Reabra o fechamento para excluir esta situação.', to_char(v_fechado, 'DD/MM/YYYY');
  end if;
  delete from colaborador_situacoes where id = p_id;
  perform fn_colaborador_situacao_aplicar(v_old.colaborador_id);
  perform fn_processar_banco_horas(v_old.data_inicio, fn_hoje() - 1, v_old.colaborador_id);
  return jsonb_build_object('ok', true);
end $$;


create or replace function api_colaborador_obter(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  perform fn_auth(p_token, 'colaboradores');
  select to_jsonb(c) - 'created_at' - 'updated_at'
         || jsonb_build_object(
              'historico', coalesce((
                select jsonb_agg(jsonb_build_object(
                         'id', h.id, 'tipo', h.tipo, 'descricao', h.descricao,
                         'dados_anteriores', h.dados_anteriores, 'dados_novos', h.dados_novos,
                         'usuario', u.nome, 'created_at', h.created_at, 'data_vigencia', h.data_vigencia)
                       order by h.data_vigencia desc, h.created_at desc)
                  from colaborador_historico h
                  left join usuarios u on u.id = h.usuario_id
                 where h.colaborador_id = c.id), '[]'::jsonb),
              'situacoes', fn_situacoes_json(c.id, null),
              'acesso', (
                select jsonb_build_object('usuario_id', u.id, 'login', u.login, 'status', u.status,
                                          'perfil', p.nome, 'ultimo_acesso', u.ultimo_acesso)
                  from usuarios u join perfis p on p.id = u.perfil_id
                 where u.colaborador_id = c.id
                 limit 1))
    into v
    from colaboradores c
   where c.id = p_id and fn_visivel(c.id);

  if v is null then
    raise exception 'Colaborador não encontrado.';
  end if;
  return v;
end $$;

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
  if fn_txt(d, 'matricula') is null then raise exception 'Informe a matrícula.'; end if;
  if length(regexp_replace(coalesce(d ->> 'cpf', ''), '[^0-9]', '', 'g')) <> 11 then
    raise exception 'Informe um CPF válido (11 dígitos).';
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

  if v_situacao = 'desligado' and v_deslig is null then
    v_deslig := fn_hoje();
  elsif v_situacao <> 'desligado' then
    v_deslig := null;
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
      data_admissao = v_admissao, observacoes = fn_txt(d, 'observacoes'),
      controla_ponto = coalesce((d ->> 'controla_ponto')::boolean, true),
      controle_ponto_inicio = v_controle,
      empresa_id = coalesce(fn_txt(d, 'empresa_id')::uuid, empresa_id)
    where id = v_id;
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
begin
  perform fn_auth(p_token, 'jornadas', true);

  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome da jornada.'; end if;
  if v_tipo not in ('semanal', 'escala') then raise exception 'Tipo de jornada inválido.'; end if;
  if v_tipo = 'escala' then
    if coalesce(v_ciclo, 0) not between 2 and 60 then
      raise exception 'O ciclo da escala deve ter de 2 a 60 dias (ex.: 12x36 = 2 dias).';
    end if;
    if fn_txt(d, 'data_base') is null then
      raise exception 'Informe a data de início do ciclo (o dia 1 da escala).';
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
    insert into jornadas (nome, descricao, ativo, tipo, ciclo_dias, data_base, intervalo_flexivel)
    values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'),
            coalesce((d ->> 'ativo')::boolean, true),
            v_tipo, case when v_tipo = 'escala' then v_ciclo end,
            case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
            coalesce((d ->> 'intervalo_flexivel')::boolean, false))
    returning id into v_id;
  else
    update jornadas set
      nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'),
      ativo = coalesce((d ->> 'ativo')::boolean, true),
      tipo = v_tipo,
      ciclo_dias = case when v_tipo = 'escala' then v_ciclo end,
      data_base = case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
      intervalo_flexivel = coalesce((d ->> 'intervalo_flexivel')::boolean, false)
    where id = v_id;
    if not found then raise exception 'Jornada não encontrada.'; end if;
    delete from jornada_dias where jornada_id = v_id;
  end if;

  insert into jornada_dias (jornada_id, dia_semana, folga, entrada, saida_intervalo, retorno_intervalo, saida)
  select v_id, (x ->> 'dia_semana')::smallint, f.folga,
         case when f.folga then null else fn_txt(x, 'entrada')::time end,
         case when f.folga then null else fn_txt(x, 'saida_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'retorno_intervalo')::time end,
         case when f.folga then null else fn_txt(x, 'saida')::time end
    from jsonb_array_elements(d -> 'dias') x
   cross join lateral (select coalesce((x ->> 'folga')::boolean, false) as folga) f;

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
    raise exception 'Valores inválidos: confira o ciclo e a data de início da escala.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Horário inválido. Use o formato HH:MM.';
end $$;

create or replace function api_jornada_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_qtd int;
begin
  perform fn_auth(p_token, 'jornadas', true);
  select count(distinct colaborador_id) into v_qtd
    from (select id as colaborador_id from colaboradores where jornada_id = p_id
          union all
          select colaborador_id from colaborador_situacoes where jornada_id = p_id) x;
  if v_qtd > 0 then
    raise exception 'Esta jornada está vinculada a % colaborador(es). Ela fica no histórico deles; desative-a em vez de excluir.', v_qtd;
  end if;
  delete from jornadas where id = p_id;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function api_colaborador_situacoes(text, uuid[])          to anon, authenticated;

grant execute on function api_colaborador_situacao_salvar(text, jsonb)     to anon, authenticated;

grant execute on function api_colaborador_situacao_excluir(text, uuid)     to anon, authenticated;

revoke execute on function fn_situacoes_json(uuid, uuid[])                 from public, anon, authenticated;

revoke execute on function fn_fechado_ate()                                from public, anon, authenticated;

revoke execute on function fn_perfil_vigente(uuid, date)                   from public, anon, authenticated;

revoke execute on function fn_colaborador_situacao_aplicar(uuid)           from public, anon, authenticated;


-- ---------- Menu e permissões ----------
insert into paginas (chave, nome, grupo, ordem) values
  ('situacoes_colaborador', 'Situação do Colaborador', 'Cadastros', 22)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

-- Situação do Colaborador: quem cuida do cadastro de colaboradores cuida também das situações
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'situacoes_colaborador', pode_visualizar, pode_editar
  from perfil_permissoes where pagina = 'colaboradores'
on conflict (perfil_id, pagina) do nothing;


-- O cadastro passa a refletir a situação vigente hoje
select fn_colaborador_situacao_aplicar(id) from colaboradores;

notify pgrst, 'reload schema';
