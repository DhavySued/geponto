import { Wallet } from 'lucide-react';
import { CadastroTipos, type ItemTipo } from '@/components/cadastros/CadastroTipos';
import { Badge } from '@/components/ui/Badge';
import { Field } from '@/components/ui/Field';
import { formatMoeda } from '@/lib/format';
import type { TipoBeneficio } from '@/lib/types';

interface ItemBeneficio extends ItemTipo {
  codigo: string;
  tipo: TipoBeneficio;
  valor_diario: string | number;
}

export default function TiposBeneficio() {
  return (
    <CadastroTipos<ItemBeneficio>
      pagina="tipos_beneficio"
      titulo="Tipos de VT e VA"
      descricao="Vale-transporte e vale-alimentação, com o valor por dia. O tipo de cada colaborador é escolhido no cadastro ou na Situação do Colaborador."
      icon={Wallet}
      nomeItem="tipo"
      rotuloDescricao="Nome"
      rotuloUso="Colaboradores"
      rpc={{ listar: 'api_tipos_beneficio_listar', salvar: 'api_tipo_beneficio_salvar', excluir: 'api_tipo_beneficio_excluir' }}
      novo={() => ({ descricao: '', codigo: '', tipo: 'vt', valor_diario: '', ativo: true })}
      colunas={[
        { titulo: 'Código', valor: (i) => i.codigo },
        { titulo: 'Tipo', valor: (i) => <Badge tone={i.tipo === 'vt' ? 'blue' : 'violet'} dot={false}>{i.tipo.toUpperCase()}</Badge> },
        { titulo: 'Valor diário', valor: (i) => <span className="tabular-nums">{formatMoeda(Number(i.valor_diario))}</span> },
      ]}
      campos={(f, set) => (
        <div className="grid gap-4 sm:grid-cols-3">
          <Field label="Código" obrigatorio>
            <input className="input" value={f.codigo} onChange={(e) => set('codigo', e.target.value)} />
          </Field>
          <Field label="VT ou VA" obrigatorio>
            <select className="input" value={f.tipo} onChange={(e) => set('tipo', e.target.value)}>
              <option value="vt">VT — vale-transporte</option>
              <option value="va">VA — vale-alimentação</option>
            </select>
          </Field>
          <Field label="Valor diário (R$)" obrigatorio>
            <input className="input tabular-nums" inputMode="decimal" placeholder="0,00"
              value={typeof f.valor_diario === 'number' ? f.valor_diario.toFixed(2).replace('.', ',') : f.valor_diario}
              onChange={(e) => set('valor_diario', e.target.value.replace(/[^\d.,]/g, ''))} />
          </Field>
        </div>
      )}
    />
  );
}
