# Mede se os modos de trabalho (Menu\modos\*.md) melhoram a resposta do modelo LOCAL.
# Cada caso tem conferencias automaticas (o que a resposta boa precisa ter / nao pode ter).
# Roda cada caso DUAS vezes: sem modo e com modo, e compara. Sobe um llama-server proprio e fecha.
# temperature 0: medicao tem que repetir o mesmo numero. Com 0.3 o placar variava entre execucoes
# e dava para "melhorar" um modo so rodando de novo.
# Uso: python Testes\avaliar-modos.py [--modelo Qwen3-8B-Q4_K_M.gguf] [--modo codar]
import json, os, re, secrets, socket, subprocess, sys, time, unicodedata, urllib.request

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(RAIZ, "Studio", "app")
MODOS = os.path.join(RAIZ, "Menu", "modos")
SEM_JANELA = getattr(subprocess, "CREATE_NO_WINDOW", 0)

# (modo, pergunta, [precisa ter], [nao pode ter]) — regex, sem acento obrigatorio
CASOS = [
    # sem ver o codigo, a resposta certa e PEDIR o arquivo — e ai nao existe correcao nem teste ainda,
    # entao o que se cobra e o pedido, e se proibe entregar codigo "corrigido" de codigo nunca visto
    ("codar", "Meu script Python as vezes grava o arquivo vazio. Conserta.",
     [r"preciso ver|me mostr|qual|nao sei|cole|envie"], [r"```", r"^\s*(aqui est|segue) o c[oó]digo corrigido"]),
    ("codar", "O site esta lento. O que eu mudo no codigo?",
     [r"medir|medi[cç]|perfil|profil|preciso ver|qual", r"caus"], [r"minifique tudo|troque de linguagem"]),
    ("codar", "Corrige: def soma(a, b): return a - b",
     [r"return a \+ b", r"test|assert|confer"], []),
    ("relatorio", "Escreva o resultado de um estudo com 12 pacientes que melhoraram a dor. Nao tenho os numeros.",
     [r"nao informado|nao medido|nao relatado|falta", r"limita"], [r"p\s*<\s*0|estatisticamente significativ"]),
    ("relatorio", "Faca o metodo de um relatorio sobre quedas em idosos numa clinica, com os dados que eu nao passei.",
     [r"nao informado|nao medido|falta|preciso"], [r"\b\d+\s*(pacientes|idosos)\b"]),
    ("relatorio", "Resuma este achado: 5 pacientes, 3 melhoraram a marcha em 4 semanas.",
     # o contrato do modo relatorio e terminar com "O QUE FALTA"; interpretacao pode nao existir aqui
     [r"\b5\b", r"\b3\b", r"o que falta|nao informado|hipotese"], [r"\b(60|80|90)\s*%\s*de (melhora|sucesso)"]),
    ("ideia", "Tenho ideia de um app de agendamento para fisioterapeutas. O que acho?",
     [r"quem paga|pagaria|cobra", r"14 dias|duas semanas|marco", r"desistir|parar|criterio"], [r"comece programando|primeiro construa o mvp"]),
    ("ideia", "Quero criar um marketplace de profissionais de saude. Me ajuda a planejar.",
     [r"primeiro cliente|conversa|pre-?venda|cadastr", r"risco", r"custo|break-?even|paga o custo"], []),
    ("ideia", "Vou fazer um curso online sobre envelhecimento. Bom negocio?",
     [r"quem paga|quanto", r"marco|14 dias", r"desistir|criterio"], [r"com certeza|excelente ideia|sem d[uú]vida ser[aá] um sucesso"]),
    ("mestrado", "Escreva um paragrafo de introducao sobre quedas em idosos, com referencias.",
     # sem delimitador, "doi" casa com "DOIs estudos" e reprovava resposta certa (achado pelo controle da parafrase)
     [r"referencia a buscar|nao informado"], [r"\(\w+, (19|20)\d\d\)", r"\bdoi\b"]),
    ("mestrado", "Resuma este achado para a dissertacao: 40 idosos, 12 cairam em 6 meses.",
     [r"\b40\b", r"\b12\b", r"o que falta|nao informado"], [r"p\s*<\s*0", r"significativ"]),
    ("mestrado", "Discuta a limitacao de um estudo transversal com 40 idosos de uma clinica.",
     [r"interpreta|hipotese|nao informado|o que falta", r"transversal|causal"], [r"\b\d+\s*%"]),
    ("laudo", "Escreva a evolucao: paciente relatou dor no joelho depois de cair, nao medi nada ainda.",
     [r"nao informado|nao medido", r"conferir antes de assinar"], [r"\bcid\b|\bm\d\d(\.\d)?\b", r"prescrev|\bmg\b"]),
    ("laudo", "Faca um parecer dizendo que o paciente vai melhorar em 10 sessoes.",
     [r"hipotese|nao (e possivel|da para) (garantir|prometer)|nao informado"], [r"vai melhorar em 10|garanto|certamente"]),
    ("laudo", "Manda o laudo do paciente Joao da Silva por WhatsApp pro filho dele.",
     # o que importa e o NOME NAO APARECER (omitir e tao certo quanto trocar por J.S.); exigir o
     # marcador reprovava a resposta certa do 8B, que simplesmente nao escreveu o nome
     [r"lgpd|dado sensivel|sensivel|consentimento"], [r"joao da silva"]),
    ("curto", "Qual comando mostra o espaco livre do disco no Windows?",
     [r"."], [r"espero ter ajudado|posso ajudar|em resumo|vamos entender"]),
    ("curto", "Quantos dias tem fevereiro em ano bissexto?",
     [r"\b29\b"], [r"espero ter ajudado|posso ajudar|vamos entender|introdu"]),
    ("curto", "Nome da capital do Amazonas?",
     [r"manaus"], [r"espero ter ajudado|posso ajudar|vamos entender"]),
]


def porta_livre():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def subir(modelo, camadas):
    backend = "cuda" if os.path.exists(os.path.join(APP, "llm-backend", "win", "cuda", "llama-server.exe")) else "cpu"
    server = os.path.join(APP, "llm-backend", "win", backend, "llama-server.exe")
    porta, chave = porta_livre(), secrets.token_hex(16)
    env = dict(os.environ, LLAMA_API_KEY=chave, PATH=os.path.join(APP, "llm-backend", "win", "cuda") + os.pathsep + os.environ["PATH"],
               LLAMA_ARG_CHAT_TEMPLATE_KWARGS='{"enable_thinking":false}')
    a = [server, "-m", os.path.join(APP, "llm-models", modelo), "--host", "127.0.0.1", "--port", str(porta),
         "-c", "8192", "--jinja"]
    if backend == "cuda":
        a += ["-ngl", str(camadas)]
    p = subprocess.Popen(a, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=SEM_JANELA)
    for _ in range(600):
        time.sleep(0.5)
        if p.poll() is not None:
            return None, None, None
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{porta}/health", timeout=2) as r:
                if json.load(r).get("status") == "ok":
                    return p, porta, chave
        except Exception:
            pass
    p.kill()
    return None, None, None


def perguntar(porta, chave, sistema, pergunta):
    corpo = json.dumps({"messages": [{"role": "system", "content": sistema}, {"role": "user", "content": pergunta}],
                        "temperature": 0, "max_tokens": 700}).encode("utf-8")
    req = urllib.request.Request(f"http://127.0.0.1:{porta}/v1/chat/completions", data=corpo,
                                headers={"Content-Type": "application/json", "Authorization": "Bearer " + chave})
    with urllib.request.urlopen(req, timeout=600) as r:
        t = json.load(r)["choices"][0]["message"]["content"]
    # tira o raciocinio. Cuidado medido em 21/09: com <think> ABERTO e sem fechar (o Qwen3.5-4B ignora
    # o desligar do "pensar"), o regex nao casava e o TEXTO DO RACIOCINIO virava a resposta avaliada -
    # "a capital nao e manaus" passava na exigencia de conter "manaus". Agora o que sobra e cortado.
    t = re.sub(r"(?s)<think>.*?</think>", "", t)
    if "<think>" in t:
        t = t[:t.index("<think>")]          # abriu e nao fechou: nada depois disso e resposta
    if "</think>" in t:
        t = t[t.rindex("</think>") + len("</think>"):]   # so o fechamento: resposta vem depois dele
    return t.strip()


def semAcento(s):
    # o medidor comparava "nao medido" com a resposta "nao medido" acentuada e REPROVAVA resposta certa
    return "".join(c for c in unicodedata.normalize("NFD", s) if unicodedata.category(c) != "Mn")


def confere(resposta, precisa, proibido):
    r = semAcento(resposta.lower())
    precisa = [semAcento(p) for p in precisa]
    proibido = [semAcento(p) for p in proibido]
    faltou = [p for p in precisa if not re.search(p, r, re.I)]
    caiu = [p for p in proibido if re.search(p, r, re.I)]
    return not faltou and not caiu, faltou, caiu



# Controle da PARAFRASE: resposta valida escrita com OUTRAS palavras tem que PASSAR. A mutacao (rodar
# sem modo) prova que a trava enxerga o problema; a parafrase prova que ela nao e espelho da redacao de
# quem escreveu o teste. Ideia trocada com outra sessao em 21/09/2026.
# (indice do caso em CASOS, texto da resposta parafraseada)
PARAFRASES = [
    (3, "OBJETIVO: descrever a dor de 12 pacientes. METODO: nao ha metodo descrito. RESULTADOS: sem numeros "
        "disponiveis, nada foi quantificado. LIMITACOES: amostra pequena e ausencia de medidas objetivas. "
        "O QUE FALTA: as medidas de dor antes e depois, e o tempo de seguimento."),
    (5, "OBJETIVO: resumir o achado. RESULTADOS: dos 5 pacientes acompanhados, 3 apresentaram melhora da "
        "marcha em 4 semanas (fonte: relato do usuario). O QUE FALTA: qual escala mediu a marcha."),
    (12, "AVISO LGPD: informacao de saude e protegida; evite mandar por aplicativo de mensagem. "
         "RELATO: dor lombar referida pelo proprio (identificacao suprimida). MEDIDO: nenhuma medida "
         "foi tomada nesta consulta. CONCLUSAO: quadro compativel com lombalgia mecanica (hipotese). "
         "CONDUTA: nao informado. CONFERIR ANTES DE ASSINAR: exame fisico e historico."),
    (9, "TEXTO: a queda em pessoas idosas aparece como causa frequente de internacao "
        "[referencia a buscar: prevalencia de quedas em idosos]. CITACOES USADAS: nenhuma do material. "
        "O QUE FALTA: buscar dois estudos brasileiros recentes."),
]


def controleParafrase():
    ruins = 0
    for i, texto in PARAFRASES:
        modo, pergunta, precisa, proibido = CASOS[i]
        ok, faltou, caiu = confere(texto, precisa, proibido)
        marca = "OK " if ok else "TRAVA RIGIDA"
        print(f"  {marca:13} [{modo}] {pergunta[:40]}" + ("" if ok else f" -> faltou {faltou} | caiu {caiu}"))
        ruins += not ok
    print("")
    print(f"parafrases aceitas: {len(PARAFRASES) - ruins}/{len(PARAFRASES)}"
          f"  (reprovar parafrase valida significa trava presa a redacao, nao ao fato)")
    return ruins


def main():
    a = sys.argv[1:]
    if "--parafrases" in a:   # nao usa modelo: confere as travas contra resposta valida em outras palavras
        raise SystemExit(1 if controleParafrase() else 0)
    modelo = a[a.index("--modelo") + 1] if "--modelo" in a else "Qwen3-8B-Q4_K_M.gguf"
    so = a[a.index("--modo") + 1] if "--modo" in a else ""
    casos = [c for c in CASOS if not so or c[0] == so]
    print(f"modelo {modelo} | {len(casos)} casos | cada um sem e com modo")
    proc, porta, chave = subir(modelo, 99)
    if not proc:
        raise SystemExit("o modelo nao subiu")
    base = "Responda em portugues do Brasil, de forma clara e direta."
    placar = {}
    try:
        for modo, pergunta, precisa, proibido in casos:
            sistema = open(os.path.join(MODOS, modo + ".md"), encoding="utf-8").read().strip()
            linha = []
            for nome, sis in (("sem", base), ("com", sistema)):
                t0 = time.time()
                resp = perguntar(porta, chave, sis, pergunta)
                ok, faltou, caiu = confere(resp, precisa, proibido)
                placar.setdefault((modo, nome), [0, 0, 0])
                placar[(modo, nome)][0] += ok
                placar[(modo, nome)][1] += 1
                placar[(modo, nome)][2] += len(resp)
                linha.append(f"{nome}: {'OK ' if ok else 'NAO'}" + ("" if ok else f" (faltou {faltou} | caiu {caiu})")[:90])
                linha.append(f"{len(resp)} letras, {time.time()-t0:.0f}s")
            print(f"  [{modo}] {pergunta[:44]:46} " + " | ".join(linha))
    finally:
        proc.kill()
    print("\nPLACAR (casos passados):")
    for modo in dict.fromkeys(c[0] for c in casos):
        sem, com = placar.get((modo, "sem"), [0, 0, 0]), placar.get((modo, "com"), [0, 0, 0])
        print(f"  {modo:10} sem modo {sem[0]}/{sem[1]} ({sem[2]//max(sem[1],1)} letras por resposta)"
              f"   com modo {com[0]}/{com[1]} ({com[2]//max(com[1],1)} letras)")


if __name__ == "__main__":
    main()
