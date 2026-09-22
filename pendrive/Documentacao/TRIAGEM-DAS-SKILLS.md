# As 729 skills instaladas: o que dá para aproveitar na IA do pendrive (22/09/2026)

Pergunta que originou este documento: "não temos várias skills que podemos aproveitar? o /skills tem mais de 1000 boas".
Tem. Este documento é a triagem — e a conclusão é **quase nenhuma serve copiada**, por dois motivos
medidos, não por opinião.

## O levantamento

`%USERPROFILE%\.claude\skills` tem **491 pastas** e **729 arquivos `SKILL.md`** (há bundles com
várias skills dentro, e algumas repetidas em dois caminhos). Tamanho do corpo de cada uma, em palavras:

| faixa | quantas |
|---|---|
| até 100 palavras | **4** |
| 100 a 400 | poucas dezenas |
| acima de 400 | a grande maioria |

## Motivo 1: instrução longa PIORA o modelo local (medido)

Não é suposição. Três medições desta semana, no `Testes\avaliar-modos.py`:

- o modo `laudo` com **231 palavras** acertou **0/3**; encurtado para **155 palavras**, subiu para 2/3;
- o `revisar`, no formato rígido copiado de skill, fez o Qwen3-8B responder `QUEBRA: nada / SOBRA: nada`
  — **o molde substituiu o raciocínio**. Sem modo nenhum, o mesmo modelo achava a divisão por zero;
- nenhum modo entra sem ganhar de "sem modo" nos **dois** modelos (4B e 8B).

O Claude lê 1.800 palavras e entende. O modelo do pendrive afoga. Então aproveitar uma skill é
**extrair a regra conferível** dela, não copiá-la.

## Motivo 2: metade delas manda usar o que o pendrive não tem

Filtrando as descrições por dependência externa (API, HTTP, navegador, GitHub, Slack, Docker, banco,
nuvem, busca na web, servidor MCP pago), sai uma fatia enorme. Skill que manda consultar uma API
não tem tradução offline: a IA do pendrive não tem para onde ligar.

## O que sobrou, e o que virou modo

As únicas curtas o bastante para servirem de base (e são curtas porque são do mesmo padrão enxuto):

| skill | palavras | virou |
|---|---|---|
| `safe-refactor` | 68 | entrou no `revisar` (não misturar refatoração com conserto) |
| `investigate-first` | 69 | **modo `investigar`** |
| `verify-and-stop` | 72 | entrou no `revisar` (não acrescentar polimento depois de passar) |
| `surgical-patch` | 93 | **modo `investigar`** + `revisar` (mexer na camada mais estreita) |
| `karpathy-coder` | 836 | duas ideias sobreviveram ao corte, no `revisar` |
| `adversarial-reviewer` | 1805 | uma ideia: crítica só com cenário que quebra |

De 729 arquivos, **3 modos novos**: `revisar`, `commit`, `investigar`. Não é pouco — é o que passou
na medição. O custo de cada um foi ~3 casos de teste e 3 a 4 rodadas de correção.

## O que NÃO vale a pena, e por quê

- **Copiar skill inteira para o pendrive.** Mede pior. Já está medido acima.
- **Modo para assunto que quem usa o pendrive não usa.** Havia 96 candidatas de "negócio/estratégia" (M&A,
  expansão internacional, analytics de produto). Viram modo que ninguém abre.
- **Skill que é fluxo de trabalho com subagentes** (`do`, `make-plan`, `planning-with-files`): pressupõem
  agente que dispara outros agentes. O pendrive tem `agente.py`, de um só passo.

## Como aproveitar mais, quando quiser

O caminho não é volume, é assunto. Diga o assunto (ex.: "quero um modo para escrever e-mail para
médico parceiro") e o trabalho é: achar a skill do assunto, tirar dela as 4 ou 5 regras conferíveis,
escrever em menos de 180 palavras, criar 3 casos no medidor e rodar nos dois modelos. Se não ganhar de
"sem modo", o modo não entra.
