# OCR dos livros escaneados (PDF/EPUB que sao so imagem) para eles aparecerem na busca, sem internet.
# Usa o pdftoppm do Calibre + o Tesseract portatil que veio no NAPS2 (portugues), tudo do pendrive.
# Uso:
#   python livros-ocr.py                      -> OCR nos livros sem texto (30 primeiras paginas cada)
#   python livros-ocr.py --paginas 60 --processos 4 --limite 5
# So le a biblioteca; escreve no indice (Livros\indice\livros.db) marcando erro='ocr: N paginas'.
# As imagens temporarias ficam em Livros\indice\ocr-tmp (nunca no %TEMP% do PC) e sao apagadas.
import os, re, sys, sqlite3, subprocess, tempfile, shutil, time, zipfile
from concurrent.futures import ProcessPoolExecutor

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAL = os.path.join(RAIZ, "Ferramentas", "Calibre Portable", "Calibre", "app", "bin")
PDFTOPPM = os.path.join(CAL, "pdftoppm.exe")
# O Tesseract vem no NAPS2 do pendrive; NAPS2_DIR aponta outra pasta (usado ao trabalhar numa copia)
NAPS2 = os.environ.get("NAPS2_DIR") or os.path.join(RAIZ, "Ferramentas", "NAPS2")
TESSERACT = os.path.join(NAPS2, "App", "lib", "_win64", "tesseract.exe")
TESSDATA = os.path.join(NAPS2, "Data", "components", "tesseract4", "fast")
DB = os.path.join(RAIZ, "Livros", "indice", "livros.db")
TMP = os.path.join(RAIZ, "Livros", "indice", "ocr-tmp")
TAM = 800
SEM_JANELA = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def paginas_do_epub(arq, destino, paginas):
    """EPUB escaneado: as paginas sao imagens dentro do zip, em ordem de nome."""
    saida = []
    with zipfile.ZipFile(arq) as z:
        imgs = sorted(n for n in z.namelist() if n.lower().endswith((".jpg", ".jpeg", ".png")))
        for i, n in enumerate(imgs[:paginas]):
            p = os.path.join(destino, f"pag-{i:04d}" + os.path.splitext(n)[1].lower())
            with open(p, "wb") as f:
                f.write(z.read(n))
            saida.append(p)
    return saida


def ocr_livro(tarefa):
    lid, arq, paginas = tarefa
    pasta = tempfile.mkdtemp(dir=TMP)
    try:
        if arq.lower().endswith(".pdf"):
            # 200 dpi e o que o Tesseract pede; -f/-l limitam as paginas
            subprocess.run([PDFTOPPM, "-r", os.environ.get("OCR_DPI", "150"), "-f", "1", "-l", str(paginas), "-png", arq, os.path.join(pasta, "pag")],
                           capture_output=True, timeout=1800, creationflags=SEM_JANELA)
            imgs = sorted(f for f in os.listdir(pasta) if f.endswith(".png"))
            imgs = [os.path.join(pasta, f) for f in imgs]
        else:
            imgs = paginas_do_epub(arq, pasta, paginas)
        if not imgs:
            return lid, "", 0, "nao consegui gerar imagem da pagina"
        lista = os.path.join(pasta, "lista.txt")
        with open(lista, "w", encoding="utf-8") as f:
            f.write("\n".join(imgs))
        env = dict(os.environ, TESSDATA_PREFIX=TESSDATA)
        r = subprocess.run([TESSERACT, lista, os.path.join(pasta, "saida"), "-l", "por"],
                           capture_output=True, timeout=7200, creationflags=SEM_JANELA, env=env)
        txt = os.path.join(pasta, "saida.txt")
        if not os.path.exists(txt):
            return lid, "", 0, "tesseract falhou: " + r.stderr.decode("utf-8", "ignore")[-120:]
        texto = re.sub(r"\s+", " ", open(txt, encoding="utf-8", errors="replace").read()).strip()
        return lid, texto, len(imgs), None
    except Exception as e:
        return lid, "", 0, f"{type(e).__name__}: {e}"[:150]
    finally:
        shutil.rmtree(pasta, ignore_errors=True)


def pedacos(txt):
    saida, p = [], 0
    while p < len(txt):
        fim = min(p + TAM, len(txt))
        if fim < len(txt):
            esp = txt.rfind(" ", p + TAM - 120, fim)
            fim = esp if esp > p else fim
        saida.append(txt[p:fim].strip())
        p = fim
    return saida


def main(paginas=30, processos=4, limite=0):
    os.makedirs(TMP, exist_ok=True)
    for p in (PDFTOPPM, TESSERACT, os.path.join(TESSDATA, "por.traineddata"), DB):
        if not os.path.exists(p):
            raise SystemExit("nao encontrei " + p)
    c = sqlite3.connect(DB)
    c.execute("PRAGMA journal_mode=WAL")
    # so livro sem texto que ainda nao passou por OCR
    alvos = [(lid, os.path.join(RAIZ, cam)) for lid, cam in
             c.execute("SELECT id, caminho FROM livros WHERE erro IS NOT NULL AND erro NOT LIKE 'ocr:%'").fetchall()]
    alvos = [(lid, arq) for lid, arq in alvos if os.path.exists(arq)]
    if limite:
        alvos = alvos[:limite]
    print(f"{len(alvos)} livros escaneados para OCR ({paginas} paginas cada, {processos} por vez)", flush=True)
    t0, feitos, comTexto, ntrechos = time.time(), 0, 0, 0
    with ProcessPoolExecutor(max_workers=processos) as ex:
        for lid, texto, npag, erro in ex.map(ocr_livro, [(lid, arq, paginas) for lid, arq in alvos]):
            feitos += 1
            titulo, autor = c.execute("SELECT titulo, autor FROM livros WHERE id=?", (lid,)).fetchone()
            ps = pedacos(texto) if len(texto) > 200 else []
            if ps:
                c.execute("DELETE FROM trechos WHERE livro_id=?", (lid,))
                c.executemany("INSERT INTO trechos(texto,titulo,autor,livro_id) VALUES(?,?,?,?)",
                              [(t, titulo, autor, lid) for t in ps])
                comTexto += 1
                ntrechos += len(ps)
            c.execute("UPDATE livros SET trechos=?, erro=? WHERE id=?",
                      (len(ps), f"ocr: {npag} paginas" if ps else (erro or "ocr sem texto"), lid))
            c.commit()
            if feitos % 5 == 0 or feitos == len(alvos):
                print(f"{feitos}/{len(alvos)} | com texto: {comTexto} | {ntrechos} trechos | {time.time()-t0:.0f}s", flush=True)
    c.execute("INSERT INTO trechos(trechos) VALUES('optimize')")
    c.commit()
    c.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    c.close()
    shutil.rmtree(TMP, ignore_errors=True)
    print(f"RESUMO: {feitos} livros com OCR | {comTexto} passaram a ter texto | {ntrechos} trechos novos | {time.time()-t0:.0f}s")


if __name__ == "__main__":
    a = sys.argv[1:]
    def val(nome, padrao):
        return int(a[a.index(nome) + 1]) if nome in a else padrao
    main(val("--paginas", 30), val("--processos", 4), val("--limite", 0))
