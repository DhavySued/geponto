-- =============================================================================
-- GePonto — limpar_dados_demo.sql
-- Remove os dados de exemplo (04_dados_demo.sql) e as jornadas padrão do seed,
-- deixando o sistema pronto para o cadastro real.
-- Mantém: empresa, perfis, permissões, páginas, usuários e feriados.
-- =============================================================================

-- Colaboradores reais que tenham um gestor de exemplo ficam sem gestor
update colaboradores set gestor_id = null
 where observacoes is distinct from '[DEMO]'
   and gestor_id in (select id from colaboradores where observacoes = '[DEMO]');

-- Colaboradores de exemplo. As batidas, o banco de horas, as ausências e o
-- histórico deles são apagados junto (on delete cascade).
delete from colaboradores where observacoes = '[DEMO]';

-- Departamentos e cargos de exemplo que não estejam em uso
delete from departamentos d
 where d.nome in ('Administrativo', 'Comercial', 'Operações', 'Tecnologia')
   and not exists (select 1 from colaboradores c where c.departamento_id = d.id);

delete from cargos g
 where g.nome in ('Analista Administrativo', 'Assistente Comercial', 'Supervisor de Operações',
                  'Operador', 'Desenvolvedor', 'Coordenador Comercial')
   and not exists (select 1 from colaboradores c where c.cargo_id = g.id);

-- Jornadas padrão criadas pelo seed, se não estiverem em uso
delete from jornadas j
 where j.nome in ('Administrativa 44h', 'Comercial 40h')
   and not exists (select 1 from colaboradores c where c.jornada_id = j.id)
   and not exists (select 1 from colaborador_jornadas cj where cj.jornada_id = j.id);

select
  (select count(*) from colaboradores) as colaboradores,
  (select count(*) from jornadas)      as jornadas,
  (select count(*) from batidas)       as batidas,
  (select count(*) from banco_horas)   as lancamentos_banco_horas;
