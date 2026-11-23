const digitos = (v: string) => v.replace(/\D/g, '');

function aplicar(v: string, padrao: string): string {
  const d = digitos(v);
  let out = '';
  let i = 0;
  for (const ch of padrao) {
    if (i >= d.length) break;
    out += ch === '#' ? d[i++] : ch;
  }
  return out;
}

export const mascaraCPF = (v: string) => aplicar(v, '###.###.###-##');
export const mascaraPIS = (v: string) => aplicar(v, '###.#####.##-#');
export const mascaraCEP = (v: string) => aplicar(v, '#####-###');
export const mascaraTelefone = (v: string) =>
  aplicar(v, digitos(v).length > 10 ? '(##) #####-####' : '(##) ####-####');

export const somenteDigitos = digitos;

/** CPF com 11 dígitos, não todos iguais e com os dois dígitos verificadores corretos */
export function cpfValido(v: string | null | undefined): boolean {
  const d = digitos(v ?? '');
  if (d.length !== 11 || /^(\d)\1{10}$/.test(d)) return false;
  const dv = (n: number) => {
    let s = 0;
    for (let i = 0; i < n; i++) s += Number(d[i]) * (n + 1 - i);
    const r = (s * 10) % 11;
    return r === 10 ? 0 : r;
  };
  return dv(9) === Number(d[9]) && dv(10) === Number(d[10]);
}
export const mascaraCNPJ = (v: string) => aplicar(v, '##.###.###/####-##');
