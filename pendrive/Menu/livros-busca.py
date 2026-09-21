# Busca nos livros do Calibre do pendrive (indice SQLite FTS5, sem internet).
# Uso:
#   python livros-busca.py "pergunta"          -> 6 melhores trechos: [Titulo — Autor] trecho
#   python livros-busca.py --livros "assunto"  -> quais LIVROS falam disso (titulo + n de trechos)
#   python livros-busca.py --indexar [--max-trechos N]  -> cria/atualiza o indice (incremental)
# Indice: <pendrive>\Livros\indice\livros.db   (direito autoral: uso pessoal, fica so no pendrive)
import sys, os, re, html, itertools, zipfile, sqlite3, subprocess, time, shutil, faulthandler, urllib.request

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIBLIO = os.path.join(RAIZ, "Ferramentas", "Calibre Portable", "Calibre Library")
PDFTOTEXT = os.path.join(RAIZ, "Ferramentas", "Calibre Portable", "Calibre", "app", "bin", "pdftotext.exe")
DB = os.path.join(RAIZ, "Livros", "indice", "livros.db")
TAM = 800
sys.stdout.reconfigure(encoding="utf-8")


def abrir():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    c = sqlite3.connect(DB)
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE IF NOT EXISTS livros(id INTEGER PRIMARY KEY, caminho TEXT UNIQUE, tamanho INT, mtime INT, titulo TEXT, autor TEXT, trechos INT, erro TEXT)")
    c.execute("CREATE VIRTUAL TABLE IF NOT EXISTS trechos USING fts5(texto, titulo, autor, livro_id UNINDEXED, tokenize='unicode61 remove_diacritics 2')")
    return c


def metadados():
    """Titulo/autor pelo metadata.db do Calibre (copia em Livros/indice, so leitura; nada no %TEMP% do PC)."""
    orig = os.path.join(BIBLIO, "metadata.db")
    meta = {}
    if not os.path.exists(orig):
        return meta
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    tmp = os.path.join(os.path.dirname(DB), "metadata-copia.db")
    try:
        shutil.copy2(orig, tmp)
        m = sqlite3.connect(tmp)
        try:
            for path, titulo, autor in m.execute("SELECT b.path, b.title, b.author_sort FROM books b"):
                meta[os.path.normcase(os.path.join(BIBLIO, path))] = (titulo, autor or "")
        finally:
            m.close()
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)
    return meta


def texto_epub(arq):
    partes = []
    with zipfile.ZipFile(arq) as z:
        nomes = [n for n in z.namelist() if n.lower().endswith((".html", ".xhtml", ".htm"))]
        # ordem do spine quando der; senao ordem do zip
        try:
            opf = next(n for n in z.namelist() if n.lower().endswith(".opf"))
            o = z.read(opf).decode("utf-8", "ignore")
            base = os.path.dirname(opf)
            man = dict(re.findall(r'<item\b[^>]*?id="([^"]+)"[^>]*?href="([^"]+)"', o))
            man.update({i: h for h, i in re.findall(r'<item\b[^>]*?href="([^"]+)"[^>]*?id="([^"]+)"', o)})
            ordem = [(base + "/" if base else "") + man[i] for i in re.findall(r'<itemref\b[^>]*?idref="([^"]+)"', o) if i in man]
            ordem = [n.replace("%20", " ") for n in ordem]
            nomes = [n for n in ordem if n in z.namelist()] or nomes
        except Exception:
            pass
        for n in nomes:
            b = z.read(n).decode("utf-8", "ignore")
            b = re.sub(r"(?is)<(script|style|head)[^>]*>.*?</\1>", " ", b)
            partes.append(html.unescape(re.sub(r"<[^>]+>", " ", b)))
    return " ".join(partes)


def texto_pdf(arq):
    r = subprocess.run([PDFTOTEXT, "-enc", "UTF-8", "-q", arq, "-"], capture_output=True, timeout=600,
                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return r.stdout.decode("utf-8", "ignore")


def indexar(max_trechos=None):
    c = abrir()
    meta = metadados()
    ja = {row[0]: (row[1], row[2]) for row in c.execute("SELECT caminho, tamanho, mtime FROM livros")}
    arquivos = []
    for pasta, _, fs in os.walk(BIBLIO):
        # um formato por livro: prefere EPUB
        eps = [f for f in fs if f.lower().endswith(".epub")]
        pds = [f for f in fs if f.lower().endswith(".pdf")]
        for f in (eps[:1] or pds[:1]):
            arquivos.append(os.path.join(pasta, f))
    t0, novos, pulados, erros, ntrechos = time.time(), 0, 0, 0, 0
    for i, arq in enumerate(arquivos, 1):
        rel = os.path.relpath(arq, RAIZ)
        st = os.stat(arq)
        if ja.get(rel) == (st.st_size, int(st.st_mtime)):
            pulados += 1
            continue
        titulo, autor = meta.get(os.path.normcase(os.path.dirname(arq)),
                                 (os.path.splitext(os.path.basename(arq))[0], ""))
        velho = c.execute("SELECT id FROM livros WHERE caminho=?", (rel,)).fetchone()
        if velho:
            c.execute("DELETE FROM trechos WHERE livro_id=?", (velho[0],))
            c.execute("DELETE FROM livros WHERE id=?", (velho[0],))
        with open(os.path.join(os.path.dirname(DB), 'atual.txt'), 'w', encoding='utf-8') as fa:
            fa.write(f'{i} {rel}')
        erro = None
        try:
            txt = texto_epub(arq) if arq.lower().endswith(".epub") else texto_pdf(arq)
        except Exception as e:
            txt, erro = "", f"{type(e).__name__}: {e}"[:200]
        txt = re.sub(r"\s+", " ", txt).strip()
        pedacos = []
        p = 0
        while p < len(txt):
            fim = min(p + TAM, len(txt))
            if fim < len(txt):  # corta no fim de palavra
                esp = txt.rfind(" ", p + TAM - 120, fim)
                fim = esp if esp > p else fim
            pedacos.append(txt[p:fim].strip())
            p = fim
        if max_trechos:
            pedacos = pedacos[:max_trechos]
        if not pedacos and not erro:
            erro = "sem texto (PDF escaneado?)"
        cur = c.execute("INSERT INTO livros(caminho,tamanho,mtime,titulo,autor,trechos,erro) VALUES(?,?,?,?,?,?,?)",
                        (rel, st.st_size, int(st.st_mtime), titulo, autor, len(pedacos), erro))
        lid = cur.lastrowid
        c.executemany("INSERT INTO trechos(texto,titulo,autor,livro_id) VALUES(?,?,?,?)",
                      [(t, titulo, autor, lid) for t in pedacos])
        c.commit()
        novos += 1
        ntrechos += len(pedacos)
        erros += bool(erro)
        if novos % 25 == 0:
            print(f"{i}/{len(arquivos)} livros | {ntrechos} trechos | {time.time() - t0:.0f}s", flush=True)
    # livros que sairam da biblioteca: tira do indice (so se a biblioteca existe e tem livro, senao apagaria tudo)
    removidos = 0
    if os.path.isdir(BIBLIO) and arquivos:
        for lid, rel in c.execute("SELECT id, caminho FROM livros").fetchall():
            if not os.path.exists(os.path.join(RAIZ, rel)):
                c.execute("DELETE FROM trechos WHERE livro_id=?", (lid,))
                c.execute("DELETE FROM livros WHERE id=?", (lid,))
                removidos += 1
        c.commit()
    c.execute("INSERT INTO trechos(trechos) VALUES('optimize')")
    c.commit()
    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    tot = c.execute("SELECT count(*), sum(trechos) FROM livros").fetchone()
    c.close()
    mb = os.path.getsize(DB) / 2**20
    print(f"RESUMO: {len(arquivos)} livros na biblioteca | {novos} indexados agora, {pulados} ja estavam, {erros} com erro/sem texto, {removidos} removidos | "
          f"total {tot[0]} livros, {tot[1] or 0} trechos | indice {mb:.0f} MB | {time.time() - t0:.0f}s")


PARADAS = set("o a os as um uma de do da dos das em no na nos nas por para com sem que qual quais quem como quando onde e ou se ao aos é são ser foi mais menos sobre me explique diga fale principais principal fatores tipos causas the of and".split())


TITULO_RUIM = re.compile(
    # extensao no titulo (o .epub faltava: "...como salva-la.epub"), nome de programa, titulo de
    # digitalizacao ("Impressao de foto de pagina inteira") e titulo com escape de PDF (\343)
    r"\.(cdr|docx?|indd|pdf|qxd|pmd|rtf|epub|mobi|azw3?|txt)\b"
    r"|^(microsoft\s+word|untitled|unknown|sem t[ií]tulo|documento\d*|livro|e-?book|scan|digitaliza)\b"
    r"|foto de p.{0,6}gina inteira|impress.{0,6}o de foto"
    r"|\\\d{3}|^\\?\(|^[\d\s_.-]+$", re.I)
AUTOR_RUIM = {"", "unknown", "desconhecido", "administrador", "admin", "user", "usuario", "usuário"}


def nomes_originais():
    """id do Calibre -> nome do arquivo de origem, pelo registro do importar-livros.ps1."""
    reg, nomes = os.path.join(RAIZ, "Livros", "importados.tsv"), {}
    if os.path.exists(reg):
        with open(reg, encoding="utf-8-sig", errors="replace") as f:
            for linha in f:
                partes = linha.rstrip("\n").split("\t")
                if len(partes) >= 3 and partes[2].strip().isdigit():
                    nomes[partes[2].strip()] = os.path.splitext(os.path.basename(partes[0]))[0].replace("_", " ")
    return nomes


def nome_do_livro(titulo, autor, caminho, originais):
    """Titulo/autor apresentaveis: o PDF muitas vezes traz 'Ebook final-2.cdr' e autor vazio;
    a pasta do Calibre (Autor\\Titulo (id)) e o nome do arquivo original dizem melhor."""
    partes = caminho.replace("/", "\\").split("\\")
    if (autor or "").strip().lower() in AUTOR_RUIM and len(partes) >= 3 and partes[-3].strip().lower() not in AUTOR_RUIM:
        autor = partes[-3]
    if TITULO_RUIM.search(titulo or ""):
        m = re.search(r"\((\d+)\)$", partes[-2]) if len(partes) >= 2 else None
        orig = originais.get(m.group(1)) if m else None
        if orig and not TITULO_RUIM.search(orig):
            titulo = orig
        else:
            # sem nome original guardado: limpa o que der (extensao, "Microsoft Word -", escape \343)
            limpo = re.sub(r"^microsoft\s+word\s*-\s*", "", titulo, flags=re.I)
            limpo = re.sub(r"\.(cdr|docx?|indd|pdf|qxd|pmd|rtf|epub|mobi|azw3?|txt)\b", "", limpo, flags=re.I)
            limpo = re.sub(r"\\+\d{3}|\\+", "", limpo).strip(" ()-_")
            titulo = limpo or titulo
    # autor que e nome de arquivo ou frase inteira nao e autor: o Calibre tira do nome do arquivo
    # quando o PDF/EPUB nao diz ("salva-la.epub, O povo contra a democracia Por que nossa...")
    if (autor or "").strip().lower() in AUTOR_RUIM or len(autor or "") > 45 or TITULO_RUIM.search(autor or ""):
        autor = ""
    return titulo, autor


def radical(p):
    """Prefixo para pegar singular/plural e variacoes (quedas -> qued*, prevenir -> preven*)."""
    return p if len(p) <= 4 else p[:max(4, len(p) - 2)]


def buscar(pergunta, n=6):
    if not os.path.exists(DB):
        return ""
    palavras = [p for p in re.findall(r"[\wÀ-ÿ-]+", pergunta.lower()) if p not in PARADAS and len(p) > 2]
    if not palavras:
        return ""
    exatos = ['"' + p.replace('"', "") + '"' for p in palavras]
    prefixos = ['"' + radical(p).replace('"', "") + '"*' for p in palavras]
    c = sqlite3.connect("file:" + urllib.request.pathname2url(DB) + "?mode=ro", uri=True)
    # "ORDER BY rank" e o caminho rapido do FTS5 (bm25 com peso 2 para titulo/autor)
    sql = "SELECT livro_id, texto FROM trechos WHERE trechos MATCH ? AND rank MATCH 'bm25(1.0, 2.0, 2.0)' ORDER BY rank LIMIT 60"
    linhas = []
    # todas as palavras (exatas, depois com variacao); se nada tem todas, tira uma, depois duas...
    # sempre com 2/3 das palavras e no minimo 2 (metade deixava "xyzzy foguete marciano" achar Eca). Nunca "qualquer palavra": trazia dicionario e
    # romance ate para pergunta sem sentido, e a IA citava isso como fonte em vez de dizer que nao achou.
    for consulta in (" AND ".join(exatos), " AND ".join(prefixos)):
        linhas += c.execute(sql, (consulta,)).fetchall()
        if len({lid for lid, _ in linhas}) >= n:
            break
    prefixos = prefixos[:6]
    # A palavra mais rara nunca sai da busca: sem isso "manutencao motor foguete falcon" achava
    # livro qualquer por "manutencao" + "motor" (2 de 3 basta) e a IA citava isso como fonte.
    def documentos(termo):
        return c.execute("SELECT count(*) FROM trechos WHERE trechos MATCH ?", (termo,)).fetchone()[0]
    raro = min(prefixos, key=documentos) if len(prefixos) > 1 else None
    # So pergunta longa (5+ palavras) pode perder palavra: em pergunta curta, exigir todas e' o que
    # separa "achei" de "inventei" (com 3 palavras, 2 bastavam e vinha romance).
    k = len(prefixos) - 1 if len(prefixos) >= 5 else 0
    while not linhas and k >= max(3, -(-2 * len(prefixos) // 3)):
        for grupo in itertools.combinations(prefixos, k):
            if raro and raro not in grupo:
                continue
            linhas += c.execute(sql, (" AND ".join(grupo),)).fetchall()
        k -= 1
    info = {lid: c.execute("SELECT titulo, autor, caminho FROM livros WHERE id=?", (lid,)).fetchone()
            for lid in {lid for lid, _ in linhas}}
    c.close()
    originais = nomes_originais()
    # tabela de palavras-chave, indice e lista de numeros casam com a busca mas nao respondem nada:
    # sao poucos numeros/pontuacao e quase nenhuma palavra de ligacao. Texto corrido vem primeiro.
    LIGACAO = set("de da do das dos e em no na para com que uma um os as por ao se nao como mais".split())
    def prosa(t):
        pal = re.findall(r"[\wÀ-ÿ]+", t.lower())
        if len(pal) < 12:
            return False
        simbolos = sum(c.isdigit() or c in "[]|()/%:;" for c in t) / max(len(t), 1)
        ligacao = sum(p in LIGACAO for p in pal) / len(pal)
        return simbolos < 0.10 and ligacao > 0.10
    # livro cujo TITULO fala do assunto vem antes: "exercicios de fortalecimento muscular" trazia
    # gabarito de prova na frente do livro de exercicio. Ordem: titulo casa E e prosa > prosa > resto.
    def tituloCasa(lid):
        dados = info.get(lid)
        if not dados:
            return False
        titulo = (dados[0] or "").lower()
        return any(radical(p) in titulo for p in palavras)
    linhas = sorted(linhas, key=lambda l: (not (tituloCasa(l[0]) and prosa(l[1])), not prosa(l[1])))
    achados, por_livro, vistos = [], {}, set()
    for lid, texto in linhas:  # no maximo 2 trechos por livro
        if texto in vistos or not info.get(lid):
            continue
        titulo, autor = nome_do_livro(*info[lid], originais)
        # pelo TITULO, nao pelo registro: a biblioteca tem 530 copias repetidas (um guia aparece 27
        # vezes) e um livro so podia ocupar os 6 trechos com o mesmo texto
        mesmo = re.sub(r"[^a-z0-9]+", "", re.sub(r"\(\d+\)$", "", titulo.lower()))[:60]
        if por_livro.get(mesmo, 0) >= 2:
            continue
        vistos.add(texto)
        por_livro[mesmo] = por_livro.get(mesmo, 0) + 1
        achados.append(f"[{titulo} — {autor}] {texto}" if autor else f"[{titulo}] {texto}")
        if len(achados) >= n:
            break
    return "\n\n".join(achados)


def livros_sobre(pergunta, n=15):
    """Quais LIVROS falam do assunto: titulo + quantos trechos casaram. Com 5 mil livros, saber que
    livro existe e tao util quanto ler o trecho."""
    if not os.path.exists(DB):
        return ""
    palavras = [p for p in re.findall(r"[\wÀ-ÿ-]+", pergunta.lower()) if p not in PARADAS and len(p) > 2]
    if not palavras:
        return ""
    termos = ['"' + radical(p).replace('"', "") + '"*' for p in palavras]
    c = sqlite3.connect("file:" + urllib.request.pathname2url(DB) + "?mode=ro", uri=True)
    sql = ("SELECT livro_id, count(*) FROM trechos WHERE trechos MATCH ? "
           "GROUP BY livro_id ORDER BY 2 DESC LIMIT 200")
    # aqui e navegacao ("que livro fala disso"), nao citacao: se exigir todas as palavras nao sobra
    # nada ("fisioterapia equilibrio idoso" no mesmo trecho de 800 letras e raro), entao vai soltando
    # a palavra mais comum. O numero de trechos na saida mostra quao forte e cada livro.
    comuns = sorted(termos, key=lambda t: -c.execute("SELECT count(*) FROM trechos WHERE trechos MATCH ?", (t,)).fetchone()[0])
    linhas = []
    usados = list(termos)
    while usados and not linhas:
        linhas = c.execute(sql, (" AND ".join(usados),)).fetchall()
        if not linhas:
            usados = [t for t in usados if t != comuns[0]]
            comuns = comuns[1:]
    contas = {}
    for lid, quantos in linhas:
        info = c.execute("SELECT titulo, autor, caminho FROM livros WHERE id=?", (lid,)).fetchone()
        if info:
            contas[lid] = (quantos, info)
    c.close()
    originais = nomes_originais()
    vistos, saida = set(), []
    if len(usados) < len(termos):   # avisa quando afrouxou, para ninguem ler 1 trecho como "o livro fala disso"
        saida.append(f"(nenhum livro tem todas as palavras; mostrando com {len(usados)} de {len(termos)})")
    for quantos, info in sorted(contas.values(), key=lambda x: -x[0]):
        titulo, autor = nome_do_livro(*info, originais)
        chave = re.sub(r"[^a-z0-9]+", "", re.sub(r"\(\d+\)\s*$", "", titulo.lower()))[:60]
        if chave in vistos:      # a biblioteca tem 530 copias de titulo repetido ("... (2)")
            continue
        vistos.add(chave)
        saida.append(f"{quantos:4d} trechos  {titulo}" + (f" - {autor}" if autor else ""))
        if len(saida) >= n:
            break
    return "\n".join(saida)


if __name__ == "__main__":
    faulthandler.enable()
    a = sys.argv[1:]
    if a and a[0] == "--livros":
        print(livros_sobre(" ".join(a[1:])))
    elif a and a[0] == "--indexar":
        mx = int(a[a.index("--max-trechos") + 1]) if "--max-trechos" in a else None
        indexar(mx)
    elif a:
        print(buscar(" ".join(a)))
    else:
        print(__doc__ or 'uso: livros-busca.py "pergunta" | --indexar')
