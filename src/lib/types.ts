export type PaginaChave =
  | 'meu_ponto'
  | 'dashboard'
  | 'colaboradores'
  | 'situacoes_colaborador'
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
  | 'ocorrencias'
  | 'afastamentos'
  | 'tipos_licenca'
  | 'tipos_beneficio'
  | 'relatorio_vt'
  | 'relatorio_va'
  | 'motivos_batida'
  | 'afd'
  | 'relatorio_noturno'
  | 'relatorio_folgas'
  | 'relatorio_faltas'
  | 'relatorio_assiduidade'
  | 'relatorio_colaboradores'
  | 'config_dashboard'
  | 'justificativas'
  | 'solicitacoes'
  | 'fechamento'
  | 'totais_periodo'
  | 'quebra_regras'
  | 'locais_batidas'
  | 'relatorio_banco_horas'
  | 'relatorio_banco_horas_detalhe'
  | 'relatorio_escalas'
  | 'auditoria'
  | 'empresas'
  | 'configuracoes'
  | 'integracoes';

export interface Usuario {
  id: string;
  nome: string;
  login: string;
  email: string | null;
  colaborador_id: string | null;
  trocar_senha: boolean;
  perfil: { id: string; nome: string; is_admin: boolean; abrangencia: Abrangencia };
  permissoes: Partial<Record<PaginaChave, { visualizar: boolean; editar: boolean }>>;
  /** Empresa em que o usuário está conectado */
  empresa: { id: string; nome: string; razao_social: string; cnpj: string | null } | null;
  /** Empresas a que o usuário tem acesso */
  empresas: EmpresaOpcao[];
}

export interface EmpresaOpcao {
  id: string;
  nome: string;
  cidade?: string | null;
  uf?: string | null;
}

/** Local de ponto da empresa (cerca virtual) */
export interface LocalEmpresa {
  latitude: number;
  longitude: number;
  raio_m: number;
  precisao_m: number | null;
}

export interface Empresa {
  id?: string;
  razao_social: string;
  nome_fantasia: string | null;
  cnpj: string | null;
  inscricao_estadual: string | null;
  telefone: string | null;
  email: string | null;
  cep: string | null;
  logradouro: string | null;
  numero: string | null;
  complemento: string | null;
  bairro: string | null;
  cidade: string | null;
  uf: string | null;
  ativo: boolean;
  local: LocalEmpresa | null;
  colaboradores?: number;
  batidas_30d?: number;
  fora_30d?: number;
}

export interface EmpresasDados {
  pode_editar: boolean;
  atual: string | null;
  usar_limitacoes_ponto: boolean;
  empresas: Empresa[];
}

export type EscopoChave = 'leitura' | 'batidas';

export interface ChaveApi {
  id: string;
  nome: string;
  prefixo: string;
  escopos: EscopoChave[];
  ativo: boolean;
  ultimo_uso: string | null;
  criada_em: string;
  revogada_em: string | null;
  criado_por: string | null;
}

export interface IntegracoesDados {
  pode_editar: boolean;
  empresa: { id: string; razao_social: string; nome_fantasia: string | null } | null;
  chaves: ChaveApi[];
}

export interface Configuracoes {
  pode_editar: boolean;
  usar_limitacoes_ponto: boolean;
  bloquear_fora_cerca: boolean;
  /** Quando o dia conta para VT/VA: um turno trabalhado ou os dois */
  beneficio_turnos: 'um' | 'dois';
  /** Quando o saldo do dia entra no banco de horas */
  banco_contabilizar?: 'fim_dia' | 'fim_turnos';
  fuso_horario: string;
  empresas: { id: string; nome: string; tem_local: boolean; raio_m: number | null }[];
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
  /** Feriado sem escala de trabalho */
  feriado?: boolean;
  /** Marcações previstas do dia (E1, S1, E2, S2); null sem previsão */
  previstas: { sigla: string; hora: string }[] | null;
  /** Jornada com intervalo flexível: duração do intervalo */
  intervalo_flexivel_min: number | null;
  atraso_min: number;
  /** Saldo do banco de horas até hoje */
  saldo_banco_min: number;
  usa_banco: boolean;
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
  tipos_beneficio?: OpcaoBeneficio[];
  /** Próxima matrícula da sequência (sugerida no cadastro) */
  proxima_matricula: string | null;
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

/** Situação do Colaborador: o que vale a partir de data_inicio até data_fim (a véspera da seguinte) */
export type TipoBeneficio = 'vt' | 'va';

export interface OpcaoBeneficio {
  id: string;
  nome: string;
  codigo: string;
  tipo: TipoBeneficio;
  valor_diario: number;
}

/** VT e VA no formulário (tipo vazio = não escolhido) */
export interface BeneficiosColaborador {
  recebe_vt: boolean;
  tipo_vt_id: string;
  recebe_va: boolean;
  tipo_va_id: string;
}

export interface RelatorioBeneficioDia {
  data: string;
  tipo: string;
  codigo: string;
  valor_diario: number;
  batidas: { hora: string; sentido: Sentido; turno: number; manual: boolean }[];
  pre_assinalado: boolean;
  turnos: number;
  turnos_previstos: number;
  trabalhado_min: number;
  ocorrencia: string;
  escala: 'trabalho' | 'folga' | null;
  computa: boolean;
}

export interface RelatorioBeneficioItem {
  colaborador_id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  dias_marcados: number;
  dias_computados: number;
  valor_total: number;
  dias: RelatorioBeneficioDia[];
}

export interface RelatorioBeneficio {
  periodo: { inicio: string; fim: string; apurado_ate: string };
  turnos: 'um' | 'dois';
  itens: RelatorioBeneficioItem[];
}

export interface ColaboradorSituacao {
  id: string;
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  data_inicio: string;
  data_fim: string | null;
  situacao: SituacaoColaborador;
  cargo_id: string | null;
  cargo: string | null;
  departamento_id: string | null;
  departamento: string | null;
  jornada_id: string | null;
  jornada: string | null;
  perfil_evento_id: string | null;
  perfil_evento: string | null;
  salario: number | null;
  recebe_vt: boolean;
  tipo_vt_id: string | null;
  tipo_vt: string | null;
  recebe_va: boolean;
  tipo_va_id: string | null;
  tipo_va: string | null;
  motivo: string | null;
  /** A da admissão: não muda de data nem é excluída */
  primeira: boolean;
  vigente: boolean;
  futura: boolean;
  fechado: boolean;
  usuario: string | null;
  alterado_por: string | null;
  created_at: string;
  updated_at: string;
}

export interface SituacoesDados {
  situacoes: ColaboradorSituacao[];
  fechado_ate: string | null;
  colaboradores: {
    id: string; nome: string; matricula: string; situacao: SituacaoColaborador; data_admissao: string;
    departamento_id: string | null; cargo_id: string | null; jornada_id: string | null;
  }[];
  cargos: Opcao[];
  departamentos: Opcao[];
  jornadas: Opcao[];
  perfis_eventos: (Opcao & { padrao: boolean })[];
  tipos_beneficio?: OpcaoBeneficio[];
}

export type LocalPontoModo = 'empresa' | 'proprio' | 'ambos';

export interface LocalPontoProprio {
  latitude: number;
  longitude: number;
  raio_m: number;
  precisao_m: number | null;
  endereco: string | null;
}

export interface AcessoColaborador {
  usuario_id: string;
  login: string;
  status: 'ativo' | 'inativo' | 'bloqueado';
  perfil: string;
  ultimo_acesso: string | null;
}

export interface Colaborador extends BeneficiosColaborador {
  id?: string;
  /** Empresa do colaborador; vazio = a empresa em que o usuário está conectado */
  empresa_id: string;
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
  historico?: HistoricoItem[];
  /** Situações (da mais recente para a mais antiga): só se alteram na Situação do Colaborador */
  situacoes?: ColaboradorSituacao[];
  /** Onde pode bater o ponto: local da empresa, local próprio (home office) ou os dois */
  local_ponto_modo: LocalPontoModo;
  local_ponto?: LocalPontoProprio | null;
  local_empresa?: { nome: string; raio_m: number; ativo: boolean } | null;
  acesso?: AcessoColaborador | null;
}

export interface JornadaDia {
  dia_semana: number;
  folga: boolean;
  /** Dia útil (controle de DSR) e se o dia dá direito a VT e a VA; sem o campo, segue o dia de trabalho */
  dia_util?: boolean;
  recebe_vt?: boolean;
  recebe_va?: boolean;
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
  /** Como os dias se repetem — semanal: dias 0–6 (domingo = 0) · escala: ciclo 0…ciclo_dias-1 a partir de data_base */
  tipo: TipoJornada;
  /** Tipo de jornada (TIPOS_JORNADA) */
  modelo?: string | null;
  ciclo_dias: number | null;
  data_base: string | null;
  ativo: boolean;
  /** A saída e o retorno do intervalo não precisam bater no horário: vale a duração do intervalo */
  intervalo_flexivel: boolean;
  /** Intervalo pré-assinalado (Portaria 671): sem as batidas do intervalo, vale o previsto */
  intervalo_pre_assinalado: boolean;
  /** Aparece em todas as empresas (senão, só na empresa em que foi criada) */
  todas_empresas: boolean;
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
  /** Aparece em todas as empresas (senão, só na empresa em que foi criada) */
  todas_empresas: boolean;
  tolerancia_entrada_min: number;
  tolerancia_saida_min: number;
  tolerancia_diaria_min: number;
  /** 'batida': tolerância de entrada/saída em cada marcação · 'diaria': só a geral do dia */
  tolerancia_modo: 'batida' | 'diaria';
  limite_he_diario_min: number;
  usa_banco_horas: boolean;
  /** Crédito do banco multiplicado pelo percentual de hora extra do dia (feriado 100% → 8h viram 16h) */
  bh_multiplicar: boolean;
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
  situacao_dia?: SituacaoDiaBatida;
  hoje: {
    data: string;
    previsto_min: number;
    trabalhado_min: number;
    qtd_batidas: number;
    batidas: BatidaResumo[];
    jornada_dia: {
      /** Nome do feriado (sem escala de trabalho no dia) */
      feriado?: string | null;
      folga: boolean;
      entrada: string | null;
      saida_intervalo: string | null;
      retorno_intervalo: string | null;
      saida: string | null;
      intervalo_flexivel?: boolean;
      intervalo_min?: number | null;
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

/** Como a batida fica no dia: sem controle de ponto, em feriado, em folga ou null (dia normal) */
export type SituacaoDiaBatida = 'nao_controlada' | 'feriado' | 'folga' | null;

export interface RegistroPonto extends GeoBatida {
  ok: boolean;
  situacao_dia?: SituacaoDiaBatida;
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
  /** Dia sem batidas, com previsão */
  falta?: boolean;
  /** Falta levada para a folha: não foi debitada do banco */
  falta_folha?: boolean;
  fechado?: boolean;
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
  | 'nao_controlada'
  | 'ausencia'
  | 'fora_jornada'
  | 'intervalo_flexivel'
  | 'intervalo_excedido'
  | 'intervalo_reduzido'
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

/** Relatório de locais das batidas */
export interface LocalBatidaItem {
  id: string;
  data_hora: string;
  data: string;
  hora: string;
  origem: string;
  geo_status: GeoStatus;
  geo_erro: string | null;
  latitude: number | null;
  longitude: number | null;
  precisao_m: number | null;
  distancia_m: number | null;
  /** Local de ponto mais próximo */
  local: string | null;
  colaborador_id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  /** Endereço já conhecido da coordenada (null = ainda não buscado) */
  endereco: import('./enderecos').EnderecoGeo | null;
}

export interface LocaisBatidasRelatorio {
  itens: LocalBatidaItem[];
}

export interface FiltrosAux {
  /** Locais de ponto cadastrados */
  locais?: { id: string; nome: string; ativo: boolean }[];
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
  licenca_id: string | null;
  licenca: string | null;
}

export interface TipoLicencaOpcao {
  id: string;
  descricao: string;
  abona: boolean;
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
  /** Intervalo pré-assinalado (Portaria 671): saída e retorno do intervalo previstos, não batidos */
  pre_assinalado?: boolean;
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
  /** Administrador de fato: pelo perfil ou pela chave no usuário */
  is_admin: boolean;
  /** Chave "Administrador: acesso a tudo" no próprio usuário */
  administrador: boolean;
  /** Usuário master: único que entra pelo login; sempre com acesso total */
  master: boolean;
  /** O perfil é de administrador */
  perfil_admin: boolean;
  abrangencia: Abrangencia;
  colaborador_id: string | null;
  colaborador: string | null;
  matricula: string | null;
  /** Empresas de acesso (além da empresa do colaborador vinculado) */
  empresas: string[];
  empresa_colaborador: string | null;
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
  empresas: { id: string; nome: string; ativo: boolean }[];
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
  lancamento_id: string | null;
  /** Nome da escala lançada */
  nome: string | null;
}

/** Escala lançada: o registro com nome, período, dias da semana, horários e colaboradores */
/** Horário próprio de um dia da escala (os dias sem ajuste seguem o horário da escala) */
export interface HorarioEscalaDia extends HorarioDia {
  tipo: TipoEscala;
}

export interface EscalaLancamento extends HorarioDia {
  /** Horário próprio por dia: chave AAAA-MM-DD */
  horarios: Record<string, HorarioEscalaDia>;
  id: string;
  nome: string;
  tipo: TipoEscala;
  data_inicio: string;
  data_fim: string;
  dias_semana: number[];
  observacao: string | null;
  colaboradores: { id: string; nome: string; matricula: string }[];
  dias: number;
  fechado: boolean;
  lancado_por: string | null;
  lancado_em: string;
  alterado_por: string | null;
  alterado_em: string | null;
}

export interface EscalasLancamentos {
  pode_editar: boolean;
  escalas: EscalaLancamento[];
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

/** Justificativas de atraso, saída antecipada e falta */
export type TipoJustificativa = 'atraso' | 'saida_antecipada' | 'falta';

export interface Justificativa {
  id: string;
  motivo: string;
  abona: boolean;
  /** null = abona todo o tempo */
  minutos: number | null;
  observacao: string | null;
  usuario: string | null;
  atualizado_em: string;
  /** Minutos efetivamente abonados (0 quando só justifica) */
  minutos_abonados: number;
}

export interface JustificativaItem {
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  data: string;
  tipo: TipoJustificativa;
  /** Atraso/saída em minutos; na falta, a jornada prevista do dia */
  minutos: number;
  /** Primeira batida do dia (atraso) */
  hora: string | null;
  /** false: a justificativa existe, mas o evento não aparece mais na apuração (batida corrigida) */
  ocorreu: boolean;
  fechado: boolean;
  justificativa: Justificativa | null;
}

export interface JustificativasLista {
  itens: JustificativaItem[];
  motivos: string[];
}

export interface RelatorioBancoHorasItem {
  colaborador_id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  cargo: string | null;
  saldo_anterior: number;
  creditos: number;
  debitos: number;
  ajustes: number;
  conversoes: number;
  saldo_final: number;
  dias_credito: number;
  dias_debito: number;
}

export interface RelatorioBancoHoras {
  periodo: { inicio: string; fim: string };
  itens: RelatorioBancoHorasItem[];
}

export interface BancoHorasDetalheDia {
  data: string;
  horario: string | null;
  feriado: string | null;
  escala: 'trabalho' | 'folga' | null;
  /** null: dia sem apuração (hoje, futuro ou fora do controle de ponto) */
  ocorrencia: string | null;
  batidas: { hora: string; sentido: Sentido; turno: number; manual: boolean }[];
  pre_assinalado: boolean;
  previsto_min: number | null;
  trabalhado_min: number | null;
  saldo_min: number | null;
  banco_horas: boolean | null;
  /** Lançamento automático do dia (com o percentual da regra) */
  banco_min: number;
  descricao: string | null;
  /** Ajustes manuais e conversões do dia */
  lancamentos: { tipo: string; minutos: number; descricao: string | null }[];
  saldo_acumulado: number;
  fechado: boolean;
}

export interface BancoHorasDetalheItem {
  colaborador_id: string;
  nome: string;
  matricula: string;
  departamento: string | null;
  cargo: string | null;
  saldo_anterior: number;
  saldo_final: number;
  dias: BancoHorasDetalheDia[];
}

export interface RelatorioBancoHorasDetalhe {
  periodo: { inicio: string; fim: string; apurado_ate: string };
  itens: BancoHorasDetalheItem[];
}

export interface RelatorioEscalasItem {
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  data: string;
  tipo: 'trabalho' | 'folga';
  escala: string | null;
  entrada: string | null;
  saida_intervalo: string | null;
  retorno_intervalo: string | null;
  saida: string | null;
  feriado: string | null;
  previsto_min: number | null;
  trabalhado_min: number | null;
  saldo_min: number | null;
  qtd_batidas: number | null;
  falta: boolean | null;
  he_percentual: number | null;
  /** O dia já passou (tem apuração) */
  realizado: boolean;
}

export interface RelatorioEscalas {
  periodo: { inicio: string; fim: string };
  itens: RelatorioEscalasItem[];
}

export interface RelatorioNoturnoItem {
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  data: string;
  horario: string | null;
  trabalhado_min: number;
  noturno_min: number;
  noturno_reduzido_min: number;
  percentual: number;
  faixa: string;
  reduzida: boolean;
}

export interface RelatorioFolgasItem {
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  data: string;
  origem: 'jornada' | 'escala' | 'ocorrencia';
  feriado: string | null;
  trabalhou: boolean;
  trabalhado_min: number;
  extra_min: number;
  he_percentual: number;
  realizado: boolean;
}

export interface RelatorioFaltasItem {
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  data: string;
  horario: string | null;
  previsto_min: number;
  situacao: 'injustificada' | 'justificada' | 'abonada';
  motivo: string | null;
  abonado_min: number;
  /** Falta descontada na folha (não vai para o banco de horas) */
  folha: boolean;
  fechado: boolean;
}

export interface RelatorioAssiduidadeItem {
  colaborador_id: string;
  colaborador: string;
  matricula: string;
  departamento: string | null;
  dias_previstos: number;
  dias_trabalhados: number;
  faltas: number;
  faltas_abonadas: number;
  dias_ausencia: number;
  atrasos: number;
  atraso_min: number;
  saidas_antecipadas: number;
  saida_antecipada_min: number;
  dias_com_ocorrencia: number;
}

export interface RelatorioColaboradorItem {
  colaborador_id: string;
  matricula: string;
  nome: string;
  nome_social: string | null;
  cpf: string;
  pis: string | null;
  rg: string | null;
  data_nascimento: string | null;
  sexo: 'M' | 'F' | 'O' | null;
  email: string | null;
  telefone: string | null;
  cep: string | null;
  logradouro: string | null;
  numero: string | null;
  complemento: string | null;
  bairro: string | null;
  cidade: string | null;
  uf: string | null;
  empresa: string | null;
  cargo: string | null;
  cbo: string | null;
  departamento: string | null;
  jornada: string | null;
  regra: string | null;
  gestor: string | null;
  data_admissao: string;
  data_desligamento: string | null;
  situacao: 'ativo' | 'afastado' | 'ferias' | 'desligado';
  salario: number | null;
  controla_ponto: boolean;
  controle_ponto_inicio: string | null;
  local_ponto_modo: string | null;
  usuario: string | null;
  observacoes: string | null;
}

export interface RelatorioPeriodo<T> {
  periodo: { inicio: string; fim: string };
  itens: T[];
}

export type AcaoAuditoria = 'inclusao' | 'alteracao' | 'exclusao' | 'login' | 'login_falha';

export interface AuditoriaItem {
  id: number;
  data_hora: string;
  usuario_id: string | null;
  usuario: string | null;
  tabela: string;
  registro_id: string | null;
  acao: AcaoAuditoria;
  colaborador_id: string | null;
  colaborador: string | null;
  descricao: string | null;
  campos: string[] | null;
  antes: Record<string, unknown> | null;
  depois: Record<string, unknown> | null;
}

export interface AuditoriaConsulta {
  itens: AuditoriaItem[];
  limite: number;
  usuarios: { id: string; nome: string }[];
  tabelas: string[];
}
