export type PaginaChave =
  | 'meu_ponto'
  | 'dashboard'
  | 'colaboradores'
  | 'usuarios'
  | 'jornadas'
  | 'perfis_eventos'
  | 'escalas'
  | 'batidas'
  | 'banco_horas'
  | 'banco_horas_conversao'
  | 'consulta_batidas'
  | 'lancamento_manual'
  | 'espelho_ponto'
  | 'feriados'
  | 'locais_ponto'
  | 'ocorrencias'
  | 'solicitacoes'
  | 'fechamento'
  | 'totais_periodo'
  | 'quebra_regras';

export interface Usuario {
  id: string;
  nome: string;
  login: string;
  email: string | null;
  colaborador_id: string | null;
  trocar_senha: boolean;
  perfil: { id: string; nome: string; is_admin: boolean; abrangencia: Abrangencia };
  permissoes: Partial<Record<PaginaChave, { visualizar: boolean; editar: boolean }>>;
}

/** Dados que o perfil enxerga: todos, a equipe do colaborador vinculado ou somente ele. */
export type Abrangencia = 'todos' | 'equipe' | 'proprio';

export type SituacaoColaborador = 'ativo' | 'afastado' | 'desligado' | 'ferias';

export type StatusHoje =
  | 'em_jornada'
  | 'em_intervalo'
  | 'finalizado'
  | 'aguardando'
  | 'ausente'
  | 'folga'
  | 'ausencia'
  | 'ferias'
  | 'afastado'
  | 'inconsistente';

export interface RegistroHoje {
  id: string;
  nome: string;
  matricula: string;
  situacao: SituacaoColaborador;
  departamento: string | null;
  cargo: string | null;
  entrada_prevista: string | null;
  atraso_min: number;
  batidas: BatidaResumo[];
  status: StatusHoje;
}

export interface SaldoColaborador {
  id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  saldo_minutos: number;
}

export interface AbsenteismoDia {
  data: string;
  faltas: number;
  atrasos: number;
  previstos: number;
}

export interface RankingAtraso {
  id: string;
  nome: string;
  departamento: string | null;
  ocorrencias: number;
  minutos: number;
  faltas: number;
}

export interface DashboardData {
  periodo: { inicio: string; fim: string; hoje: string };
  resumo: {
    situacoes: Record<SituacaoColaborador, number>;
    hoje: { previstos: number; presentes: number; ausentes: number; atrasados: number; batidas: number };
    periodo: {
      dias_previstos: number;
      faltas: number;
      atrasos: number;
      minutos_atraso: number;
      absenteismo_pct: number | null;
    };
    banco_horas: {
      saldo_positivo: number;
      saldo_negativo: number;
      qtd_positivos: number;
      qtd_negativos: number;
    };
  };
  banco_horas: SaldoColaborador[];
  absenteismo_diario: AbsenteismoDia[];
  ranking_atrasos: RankingAtraso[];
  registros_hoje: RegistroHoje[];
}

// ---------------------------------------------------------------------------
// Cadastros
// ---------------------------------------------------------------------------
export interface Opcao {
  id: string;
  nome: string;
}

export interface CadastrosAuxiliares {
  departamentos: Opcao[];
  cargos: Opcao[];
  jornadas: Opcao[];
  perfis_eventos: (Opcao & { padrao: boolean })[];
  gestores: Opcao[];
}

export interface ColaboradorResumo {
  id: string;
  matricula: string;
  nome: string;
  cpf: string;
  email: string | null;
  telefone: string | null;
  situacao: SituacaoColaborador;
  data_admissao: string;
  data_desligamento: string | null;
  cargo: string | null;
  departamento: string | null;
  jornada: string | null;
  perfil_evento: string | null;
  controla_ponto: boolean;
  controle_ponto_inicio: string;
  tem_acesso: boolean;
}

export interface HistoricoItem {
  id: string;
  tipo: string;
  descricao: string;
  dados_anteriores: Record<string, unknown> | null;
  dados_novos: Record<string, unknown> | null;
  usuario: string | null;
  created_at: string;
  data_vigencia: string;
}

export interface JornadaVigencia {
  data_inicio: string;
  data_fim: string | null;
  jornada_id: string;
  jornada: string;
}

export interface AcessoColaborador {
  usuario_id: string;
  login: string;
  status: 'ativo' | 'inativo' | 'bloqueado';
  perfil: string;
  ultimo_acesso: string | null;
}

export interface Colaborador {
  id?: string;
  matricula: string;
  nome: string;
  nome_social: string;
  cpf: string;
  pis: string;
  rg: string;
  data_nascimento: string;
  sexo: string;
  email: string;
  telefone: string;
  cep: string;
  logradouro: string;
  numero: string;
  complemento: string;
  bairro: string;
  cidade: string;
  uf: string;
  cargo_id: string;
  departamento_id: string;
  jornada_id: string;
  /** Perfil de eventos (regras de cálculo); vazio = perfil padrão */
  perfil_evento_id: string;
  gestor_id: string;
  data_admissao: string;
  data_desligamento: string;
  situacao: SituacaoColaborador;
  salario: string;
  observacoes: string;
  controla_ponto: boolean;
  controle_ponto_inicio: string;
  /** Data a partir da qual as alterações valem (histórico e jornada) */
  data_vigencia: string;
  historico?: HistoricoItem[];
  jornadas_vigencias?: JornadaVigencia[];
  acesso?: AcessoColaborador | null;
}

export interface JornadaDia {
  dia_semana: number;
  folga: boolean;
  entrada: string | null;
  saida_intervalo: string | null;
  retorno_intervalo: string | null;
  saida: string | null;
}

export type TipoJornada = 'semanal' | 'escala';

export interface Jornada {
  id?: string;
  nome: string;
  descricao: string | null;
  /** semanal: dias 0–6 (domingo = 0) · escala: dias do ciclo 0…ciclo_dias-1 a partir de data_base */
  tipo: TipoJornada;
  ciclo_dias: number | null;
  data_base: string | null;
  ativo: boolean;
  colaboradores?: number;
  minutos_semana?: number;
  dias: JornadaDia[];
}

/** Percentual de hora extra de um dia: 0 = domingo … 6 = sábado, 7 = feriado, 8 = folga */
export interface PerfilEventoHe {
  dia: number;
  percentual: number;
}

/** Regras de cálculo do ponto, vinculadas ao colaborador (separadas da jornada) */
export interface PerfilEvento {
  id?: string;
  nome: string;
  descricao: string | null;
  padrao: boolean;
  tolerancia_entrada_min: number;
  tolerancia_saida_min: number;
  tolerancia_diaria_min: number;
  /** 'batida': tolerância de entrada/saída em cada marcação · 'diaria': só a geral do dia */
  tolerancia_modo: 'batida' | 'diaria';
  limite_he_diario_min: number;
  usa_banco_horas: boolean;
  noturno_inicio: string;
  noturno_fim: string;
  percentual_noturno: number;
  hora_noturna_reduzida: boolean;
  ativo: boolean;
  he: PerfilEventoHe[];
  colaboradores?: number;
}

/** Horas extras pagas de um percentual (chave = evento da folha, ex.: he_50) */
export interface HePercentual {
  chave: string;
  percentual: number;
  minutos: number;
}

// ---------------------------------------------------------------------------
// Ponto e banco de horas
// ---------------------------------------------------------------------------
/** Situação da localização da batida: no raio de um local, fora dele, sem local cadastrado ou sem localização */
export type GeoStatus = 'dentro' | 'fora' | 'registrada' | 'sem_localizacao';

/** Geolocalização registrada com a batida (só batidas feitas pelo sistema/quiosque têm) */
export interface GeoBatida {
  geo_status?: GeoStatus | null;
  geo_erro?: string | null;
  latitude?: number | null;
  longitude?: number | null;
  precisao_m?: number | null;
  distancia_m?: number | null;
  /** Local de ponto mais próximo */
  local?: string | null;
}

export interface BatidaResumo extends GeoBatida {
  id: string;
  hora: string;
  origem: string;
  nsr: number | null;
  /** Classificação efetiva: declarada pelo RH ou pela sequência do dia */
  sentido: Sentido;
  turno: number;
}

/** Local onde o colaborador deve bater o ponto (um só; centro capturado pelo aparelho + raio) */
export interface LocalPonto {
  id?: string;
  nome: string;
  endereco: string | null;
  latitude: number | null;
  longitude: number | null;
  raio_m: number;
  /** Precisão do GPS quando as coordenadas foram capturadas */
  precisao_m: number | null;
  ativo: boolean;
  batidas_30d?: number;
  fora_30d?: number;
}

export interface MeuPontoData {
  vinculado: boolean;
  agora: string;
  colaborador: {
    id: string;
    nome: string;
    matricula: string;
    situacao: SituacaoColaborador;
    cargo: string | null;
    departamento: string | null;
    jornada: string | null;
    controle_ponto_inicio: string;
  };
  pode_registrar: boolean;
  motivo: string | null;
  hoje: {
    data: string;
    previsto_min: number;
    trabalhado_min: number;
    qtd_batidas: number;
    batidas: BatidaResumo[];
    jornada_dia: {
      folga: boolean;
      entrada: string | null;
      saida_intervalo: string | null;
      retorno_intervalo: string | null;
      saida: string | null;
    } | null;
  };
  saldo_banco_min: number;
  ultimos_dias: {
    data: string;
    previsto_min: number;
    trabalhado_min: number;
    saldo_min: number;
    atraso_min: number;
    ocorrencia: string;
    batidas: BatidaResumo[];
  }[];
}

export interface RegistroPonto extends GeoBatida {
  ok: boolean;
  data: string;
  hora: string;
  nsr: number;
  sequencia: number;
  tipo: string; // "Entrada do 1º turno", "Saída do 1º turno"…
  colaborador?: string;
  matricula?: string;
}

export interface BatidasDiaColaborador {
  id: string;
  nome: string;
  matricula: string;
  situacao: SituacaoColaborador;
  departamento: string | null;
  jornada: string | null;
  horario_previsto: string | null;
  previsto_min: number;
  trabalhado_min: number;
  atraso_min: number;
  saldo_min: number;
  ocorrencia: string;
  batidas: BatidaResumo[];
  status: StatusHoje;
}

export interface BatidasDia {
  data: string;
  hoje: string;
  colaboradores: BatidasDiaColaborador[];
  ultimas: { id: string; nome: string; hora: string; origem: string; nsr: number | null }[];
}

/** Prévia/resultado da conversão do saldo do banco de horas */
export interface ConversaoBH {
  gravado: boolean;
  itens: { id: string; nome: string; matricula: string; saldo: number; convertido: number; saldo_final: number }[];
  pago_min: number;
  descontado_min: number;
}

export interface ConversaoBHHistorico {
  id: string;
  data: string;
  colaborador_id: string;
  nome: string;
  matricula: string;
  /** positivo = pago como hora extra; negativo = descontado */
  convertido: number;
  descricao: string | null;
  usuario: string | null;
  created_at: string;
}

/** Banco de horas detalhado por dia (batidas, o que cada uma gerou e o saldo do dia) */
export interface BancoHorasDia {
  data: string;
  horario_previsto: string | null;
  ocorrencia: string;
  previsto_min: number;
  trabalhado_min: number;
  /** Saldo apurado do dia (já com a tolerância diária) */
  saldo_dia: number;
  vai_para_banco: boolean;
  /** Tudo que entrou no banco no dia (automático + manuais) */
  banco_dia: number;
  /** Saldo do banco ao fim do dia */
  acumulado: number;
  /** Marcações previstas (E1, S1, E2, S2) com o realizado, mais batidas sem previsão */
  linhas: {
    turno: number;
    sentido: Sentido;
    previsto: string | null;
    /** null = marcação não realizada */
    hora: string | null;
    origem: string | null;
    /** Minutos que a batida gerou (+ crédito, − débito); null = turno não fechou */
    gerou_min: number | null;
  }[];
  /** Resultado de cada turno: incompleto → o previsto do turno vira débito */
  turnos: { turno: number; previsto_min: number; trabalhado_min: number; completo: boolean; gerou_min: number }[];
  lancamentos: { id: string; tipo: TipoLancamento; minutos: number; descricao: string | null; usuario: string | null }[];
}

export interface BancoHorasDetalhe {
  id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  jornada: string | null;
  saldo_anterior: number;
  creditos: number;
  debitos: number;
  saldo_final: number;
  dias: BancoHorasDia[];
}

export interface BancoHorasResumo {
  id: string;
  nome: string;
  matricula: string;
  situacao: SituacaoColaborador;
  departamento: string | null;
  jornada: string | null;
  creditos: number;
  debitos: number;
  saldo: number;
  ultimo_lancamento: string | null;
}

export type TipoLancamento = 'credito' | 'debito' | 'compensacao' | 'ajuste' | 'conversao';

export interface LancamentoBH {
  id: string;
  data: string;
  tipo: TipoLancamento;
  origem: 'automatico' | 'manual';
  minutos: number;
  descricao: string | null;
  usuario: string | null;
  created_at: string;
  saldo: number;
}

// ---------------------------------------------------------------------------
// Tratamento de batidas
// ---------------------------------------------------------------------------
export type StatusBatida = 'original' | 'incluida' | 'desconsiderada';
export type Sentido = 'E' | 'S';

export interface BatidaTratamento extends GeoBatida {
  id: string;
  colaborador_id: string;
  data_hora: string;
  /** Data local em que a batida aconteceu */
  data: string;
  hora: string;
  /** Dia de trabalho ao qual a batida pertence */
  data_referencia: string;
  origem: string;
  status: StatusBatida;
  /** Sentido efetivo (declarado ou pela alternância) */
  sentido: Sentido | null;
  sentido_declarado: Sentido | null;
  /** Turno efetivo (1º, 2º, 3º…) e o declarado pelo RH */
  turno: number | null;
  turno_declarado: number | null;
  nsr: number | null;
  motivo_id: string | null;
  motivo: string | null;
  observacao: string | null;
  colaborador?: string;
  matricula?: string;
  departamento?: string | null;
}

export interface MotivoBatida {
  id: string;
  descricao: string;
  aplicacao: 'inclusao' | 'desconsideracao' | 'ambos';
}

export interface TratamentoAux {
  pode_editar: boolean;
  estabelecimentos: Opcao[];
  colaboradores: {
    id: string;
    nome: string;
    matricula: string;
    situacao: SituacaoColaborador;
    departamento_id: string | null;
    cargo_id: string | null;
    jornada_id: string | null;
  }[];
  departamentos: Opcao[];
  cargos: Opcao[];
  jornadas: Opcao[];
  motivos: MotivoBatida[];
}

export type SituacaoBatida =
  | 'precisa'
  | 'entrada_tolerancia'
  | 'saida_tolerancia'
  | 'atraso'
  | 'antecipada'
  | 'saida_antecipada'
  | 'apos_previsto'
  | 'feriado'
  | 'folga'
  | 'ausencia'
  | 'fora_jornada'
  | 'sem_jornada'
  | 'desconsiderada'
  | 'turno_incompleto'
  | 'turno_aberto'
  | 'nao_registrada'
  | 'pendente'
  | 'dia_ausencia'
  | 'dia_feriado';

/** Linha da Consulta de batidas: uma batida, com o horário previsto da marcação e a situação */
export interface ConsultaBatida extends BatidaTratamento {
  tipo: 'batida';
  colaborador: string;
  matricula: string;
  departamento: string | null;
  jornada: string | null;
  /** Jornada do dia em texto ('08:00–12:00 · 13:00–17:00'); null em folga */
  horario_previsto: string | null;
  /** Horário previsto para esta marcação (HH:MM) */
  previsto: string | null;
  /** Batida − previsto, em minutos (negativo = antes) */
  diferenca_min: number | null;
  ausencia: TipoAusencia | null;
  /** Observação do dia: "Empregado de férias", "Empregado afastado", "Feriado: …" */
  obs_dia: string | null;
  situacao: SituacaoBatida;
}

/** Marcação prevista na jornada do dia que não tem batida (não registrada ou ainda pendente) */
export interface ConsultaMarcacaoPrevista {
  tipo: 'prevista';
  id: string;
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  data: string;
  data_referencia: string;
  jornada: string | null;
  horario_previsto: string | null;
  sentido: Sentido;
  turno: number;
  previsto: string;
  obs_dia: string | null;
  situacao: 'nao_registrada' | 'pendente';
}

/** Dia de ausência (férias, afastamento…) ou feriado sem batidas: uma linha com a observação */
export interface ConsultaDiaSemBatida {
  tipo: 'dia';
  id: string;
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  data: string;
  data_referencia: string;
  jornada: string | null;
  horario_previsto: string | null;
  ausencia: TipoAusencia | null;
  obs_dia: string;
  situacao: 'dia_ausencia' | 'dia_feriado';
  sentido?: null;
  turno?: null;
  previsto?: null;
}

export type ConsultaLinha = ConsultaBatida | ConsultaMarcacaoPrevista | ConsultaDiaSemBatida;

export interface HistoricoBatida {
  acao: string;
  valor_anterior: string | null;
  valor_novo: string | null;
  justificativa: string | null;
  motivo: string | null;
  dados: Record<string, unknown> | null;
  usuario: string | null;
  created_at: string;
}

// ---------------------------------------------------------------------------
// Módulos no padrão Fortes Ponto: ocorrências, solicitações, fechamento,
// espelho, totais/folha, e quebra de regras
// ---------------------------------------------------------------------------
export type TipoAusencia = 'falta_justificada' | 'atestado' | 'ferias' | 'folga' | 'afastamento' | 'abono';

export interface FiltrosAux {
  empresa: { razao_social: string; nome_fantasia: string | null; cnpj: string | null } | null;
  colaboradores: {
    id: string;
    nome: string;
    matricula: string;
    situacao: SituacaoColaborador;
    departamento_id: string | null;
    cargo_id: string | null;
    jornada_id: string | null;
  }[];
  departamentos: Opcao[];
  motivos: MotivoBatida[];
  fechado_ate: string | null;
}

export interface Feriado {
  id?: string;
  data: string;
  descricao: string;
  tipo: 'nacional' | 'estadual' | 'municipal' | 'facultativo';
}

export interface Ocorrencia {
  id: string;
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  tipo: TipoAusencia;
  data_inicio: string;
  data_fim: string;
  dias: number;
  abona: boolean;
  minutos: number | null;
  justificativa: string | null;
  usuario: string | null;
  created_at: string;
  fechado: boolean;
}

export type TipoSolicitacao = 'inclusao_batida' | 'abono';
export type StatusSolicitacao = 'pendente' | 'aprovada' | 'reprovada' | 'cancelada';

export interface Solicitacao {
  id: string;
  colaborador_id: string;
  tipo: TipoSolicitacao;
  data: string;
  data_fim: string | null;
  hora: string | null;
  sentido: Sentido | null;
  tipo_ausencia: TipoAusencia | null;
  minutos: number | null;
  motivo: string | null;
  justificativa: string;
  status: StatusSolicitacao;
  resposta: string | null;
  avaliador: string | null;
  avaliado_em: string | null;
  created_at: string;
  // Na visão do gestor
  colaborador?: string;
  matricula?: string;
  departamento?: string | null;
  batidas_dia?: BatidaResumo[];
  fechado?: boolean;
}

export interface Fechamento {
  id: string;
  data_inicio: string;
  data_fim: string;
  observacao: string | null;
  usuario: string | null;
  created_at: string;
}

export interface PreviaFechamento {
  resumo: {
    colaboradores: number;
    inconsistentes: number;
    faltas: number;
    sem_jornada: number;
    solicitacoes: number;
    ja_fechado: boolean;
  };
  pendencias: {
    colaborador_id: string;
    nome: string;
    matricula: string;
    data: string;
    ocorrencia: string;
    qtd_batidas: number;
  }[];
}

export interface EspelhoDia {
  data: string;
  previsto: string | null;
  /** Escala lançada no dia (fora do padrão da jornada) */
  escala?: TipoEscala | null;
  previsto_min: number;
  trabalhado_min: number;
  extra_min: number;
  debito_min: number;
  /** Percentual de HE do dia, pelo perfil de eventos */
  he_percentual: number;
  atraso_min: number;
  saida_antecipada_min: number;
  noturno_min: number;
  abonado_min: number;
  banco_horas: boolean;
  ocorrencia: string;
  observacao: string | null;
  batidas: BatidaTratamento[];
}

export interface EspelhoColaborador {
  colaborador: {
    id: string;
    nome: string;
    matricula: string;
    cpf: string;
    pis: string | null;
    admissao: string;
    cargo: string | null;
    departamento: string | null;
  };
  jornadas: { nome: string; tipo: TipoJornada; descricao: string | null }[];
  dias: EspelhoDia[];
  totais: {
    previsto_min: number;
    trabalhado_min: number;
    he_min: number;
    he: HePercentual[];
    debito_min: number;
    faltas: number;
    atraso_min: number;
    saida_antecipada_min: number;
    noturno_min: number;
    abonado_min: number;
  };
  banco_horas: { anterior: number; creditos: number; debitos: number; saldo: number };
}

export interface EspelhoPonto {
  empresa: { razao_social: string; nome_fantasia: string | null; cnpj: string | null; endereco: string | null };
  periodo: { inicio: string; fim: string };
  emitido_em: string;
  emitido_por: string;
  espelhos: EspelhoColaborador[];
}

export interface EventoFolha {
  chave: string;
  descricao: string;
  codigo: string | null;
  unidade: 'horas' | 'dias';
  ativo: boolean;
}

export interface TotaisColaborador {
  id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  jornada: string | null;
  dias_trabalhados: number;
  previsto_min: number;
  trabalhado_min: number;
  /** Horas extras pagas (sem banco de horas): total e por percentual */
  he_min: number;
  he: HePercentual[];
  noturno_min: number;
  faltas_dias: number;
  faltas_min: number;
  atraso_min: number;
  saida_antecipada_min: number;
  /** O que vai para a folha: só jornadas sem banco de horas */
  faltas_folha_dias: number;
  faltas_folha_min: number;
  atraso_folha_min: number;
  /** Débito do dia além dos atrasos e saídas antecipadas (sem banco de horas) */
  desconto_min: number;
  dsr_perdidos: number;
  bh_periodo_min: number;
  bh_saldo_min: number;
  /** Saldo do banco convertido em pagamento / desconto no período */
  bh_pago_min: number;
  bh_descontado_min: number;
  inconsistencias: number;
}

export interface TotaisPeriodo {
  periodo: { inicio: string; fim: string; apurado_ate: string };
  pode_editar: boolean;
  eventos: EventoFolha[];
  colaboradores: TotaisColaborador[];
}

export type RegraQuebrada =
  | 'interjornada'
  | 'intrajornada'
  | 'jornada_maxima'
  | 'limite_he'
  | 'marcacao_impar'
  | 'fora_local'
  | 'sem_localizacao';

export interface QuebraRegra {
  colaborador_id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  data: string;
  regra: RegraQuebrada;
  detalhe: string;
  minutos: number | null;
}

// -----------------------------------------------------------------------------
// Usuários & Permissões
// -----------------------------------------------------------------------------
export type StatusUsuario = 'ativo' | 'inativo' | 'bloqueado';
export type Permissoes = Partial<Record<PaginaChave, { visualizar: boolean; editar: boolean }>>;

export interface UsuarioSistema {
  id: string;
  nome: string;
  login: string;
  email: string | null;
  status: StatusUsuario;
  perfil_id: string;
  perfil: string;
  is_admin: boolean;
  abrangencia: Abrangencia;
  colaborador_id: string | null;
  colaborador: string | null;
  matricula: string | null;
  ultimo_acesso: string | null;
  trocar_senha: boolean;
  bloqueado: boolean;
  sessoes: number;
  created_at: string;
}

export interface PerfilAcesso {
  id: string;
  nome: string;
  descricao: string | null;
  is_admin: boolean;
  abrangencia: Abrangencia;
  usuarios: number;
  permissoes: Permissoes;
}

export interface UsuariosDados {
  pode_editar: boolean;
  eu: string;
  usuarios: UsuarioSistema[];
  perfis: PerfilAcesso[];
  paginas: { chave: PaginaChave; nome: string; grupo: string }[];
  colaboradores: {
    id: string;
    nome: string;
    matricula: string;
    cpf: string;
    email: string | null;
    situacao: SituacaoColaborador;
    departamento: string | null;
    usuario_id: string | null;
  }[];
}

export interface ResultadoAcessos {
  criados: { nome: string; login: string }[];
  ignorados: { nome: string; motivo: string }[];
}

export interface MeuDashboardDia {
  data: string;
  previsto_min: number;
  trabalhado_min: number;
  saldo_min: number;
  atraso_min: number;
  falta: boolean;
  ocorrencia: string | null;
  impar: boolean;
  feriado: boolean;
  batidas: BatidaResumo[];
}

export interface MeuDashboardData {
  vinculado: boolean;
  periodo: { inicio: string; fim: string; hoje: string };
  colaborador: {
    id: string;
    nome: string;
    matricula: string;
    situacao: SituacaoColaborador;
    cargo: string | null;
    departamento: string | null;
    jornada: string | null;
    horario_hoje: string | null;
  };
  resumo: {
    dias_previstos: number;
    dias_trabalhados: number;
    previsto_min: number;
    trabalhado_min: number;
    extra_min: number;
    debito_min: number;
    faltas: number;
    atrasos: number;
    minutos_atraso: number;
    noturno_min: number;
    inconsistencias: number;
  };
  banco_horas: { saldo: number; anterior: number; periodo: number };
  hoje: { batidas: BatidaResumo[]; previsto_min: number; trabalhado_min: number };
  dias: MeuDashboardDia[];
  solicitacoes_pendentes: number;
  pode_registrar: boolean;
}

// ---------------------------------------------------------------------------
// Escalas (previsão de trabalho ou folga em dias específicos)
// ---------------------------------------------------------------------------
export type TipoEscala = 'trabalho' | 'folga';

export interface HorarioDia {
  entrada: string | null;
  saida_intervalo: string | null;
  retorno_intervalo: string | null;
  saida: string | null;
}

export interface Escala extends HorarioDia {
  id: string;
  tipo: TipoEscala;
  observacao: string | null;
  usuario: string | null;
}

/** Um dia da grade: o padrão da jornada (sem a escala) e a escala lançada */
export interface EscalaDia extends HorarioDia {
  data: string;
  jornada_folga: boolean;
  escala: Escala | null;
}

export interface EscalaColaborador {
  id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  jornada: string | null;
  inicio: string;
  desligamento: string | null;
  dias: EscalaDia[];
}

export interface EscalasGrade {
  feriados: { data: string; descricao: string }[];
  fechado_ate: string | null;
  colaboradores: EscalaColaborador[];
}
