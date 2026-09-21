# Agente de programação offline no pendrive — o que dá e o que não dá (21/09/2026)

Hoje o pendrive **conversa** sobre código (`ia -modo codar`). Um **agente** é outra coisa: ele lê
arquivo, edita, roda comando e confere o resultado sozinho. Candidato avaliado:
[openclaude](https://github.com/Gitlawb/openclaude) — CLI de agente que fala com servidor local
compatível com OpenAI, que é exatamente o que o pendrive já expõe.

## O achado que decide tudo, e é contraintuitivo

Um agente só funciona se o modelo **chamar ferramenta** pela API (`tool_calls`). Medido direto contra
o `llama-server` do pendrive, com a mesma pergunta e a mesma definição de ferramenta:

| Modelo | Chama ferramenta? |
|---|---|
| `Qwen2.5-Coder-7B` — o modelo "de código" (`ia -m codigo`) | **NÃO.** Devolve a chamada como **texto**, dentro de um bloco ```xml. Nenhum agente funciona assim. |
| `Qwen3-8B` — o modelo normal | **SIM**, chamada de verdade, com nome e argumentos. |

**Portanto: para agente, use o modelo normal, não o "de código".** O nome engana.

Ciclo completo provado sem internet, com o Qwen3-8B: ele pediu `rodar_comando("python rodar-testes.py")`,
recebeu a saída real (`TESTES: FALHOU -> soma(2,3) deu -1, esperado 5`) e concluiu certo na volta
seguinte. Script do teste: `teste-openclaude\ciclo.py` (fora do pendrive).

## Atrito previsto

- O modelo pediu `python3`, que **não existe no Windows**. Qualquer agente vai tropeçar nisso até
  aprender pelo erro — e um modelo fraco pode não aprender. Vale dar o comando exato no pedido.
- Agente que edita arquivo com modelo fraco **apaga o que não devia**. Só usar em pasta com git, ou
  descartável, e nunca apontar para a biblioteca, os Documentos ou a pasta de atendimentos.
- `npm install -g @gitlawb/openclaude` avisou "removed 657 packages". Conferido: os pacotes globais
  (Gemini CLI, agent-browser, pnpm...) continuaram lá e o Claude Code não foi afetado, porque não é npm.

## Como ligar, quando quiser testar

```powershell
# 1) sobe o modelo do pendrive como servidor compativel com OpenAI
$env:LLAMA_API_KEY = "<uma chave qualquer>"
llama-server.exe -m Qwen3-8B-Q4_K_M.gguf --host 127.0.0.1 --port 11888 -c 16384 --jinja -ngl 99 --alias qwen3

# 2) aponta o agente para ele
$env:CLAUDE_CODE_USE_OPENAI = 1
$env:OPENAI_BASE_URL = "http://127.0.0.1:11888/v1"
$env:OPENAI_API_KEY  = "<a mesma chave>"
$env:OPENAI_MODEL    = "qwen3"
openclaude --print "rode X, ache a causa, corrija e prove com o teste"
```

## Estado

**Não instalado no pendrive.** O teste ficou em `C:\Users\Pichau\teste-openclaude` (25 KB, mais o
pacote npm global). A execução do agente em si foi **bloqueada pelo ambiente** do Claude Code
("criar agente não confiável"), então o que está provado é a parte do modelo — que era a parte
incerta. Rodar o agente de ponta a ponta depende de liberar essa permissão.

## O que fizemos no lugar: `Menu\agente.py` (21/09/2026)

O openclaude diagnosticava e não consertava. Como o ciclo de ferramenta com o modelo local já estava
provado, escrevemos o nosso: **um arquivo, 230 linhas, sem Node, sem 300 MB**.

```powershell
python Menu\agente.py --pasta C:\meu\projeto --testar "python rodar-testes.py" "conserte o que falha"
python Menu\agente.py --pasta C:\meu\projeto --desfazer      # devolve tudo ao estado anterior
```
Opções: `--voltas N` (teto), `--mostrar` (diff do que mudou), `--modelo <gguf>`, `--porta` (servidor já no ar).

### Medido nos quatro testes

| Teste | Resultado |
|---|---|
| Defeito simples (`return a - b`) | ✅ consertou e provou em **9 s**; não tocou na função correta |
| Defeito em **dois** arquivos | ✅ consertou os dois em **14 s** |
| Tarefa **impossível** (teste contraditório) | ✅ **não** declara sucesso falso: volta ao trabalho e termina vermelho, com código de saída 1 |
| Tentar **sair da pasta** | ✅ ler/escrever recusados; comando de terminal recusado depois do conserto |
| **Qwen3.5-4B** (o de PC sem placa) | ✅ **melhor de todos**: os dois casos em **4 s**, correção limpa, sem acrescentar nada |
| **Qwen3-1.7B** (o mais leve) | ❌ não funciona: gravou 578 letras de lixo e nunca resolveu |

### As quatro coisas que a medição obrigou a construir

1. **A palavra do agente não vale.** Em 2 dos 4 testes ele disse "PRONTO" sem ter resolvido. Hoje,
   quando ele diz que acabou, o agente **roda o teste, devolve o erro e manda continuar**; e no fim
   confere por fora. Sem `--testar`, você fica na palavra dele — use sempre.
2. **Listar os arquivos no pedido.** Sem isso ele chutava `src/conta.py` e queimava 3 voltas.
3. **Avisar o que ele acrescentou.** Mesmo proibido, ele cria função sem uso. A ferramenta compara com
   a cópia `.antes` e **lista as definições novas** no fim: quem decide manter é você.
4. **Traduzir `python3` para `python`**, que o modelo insiste em pedir no Windows.

### O que NÃO é

**Não é caixa de areia.** A trava de pasta vale para ler e escrever; no terminal é **quebra-mola**
(recusa `..`, caminhos do Windows, `curl` e afins). Quem roda o agente roda com a sua conta: aponte
`--pasta` só para projeto que você deixaria um script solto, e prefira pasta com git.

**Qual modelo usar:** o **Qwen3.5-4B** é o melhor para o agente — mais rápido (4 s) e mais limpo que o
8B, que insiste em criar função sem uso. O **1.7B não serve**: estraga o arquivo. Ressalva medida: os 4 s
são **com placa de vídeo**; em PC sem placa o mesmo 4B roda a ~6 tokens/s, então espere minutos em vez de
segundos — funciona, mas com paciência.
