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
