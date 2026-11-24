-- =============================================================================
-- 016 · Configuração: contabilizar o banco de horas no fim do dia ou na finalização dos turnos
-- Requer: 015. Re-executável. Começa em "fim do dia" (como é hoje): nenhum saldo muda.
-- =============================================================================

-- Quando o saldo do dia entra no banco de horas: 'fim_dia' (só no dia seguinte) ou 'fim_turnos'
-- (assim que o colaborador fecha os turnos do dia)
alter table empresa add column if not exists banco_contabilizar text not null default 'fim_dia'
  check (banco_contabilizar in ('fim_dia', 'fim_turnos'));

-- Último dia que pode estar no banco: ontem ou, contabilizando na finalização dos turnos, hoje
create or replace function fn_banco_ate()
returns date language sql stable set search_path = public as $$
  select fn_hoje() - case when (select banco_contabilizar from empresa where id = 1) = 'fim_turnos' then 0 else 1 end;
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
  banco_min                   integer,   -- o que vai para o banco: saldo, com o crédito multiplicado pelo percentual de HE
  pre_assinalado              boolean    -- o intervalo do dia foi pré-assinalado (não batido)
)
language sql stable set search_path = public as $$
with cfg as (
  select fn_fuso() as tz, fn_hoje() as hoje,
         coalesce((select banco_contabilizar from empresa where id = 1), 'fim_dia') = 'fim_turnos' as fim_turnos
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
  -- horários dela, mesmo em folga ou feriado (o feriado deixa de valer para o colaborador nesse dia: o
  -- saldo é o trabalhado menos o previsto da escala, com o percentual de HE do dia da semana);
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
         coalesce(j.intervalo_pre_assinalado, false) and not coalesce(j.intervalo_flexivel, false) as pre_assinalado_jornada,
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
                                 -- escalado para trabalhar no feriado: o dia vale como dia normal da semana
                                 and ph.dia = case when f.id is not null and e.tipo is distinct from 'trabalho' then 7
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
-- O cálculo usa o minuto cheio (08:05:40 vale 08:05, como aparece nas telas); os segundos só desempatam a ordem.
bat as (
  select bt.colaborador_id, bt.data_referencia, date_trunc('minute', bt.data_hora) as data_hora, bt.data_hora as ord,
         bt.sentido as sent, bt.turno as tur, false as virtual
    from fn_batidas_periodo(p_ini - 1, p_fim, p_colaborador) bt
   where bt.status = 'valida'
),
-- Intervalo pré-assinalado: a jornada marca a opção e o colaborador bateu só a entrada e a saída
-- (sem as batidas do intervalo) → vale a saída e o retorno do intervalo previstos. São marcações
-- virtuais da apuração: as batidas registradas (e o AFD) não mudam.
pre as (
  select x.colaborador_id, x.data, x.si, x.ri
    from (
      select bs.colaborador_id, bs.data, b.ini, b.fim,
             (bs.data + bs.saida_intervalo
              + case when bs.saida_intervalo < bs.entrada then interval '1 day' else interval '0' end) at time zone cfg.tz as si,
             (bs.data + bs.retorno_intervalo
              + case when bs.retorno_intervalo < bs.entrada then interval '1 day' else interval '0' end) at time zone cfg.tz as ri
        from base bs
       cross join cfg
        join (select colaborador_id, data_referencia, min(data_hora) as ini, max(data_hora) as fim
                from bat
               group by colaborador_id, data_referencia
              having count(*) = 2
                 and count(*) filter (where sent = 'E' and tur = 1) = 1
                 and count(*) filter (where sent = 'S' and tur = 2) = 1) b
          on b.colaborador_id = bs.colaborador_id and b.data_referencia = bs.data
       where bs.pre_assinalado_jornada and not coalesce(bs.folga, true)
         and bs.entrada is not null and bs.saida_intervalo is not null and bs.retorno_intervalo is not null
    ) x
   where x.ini < x.si and x.ri < x.fim
),
seq as (
  select x.*,
         lead(x.sent)      over w2 as prox_sent,
         lead(x.tur)       over w2 as prox_tur,
         lead(x.data_hora) over w2 as prox
    from (
      select * from bat
      union all
      select p.colaborador_id, p.data, v.ts, v.ts, v.sent, v.tur, true
        from pre p
       cross join lateral (values (p.si, 'S', 1), (p.ri, 'E', 2)) v(ts, sent, tur)
    ) x
  window w2 as (partition by x.colaborador_id, x.data_referencia order by x.ord)
),
-- Pares entrada → saída do mesmo turno (turno só conta com as duas), com o descanso desde o par anterior
pares as (
  select p.*, p.ini - lag(p.fim) over (partition by p.colaborador_id, p.data_referencia order by p.ord) as pausa
    from (
      select s.colaborador_id, s.data_referencia, s.data_hora as ini, s.prox as fim, s.tur, s.ord
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
         (array_agg(s.sent order by s.ord desc))[1] as ultimo_sentido,
         (array_agg(s.tur order by s.ord))[1] as primeiro_tur,
         bool_or(s.virtual) as pre_assinalado
    from seq s
   group by s.colaborador_id, s.data_referencia
),
marc_pares as (
  select p.colaborador_id, p.data_referencia as data,
         count(*)::int as pares,
         min(p.ini) as primeiro_ini,
         (array_agg(p.tur order by p.ord))[1] as primeiro_tur,
         max(p.tur) as ultimo_tur,
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
         coalesce(m.pre_assinalado, false) as pre_assinalado,
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
         -- O dia de hoje fica em andamento até acabar ou, contabilizando na finalização dos turnos, até fechar o
         -- último turno previsto (folga e feriado: qualquer turno) sem nenhuma batida em aberto
         (bs.data > cfg.hoje
          or (bs.data = cfg.hoje
              and not (cfg.fim_turnos
                       and coalesce(m.qtd, 0) > 0 and m.qtd = 2 * coalesce(mp.pares, 0)
                       and mp.ultimo_tur >= case when bs.saida_intervalo is not null and not coalesce(bs.folga, true)
                                                      and not bs.feriado and not bs.abona then 2 else 1 end))) as em_andamento,
         fn_periodo_fechado(bs.data, bs.colaborador_id) as fechado
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
            else f.saldo end,
       f.pre_assinalado
  from fin f;
$$;

revoke execute on function fn_apuracao(date, date, uuid) from public, anon, authenticated;

create or replace function fn_processar_banco_horas(p_ini date, p_fim date, p_colaborador uuid default null)
returns integer language plpgsql volatile set search_path = public as $$
declare
  -- Quem recalcula até ontem recalcula também hoje, quando o banco é contabilizado na finalização dos turnos
  v_fim date := case when p_fim >= fn_hoje() - 1 then fn_banco_ate() else p_fim end;
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
     and not fn_periodo_fechado(data, colaborador_id);

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
       from (select s.colaborador_id from colaborador_situacoes s
              where s.data_inicio > coalesce(v_ate, '-infinity'::date) and s.data_inicio <= fn_hoje()
             union   -- e quem passou da data de desligamento
             select c.id from colaboradores c
              where c.data_desligamento >= coalesce(v_ate, '-infinity'::date) and c.data_desligamento < fn_hoje()) x;
    if v_ate is not null then
      perform fn_processar_banco_horas(v_ate + 1, v_ontem);
    end if;
    update empresa set banco_horas_processado_ate = v_ontem where id = 1;
  end if;
  -- Contabilizando na finalização dos turnos: mantém o dia de hoje igual à apuração
  if fn_banco_ate() > v_ontem then
    perform fn_processar_banco_horas(v_ontem + 1, v_ontem + 1, x.colaborador_id)
       from (select a.colaborador_id
               from fn_apuracao(v_ontem + 1, v_ontem + 1) a
               left join banco_horas b on b.colaborador_id = a.colaborador_id and b.data = a.data and b.origem = 'automatico'
              where not a.fechado
                and coalesce(b.minutos, 0) <> case when a.banco_horas then a.banco_min else 0 end) x;
  end if;
end $$;

create or replace function fn_batidas_reprocessar()
returns trigger language plpgsql as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.data_referencia <= fn_banco_ate() then
    perform fn_processar_banco_horas(old.data_referencia, old.data_referencia, old.colaborador_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.data_referencia <= fn_banco_ate()
     and (tg_op = 'INSERT' or new.data_referencia is distinct from old.data_referencia
          or new.colaborador_id is distinct from old.colaborador_id
          or new.status is distinct from old.status or new.data_hora is distinct from old.data_hora
          or new.sentido is distinct from old.sentido) then
    perform fn_processar_banco_horas(new.data_referencia, new.data_referencia, new.colaborador_id);
  end if;
  return null;
end $$;

create or replace function fn_escalas_reprocessar()
returns trigger language plpgsql as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.data <= fn_banco_ate() then
    perform fn_processar_banco_horas(old.data, old.data, old.colaborador_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.data <= fn_banco_ate() then
    perform fn_processar_banco_horas(new.data, new.data, new.colaborador_id);
  end if;
  return null;
end $$;

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

create or replace function api_configuracoes(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_usuario uuid := fn_auth(p_token, 'configuracoes');
begin
  return (select jsonb_build_object(
            'pode_editar', fn_pode(v_usuario, 'configuracoes', true),
            'usar_limitacoes_ponto', e.usar_limitacoes_ponto,
            'bloquear_fora_cerca', e.bloquear_fora_cerca,
            'beneficio_turnos', e.beneficio_turnos,
            'banco_contabilizar', e.banco_contabilizar,
            'fuso_horario', e.fuso_horario,
            'empresas', coalesce((
              select jsonb_agg(jsonb_build_object(
                       'id', x.id, 'nome', coalesce(x.nome_fantasia, x.razao_social),
                       'tem_local', exists (select 1 from locais_ponto l where l.empresa_id = x.id and l.ativo),
                       'raio_m', (select l.raio_m from locais_ponto l where l.empresa_id = x.id and l.ativo))
                     order by coalesce(x.nome_fantasia, x.razao_social))
                from empresas x where x.ativo), '[]'::jsonb))
            from empresa e where e.id = 1);
end $$;

create or replace function api_configuracoes_salvar(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'configuracoes', true);
  if coalesce(fn_txt(p_dados, 'beneficio_turnos'), 'um') not in ('um', 'dois') then
    raise exception 'Opção inválida para VT e VA.';
  end if;
  if coalesce(fn_txt(p_dados, 'banco_contabilizar'), 'fim_dia') not in ('fim_dia', 'fim_turnos') then
    raise exception 'Opção inválida para o banco de horas.';
  end if;
  update empresa set
    usar_limitacoes_ponto = coalesce((p_dados ->> 'usar_limitacoes_ponto')::boolean, usar_limitacoes_ponto),
    bloquear_fora_cerca = coalesce((p_dados ->> 'bloquear_fora_cerca')::boolean, bloquear_fora_cerca),
    beneficio_turnos = coalesce(fn_txt(p_dados, 'beneficio_turnos'), beneficio_turnos),
    banco_contabilizar = coalesce(fn_txt(p_dados, 'banco_contabilizar'), banco_contabilizar)
   where id = 1;
  -- Mudou para o fim do dia: o que já tinha entrado hoje sai (volta amanhã); para os turnos: entra o que já fechou
  if fn_banco_ate() < fn_hoje() then
    delete from banco_horas
     where origem = 'automatico' and data >= fn_hoje() and not fn_periodo_fechado(data, colaborador_id);
  else
    perform fn_banco_horas_atualizar();
  end if;
  return jsonb_build_object('ok', true);
end $$;

update paginas set nome = 'Ponto, Banco de Horas, VT e VA' where chave = 'configuracoes';

revoke execute on function fn_banco_ate() from public, anon, authenticated;
revoke execute on function fn_processar_banco_horas(date, date, uuid) from public, anon, authenticated;
revoke execute on function fn_banco_horas_atualizar() from public, anon, authenticated;

notify pgrst, 'reload schema';
