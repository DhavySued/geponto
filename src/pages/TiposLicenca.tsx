import { FileHeart } from 'lucide-react';
import { CadastroTipos, type ItemTipo } from '@/components/cadastros/CadastroTipos';
import { Switch } from '@/components/ui/Field';

interface TipoLicenca extends ItemTipo {
  abona: boolean;
}

export default function TiposLicenca() {
  return (
    <CadastroTipos<TipoLicenca>
      pagina="tipos_licenca"
      titulo="Tipos de licença"
      descricao="Licenças usadas nos afastamentos (maternidade, INSS, acidente de trabalho…). Um tipo já lançado não pode ser excluído: desative-o."
      icon={FileHeart}
      nomeItem="tipo de licença"
      rpc={{ listar: 'api_tipos_licenca_listar', salvar: 'api_tipo_licenca_salvar', excluir: 'api_tipo_licenca_excluir' }}
      novo={() => ({ descricao: '', abona: true, ativo: true })}
      colunas={[{ titulo: 'Abona', valor: (i) => (i.abona ? 'Sim' : 'Não') }]}
      campos={(f, set) => (
        <Switch ativo={f.abona} onChange={(v) => set('abona', v)} label="Abona a jornada"
          descricao="Sugestão para o afastamento: os dias não geram falta nem débito no banco de horas." />
      )}
    />
  );
}
