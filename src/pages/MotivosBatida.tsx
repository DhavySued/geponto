import { ListChecks } from 'lucide-react';
import { CadastroTipos, type ItemTipo } from '@/components/cadastros/CadastroTipos';
import { Field } from '@/components/ui/Field';

type Aplicacao = 'inclusao' | 'desconsideracao' | 'ambos';
interface Motivo extends ItemTipo {
  aplicacao: Aplicacao;
}

const APLICACAO: Record<Aplicacao, string> = {
  inclusao: 'Inclusão de batida',
  desconsideracao: 'Desconsideração de batida',
  ambos: 'Inclusão e desconsideração',
};

export default function MotivosBatida() {
  return (
    <CadastroTipos<Motivo>
      pagina="motivos_batida"
      titulo="Motivos de batida"
      descricao="Motivos usados ao incluir ou desconsiderar batidas. Um motivo já usado não pode ser excluído: desative-o."
      icon={ListChecks}
      nomeItem="motivo"
      rpc={{ listar: 'api_motivos_batida_listar', salvar: 'api_motivo_batida_salvar', excluir: 'api_motivo_batida_excluir' }}
      novo={() => ({ descricao: '', aplicacao: 'ambos', ativo: true })}
      colunas={[{ titulo: 'Usado em', valor: (i) => APLICACAO[i.aplicacao] }]}
      campos={(f, set) => (
        <Field label="Usado em" obrigatorio>
          <select className="input" value={f.aplicacao} onChange={(e) => set('aplicacao', e.target.value)}>
            {Object.entries(APLICACAO).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </select>
        </Field>
      )}
    />
  );
}
