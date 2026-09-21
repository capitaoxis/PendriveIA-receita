# Busca na Wikipedia offline (arquivos .zim do pendrive) e devolve os melhores trechos.
# Uso: python ia-wiki.py <pasta-zim> "pergunta"   -> texto com [Titulo] e trecho de cada artigo
import sys, re, html, glob, os
from libzim.reader import Archive
from libzim.search import Query, Searcher
from libzim.suggestion import SuggestionSearcher

pasta, pergunta = sys.argv[1], " ".join(sys.argv[2:])
sys.stdout.reconfigure(encoding="utf-8")
PARADAS = set("o a os as um uma de do da dos das em no na nos nas por para com sem que qual quais quem como quando onde e ou se ao aos é são ser foi mais menos sobre me explique diga fale principais principal quais fatores tipos causas".split())
palavras = [p for p in re.findall(r"[\wÀ-ÿ-]+", pergunta.lower()) if p not in PARADAS and len(p) > 2]
consulta = " ".join(palavras) or pergunta

zims = sorted(glob.glob(os.path.join(pasta, "wikipedia_pt*.zim")), key=os.path.getsize, reverse=True)
achados, vistos = [], set()
for z in zims:
    arq = Archive(z)
    if not arq.has_fulltext_index:
        continue
    # primeiro artigos cujo TITULO bate com pares de palavras da pergunta, depois busca no texto
    caminhos = []
    pares = [" ".join(palavras[i:i + 2]) for i in range(len(palavras) - 1)][::-1] or [consulta]
    for termo in [consulta] + pares:
        for c in SuggestionSearcher(arq).suggest(termo).getResults(0, 2):
            if c not in caminhos:
                caminhos.append(c)
        if len(caminhos) >= 2:
            break
    caminhos = caminhos[:2] + list(Searcher(arq).search(Query().set_query(consulta)).getResults(0, 3))
    for caminho in caminhos:
        e = arq.get_entry_by_path(caminho)
        if e.title in vistos:
            continue
        vistos.add(e.title)
        bruto = bytes(e.get_item().content).decode("utf-8", "ignore")
        bruto = re.sub(r"(?is)<(script|style|table|sup)[^>]*>.*?</\1>", " ", bruto)
        texto = html.unescape(re.sub(r"<[^>]+>", " ", bruto))
        texto = re.sub(r"\s+", " ", texto).strip()
        # trechos de ~600 caracteres; ficam o comeco e os que mais tem palavras da pergunta
        pedacos = [texto[i:i + 600] for i in range(0, len(texto), 600)]
        nota = lambda p: sum(p.lower().count(w) for w in palavras)
        melhores = sorted(sorted(range(1, len(pedacos)), key=lambda i: -nota(pedacos[i]))[:5])
        achados.append(f"[{e.title}] " + " (...) ".join(pedacos[i] for i in [0] + melhores))
    if len(achados) >= 3:
        break
print("\n\n".join(achados[:3]) if achados else "")
