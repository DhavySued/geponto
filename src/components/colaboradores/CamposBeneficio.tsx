import { Field, Switch } from '@/components/ui/Field';
import { formatMoeda } from '@/lib/format';
import type { BeneficiosColaborador, OpcaoBeneficio, TipoBeneficio } from '@/lib/types';

const TITULO: Record<TipoBeneficio, string> = { vt: 'Recebe VT', va: 'Recebe VA' };
const DESCRICAO: Record<TipoBeneficio, string> = { vt: 'Vale-transporte', va: 'Vale-alimentação' };

/** "Recebe VT" e "Recebe VA", cada um com o tipo (habilitado quando marcado) */
export function CamposBeneficio({
  valor,
  tipos,
  nomes,
  desabilitado = false,
  onChange,
}: {
  valor: BeneficiosColaborador;
  tipos: OpcaoBeneficio[];
  /** Nome do tipo atual, para quando ele já foi desativado */
  nomes?: { vt?: string | null; va?: string | null };
  desabilitado?: boolean;
  onChange: (v: Partial<BeneficiosColaborador>) => void;
}) {
  return (
    <div className="grid gap-4 sm:col-span-2 sm:grid-cols-2">
      {(['vt', 'va'] as TipoBeneficio[]).map((t) => {
        const recebe = valor[`recebe_${t}`];
        const id = valor[`tipo_${t}_id`];
        const lista = tipos.filter((o) => o.tipo === t);
        return (
          <div key={t} className="rounded-xl p-3 ring-1 ring-slate-200/80">
            <Switch ativo={recebe} onChange={(v) => onChange({ [`recebe_${t}`]: v, ...(v ? {} : { [`tipo_${t}_id`]: '' }) })}
              label={TITULO[t]} descricao={DESCRICAO[t]} />
            <Field label={`Tipo de ${t.toUpperCase()}`} obrigatorio={recebe}
              dica={recebe && lista.length === 0 ? 'Nenhum tipo ativo. Cadastre em Cadastros › Tipos › Tipos de VT e VA.' : undefined}>
              <select className="input" value={id} disabled={!recebe || desabilitado}
                onChange={(e) => onChange({ [`tipo_${t}_id`]: e.target.value })}>
                <option value="">{recebe ? 'Selecione…' : 'Não recebe'}</option>
                {id && !lista.some((o) => o.id === id) && <option value={id}>{nomes?.[t] ?? 'Atual'} (inativo)</option>}
                {lista.map((o) => <option key={o.id} value={o.id}>{o.codigo} · {o.nome} ({formatMoeda(Number(o.valor_diario))}/dia)</option>)}
              </select>
            </Field>
          </div>
        );
      })}
    </div>
  );
}

/** Aviso quando marcou que recebe e não escolheu o tipo */
export function erroBeneficio(v: BeneficiosColaborador): string | null {
  if (v.recebe_vt && !v.tipo_vt_id) return 'Escolha o tipo de VT do colaborador.';
  if (v.recebe_va && !v.tipo_va_id) return 'Escolha o tipo de VA do colaborador.';
  return null;
}
