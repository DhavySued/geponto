import clsx from 'clsx';
import { AlertTriangle, BarChart3, Gauge } from 'lucide-react';
import { useEffect, useState } from 'react';
import { Button } from '@/components/ui/Button';
import { Switch } from '@/components/ui/Field';
import { useToast } from '@/components/ui/Toast';
import { useAuth } from '@/contexts/AuthContext';
import { api } from '@/lib/api';
import { distribuir, widgetLigado, WIDGETS, type ConfigDashboard as Config, type WidgetChave } from '@/lib/dashboardWidgets';

export default function ConfigDashboard() {
  const { pode, usuario } = useAuth();
  const podeEditar = pode('config_dashboard', 'editar');
  const toast = useToast();
  const [cfg, setCfg] = useState<Config | null>(null);
  const [erro, setErro] = useState<string | null>(null);
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    api<Config>('api_dashboard_config').then(setCfg).catch((e) => setErro(e instanceof Error ? e.message : 'Erro ao carregar.'));
  }, []);

  const ligado = (k: WidgetChave) => widgetLigado(cfg, k);
  const alternar = (k: WidgetChave, v: boolean) => setCfg((c) => ({ ...c, [k]: v }));

  const salvar = async () => {
    if (!cfg) return;
    setSalvando(true);
    try {
      const completo = Object.fromEntries(WIDGETS.map((w) => [w.chave, ligado(w.chave)]));
      await api('api_dashboard_config_salvar', { p_config: completo });
      toast('Dashboard configurado.');
    } catch (e) {
      toast(e instanceof Error ? e.message : 'Erro ao salvar.', 'erro');
    } finally {
      setSalvando(false);
    }
  };

  const kpis = WIDGETS.filter((w) => w.tipo === 'indicador' && ligado(w.chave));
  const linhas = distribuir(WIDGETS.filter((w) => w.tipo === 'grafico' && ligado(w.chave)));

  return (
    <div className="space-y-6">
      <div className="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Dashboard</h2>
          <p className="mt-1 text-sm text-slate-500">
            Escolha os indicadores e gráficos que aparecem no dashboard{usuario?.empresa ? ` da empresa ${usuario.empresa.nome}` : ''}. O layout se ajusta sozinho.
          </p>
        </div>
        {podeEditar && <Button onClick={salvar} loading={salvando} disabled={!cfg}>Salvar</Button>}
      </div>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      {!cfg ? <div className="card h-64 animate-pulse" /> : (
        <div className="grid gap-6 lg:grid-cols-[1fr_1fr]">
          <fieldset disabled={!podeEditar} className="space-y-6">
            {(['indicador', 'grafico'] as const).map((tipo) => (
              <section key={tipo} className="card p-5">
                <h3 className="mb-3 flex items-center gap-2 text-sm font-semibold text-slate-800">
                  {tipo === 'indicador' ? <Gauge className="h-4 w-4" /> : <BarChart3 className="h-4 w-4" />}
                  {tipo === 'indicador' ? 'Indicadores (cartões do topo)' : 'Gráficos e quadros'}
                </h3>
                <div className="space-y-3">
                  {WIDGETS.filter((w) => w.tipo === tipo).map((w) => (
                    <Switch key={w.chave} ativo={ligado(w.chave)} onChange={(v) => alternar(w.chave, v)} label={w.titulo} descricao={w.descricao} />
                  ))}
                </div>
              </section>
            ))}
          </fieldset>

          <section className="card p-5">
            <h3 className="mb-3 text-sm font-semibold text-slate-800">Prévia do layout</h3>
            <div className="space-y-2 rounded-xl bg-slate-50 p-3">
              {kpis.length > 0 && (
                <div className="grid gap-2" style={{ gridTemplateColumns: `repeat(${kpis.length}, minmax(0, 1fr))` }}>
                  {kpis.map((k) => <div key={k.chave} className="truncate rounded-lg bg-white px-2 py-3 text-[11px] text-slate-500 ring-1 ring-slate-200">{k.titulo}</div>)}
                </div>
              )}
              {linhas.map((l, i) => (
                <div key={i} className="grid grid-cols-3 gap-2">
                  {l.map((w) => (
                    <div key={w.chave} className={clsx('truncate rounded-lg bg-white px-2 py-6 text-[11px] text-slate-500 ring-1 ring-slate-200',
                      w.span === 3 ? 'col-span-3' : w.span === 2 ? 'col-span-2' : 'col-span-1')}>{w.titulo}</div>
                  ))}
                </div>
              ))}
              {!kpis.length && !linhas.length && <p className="py-10 text-center text-xs text-slate-400">Nada ligado: o dashboard fica só com o cabeçalho.</p>}
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
