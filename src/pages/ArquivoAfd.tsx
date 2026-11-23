import { AlertTriangle, Download, FileCode2 } from 'lucide-react';
import { useState } from 'react';
import { Button } from '@/components/ui/Button';
import { Field } from '@/components/ui/Field';
import { useToast } from '@/components/ui/Toast';
import { api } from '@/lib/api';
import { baixarArquivo } from '@/lib/exportacao';
import { competencia } from '@/lib/hooks';

interface Afd {
  nome_arquivo: string;
  conteudo: string;
  marcacoes: number;
  empresa: string;
}

const CHAVE = 'geponto.afd';
function lerConfig(): { inpi: string; desenvolvedor_doc: string } {
  try {
    return { inpi: '', desenvolvedor_doc: '', ...JSON.parse(localStorage.getItem(CHAVE) ?? '{}') };
  } catch {
    return { inpi: '', desenvolvedor_doc: '' };
  }
}

/** AFD do REP-P no leiaute da Portaria MTP 671/2021 */
export default function ArquivoAfd() {
  const toast = useToast();
  const [periodo, setPeriodo] = useState(() => competencia());
  const [cfg, setCfg] = useState(lerConfig);
  const [erro, setErro] = useState<string | null>(null);
  const [gerando, setGerando] = useState(false);
  const [ultimo, setUltimo] = useState<Afd | null>(null);

  const gerar = async () => {
    setErro(null);
    setGerando(true);
    try {
      try { localStorage.setItem(CHAVE, JSON.stringify(cfg)); } catch { /* sem armazenamento local */ }
      const r = await api<Afd>('api_afd_gerar', { p_ini: periodo.ini, p_fim: periodo.fim, p_dados: cfg });
      baixarArquivo(r.nome_arquivo, r.conteudo, 'text/plain');
      setUltimo(r);
      toast(`AFD gerado com ${r.marcacoes} marcação(ões).`);
    } catch (e) {
      setErro(e instanceof Error ? e.message : 'Erro ao gerar o AFD.');
    } finally {
      setGerando(false);
    }
  };

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-2xl font-semibold tracking-tight text-slate-900">Arquivo AFD</h2>
        <p className="mt-1 text-sm text-slate-500">
          Arquivo Fonte de Dados do REP-P (registro eletrônico de ponto por programa), no leiaute da Portaria MTP 671/2021, da empresa em que você está.
        </p>
      </div>

      <section className="card space-y-4 p-5">
        <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <Field label="De">
            <input type="date" className="input" value={periodo.ini} max={periodo.fim} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, ini: e.target.value }))} />
          </Field>
          <Field label="Até">
            <input type="date" className="input" value={periodo.fim} min={periodo.ini} onChange={(e) => e.target.value && setPeriodo((p) => ({ ...p, fim: e.target.value }))} />
          </Field>
          <Field label="Nº de registro do programa (INPI)" dica="17 dígitos; em branco sai com zeros.">
            <input className="input tabular-nums" inputMode="numeric" value={cfg.inpi} maxLength={17}
              onChange={(e) => setCfg((c) => ({ ...c, inpi: e.target.value.replace(/\D/g, '') }))} />
          </Field>
          <Field label="CNPJ/CPF do desenvolvedor" dica="Do fabricante do programa de ponto.">
            <input className="input tabular-nums" value={cfg.desenvolvedor_doc}
              onChange={(e) => setCfg((c) => ({ ...c, desenvolvedor_doc: e.target.value.replace(/[^\d./-]/g, '') }))} />
          </Field>
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3">
          <p className="text-xs text-slate-500">
            Entram as marcações registradas no sistema (com NSR), inclusive as desconsideradas no tratamento. Batidas incluídas
            manualmente não são marcações do REP e ficam só no espelho.
          </p>
          <Button onClick={gerar} loading={gerando}><Download className="h-4 w-4" /> Gerar AFD</Button>
        </div>
      </section>

      {erro && (
        <div className="flex items-center gap-3 rounded-2xl bg-rose-50 p-4 text-sm text-rose-700 ring-1 ring-rose-200">
          <AlertTriangle className="h-4 w-4" /> {erro}
        </div>
      )}

      <section className="card p-5 text-sm text-slate-600">
        <h3 className="mb-2 flex items-center gap-2 font-semibold text-slate-800"><FileCode2 className="h-4 w-4" /> Conteúdo do arquivo</h3>
        <ul className="list-disc space-y-1 pl-5 text-xs">
          <li><strong>Tipo 1</strong>: cabeçalho com CNPJ, razão social, nº do REP-P no INPI, período, data da geração, leiaute 003 e CRC-16.</li>
          <li><strong>Tipo 7</strong>: uma linha por marcação, com NSR, data e hora, CPF, data da gravação, coletor (aplicativo ou navegador) e hash SHA-256 encadeado.</li>
          <li><strong>Tipo 9</strong>: trailer com a quantidade de registros.</li>
        </ul>
        <p className="mt-3 text-xs text-slate-500">
          A Portaria exige que o AFD entregue à fiscalização seja assinado digitalmente (arquivo .p7s, CAdES) com o certificado do
          desenvolvedor. Assine o arquivo gerado aqui com esse certificado antes de entregar.
        </p>
        {ultimo && <p className="mt-3 text-xs text-slate-500">Último arquivo: {ultimo.nome_arquivo} · {ultimo.empresa} · {ultimo.marcacoes} marcação(ões).</p>}
      </section>
    </div>
  );
}
