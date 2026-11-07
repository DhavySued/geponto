import { formatData, formatMinutos } from './format';
import { ORIGEM_BATIDA, ocorrencia, rotuloMarcacao, siglaMarcacao } from './ponto';
import type { BancoHorasDetalhe, BancoHorasDia } from './types';

// Cores da marca (tailwind.config: primary-700, slate-700, accent-700, rose-600)
const AZUL: [number, number, number] = [0, 35, 106];
const TARJA: [number, number, number] = [51, 65, 85];
const CINZA: [number, number, number] = [100, 116, 139];
const CREDITO: [number, number, number] = [36, 67, 143];
const DEBITO: [number, number, number] = [166, 95, 0];
const VERMELHO: [number, number, number] = [225, 29, 72];

const dataBR = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });
const horas = (min: number | null | undefined) => (min == null ? '—' : min === 0 ? '0h00' : formatMinutos(min, true));
const corMin = (min: number | null | undefined) => (min == null || min === 0 ? CINZA : min > 0 ? CREDITO : DEBITO);

const TIPOS_LANCAMENTO: Record<string, string> = {
  credito: 'Crédito',
  debito: 'Débito',
  compensacao: 'Compensação',
  ajuste: 'Ajuste',
  conversao: 'Conversão',
};

/**
 * Gera o relatório do banco de horas em PDF (uma tarja por colaborador e uma seção por dia,
 * com previsto × realizado de cada marcação, o resultado de cada turno e o saldo) e baixa o arquivo.
 */
export async function gerarPdfBancoHoras(dados: BancoHorasDetalhe[], periodo: { ini: string; fim: string }) {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([import('jspdf'), import('jspdf-autotable')]);
  const doc = new jsPDF({ unit: 'mm', format: 'a4' });
  const M = 12;
  const largura = doc.internal.pageSize.getWidth() - 2 * M;
  const altura = doc.internal.pageSize.getHeight();
  const emitido = new Date().toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' });
  let y = M;

  const fimDaTabela = () => (doc as unknown as { lastAutoTable: { finalY: number } }).lastAutoTable.finalY;
  const garantirEspaco = (mm: number) => {
    if (y + mm > altura - M) {
      doc.addPage();
      y = M;
    }
  };

  dados.forEach((c, i) => {
    if (i > 0) {
      doc.addPage();
      y = M;
    }

    // Cabeçalho do relatório
    doc.setFont('helvetica', 'bold').setFontSize(13).setTextColor(...AZUL);
    doc.text('Banco de horas — relatório diário', M, y + 4);
    doc.setFont('helvetica', 'normal').setFontSize(8).setTextColor(...CINZA);
    doc.text(`Período ${dataBR(periodo.ini)} a ${dataBR(periodo.fim)} · emitido em ${emitido}`, M, y + 9);
    y += 13;

    // Tarja do colaborador
    doc.setFillColor(...AZUL).rect(M, y, largura, 14, 'F');
    doc.setTextColor(255, 255, 255).setFont('helvetica', 'bold').setFontSize(11);
    doc.text(c.nome, M + 3, y + 6);
    doc.setFont('helvetica', 'normal').setFontSize(7.5);
    doc.text([`Mat. ${c.matricula}`, c.departamento, c.jornada].filter(Boolean).join(' · '), M + 3, y + 11);
    const resumo: [string, number][] = [
      ['Saldo anterior', c.saldo_anterior],
      ['Créditos', c.creditos],
      ['Débitos', c.debitos],
      ['Saldo final', c.saldo_final],
    ];
    resumo.forEach(([rotulo, v], k) => {
      const x = M + largura - 3 - (resumo.length - 1 - k) * 26;
      doc.setFontSize(6.5).setFont('helvetica', 'normal').text(rotulo, x, y + 5, { align: 'right' });
      doc.setFontSize(k === 3 ? 10 : 8.5).setFont('helvetica', 'bold').text(horas(v), x, y + 11, { align: 'right' });
    });
    y += 18;

    if (c.dias.length === 0) {
      doc.setTextColor(...CINZA).setFontSize(9).setFont('helvetica', 'normal');
      doc.text('Sem dias com previsão ou movimento no período.', M, y + 4);
      return;
    }

    c.dias.forEach((d) => {
      garantirEspaco(30);
      desenharDia(d);
      y = fimDaTabela() + 4;
    });
  });

  function desenharDia(d: BancoHorasDia) {
    const oc = ocorrencia(d.ocorrencia).label;
    const hoje = d.ocorrencia === 'em_andamento';
    const linhas = d.linhas ?? [];
    const corpo: { content: string; styles?: Record<string, unknown>; colSpan?: number }[][] = [];

    for (const t of d.turnos ?? []) {
      for (const l of linhas.filter((x) => x.turno === t.turno)) {
        corpo.push([
          { content: `${siglaMarcacao(l.sentido, l.turno)}  ${rotuloMarcacao(l.sentido, l.turno)}` },
          { content: l.previsto ?? '—', styles: { halign: 'center' } },
          l.hora
            ? { content: l.hora, styles: { halign: 'center', fontStyle: 'bold' } }
            : { content: hoje ? 'Aguardando' : 'Não realizada', styles: { halign: 'center', textColor: hoje ? CINZA : VERMELHO } },
          { content: l.origem ? (ORIGEM_BATIDA[l.origem] ?? l.origem) : '—' },
          { content: t.completo ? horas(l.gerou_min) : '—', styles: { halign: 'right', textColor: corMin(t.completo ? l.gerou_min : null) } },
        ]);
      }
      const aberto = hoje && !t.completo;
      corpo.push([
        {
          content:
            `${t.turno}º turno ${t.completo ? 'completo' : aberto ? 'em andamento' : 'não fechado — não computado; o previsto vira débito'}` +
            `   (previsto ${formatMinutos(t.previsto_min)} · trabalhado ${formatMinutos(t.trabalhado_min)})`,
          colSpan: 4,
          styles: {
            fontSize: 7,
            fillColor: t.completo || aberto ? [248, 250, 252] : [255, 241, 242],
            textColor: t.completo || aberto ? CINZA : VERMELHO,
          },
        },
        {
          content: aberto ? '—' : horas(t.gerou_min),
          styles: { halign: 'right', fontStyle: 'bold', fillColor: t.completo || aberto ? [248, 250, 252] : [255, 241, 242], textColor: corMin(aberto ? null : t.gerou_min) },
        },
      ]);
    }
    for (const l of d.lancamentos ?? []) {
      corpo.push([
        { content: `Lançamento: ${TIPOS_LANCAMENTO[l.tipo] ?? l.tipo}${l.descricao ? ` · ${l.descricao}` : ''}`, colSpan: 4, styles: { fillColor: [245, 243, 255] } },
        { content: horas(l.minutos), styles: { halign: 'right', fillColor: [245, 243, 255], textColor: corMin(l.minutos) } },
      ]);
    }
    if (corpo.length === 0) {
      corpo.push([{ content: d.ocorrencia.startsWith('ausencia:') ? `${oc} — sem marcações previstas` : 'Sem marcações', colSpan: 5, styles: { halign: 'center', textColor: CINZA } }]);
    }

    const lancado = (d.lancamentos ?? []).reduce((s, l) => s + l.minutos, 0);
    const dia = `${formatData(d.data, { weekday: 'long' })} · ${dataBR(d.data)}`;

    autoTable(doc, {
      startY: y,
      margin: { left: M, right: M },
      theme: 'grid',
      styles: { fontSize: 7.5, cellPadding: 1.4, lineColor: [226, 232, 240], lineWidth: 0.2, textColor: [30, 41, 59] },
      head: [
        [
          {
            content: `${dia.charAt(0).toUpperCase()}${dia.slice(1)}      ${d.horario_previsto ?? 'Sem horário previsto'}`,
            colSpan: 4,
            styles: { fillColor: TARJA, textColor: 255, fontStyle: 'bold', fontSize: 8.5 },
          },
          { content: oc, styles: { fillColor: TARJA, textColor: 255, halign: 'right', fontSize: 7.5 } },
        ],
        ['Marcação', 'Previsto', 'Realizado', 'Origem', 'Gerou'].map((h, k) => ({
          content: h,
          styles: { fillColor: [241, 245, 249], textColor: CINZA, fontSize: 6.5, halign: k === 1 || k === 2 ? 'center' : k === 4 ? 'right' : 'left' },
        })),
      ],
      body: corpo,
      foot: [
        [
          { content: `Previsto ${formatMinutos(d.previsto_min)}`, styles: { fontStyle: 'normal' } },
          { content: `Trabalhado ${formatMinutos(d.trabalhado_min)}`, colSpan: 2, styles: { fontStyle: 'normal' } },
          { content: `Saldo do dia ${horas(d.saldo_dia + lancado)}`, styles: { textColor: corMin(d.saldo_dia + lancado) } },
          { content: `Acumulado ${horas(d.acumulado)}`, styles: { halign: 'right', textColor: corMin(d.acumulado) } },
        ],
      ],
      footStyles: { fillColor: [248, 250, 252], textColor: [30, 41, 59], fontStyle: 'bold', fontSize: 7.5 },
      columnStyles: { 0: { cellWidth: 58 }, 1: { cellWidth: 24 }, 2: { cellWidth: 28 }, 4: { cellWidth: 26 } },
      rowPageBreak: 'avoid',
      showHead: 'firstPage',
      showFoot: 'lastPage',
    });
  }

  // Numeração das páginas
  const total = doc.getNumberOfPages();
  for (let p = 1; p <= total; p++) {
    doc.setPage(p);
    doc.setFont('helvetica', 'normal').setFontSize(7).setTextColor(...CINZA);
    doc.text(`GePonto · página ${p} de ${total}`, M + largura, altura - 6, { align: 'right' });
  }

  doc.save(`banco-de-horas_${periodo.ini}_${periodo.fim}.pdf`);
}
