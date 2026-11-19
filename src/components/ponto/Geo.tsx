import clsx from 'clsx';
import { ExternalLink, MapPin, MapPinOff } from 'lucide-react';
import { textoEndereco, useEndereco } from '@/lib/enderecos';
import { descricaoGeo, GEO_STATUS, linkMapa } from '@/lib/geo';
import type { GeoBatida } from '@/lib/types';

const COR: Record<string, string> = {
  green: 'text-emerald-600',
  slate: 'text-slate-400',
  orange: 'text-accent-600',
  red: 'text-rose-600',
};

/** Endereço da coordenada (rua, número, bairro, cidade/UF) como link que abre o mapa */
export function EnderecoLink({ lat, lng, className }: { lat: number; lng: number; className?: string }) {
  const e = useEndereco(lat, lng);
  const texto = textoEndereco(e);
  const coords = `${lat.toFixed(6)}, ${lng.toFixed(6)}`;
  return (
    <a
      href={linkMapa(lat, lng)}
      target="_blank"
      rel="noreferrer"
      onClick={(ev) => ev.stopPropagation()}
      title={`${texto ?? coords} · abrir no mapa`}
      className={clsx('inline-flex min-w-0 items-start gap-1 text-primary-600 hover:text-primary-800 hover:underline', className)}
    >
      <ExternalLink className="mt-0.5 h-3 w-3 shrink-0" />
      <span className={clsx('min-w-0', e === undefined && 'text-slate-400')}>
        {e === undefined ? 'Buscando endereço…' : (texto ?? `Ver no mapa (${coords})`)}
      </span>
    </a>
  );
}

/** Situação da localização da batida e, quando há coordenadas, o endereço com link para o mapa */
export function GeoIndicador({ g, compacto = false }: { g: GeoBatida; compacto?: boolean }) {
  if (!g.geo_status) return null;
  const st = GEO_STATUS[g.geo_status];
  const Icone = g.geo_status === 'sem_localizacao' ? MapPinOff : MapPin;
  const texto = descricaoGeo(g) ?? st.label;
  const titulo = texto + (g.precisao_m != null ? ` · precisão do GPS ${g.precisao_m} m` : '');
  const temCoord = g.latitude != null && g.longitude != null;

  if (compacto) {
    const icone = <Icone className={clsx('h-3.5 w-3.5 shrink-0', COR[st.tone])} />;
    return temCoord ? (
      <a href={linkMapa(g.latitude!, g.longitude!)} target="_blank" rel="noreferrer" title={`${titulo} · abrir no mapa`} onClick={(e) => e.stopPropagation()}>
        {icone}
      </a>
    ) : (
      <span title={titulo}>{icone}</span>
    );
  }

  return (
    <span className="flex min-w-0 flex-col gap-0.5 text-[11px]">
      <span className={clsx('inline-flex min-w-0 items-center gap-1', st.alerta ? 'font-medium text-slate-700' : 'text-slate-500')} title={titulo}>
        <Icone className={clsx('h-3.5 w-3.5 shrink-0', COR[st.tone])} />
        <span className="truncate">{texto}</span>
      </span>
      {temCoord && <EnderecoLink lat={g.latitude!} lng={g.longitude!} className="pl-[18px]" />}
    </span>
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
