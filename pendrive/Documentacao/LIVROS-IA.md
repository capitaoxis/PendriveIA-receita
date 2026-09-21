# Perguntar aos livros (offline)

A IA responde citando **livro e trecho** da biblioteca do Calibre do pendrive.

## Como funciona
- `Menu\livros-busca.py` extrai o texto dos EPUB (Python puro) e PDF (`pdftotext.exe` do Calibre),
  corta em trechos de ~800 caracteres e grava num índice SQLite FTS5 que ignora acento.
- Índice: `Livros\indice\livros.db` (log: `Livros\indice\indexar.log`).
- A biblioteca do Calibre só é LIDA (o `metadata.db` é copiado para o TEMP para pegar título/autor).
- Direito autoral: livros da "Grande Biblioteca" são para uso pessoal. O índice fica só no pendrive.

## Uso
```powershell
# criar/atualizar o índice (segundo plano; incremental: pula livro com mesmo caminho+tamanho+data)
& E:\IA\Menu\livros-busca.ps1 -Indexar
# índice menor, só os primeiros N trechos de cada livro
& E:\IA\Menu\livros-busca.ps1 -Indexar -MaxTrechos 200
# buscar: 6 trechos, no máximo 2 por livro, formato [Titulo — Autor] trecho
& E:\IA\Menu\livros-busca.ps1 "equilíbrio idosos"
```
PDF escaneado (só imagem) não tem texto: aparece com erro "sem texto" na tabela `livros`.

## Integração com o ia.ps1 (futuro `ia -l "pergunta"`)
Mesmo contrato do `ia-wiki.py`: stdout UTF-8, blocos separados por linha em branco, vazio se não achar.
```powershell
$env:PYTHONIOENCODING = 'utf-8'
$trechos = & "$raiz\Python\python312\python.exe" "$raiz\Menu\livros-busca.py" $pergunta | Out-String
```
(`$raiz` = raiz do pendrive, ex. `E:\IA`.) Se `$trechos` vier vazio, avisar "nada nos livros"
em vez de deixar a IA inventar; senão injetar no prompt pedindo que cite `[Titulo — Autor]`.

## Nos Documentos (AnythingLLM) — 19/09
- `Menu\livros-mcp.py`: servidor MCP `livros-offline` com a ferramenta `buscar_livros(palavras_chave)`.
  O `preparar.ps1` registra ao lado do `wikipedia-offline`. Usar com `@agent` no chat.
- Busca: todas as palavras (exatas, depois com variação: quedas → qued*); sem resultado, tira
  palavras até 2/3 delas. **Nunca "qualquer palavra"**: isso trazia Eça e dicionário até para
  "xyzzy foguete marciano" e a IA citava como fonte. Sem trecho → a IA diz que não encontrou.
- Nome do livro na citação: título ruim do PDF (".cdr", "Microsoft Word -", "Unknown") vira o nome do
  arquivo original (`Livros\importados.tsv`, pelo id do Calibre); autor vazio vira a pasta do Calibre.
- Teste 19/09: "quedas em idosos" → citou [O cuidado ao idoso na atenção primária… — Aline Salla], trecho
  conferido no índice; controle "Falcon 9" → "não encontrou". `Testes\agente-anythingllm.mjs`.

## No terminal: `ia -l "pergunta"` — 19/09
- Busca duas vezes e junta (até 8 trechos): a frase inteira + 2 a 4 palavras-chave que o próprio modelo tira
  dela (pede o termo técnico: "largar a fralda" → desfralde). Só a frase falhava: longa vinha vazia, ou trazia
  trecho sem relação e o livro certo nunca era buscado.
- Sem nenhum trecho, **não pergunta ao modelo**: mostra "Não encontrei isso nos livros do pendrive"
  (antes ele respondia de memória, parecendo vir dos livros).
- Teste: quedas em idosos e "filho autista largar a fralda" citaram o livro certo; "Falcon 9" → não encontrou.

## Medido em 19/09 com a biblioteca inteira (5.116 livros, 1,72 milhão de trechos, índice 2,4 GB)
`Testes\avaliar-busca-livros.py`: 20 perguntas com o livro esperado + 2 que não devem achar nada.
**19/20 acham o livro certo nos 6 trechos, 17/20 já no 1º trecho, 0/2 inventam fonte.**
Três regras que vieram de erro medido, não de palpite:
- **Texto corrido na frente de tabela/índice** (poucos números e sinais, com palavras de ligação):
  "adestramento de cães" trazia uma tabela de palavras-chave de um livro de marketing; passou a trazer
  *Como criar o cão perfeito*. Ganho: 1º trecho certo de 8/10 para 9/10.
- **Máximo 2 trechos por TÍTULO, não por registro:** a biblioteca tem 530 cópias repetidas (um guia
  aparece 27 vezes) e um livro só ocupava os 6 trechos com o mesmo texto.
- **Só pergunta de 5+ palavras pode perder palavra na busca.** Com 3 palavras, 2 bastavam e
  "manutenção motor foguete Falcon" achava romance ("falc*" casa com "falcão"). Exigir a palavra mais
  rara NÃO resolveu; exigir todas resolveu.
Pergunta longa em frase ainda volta vazia ou fraca: por isso o `ia -l` e a ferramenta da IA buscam por
palavras-chave. 186 livros não têm texto (PDF escaneado, só imagem) e nunca aparecem na busca.

## OCR dos livros escaneados — 19/09
`Menu\livros-ocr.py`: os livros que são só imagem (162 PDF + 24 EPUB de imagens, 4,5 GB) não apareciam
na busca. O OCR roda com o **pdftoppm do Calibre + o Tesseract em português que já vinha no NAPS2** do
pendrive — sem baixar nada, sem internet.
- `python Menu\livros-ocr.py --paginas 25 --processos 8` (150 dpi; `OCR_DPI` muda, `NAPS2_DIR` aponta
  outra pasta do NAPS2). Marca no índice `erro='ocr: N paginas'`, então rodar de novo não repete trabalho.
- Ritmo medido: **~3 s por página** com 8 processos (200 dpi e 3 processos davam 7 s). 175 livros com 25
  páginas ≈ 3,5 h. Só as primeiras páginas: serve para o livro ser achado, não para lê-lo todo.
- Qualidade em 150 dpi: boa para busca, com erro pequeno ("11ª edição" → "11%").
- As imagens temporárias ficam em `Livros\indice\ocr-tmp` (nunca no %TEMP% do PC) e são apagadas.
- Cuidado: o OCR escreve no índice. Não copiar o índice para o pendrive enquanto ele roda.

## Duplicados: medidos, e NÃO apagados — 19/09
360 títulos repetidos, 530 cópias extras. Comparando o sha256 dos arquivos, **só 1 é cópia idêntica**:
as outras 255 têm o mesmo título e conteúdo diferente (edições, PLR com nome igual). Apagar perderia
material. O barulho na busca já é resolvido pelo limite de 2 trechos por título.

## Nomes de quem falou e opção no menu — 19/09
- `transcrever-audio.ps1 -QuemFalou -Nomes "Artur,Sr. Jose"` (e `consulta.ps1 -Nomes ...`) troca
  "Pessoa 1/2" pelos nomes, na ordem em que cada um fala primeiro. Sem `-Nomes`, fica Pessoa N.
- Menu: **tecla Q, "Perguntar aos livros"** — chama `ia.ps1 -l`, a IA responde citando o livro.
- `quem-falou.py` com arquivo que não existe agora diz isso, em vez de mostrar erro técnico.

## Resultado do OCR e nomes limpos — 19/09
- OCR nos 175 escaneados em **33 min** (8 processos, 150 dpi, 25 páginas): **167 passaram a ter texto**.
  A biblioteca foi de 4.930 para **5.108 livros com texto de 5.116**; sobraram 8 sem texto. Índice: 1,73
  milhão de trechos, 2,3 GB, integridade ok. bell hooks, Stuart Hall e Müller, que eram só imagem, agora
  aparecem na busca.
- **`--livros "assunto"`** (e a ferramenta `listar_livros` da IA): diz QUAIS livros falam do assunto, com
  o nº de trechos. Aqui a busca afrouxa quando nenhum livro tem todas as palavras, e **avisa na 1ª linha**,
  porque 1 trecho não quer dizer que o livro trata do assunto.
- Nome do livro na citação: passou a limpar `.epub` (faltava), título de digitalização ("Impressão de foto
  de página inteira") e escape de PDF (`\343`); autor com nome de arquivo ou com mais de 45 letras é
  descartado. "\(Impress\343o...\)" virou *HALL, Stuart. A Identidade Cultural na Pós-Modernidade*.

## 21/09: título do livro pesa na ordem — 20/20
Livro cujo **título** fala do assunto passou a vir na frente (entre os trechos que são texto corrido).
Placar: **20/20 achando o livro certo, 18/20 já no 1º trecho** (era 19/20 e 17/20), com os controles
ainda em 0/2 inventando fonte. O caso que faltava era "exercícios de fortalecimento muscular", que
trazia um gabarito de prova antes do livro de exercício.
