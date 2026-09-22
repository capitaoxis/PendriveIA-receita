# Procura BYTE DE CONTROLE em arquivo nosso (texto, script, documento). Sai 1 se achar.
#
# POR QUE existe: escrever arquivo por heredoc/string come a barra invertida e deixa um byte de
# controle no lugar. Medido 3 vezes: 0x08 em regex do medidor, 0x07 em "Testes\avaliar-modos.py"
# (que virou "Testesavaliar-modos.py" - quem copiasse a linha rodaria comando com nome errado) e 0x0b
# em "diarizacao\voz.onnx" na skill da voz. NENHUM desses deu erro: o arquivo fica valido e errado.
#
# Uso: python Testes\conferir-bytes-de-controle.py
import io, os, sys

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOSSO = ("Menu", "Testes", "Documentacao")          # o que nos escrevemos
EXT = (".md", ".py", ".ps1", ".cmd", ".bat", ".txt", ".tsv", ".json")
PERMITIDO = {9, 10, 13}                              # tab, LF, CR
# logo.txt do JASP usa 0x1b (cor no terminal) de proposito e nao e nosso; nem entra na varredura


def maus_bytes(caminho):
    with io.open(caminho, "rb") as f:
        dados = f.read()
    return sorted({b for b in dados if b < 32 and b not in PERMITIDO})


def varrer():
    achados = []
    alvos = [os.path.join(RAIZ, p) for p in NOSSO] + [RAIZ]
    vistos = set()
    for alvo in alvos:
        anda = os.walk(alvo) if os.path.isdir(alvo) else []
        for pasta, subs, arquivos in anda:
            subs[:] = [s for s in subs if s not in (".git", "__pycache__", "node_modules")]
            if alvo == RAIZ and os.path.abspath(pasta) != RAIZ:
                continue                             # na raiz, so os arquivos soltos
            for a in arquivos:
                if not a.lower().endswith(EXT):
                    continue
                p = os.path.abspath(os.path.join(pasta, a))
                if p in vistos:
                    continue
                vistos.add(p)
                m = maus_bytes(p)
                if m:
                    achados.append((os.path.relpath(p, RAIZ), [hex(x) for x in m]))
    return achados, len(vistos)


def controle():
    """Planta um byte de controle num arquivo temporario e prova que a varredura o VE.
    Sem isso, uma varredura quebrada diria "nada encontrado" e passaria verde para sempre."""
    p = os.path.join(RAIZ, "Testes", "_controle_byte.md")
    io.open(p, "wb").write("teste".encode() + bytes([8]) + b"x")
    try:
        viu = bool(maus_bytes(p))
        achados, _ = varrer()
        na_varredura = any("_controle_byte.md" in a for a, _ in achados)
    finally:
        os.remove(p)
    return viu and na_varredura


if __name__ == "__main__":
    if not controle():
        print("A VARREDURA ESTA CEGA: plantei um 0x08 e ela nao acusou. Conserte antes de confiar.")
        sys.exit(2)
    achados, quantos = varrer()
    print(f"{quantos} arquivos nossos conferidos (controle: a varredura ENXERGA um 0x08 plantado)")
    if achados:
        print("")
        print(f"{len(achados)} arquivo(s) com byte de controle - provavel barra invertida comida:")
        for caminho, bs in achados:
            print(f"  {caminho}  ->  {', '.join(bs)}")
        sys.exit(1)
    print("nenhum byte de controle. OK")
