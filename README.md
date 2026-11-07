# GePonto — ERP de Controle de Ponto

React 18 + Vite + TypeScript + Tailwind CSS, com Supabase (PostgreSQL) como banco.

## Arquitetura de segurança

- **Sem Supabase Auth.** Os usuários ficam na tabela `usuarios`, com senha em bcrypt (`pgcrypto`).
- **RLS ligado em todas as tabelas, sem policies.** A chave publishable não lê nem grava tabelas diretamente.
- **Todo acesso passa por funções `api_*`** (`SECURITY DEFINER`). Cada uma recebe `p_token` e chama
  `fn_auth(token, página, editar)`, que valida a sessão (tabela `sessoes`, token guardado como hash
  SHA-256, expiração deslizante de 12h) e a permissão do perfil (`perfil_permissoes`).
- O login bloqueia o usuário por 15 minutos após 5 tentativas erradas.
- Os triggers de auditoria (`colaborador_historico`) registram o usuário via `app.usuario_id`.

## Banco de dados

No **SQL Editor** do Supabase, execute nesta ordem:

| Arquivo | Conteúdo |
|---|---|
| `supabase/01_schema.sql` | Tipos, tabelas, índices, triggers e RLS |
| `supabase/02_functions.sql` | Autenticação, apuração diária, banco de horas e API do dashboard |
| `supabase/03_seed.sql` | Empresa, páginas, perfis, permissões e feriados de 2026 |
| `supabase/04_dados_demo.sql` | *(opcional)* jornadas de exemplo, 10 colaboradores e cerca de 5 semanas de batidas |
| `supabase/05_api_cadastros.sql` | API dos cadastros de colaboradores, departamentos, cargos e jornadas |
| `supabase/06_api_ponto.sql` | Meu Ponto (registro pelo colaborador), banco de horas e conversão do saldo |
| `supabase/07_api_tratamento.sql` | Tratamento e consulta de batidas (incluir, editar, apagar, desconsiderar, sentido, data de referência) |
| `supabase/08_api_fortes.sql` | Feriados, ocorrências em lote, fechamento, espelho, totais/folha e quebra de regras |
| `supabase/09_api_usuarios.sql` | Usuários & Permissões (perfis, abrangência, acessos em lote), dashboard pessoal e registro rápido de ponto |
| `supabase/99_admin.local.sql` | Usuário administrador (arquivo local, fora do Git) |

Para remover os dados de exemplo, rode `supabase/limpar_dados_demo.sql`.

Todos os scripts podem ser executados de novo sem erro. Para atualizar um banco existente, rode de novo
01, 02, 03, 05, 06, 07, 08 e 09, nesta ordem.

### Acessos e permissões

- **Cada colaborador tem o próprio login** (vinculado ao cadastro dele) e só registra o próprio ponto: a batida é sempre
  do colaborador vinculado ao usuário, com a hora do servidor.
- **Perfis** definem as telas (acessar / alterar) e a **abrangência** dos dados:
  - `todos`: todos os colaboradores (Administrador, RH, Consulta);
  - `equipe`: o próprio colaborador e os subordinados diretos (campo *Gestor* do cadastro), como no perfil Gestor;
  - `proprio`: somente o próprio colaborador. Esse perfil vê o **dashboard pessoal** no lugar do dashboard da empresa.
- A abrangência é aplicada no banco (`fn_visivel`) em todas as listas e ações, não só no menu.
- **Gerar acessos** cria em lote o login de quem ainda não tem (matrícula ou CPF), com senha inicial e **troca obrigatória** no 1º acesso.
- **Registrar ponto na tela de login:** o colaborador informa login e senha e a batida é registrada sem abrir o sistema
  (útil num computador compartilhado na recepção). Vale o mesmo bloqueio após 5 senhas erradas.
- O sistema nunca fica sem um administrador ativo, e ninguém altera o próprio perfil nem inativa o próprio acesso.
- Só um administrador cria, altera ou exclui administradores (também vale para "editar usuários" em perfis personalizados).

### Tabelas

`empresa`, `paginas`, `perfis`, `perfil_permissoes`, `usuarios`, `sessoes`, `departamentos`, `cargos`,
`jornadas`, `jornada_dias`, `feriados`, `colaboradores`, `colaborador_historico`, `colaborador_jornadas`, `ausencias`,
`batidas`, `batida_ajustes`, `motivos_batida`, `banco_horas`, `fechamentos`, `solicitacoes`, `eventos_folha`.

### Regras de apuração (`fn_apuracao`)

- A jornada prevista sai de `jornada_dias`. Ela é zerada em folgas, feriados e ausências que abonam.
- **Escalas:** jornada `semanal` usa o dia da semana; jornada `escala` (12x36, 5x1, 6x2…) usa o dia do ciclo,
  contado a partir de `data_base` (`fn_jornada_indice`).
- **Virada de turno:** batida até 4h depois da saída de um turno que atravessa a meia-noite conta no dia em que ele começou.
- **Horas extras:** saldo positivo; extras em folga/feriado usam o percentual de "folga/feriado". Jornadas sem banco de horas
  mandam extras e descontos para a folha (Totais); com banco, o saldo vai para o banco.
- **Arquivo da folha:** faltas e atrasos só vão para o arquivo em jornadas sem banco de horas (com banco, o débito já está no saldo).
  O débito do dia é repartido entre "atrasos e saídas antecipadas" e "horas não trabalhadas", sem ser descontado duas vezes.
  A tela de Totais continua mostrando todos os atrasos e faltas do período.
- **Adicional noturno:** minutos entre `noturno_inicio` e `noturno_fim` (22h–5h), com hora reduzida de 52min30s opcional.
- **Saída antecipada** além da tolerância de saída, **abono parcial** (ocorrência `abono` com minutos), **intervalo** e
  **interjornada** também são apurados por dia.
- As horas trabalhadas são calculadas por pares de batidas (entrada/saída).
- O atraso só conta quando passa da `tolerancia_entrada_min`. Quando passa, conta inteiro.
- Diferenças de até `tolerancia_diaria_min` (10 min, conforme a CLT, art. 58 §1º) não geram saldo.
- Uma falta é um dia com jornada prevista e nenhuma batida. O dia corrente não é contado.
- Só entram colaboradores com **controle de ponto** ligado, a partir da data "controlar ponto a partir de" (ou da admissão).
- Cada dia usa a **jornada vigente naquela data** (`colaborador_jornadas`). Ao trocar a jornada, informe a vigência: os dias anteriores continuam com a jornada antiga.
- **Banco de horas automático:** cada dia encerrado gera um lançamento `automatico` com o saldo do dia. O processamento roda sozinho:
  - ao abrir o dashboard, o Banco de Horas ou o Meu Ponto (dias pendentes);
  - ao incluir, alterar ou excluir uma batida de um dia passado (aquele dia);
  - ao salvar o colaborador (todo o histórico dele).
- Lançamentos manuais (crédito, débito, compensação, ajuste) exigem justificativa e registram o usuário.
- **Conversão do saldo** (menu próprio, permissão `banco_horas_conversao`): leva o saldo até uma data para a folha —
  positivo vira horas extras pagas, negativo vira desconto — com limite opcional por colaborador. Gera um lançamento
  `conversao` que zera o saldo e alimenta os eventos `bh_pago` e `bh_descontado` dos Totais. Estornar exclui o lançamento.

### Fechamento de período

- `fechamentos` congela os dias: o trigger `fn_bloquear_periodo_fechado` impede alterar batidas, ocorrências e lançamentos
  manuais do banco nesses dias, e o banco de horas automático não os recalcula. Reabrir recalcula o período.

### Turno completo

- Um turno só é apurado com entrada **e** saída. Batida sem o par (entrada que nunca saiu, saída sem entrada) não gera
  horas trabalhadas, atraso nem saldo; o dia fica como marcação ímpar até o RH tratar. No dia de hoje, o turno aberto
  ainda conta para o atraso. Na Consulta de batidas ela aparece como “Turno incompleto”.

### Tratamento de batidas

| Status | Origem | Cor | Ações permitidas |
|---|---|---|---|
| Original | relógio/REP, sistema, celular, importação | preto | desconsiderar, declarar sentido, alterar data de referência |
| Incluída | manual | azul | editar, apagar, declarar sentido, alterar data de referência |
| Desconsiderada | qualquer | vermelho | reconsiderar |

- A batida original **nunca** é excluída nem tem horário alterado. Isso é garantido pelo trigger `fn_batida_proteger`, inclusive contra SQL direto.
- Inclusão e desconsideração exigem um motivo cadastrado (`motivos_batida`).
- Toda ação vai para `batida_ajustes` (quem, quando, antes/depois, motivo). A exclusão guarda uma cópia da batida.
- O sentido declarado (E/S) substitui a alternância automática na formação dos pares entrada→saída.
- A data de referência pode ir para o dia anterior ou o seguinte (turnos que viram a noite).

## Front-end

```bash
cp .env.example .env    # preencha a URL e a chave publishable
npm install
npm run dev
```

## Keep-alive (GitHub Actions)

O arquivo é `.github/workflows/supabase-keep-alive.yml`. Ele roda todos os dias e chama a RPC `api_ping`.
Cadastre estes secrets no repositório: `SUPABASE_URL` e `SUPABASE_PUBLISHABLE_KEY`.

## Estrutura

```
src/
  App.tsx                    rotas, guarda de sessão e de permissão
  contexts/AuthContext.tsx   login, logout, restauração de sessão e permissões
  lib/                       cliente Supabase, helper api(), navegação, tipos e formatadores
  components/layout/         MenuSuperior (menu no topo com submenus em cascata; acordeão no celular), AppLayout
  components/ui/             Badge, Button, ContextMenu, EmptyState, Field, Modal, Toast
  components/dashboard/      KPIs, gráfico de banco de horas, faltas e atrasos, ranking, registros do dia, painel pessoal
  components/                colaboradores, jornadas, meuponto, relatorios, tratamento, usuarios
  pages/                     uma tela por item do menu (lib/navigation.ts), Login e Status
```
