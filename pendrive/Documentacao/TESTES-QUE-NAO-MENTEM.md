# Testes que não mentem

Em 21/09/2026, medindo os modos da IA local, **quatro dos defeitos que apareceram estavam no medidor e
nenhum no que ele media**. Outra sessão, mexendo em copy e CSS nos marketplaces no mesmo dia, chegou ao
mesmo padrão: de tudo que "falhou", a maioria era instrumento. Este documento é o que sobrou disso.

## Os quatro bugs do medidor, e o que cada um ensina

| Bug | Sintoma | Por que passou tanto tempo |
|---|---|---|
| Comparava sem acento (`nao medido` vs "não medido") | placar pior | ninguém investiga uma reprovação: parece que o prompt é ruim |
| Media com temperatura 0,3 | placar mudava a cada execução | dava para "melhorar" um prompt só rodando de novo até dar sorte |
| Exigia ver o marcador `J.S.` | reprovava resposta certa | a resposta certa **omitia** o nome, que é ainda melhor que trocar |
| `<think>` aberto e sem fechar | **aprovava resposta errada** | aprovar errado **não tem sintoma**: ninguém investiga um teste que passou |

O último é o pior justamente por não incomodar. Os outros três pelo menos davam trabalho.

## Os dois controles que toda trava precisa

Uma trava sem controle é uma opinião. Cada uma precisa de **dois** casos:

1. **Mutação** — estrague o que ela vigia; ela tem que **reprovar**.
   Aqui isso é "rodar sem o modo": se o placar sem modo é igual ao com modo, a trava não vigia nada.
2. **Paráfrase** — escreva a resposta certa com **outras palavras**; ela tem que **aprovar**.
   Sem este, a trava é espelho da redação de quem a escreveu.

`Testes\avaliar-modos.py --parafrases` roda o segundo sem carregar modelo. Na primeira execução ele
achou um proibido `doi` (para DOI inventado) que casava com a palavra **"dois"**: qualquer resposta que
dissesse "buscar dois estudos" era reprovada.

## Fato ou contrato: o que travar

- Se a frase é **um dos muitos jeitos** de dizer a coisa → trave o **fato**, aceite paráfrase.
  Exigir "J.S." reprovava quem simplesmente não escreveu o nome. O invariante era "o nome não aparece".
- Se a frase foi **imposta pela especificação** → trave a **frase**, porque ali a frase é o fato.
  O modo `laudo` manda "responda com estas cinco linhas, começando exatamente assim"; cobrar
  `CONFERIR ANTES DE ASSINAR:` testa se o formato foi cumprido, não o gosto de quem escreveu o teste.

O teste para saber em qual caso você está: **alguém que cumpriu a exigência poderia, de boa-fé, ter
escrito diferente?** Se poderia, é paráfrase. Se não poderia sem descumprir a especificação, é contrato.

## Onde a trava olha também mente

Antes de desconfiar do que a trava exige, confira **onde** ela olha:

- **A âncora do recorte é única?** A outra sessão recortava o bloco da garantia ancorando na primeira
  ocorrência de "30 dias" — e a página já dizia "avisamos 30 dias antes da primeira cobrança" bem antes.
  O teste lia a região errada e reprovava texto correto.
- **O que você remove antes de avaliar pode não ter sido removido.** Foi o caso do `<think>` órfão.
- **A varredura enxerga o que procura?** Antes de confiar num "limpo", crie de propósito o problema e
  veja a varredura acusar. Varredura cega devolve "limpo" para tudo.

## E o que nada disso substitui

Os defeitos **reais** daquele dia — dos dois lados — só apareceram quando se parou de ler e se
**executou**: uma tela de teste real, um comando rodando, uma resposta de modelo de verdade. `grep`
confere texto, não comportamento.


## A barra invertida comida, e a trava que nasceu dela (22/09/2026)

Escrever arquivo por heredoc ou por string come a barra invertida e deixa um **byte de controle** no
lugar. Aconteceu **quatro vezes** e nenhuma delas deu erro:

| onde | o que virou | consequencia |
|---|---|---|
| regex do medidor (21/09) | `\b` -> 0x08 | trava mais frouxa do que parecia |
| `Documentacao\MODOS-IA.md` | `\a` -> 0x07 | a linha ficou `Testesavaliar-modos.py`: **quem copiasse rodaria comando com nome errado** |
| skill `pendrive-voz` (2 copias) | `\v` -> 0x0b | caminho do modelo de voz virou `diarizacao\x0boz.onnx` |
| casos do modo `commit` (22/09) | `\b` -> 0x08 | `\bchore\b` virou `0x08chore0x08`, que **nunca casa**: a proibicao estava MORTA e o 3/3 do modo saiu de trava cega |

O perigo nao e o erro, e a **ausencia** de erro: o arquivo continua valido, o Python compila, o Markdown
renderiza, e o comando documentado nao existe.

### `Testes\conferir-bytes-de-controle.py`

```
python Testes\conferir-bytes-de-controle.py
```

Varre `Menu`, `Testes`, `Documentacao` e os arquivos soltos da raiz (93 arquivos hoje) procurando byte
menor que 32 fora de tab/LF/CR. Sai **1** se achar, e imprime o arquivo e qual byte.

**Tem controle embutido, e e o que faz ela valer:** antes de varrer, ela **planta um 0x08** num arquivo
temporario e confere que a propria varredura o acusa. Se nao acusar, sai com codigo **2** e diz
"A VARREDURA ESTA CEGA". Sem isso, uma varredura quebrada imprimiria "nenhum byte de controle" para
sempre - exatamente o tipo de verde falso que ja nos custou um dia de trabalho.

Os `logo.txt` do JASP ficam de fora de proposito: usam 0x1b para dar cor no terminal, sao legitimos e
nao sao nossos.
