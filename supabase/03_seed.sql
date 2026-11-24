-- =============================================================================
-- GePonto — 03_seed.sql — Dados iniciais (idempotente)
-- O usuário administrador é criado em 99_admin.local.sql (fora do Git).
-- =============================================================================

insert into empresa (id, razao_social, nome_fantasia, fuso_horario)
values (1, 'GePonto Ltda', 'GePonto', 'America/Sao_Paulo')
on conflict (id) do nothing;

-- Primeira empresa (cadastro de empresas) a partir dos dados gerais
insert into empresas (razao_social, nome_fantasia, cnpj, logradouro)
select razao_social, nome_fantasia, nullif(trim(cnpj), ''), endereco from empresa
 where id = 1 and not exists (select 1 from empresas);
update colaboradores set empresa_id = fn_empresa_padrao() where empresa_id is null;

-- Páginas do ERP (usadas pelo menu e pelo controle de permissões)
insert into paginas (chave, nome, grupo, ordem) values
  ('meu_ponto',          'Meu Ponto',                 'Meu Ponto',   5),
  ('dashboard',          'Dashboard',                 'Dashboard',  10),
  ('colaboradores',      'Colaboradores',             'Cadastros',  20),
  ('situacoes_colaborador', 'Situação do Colaborador', 'Cadastros',  22),
  ('usuarios',           'Usuários & Permissões',     'Cadastros',  30),
  ('jornadas',           'Jornadas',                  'Cadastros',  40),
  ('perfis_eventos',     'Regras de Cálculo',         'Cadastros',  42),
  ('feriados',           'Feriados',                  'Cadastros',  45),
  ('batidas',            'Acompanhamento de Batidas', 'Movimentos', 50),
  ('banco_horas_conversao', 'Conversão do Banco de Horas', 'Movimentos', 62),
  ('banco_horas',        'Banco de Horas',            'Movimentos', 60),
  ('consulta_batidas',   'Consulta de Batidas',       'Movimentos', 65),
  ('lancamento_manual',  'Tratamento de Batidas',     'Movimentos', 70),
  ('escalas',            'Escalas',                   'Movimentos', 71),
  ('ocorrencias',        'Ocorrências',               'Movimentos', 72),
  ('afastamentos',       'Afastamentos',              'Movimentos', 72),
  ('afd',                'Arquivo AFD',               'Movimentos', 79),
  ('tipos_licenca',      'Tipos de Licença',          'Cadastros',  46),
  ('motivos_batida',     'Motivos de Batida',         'Cadastros',  47),
  ('justificativas',     'Justificativas',            'Movimentos', 73),
  ('solicitacoes',       'Solicitações',              'Movimentos', 74),
  ('fechamento',         'Fechamento de Período',     'Movimentos', 78),
  ('espelho_ponto',      'Espelho de Ponto',          'Relatórios', 80),
  ('totais_periodo',     'Totais e Exportação p/ Folha', 'Relatórios', 82),
  ('quebra_regras',      'Quebra de Regras',          'Relatórios', 84),
  ('locais_batidas',     'Locais das Batidas',        'Relatórios', 86),
  ('relatorio_banco_horas_detalhe', 'Detalhamento de Banco de Horas', 'Relatórios', 87),
  ('relatorio_banco_horas', 'Resumo do Banco de Horas', 'Relatórios', 87),
  ('relatorio_escalas',  'Relatório de Escalas',      'Relatórios', 88),
  ('relatorio_noturno',  'Relatório de Adicional Noturno', 'Relatórios', 89),
  ('relatorio_folgas',   'Relatório de Folgas',       'Relatórios', 89),
  ('relatorio_faltas',   'Listagem de Faltas',        'Relatórios', 89),
  ('relatorio_assiduidade', 'Listagem de Assiduidade', 'Relatórios', 89),
  ('relatorio_colaboradores', 'Relatório de Colaboradores', 'Relatórios', 89),
  ('tipos_beneficio',    'Tipos de VT e VA',          'Cadastros',  48),
  ('relatorio_vt',       'Relatório de VT',           'Relatórios', 89),
  ('relatorio_va',       'Relatório de VA',           'Relatórios', 89),
  ('empresas',           'Empresas',                  'Configurações', 90),
  ('configuracoes',      'Ponto, Banco de Horas, VT e VA', 'Configurações', 92),
  ('config_dashboard',   'Dashboard',                 'Configurações', 93),
  ('integracoes',        'Integrações (API)',         'Configurações', 94),
  ('auditoria',          'Log e Auditoria',           'Configurações', 96)
on conflict (chave) do update
  set nome = excluded.nome, grupo = excluded.grupo, ordem = excluded.ordem;

-- O local de ponto foi para dentro do cadastro da empresa: quem cuidava dele passa a cuidar das empresas
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'empresas', pode_visualizar, pode_editar from perfil_permissoes where pagina = 'locais_ponto'
on conflict (perfil_id, pagina) do nothing;
delete from paginas where chave = 'locais_ponto';

-- Perfis
insert into perfis (nome, descricao, is_admin, abrangencia) values
  ('Administrador', 'Acesso total ao sistema', true, 'todos'),
  ('RH',            'Gestão de pessoas, jornadas, banco de horas e relatórios', false, 'todos'),
  ('Gestor',        'Acompanha a equipe e realiza ajustes de ponto', false, 'equipe'),
  ('Consulta',      'Somente visualização de indicadores e relatórios', false, 'todos'),
  ('Colaborador',   'Registra o próprio ponto e vê somente as próprias informações', false, 'proprio')
on conflict (nome) do nothing;

insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select p.id, x.pagina, x.ver, x.editar
  from perfis p
  join (values
    ('RH', 'dashboard', true, false),
    ('RH', 'colaboradores', true, true),
    ('RH', 'jornadas', true, true),
    ('RH', 'perfis_eventos', true, true),
    ('RH', 'batidas', true, false),
    ('RH', 'banco_horas', true, true),
    ('RH', 'banco_horas_conversao', true, true),
    ('RH', 'lancamento_manual', true, true),
    ('RH', 'espelho_ponto', true, false),
    ('Gestor', 'dashboard', true, false),
    ('Gestor', 'colaboradores', true, false),
    ('Gestor', 'batidas', true, false),
    ('Gestor', 'banco_horas', true, false),
    ('Gestor', 'lancamento_manual', true, true),
    ('Gestor', 'espelho_ponto', true, false),
    ('Consulta', 'dashboard', true, false),
    ('Consulta', 'espelho_ponto', true, false),
    ('RH', 'consulta_batidas', true, true),
    ('Gestor', 'consulta_batidas', true, true),
    ('RH', 'meu_ponto', true, true),
    ('Gestor', 'meu_ponto', true, true),
    ('Consulta', 'meu_ponto', true, true),
    ('Colaborador', 'meu_ponto', true, true),
    ('Colaborador', 'dashboard', true, false),
    ('RH', 'feriados', true, true),
    ('RH', 'empresas', true, true),
    ('RH', 'configuracoes', true, true),
    ('RH', 'integracoes', true, true),
    ('RH', 'ocorrencias', true, true),
    ('RH', 'escalas', true, true),
    ('Gestor', 'escalas', true, false),
    ('RH', 'solicitacoes', true, true),
    ('RH', 'fechamento', true, true),
    ('RH', 'totais_periodo', true, true),
    ('RH', 'quebra_regras', true, false),
    ('Gestor', 'ocorrencias', true, false),
    ('RH', 'justificativas', true, true),
    ('Gestor', 'justificativas', true, true),
    ('Gestor', 'solicitacoes', true, true),
    ('Gestor', 'quebra_regras', true, false),
    ('Consulta', 'totais_periodo', true, false),
    ('Consulta', 'quebra_regras', true, false),
    ('RH', 'locais_batidas', true, false),
    ('Gestor', 'locais_batidas', true, false),
    ('Consulta', 'locais_batidas', true, false)
  ) as x(perfil, pagina, ver, editar) on x.perfil = p.nome
on conflict (perfil_id, pagina) do nothing;

-- Motivos de inclusão / desconsideração de batidas
insert into motivos_batida (descricao, aplicacao) values
  ('Esquecimento de marcação',            'inclusao'),
  ('Falha no relógio de ponto',           'inclusao'),
  ('Serviço externo',                     'inclusao'),
  ('Trabalho remoto',                     'inclusao'),
  ('Treinamento ou curso externo',        'inclusao'),
  ('Marcação duplicada',                  'desconsideracao'),
  ('Marcação indevida ou por engano',     'desconsideracao'),
  ('Marcação feita por terceiro',         'desconsideracao'),
  ('Ajuste autorizado pelo gestor',       'ambos')
on conflict (descricao) do nothing;

-- Eventos da folha de pagamento (o código de cada verba é configurado na tela de Totais).
-- As horas extras têm um evento por percentual, criado a partir dos perfis de eventos.
insert into eventos_folha (chave, descricao, unidade, ordem) values
  ('adicional_noturno','Adicional noturno',                  'horas',  30),
  ('faltas_dias',      'Faltas (dias)',                      'dias',   40),
  ('faltas_horas',     'Faltas (horas)',                     'horas',  50),
  ('atrasos',          'Atrasos e saídas antecipadas',       'horas',  60),
  ('desconto_horas',   'Horas não trabalhadas (sem banco)',  'horas',  70),
  ('dsr',              'DSR descontado',                     'dias',   80),
  ('bh_pago',          'Banco de horas convertido em pagamento', 'horas', 90),
  ('bh_descontado',    'Banco de horas convertido em desconto',  'horas', 100)
on conflict (chave) do update set descricao = excluded.descricao, unidade = excluded.unidade, ordem = excluded.ordem;

select fn_eventos_he_sincronizar();

-- Feriados nacionais 2026
insert into feriados (data, descricao) values
  ('2026-01-01', 'Confraternização Universal'),
  ('2026-02-16', 'Carnaval (ponto facultativo)'),
  ('2026-02-17', 'Carnaval (ponto facultativo)'),
  ('2026-04-03', 'Sexta-feira Santa'),
  ('2026-04-21', 'Tiradentes'),
  ('2026-05-01', 'Dia do Trabalho'),
  ('2026-06-04', 'Corpus Christi (ponto facultativo)'),
  ('2026-09-07', 'Independência do Brasil'),
  ('2026-10-12', 'Nossa Senhora Aparecida'),
  ('2026-11-02', 'Finados'),
  ('2026-11-15', 'Proclamação da República'),
  ('2026-11-20', 'Dia Nacional de Zumbi e da Consciência Negra'),
  ('2026-12-25', 'Natal')
on conflict (data) do nothing;

update feriados set tipo = 'facultativo'
 where tipo = 'nacional' and descricao like '%(ponto facultativo)';

-- Situação do Colaborador: quem cuida do cadastro de colaboradores cuida também das situações
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'situacoes_colaborador', pode_visualizar, pode_editar
  from perfil_permissoes where pagina = 'colaboradores'
on conflict (perfil_id, pagina) do nothing;

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
-- Listagens de faltas e de assiduidade: quem vê os totais do período; dados cadastrais: quem vê os colaboradores
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_faltas', pode_visualizar, false from perfil_permissoes where pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_assiduidade', pode_visualizar, false from perfil_permissoes where pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_colaboradores', pode_visualizar, false from perfil_permissoes where pagina = 'colaboradores'
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

-- VT e VA: o cadastro segue as jornadas; os relatórios, os totais do período
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'tipos_beneficio', pode_visualizar, pode_editar from perfil_permissoes where pagina = 'jornadas'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, x.pagina, pode_visualizar, false
  from perfil_permissoes cross join (values ('relatorio_vt'), ('relatorio_va')) x(pagina)
 where perfil_permissoes.pagina = 'totais_periodo'
on conflict (perfil_id, pagina) do nothing;

-- Relatórios de Banco de Horas e de Escalas: quem vê o banco de horas / as escalas vê o relatório
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_banco_horas', pode_visualizar, false from perfil_permissoes where pagina = 'banco_horas'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_banco_horas_detalhe', pode_visualizar, false from perfil_permissoes where pagina = 'relatorio_banco_horas'
on conflict (perfil_id, pagina) do nothing;
insert into perfil_permissoes (perfil_id, pagina, pode_visualizar, pode_editar)
select perfil_id, 'relatorio_escalas', pode_visualizar, false from perfil_permissoes where pagina = 'escalas'
on conflict (perfil_id, pagina) do nothing;
