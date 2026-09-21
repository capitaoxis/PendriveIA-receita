# Agente de programacao offline: o modelo do pendrive le, edita e roda comando DENTRO de uma pasta.
# Uso:
#   python agente.py --pasta C:\projeto --testar "python rodar-testes.py" "conserte o que faz o teste falhar"
#   ... --voltas 8        teto de voltas (padrao 10)
#   ... --porta 11888     servidor ja no ar (senao sobe um com o modelo normal do pendrive)
#   ... --mostrar         imprime o que mudou em cada arquivo
#
# TRAVAS (modelo local erra, e agente que edita arquivo estraga coisa):
# - tudo preso a --pasta: caminho que sair dela e RECUSADO;
# - copia .antes de cada arquivo tocado, e --desfazer devolve tudo;
# - so roda comando; nao instala nada, nao acessa rede (o modelo e local);
# - para quando o comando de teste passa, ou quando acabam as voltas.
# O modelo TEM de saber chamar ferramenta: o Qwen3-8B sabe, o Qwen2.5-Coder NAO (medido 21/09/2026).
import argparse, json, os, shutil, subprocess, sys, time, urllib.request

sys.stdout.reconfigure(encoding="utf-8")
RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(RAIZ, "Studio", "app")
SEM_JANELA = getattr(subprocess, "CREATE_NO_WINDOW", 0)

FERRAMENTAS = [
    {"type": "function", "function": {"name": "ler_arquivo", "description": "Le um arquivo da pasta do projeto",
     "parameters": {"type": "object", "properties": {"caminho": {"type": "string"}}, "required": ["caminho"]}}},
    {"type": "function", "function": {"name": "escrever_arquivo",
     "description": "Grava o conteudo COMPLETO de um arquivo da pasta do projeto (o conteudo antigo e substituido)",
     "parameters": {"type": "object", "properties": {"caminho": {"type": "string"}, "conteudo": {"type": "string"}},
                    "required": ["caminho", "conteudo"]}}},
    {"type": "function", "function": {"name": "rodar_comando", "description": "Roda um comando na pasta do projeto e devolve a saida",
     "parameters": {"type": "object", "properties": {"comando": {"type": "string"}}, "required": ["comando"]}}},
]


class Projeto:
    """Guarda a pasta e garante que nada saia dela."""

    def __init__(self, pasta):
        self.pasta = os.path.abspath(pasta)
        self.tocados = {}

    def caminho(self, rel):
        p = os.path.abspath(os.path.join(self.pasta, rel))
        if os.path.commonpath([p, self.pasta]) != self.pasta:
            raise PermissionError(f"fora da pasta do projeto: {rel}")
        return p

    def ler_arquivo(self, caminho):
        p = self.caminho(caminho)
        if not os.path.exists(p):
            return f"ERRO: {caminho} nao existe. Arquivos da pasta: " + ", ".join(sorted(os.listdir(self.pasta))[:30])
        return open(p, encoding="utf-8", errors="replace").read()[:20000]

    def escrever_arquivo(self, caminho, conteudo):
        p = self.caminho(caminho)
        if p not in self.tocados and os.path.exists(p):
            shutil.copy2(p, p + ".antes")       # da para desfazer
            self.tocados[p] = True
        with open(p, "w", encoding="utf-8", newline="\n") as f:
            f.write(conteudo)
        return f"gravado: {caminho} ({len(conteudo)} letras). Copia do anterior em {os.path.basename(p)}.antes"

    # A trava de pasta NAO alcanca o terminal: "type ..\\segredo.txt" leu fora (medido 21/09/2026).
    # Isto aqui e QUEBRA-MOLA, nao caixa de areia: recusa a fuga obvia e a saida para a rede. Quem
    # roda o agente roda com a SUA conta: so aponte --pasta para projeto que voce deixaria um script solto.
    PROIBIDO = ("..", "%userprofile%", "$env:", "c:\\users", "c:\\windows", "curl", "wget",
                "invoke-webrequest", "start-bitstransfer", "net use", "reg ", "schtasks", "shutdown")

    def rodar_comando(self, comando):
        baixo = comando.lower()
        for termo in self.PROIBIDO:
            if termo in baixo:
                return (f"RECUSADO: o comando tem \"{termo}\", que sai da pasta do projeto ou usa a rede. "
                        "Trabalhe so com caminhos de dentro da pasta.")
        # o modelo costuma pedir "python3", que nao existe no Windows (medido 21/09/2026)
        comando = comando.replace("python3 ", "python ")
        try:
            r = subprocess.run(comando, shell=True, cwd=self.pasta, capture_output=True, text=True,
                               timeout=180, creationflags=SEM_JANELA)
        except subprocess.TimeoutExpired:
            return "ERRO: o comando passou de 3 minutos e foi interrompido."
        saida = ((r.stdout or "") + (r.stderr or "")).strip()
        return f"(codigo {r.returncode})\n{saida[:4000]}" if saida else f"(codigo {r.returncode}, sem saida)"


def subir_modelo(modelo, porta):
    backend = "cuda" if os.path.exists(os.path.join(APP, "llm-backend", "win", "cuda", "llama-server.exe")) else "cpu"
    exe = os.path.join(APP, "llm-backend", "win", backend, "llama-server.exe")
    chave = os.urandom(16).hex()
    env = dict(os.environ, LLAMA_API_KEY=chave, LLAMA_ARG_CHAT_TEMPLATE_KWARGS='{"enable_thinking":false}',
               PATH=os.path.join(APP, "llm-backend", "win", "cuda") + os.pathsep + os.environ["PATH"])
    a = [exe, "-m", os.path.join(APP, "llm-models", modelo), "--host", "127.0.0.1", "--port", str(porta),
         "-c", "40960", "--jinja", "--alias", "modelo"]     # contexto grande: com 16k o agente se perde
    if backend == "cuda":
        a += ["-ngl", "99"]
    p = subprocess.Popen(a, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, creationflags=SEM_JANELA)
    for _ in range(300):
        time.sleep(1)
        if p.poll() is not None:
            return None, None
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{porta}/health", timeout=2) as r:
                if json.load(r).get("status") == "ok":
                    return p, chave
        except Exception:
            pass
    p.kill()
    return None, None


def falar(porta, chave, msgs):
    corpo = json.dumps({"model": "modelo", "messages": msgs, "tools": FERRAMENTAS, "tool_choice": "auto",
                        "temperature": 0, "max_tokens": 1500}).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{porta}/v1/chat/completions", data=corpo,
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + chave})
    with urllib.request.urlopen(req, timeout=900) as r:
        return json.load(r)["choices"][0]["message"]


SISTEMA = """Voce e um programador que trabalha NESTA pasta, em portugues do Brasil.
Voce TEM ferramentas: ler_arquivo, escrever_arquivo e rodar_comando. Use-as; nunca peca permissao e
nunca diga que vai fazer: faca chamando a ferramenta.
Ordem de trabalho: 1) rode o comando de teste para VER o erro; 2) leia o arquivo culpado;
3) grave o arquivo corrigido inteiro com escrever_arquivo; 4) rode o teste de novo para PROVAR.
Regras: mude so o que causa a falha; nao toque no que ja passa; escreva o arquivo COMPLETO.
NAO acrescente funcao, classe nem arquivo novo: conserte o que ja existe, no arquivo onde ele esta.
Quando o teste passar, responda em uma linha: PRONTO: <o que era e o que voce mudou>."""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tarefa", nargs="*")
    ap.add_argument("--pasta", required=True)
    ap.add_argument("--testar", default="")
    ap.add_argument("--voltas", type=int, default=10)
    ap.add_argument("--porta", type=int, default=0)
    ap.add_argument("--modelo", default="unsloth--Qwen3.5-4B-GGUF--Qwen3.5-4B-Q4_K_M.gguf")   # medido 21/09: 4 s e sem lixo; o 8B leva 9-14 s e cria funcao sem uso
    ap.add_argument("--desfazer", action="store_true")
    ap.add_argument("--mostrar", action="store_true")
    a = ap.parse_args()
    proj = Projeto(a.pasta)

    if a.desfazer:
        n = 0
        for pasta, _, arqs in os.walk(proj.pasta):
            for arq in arqs:
                if arq.endswith(".antes"):
                    shutil.move(os.path.join(pasta, arq), os.path.join(pasta, arq[:-6]))
                    n += 1
        print(f"desfeito: {n} arquivo(s) voltaram ao estado anterior")
        return

    proc, chave = (None, None)
    porta = a.porta
    if porta:
        chave = os.environ.get("LLAMA_API_KEY", "")
    else:
        porta = 11888
        print(f"[subindo {a.modelo}; pode levar 1 min]", flush=True)
        proc, chave = subir_modelo(a.modelo, porta)
        if not proc:
            raise SystemExit("o modelo nao subiu")

    tarefa = " ".join(a.tarefa) or "conserte o que faz o teste falhar"
    # a lista de arquivos vai no pedido: sem ela o modelo chuta caminho ("src/conta.py") e gasta voltas
    arquivos = []
    for pasta, dirs, arqs in os.walk(proj.pasta):
        dirs[:] = [d for d in dirs if d not in ("__pycache__", ".git", "node_modules")]
        for arq in arqs:
            if not arq.endswith(".antes"):
                arquivos.append(os.path.relpath(os.path.join(pasta, arq), proj.pasta))
    tarefa += "\nArquivos desta pasta (use exatamente estes caminhos): " + ", ".join(sorted(arquivos)[:60])
    if a.testar:
        tarefa += f"\nComando de teste (rode-o com rodar_comando): {a.testar}"
    msgs = [{"role": "system", "content": SISTEMA}, {"role": "user", "content": tarefa}]
    t0 = time.time()
    try:
        for volta in range(1, a.voltas + 1):
            m = falar(porta, chave, msgs)
            if not m.get("tool_calls"):
                fala = (m.get("content") or "").strip()
                # a palavra do agente nao encerra o trabalho: em 2 de 4 testes ele disse PRONTO sem
                # ter resolvido (medido 21/09/2026). Quem encerra e o comando de teste.
                if a.testar:
                    saida = proj.rodar_comando(a.testar)
                    if not saida.startswith("(codigo 0"):
                        print(f"[volta {volta}] disse que acabou, mas o teste falha -> devolvendo o erro")
                        msgs.append(m)
                        msgs.append({"role": "user", "content":
                                     "O teste AINDA FALHA. Saida real:" + "\n" + saida[:2000] +
                                     "\nContinue: leia o arquivo certo, corrija e rode o teste de novo. Nao responda texto; chame ferramenta."})
                        continue
                print(f"[volta {volta}] {fala[:400]}")
                break
            msgs.append(m)
            for chamada in m["tool_calls"]:
                nome = chamada["function"]["name"]
                try:
                    args = json.loads(chamada["function"]["arguments"] or "{}")
                except json.JSONDecodeError:
                    args, resposta = {}, "ERRO: argumentos nao sao JSON valido"
                try:
                    resposta = getattr(proj, nome)(**args)
                except Exception as e:
                    resposta = f"ERRO: {type(e).__name__}: {e}"
                resumo = str(args.get("comando") or args.get("caminho") or "")[:60]
                print(f"[volta {volta}] {nome}({resumo}) -> {resposta.splitlines()[0][:90] if resposta else ''}", flush=True)
                msgs.append({"role": "tool", "tool_call_id": chamada.get("id", str(volta)), "content": resposta[:6000]})
        # a palavra do agente nao vale: quem diz se resolveu e o teste
        passou = None
        if a.testar:
            print("\n=== conferindo por fora (a palavra do agente nao vale) ===")
            saida = proj.rodar_comando(a.testar)
            print(saida)
            passou = saida.startswith("(codigo 0")
            if not passou:
                print("ATENCAO: o agente pode ter dito que resolveu, mas o teste AINDA FALHA.")
        if a.mostrar and proj.tocados:
            for p in proj.tocados:
                print(f"\n=== {os.path.basename(p)} (antes -> depois) ===")
                antes = open(p + ".antes", encoding="utf-8", errors="replace").read().splitlines()
                depois = open(p, encoding="utf-8", errors="replace").read().splitlines()
                import difflib
                print("\n".join(list(difflib.unified_diff(antes, depois, lineterm=""))[:40]))
        # o modelo acrescenta funcao sem uso mesmo proibido (medido 21/09/2026): a ferramenta AVISA,
        # em vez de confiar na obediencia dele. Quem decide manter ou tirar e a pessoa.
        acrescentados = []
        for p in proj.tocados:
            if not os.path.exists(p + ".antes"):
                continue
            def definicoes(caminho):
                fora = set()
                for linha in open(caminho, encoding="utf-8", errors="replace"):
                    if linha.startswith(("def ", "class ")):
                        fora.add(linha.strip().rstrip(":"))
                return fora
            for d in sorted(definicoes(p) - definicoes(p + ".antes")):
                acrescentados.append(f"{os.path.basename(p)}: {d}")
        if acrescentados:
            print("AVISO: o agente ACRESCENTOU codigo novo (confira se e necessario):")
            for x in acrescentados:
                print("  - " + x)
        print(f"\narquivos tocados: {len(proj.tocados)} | {time.time() - t0:.0f}s"
              f"{' | desfaca com --desfazer' if proj.tocados else ''}")
        if passou is False:
            raise SystemExit(1)
    finally:
        if proc:
            proc.kill()


if __name__ == "__main__":
    main()
