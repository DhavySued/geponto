import clsx from 'clsx';
import { Building2, CalendarDays, Check, ChevronDown, ChevronRight, KeyRound, LogOut, Menu, X } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { NavLink, useLocation } from 'react-router-dom';
import { useAuth } from '@/contexts/AuthContext';
import { iniciais } from '@/lib/format';
import { ICONES_SUBMENU, NAVEGACAO, type NavGroup, type NavItem } from '@/lib/navigation';

function Logo() {
  return (
    <div className="flex items-center gap-2.5">
      <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-white/10 ring-1 ring-white/15">
        <svg viewBox="0 0 32 32" className="h-6 w-6" aria-hidden>
          <circle cx="16" cy="16" r="10" fill="none" stroke="#fff" strokeWidth="2.6" />
          <path d="M16 10.5v5.5l4 2.3" fill="none" stroke="#f39200" strokeWidth="2.6" strokeLinecap="round" />
        </svg>
      </div>
      <p className="text-[17px] font-semibold tracking-tight text-white">
        Ge<span className="text-accent-400">Ponto</span>
      </p>
    </div>
  );
}

/** Entradas de um grupo: itens soltos e submenus (itens com o mesmo `submenu`), na ordem do cadastro. */
type Entrada = { tipo: 'item'; item: NavItem } | { tipo: 'submenu'; nome: string; itens: NavItem[] };

function entradas(grupo: NavGroup): Entrada[] {
  const lista: Entrada[] = [];
  for (const item of grupo.itens) {
    if (!item.submenu) {
      lista.push({ tipo: 'item', item });
      continue;
    }
    const existente = lista.find((e) => e.tipo === 'submenu' && e.nome === item.submenu);
    if (existente && existente.tipo === 'submenu') existente.itens.push(item);
    else lista.push({ tipo: 'submenu', nome: item.submenu, itens: [item] });
  }
  return lista;
}

const ativo = (pathname: string, path: string) => (path === '/' ? pathname === '/' : pathname === path);

function LinkItem({ item, onNavegar }: { item: NavItem; onNavegar: () => void }) {
  return (
    <NavLink
      to={item.path}
      end
      onClick={onNavegar}
      className={({ isActive }) =>
        clsx(
          'flex items-center gap-3 rounded-xl px-3 py-2.5 transition focus-visible:outline-none',
          // Sombreamento do item em foco/selecionado na cascata
          isActive
            ? 'bg-primary-50 text-primary-700 shadow-sm ring-1 ring-inset ring-primary-200/70'
            : 'text-slate-700 hover:bg-slate-100 hover:shadow-sm focus-visible:bg-slate-100',
        )
      }
    >
      {({ isActive }) => (
        <>
          <item.icon className={clsx('h-[18px] w-[18px] shrink-0', isActive ? 'text-accent-500' : 'text-slate-400')} strokeWidth={1.9} />
          <span className="min-w-0 text-sm font-medium">{item.titulo}</span>
        </>
      )}
    </NavLink>
  );
}

/** Grupo do menu superior: abre um painel; os submenus se destrincham para o lado. */
function GrupoMenu({
  grupo,
  aberto,
  onAbrir,
  onFechar,
  onClicar,
  onNavegar,
}: {
  grupo: NavGroup;
  aberto: boolean;
  onAbrir: () => void;
  onFechar: () => void;
  /** Clique no grupo: fixa o menu aberto (ou fecha, se já estava fixado) */
  onClicar: () => void;
  onNavegar: () => void;
}) {
  const { pathname } = useLocation();
  const [sub, setSub] = useState<string | null>(null);
  const lista = entradas(grupo);
  const grupoAtivo = grupo.itens.some((i) => ativo(pathname, i.path));

  useEffect(() => {
    if (!aberto) setSub(null);
  }, [aberto]);

  // Grupo de uma página só (Dashboard, Meu Ponto): link direto
  if (grupo.itens.length === 1 && !grupo.itens[0].submenu) {
    const item = grupo.itens[0];
    return (
      <NavLink
        to={item.path}
        end
        className={({ isActive }) =>
          clsx(
            'flex h-10 items-center gap-2 rounded-xl px-3 text-sm font-medium transition',
            isActive ? 'bg-white/[0.14] text-white' : 'text-white/75 hover:bg-white/[0.08] hover:text-white',
          )
        }
      >
        <grupo.icon className="h-4 w-4" strokeWidth={1.9} />
        {grupo.titulo}
      </NavLink>
    );
  }

  return (
    <div className="relative" onMouseEnter={onAbrir} onMouseLeave={onFechar}>
      <button
        type="button"
        onClick={onClicar}
        aria-expanded={aberto}
        className={clsx(
          'flex h-10 items-center gap-2 rounded-xl px-3 text-sm font-medium transition',
          aberto || grupoAtivo ? 'bg-white/[0.14] text-white' : 'text-white/75 hover:bg-white/[0.08] hover:text-white',
        )}
      >
        <grupo.icon className="h-4 w-4" strokeWidth={1.9} />
        {grupo.titulo}
        <ChevronDown className={clsx('h-3.5 w-3.5 transition', aberto && 'rotate-180')} />
      </button>

      {aberto && (
        // pt-2 mantém o hover entre o botão e o painel
        <div className="absolute left-0 top-full z-50 pt-2">
          <div className="w-72 rounded-2xl bg-white p-2 shadow-2xl ring-1 ring-slate-200/70">
            {lista.map((e) =>
              e.tipo === 'item' ? (
                <div key={e.item.chave} onMouseEnter={() => setSub(null)}>
                  <LinkItem item={e.item} onNavegar={onNavegar} />
                </div>
              ) : (
                <div key={e.nome} className="relative" onMouseEnter={() => setSub(e.nome)}>
                  <SubmenuBotao
                    nome={e.nome}
                    aberto={sub === e.nome}
                    ativo={e.itens.some((i) => ativo(pathname, i.path))}
                    onClick={() => setSub(e.nome)}
                  />
                  {sub === e.nome && (
                    <div className="absolute left-full top-0 z-50 pl-2">
                      <div className="w-72 rounded-2xl bg-white p-2 shadow-2xl ring-1 ring-slate-200/70">
                        {e.itens.map((i) => (
                          <LinkItem key={i.chave} item={i} onNavegar={onNavegar} />
                        ))}
                      </div>
                    </div>
                  )}
                </div>
              ),
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function SubmenuBotao({ nome, aberto, ativo: estaAtivo, onClick }: { nome: string; aberto: boolean; ativo: boolean; onClick: () => void }) {
  const Icone = ICONES_SUBMENU[nome];
  return (
    <button
      type="button"
      onClick={onClick}
      aria-expanded={aberto}
      className={clsx(
        'flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left text-sm font-medium transition',
        // Submenu aberto fica sombreado enquanto a cascata ao lado está visível
        aberto
          ? 'bg-slate-100 text-slate-900 shadow-sm ring-1 ring-inset ring-slate-200'
          : estaAtivo
            ? 'bg-primary-50 text-primary-700 shadow-sm ring-1 ring-inset ring-primary-200/70'
            : 'text-slate-700 hover:bg-slate-100 hover:shadow-sm',
      )}
    >
      {Icone && <Icone className={clsx('h-[18px] w-[18px] shrink-0', estaAtivo ? 'text-accent-500' : 'text-slate-400')} strokeWidth={1.9} />}
      <span className="flex-1">{nome}</span>
      <ChevronRight className="h-4 w-4 text-slate-400" />
    </button>
  );
}

/** Menu do celular: grupos e submenus abrem em cascata (acordeão). */
function MenuMovel({ grupos, onFechar }: { grupos: NavGroup[]; onFechar: () => void }) {
  const { pathname } = useLocation();
  const [abertos, setAbertos] = useState<Set<string>>(
    () => new Set(grupos.filter((g) => g.itens.some((i) => ativo(pathname, i.path))).map((g) => g.titulo)),
  );
  const alternar = (k: string) =>
    setAbertos((s) => {
      const n = new Set(s);
      if (n.has(k)) n.delete(k);
      else n.add(k);
      return n;
    });

  return (
    <nav className="max-h-[calc(100vh-4rem)] overflow-y-auto border-t border-white/10 bg-white px-3 py-3 lg:hidden">
      {grupos.map((g) => (
        <div key={g.titulo} className="border-b border-slate-100 py-1 last:border-0">
          <button
            type="button"
            onClick={() => alternar(g.titulo)}
            className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-sm font-semibold text-slate-800"
          >
            <g.icon className="h-4 w-4 text-primary-600" />
            <span className="flex-1 text-left">{g.titulo}</span>
            <ChevronDown className={clsx('h-4 w-4 text-slate-400 transition', abertos.has(g.titulo) && 'rotate-180')} />
          </button>
          {abertos.has(g.titulo) && (
            <div className="space-y-0.5 pb-2 pl-4">
              {entradas(g).map((e) =>
                e.tipo === 'item' ? (
                  <LinkItem key={e.item.chave} item={e.item} onNavegar={onFechar} />
                ) : (
                  <div key={e.nome}>
                    <SubmenuBotao
                      nome={e.nome}
                      aberto={abertos.has(g.titulo + '/' + e.nome)}
                      ativo={e.itens.some((i) => ativo(pathname, i.path))}
                      onClick={() => alternar(g.titulo + '/' + e.nome)}
                    />
                    {abertos.has(g.titulo + '/' + e.nome) && (
                      <div className="space-y-0.5 pl-4">
                        {e.itens.map((i) => <LinkItem key={i.chave} item={i} onNavegar={onFechar} />)}
                      </div>
                    )}
                  </div>
                ),
              )}
            </div>
          )}
        </div>
      ))}
    </nav>
  );
}

/** Empresa em que o usuário está conectado; troca entre as empresas a que ele tem acesso */
function SeletorEmpresa() {
  const { usuario, trocarEmpresa } = useAuth();
  const [aberto, setAberto] = useState(false);
  const [trocando, setTrocando] = useState<string | null>(null);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const fora = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setAberto(false);
    document.addEventListener('mousedown', fora);
    return () => document.removeEventListener('mousedown', fora);
  }, []);

  if (!usuario?.empresa) return null;
  const varias = usuario.empresas.length > 1;
  const trocar = async (id: string) => {
    if (id === usuario.empresa?.id) return setAberto(false);
    setTrocando(id);
    try {
      await trocarEmpresa(id);
    } catch {
      setTrocando(null);
    }
  };

  return (
    <div ref={ref} className="relative">
      <button
        onClick={() => varias && setAberto((v) => !v)}
        className={clsx('flex max-w-[220px] items-center gap-2 rounded-xl bg-white/[0.08] px-3 py-2 text-left text-xs font-medium text-white/90',
          varias ? 'hover:bg-white/[0.14]' : 'cursor-default')}
        title={usuario.empresa.razao_social}
        aria-expanded={aberto}
      >
        <Building2 className="h-4 w-4 shrink-0 text-accent-400" />
        <span className="truncate">{usuario.empresa.nome}</span>
        {varias && <ChevronDown className="h-3.5 w-3.5 shrink-0 text-white/60" />}
      </button>
      {aberto && (
        <div className="absolute right-0 top-full z-50 mt-2 w-64 rounded-2xl bg-white p-2 text-slate-700 shadow-2xl ring-1 ring-slate-200/70">
          <p className="px-3 pb-1 pt-1.5 text-[11px] font-medium uppercase tracking-wide text-slate-400">Trocar de empresa</p>
          {usuario.empresas.map((e) => (
            <button key={e.id} onClick={() => trocar(e.id)} disabled={!!trocando}
              className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left text-sm hover:bg-slate-50 disabled:opacity-60">
              <span className="min-w-0 flex-1 truncate">{e.nome}</span>
              {e.id === usuario.empresa?.id && <Check className="h-4 w-4 text-primary-600" />}
              {trocando === e.id && <span className="text-xs text-slate-400">abrindo…</span>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export function MenuSuperior({ onAlterarSenha }: { onAlterarSenha: () => void }) {
  const { usuario, pode, sair, trocarEmpresa } = useAuth();
  const { pathname } = useLocation();
  const [grupoAberto, setGrupoAberto] = useState<string | null>(null);
  // Grupo aberto por clique: fica aberto mesmo com o mouse fora, até clicar fora, Esc ou escolher um item
  const [fixado, setFixado] = useState<string | null>(null);
  const navRef = useRef<HTMLElement>(null);
  const [movelAberto, setMovelAberto] = useState(false);
  const [contaAberta, setContaAberta] = useState(false);
  const fechar = useRef<number>();
  const contaRef = useRef<HTMLDivElement>(null);

  // "Meu Ponto" só aparece para quem tem um colaborador vinculado ao usuário
  const visivel = (chave: string) => chave !== 'meu_ponto' || !!usuario?.colaborador_id;
  const grupos = NAVEGACAO.map((g) => ({ ...g, itens: g.itens.filter((i) => pode(i.chave) && visivel(i.chave)) })).filter(
    (g) => g.itens.length > 0,
  );

  useEffect(() => {
    setGrupoAberto(null);
    setFixado(null);
    setMovelAberto(false);
    setContaAberta(false);
  }, [pathname]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setGrupoAberto(null);
        setFixado(null);
        setContaAberta(false);
      }
    };
    const onClick = (e: MouseEvent) => {
      if (contaRef.current && !contaRef.current.contains(e.target as Node)) setContaAberta(false);
      if (navRef.current && !navRef.current.contains(e.target as Node)) {
        setFixado(null);
        setGrupoAberto(null);
      }
    };
    document.addEventListener('keydown', onKey);
    document.addEventListener('mousedown', onClick);
    return () => {
      document.removeEventListener('keydown', onKey);
      document.removeEventListener('mousedown', onClick);
    };
  }, []);

  // Pequeno atraso ao sair do grupo, para o mouse poder atravessar até o painel
  const abrir = (titulo: string) => {
    window.clearTimeout(fechar.current);
    setGrupoAberto(titulo);
  };
  const agendarFechar = () => {
    window.clearTimeout(fechar.current);
    fechar.current = window.setTimeout(() => setGrupoAberto((g) => (fixadoRef.current && g === fixadoRef.current ? g : null)), 180);
  };
  const fixadoRef = useRef<string | null>(null);
  fixadoRef.current = fixado;
  const clicar = (titulo: string) => {
    window.clearTimeout(fechar.current);
    if (fixado === titulo) {
      setFixado(null);
      setGrupoAberto(null);
    } else {
      setFixado(titulo);
      setGrupoAberto(titulo);
    }
  };
  const navegar = () => {
    setFixado(null);
    setGrupoAberto(null);
  };

  const hoje = new Date().toLocaleDateString('pt-BR', { weekday: 'long', day: '2-digit', month: 'long' });

  return (
    <header
      className={clsx(
        'sticky top-0 z-40 bg-primary-700 text-white shadow-soft print:hidden',
        'bg-[radial-gradient(80%_120%_at_0%_0%,rgba(255,255,255,0.08),transparent_60%)]',
      )}
    >
      <div className="mx-auto flex h-16 w-full max-w-[1440px] items-center gap-4 px-4 sm:px-6 lg:px-8">
        <button
          onClick={() => setMovelAberto((v) => !v)}
          className="-ml-1 rounded-lg p-2 text-white/70 hover:bg-white/10 lg:hidden"
          aria-label={movelAberto ? 'Fechar menu' : 'Abrir menu'}
        >
          {movelAberto ? <X className="h-5 w-5" /> : <Menu className="h-5 w-5" />}
        </button>

        <Logo />

        <nav ref={navRef} className="ml-4 hidden flex-1 items-center gap-1 lg:flex" aria-label="Menu principal">
          {grupos.map((g) => (
            <GrupoMenu
              key={g.titulo}
              grupo={g}
              aberto={grupoAberto === g.titulo}
              onAbrir={() => { if (!fixado || fixado === g.titulo) abrir(g.titulo); }}
              onFechar={agendarFechar}
              onClicar={() => clicar(g.titulo)}
              onNavegar={navegar}
            />
          ))}
        </nav>
        <div className="flex-1 lg:hidden" />

        <div className="hidden items-center gap-2 rounded-xl bg-white/[0.08] px-3 py-2 text-xs font-medium capitalize text-white/70 2xl:flex">
          <CalendarDays className="h-4 w-4 text-accent-400" />
          {hoje}
        </div>
        <div className="hidden sm:block">
          <SeletorEmpresa />
        </div>

        {usuario && (
          <div ref={contaRef} className="relative">
            <button
              onClick={() => setContaAberta((v) => !v)}
              aria-expanded={contaAberta}
              className="flex items-center gap-2 rounded-xl p-1 pr-2 transition hover:bg-white/[0.08]"
            >
              <span className="flex h-8 w-8 items-center justify-center rounded-lg bg-accent-500 text-xs font-semibold">
                {iniciais(usuario.nome)}
              </span>
              <span className="hidden max-w-[140px] text-left leading-tight sm:block">
                <span className="block truncate text-sm font-medium">{usuario.nome}</span>
                <span className="block truncate text-[11px] text-white/50">{usuario.perfil.nome}</span>
              </span>
              <ChevronDown className="h-3.5 w-3.5 text-white/60" />
            </button>
            {contaAberta && (
              <div className="absolute right-0 top-full z-50 mt-2 w-56 rounded-2xl bg-white p-2 text-slate-700 shadow-2xl ring-1 ring-slate-200/70">
                <div className="px-3 py-2 sm:hidden">
                  <p className="truncate text-sm font-medium text-slate-900">{usuario.nome}</p>
                  <p className="truncate text-xs text-slate-400">{usuario.perfil.nome}</p>
                  {usuario.empresa && <p className="mt-1 truncate text-xs text-slate-500">{usuario.empresa.nome}</p>}
                </div>
                {usuario.empresas.length > 1 && (
                  <div className="border-b border-slate-100 pb-1 sm:hidden">
                    {usuario.empresas.filter((e) => e.id !== usuario.empresa?.id).map((e) => (
                      <button key={e.id} onClick={() => trocarEmpresa(e.id)}
                        className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-left text-sm hover:bg-slate-50">
                        <Building2 className="h-4 w-4 text-slate-400" /> <span className="truncate">Trocar para {e.nome}</span>
                      </button>
                    ))}
                  </div>
                )}
                <button
                  onClick={() => {
                    setContaAberta(false);
                    onAlterarSenha();
                  }}
                  className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-sm hover:bg-slate-50"
                >
                  <KeyRound className="h-4 w-4 text-slate-400" /> Alterar senha
                </button>
                <button onClick={sair} className="flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-sm text-rose-600 hover:bg-rose-50">
                  <LogOut className="h-4 w-4" /> Sair
                </button>
              </div>
            )}
          </div>
        )}
      </div>

      {movelAberto && <MenuMovel grupos={grupos} onFechar={() => setMovelAberto(false)} />}
    </header>
  );
}
