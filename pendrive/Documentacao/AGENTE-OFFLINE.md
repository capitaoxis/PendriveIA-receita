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
