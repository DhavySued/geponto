import type { GeoBatida, GeoStatus } from './types';

/** Parâmetros de localização enviados junto com o registro do ponto */
export interface ParametrosGeo {
  p_latitude: number | null;
  p_longitude: number | null;
  p_precisao: number | null;
  p_geo_erro: string | null;
}

const MENSAGENS_ERRO: Record<number, string> = {
  1: 'Permissão de localização negada no navegador',
  2: 'Localização indisponível no aparelho',
  3: 'Tempo esgotado ao obter a localização',
};

/**
 * Pede a localização atual ao navegador. Nunca falha: sem localização, devolve o motivo em
 * p_geo_erro e o ponto é registrado mesmo assim (Portaria 671 — o registro não pode ser impedido).
 */
export function obterLocalizacao(timeoutMs = 12_000): Promise<ParametrosGeo> {
  const semGeo = (motivo: string): ParametrosGeo => ({ p_latitude: null, p_longitude: null, p_precisao: null, p_geo_erro: motivo });
  if (typeof navigator === 'undefined' || !navigator.geolocation) {
    return Promise.resolve(semGeo('Navegador sem suporte a localização'));
  }
  if (!window.isSecureContext) return Promise.resolve(semGeo('Localização exige conexão segura (https)'));
  return new Promise((resolve) => {
    // Alguns navegadores não chamam nenhum dos callbacks se o aviso de permissão ficar aberto
    const limite = window.setTimeout(() => resolve(semGeo(MENSAGENS_ERRO[3])), timeoutMs + 3_000);
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        window.clearTimeout(limite);
        resolve({
          p_latitude: pos.coords.latitude,
          p_longitude: pos.coords.longitude,
          p_precisao: Math.round(pos.coords.accuracy),
          p_geo_erro: null,
        });
      },
      (err) => {
        window.clearTimeout(limite);
        resolve(semGeo(MENSAGENS_ERRO[err.code] ?? 'Não foi possível obter a localização'));
      },
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 0 },
    );
  });
}

export const linkMapa = (lat: number, lng: number) => `https://www.google.com/maps?q=${lat},${lng}`;

export const GEO_STATUS: Record<GeoStatus, { label: string; tone: 'green' | 'orange' | 'red' | 'slate'; alerta: boolean }> = {
  dentro: { label: 'No local', tone: 'green', alerta: false },
  registrada: { label: 'Com localização', tone: 'slate', alerta: false },
  fora: { label: 'Fora do local', tone: 'orange', alerta: true },
  sem_localizacao: { label: 'Sem localização', tone: 'red', alerta: true },
};

/** "a 820 m de Sede" / "a 1,2 km de Sede" */
export function textoDistancia(m: number): string {
  return m < 1000 ? `${m} m` : `${(m / 1000).toFixed(1).replace('.', ',')} km`;
}

/** Descrição em uma linha da localização da batida (tooltip, comprovante) */
export function descricaoGeo(g: GeoBatida): string | null {
  if (!g.geo_status) return null;
  switch (g.geo_status) {
    case 'sem_localizacao':
      return `Sem localização${g.geo_erro ? ` (${g.geo_erro.toLowerCase()})` : ''}`;
    case 'dentro':
      return `No local ${g.local ?? ''}${g.distancia_m != null ? ` (a ${textoDistancia(g.distancia_m)})` : ''}`.trim();
    case 'fora':
      return `Fora do local: a ${textoDistancia(g.distancia_m ?? 0)} de ${g.local ?? 'local mais próximo'}`;
    default:
      return 'Localização registrada';
  }
}
