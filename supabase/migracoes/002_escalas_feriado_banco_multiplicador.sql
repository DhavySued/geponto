-- =============================================================================
-- GePonto: atualização 002
-- • Escalas com nome, período de até 30 dias e registro guardado (consultar, alterar, excluir)
-- • Feriado trabalhado em escala: todo o tempo é hora extra de feriado
-- • Banco de horas com o percentual de hora extra da regra de cálculo (feriado 100% → 8h viram 16h)
-- Requer: atualização 001. Pode ser executado mais de uma vez.
-- =============================================================================

-- ---------- Cadastro das escalas (as escalas antigas viram registros) ----------
-- Escala lançada: o registro com nome, período (até 30 dias), dias da semana, horários e colaboradores.
-- Gera os dias em `escalas` e fica guardada para consultar e alterar depois.
create table if not exists escala_lancamentos (
  id                 uuid primary key default gen_random_uuid(),
  nome               text not null,
  tipo               text not null check (tipo in ('trabalho', 'folga')),
  data_inicio        date not null,
  data_fim           date not null,
  dias_semana        smallint[] not null default '{0,1,2,3,4,5,6}',
  entrada            time,
  saida_intervalo    time,
  retorno_intervalo  time,
  saida              time,
  observacao         text,
  colaboradores      uuid[] not null default '{}',
  usuario_id         uuid references usuarios(id) on delete set null,   -- quem lançou
  alterado_por       uuid references usuarios(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (data_fim >= data_inicio)
);
create index if not exists ix_escala_lancamentos_periodo on escala_lancamentos (data_inicio, data_fim);

alter table escalas add column if not exists lancamento_id uuid references escala_lancamentos(id) on delete cascade;
create index if not exists ix_escalas_lancamento on escalas (lancamento_id);

-- Escalas lançadas antes do cadastro: cada lançamento antigo (mesma gravação, tipo e horários) vira um registro
do $$
declare
  r record;
  v_id uuid;
begin
  if not exists (select 1 from escalas where lancamento_id is null) then return; end if;
  -- Só o vínculo muda: sem bloqueio de período fechado nem recálculo do banco
  alter table escalas disable trigger user;
  for r in
    select e.usuario_id, e.created_at, e.tipo, e.entrada, e.saida_intervalo, e.retorno_intervalo, e.saida,
           nullif(trim(e.observacao), '') as observacao,
           min(e.data) as ini, max(e.data) as fim,
           array_agg(distinct extract(dow from e.data)::smallint order by extract(dow from e.data)::smallint) as dias,
           array_agg(distinct e.colaborador_id) as colabs
      from escalas e
     where e.lancamento_id is null
     group by 1, 2, 3, 4, 5, 6, 7, 8
  loop
    insert into escala_lancamentos (nome, tipo, data_inicio, data_fim, dias_semana, entrada, saida_intervalo,
                                    retorno_intervalo, saida, observacao, colaboradores, usuario_id, created_at, updated_at)
    values (coalesce(left(r.observacao, 80), case r.tipo when 'trabalho' then 'Escala de trabalho' else 'Escala de folga' end)
              || ' (' || to_char(r.ini, 'DD/MM') || case when r.fim > r.ini then ' a ' || to_char(r.fim, 'DD/MM') else '' end || ')',
            r.tipo, r.ini, r.fim, r.dias, r.entrada, r.saida_intervalo, r.retorno_intervalo, r.saida, r.observacao,
            r.colabs, r.usuario_id, r.created_at, r.created_at)
    returning id into v_id;
    update escalas e set lancamento_id = v_id
     where e.lancamento_id is null
       and e.usuario_id is not distinct from r.usuario_id and e.created_at = r.created_at and e.tipo = r.tipo
       and e.entrada is not distinct from r.entrada and e.saida_intervalo is not distinct from r.saida_intervalo
       and e.retorno_intervalo is not distinct from r.retorno_intervalo and e.saida is not distinct from r.saida
       and nullif(trim(e.observacao), '') is not distinct from r.observacao;
  end loop;
  alter table escalas enable trigger user;
end $$;

drop trigger if exists trg_escala_lancamentos_updated on escala_lancamentos;
create trigger trg_escala_lancamentos_updated before update on escala_lancamentos
  for each row execute function fn_set_updated_at();
alter table escala_lancamentos enable row level security;
revoke all on escala_lancamentos from anon, authenticated;

-- ---------- Regra de cálculo: multiplicador do banco de horas ----------
-- Banco de horas com o percentual de hora extra do dia: crédito = excedente × (1 + percentual).
-- Ex.: feriado a 100% → 8h trabalhadas viram 16h no banco. Débitos continuam hora por hora.
-- Vem ligado (também nas regras que já existiam): desligue na regra para voltar ao hora por hora.
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'perfis_eventos' and column_name = 'bh_multiplicar') then
    alter table perfis_eventos add column bh_multiplicar boolean not null default true;
  end if;
end $$;

-- ---------- Apuração e banco de horas ----------
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

-- 125 → "2h05"
create or replace function fn_minutos_texto(p_min integer)
returns text language sql immutable as $$
  select (abs(p_min) / 60)::text || 'h' || lpad((abs(p_min) % 60)::text, 2, '0');
$$;

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
         case when a.banco_min > 0 then 'credito' else 'debito' end::tipo_lancamento_bh,
         'automatico', a.banco_min,
         case when a.falta then 'Falta não justificada'
              when a.banco_min > a.saldo_min then
                'Horas excedentes (' || fn_minutos_texto(a.saldo_min) || ' + ' || case when a.he_percentual = trunc(a.he_percentual) then trunc(a.he_percentual)::text else replace(rtrim(a.he_percentual::text, '0'), '.', ',') end || '%)'
              when a.banco_min > 0 then 'Horas excedentes'
              else 'Horas não trabalhadas' end,
         nullif(current_setting('app.usuario_id', true), '')::uuid
    from fn_apuracao(p_ini, v_fim, p_colaborador) a
   where a.banco_min <> 0 and a.banco_horas and not a.fechado;

  get diagnostics v_qtd = row_count;
  return v_qtd;
end $$;

create or replace function api_perfil_evento_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d        jsonb := p_dados;
  v_id     uuid := nullif(d ->> 'id', '')::uuid;
  v_padrao boolean := coalesce((d ->> 'padrao')::boolean, false);
  v_ativo  boolean := coalesce((d ->> 'ativo')::boolean, true);
  v_era_padrao boolean;
begin
  perform fn_auth(p_token, 'perfis_eventos', true);

  if fn_txt(d, 'nome') is null then raise exception 'Informe o nome do perfil.'; end if;
  if jsonb_typeof(d -> 'he') <> 'array'
     or (select count(distinct (x ->> 'dia')::int) from jsonb_array_elements(d -> 'he') x
          where (x ->> 'dia')::int between 0 and 8 and fn_txt(x, 'percentual') is not null) <> 9 then
    raise exception 'Informe o percentual de hora extra de todos os dias da semana, do feriado e da folga.';
  end if;
  if coalesce(fn_txt(d, 'tolerancia_modo'), 'batida') not in ('batida', 'diaria') then
    raise exception 'Escolha a tolerância por batida ou a geral do dia.';
  end if;
  if exists (select 1 from jsonb_array_elements(d -> 'he') x
              where (x ->> 'percentual')::numeric not between 0 and 999) then
    raise exception 'O percentual de hora extra deve ficar entre 0%% e 999%%.';
  end if;
  if v_padrao and not v_ativo then
    raise exception 'O perfil padrão precisa estar ativo.';
  end if;

  select padrao into v_era_padrao from perfis_eventos where id = v_id;
  if coalesce(v_era_padrao, false) and not v_padrao then
    raise exception 'Este é o perfil padrão. Para trocar, marque outro perfil como padrão.';
  end if;
  if v_padrao then
    update perfis_eventos set padrao = false where padrao and id is distinct from v_id;
  end if;

  if v_id is null then
    insert into perfis_eventos (nome, descricao, padrao, ativo) values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'), v_padrao, v_ativo)
    returning id into v_id;
  else
    if v_era_padrao is null then raise exception 'Perfil não encontrado.'; end if;
    if not v_ativo and exists (select 1 from colaboradores where perfil_evento_id = v_id and situacao <> 'desligado') then
      raise exception 'Há colaboradores ativos com este perfil. Mude o perfil deles antes de desativá-lo.';
    end if;
  end if;

  update perfis_eventos set
    nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'), padrao = v_padrao, ativo = v_ativo,
    tolerancia_entrada_min = coalesce(fn_txt(d, 'tolerancia_entrada_min')::smallint, 5),
    tolerancia_saida_min   = coalesce(fn_txt(d, 'tolerancia_saida_min')::smallint, 5),
    tolerancia_diaria_min  = coalesce(fn_txt(d, 'tolerancia_diaria_min')::smallint, 10),
    tolerancia_modo        = coalesce(fn_txt(d, 'tolerancia_modo'), 'batida'),
    limite_he_diario_min   = coalesce(fn_txt(d, 'limite_he_diario_min')::smallint, 120),
    usa_banco_horas        = coalesce((d ->> 'usa_banco_horas')::boolean, true),
    bh_multiplicar         = coalesce((d ->> 'bh_multiplicar')::boolean, true),
    noturno_inicio         = coalesce(fn_txt(d, 'noturno_inicio')::time, '22:00'),
    noturno_fim            = coalesce(fn_txt(d, 'noturno_fim')::time, '05:00'),
    percentual_noturno     = coalesce(fn_txt(d, 'percentual_noturno')::numeric, 20),
    hora_noturna_reduzida  = coalesce((d ->> 'hora_noturna_reduzida')::boolean, true)
  where id = v_id;

  insert into perfil_evento_he (perfil_id, dia, percentual)
  select v_id, (x ->> 'dia')::smallint, (x ->> 'percentual')::numeric
    from jsonb_array_elements(d -> 'he') x
   where (x ->> 'dia')::int between 0 and 8
  on conflict (perfil_id, dia) do update set percentual = excluded.percentual;

  perform fn_eventos_he_sincronizar();

  -- As regras valem para os dias já encerrados: recalcula o banco de horas de quem usa o perfil
  perform fn_processar_banco_horas(least(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao)),
                                   fn_hoje() - 1, c.id)
     from colaboradores c
    where c.perfil_evento_id = v_id;

  return jsonb_build_object('id', v_id);
exception
  when unique_violation then
    raise exception 'Já existe um perfil com este nome.';
  when check_violation then
    raise exception 'Valores inválidos: tolerâncias, limite e percentuais não podem ser negativos.';
  when invalid_datetime_format or datetime_field_overflow then
    raise exception 'Horário inválido. Use o formato HH:MM.';
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception 'Confira os números informados.';
end $$;

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
                 -- DSR perdido: semanas (dom–sáb) com falta não justificada
                 count(distinct date_trunc('week', t.data + 1)) filter (where t.falta)            as dsr_perdidos,
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
grant execute on function api_totais_periodo(text, date, date, uuid, uuid, uuid[])             to anon, authenticated;

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

-- ---------- API das escalas ----------
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

create or replace function fn_escala_lancamento_json(l escala_lancamentos)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', l.id, 'nome', l.nome, 'tipo', l.tipo, 'data_inicio', l.data_inicio, 'data_fim', l.data_fim,
    'dias_semana', to_jsonb(l.dias_semana),
    'entrada', to_char(l.entrada, 'HH24:MI'), 'saida_intervalo', to_char(l.saida_intervalo, 'HH24:MI'),
    'retorno_intervalo', to_char(l.retorno_intervalo, 'HH24:MI'), 'saida', to_char(l.saida, 'HH24:MI'),
    'observacao', l.observacao,
    'colaboradores', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'nome', c.nome, 'matricula', c.matricula)
                                                order by c.nome)
                                 from colaboradores c where c.id = any(l.colaboradores) and fn_visivel(c.id)), '[]'::jsonb),
    'dias', (select count(*) from escalas e where e.lancamento_id = l.id),
    'fechado', exists (select 1 from escalas e where e.lancamento_id = l.id and fn_periodo_fechado(e.data)),
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
--            entrada?, saida_intervalo?, retorno_intervalo?, saida?, observacao? }
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

  if v_tipo = 'trabalho' then
    v_ent := fn_txt(d, 'entrada')::time;
    v_si  := fn_txt(d, 'saida_intervalo')::time;
    v_ri  := fn_txt(d, 'retorno_intervalo')::time;
    v_sai := fn_txt(d, 'saida')::time;
    if v_ent is null or v_sai is null then raise exception 'Informe a entrada e a saída da escala de trabalho.'; end if;
    if (v_si is null) <> (v_ri is null) then
      raise exception 'Informe a saída e o retorno do intervalo (ou deixe os dois em branco).';
    end if;
    if v_ent = v_sai then raise exception 'A entrada e a saída não podem ser iguais.'; end if;
    if v_si is not null and
       (fn_minutos(v_ent, v_si) + fn_minutos(v_si, v_ri) + fn_minutos(v_ri, v_sai) <> fn_minutos(v_ent, v_sai)
        or v_si = v_ent or v_ri = v_si or v_sai = v_ri) then
      raise exception 'Os horários do intervalo precisam ficar entre a entrada e a saída.';
    end if;
  end if;

  select array_agg(g::date order by g) into v_datas
    from generate_series(v_ini, v_fim, interval '1 day') g
   where extract(dow from g)::smallint = any(v_dias);
  if v_datas is null then raise exception 'Nenhum dia do período cai nos dias da semana marcados.'; end if;

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
                                    retorno_intervalo, saida, observacao, colaboradores, usuario_id)
    values (v_nome, v_tipo, v_ini, v_fim, v_dias, v_ent, v_si, v_ri, v_sai, nullif(trim(fn_txt(d, 'observacao')), ''),
            v_colabs, v_usuario)
    returning id into v_id;
  else
    update escala_lancamentos
       set nome = v_nome, tipo = v_tipo, data_inicio = v_ini, data_fim = v_fim, dias_semana = v_dias,
           entrada = v_ent, saida_intervalo = v_si, retorno_intervalo = v_ri, saida = v_sai,
           observacao = nullif(trim(fn_txt(d, 'observacao')), ''), colaboradores = v_colabs, alterado_por = v_usuario
     where id = v_id;
    -- Dias que saíram da escala (o trigger de fechamento impede mexer em período fechado)
    delete from escalas e
     where e.lancamento_id = v_id
       and not (e.colaborador_id = any(v_colabs) and e.data = any(v_datas));
  end if;

  insert into escalas (colaborador_id, data, tipo, entrada, saida_intervalo, retorno_intervalo, saida, observacao,
                       usuario_id, lancamento_id)
  select c, dt, v_tipo, v_ent, v_si, v_ri, v_sai, v_nome, v_usuario, v_id
    from unnest(v_colabs) c cross join unnest(v_datas) dt
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
  if exists (select 1 from escalas e where e.lancamento_id = p_id and fn_periodo_fechado(e.data)) then
    raise exception 'A escala alcança um período fechado. Reabra o período para excluí-la.';
  end if;
  delete from escala_lancamentos where id = p_id;   -- os dias saem junto (on delete cascade)
  return jsonb_build_object('ok', true);
end $$;

grant execute on function api_escalas_grade(text, date, date, uuid, uuid, uuid[])              to anon, authenticated;

grant execute on function api_escalas_lancamentos(text, date, date, uuid[], text)         to anon, authenticated;

grant execute on function api_escala_lancamento(text, uuid)                              to anon, authenticated;

grant execute on function api_escala_lancamento_salvar(text, jsonb)                      to anon, authenticated;

grant execute on function api_escala_lancamento_excluir(text, uuid)                      to anon, authenticated;


-- ---------- Recalcula o banco de horas dos dias que não estão em período fechado ----------
-- (créditos com o percentual da regra e feriados com escala; os dias fechados ficam como estão)
do $$
declare
  v_ini date := (select min(data) from banco_horas where origem = 'automatico');
begin
  if v_ini is not null then
    perform fn_processar_banco_horas(v_ini, fn_hoje() - 1);
  end if;
end $$;

notify pgrst, 'reload schema';
