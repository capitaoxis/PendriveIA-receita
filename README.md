# Pendrive de IA offline — a receita

Monta um pendrive que roda **inteligência artificial, Wikipédia, livros e ferramentas sem internet e
sem instalar nada** no computador. Plugue em qualquer Windows 10/11, dê dois cliques no `MENU.bat`, e
tudo roda de lá: conversa com a IA, resumo de consulta, transcrição com separação de quem falou, busca
nos seus livros com citação da fonte, Wikipédia offline, estatística, flashcards, escritório.

Este repositório é a **receita**, não uma cópia do pendrive: os scripts são nossos, e o instalador baixa
cada programa, modelo e acervo **da fonte oficial, conferindo o SHA-256**. Nada de livro, nada de dado
pessoal, nada de binário de terceiro redistribuído por nós.

## Por que receita, e não um arquivo pronto

| Parte | Por quê |
|---|---|
| Programas e motores | São de outros projetos, com licenças próprias. Baixar da origem mantém a autoria e a atualização. |
| Modelos de IA (~25 GB) e acervos (~76 GB) | Grandes demais para redistribuir, e já publicados com hash pela origem. |
| **Livros** | Direito autoral. Cada pessoa usa os próprios. O instalador só prepara a biblioteca e os scripts. |
| **Dados pessoais** | Consulta de paciente é dado sensível (LGPD art. 11). Nunca sai do pendrive de quem usa. |

## O que você precisa

- Windows 10 ou 11, 64 bits.
- Um pendrive de **128 GB ou mais** (formatado em NTFS; o instalador avisa se faltar espaço).
  Com 64 GB dá para montar sem a Wikipédia completa.
- Internet só na montagem. Depois, nunca mais.
- Placa de vídeo NVIDIA é opcional: sem ela o menu escolhe um modelo menor automaticamente.

## Como montar

```powershell
git clone https://github.com/<voce>/PendriveIA-receita
cd PendriveIA-receita
powershell -ExecutionPolicy Bypass -File .\montar-pendrive.ps1 -Destino E:
```

O instalador confere espaço e formato do disco (tem de ser NTFS: modelo passa de 4 GB), copia os nossos
scripts, e então trata cada item do `fontes.tsv` de um de dois jeitos:

**Sozinho, com hash conferido** — modelos de IA, vozes, modelos de separar voz, acervos `.zim` e
pacotes Python. O Hugging Face e o Kiwix publicam o SHA-256 de cada arquivo, então o instalador baixa,
compara e retoma download interrompido. Dois modelos que não têm hash publicado vêm com o hash
**fixado** neste repositório, medido numa cópia que funcionou: se a origem mudar o arquivo, o download
é recusado em vez de aceito no escuro.

**Com você no meio** — programas e motores (Calibre, NAPS2, LibreOffice, llama.cpp, ffmpeg, Anki...).
O endereço do arquivo muda a cada versão, e chutar URL dá download errado ou desatualizado. O
instalador lista o que falta com a **página oficial** de cada um; você baixa e joga em `baixados\`; ele
confere, extrai no lugar certo e anota o SHA-256 em `hashes-obtidos.tsv`. Rodar de novo continua de
onde parou.

No fim ele mostra os comandos dos **testes** que provam que ficou certo: segurança (nada escuta fora de
127.0.0.1, site nenhum alcança os servidores), voz, busca nos livros e o placar dos modos da IA.

Opções úteis:

```powershell
-Somente modelo,acervo     # só uma parte (grupos do fontes.tsv)
-SemAcervos                # pula a Wikipédia (economiza ~76 GB)
# (nao existe flag de continuar: rodar de novo ja pula o que esta conferido)
-Conferir                  # não baixa nada: só confere o que já está no pendrive
```

## O que vem pronto, e que é o miolo do projeto

- **Menu único** (`MENU.bat`) que detecta o hardware e escolhe o modelo por PC.
- **`ia` no terminal** com modos de trabalho medidos: `codar`, `relatorio`, `ideia`, `curto`,
  `mestrado`, `laudo`. Ver `Documentacao/MODOS-IA.md` — com placar de antes e depois.
- **Busca nos seus livros** com citação `[Título — Autor]`, OCR dos escaneados (Tesseract em
  português) e regra de não inventar fonte. Ver `LIVROS-IA.md`.
- **Transcrição com separação de quem falou** (`-QuemFalou`, `-Nomes "Ana,Paciente"`).
- **Wikipédia e documentação offline** pelo Kiwix, com a IA citando o artigo.
- **Testes de segurança** que provam que nada escuta fora de 127.0.0.1 e que site nenhum alcança os
  servidores locais.

## Cuidado com o que é seu

O pendrive guarda coisa sensível se você usar para trabalho clínico. O projeto já trata disso:
áudio e transcrição ficam no pendrive, o texto avisa da LGPD, e há um cofre para senhas. Mas a
responsabilidade é de quem usa: **não empreste o pendrive sem antes tirar os seus dados e os livros
com direito autoral.**

## Licença

Os **scripts deste repositório**: MIT (ver `LICENSE`). Cada programa, modelo e acervo que o instalador
baixa tem a licença da sua própria origem, anotada no `fontes.tsv`. Nós não redistribuímos nenhum
deles.
