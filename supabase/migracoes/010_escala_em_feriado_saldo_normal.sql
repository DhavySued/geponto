-- =============================================================================
-- 010 · Escala de trabalho em feriado: a previsão da escala vale como dia normal
-- Requer: 009
--
-- Antes: escalado para trabalhar no feriado, todo o tempo trabalhado virava hora extra com o
-- percentual de Feriado (e, com o multiplicador do banco, entrava em dobro), sem descontar a
-- previsão da escala. Agora a escala substitui o feriado para o colaborador: o saldo é o
-- trabalhado menos o previsto da escala, com o percentual de HE do dia da semana.
-- Re-executável.
-- =============================================================================

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
bat as (
  select bt.colaborador_id, bt.data_referencia, bt.data_hora, bt.sentido as sent, bt.turno as tur, false as virtual
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
      select p.colaborador_id, p.data, v.ts, v.sent, v.tur, true
        from pre p
       cross join lateral (values (p.si, 'S', 1), (p.ri, 'E', 2)) v(ts, sent, tur)
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
         (array_agg(s.tur order by s.data_hora))[1] as primeiro_tur,
         bool_or(s.virtual) as pre_assinalado
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
         (bs.data >= cfg.hoje) as em_andamento,
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

-- Recalcula o banco de horas dos dias já encerrados com escala de trabalho em feriado
-- (períodos fechados continuam congelados)
do $$
declare r record;
begin
  for r in
    select distinct e.colaborador_id, e.data
      from escalas e
      join feriados f on f.data = e.data
     where e.tipo = 'trabalho' and e.data < fn_hoje()
  loop
    perform fn_processar_banco_horas(r.data, r.data, r.colaborador_id);
  end loop;
end $$;

notify pgrst, 'reload schema';
