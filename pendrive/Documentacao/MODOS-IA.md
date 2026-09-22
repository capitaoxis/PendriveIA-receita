# Modos de trabalho da IA local (19/09/2026)

A IA local é fraca comparada às de internet: ela **inventa**, enrola e esquece o que importa. Os modos
são instruções curtas que corrigem isso por uso. Ficam em `Menu\modos\*.md` — texto simples, dá para
editar e criar novos.

## Como usar

```powershell
ia -modo codar     "por que esse script grava vazio?"
ia -modo relatorio -f dados.txt "escreva os resultados"
ia -modo ideia     "vale abrir uma clínica de fisioterapia domiciliar?"
ia -modo curto     "comando para ver o espaço livre do disco"
ia -d mestrado -modo relatorio "resuma o capítulo 2"   # nos Documentos também
```

## O que cada modo cobra da IA

| Modo | Exige | Proíbe |
|---|---|---|
| `codar` | prova do defeito (o que foi medido ou lido), uma causa por vez, teste que falha antes e passa depois | consertar código que ela não viu, inventar função ou biblioteca |
| `relatorio` | só o material dado, fonte de cada número, fato separado de "(hipótese)", seção "O QUE FALTA" | número de pessoas/sessões/% que não está no material |
| `ideia` | quem paga, marco de 14 dias que não é programar, critério de desistir, custo e break-even, maior risco | empolgação, "depois eu divulgo", chutar custo que você não deu |
| `curto` | resposta direta, no máximo 6 linhas, número e comando exatos | introdução, resumo da pergunta, oferta de ajuda extra |
| `mestrado` | desenho do estudo e o que ele NÃO permite concluir, "[referencia a buscar: X]", "O QUE FALTA" | citação `(SOBRENOME, ano)` de referência que não está no material, p-valor inventado |
| `laudo` | relato / medido / conclusão com "(hipótese)" / "CONFERIR ANTES DE ASSINAR", aviso de LGPD | CID, dose, exame ou data inventados, promessa de resultado, nome do paciente quando cabe a inicial |

## Medido, não achado

`Testes\avaliar-modos.py` roda 18 casos (3 por modo), cada um **duas vezes: sem e com o modo**, e
confere automaticamente o que a resposta precisa ter e o que não pode ter. Com o Qwen3-8B na placa:

| Modo | Sem modo | Com modo | Tamanho da resposta |
|---|---|---|---|
| codar | 0/3 | **3/3** | 734 → 436 letras |
| relatorio | 1/3 | **3/3** | 1.041 → 899 letras |
| ideia | 0/3 | **3/3** | 1.447 → 288 letras |
| curto | 3/3 | **3/3** | 355 → **58** letras |
| mestrado | 1/3 | **2/3** | 968 → 578 letras |
| laudo | 0/3 | **2/3** | 398 → 1.298 letras (aqui crescer é certo: o laudo precisa das seções) |

Total dos 6 modos: **5/18 sem modo, 16/18 com modo**. Nos 4 primeiros: **4/12 sem, 12/12 com**, e respostas de 2 a 6 vezes menores (menos tempo e menos
leitura). Rodar de novo: `python Testes\avaliar-modos.py` (sobe um llama-server próprio e fecha).

## Três coisas que a medição ensinou

1. **O modo `curto` já passava sem modo**: o ganho dele não é acerto, é tamanho (6x menor). Sem medir,
   eu teria contado isso como acerto.
2. **Dois "erros do modo" eram erros do meu teste**: eu exigia "teste que confere" de uma resposta que
   corretamente apenas pedia o arquivo, e exigia interpretação onde não havia o que interpretar.
3. **A IA chuta número com cara de certeza.** No teste real ela escreveu "custo R$ 3.000/mês" sem eu ter
   dado o número. Só parou quando a regra passou a exigir "(você informa)". Vale para relatório e ideia:
   **número que você não deu, não é dado — é chute.**

## Ao criar um modo novo

- Curto e concreto. Texto longo o modelo ignora; regra com exemplo errado/certo ele segue.
- Termine com um FORMATO de saída (seções em maiúsculas). É o que mais muda a resposta.
- Acrescente 3 casos em `Testes\avaliar-modos.py` com o que a resposta precisa ter e o que não pode.
  Sem isso, não se sabe se o modo ajuda ou só enfeita.

## Os dois modos do mestrado e do laudo (20/09)

- **O `mestrado` primeiro NÃO ajudou** (1/3 sem e 1/3 com). Causa medida: a minha regra 2 *convidava* a
  citar em ABNT, e o modelo inventava "(SOBRENOME, ano)". Virou proibição explícita, com
  "[referencia a buscar: <assunto>]" no lugar, e passou a 2/3. O caso que ainda falha é o parágrafo de
  introdução: ele quer citar, e às vezes cita sem fonte. **Confira toda citação antes de usar.**
- **O `laudo` foi de 0/3 para 2/3.** Ele já recusa prometer "vai melhorar em 10 sessões" (responde com
  hipótese) e avisa da LGPD quando se pede para mandar laudo por WhatsApp, sugerindo inicial no lugar do
  nome. O caso que falha é escrever "(nao medido)" quando nada foi medido.
- Aqui a resposta com modo **cresceu** (398 → 1.298 letras), ao contrário dos outros. É esperado: o
  formato exige relato, medido, conclusão, conduta e o que conferir antes de assinar.

## No modelo LEVE (PC sem placa) o quadro muda — medido 21/09

Os numeros acima sao do Qwen3-8B na placa. Rodando o mesmo medidor com o **Qwen3-1.7B** (o modelo que o
menu escolhe em PC sem placa):

| Modo | Sem modo | Com modo |
|---|---|---|
| codar | 0/3 | 1/3 |
| relatorio | 0/3 | 2/3 |
| ideia | 0/3 | 2/3 |
| mestrado | 1/3 | **3/3** |
| laudo | 0/3 | 2/3 |
| curto | **3/3** | **2/3 (piorou)** |

Total: **4/18 sem modo, 12/18 com modo** — os modos ainda ajudam, mas menos que no 8B (16/18).

**O caso que piorou é o que mais ensina:** com o modelo leve, o `curto` fez ele cortar até a resposta.
"Nome da capital do Amazonas?" virou "amazonas - brasilia" em vez de Manaus. No 8B o mesmo modo acerta
3/3. Ou seja: **quanto mais fraco o modelo, mais perigoso pedir brevidade** — ele economiza a parte certa.

Recomendacao pratica:
- Em PC com placa (Qwen3-8B): use os modos livremente, inclusive o `curto`.
- Em PC sem placa (Qwen3-1.7B): use `relatorio`, `ideia`, `mestrado` e `laudo`; **evite o `curto`** e
  desconfie do `codar`, que cai para 1/3. Para pergunta de fato (data, nome, comando), prefira sem modo.
- Rodar o medidor em outro PC: `python Testesvaliar-modos.py --modelo <arquivo .gguf>`.

## 21/09 (tarde): 17/18 no 8B e 15/18 no leve — e tres defeitos do MEDIDOR

Placar com temperatura 0 (determinístico), 18 casos + 2 controles:

| Modo | 8B (com placa) | 1.7B (sem placa) |
|---|---|---|
| codar | **3/3** | **3/3** |
| relatorio | **3/3** | 2/3 |
| ideia | **3/3** | **3/3** |
| mestrado | 2/3 | **3/3** |
| laudo | **3/3** | 2/3 |
| curto | **3/3** | 2/3 |
| **total** | **17/18** (sem modo: 4/18) | **15/18** (sem modo: 3/18) |

### O que melhorou nos modos
- **`codar` (1/3 → 3/3 no leve):** trocar "Formato: CAUSA / CORRECAO / COMO CONFERIR" por **três linhas
  literais** que o modelo copia. Ao fazer isso, o 8B parou de escrever a linha corrigida do código —
  consertado exigindo "se o usuario MOSTROU o codigo, escreva a linha ja corrigida". Resposta do 8B
  caiu de 436 para **118 letras** com o mesmo acerto.
- **`laudo` (0/3 → 3/3 no 8B):** encurtado de 231 para 155 palavras, com as regras duras **primeiro**
  (envio/LGPD, nome, promessa). Modelo fraco obedece o começo e ignora o fim: a versão longa levou o
  1.7B de 2/3 para 0/3.
- **`mestrado`:** proibida a citação `(AUTOR, ano)` que não veio do material; toda afirmação de fato
  termina com `[referencia a buscar: <assunto>]`.

### Três defeitos que eram do MEDIDOR, não dos modos
1. **Comparava sem acento:** procurava "nao medido" e a IA respondia "não medido" — resposta certa
   reprovada. Agora a conferência tira acento dos dois lados.
2. **Temperatura 0,3:** o placar variava entre execuções, e dava para "melhorar" um modo só rodando de
   novo até dar sorte. Agora é **temperatura 0**.
3. **Exigia ver "J.S." ou "código":** o 8B simplesmente **não escreveu o nome do paciente**, que é o
   comportamento certo, e era reprovado. Agora o teste cobra o que importa: o nome **não pode aparecer**.

Moral: quando o placar não bate com a leitura das respostas, **desconfie do medidor antes do modo**.

## 22/09: o `curto` parou de piorar no modelo fraco
Era o único modo que **piorava** o acerto no Qwen3-1.7B (3/3 sem modo, 2/3 com). Causa: pressionado a
economizar, ele repetia o tema em vez de responder ("capital do Amazonas?" → "amazonas"). A regra nova
diz isso na cara: *"se a pergunta tem resposta de uma palavra, escreva ESSA palavra; nunca repita o tema
no lugar da resposta"*. Medido depois: **3/3 no 1.7B** (resposta de 6 letras contra 89 sem modo) e
**3/3 no 4B** (5 letras contra 202).
