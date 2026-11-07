import clsx from 'clsx';
import { formatData, formatMinutos } from '@/lib/format';
import { ocorrencia } from '@/lib/ponto';
import type { EspelhoColaborador, EspelhoPonto } from '@/lib/types';

const dataCurta = (s: string) => formatData(s, { day: '2-digit', month: '2-digit', year: 'numeric' });
const h = (min: number) => (min ? formatMinutos(min) : '');

function cnpj(v: string | null) {
  const d = (v ?? '').replace(/\D/g, '');
  return d.length === 14 ? d.replace(/^(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})$/, '$1.$2.$3/$4-$5') : (v ?? '—');
}

function cpf(v: string | null) {
  const d = (v ?? '').replace(/\D/g, '');
  return d.length === 11 ? d.replace(/^(\d{3})(\d{3})(\d{3})(\d{2})$/, '$1.$2.$3-$4') : (v ?? '—');
}

function Info({ rotulo, valor, className }: { rotulo: string; valor: string; className?: string }) {
  return (
    <div className={className}>
      <dt className="text-[10px] uppercase tracking-wide text-slate-400">{rotulo}</dt>
      <dd className="truncate text-xs font-medium text-slate-800">{valor}</dd>
    </div>
  );
}

function Folha({ dados, e }: { dados: EspelhoPonto; e: EspelhoColaborador }) {
  const t = e.totais;
  const c = e.colaborador;
  return (
    <article className="card overflow-hidden p-6 print:break-after-page print:last:break-after-auto print:rounded-none print:p-0 print:shadow-none print:ring-0">
      <header className="flex flex-wrap items-start justify-between gap-4 border-b border-slate-200 pb-4">
        <div>
          <p className="text-[10px] font-semibold uppercase tracking-[0.12em] text-primary-600">Espelho de ponto</p>
          <h3 className="text-base font-semibold text-slate-900">{dados.empresa.razao_social}</h3>
          <p className="text-xs text-slate-500">
            CNPJ {cnpj(dados.empresa.cnpj)}
            {dados.empresa.endereco && ` · ${dados.empresa.endereco}`}
          </p>
        </div>
        <div className="text-right text-xs text-slate-500">
          <p className="font-semibold text-slate-800">
            {dataCurta(dados.periodo.inicio)} a {dataCurta(dados.periodo.fim)}
          </p>
          <p>Emitido em {new Date(dados.emitido_em).toLocaleString('pt-BR', { dateStyle: 'short', timeStyle: 'short' })}</p>
        </div>
      </header>

      <dl className="grid grid-cols-2 gap-x-6 gap-y-2 border-b border-slate-200 py-4 sm:grid-cols-4">
        <Info rotulo="Empregado" valor={c.nome} className="col-span-2" />
        <Info rotulo="Matrícula" valor={c.matricula} />
        <Info rotulo="Admissão" valor={dataCurta(c.admissao)} />
        <Info rotulo="CPF" valor={cpf(c.cpf)} />
        <Info rotulo="PIS" valor={c.pis ?? '—'} />
        <Info rotulo="Cargo" valor={c.cargo ?? '—'} />
        <Info rotulo="Departamento" valor={c.departamento ?? '—'} />
        <Info rotulo="Jornada" valor={e.jornadas.map((j) => j.nome).join(' / ') || '—'} className="col-span-2 sm:col-span-4" />
      </dl>

      <div className="overflow-x-auto">
        <table className="w-full min-w-[860px] text-[11px] leading-tight print:min-w-0">
          <thead>
            <tr className="border-b border-slate-200 text-left text-[10px] uppercase tracking-wide text-slate-400">
              <th className="py-2 pr-2 font-medium">Dia</th>
              <th className="py-2 pr-2 font-medium">Horário previsto</th>
              <th className="py-2 pr-2 font-medium">Marcações</th>
              <th className="py-2 pr-2 text-right font-medium">Trab.</th>
              <th className="py-2 pr-2 text-right font-medium">Extras</th>
              <th className="py-2 pr-2 text-right font-medium">Faltas/Déb.</th>
              <th className="py-2 pr-2 text-right font-medium">Atraso</th>
              <th className="py-2 pr-2 text-right font-medium">Noturno</th>
              <th className="py-2 font-medium">Ocorrência</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {e.dias.map((d) => {
              const oc = ocorrencia(d.ocorrencia);
              return (
                <tr key={d.data} className={clsx(!d.previsto && 'bg-slate-50/70 print:bg-transparent')}>
                  <td className="whitespace-nowrap py-1.5 pr-2 tabular-nums text-slate-700">
                    <span className="inline-block w-8 capitalize text-slate-400">{formatData(d.data, { weekday: 'short' }).replace('.', '')}</span>
                    {formatData(d.data)}
                  </td>
                  <td className="whitespace-nowrap py-1.5 pr-2 tabular-nums text-slate-500">{d.previsto ?? 'Folga'}</td>
                  <td className="py-1.5 pr-2 tabular-nums">
                    <span className="flex flex-wrap gap-x-2">
                      {d.batidas.length === 0 && <span className="text-slate-300">—</span>}
                      {d.batidas.map((b) => (
                        <span
                          key={b.id}
                          title={b.motivo ?? undefined}
                          className={clsx(
                            b.status === 'incluida' && 'font-semibold text-blue-700',
                            b.status === 'desconsiderada' && 'text-rose-600 line-through',
                            b.status === 'original' && 'text-slate-800',
                          )}
                        >
                          {b.hora}
                          {b.status === 'incluida' && <sup className="ml-px">I</sup>}
                          {b.status === 'desconsiderada' && <sup className="ml-px no-underline">D</sup>}
                        </span>
                      ))}
                    </span>
                  </td>
                  <td className="py-1.5 pr-2 text-right tabular-nums text-slate-800">{h(d.trabalhado_min)}</td>
                  <td className="py-1.5 pr-2 text-right tabular-nums text-primary-700">
                    {h(d.extra_min)}
                    {d.extra_min > 0 && d.banco_horas && <sup className="ml-px text-slate-400">BH</sup>}
                  </td>
                  <td className="py-1.5 pr-2 text-right tabular-nums text-accent-700">
                    {h(d.debito_min)}
                    {d.debito_min > 0 && d.banco_horas && <sup className="ml-px text-slate-400">BH</sup>}
                  </td>
                  <td className="py-1.5 pr-2 text-right tabular-nums text-slate-600">{h(d.atraso_min + d.saida_antecipada_min)}</td>
                  <td className="py-1.5 pr-2 text-right tabular-nums text-slate-600">{h(d.noturno_min)}</td>
                  <td className="py-1.5 text-slate-600">
                    {!['normal', 'folga', 'em_andamento'].includes(d.ocorrencia) && <span className="font-medium">{oc.label}</span>}
                    {d.abonado_min > 0 && <span className="ml-1 text-slate-400">abono {formatMinutos(d.abonado_min)}</span>}
                    {d.observacao && <span className="block max-w-[220px] truncate text-[10px] text-slate-400">{d.observacao}</span>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <section className="mt-4 grid gap-4 border-t border-slate-200 pt-4 lg:grid-cols-[2fr_1fr] print:grid-cols-[2fr_1fr]">
        <dl className="grid grid-cols-3 gap-x-6 gap-y-2 sm:grid-cols-5 print:grid-cols-5">
          <Info rotulo="Previsto" valor={formatMinutos(t.previsto_min)} />
          <Info rotulo="Trabalhado" valor={formatMinutos(t.trabalhado_min)} />
          <Info rotulo="HE dia útil" valor={formatMinutos(t.he_util_min)} />
          <Info rotulo="HE folga/feriado" valor={formatMinutos(t.he_especial_min)} />
          <Info rotulo="Adic. noturno" valor={formatMinutos(t.noturno_min)} />
          <Info rotulo="Faltas" valor={`${t.faltas} dia(s)`} />
          <Info rotulo="Horas a descontar" valor={formatMinutos(t.debito_min)} />
          <Info rotulo="Atrasos" valor={formatMinutos(t.atraso_min)} />
          <Info rotulo="Saídas antecipadas" valor={formatMinutos(t.saida_antecipada_min)} />
          <Info rotulo="Abonado" valor={formatMinutos(t.abonado_min)} />
        </dl>
        <dl className="grid grid-cols-2 gap-x-6 gap-y-2 rounded-xl bg-slate-50 p-3 print:bg-transparent print:p-0">
          <Info rotulo="Banco: saldo anterior" valor={formatMinutos(e.banco_horas.anterior, true)} />
          <Info rotulo="Créditos no período" valor={formatMinutos(e.banco_horas.creditos, true)} />
          <Info rotulo="Débitos no período" valor={formatMinutos(e.banco_horas.debitos, true)} />
          <Info rotulo="Saldo final" valor={formatMinutos(e.banco_horas.saldo, true)} />
        </dl>
      </section>

      <p className="mt-4 text-[10px] text-slate-400">
        Marcações: preto = original do registro · <span className="text-blue-700">azul ᴵ = incluída no tratamento</span> ·{' '}
        <span className="text-rose-600 line-through">vermelho ᴰ</span> = desconsiderada (mantida no registro) · BH = vai para o banco de horas.
      </p>

      <footer className="mt-10 grid grid-cols-2 gap-10 text-center text-[11px] text-slate-500">
        <div className="border-t border-slate-400 pt-1.5">{c.nome}</div>
        <div className="border-t border-slate-400 pt-1.5">{dados.empresa.razao_social}</div>
      </footer>
    </article>
  );
}

/** Espelho de ponto pronto para impressão/PDF: uma página por colaborador. */
export function EspelhoImpressao({ dados }: { dados: EspelhoPonto }) {
  return (
    <div className="space-y-6 print:space-y-0">
      {dados.espelhos.map((e) => (
        <Folha key={e.colaborador.id} dados={dados} e={e} />
      ))}
    </div>
  );
}
