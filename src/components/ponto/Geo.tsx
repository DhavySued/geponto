import clsx from 'clsx';
import { MapPin, MapPinOff } from 'lucide-react';
import { descricaoGeo, GEO_STATUS, linkMapa } from '@/lib/geo';
import type { GeoBatida } from '@/lib/types';

const COR: Record<string, string> = {
  green: 'text-emerald-600',
  slate: 'text-slate-400',
  orange: 'text-accent-600',
  red: 'text-rose-600',
};

/** Ícone + texto curto da localização da batida; abre o mapa quando há coordenadas */
export function GeoIndicador({ g, compacto = false }: { g: GeoBatida; compacto?: boolean }) {
  if (!g.geo_status) return null;
  const st = GEO_STATUS[g.geo_status];
  const Icone = g.geo_status === 'sem_localizacao' ? MapPinOff : MapPin;
  const texto = descricaoGeo(g) ?? st.label;
  const conteudo = (
    <>
      <Icone className={clsx('h-3.5 w-3.5 shrink-0', COR[st.tone])} />
      {!compacto && <span className="truncate">{texto}</span>}
    </>
  );
  const classe = clsx('inline-flex min-w-0 items-center gap-1 text-[11px]', st.alerta ? 'font-medium text-slate-700' : 'text-slate-500');
  const titulo = texto + (g.precisao_m != null ? ` · precisão do GPS ${g.precisao_m} m` : '');
  return g.latitude != null && g.longitude != null ? (
    <a href={linkMapa(g.latitude, g.longitude)} target="_blank" rel="noreferrer" title={`${titulo} · abrir no mapa`}
      className={clsx(classe, 'hover:underline')} onClick={(e) => e.stopPropagation()}>
      {conteudo}
    </a>
  ) : (
    <span className={classe} title={titulo}>{conteudo}</span>
  );
}

/** Aviso no comprovante quando a batida foi registrada fora do local ou sem localização */
export function AvisoGeo({ g, className }: { g: GeoBatida; className?: string }) {
  if (!g.geo_status || !GEO_STATUS[g.geo_status].alerta) return null;
  const semLocal = g.geo_status === 'sem_localizacao';
  return (
    <div className={clsx('flex items-start gap-2 rounded-xl bg-amber-50 p-3 text-xs text-amber-900 ring-1 ring-amber-200', className)}>
      {semLocal ? <MapPinOff className="mt-0.5 h-4 w-4 shrink-0" /> : <MapPin className="mt-0.5 h-4 w-4 shrink-0" />}
      <p>
        <strong className="font-semibold">Ponto registrado {semLocal ? 'sem localização' : 'fora do local de trabalho'}.</strong>{' '}
        {semLocal
          ? `${g.geo_erro ?? 'O navegador não informou a localização'}. Permita o acesso à localização nas próximas batidas — o RH será avisado.`
          : `${descricaoGeo(g)}. O RH será avisado para conferir.`}
      </p>
    </div>
  );
}
