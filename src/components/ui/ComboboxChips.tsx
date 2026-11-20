import clsx from 'clsx';
import { Check, ChevronDown, Search, X } from 'lucide-react';
import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent } from 'react';

export interface OpcaoCombobox {
  id: string;
  nome: string;
  /** Texto menor ao lado (matrícula, departamento…); também entra na busca */
  detalhe?: string | null;
}

const normalizar = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase();

/**
 * Combobox de seleção múltipla com chips: digite para filtrar, marque vários e use
 * "Marcar todos" (respeita a busca). Nada marcado = todos.
 */
export function ComboboxChips({
  opcoes,
  valor,
  onChange,
  placeholder = 'Todos',
  rotuloTodos = 'Todos',
  maxChips = 3,
  disabled = false,
  id,
}: {
  opcoes: OpcaoCombobox[];
  valor: string[];
  onChange: (ids: string[]) => void;
  placeholder?: string;
  /** Texto quando nada está marcado */
  rotuloTodos?: string;
  /** Chips visíveis antes de resumir em "+N" */
  maxChips?: number;
  disabled?: boolean;
  id?: string;
}) {
  const [aberto, setAberto] = useState(false);
  const [busca, setBusca] = useState('');
  const [ativo, setAtivo] = useState(0);
  const caixa = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const lista = useRef<HTMLUListElement>(null);
  const idLista = useId();

  const marcados = useMemo(() => new Set(valor), [valor]);
  const porId = useMemo(() => new Map(opcoes.map((o) => [o.id, o])), [opcoes]);
  const filtradas = useMemo(() => {
    const t = normalizar(busca.trim());
    if (!t) return opcoes;
    return opcoes.filter((o) => normalizar(`${o.nome} ${o.detalhe ?? ''}`).includes(t));
  }, [opcoes, busca]);
  const todosFiltradosMarcados = filtradas.length > 0 && filtradas.every((o) => marcados.has(o.id));

  // Fecha ao clicar fora
  useEffect(() => {
    if (!aberto) return;
    const fora = (e: MouseEvent) => {
      if (caixa.current && !caixa.current.contains(e.target as Node)) {
        setAberto(false);
        setBusca('');
      }
    };
    document.addEventListener('mousedown', fora);
    return () => document.removeEventListener('mousedown', fora);
  }, [aberto]);

  useEffect(() => setAtivo(0), [busca, aberto]);

  // Mantém o item ativo visível ao navegar pelo teclado (índice 0 = "Marcar todos")
  useEffect(() => {
    lista.current?.querySelector<HTMLElement>(`[data-indice="${ativo}"]`)?.scrollIntoView({ block: 'nearest' });
  }, [ativo]);

  const alternar = (oid: string) => onChange(marcados.has(oid) ? valor.filter((v) => v !== oid) : [...valor, oid]);

  const marcarTodos = () => {
    const ids = filtradas.map((o) => o.id);
    if (todosFiltradosMarcados) onChange(valor.filter((v) => !ids.includes(v)));
    else onChange([...valor, ...ids.filter((i) => !marcados.has(i))]);
  };

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      if (!aberto) return setAberto(true);
      setAtivo((a) => Math.min(a + 1, filtradas.length));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setAtivo((a) => Math.max(a - 1, 0));
    } else if (e.key === 'Enter') {
      if (!aberto) return;
      e.preventDefault();
      if (ativo === 0) marcarTodos();
      else if (filtradas[ativo - 1]) alternar(filtradas[ativo - 1].id);
    } else if (e.key === 'Escape') {
      setAberto(false);
      setBusca('');
    } else if (e.key === 'Backspace' && !busca && valor.length) {
      onChange(valor.slice(0, -1));
    }
  };

  const visiveis = valor.slice(0, maxChips);
  const resto = valor.length - visiveis.length;
  const tudo = opcoes.length > 0 && valor.length === opcoes.length;

  return (
    <div ref={caixa} className="relative">
      <div
        onClick={() => {
          if (disabled) return;
          setAberto(true);
          input.current?.focus();
        }}
        className={clsx(
          'input flex h-auto min-h-[42px] cursor-text flex-wrap items-center gap-1.5 py-1.5 pr-14',
          disabled && 'cursor-not-allowed opacity-60',
          aberto && 'ring-2 ring-primary-500/30',
        )}
      >
        {tudo ? (
          <Chip texto={`${rotuloTodos} (${opcoes.length})`} onRemover={() => onChange([])} />
        ) : (
          <>
            {visiveis.map((v) => (
              <Chip key={v} texto={porId.get(v)?.nome ?? '…'} onRemover={() => alternar(v)} />
            ))}
            {resto > 0 && (
              <span className="rounded-lg bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600" title={valor.slice(maxChips).map((v) => porId.get(v)?.nome).join(', ')}>
                +{resto}
              </span>
            )}
          </>
        )}
        <input
          ref={input}
          id={id}
          value={busca}
          disabled={disabled}
          onChange={(e) => {
            setBusca(e.target.value);
            setAberto(true);
          }}
          onFocus={() => setAberto(true)}
          onKeyDown={onKeyDown}
          placeholder={valor.length ? '' : placeholder}
          role="combobox"
          aria-expanded={aberto}
          aria-controls={idLista}
          aria-autocomplete="list"
          className="min-w-[80px] flex-1 border-0 bg-transparent p-0 text-sm outline-none placeholder:text-slate-400 focus:ring-0"
        />
        <span className="absolute right-2 top-1/2 flex -translate-y-1/2 items-center gap-0.5">
          {valor.length > 0 && !disabled && (
            <button
              type="button"
              onClick={(e) => {
                e.stopPropagation();
                onChange([]);
              }}
              className="rounded-md p-1 text-slate-400 hover:bg-slate-100 hover:text-slate-600"
              aria-label="Limpar seleção"
            >
              <X className="h-3.5 w-3.5" />
            </button>
          )}
          <ChevronDown className={clsx('h-4 w-4 text-slate-400 transition', aberto && 'rotate-180')} />
        </span>
      </div>

      {aberto && (
        <div className="absolute left-0 right-0 top-full z-50 mt-1 overflow-hidden rounded-xl bg-white shadow-2xl ring-1 ring-slate-200">
          <ul ref={lista} id={idLista} role="listbox" aria-multiselectable className="max-h-72 overflow-y-auto p-1">
            <li
              data-indice={0}
              role="option"
              aria-selected={todosFiltradosMarcados}
              onMouseDown={(e) => e.preventDefault()}
              onClick={marcarTodos}
              onMouseEnter={() => setAtivo(0)}
              className={clsx(
                'flex cursor-pointer items-center gap-2.5 rounded-lg border-b border-slate-100 px-2.5 py-2 text-sm font-medium text-slate-700',
                ativo === 0 && 'bg-slate-50',
              )}
            >
              <Caixa marcada={todosFiltradosMarcados} parcial={!todosFiltradosMarcados && filtradas.some((o) => marcados.has(o.id))} />
              {busca.trim() ? `Marcar todos os encontrados (${filtradas.length})` : `Marcar todos (${opcoes.length})`}
            </li>
            {filtradas.length === 0 && (
              <li className="flex items-center gap-2 px-2.5 py-3 text-sm text-slate-400">
                <Search className="h-4 w-4" /> Nenhum resultado para “{busca}”
              </li>
            )}
            {filtradas.map((o, i) => {
              const marcada = marcados.has(o.id);
              return (
                <li
                  key={o.id}
                  data-indice={i + 1}
                  role="option"
                  aria-selected={marcada}
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => alternar(o.id)}
                  onMouseEnter={() => setAtivo(i + 1)}
                  className={clsx(
                    'flex cursor-pointer items-center gap-2.5 rounded-lg px-2.5 py-2 text-sm',
                    ativo === i + 1 && 'bg-slate-50',
                    marcada ? 'text-slate-900' : 'text-slate-600',
                  )}
                >
                  <Caixa marcada={marcada} />
                  <span className="min-w-0 flex-1 truncate">{o.nome}</span>
                  {o.detalhe && <span className="shrink-0 text-xs text-slate-400">{o.detalhe}</span>}
                </li>
              );
            })}
          </ul>
          <div className="flex items-center justify-between border-t border-slate-100 bg-slate-50/60 px-3 py-2 text-xs text-slate-500">
            <span>{valor.length ? `${valor.length} de ${opcoes.length} marcado(s)` : `Nenhum marcado: ${rotuloTodos.toLowerCase()}`}</span>
            {valor.length > 0 && (
              <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={() => onChange([])} className="font-medium text-primary-700 hover:underline">
                Limpar
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function Chip({ texto, onRemover }: { texto: string; onRemover: () => void }) {
  return (
    <span className="inline-flex max-w-[180px] items-center gap-1 rounded-lg bg-primary-50 py-0.5 pl-2 pr-1 text-xs font-medium text-primary-800 ring-1 ring-inset ring-primary-200">
      <span className="truncate">{texto}</span>
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation();
          onRemover();
        }}
        className="rounded p-0.5 text-primary-500 hover:bg-primary-100 hover:text-primary-800"
        aria-label={`Remover ${texto}`}
      >
        <X className="h-3 w-3" />
      </button>
    </span>
  );
}

function Caixa({ marcada, parcial = false }: { marcada: boolean; parcial?: boolean }) {
  return (
    <span
      className={clsx(
        'flex h-4 w-4 shrink-0 items-center justify-center rounded border',
        marcada || parcial ? 'border-primary-600 bg-primary-600 text-white' : 'border-slate-300 bg-white',
      )}
    >
      {marcada ? <Check className="h-3 w-3" strokeWidth={3} /> : parcial ? <span className="h-0.5 w-2 rounded bg-white" /> : null}
    </span>
  );
}
