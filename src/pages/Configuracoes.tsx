import clsx from 'clsx';
import { AlertTriangle, CheckCircle2, Info, MapPin, MapPinOff, ShieldAlert, ShieldCheck } from 'lucide-react';
import { useCallback, useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { Button } from '@/components/ui/Button';
import { Switch } from '@/components/ui/Field';
import { useToast } from '@/components/ui/Toast';
import { textoDistancia } from '@/lib/geo';
import { api } from '@/lib/api';
import type { Configuracoes as ConfiguracoesDados } from '@/lib/types';

export default function Configuracoes() {
  const toast = useToast();
  const [dados, setDados] = useState<ConfiguracoesDados | null>(null);
  const [form, setForm] = useState({ usar_limitacoes_ponto: false, bloquear_fora_cerca: false, beneficio_turnos: 'um' as 'um' | 'dois' });
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  const carregar = useCallback(async () => {
    try {
      setErro(null);
      const d = await api<ConfiguracoesDados>('api_configuracoes');
      setDados(d);
      setForm({ usar_limitacoes_ponto: d.usar_limitacoes_ponto, bloquear_fora_cerca: d.bloquear_fora_cerca, beneficio_turnos: d.beneficio_turnos ?? 'um' });
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao carregar as configurações.');
    }
  }, []);

  useEffect(() => {
    carregar();
  }, [carregar]);

  const alterado = !!dados && (form.usar_limitacoes_ponto !== dados.usar_limitacoes_ponto || form.bloquear_fora_cerca !== dados.bloquear_fora_cerca
    || form.beneficio_turnos !== (dados.beneficio_turnos ?? 'um'));

  const salvar = async () => {
    setSalvando(true);
    try {
      await api('api_configuracoes_salvar', { p_dados: form });
      toast('Configurações salvas.');
      carregar();
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao salvar.', 'erro');
    } finally {
      setSalvando(false);
    }
  };

  const semLocal = dados?.empresas.filter((e) => !e.tem_local) ?? [];
  const opcao = (ativo: boolean) =>
    clsx('flex cursor-pointer items-start gap-3 rounded-xl p-4 ring-1 transition',
      ativo ? 'bg-primary-50/60 ring-primary-300' : 'ring-slate-200 hover:bg-slate-50');

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Registro de ponto, VT e VA</h2>
        <p className="mt-1 text-sm text-slate-500">Regras para o colaborador registrar o ponto pelo sistema (Meu Ponto e tela de login) e para contar os dias de VT e VA.</p>
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {!dados ? (
        !erro && <div className="card h-64 animate-pulse" />
      ) : (
        <section className="card space-y-5 p-6">
          <fieldset disabled={!dados.pode_editar} className="space-y-5">
            <Switch
              ativo={form.usar_limitacoes_ponto}
              onChange={(v) => setForm((f) => ({ ...f, usar_limitacoes_ponto: v }))}
              label="Usar limitações para registro de ponto?"
              descricao="Ligue se a empresa quer usar a cerca virtual nas batidas: a localização do colaborador é comparada com o local de ponto da empresa (cadastrado em Configurações › Empresas)."
            />

            <div className="flex gap-3 rounded-xl bg-slate-50 p-4 text-xs leading-relaxed text-slate-600">
              <Info className="mt-0.5 h-4 w-4 shrink-0 text-primary-600" />
              <div className="space-y-1.5">
                <p>
                  <strong className="font-semibold text-slate-700">Desligado:</strong> o ponto pode ser batido de qualquer lugar. A localização
                  continua sendo guardada com a batida (aparece na consulta e no relatório Locais das Batidas), mas não é conferida.
                </p>
                <p>
                  <strong className="font-semibold text-slate-700">Ligado:</strong> cada batida é comparada com o local de ponto da empresa em que o
                  colaborador entrou. Escolha abaixo o que acontece quando ele está fora da área permitida.
                </p>
              </div>
            </div>

            {form.usar_limitacoes_ponto && (
              <div className="grid gap-3 md:grid-cols-2">
                <label className={opcao(!form.bloquear_fora_cerca)}>
                  <input type="radio" name="modo" className="mt-1 accent-primary-700" checked={!form.bloquear_fora_cerca}
                    onChange={() => setForm((f) => ({ ...f, bloquear_fora_cerca: false }))} />
                  <span>
                    <span className="flex items-center gap-1.5 text-sm font-semibold text-slate-800">
                      <ShieldCheck className="h-4 w-4 text-emerald-600" /> Registrar e sinalizar
                    </span>
                    <span className="mt-1 block text-xs text-slate-500">
                      A batida fora da área (ou sem localização) é registrada normalmente e fica marcada como “fora do local” para o RH conferir
                      na Consulta de Batidas, na Quebra de Regras e em Locais das Batidas.
                    </span>
                  </span>
                </label>
                <label className={opcao(form.bloquear_fora_cerca)}>
                  <input type="radio" name="modo" className="mt-1 accent-primary-700" checked={form.bloquear_fora_cerca}
                    onChange={() => setForm((f) => ({ ...f, bloquear_fora_cerca: true }))} />
                  <span>
                    <span className="flex items-center gap-1.5 text-sm font-semibold text-slate-800">
                      <ShieldAlert className="h-4 w-4 text-accent-600" /> Bloquear fora da área
                    </span>
                    <span className="mt-1 block text-xs text-slate-500">
                      O sistema só aceita a batida dentro do raio do local de ponto, e exige que o navegador informe a localização.
                      Fora da área, o colaborador vê a distância e não consegue registrar.
                    </span>
                  </span>
                </label>
              </div>
            )}

            {form.usar_limitacoes_ponto && form.bloquear_fora_cerca && (
              <p className="flex gap-2 rounded-xl bg-amber-50 p-3 text-xs text-amber-900 ring-1 ring-amber-200">
                <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
                O bloqueio impede o registro de quem está fora do local (trabalho externo, GPS impreciso, permissão negada). A Portaria 671
                prevê que a marcação não seja impedida: use o bloqueio só se a política da empresa permitir, e mantenha o Tratamento de
                Batidas para os ajustes.
              </p>
            )}
          </fieldset>

          {form.usar_limitacoes_ponto && (
            <div className="space-y-2 border-t border-slate-100 pt-4">
              <h3 className="text-sm font-semibold text-slate-800">Local de ponto das empresas</h3>
              <ul className="divide-y divide-slate-100 rounded-xl ring-1 ring-slate-200">
                {dados.empresas.map((e) => (
                  <li key={e.id} className="flex items-center justify-between gap-3 px-4 py-2.5 text-sm">
                    <span className="truncate text-slate-700">{e.nome}</span>
                    {e.tem_local ? (
                      <span className="flex items-center gap-1.5 text-xs text-emerald-700">
                        <MapPin className="h-3.5 w-3.5" /> raio de {textoDistancia(e.raio_m ?? 0)}
                      </span>
                    ) : (
                      <span className="flex items-center gap-1.5 text-xs text-accent-700">
                        <MapPinOff className="h-3.5 w-3.5" /> sem local: as batidas não são conferidas
                      </span>
                    )}
                  </li>
                ))}
              </ul>
              {semLocal.length > 0 && (
                <p className="text-xs text-slate-500">
                  Cadastre o local em <Link to="/configuracoes/empresas" className="font-medium text-primary-700 hover:underline">Configurações › Empresas</Link>.
                </p>
              )}
            </div>
          )}

          <fieldset disabled={!dados.pode_editar} className="space-y-3 border-t border-slate-100 pt-4">
            <h3 className="text-sm font-semibold text-slate-800">Considerar VT ou VA quando:</h3>
            <div className="grid gap-3 md:grid-cols-2">
              {([
                ['um', 'Trabalhar um turno', 'Basta um turno completo (entrada e saída) no dia.'],
                ['dois', 'Trabalhar os dois turnos', 'Precisa dos dois turnos completos. Em dia previsto com um turno só, basta ele.'],
              ] as const).map(([v, titulo, texto]) => (
                <label key={v} className={opcao(form.beneficio_turnos === v)}>
                  <input type="radio" name="beneficio" className="mt-1 accent-primary-700" checked={form.beneficio_turnos === v}
                    onChange={() => setForm((f) => ({ ...f, beneficio_turnos: v }))} />
                  <span>
                    <span className="text-sm font-semibold text-slate-800">{titulo}</span>
                    <span className="mt-1 block text-xs text-slate-500">{texto}</span>
                  </span>
                </label>
              ))}
            </div>
            <p className="text-xs text-slate-500">
              Vale para os dias marcados com VT ou VA na jornada, de quem recebe o benefício, nos Relatórios de VT e de VA.
            </p>
          </fieldset>

          {dados.pode_editar && (
            <div className="flex items-center justify-end gap-3 border-t border-slate-100 pt-4">
              {!alterado && <span className="flex items-center gap-1.5 text-xs text-slate-400"><CheckCircle2 className="h-3.5 w-3.5" /> Salvo</span>}
              <Button onClick={salvar} loading={salvando} disabled={!alterado}>Salvar</Button>
            </div>
          )}
        </section>
      )}
    </div>
  );
}
