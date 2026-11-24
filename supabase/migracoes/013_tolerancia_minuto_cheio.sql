-- =============================================================================
-- 013 · Tolerância: o cálculo usa o minuto cheio da batida (08:05:40 vale 08:05)
-- Requer: 012. Re-executável.
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
    insert into perfis_eventos (nome, descricao, padrao, ativo, empresa_id) values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'), v_padrao, v_ativo, fn_empresa_atual())
    returning id into v_id;
  else
    if v_era_padrao is null then raise exception 'Perfil não encontrado.'; end if;
    if not v_ativo and exists (select 1 from colaboradores where perfil_evento_id = v_id and situacao <> 'desligado') then
      raise exception 'Há colaboradores ativos com este perfil. Mude o perfil deles antes de desativá-lo.';
    end if;
  end if;

  update perfis_eventos set
    nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'), padrao = v_padrao, ativo = v_ativo,
    todas_empresas         = coalesce((d ->> 'todas_empresas')::boolean, todas_empresas),
    empresa_id             = coalesce(empresa_id, fn_empresa_atual()),
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
    where c.perfil_evento_id = v_id
       or exists (select 1 from colaborador_situacoes s where s.colaborador_id = c.id and s.perfil_evento_id = v_id);

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

create or replace function api_banco_horas_detalhe(p_token text, p_ini date, p_fim date, p_colaborador uuid default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_tz text := fn_fuso();
begin
  perform fn_auth(p_token, 'banco_horas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 62 then raise exception 'Selecione um período de até 2 meses.'; end if;
  if p_colaborador is not null and not fn_visivel(p_colaborador) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  perform fn_banco_horas_atualizar();

  drop table if exists pg_temp._bh_col;
  create temp table _bh_col on commit drop as
    select c.id, c.nome, c.matricula, d.nome as departamento, j.nome as jornada
      from colaboradores c
      left join departamentos d on d.id = c.departamento_id
      left join jornadas j      on j.id = c.jornada_id
     where fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
       and fn_visivel(c.id)
       and (c.situacao <> 'desligado' or exists (select 1 from banco_horas bh where bh.colaborador_id = c.id
                                                   and bh.data between p_ini and p_fim))
       and (c.controla_ponto or exists (select 1 from banco_horas bh where bh.colaborador_id = c.id));

  drop table if exists pg_temp._bh_ap;
  create temp table _bh_ap on commit drop as
    select a.* from fn_apuracao(p_ini, p_fim, p_colaborador) a where a.colaborador_id in (select id from _bh_col);

  -- Batidas válidas, com o instante local (minuto cheio)
  drop table if exists pg_temp._bh_bat;
  create temp table _bh_bat on commit drop as
    select b.id, b.colaborador_id, b.data_referencia as data, b.sentido, b.turno, b.origem, b.data_hora,
           date_trunc('minute', b.data_hora at time zone v_tz) as local
      from fn_batidas_periodo(p_ini, p_fim, p_colaborador) b
     where b.colaborador_id in (select id from _bh_col) and b.status = 'valida';

  -- Marcações previstas dos dias com previsão (feriado, folga e abono não têm).
  -- Intervalo flexível: a saída para o intervalo prevista é a real, e o retorno previsto é ela + a duração.
  drop table if exists pg_temp._bh_prev;
  create temp table _bh_prev on commit drop as
    select x.colaborador_id, x.data, x.sentido, x.turno,
           case when x.flex and x.s1 is not null then x.ts_flex::time else x.hora end as hora,
           case when x.flex and x.s1 is not null then x.ts_flex else x.ts end as ts
      from (
    select a.colaborador_id, a.data, v.sentido, v.turno, v.hora,
           a.data + v.hora + case when v.hora < jd.entrada then interval '1 day' else interval '0' end as ts,
           (jd.intervalo_flexivel and (v.sentido, v.turno) in (('S', 1), ('E', 2))) as flex,
           s1.local as s1,
           s1.local + case when v.sentido = 'E'
                           then make_interval(mins => fn_minutos(jd.saida_intervalo, jd.retorno_intervalo))
                           else interval '0' end as ts_flex
      from _bh_ap a
     cross join lateral fn_jornada_dia(a.colaborador_id, a.data) jd
      left join lateral (select min(b.local) as local from _bh_bat b
                          where jd.intervalo_flexivel and b.colaborador_id = a.colaborador_id and b.data = a.data
                            and b.sentido = 'S' and b.turno = 1) s1 on true
     cross join lateral (values ('E', 1, jd.entrada),
                                ('S', 1, coalesce(jd.saida_intervalo, jd.saida)),
                                ('E', 2, jd.retorno_intervalo),
                                ('S', 2, case when jd.saida_intervalo is not null then jd.saida end)) v(sentido, turno, hora)
     where a.previsto_min > 0 and v.hora is not null
      ) x;

  -- Turnos do dia: previsto, realizado (já com a tolerância por batida) e se fechou (entrada e saída)
  drop table if exists pg_temp._bh_tur;
  create temp table _bh_tur on commit drop as
    select k.colaborador_id, k.data, k.turno,
           coalesce((extract(epoch from ps.ts - pe.ts) / 60)::int, 0) as previsto_min,
           (be.local is not null and bs.local is not null) as completo,
           greatest(coalesce((extract(epoch from aj.s - aj.e) / 60)::int, 0), 0) as trabalhado_min,
           aj.e as e_aj, aj.s as s_aj,
           pe.ts as e_prev, ps.ts as s_prev
      from (select colaborador_id, data, turno from _bh_prev
            union
            select colaborador_id, data, turno from _bh_bat) k
      left join _bh_prev pe on pe.colaborador_id = k.colaborador_id and pe.data = k.data and pe.turno = k.turno and pe.sentido = 'E'
      left join _bh_prev ps on ps.colaborador_id = k.colaborador_id and ps.data = k.data and ps.turno = k.turno and ps.sentido = 'S'
      left join lateral (select min(b.local) as local from _bh_bat b
                          where b.colaborador_id = k.colaborador_id and b.data = k.data
                            and b.turno = k.turno and b.sentido = 'E') be on true
      left join lateral (select min(b.local) as local from _bh_bat b
                          where b.colaborador_id = k.colaborador_id and b.data = k.data
                            and b.turno = k.turno and b.sentido = 'S') bs on true
      left join perfis_eventos pf on pf.id = fn_perfil_vigente(k.colaborador_id, k.data) and pf.tolerancia_modo = 'batida'
     cross join lateral (
       select case when abs(extract(epoch from be.local - pe.ts) / 60) <= pf.tolerancia_entrada_min then pe.ts else be.local end as e,
              case when abs(extract(epoch from bs.local - ps.ts) / 60) <= pf.tolerancia_saida_min then ps.ts else bs.local end as s) aj;

  -- Linhas do dia: cada marcação prevista com a batida correspondente, mais as batidas sem previsão
  drop table if exists pg_temp._bh_lin;
  create temp table _bh_lin on commit drop as
    select coalesce(p.colaborador_id, b.colaborador_id) as colaborador_id, coalesce(p.data, b.data) as data,
           coalesce(p.turno, b.turno) as turno, coalesce(p.sentido, b.sentido) as sentido,
           p.hora as previsto, b.id as batida_id, b.local, b.origem,
           coalesce(b.local, p.ts) as ordem
      from _bh_prev p
      full join _bh_bat b on b.colaborador_id = p.colaborador_id and b.data = p.data
                         and b.turno = p.turno and b.sentido = p.sentido;

  drop table if exists pg_temp._bh_mov;
  create temp table _bh_mov on commit drop as
    select bh.colaborador_id, bh.data, sum(bh.minutos)::int as minutos
      from banco_horas bh
     where bh.colaborador_id in (select id from _bh_col) and bh.data between p_ini and p_fim
     group by bh.colaborador_id, bh.data;

  return coalesce((
    select jsonb_agg(col order by col ->> 'nome')
      from (
        select jsonb_build_object(
                 'id', c.id, 'nome', c.nome, 'matricula', c.matricula,
                 'departamento', c.departamento, 'jornada', c.jornada,
                 'saldo_anterior', s.anterior,
                 'creditos', coalesce((select sum(minutos) from banco_horas where colaborador_id = c.id
                                        and data between p_ini and p_fim and minutos > 0), 0),
                 'debitos', coalesce((select sum(minutos) from banco_horas where colaborador_id = c.id
                                       and data between p_ini and p_fim and minutos < 0), 0),
                 'saldo_final', s.anterior + coalesce((select sum(minutos) from _bh_mov where colaborador_id = c.id), 0),
                 'dias', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'data', a.data,
                            'horario_previsto', case when a.previsto_min > 0 then fn_horario_dia(a.colaborador_id, a.data) end,
                            'ocorrencia', a.ocorrencia,
                            'previsto_min', a.previsto_min,
                            'trabalhado_min', a.trabalhado_min,
                            'saldo_dia', a.saldo_min,
                            'vai_para_banco', a.banco_horas,
                            'falta', a.falta,
                            'falta_folha', a.falta_folha,
                            'fechado', a.fechado,
                            'banco_dia', coalesce(mv.minutos, 0),
                            'acumulado', s.anterior + coalesce((select sum(m2.minutos) from _bh_mov m2
                                                                 where m2.colaborador_id = c.id and m2.data <= a.data), 0),
                            'linhas', coalesce((
                              select jsonb_agg(jsonb_build_object(
                                       'turno', l.turno, 'sentido', l.sentido,
                                       'previsto', to_char(l.previsto, 'HH24:MI'),
                                       'hora', to_char(l.local, 'HH24:MI'),
                                       'origem', l.origem,
                                       'gerou_min', case
                                          when not t.completo or l.local is null then null
                                          when t.e_prev is not null and t.s_prev is not null then
                                            case when l.sentido = 'E' then (extract(epoch from t.e_prev - t.e_aj) / 60)::int
                                                 else (extract(epoch from t.s_aj - t.s_prev) / 60)::int end
                                          when l.sentido = 'S' then t.trabalhado_min
                                       end)
                                       order by l.turno, l.sentido, l.ordem)
                                from _bh_lin l
                                join _bh_tur t on t.colaborador_id = l.colaborador_id and t.data = l.data and t.turno = l.turno
                               where l.colaborador_id = c.id and l.data = a.data), '[]'::jsonb),
                            'turnos', coalesce((
                              select jsonb_agg(jsonb_build_object(
                                       'turno', t.turno, 'previsto_min', t.previsto_min,
                                       'trabalhado_min', case when t.completo then t.trabalhado_min else 0 end,
                                       'completo', t.completo,
                                       'gerou_min', case when t.completo then t.trabalhado_min else 0 end - t.previsto_min)
                                       order by t.turno)
                                from _bh_tur t
                               where t.colaborador_id = c.id and t.data = a.data), '[]'::jsonb),
                            'lancamentos', coalesce((
                              select jsonb_agg(jsonb_build_object('id', l.id, 'tipo', l.tipo, 'minutos', l.minutos,
                                                                  'descricao', l.descricao, 'usuario', u.nome)
                                               order by l.created_at)
                                from banco_horas l
                                left join usuarios u on u.id = l.usuario_id
                               where l.colaborador_id = c.id and l.data = a.data and l.origem = 'manual'), '[]'::jsonb))
                          order by a.data)
                     from _bh_ap a
                     left join _bh_mov mv on mv.colaborador_id = a.colaborador_id and mv.data = a.data
                    where a.colaborador_id = c.id
                      and (a.previsto_min > 0 or a.qtd_batidas > 0 or a.saldo_min <> 0 or mv.minutos is not null
                           or a.ocorrencia like 'ausencia:%')), '[]'::jsonb)
               ) as col
          from _bh_col c
         cross join lateral (
           select coalesce(sum(bh.minutos), 0)::int as anterior
             from banco_horas bh where bh.colaborador_id = c.id and bh.data < p_ini
         ) s
      ) x), '[]'::jsonb);
end $$;

create or replace function api_consulta_batidas(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null,
  p_cargo uuid default null, p_jornada uuid default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_tz    text := fn_fuso();
  v_agora timestamp := now() at time zone fn_fuso();
begin
  perform fn_auth_tratamento_leitura(p_token);
  if p_ini is null or p_fim is null or p_fim < p_ini then
    raise exception 'Informe um período válido.';
  end if;
  if p_fim - p_ini > 62 then
    raise exception 'Selecione um período de até 2 meses.';
  end if;

  return coalesce((
    with colab as (
      select c.*, d.nome as departamento
        from colaboradores c
        left join departamentos d on d.id = c.departamento_id
       where fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
         and (p_departamento is null or c.departamento_id = p_departamento)
         and (p_cargo        is null or c.cargo_id = p_cargo)
         and (p_jornada      is null or c.jornada_id = p_jornada)
         and fn_visivel(c.id)
    ),
    -- Jornada de cada colaborador em cada dia do período (só quem tem o ponto controlado;
    -- as batidas de quem não tem aparecem como "não controladas", sem previsão)
    dia as (
      select c.id as colaborador_id, g::date as data, jd.*, j.nome as jornada,
             -- tolerância por batida, ou a geral do dia quando o perfil usa só ela
             case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else pe.tolerancia_entrada_min end as tol_e,
             case when pe.tolerancia_modo = 'diaria' then pe.tolerancia_diaria_min else pe.tolerancia_saida_min end as tol_s,
             -- escala de trabalho no feriado: para o colaborador o dia é normal
             (f.id is not null and jd.escala is distinct from 'trabalho') as feriado, a.tipo as ausencia,
             fn_horario_dia(c.id, g::date) as horario_previsto,
             -- Observação do dia: ausência registrada (férias, afastamento…) ou feriado
             case a.tipo
               when 'ferias'            then 'Empregado de férias'
               when 'afastamento'       then 'Empregado afastado'
               when 'atestado'          then 'Empregado com atestado médico'
               when 'falta_justificada' then 'Falta justificada'
               when 'folga'             then 'Folga concedida'
               when 'abono'             then 'Dia abonado'
               else case when f.id is not null and jd.escala is distinct from 'trabalho' then 'Feriado: ' || f.descricao end
             end as obs_dia
        from colab c
       cross join generate_series(greatest(p_ini, c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao)),
                                  least(p_fim, coalesce(c.data_desligamento, p_fim)), interval '1 day') g
        left join lateral fn_jornada_dia(c.id, g::date) jd on true
        left join jornadas j on j.id = jd.jornada_id
        left join perfis_eventos pe on pe.id = fn_perfil_vigente(c.id, g::date)
        left join feriados f on f.data = g::date
        left join lateral (
          select au.tipo
            from ausencias au
           where au.colaborador_id = c.id
             and g::date between au.data_inicio and au.data_fim
             and au.minutos is null
           order by au.abona desc
           limit 1
        ) a on true
       where c.controla_ponto
    ),
    -- Marcações previstas do dia (E1, S1, E2, S2), com o instante local previsto.
    -- Intervalo flexível: S1 e E2 não têm horário fixo (flex) e só ficam "não registradas" depois da saída prevista.
    prev as (
      select d.colaborador_id, d.data, m.sentido, m.turno, m.hora,
             d.data + m.hora + case when m.hora < d.entrada then interval '1 day' else interval '0' end as ts,
             (d.intervalo_flexivel and (m.sentido, m.turno) in (('S', 1), ('E', 2))) as flex,
             d.data + d.saida + case when d.saida <= d.entrada then interval '1 day' else interval '0' end as ts_saida
        from dia d
       cross join lateral (values
         ('E', 1, d.entrada),
         ('S', 1, coalesce(d.saida_intervalo, d.saida)),
         ('E', 2, d.retorno_intervalo),
         ('S', 2, case when d.saida_intervalo is not null then d.saida end)
       ) m(sentido, turno, hora)
       where not coalesce(d.folga, true) and d.entrada is not null and m.hora is not null
    ),
    bat as (
      select b.*, (b.data_hora at time zone v_tz) as local
        from fn_batidas_periodo(p_ini, p_fim, p_colaborador) b
       where b.colaborador_id in (select id from colab)
         and b.status = 'valida'   -- desconsideradas não aparecem na consulta (ficam no Tratamento de Batidas)
    ),
    linhas as (
      -- Batidas
      select c.nome, b.local as ordem,
             fn_batida_json(b, m.descricao) || jsonb_build_object(
               'tipo', 'batida',
               'colaborador', c.nome, 'matricula', c.matricula, 'departamento', c.departamento,
               'jornada', d.jornada, 'horario_previsto', d.horario_previsto,
               'previsto', case when pv.flex and p.hora is null then 'Flexível' else to_char(p.hora, 'HH24:MI') end,
               'diferenca_min', p.dif,
               'ausencia', d.ausencia,
               'obs_dia', d.obs_dia,
               'situacao',
                 case when b.status <> 'valida'  then 'desconsiderada'
                      -- Sem controle de ponto (ou antes do início do controle): registrada, mas não apurada
                      when not c.controla_ponto
                        or b.data_referencia < greatest(c.data_admissao, coalesce(c.controle_ponto_inicio, c.data_admissao))
                        then 'nao_controlada'
                      -- Feriado e folga aparecem sempre (mesmo com o turno aberto ou incompleto)
                      when d.jornada_id is not null and d.feriado then 'feriado'
                      when d.jornada_id is not null and d.ausencia is null
                           and (coalesce(d.folga, true) or d.entrada is null) then 'folga'
                      -- Turno só existe com entrada e saída: batida sem o par não é apurada
                      when not par.tem and b.sentido = 'E' and b.data_referencia >= fn_hoje() then 'turno_aberto'
                      when not par.tem           then 'turno_incompleto'
                      when d.jornada_id is null  then 'sem_jornada'
                      when d.ausencia is not null then 'ausencia'
                      -- Intervalo flexível: a saída vale em qualquer horário; o retorno é comparado com a duração
                      when pv.flex and b.sentido = 'S' then 'intervalo_flexivel'
                      when pv.flex and p.hora is null then 'intervalo_flexivel'
                      when pv.flex and p.dif >  d.tol_e then 'intervalo_excedido'
                      when pv.flex and p.dif < -d.tol_e then 'intervalo_reduzido'
                      when p.hora is null        then 'fora_jornada'
                      when p.dif = 0             then 'precisa'
                      when b.sentido = 'E' and p.dif >  d.tol_e then 'atraso'
                      when b.sentido = 'E' and p.dif < -d.tol_e then 'antecipada'
                      when b.sentido = 'E'                       then 'entrada_tolerancia'
                      when p.dif < -d.tol_s                      then 'saida_antecipada'
                      when p.dif >  d.tol_s                      then 'apos_previsto'
                      else 'saida_tolerancia' end) as linha
        from bat b
        join colab c               on c.id = b.colaborador_id
        left join dia d            on d.colaborador_id = b.colaborador_id and d.data = b.data_referencia
        left join motivos_batida m on m.id = b.motivo_id
        left join prev pv          on b.status = 'valida' and pv.colaborador_id = b.colaborador_id
                                  and pv.data = b.data_referencia and pv.sentido = b.sentido and pv.turno = b.turno
        -- par do turno: a saída da entrada (ou a entrada da saída)
        cross join lateral (
          select exists (select 1 from bat o
                          where o.status = 'valida' and o.id <> b.id
                            and o.colaborador_id = b.colaborador_id and o.data_referencia = b.data_referencia
                            and o.turno = b.turno and o.sentido <> b.sentido) as tem
        ) par
        -- Intervalo flexível: retorno previsto = saída real para o intervalo (S1) + a duração do intervalo
        left join lateral (
          select min(date_trunc('minute', o.local))
                 + make_interval(mins => fn_minutos(d.saida_intervalo, d.retorno_intervalo)) as ts
            from bat o
           where pv.flex and b.sentido = 'E' and b.turno = 2
             and o.colaborador_id = b.colaborador_id and o.data_referencia = b.data_referencia
             and o.sentido = 'S' and o.turno = 1
        ) rf on true
        -- horário previsto da marcação e a diferença (em minutos) da batida para ele
        cross join lateral (
          select case when pv.flex then rf.ts::time else pv.hora end as hora,
                 (extract(epoch from date_trunc('minute', b.local)
                                     - case when pv.flex then rf.ts else pv.ts end) / 60)::int as dif
        ) p
      union all
      -- Marcações previstas sem batida válida correspondente
      select c.nome, pv.ts,
             jsonb_build_object(
               'tipo', 'prevista',
               'id', c.id || ':' || pv.data || ':' || pv.sentido || pv.turno,
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', c.departamento,
               'data', pv.data, 'data_referencia', pv.data,
               'jornada', d.jornada, 'horario_previsto', d.horario_previsto,
               'sentido', pv.sentido, 'turno', pv.turno,
               'previsto', case when pv.flex then 'Flexível' else to_char(pv.hora, 'HH24:MI') end,
               'obs_dia', d.obs_dia,
               'situacao', case when (case when pv.flex then pv.ts_saida else pv.ts end) > v_agora then 'pendente'
                                else 'nao_registrada' end)
        from prev pv
        join colab c on c.id = pv.colaborador_id
        join dia d   on d.colaborador_id = pv.colaborador_id and d.data = pv.data
       where not d.feriado and d.ausencia is null
         and not exists (select 1 from bat b
                          where b.status = 'valida' and b.colaborador_id = pv.colaborador_id
                            and b.data_referencia = pv.data and b.sentido = pv.sentido and b.turno = pv.turno)
      union all
      -- Dias de ausência (férias, afastamento…) ou feriado sem batidas: uma linha com a observação
      select c.nome, d.data::timestamp,
             jsonb_build_object(
               'tipo', 'dia',
               'id', c.id || ':' || d.data,
               'colaborador_id', c.id, 'colaborador', c.nome, 'matricula', c.matricula, 'departamento', c.departamento,
               'data', d.data, 'data_referencia', d.data,
               'jornada', d.jornada, 'horario_previsto', d.horario_previsto,
               'ausencia', d.ausencia,
               'obs_dia', d.obs_dia,
               'situacao', case when d.ausencia is not null then 'dia_ausencia' else 'dia_feriado' end)
        from dia d
        join colab c on c.id = d.colaborador_id
       where d.obs_dia is not null
         and not exists (select 1 from bat b
                          where b.status = 'valida' and b.colaborador_id = d.colaborador_id and b.data_referencia = d.data)
    )
    select jsonb_agg(l.linha order by l.nome, l.linha ->> 'colaborador_id', l.linha ->> 'data_referencia', l.ordem)
      from linhas l
  ), '[]'::jsonb);
end $$;

-- Recalcula o banco de horas de quem tem batida com segundos (períodos fechados continuam congelados)
do $$
declare r record;
begin
  for r in
    select colaborador_id, min(data_referencia) as ini, max(data_referencia) as fim
      from batidas
     where data_hora <> date_trunc('minute', data_hora) and data_referencia < fn_hoje()
     group by colaborador_id
  loop
    perform fn_processar_banco_horas(r.ini, r.fim, r.colaborador_id);
  end loop;
end $$;

notify pgrst, 'reload schema';
