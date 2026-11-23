-- =============================================================================
-- GePonto: atualização 008
-- • Jornadas e regras de cálculo da empresa (opção "Mostrar em todas as empresas")
-- • Matrícula sugerida pela sequência; empresa do colaborador = a empresa em que se está
-- • Competência fechada por empresa
-- • Situação da admissão alterada só no cadastro do colaborador
-- • Menus separados de Ocorrências e Afastamentos; cadastro de tipos de licença e de motivos de batida
--   (não exclui o que já foi lançado)
-- • Inclusão de batidas em lote com variação aleatória
-- • Intervalo pré-assinalado (Portaria 671) na jornada
-- • Arquivo AFD (Portaria 671)
-- • Configuração do dashboard por empresa
-- • Relatórios de adicional noturno e de folgas (até 31 dias)
-- Requer: atualização 007. Pode ser executado mais de uma vez.
-- =============================================================================

-- Jornadas e regras por empresa (as que já existiam continuam valendo para todas)
alter table jornadas       add column if not exists empresa_id uuid references empresas(id) on delete set null;
alter table perfis_eventos add column if not exists empresa_id uuid references empresas(id) on delete set null;
do $$ begin
  if not exists (select 1 from information_schema.columns where table_name = 'jornadas' and column_name = 'todas_empresas') then
    alter table jornadas add column todas_empresas boolean not null default false;
    update jornadas set todas_empresas = true;
  end if;
  if not exists (select 1 from information_schema.columns where table_name = 'perfis_eventos' and column_name = 'todas_empresas') then
    alter table perfis_eventos add column todas_empresas boolean not null default false;
    update perfis_eventos set todas_empresas = true;
  end if;
end $$;
alter table jornadas add column if not exists intervalo_pre_assinalado boolean not null default false;

-- Fechamento por empresa (os antigos, sem empresa, valem para todas)
alter table fechamentos add column if not exists empresa_id uuid references empresas(id) on delete cascade;
create index if not exists ix_fechamentos_empresa on fechamentos (empresa_id, data_inicio, data_fim);

-- Dashboard por empresa
alter table empresas add column if not exists dashboard jsonb not null default '{}'::jsonb;

-- Tipos de licença (afastamentos)
create table if not exists tipos_licenca (
  id          uuid primary key default gen_random_uuid(),
  descricao   text not null unique,
  abona       boolean not null default true,
  ativo       boolean not null default true,
  created_at  timestamptz not null default now()
);
alter table tipos_licenca enable row level security;
alter table ausencias add column if not exists licenca_id uuid references tipos_licenca(id);
revoke all on tipos_licenca from anon, authenticated;
drop trigger if exists trg_auditoria on tipos_licenca;
create trigger trg_auditoria after insert or update or delete on tipos_licenca for each row execute function fn_auditar();

-- Assinaturas que mudaram
drop function if exists fn_periodo_fechado(date);
drop function if exists fn_fechado_ate();
drop function if exists api_ocorrencias_listar(text, date, date, uuid, uuid, text, uuid[]);

-- [01_schema]
-- A jornada / regra aparece na empresa da sessão?
create or replace function fn_da_empresa(p_empresa uuid, p_todas boolean)
returns boolean language sql stable set search_path = public as $$
  select coalesce(p_todas, false) or p_empresa is null or fn_empresa_atual() is null or p_empresa = fn_empresa_atual();
$$;

-- [02_functions]
-- Empresa cujo fechamento vale para o colaborador (sem colaborador: a empresa da sessão)
create or replace function fn_empresa_fechamento(p_colaborador uuid)
returns uuid language sql stable set search_path = public as $$
  select coalesce((select empresa_id from colaboradores where id = p_colaborador), fn_empresa_atual());
$$;

-- [02_functions]
-- O fechamento vale para a empresa? (fechamentos antigos, sem empresa, valem para todas)
create or replace function fn_fechamento_da_empresa(p_fechamento_empresa uuid, p_colaborador uuid)
returns boolean language sql stable set search_path = public as $$
  select p_fechamento_empresa is null
      or p_fechamento_empresa = fn_empresa_fechamento(p_colaborador)
      or fn_empresa_fechamento(p_colaborador) is null;
$$;

-- [02_functions]
-- Dia dentro de um período fechado da empresa do colaborador?
drop function if exists fn_periodo_fechado(date);
create or replace function fn_periodo_fechado(p_data date, p_colaborador uuid default null)
returns boolean language sql stable set search_path = public as $$
  select exists (select 1 from fechamentos f
                  where p_data between f.data_inicio and f.data_fim
                    and fn_fechamento_da_empresa(f.empresa_id, p_colaborador));
$$;

-- [02_functions]
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
            else f.saldo end,
       f.pre_assinalado
  from fin f;
$$;

-- [02_functions]
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

-- [02_functions]
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
    if tg_op <> 'INSERT' and fn_periodo_fechado(old.data_referencia, old.colaborador_id)
       or tg_op <> 'DELETE' and fn_periodo_fechado(new.data_referencia, new.colaborador_id) then
      raise exception 'O dia % está em um período fechado. Reabra o período para alterar as batidas.',
        to_char(coalesce(new.data_referencia, old.data_referencia), 'DD/MM/YYYY');
    end if;
  elsif tg_table_name = 'ausencias' then
    if tg_op <> 'INSERT' then v_ini := old.data_inicio; v_fim := old.data_fim; end if;
    if tg_op <> 'DELETE' then
      v_ini := least(v_ini, new.data_inicio);
      v_fim := greatest(v_fim, new.data_fim);
    end if;
    if exists (select 1 from fechamentos f where f.data_inicio <= v_fim and f.data_fim >= v_ini
                  and fn_fechamento_da_empresa(f.empresa_id, coalesce(new.colaborador_id, old.colaborador_id))) then
      raise exception 'O período da ocorrência alcança um período fechado. Reabra o período para alterá-la.';
    end if;
  elsif tg_table_name = 'banco_horas' then
    -- Os automáticos já pulam os dias fechados em fn_processar_banco_horas
    if (case when tg_op = 'DELETE' then old.origem else new.origem end) = 'automatico' then
      return coalesce(new, old);
    end if;
    if tg_op <> 'INSERT' and fn_periodo_fechado(old.data, old.colaborador_id)
       or tg_op <> 'DELETE' and fn_periodo_fechado(new.data, new.colaborador_id) then
      raise exception 'O dia % está em um período fechado.', to_char(coalesce(new.data, old.data), 'DD/MM/YYYY');
    end if;
  elsif tg_table_name in ('escalas', 'justificativas', 'faltas_folha') then
    if tg_op <> 'INSERT' and fn_periodo_fechado(old.data, old.colaborador_id)
       or tg_op <> 'DELETE' and fn_periodo_fechado(new.data, new.colaborador_id) then
      raise exception 'O dia % está em um período fechado. Reabra o período para alterar %.',
        to_char(coalesce(new.data, old.data), 'DD/MM/YYYY'),
        case tg_table_name when 'escalas' then 'a escala' when 'faltas_folha' then 'a falta' else 'a justificativa' end;
    end if;
  end if;
  return coalesce(new, old);
end $$;

-- [05_api_cadastros]
-- -----------------------------------------------------------------------------
-- Listas auxiliares para os formulários
-- -----------------------------------------------------------------------------
create or replace function api_cadastros_auxiliares(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'colaboradores');
  return jsonb_build_object(
    'departamentos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from departamentos where ativo), '[]'::jsonb),
    'cargos',        coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from cargos where ativo), '[]'::jsonb),
    'jornadas',      coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from jornadas where ativo and fn_da_empresa(empresa_id, todas_empresas)), '[]'::jsonb),
    'perfis_eventos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'padrao', padrao)
                                                 order by padrao desc, nome)
                                  from perfis_eventos where ativo and (padrao or fn_da_empresa(empresa_id, todas_empresas))), '[]'::jsonb),
    -- Próxima matrícula: a maior numérica + 1, com o mesmo número de dígitos
    'proxima_matricula', (select lpad((coalesce(max(matricula::numeric), 0) + 1)::text,
                                      greatest(coalesce(max(length(matricula)), 1), length((coalesce(max(matricula::numeric), 0) + 1)::text)), '0')
                            from colaboradores where matricula ~ '^[0-9]{1,15}$'),
    'gestores',      coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from colaboradores where situacao <> 'desligado'), '[]'::jsonb)
  );
end $$;

-- [05_api_cadastros]
-- -----------------------------------------------------------------------------
-- Situação do Colaborador
-- -----------------------------------------------------------------------------
-- Último dia de período fechado (as situações até ele ficam travadas)
drop function if exists fn_fechado_ate();
create or replace function fn_fechado_ate(p_colaborador uuid default null)
returns date language sql stable set search_path = public as $$
  select max(data_fim) from fechamentos f where fn_fechamento_da_empresa(f.empresa_id, p_colaborador);
$$;

-- [05_api_cadastros]
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
           'fechado', s.data_inicio <= coalesce(fn_fechado_ate(s.colaborador_id), '-infinity'::date),
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

-- [05_api_cadastros]
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
                            from jornadas where ativo and fn_da_empresa(empresa_id, todas_empresas)), '[]'::jsonb),
    'perfis_eventos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome, 'padrao', padrao)
                                                 order by padrao desc, nome)
                                  from perfis_eventos where ativo and (padrao or fn_da_empresa(empresa_id, todas_empresas))), '[]'::jsonb));
end $$;

-- [05_api_cadastros]
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
  v_fechado date;
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
  if fn_txt(d, 'situacao') = 'desligado' then
    raise exception 'O desligamento não é uma situação: informe a data de desligamento no cadastro do colaborador.';
  end if;
  v_data := fn_txt(d, 'data_inicio')::date;
  v_fechado := fn_fechado_ate(v_colab);

  select data_admissao into v_adm from colaboradores where id = v_colab;
  select min(data_inicio) into v_primeira from colaborador_situacoes where colaborador_id = v_colab;
  -- A situação da admissão é mantida pelo cadastro do colaborador
  if v_id is not null and v_old.data_inicio = v_primeira then
    raise exception 'Esta é a situação da admissão. Para alterá-la, altere no cadastro do colaborador (aba Profissional, dados da admissão).';
  end if;
  if v_data < v_adm then
    raise exception 'A situação não pode começar antes da admissão (%).', to_char(v_adm, 'DD/MM/YYYY');
  end if;
  -- A data de uma situação lançada não muda: para outra data, lance uma nova situação (e exclua esta)
  if v_id is not null and v_data <> v_old.data_inicio then
    raise exception 'A data da situação não pode ser alterada. Lance uma nova situação na data certa e exclua esta.';
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

-- [05_api_cadastros]
create or replace function api_colaborador_situacao_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_old colaborador_situacoes%rowtype;
  v_fechado date;
begin
  perform fn_auth(p_token, 'situacoes_colaborador', true);
  select * into v_old from colaborador_situacoes where id = p_id;
  if not found then raise exception 'Situação não encontrada.'; end if;
  if not fn_visivel(v_old.colaborador_id) then
    raise exception 'Colaborador fora da sua abrangência de acesso.' using errcode = '42501';
  end if;
  v_fechado := fn_fechado_ate(v_old.colaborador_id);
  if v_old.data_inicio = (select min(data_inicio) from colaborador_situacoes where colaborador_id = v_old.colaborador_id) then
    raise exception 'A situação da admissão não pode ser excluída. Para alterá-la, altere no cadastro do colaborador.';
  end if;
  if v_fechado is not null and v_old.data_inicio <= v_fechado then
    raise exception 'O período até % está fechado. Reabra o fechamento para excluir esta situação.', to_char(v_fechado, 'DD/MM/YYYY');
  end if;
  delete from colaborador_situacoes where id = p_id;
  perform fn_colaborador_situacao_aplicar(v_old.colaborador_id);
  perform fn_processar_banco_horas(v_old.data_inicio, fn_hoje() - 1, v_old.colaborador_id);
  return jsonb_build_object('ok', true);
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

-- [05_api_cadastros]
-- -----------------------------------------------------------------------------
-- Jornadas de trabalho
-- -----------------------------------------------------------------------------
create or replace function api_jornadas_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'jornadas');
  return coalesce((
    select jsonb_agg(
             to_jsonb(j) - 'created_at' - 'updated_at'
             || jsonb_build_object(
                  'colaboradores', (select count(*) from colaboradores c
                                     where c.jornada_id = j.id and c.situacao <> 'desligado'),
                  -- Escala: média semanal (carga do ciclo × 7 / dias do ciclo)
                  'minutos_semana', coalesce(round((
                     select sum(fn_minutos(jd.entrada, jd.saida)
                                - coalesce(fn_minutos(jd.saida_intervalo, jd.retorno_intervalo), 0))
                       from jornada_dias jd where jd.jornada_id = j.id and not jd.folga)
                     * case when j.tipo = 'escala' then 7.0 / j.ciclo_dias else 1 end), 0),
                  'dias', coalesce((
                     select jsonb_agg(jsonb_build_object(
                              'dia_semana', jd.dia_semana, 'folga', jd.folga,
                              'entrada', to_char(jd.entrada, 'HH24:MI'),
                              'saida_intervalo', to_char(jd.saida_intervalo, 'HH24:MI'),
                              'retorno_intervalo', to_char(jd.retorno_intervalo, 'HH24:MI'),
                              'saida', to_char(jd.saida, 'HH24:MI'))
                            order by jd.dia_semana)
                       from jornada_dias jd where jd.jornada_id = j.id), '[]'::jsonb))
             order by j.ativo desc, j.nome)
      from jornadas j
     where fn_da_empresa(j.empresa_id, j.todas_empresas)
  ), '[]'::jsonb);
end $$;

-- [05_api_cadastros]
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
    insert into jornadas (nome, descricao, ativo, tipo, ciclo_dias, data_base, intervalo_flexivel,
                          empresa_id, todas_empresas, intervalo_pre_assinalado)
    values (fn_txt(d, 'nome'), fn_txt(d, 'descricao'),
            coalesce((d ->> 'ativo')::boolean, true),
            v_tipo, case when v_tipo = 'escala' then v_ciclo end,
            case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
            coalesce((d ->> 'intervalo_flexivel')::boolean, false),
            fn_empresa_atual(), coalesce((d ->> 'todas_empresas')::boolean, false),
            coalesce((d ->> 'intervalo_pre_assinalado')::boolean, false))
    returning id into v_id;
  else
    update jornadas set
      nome = fn_txt(d, 'nome'), descricao = fn_txt(d, 'descricao'),
      ativo = coalesce((d ->> 'ativo')::boolean, true),
      tipo = v_tipo,
      ciclo_dias = case when v_tipo = 'escala' then v_ciclo end,
      data_base = case when v_tipo = 'escala' then fn_txt(d, 'data_base')::date end,
      intervalo_flexivel = coalesce((d ->> 'intervalo_flexivel')::boolean, false),
      todas_empresas = coalesce((d ->> 'todas_empresas')::boolean, todas_empresas),
      intervalo_pre_assinalado = coalesce((d ->> 'intervalo_pre_assinalado')::boolean, false),
      empresa_id = coalesce(empresa_id, fn_empresa_atual())
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

-- [05_api_cadastros]
-- -----------------------------------------------------------------------------
-- Perfis de eventos: tolerâncias, percentual de HE por dia (domingo … sábado, feriado e folga),
-- limite de HE, adicional noturno e banco de horas. Vinculados ao colaborador.
-- -----------------------------------------------------------------------------
create or replace function api_perfis_eventos_listar(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'perfis_eventos');
  return coalesce((
    select jsonb_agg(
             to_jsonb(p) - 'created_at' - 'updated_at'
             || jsonb_build_object(
                  'noturno_inicio', to_char(p.noturno_inicio, 'HH24:MI'),
                  'noturno_fim', to_char(p.noturno_fim, 'HH24:MI'),
                  'percentual_noturno', p.percentual_noturno::float8,
                  'he', coalesce((select jsonb_agg(jsonb_build_object('dia', h.dia, 'percentual', h.percentual::float8)
                                                   order by h.dia)
                                    from perfil_evento_he h where h.perfil_id = p.id), '[]'::jsonb),
                  'colaboradores', (select count(*) from colaboradores c
                                     where c.perfil_evento_id = p.id and c.situacao <> 'desligado'))
             order by p.ativo desc, p.padrao desc, p.nome)
      from perfis_eventos p
     where p.padrao or fn_da_empresa(p.empresa_id, p.todas_empresas)
  ), '[]'::jsonb);
end $$;

-- [05_api_cadastros]
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

-- [07_api_tratamento]
-- -----------------------------------------------------------------------------
-- Leitura
-- -----------------------------------------------------------------------------
create or replace function api_tratamento_auxiliares(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_usuario uuid := fn_auth_tratamento_leitura(p_token);
begin
  return jsonb_build_object(
    'pode_editar', fn_pode(v_usuario, 'lancamento_manual', true),
    'estabelecimentos', (select jsonb_agg(jsonb_build_object('id', id::text,
                                  'nome', coalesce(nome_fantasia, razao_social)))
                           from empresas where id = coalesce(fn_empresa_atual(), fn_empresa_padrao())),
    'colaboradores', coalesce((select jsonb_agg(jsonb_build_object(
                         'id', c.id, 'nome', c.nome, 'matricula', c.matricula, 'situacao', c.situacao,
                         'departamento_id', c.departamento_id, 'cargo_id', c.cargo_id, 'jornada_id', c.jornada_id)
                         order by c.nome) from colaboradores c where fn_visivel(c.id)), '[]'::jsonb),
    'departamentos', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from departamentos), '[]'::jsonb),
    'cargos',        coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from cargos), '[]'::jsonb),
    'jornadas',      coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome) order by nome)
                                 from jornadas where fn_da_empresa(empresa_id, todas_empresas)), '[]'::jsonb),
    'motivos',       coalesce((select jsonb_agg(jsonb_build_object('id', id, 'descricao', descricao,
                                                                   'aplicacao', aplicacao) order by descricao)
                                 from motivos_batida where ativo), '[]'::jsonb));
end $$;

-- [07_api_tratamento]
-- Inclusão de batidas em lote: para cada colaborador e dia do período sem nenhuma batida, inclui as
-- marcações previstas da jornada (ou da escala do dia) com uma variação aleatória de até X minutos,
-- para que as batidas não fiquem idênticas ao horário previsto. Pula folgas, feriados, dias com
-- ocorrência/afastamento de dia inteiro, períodos fechados e horários futuros.
-- p_dados: { colaboradores: [uuid], data_inicio, data_fim, variacao_min, motivo_id, observacao?, simular? }
create or replace function api_batidas_lote(p_token text, p_dados jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  d        jsonb := p_dados;
  v_ini    date := fn_txt(d, 'data_inicio')::date;
  v_fim    date := fn_txt(d, 'data_fim')::date;
  v_var    integer := coalesce(fn_txt(d, 'variacao_min')::integer, 0);
  v_motivo uuid := nullif(d ->> 'motivo_id', '')::uuid;
  v_simular boolean := coalesce((d ->> 'simular')::boolean, false);
  v_obs    text := nullif(trim(coalesce(d ->> 'observacao', '')), '');
  v_txt    text;
  v_colabs uuid[];
  c        uuid;
  v_dia    date;
  jd       record;
  m        record;
  v_dh     timestamptz;
  v_ant    timestamptz;
  v_bat    batidas%rowtype;
  v_dias   integer := 0;
  v_qtd    integer := 0;
  v_pulos  jsonb := jsonb_build_object('com_batidas', 0, 'sem_previsao', 0, 'feriado', 0, 'ausencia', 0, 'fechado', 0, 'futuro', 0);
  v_motivo_pulo text;
begin
  perform fn_auth(p_token, 'lancamento_manual', true);
  if v_ini is null or v_fim is null or v_fim < v_ini then raise exception 'Informe um período válido.'; end if;
  if v_fim - v_ini > 30 then raise exception 'Selecione um período de até 31 dias.'; end if;
  if v_fim >= fn_hoje() then v_fim := fn_hoje(); end if;
  if v_var not between 0 and 30 then raise exception 'A variação deve ficar entre 0 e 30 minutos.'; end if;
  v_txt := fn_motivo_valido(v_motivo, 'inclusao');
  select array_agg(distinct x::uuid) into v_colabs
    from jsonb_array_elements_text(case when jsonb_typeof(d -> 'colaboradores') = 'array' then d -> 'colaboradores' else '[]'::jsonb end) x;
  if coalesce(array_length(v_colabs, 1), 0) = 0 then raise exception 'Selecione ao menos um colaborador.'; end if;
  foreach c in array v_colabs loop perform fn_exigir_visivel(c); end loop;

  foreach c in array v_colabs loop
    for v_dia in select g::date from generate_series(v_ini, v_fim, interval '1 day') g loop
      v_motivo_pulo := null;
      select * into jd from fn_jornada_dia(c, v_dia);
      if exists (select 1 from batidas b where b.colaborador_id = c and b.data_referencia = v_dia and b.status = 'valida') then
        v_motivo_pulo := 'com_batidas';
      elsif not found or coalesce(jd.folga, true) or jd.entrada is null or jd.saida is null then
        v_motivo_pulo := 'sem_previsao';
      elsif jd.escala is distinct from 'trabalho' and exists (select 1 from feriados f where f.data = v_dia) then
        v_motivo_pulo := 'feriado';
      elsif exists (select 1 from ausencias a where a.colaborador_id = c and v_dia between a.data_inicio and a.data_fim
                       and a.minutos is null) then
        v_motivo_pulo := 'ausencia';
      elsif fn_periodo_fechado(v_dia, c) then
        v_motivo_pulo := 'fechado';
      elsif fn_data_hora_local(v_dia + case when jd.saida <= jd.entrada then 1 else 0 end, to_char(jd.saida, 'HH24:MI'))
            + make_interval(mins => v_var) > now()
            or exists (select 1 from colaboradores x where x.id = c
                         and (v_dia < fn_inicio_controle(x) or (x.data_desligamento is not null and v_dia > x.data_desligamento))) then
        v_motivo_pulo := 'futuro';
      end if;
      if v_motivo_pulo is not null then
        v_pulos := jsonb_set(v_pulos, array[v_motivo_pulo], to_jsonb((v_pulos ->> v_motivo_pulo)::int + 1));
        continue;
      end if;

      v_dias := v_dias + 1;
      v_ant := null;
      for m in
        select v.o, v.s, v.t, v.h
          from (values (1, 'E', 1, jd.entrada),
                       (2, 'S', 1, coalesce(jd.saida_intervalo, jd.saida)),
                       (3, 'E', 2, jd.retorno_intervalo),
                       (4, 'S', 2, case when jd.saida_intervalo is not null then jd.saida end)) v(o, s, t, h)
         where v.h is not null
         order by v.o
      loop
        v_dh := fn_data_hora_local(v_dia + case when m.h < jd.entrada then 1 else 0 end, to_char(m.h, 'HH24:MI'))
                + make_interval(mins => round((random() * 2 - 1) * v_var)::int);
        -- Mantém a ordem das marcações (a variação não inverte saída e retorno)
        if v_ant is not null and v_dh <= v_ant then v_dh := v_ant + interval '1 minute'; end if;
        v_ant := v_dh;
        v_qtd := v_qtd + 1;
        if not v_simular then
          insert into batidas (colaborador_id, data_hora, data_referencia, origem, justificativa,
                               motivo_id, observacao, usuario_id)
          values (c, v_dh, v_dia, 'manual', v_txt || ' — Inclusão em lote' || coalesce(' — ' || v_obs, ''),
                  v_motivo, coalesce(v_obs, 'Inclusão em lote'), nullif(current_setting('app.usuario_id', true), '')::uuid)
          returning * into v_bat;
          perform fn_batida_auditar(v_bat, 'inclusao', null, v_dh, v_motivo, coalesce(v_obs, 'Inclusão em lote'));
        end if;
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('dias', v_dias, 'batidas', v_qtd, 'pulados', v_pulos, 'simulado', v_simular);
end $$;

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
create or replace function api_ocorrencia_excluir(p_token text, p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, coalesce((select fn_ausencia_grupo(tipo) from ausencias where id = p_id), 'ocorrencias'), true);
  delete from ausencias where id = p_id and fn_visivel(colaborador_id);
  if not found then raise exception 'Ocorrência não encontrada.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
-- Quantas vezes o motivo foi usado (batidas, ajustes e solicitações)
create or replace function fn_motivo_em_uso(p_id uuid)
returns integer language sql stable set search_path = public as $$
  select ((select count(*) from batidas where motivo_id = p_id)
        + (select count(*) from batida_ajustes where motivo_id = p_id)
        + (select count(*) from solicitacoes where motivo_id = p_id))::int;
$$;

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
-- Texto só com caracteres imprimíveis ASCII (sem acentos), cortado/completado à direita com espaços
create or replace function fn_afd_txt(p text, p_tam integer)
returns text language sql immutable as $$
  select rpad(left(regexp_replace(
           translate(coalesce(p, ''), 'áàâãäéèêëíìîïóòôõöúùûüçñÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇÑºª',
                                      'aaaaaeeeeiiiiooooouuuucnAAAAAEEEEIIIIOOOOOUUUUCNoa'),
           '[^ -~]', ' ', 'g'), p_tam), p_tam, ' ');
$$;

-- [08_api_fortes]
-- Número à esquerda com zeros
create or replace function fn_afd_num(p text, p_tam integer)
returns text language sql immutable as $$
  select lpad(right(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'), p_tam), p_tam, '0');
$$;

-- [08_api_fortes]
-- Data e hora no formato AAAA-MM-ddThh:mm:ss-ZZZZ, no fuso do sistema
create or replace function fn_afd_dh(p timestamptz, p_segundos boolean default false)
returns text language sql stable set search_path = public as $$
  select to_char(p at time zone fn_fuso(), case when p_segundos then 'YYYY-MM-DD"T"HH24:MI:SS' else 'YYYY-MM-DD"T"HH24:MI:"00"' end)
         || case when o < interval '0' then '-' else '+' end
         || to_char(justify_hours(abs(extract(epoch from o))::int * interval '1 second'), 'HH24MI')
    from (select (p at time zone fn_fuso()) - (p at time zone 'UTC') as o) x;
$$;

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [08_api_fortes]
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

-- [10_api_justificativas]
-- p_situacao: null (todas) · 'pendentes' (sem justificativa) · 'justificadas' · 'abonadas'
drop function if exists api_justificativas_listar(text, date, date, uuid, uuid, text);
create or replace function api_justificativas_listar(
  p_token text, p_ini date, p_fim date,
  p_colaborador uuid default null, p_departamento uuid default null, p_situacao text default null, p_colaboradores uuid[] default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_fim    date;
  v_itens  jsonb;
begin
  perform fn_auth(p_token, 'justificativas');
  if p_ini is null or p_fim is null or p_fim < p_ini then raise exception 'Informe um período válido.'; end if;
  if p_fim - p_ini > 92 then raise exception 'Selecione um período de até 3 meses.'; end if;
  v_fim := least(p_fim, fn_hoje());

  drop table if exists pg_temp._jus_col;
  create temp table _jus_col on commit drop as
    select c.id, c.nome, c.matricula, d.nome as departamento
      from colaboradores c
      left join departamentos d on d.id = c.departamento_id
     where fn_filtro_colaborador(c.id, p_colaborador, p_colaboradores)
       and (p_departamento is null or c.departamento_id = p_departamento)
       and fn_visivel(c.id);

  drop table if exists pg_temp._jus_ap;
  create temp table _jus_ap on commit drop as
    select a.colaborador_id, a.data, a.previsto_min, a.primeira_batida, a.fechado,
           a.atraso_bruto_min, a.saida_antecipada_bruta_min, a.falta_bruta
      from fn_apuracao(p_ini, greatest(v_fim, p_ini), p_colaborador) a
     where a.colaborador_id in (select id from _jus_col)
       and a.data <= v_fim;

  with ev as (
    select colaborador_id, data, 'atraso'::text as tipo, atraso_bruto_min as minutos, primeira_batida as hora, fechado
      from _jus_ap where atraso_bruto_min > 0
    union all
    select colaborador_id, data, 'saida_antecipada', saida_antecipada_bruta_min, null::time, fechado
      from _jus_ap where saida_antecipada_bruta_min > 0
    union all
    select colaborador_id, data, 'falta', previsto_min, null::time, fechado
      from _jus_ap where falta_bruta
  ),
  jus as (
    select j.* from justificativas j
     where j.data between p_ini and p_fim and j.colaborador_id in (select id from _jus_col)
  ),
  x as (
    select coalesce(ev.colaborador_id, j.colaborador_id) as colaborador_id,
           coalesce(ev.data, j.data) as data,
           coalesce(ev.tipo, j.tipo) as tipo,
           ev.minutos, ev.hora,
           ev.tipo is not null as ocorreu,
           coalesce(ev.fechado, fn_periodo_fechado(j.data, j.colaborador_id)) as fechado,
           j.id as justificativa_id, j.motivo, j.abona, j.minutos as minutos_abono, j.observacao,
           j.usuario_id, j.updated_at
      from ev
      full join jus j on j.colaborador_id = ev.colaborador_id and j.data = ev.data and j.tipo = ev.tipo
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'colaborador_id', x.colaborador_id, 'colaborador', c.nome, 'matricula', c.matricula,
           'departamento', c.departamento, 'data', x.data, 'tipo', x.tipo,
           'minutos', coalesce(x.minutos, 0), 'hora', to_char(x.hora, 'HH24:MI'),
           'ocorreu', x.ocorreu, 'fechado', x.fechado,
           'justificativa', case when x.justificativa_id is null then null else jsonb_build_object(
              'id', x.justificativa_id, 'motivo', x.motivo, 'abona', x.abona, 'minutos', x.minutos_abono,
              'observacao', x.observacao, 'usuario', u.nome, 'atualizado_em', x.updated_at,
              'minutos_abonados', case when x.abona and x.ocorreu
                                       then least(coalesce(x.minutos_abono, x.minutos), x.minutos) else 0 end) end)
         order by x.data desc, c.nome, x.tipo), '[]'::jsonb)
    into v_itens
    from x
    join _jus_col c      on c.id = x.colaborador_id
    left join usuarios u on u.id = x.usuario_id
   where p_situacao is null
      or (p_situacao = 'pendentes'    and x.justificativa_id is null)
      or (p_situacao = 'justificadas' and x.justificativa_id is not null)
      or (p_situacao = 'abonadas'     and x.abona);

  return jsonb_build_object(
    'itens', v_itens,
    -- Motivos já usados (os mais frequentes primeiro), como sugestão na tela
    'motivos', coalesce((
      select jsonb_agg(m.motivo order by m.qtd desc, m.motivo)
        from (select motivo, count(*) as qtd from justificativas group by motivo
               order by count(*) desc, motivo limit 30) m), '[]'::jsonb));
end $$;

-- [12_api_empresas]
-- Dashboard: indicadores e gráficos que aparecem na empresa da sessão
create or replace function api_dashboard_config(p_token text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token);
  return coalesce((select dashboard from empresas where id = fn_empresa_atual()), '{}'::jsonb);
end $$;

-- [12_api_empresas]
create or replace function api_dashboard_config_salvar(p_token text, p_config jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform fn_auth(p_token, 'config_dashboard', true);
  if jsonb_typeof(p_config) <> 'object' then raise exception 'Configuração inválida.'; end if;
  update empresas
     set dashboard = (select coalesce(jsonb_object_agg(k, v), '{}'::jsonb)
                        from jsonb_each(p_config) x(k, v) where jsonb_typeof(v) = 'boolean')
   where id = fn_empresa_atual();
  if not found then raise exception 'Entre em uma empresa para configurar o dashboard.'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- Páginas novas e permissões
insert into paginas (chave, nome, grupo, ordem) values
  ('ocorrencias',        'Ocorrências',               'Movimentos', 72),
  ('afastamentos',       'Afastamentos',              'Movimentos', 72),
  ('afd',                'Arquivo AFD',               'Movimentos', 79),
  ('tipos_licenca',      'Tipos de Licença',          'Cadastros',  46),
  ('motivos_batida',     'Motivos de Batida',         'Cadastros',  47),
  ('relatorio_noturno',  'Relatório de Adicional Noturno', 'Relatórios', 89),
  ('relatorio_folgas',   'Relatório de Folgas',       'Relatórios', 89),
  ('config_dashboard',   'Dashboard',                 'Configurações', 93)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

-- Afastamentos e os cadastros de tipos de licença e motivos: quem cuida das ocorrências / do tratamento
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'afastamentos', pode_visualizar, pode_editar from perfil_permissoes where pagina = 'ocorrencias'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'tipos_licenca', pode_visualizar, pode_editar from perfil_permissoes where pagina = 'ocorrencias'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'motivos_batida', pode_visualizar, pode_editar from perfil_permissoes where pagina = 'lancamento_manual'
on conflict (perfil_id, pagina) do nothing;

insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'afd', pode_visualizar, false from perfil_permissoes where pagina = 'fechamento'
on conflict (perfil_id, pagina) do nothing;
-- Configuração do dashboard: quem cuida das configurações do registro de ponto
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'config_dashboard', pode_visualizar, pode_editar from perfil_permissoes where pagina = 'configuracoes'
on conflict (perfil_id, pagina) do nothing;
-- Relatórios de adicional noturno e de folgas: quem vê os totais do período
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_noturno', pode_visualizar, false from perfil_permissoes where pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_folgas', pode_visualizar, false from perfil_permissoes where pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;

insert into tipos_licenca (descricao, abona) values
  ('Licença maternidade', true),
  ('Licença paternidade', true),
  ('Auxílio-doença (INSS)', true),
  ('Acidente de trabalho', true),
  ('Licença casamento (gala)', true),
  ('Licença nojo (falecimento)', true),
  ('Serviço militar', true),
  ('Licença não remunerada', false)
on conflict (descricao) do nothing;


revoke execute on function fn_fechado_ate(uuid)                            from public, anon, authenticated;
grant execute on function api_batidas_lote(text, jsonb)          to anon, authenticated;
revoke execute on function fn_motivo_em_uso(uuid)                             from public, anon, authenticated;
revoke execute on function fn_crc16_kermit(text)                              from public, anon, authenticated;
revoke execute on function fn_afd_dh(timestamptz, boolean)                    from public, anon, authenticated;
revoke execute on function fn_afd_txt(text, integer)                          from public, anon, authenticated;
revoke execute on function fn_afd_num(text, integer)                          from public, anon, authenticated;
grant execute on function api_ocorrencias_listar(text, date, date, uuid, uuid, text, uuid[], text) to anon, authenticated;
grant execute on function api_tipos_licenca_listar(text, boolean)                     to anon, authenticated;
grant execute on function api_tipo_licenca_salvar(text, jsonb)                        to anon, authenticated;
grant execute on function api_tipo_licenca_excluir(text, uuid)                        to anon, authenticated;
grant execute on function api_motivos_batida_listar(text)                             to anon, authenticated;
grant execute on function api_motivo_batida_salvar(text, jsonb)                       to anon, authenticated;
grant execute on function api_motivo_batida_excluir(text, uuid)                       to anon, authenticated;
grant execute on function api_afd_gerar(text, date, date, jsonb)                       to anon, authenticated;
grant execute on function api_relatorio_noturno(text, date, date, uuid[], uuid)         to anon, authenticated;
grant execute on function api_relatorio_folgas(text, date, date, uuid[], uuid)          to anon, authenticated;
grant execute on function api_dashboard_config(text)                to anon, authenticated;
grant execute on function api_dashboard_config_salvar(text, jsonb)  to anon, authenticated;

notify pgrst, 'reload schema';
