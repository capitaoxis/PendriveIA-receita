# Mede a busca nos livros do pendrive: 10 perguntas com o livro que deve aparecer.
# Uso: python Testes\avaliar-busca-livros.py [outro\livros-busca.py]
# Exige o indice pronto (Livros\indice\livros.db). Com outra biblioteca os livros esperados mudam.
# Medido em 19/09/2026 com 5.116 livros: 19/20 no top 6, 17/20 no 1o trecho, 0/2 inventando fonte.
import re, sys, os, importlib.util

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAMINHO = sys.argv[1] if len(sys.argv) > 1 else os.path.join(RAIZ, "Menu", "livros-busca.py")
_s = importlib.util.spec_from_file_location("lb", CAMINHO)
lb = importlib.util.module_from_spec(_s)
_s.loader.exec_module(lb)

CASOS = [
    ("adestramento de cães", r"adestramento|c[ãa]o perfeito|cachorro"),
    ("receitas sem glúten", r"sem gl[úu]ten"),
    ("desfralde autismo", r"desfralde"),
    ("prevenção de quedas em idosos", r"idoso|gerontologia|terceira idade"),
    ("inteligência financeira investimentos", r"financ"),
    ("plantas medicinais", r"plantas.medicinais|fitoterap"),
    ("receitas de banho e beleza", r"banho e beleza"),
    ("É assim que acaba Colleen Hoover", r"hoover|assim que"),
    ("disfagia deglutição", r"cabeca e pescoco|cabeça e pescoço|fonoaudiolog|degluti"),
    ("bolo de chocolate", r"chocolate|cacau|bolo|doce|confeitaria"),
    ("amamentação recém-nascido", r"amamenta|mam[ãa]e conta|materno"),
    ("ansiedade transtorno tratamento", r"ansiedade"),
    ("horta comunitária", r"horta"),
    ("Alzheimer cuidador", r"alzheimer|demencia|dem[êe]ncia|idoso"),
    ("yoga para a saúde", r"yoga"),
    ("violência contra a mulher", r"viol[êe]ncia|mulher"),
    ("exercícios de fortalecimento muscular", r"exerc|muscul|fisioterap|forca|força|treino"),
    ("saúde mental no trabalho", r"sa[úu]de mental|trabalho|psicossocial|psicolog"),
    ("aleitamento e nutrição infantil", r"nutri|aleitamento|infantil|crian"),
    ("currículo e sexualidade na escola", r"curriculo|curr[íi]culo|sexualidade|escola|educa"),
]

# Perguntas que NAO devem achar nada (a busca nao pode inventar fonte)
VAZIOS = [
    "manutenção do motor do foguete Falcon 9",
    "xyzzy plutonio marciano quantico",
]

acertos = primeiros = 0
for pergunta, esperado in CASOS:
    achados = lb.buscar(pergunta, n=6)
    livros = re.findall(r"^\[([^\]]+)\]", achados, re.M)
    ok = [i for i, l in enumerate(livros) if re.search(esperado, l, re.I)]
    acertos += bool(ok)
    primeiros += bool(ok) and ok[0] == 0
    marca = "OK " if ok else "NAO"
    print(f"{marca} {pergunta:42} 1o: {(livros[0] if livros else '(vazio)')[:52]}")
falsos = 0
for pergunta in VAZIOS:
    achados = lb.buscar(pergunta, n=6)
    if achados.strip():
        falsos += 1
        print("INVENTOU " + pergunta[:42] + " -> " + re.findall(r"^\[([^\]]+)\]", achados, re.M)[0][:40])
    else:
        print(f"OK  {pergunta:42} (nada, como esperado)")

n = len(CASOS)
print(f"\nachou o livro certo nos 6 trechos: {acertos}/{n} | ja no 1o trecho: {primeiros}/{n} | "
      f"inventou fonte sem resposta: {falsos}/{len(VAZIOS)}")
