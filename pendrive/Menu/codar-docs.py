# Documentacao de programacao offline para o codar (devdocs + pt.stackoverflow em Kiwix\zim).
# Uso: python codar-docs.py <pasta-zim> "termo"        -> ate 3 trechos, cada um com [Fonte: ...]
#      python codar-docs.py <pasta-zim> "python: json.loads"   (prefixo escolhe o acervo)
import sys, re, html, glob, os
from libzim.reader import Archive
from libzim.search import Query, Searcher
from libzim.suggestion import SuggestionSearcher

sys.stdout.reconfigure(encoding="utf-8")
pasta, termo = sys.argv[1], " ".join(sys.argv[2:]).strip()
ACERVOS = ["python", "javascript", "node", "react", "typescript", "postgresql", "git", "docker", "bash", "css", "html", "nextjs"]
alvo = None
m = re.match(r"^(\w+)\s*:\s*(.+)$", termo)
if m and m.group(1).lower() in ACERVOS + ["stackoverflow", "so"]:
    alvo, termo = m.group(1).lower(), m.group(2)
else:  # palavra do acervo dentro do termo tambem escolhe (ex.: "python dataclass")
    for a in ACERVOS:
        if re.search(rf"\b{a}\b", termo.lower()):
            alvo = a; termo = re.sub(rf"(?i)\b{a}\b", "", termo).strip() or termo; break

PARADAS = set("o a os as um uma de do da dos das em no na nos nas por para com sem que qual como quando onde e ou se ao ler usar fazer criar funcao arquivo exemplo".split())
limpo = " ".join(p for p in re.findall(r"[\w.\-]+", termo) if p.lower() not in PARADAS)
termo_pt = termo          # a pergunta inteira vai para o pt.stackoverflow (texto em portugues)
termo = limpo or termo

zims = []
for z in sorted(glob.glob(os.path.join(pasta, "devdocs_en_*.zim"))):
    nome = os.path.basename(z).split("_")[2]
    if alvo in (None, nome):
        zims.append((f"devdocs {nome}", z))
if alvo in (None, "stackoverflow", "so"):
    zims += [("pt.stackoverflow", z) for z in glob.glob(os.path.join(pasta, "pt.stackoverflow.com_*.zim"))]
if alvo in ACERVOS:   # a duvida pode estar respondida em portugues
    zims += [("pt.stackoverflow", z) for z in glob.glob(os.path.join(pasta, "pt.stackoverflow.com_*.zim"))]

def texto_de(entry):
    bruto = bytes(entry.get_item().content).decode("utf-8", "ignore")
    bruto = re.sub(r"(?is)<(script|style|nav|header|footer)[^>]*>.*?</\1>", " ", bruto)
    bruto = re.sub(r"(?i)<(br|p|div|pre|li|h\d|tr)[^>]*>", "\n", bruto)
    t = html.unescape(re.sub(r"<[^>]+>", "", bruto))
    return re.sub(r"\n\s*\n+", "\n", re.sub(r"[ \t]+", " ", t)).strip()

palavras = [p.lower() for p in re.findall(r"[\w.]+", termo) if len(p) > 1]
achados = []
for rotulo, z in zims:
    try:
        arq = Archive(z)
    except Exception:
        continue
    q = (termo + (" " + alvo if alvo in ACERVOS else "")) if rotulo == "pt.stackoverflow" else termo
    caminhos = list(SuggestionSearcher(arq).suggest(q).getResults(0, 2))
    if arq.has_fulltext_index and len(caminhos) < 2:
        try: caminhos += list(Searcher(arq).search(Query().set_query(q)).getResults(0, 2))
        except Exception: pass
    for c in list(dict.fromkeys(caminhos))[:2]:
        try: e = arq.get_entry_by_path(c)
        except Exception: continue
        t = texto_de(e)
        if not t: continue
        titulo = e.title.lower()
        nota = 3 * sum(w in titulo for w in palavras) + sum(t.lower().count(w) for w in palavras) / 10
        # trecho: comeco + a parte com mais palavras do termo
        i = max((t.lower().find(w) for w in palavras), default=0)
        trecho = t[:700] + ("\n(...)\n" + t[max(i - 200, 700):i + 900] if i > 900 else t[700:1500])
        achados.append((nota, f"[Fonte: {rotulo} - {e.title} ({c})]\n{trecho.strip()}"))
achados.sort(key=lambda x: -x[0])
visto = set(); achados = [a for a in achados if not (a[1].split(']')[0] in visto or visto.add(a[1].split(']')[0]))]
print("\n\n".join(a for _, a in achados[:3]) if achados else "")
