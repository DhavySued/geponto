-- =============================================================================
-- 011 · Banco de Horas: Detalhamento (dia a dia, com as batidas) e Resumo
-- Requer: 010. Re-executável.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Detalhamento do Banco de Horas: por colaborador, dia a dia, as batidas, o previsto, o trabalhado,
-- o que entrou no banco (apuração, ajustes e conversões) e o saldo acumulado. Até 92 dias.
-- Os valores do banco vêm dos lançamentos gravados: fecham com o Resumo, inclusive em períodos fechados.
-- -----------------------------------------------------------------------------
create or replace function api_relatorio_banco_horas_detalhe(
  p_token text, p_ini date, p_fim date, p_colaboradores uuid[] default null, p_departamento uuid default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare
  v_ate date := least(p_fim, fn_hoje() - 1);
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

insert into paginas (chave, nome, grupo, ordem) values
  ('relatorio_banco_horas_detalhe', 'Detalhamento de Banco de Horas', 'Relatórios', 87),
  ('relatorio_banco_horas', 'Resumo do Banco de Horas', 'Relatórios', 87)
on conflict (chave) do update set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

-- Quem vê o resumo vê o detalhamento
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_banco_horas_detalhe', pode_visualizar, false from perfil_permissoes where pagina = 'relatorio_banco_horas'
on conflict (perfil_id, pagina) do nothing;

grant execute on function api_relatorio_banco_horas_detalhe(text, date, date, uuid[], uuid) to anon, authenticated;

notify pgrst, 'reload schema';
