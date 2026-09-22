# IA pelo terminal: ia "pergunta"  |  ia (conversa)  |  type arq.txt | ia "resuma"
# Arquivo: -f foto.jpg | -f doc.pdf/.txt/.docx   Wikipedia offline com fonte: -w
# Modelo: -m normal (padrao do PC; em PC forte vira maximo) | leve | grande | maximo | codigo | saude | visao
# Documentos (AnythingLLM aberto, menu 3): ia -d mestrado "pergunta"  |  ia -d (lista as areas)
# Pensar (raciocinio visivel em cinza, mais lento e mais certo em logica/conta): -p
# Modo de trabalho: -modo codar | relatorio | ideia | curto | mestrado | laudo  (instrucoes em Menu\modos\*.md)
# Atendimentos (dados de pacientes, so em PC de confianca): ia -a "pergunta"  |  ia -a -paciente "nome ou P012" "pergunta"
# Livros do pendrive (Calibre) com fonte: -l   |  Traduzir texto longo em partes: ia -t pt -f artigo.pdf (ou -t en)
# Salvar a resposta num arquivo: -o saida.md   |  -s nao mostra a resposta na tela (usado por scripts)
# Sobe o llama-server so em 127.0.0.1, responde e fecha. Nao instala nada.
[CmdletBinding(PositionalBinding = $false)]
param([string]$m = "normal", [string]$f = "", [switch]$w, [switch]$d, [switch]$p, [string]$o = "", [switch]$s, [switch]$l, [switch]$a, [string]$paciente = "", [ValidateSet("", "pt", "en")][string]$t = "",
      [ValidateSet("", "codar", "relatorio", "ideia", "curto", "mestrado", "laudo")][string]$modo = "",
      [Parameter(ValueFromRemainingArguments = $true)][string[]]$Pergunta)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raiz = Split-Path $PSScriptRoot -Parent
$app = Join-Path $raiz "Studio\app"
$pipe = if ([Console]::IsInputRedirected) { [Console]::In.ReadToEnd() } else { "" }
$texto = ($Pergunta -join " ").Trim()
if ($o) { $o = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($o) }
if ($paciente) { $a = $true }
if ($a) {
    Write-Host "Dados de pacientes: use so em PC de confianca." -ForegroundColor Yellow
    $pastaAt = if ($env:ATENDIMENTOS_PASTA) { $env:ATENDIMENTOS_PASTA } else { Join-Path ([IO.Path]::GetPathRoot($raiz)) "Pasta de atendimentos" }
    if (-not (Test-Path -LiteralPath (Join-Path $pastaAt ".ia\atendimentos.db"))) { Write-Host "Indice dos atendimentos nao existe. Rode: Menu\atendimentos-busca.ps1 -Indexar"; exit 1 }
}

# -d: pergunta aos Documentos pela API interna do AnythingLLM de mesa (so 127.0.0.1:3001; o app
# de mesa aceita o proprio agente de usuario do Electron, sem chave - nada vai na linha de comando)
if ($d) {
    # -d e switch: a area e a primeira palavra depois dele (ia -d mestrado "pergunta")
    $d = $false; $nomeArea = ""
    if ($Pergunta) { $nomeArea = $Pergunta[0]; $texto = (@($Pergunta | Select-Object -Skip 1) -join " ").Trim() }
    $B = "http://127.0.0.1:3001/api"
    $UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) AnythingLLM/1.16.1 Chrome/138.0.0.0 Electron/37.2.0 Safari/537.36"
    try { $areas = @((Invoke-RestMethod "$B/workspaces" -UserAgent $UA -TimeoutSec 5).workspaces) }
    catch { Write-Host "Os Documentos nao estao abertos. Abra os Documentos (menu 3) primeiro."; exit 1 }
    if (-not $nomeArea) {
        Write-Host "Areas dos Documentos (use: ia -d <area> `"pergunta`"):"
        foreach ($a in $areas) { Write-Host ("  {0,-32} {1}" -f $a.slug, $a.name) }
        exit 0
    }
    $area = $areas | Where-Object { $_.slug -eq $nomeArea -or $_.name -eq $nomeArea } | Select-Object -First 1
    if (-not $area) { $area = $areas | Where-Object { $_.slug -like "*$nomeArea*" -or $_.name -like "*$nomeArea*" } | Select-Object -First 1 }
    if (-not $area) { Write-Host "Area '$nomeArea' nao existe. Areas: $(($areas | ForEach-Object slug) -join ', ')"; exit 1 }
    $q = ((@($texto, $pipe) | Where-Object { $_ }) -join "`n`n").Trim()
    if (-not $q) { $q = Read-Host "pergunta" }
    if (-not $q) { exit 0 }
    # $modoChat e o modo da AREA no AnythingLLM (chat/query); $modo e o modo de trabalho (-modo codar...)
    $modoChat = if ($area.chatMode) { $area.chatMode } else { "chat" }
    Write-Host "[Documentos | $($area.name) | modo $modoChat]" -ForegroundColor DarkGray
    if ($modo) {
        # nos Documentos o prompt do sistema e da area (fica no servidor): vai junto com a pergunta
        $arqModo = Join-Path $PSScriptRoot "modos\$modo.md"
        if (Test-Path -LiteralPath $arqModo) {
            Write-Host "[modo $modo]" -ForegroundColor DarkGray
            $q = (Get-Content -LiteralPath $arqModo -Raw -Encoding UTF8).Trim() + "`n`n" + $q
        } else { Write-Host "[modo $modo nao encontrado; seguindo sem modo]" -ForegroundColor Yellow }
    }
    if ($modoChat -ne "query") { Write-Host "[esta area esta em modo conversa: pode completar com conhecimento geral; mude para 'Consulta' nas configuracoes da area para responder so com os documentos]" -ForegroundColor DarkGray }
    $corpo = [Text.Encoding]::UTF8.GetBytes((@{ message = $q; attachments = @() } | ConvertTo-Json))
    $req = [Net.HttpWebRequest]::Create("$B/workspace/$($area.slug)/stream-chat")
    $req.Method = "POST"; $req.ContentType = "application/json; charset=utf-8"; $req.UserAgent = $UA
    $req.Timeout = 1800000; $req.ReadWriteTimeout = 1800000
    $st = $req.GetRequestStream(); $st.Write($corpo, 0, $corpo.Length); $st.Close()
    $leitor = New-Object IO.StreamReader($req.GetResponse().GetResponseStream(), [Text.Encoding]::UTF8)
    $bruto = ""; $mostrado = 0; $fontes = @(); $erro = $null
    while (($linha = $leitor.ReadLine()) -ne $null) {
        if (-not $linha.StartsWith("data:")) { continue }
        $j = $linha.Substring(5).Trim() | ConvertFrom-Json
        if ($j.error) { $erro = $j.error }
        if ($j.sources) { $fontes += @($j.sources) }
        if ($j.textResponse) {
            $bruto += $j.textResponse
            $vis = $bruto -replace '(?s)<think>.*?</think>\s*', '' -replace '(?s)<think>.*$', '' -replace '<[^>]*$', ''
            if ($vis.Length -gt $mostrado) { [Console]::Write($vis.Substring($mostrado)); $mostrado = $vis.Length }
        }
    }
    $leitor.Close(); Write-Host ""
    if ($erro) { Write-Host "Erro dos Documentos: $erro"; exit 1 }
    $nomes = $fontes | ForEach-Object { if ($_.title) { $_.title } elseif ($_.url) { Split-Path $_.url -Leaf } } | Where-Object { $_ } | Select-Object -Unique
    if ($nomes) { Write-Host "Fontes:" -ForegroundColor DarkGray; $nomes | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkGray } }
    else { Write-Host "[nenhum trecho dos documentos foi usado]" -ForegroundColor DarkGray }
    exit 0
}

$imagem = $null; $anexo = ""
if ($f) {
    if (-not (Test-Path $f)) { Write-Host "Arquivo nao encontrado: $f"; exit 1 }
    $f = (Resolve-Path $f).Path; $ext = [IO.Path]::GetExtension($f).ToLower()
    if ($ext -in ".jpg", ".jpeg", ".png", ".webp", ".bmp") {
        $mime = if ($ext -eq ".png") { "image/png" } else { "image/jpeg" }
        $imagem = "data:$mime;base64," + [Convert]::ToBase64String([IO.File]::ReadAllBytes($f))
        if ($m -notin "visao", "saude") { $m = "visao" }
    } elseif ($ext -eq ".pdf") {
        $pdftotext = Join-Path $raiz "Ferramentas\Calibre Portable\Calibre\app\bin\pdftotext.exe"
        $tmp = [IO.Path]::GetTempFileName(); & $pdftotext -enc UTF-8 -layout $f $tmp 2>$null
        $anexo = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8); Remove-Item $tmp
        if (-not $anexo.Trim()) { Write-Host "PDF sem texto (escaneado): passe pelo OCR (tecla 8) antes." ; exit 1 }
    } elseif ($ext -eq ".docx") {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($f); $e = $z.GetEntry("word/document.xml")
        $x = (New-Object IO.StreamReader($e.Open())).ReadToEnd(); $z.Dispose()
        $anexo = [Net.WebUtility]::HtmlDecode(($x -replace '</w:p>', "`n" -replace '<[^>]+>', ''))
    } else { $anexo = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) }
    if ($anexo.Length -gt 40000 -and -not $t) { Write-Host "[arquivo grande: usando os primeiros 40 mil caracteres]" -ForegroundColor DarkGray; $anexo = $anexo.Substring(0, 40000) }
}
$diag = & (Join-Path $PSScriptRoot "menu.ps1") -Diagnostico | Out-String | ConvertFrom-Json
$arquivos = @{
    normal = $diag.ModeloChat
    leve   = "unsloth--Qwen3-1.7B-GGUF--Qwen3-1.7B-Q4_K_M.gguf"
    grande = "unsloth--Qwen3-14B-GGUF--Qwen3-14B-Q4_K_M.gguf"
    maximo = "unsloth--Qwen3-30B-A3B-GGUF--Qwen3-30B-A3B-Q4_K_M.gguf"   # placa 12 GB+ ou 32 GB de RAM
    codigo = "Qwen--Qwen2.5-Coder-7B-Instruct-GGUF--qwen2.5-coder-7b-instruct-q4_k_m.gguf"
    saude  = "unsloth--medgemma-1.5-4b-it-GGUF--medgemma-1.5-4b-it-Q4_K_M.gguf"
    visao  = "unsloth--Qwen3.5-4B-GGUF--Qwen3.5-4B-Q4_K_M.gguf"
}
# PC forte: "normal" sobe para o 30B-A3B (MoE: so 3B ativos, roda bem com placa 12 GB+ ou 32 GB de RAM)
$vram = ($diag.Placas | Measure-Object VramGB -Maximum).Maximum
if (-not $PSBoundParameters.ContainsKey('m') -and ($vram -ge 12 -or $diag.RamGB -ge 31) -and
    (Test-Path (Join-Path $app "llm-models\$($arquivos.maximo)"))) { $m = "maximo" }
if (-not $arquivos.ContainsKey($m)) { Write-Host "Modelos: $($arquivos.Keys -join ', ')"; exit 1 }
$modelo = Get-ChildItem (Join-Path $app "llm-models") -Recurse -Filter $arquivos[$m] -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $modelo) { Write-Host "Modelo '$m' ($($arquivos[$m])) nao esta neste pendrive."; exit 1 }

$backend = if ($diag.Backend) { $diag.Backend } else { "cpu" }
$server = Join-Path $app "llm-backend\win\$backend\llama-server.exe"
if (-not (Test-Path $server)) { $server = Join-Path $app "llm-backend\win\cpu\llama-server.exe"; $backend = "cpu" }

# porta livre e chave aleatoria, passada por variavel de ambiente (nunca na linha de comando)
$tl = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $tl.Start(); $porta = $tl.LocalEndpoint.Port; $tl.Stop()
$chave = [Guid]::NewGuid().ToString("N")
# este llama-server le a chave em LLAMA_API_KEY (LLAMA_ARG_API_KEY e ignorada: medido 19/09, aceitava sem chave)
$env:LLAMA_API_KEY = $chave
# Qwen3/3.5 pensam por padrao; o 3.5-4B ignora --reasoning-budget 0 e responde VAZIO. So -p liga.
$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = if ($p) { '{"enable_thinking":true}' } else { '{"enable_thinking":false}' }
# log dentro do pendrive (nada no %TEMP% do PC); um por execucao, apagado no fim se deu certo
$pastaLog = if ($a) { Join-Path $pastaAt ".ia\tmp" } else { Join-Path $raiz "Testes\logs" }   # -a: log junto dos dados, nunca no repositorio
New-Item -ItemType Directory -Force $pastaLog | Out-Null
$log = Join-Path $pastaLog "ia-$PID.log"

function Subir([string]$camadas) {
    $ctx = if ($anexo -or $w -or $p -or $l -or $a -or $t) { "16384" } else { "8192" }
    $a = @("-m", "`"$($modelo.FullName)`"", "--host", "127.0.0.1", "--port", $porta, "-c", $ctx, "--jinja")
    if ($imagem) { $mm = Get-ChildItem $modelo.DirectoryName -Filter "$((($modelo.Name -split '--')[0..1]) -join '--')--mmproj*.gguf" | Select-Object -First 1
        $a += @("--mmproj", "`"$($mm.FullName)`"") }
    if ($backend -ne "cpu") { $a += @("-ngl", $camadas) }
    if ($modelo.FullName -notlike "C:*") { $a += "--no-mmap" }
    if ($m -eq "saude") { $a += "--special" }   # MedGemma pensa entre <unused94>...<unused95>: sem isso o pensamento vem misturado na resposta
    $sp = Start-Process $server -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    # pendrive USB lento + --no-mmap: um 4B leva ~2-4 min para carregar; espera ate 10 min
    for ($i = 0; $i -lt 1200; $i++) {
        Start-Sleep -Milliseconds 500
        if ($i -gt 0 -and $i % 10 -eq 0) { Write-Host "." -NoNewline -ForegroundColor DarkGray }
        if ($sp.HasExited) { return $null }
        try { if ((Invoke-RestMethod "http://127.0.0.1:$porta/health" -TimeoutSec 2).status -eq "ok") { if ($i -ge 10) { Write-Host "" }; return $sp } } catch {}
    }
    Stop-Process $sp -Force -ErrorAction SilentlyContinue; return $null
}

Write-Host "[$m | $backend | carregando...]" -ForegroundColor DarkGray
$t0 = Get-Date
$proc = Subir "99"
if (-not $proc -and $backend -ne "cpu") { Write-Host "[nao coube na placa, dividindo com o processador]" -ForegroundColor DarkGray; $proc = Subir "20" }
if (-not $proc) { Write-Host "Falhou ao subir o modelo. Log: $log"; exit 1 }
Write-Host "[pronto em $([math]::Round(((Get-Date)-$t0).TotalSeconds,1)) s]" -ForegroundColor DarkGray

# Modo de trabalho: instrucao de sistema pronta em Menu\modos\<modo>.md (codar, relatorio, ideia, curto).
# Modelo local e fraco: instrucao curta e concreta muda a resposta; texto longo ele ignora.
$sistema = "Responda em portugues do Brasil, de forma clara e direta."
if ($modo) {
    $arqModo = Join-Path $PSScriptRoot "modos\$modo.md"
    if (Test-Path -LiteralPath $arqModo) {
        $sistema = (Get-Content -LiteralPath $arqModo -Raw -Encoding UTF8).Trim()
        Write-Host "[modo $modo]" -ForegroundColor DarkGray
    } else {
        Write-Host "[modo $modo nao encontrado em $arqModo; seguindo sem modo]" -ForegroundColor Yellow
    }
}
$msgs = [Collections.ArrayList]@(@{ role = "system"; content = $sistema })
# Pergunta rapida fora da conversa (nao entra no historico), sem fluxo; "" se falhar
function Curta([string]$pedido) {
    try {
        $corpo = [Text.Encoding]::UTF8.GetBytes((@{ messages = @(@{ role = "user"; content = $pedido }); temperature = 0; max_tokens = 40 } | ConvertTo-Json -Depth 5))
        $r = Invoke-RestMethod "http://127.0.0.1:$porta/v1/chat/completions" -Method Post -Body $corpo -ContentType "application/json; charset=utf-8" -Headers @{ Authorization = "Bearer $chave" } -TimeoutSec 120
        return (($r.choices[0].message.content) -replace '(?s)<think>.*?</think>', '').Trim()
    } catch { return "" }
}
function Perguntar([string]$q) {
    if ($w) {
        Write-Host "[buscando na Wikipedia offline...]" -ForegroundColor DarkGray
        $py = Join-Path $raiz "Python\python312\python.exe"
        $ctxw = (& $py (Join-Path $PSScriptRoot "ia-wiki.py") (Join-Path $raiz "Kiwix\zim") $q | Out-String)
        if ($ctxw.Trim()) { $q = "Use SOMENTE os artigos abaixo da Wikipedia. Cite entre colchetes o titulo do artigo de onde tirou cada informacao. Se nao estiver neles, diga que nao encontrou.`n`n$ctxw`n`nPergunta: $q" }
        else { Write-Host "[nada encontrado na Wikipedia offline]" -ForegroundColor DarkGray }
    }
    if ($l) {
        Write-Host "[buscando nos livros do pendrive...]" -ForegroundColor DarkGray
        $env:PYTHONIOENCODING = 'utf-8'
        $pyL = Join-Path $raiz "Python\python312\python.exe"; $scL = Join-Path $PSScriptRoot "livros-busca.py"
        # Duas buscas somadas: a frase inteira e 2-4 palavras-chave que o proprio modelo tira dela.
        # So a frase falhava dos dois jeitos: longa vinha vazia (a busca exige quase todas as palavras),
        # ou trazia trecho sem relacao e o livro certo nunca era buscado ("filho autista largar a fralda"
        # nao achava o livro de desfralde).
        $blocos = [Collections.Generic.List[string]]::new()
        $chaves = (Curta "Extraia de 2 a 4 palavras-chave em portugues para buscar esta pergunta num indice de livros. Use o termo tecnico quando houver (ex.: largar a fralda = desfralde). Responda so as palavras, separadas por espaco, sem pontuacao.`n`nPergunta: $q") -replace '[^\p{L}\p{Nd} -]', ' '
        if ($chaves.Trim()) { Write-Host "[buscando tambem por: $($chaves.Trim())]" -ForegroundColor DarkGray }
        # quais LIVROS falam do assunto: ajuda a saber se vale ler, e mostra a fonte antes da resposta
        $listaLivros = (& $pyL $scL "--livros" $(if ($chaves.Trim()) { $chaves } else { $q }) | Out-String).Trim()
        if ($listaLivros) {
            Write-Host "[livros sobre o assunto]" -ForegroundColor DarkGray
            ($listaLivros -split "`r?`n" | Select-Object -First 5) | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
        foreach ($busca in @($chaves, $q)) {
            if (-not $busca.Trim()) { continue }
            foreach ($b in ((& $pyL $scL $busca | Out-String) -split "\r?\n\r?\n")) {
                if ($b.Trim() -and -not $blocos.Contains($b.Trim()) -and $blocos.Count -lt 8) { $blocos.Add($b.Trim()) }
            }
        }
        $ctxl = $blocos -join "`n`n"
        if ($ctxl.Trim()) { $q = "Use SOMENTE os trechos de livros abaixo. Cite entre colchetes [Titulo - Autor] o livro de onde tirou cada informacao. Se a resposta nao estiver nos trechos, diga que nao encontrou nos livros.`n`n$ctxl`n`nPergunta: $q" }
        else {
            # sem trecho nao pergunta ao modelo: ele responderia de memoria e pareceria vir dos livros
            $aviso = "Nao encontrei isso nos livros do pendrive. Tente com outras palavras, ou sem -l para a IA responder do que sabe (sem fonte)."
            Write-Host $aviso -ForegroundColor Yellow
            if ($o) { [IO.File]::WriteAllText($o, $aviso, (New-Object Text.UTF8Encoding $false)) }
            return
        }
    }
    if ($a) {
        Write-Host "[buscando nos registros de atendimento...]" -ForegroundColor DarkGray
        $env:PYTHONIOENCODING = 'utf-8'
        $pyA = Join-Path $raiz "Python\python312\python.exe"; $scA = Join-Path $PSScriptRoot "atendimentos-busca.py"
        $argA = @(); if ($paciente) { $argA = @("--paciente", $paciente) }
        $ctxa = (& $pyA $scA @argA $q | Out-String)
        $conta = if (-not $paciente) { (& $pyA $scA --contar $q | Out-String).Trim() } else { "" }
        if ($conta) { $conta = "Dado do indice (use este numero se a pergunta for 'quantos'): " + ($conta -replace '^CONTAGEM NO INDICE:\s*', '') }
        if ($ctxa.Trim()) { $q = "Use SOMENTE os registros de atendimento abaixo. Cite entre colchetes [codigo - data] o registro de onde tirou cada informacao. Nao invente. Se a resposta nao estiver nos registros, diga que nao encontrou. Responda em frases completas.`n`n$conta`n`nTrechos dos registros:`n$ctxa`n`nPergunta: $q" }
        else { Write-Host "[nada encontrado nos atendimentos]" -ForegroundColor DarkGray }
    }
    if ($anexo) { $q = "Conteudo do arquivo $(Split-Path $f -Leaf):`n`"`"`"`n$anexo`n`"`"`"`n`n$q"; $script:anexo = "" }
    if ($imagem) { [void]$msgs.Add(@{ role = "user"; content = @(@{ type = "text"; text = $q }, @{ type = "image_url"; image_url = @{ url = $imagem } }) }); $script:imagem = $null }
    else { [void]$msgs.Add(@{ role = "user"; content = $q }) }
    # resposta em fluxo (SSE): o texto aparece enquanto o modelo gera
    $corpo = [Text.Encoding]::UTF8.GetBytes((@{ messages = $msgs; temperature = 0.6; stream = $true; timings_per_token = $false; max_tokens = 6000 } | ConvertTo-Json -Depth 8))
    $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$porta/v1/chat/completions")
    $req.Method = "POST"; $req.ContentType = "application/json; charset=utf-8"; $req.Timeout = 1800000; $req.ReadWriteTimeout = 1800000
    $req.Headers.Add("Authorization", "Bearer $chave")
    $st = $req.GetRequestStream(); $st.Write($corpo, 0, $corpo.Length); $st.Close()
    $leitor = New-Object IO.StreamReader($req.GetResponse().GetResponseStream(), [Text.Encoding]::UTF8)
    $bruto = ""; $mostrado = 0; $tps = $null; $pensBruto = ""; $pensMostrado = 0
    while (($linha = $leitor.ReadLine()) -ne $null) {
        if (-not $linha.StartsWith("data: ") -or $linha -eq "data: [DONE]") { continue }
        $j = $linha.Substring(6) | ConvertFrom-Json
        if ($j.timings) { $tps = $j.timings.predicted_per_second }
        $pedaco = $j.choices[0].delta.content
        $rc = $j.choices[0].delta.reasoning_content
        if ($rc) { $pensBruto += $rc }
        if (-not $pedaco -and -not $rc) { continue }
        if ($pedaco) { $bruto += $pedaco }
        if ($p -and -not $s) {
            # pensamento em cinza: vem em reasoning_content ou dentro de <think> no texto
            $pv = $pensBruto
            if ($bruto -match '(?s)<think>(.*?)(</think>|$)') { $pv += $Matches[1] }
            $pv = $pv -replace '<[^>]*$', ''
            if ($pv.Length -gt $pensMostrado) {
                if ($pensMostrado -eq 0) { Write-Host "[pensando]" -ForegroundColor DarkGray }
                Write-Host $pv.Substring($pensMostrado) -NoNewline -ForegroundColor DarkGray; $pensMostrado = $pv.Length }
        }
        # esconde o pensamento (<think> do Qwen, <unused94>..<unused95> do MedGemma) e segura tag pela metade
        $vis = $bruto -replace '(?s)<think>.*?</think>\s*', '' -replace '(?s)<think>.*$', ''
        if ($m -eq "saude") { $vis = if ($vis -match '<unused95>') { $vis -replace '(?s)^.*<unused95>\s*', '' } else { "" } }
        $vis = $vis -replace '<(end_of_turn|eos)>', '' -replace '<[^>]*$', ''
        if ($vis.Length -gt $mostrado) { if (-not $s) { if ($pensMostrado -gt 0 -and $mostrado -eq 0) { Write-Host "`n" } ; [Console]::Write($vis.Substring($mostrado)) }; $mostrado = $vis.Length }
    }
    $leitor.Close()
    $resp = ($bruto -replace '(?s)<think>.*?</think>\s*', '' -replace '(?s)^.*<unused95>\s*', '' -replace '<(end_of_turn|eos)>', '').Trim()
    if ($mostrado -eq 0 -and -not $s) { [Console]::Write($resp) }
    if ($o) { [IO.File]::WriteAllText($o, $resp, (New-Object Text.UTF8Encoding $false)) }
    [void]$msgs.Add(@{ role = "assistant"; content = $resp })
    Write-Host ""
    if ($tps -and -not $s) { Write-Host ("[{0:0.0} tokens/s]" -f $tps) -ForegroundColor DarkGray }
}

try {
    if ($t) {
        # traducao em partes de ~6000 caracteres sem cortar paragrafo; cada parte e uma conversa nova
        $orig = if ($anexo) { $anexo } else { ((@($texto, $pipe) | Where-Object { $_ }) -join "`n`n") }
        $anexo = ""
        if (-not $orig.Trim()) { Write-Host "Nada para traduzir. Use: ia -t pt -f artigo.pdf  ou  ia -t en `"texto`""; exit 1 }
        $partes = New-Object Collections.ArrayList; $atual = ""
        foreach ($par in ($orig -split '(\r?\n\s*){2,}' | Where-Object { $_ -and $_.Trim() })) {
            $pedacos = if ($par.Length -gt 6000) { $par -split '(?<=[.!?])\s+' } else { @($par) }
            foreach ($pd in $pedacos) {
                if ($atual.Length + $pd.Length -gt 6000 -and $atual) { [void]$partes.Add($atual); $atual = "" }
                $atual += $pd.Trim() + "`n`n"
            }
        }
        if ($atual.Trim()) { [void]$partes.Add($atual) }
        $lingua = if ($t -eq "en") { "o ingles" } else { "o portugues do Brasil" }
        $destino = if ($o) { $o } elseif ($f) { [IO.Path]::ChangeExtension($f, $null).TrimEnd('.') + ".traduzido.txt" } else { "" }
        $o = ""; $traducao = New-Object Text.StringBuilder; $tt = Get-Date
        for ($k = 0; $k -lt $partes.Count; $k++) {
            Write-Host ("`n[parte {0}/{1}]" -f ($k + 1), $partes.Count) -ForegroundColor Cyan
            $msgs.Clear(); [void]$msgs.Add(@{ role = "system"; content = "Voce e um tradutor profissional. Devolva so a traducao, sem comentarios." })
            Perguntar "Traduza o texto abaixo para $lingua. Mantenha os paragrafos, numeros, siglas e termos tecnicos corretos. Nao resuma e nao comente.`n`n<<<`n$($partes[$k])`n>>>"
            [void]$traducao.AppendLine($msgs[$msgs.Count - 1].content.Trim()).AppendLine()
            if ($destino) { [IO.File]::WriteAllText($destino, $traducao.ToString(), (New-Object Text.UTF8Encoding $true)) }
        }
        Write-Host ("[traduzido em {0:N0} s, {1} partes]" -f ((Get-Date) - $tt).TotalSeconds, $partes.Count) -ForegroundColor DarkGray
        if ($destino) { Write-Host "Salvo: $destino" -ForegroundColor Green }
        return
    }
    if (-not $texto -and ($f -or $pipe)) { $texto = if ($imagem) { "Descreva e leia esta imagem." } else { "Resuma." } }
    if ($pipe -or $texto) {
        Perguntar ((@($texto, $pipe) | Where-Object { $_ }) -join "`n`n")
    } else {
        Write-Host "Conversa (digite 'sair' para terminar)." -ForegroundColor DarkGray
        while ($true) {
            $q = Read-Host "`nvoce"
            if ($q -in @("sair", "exit", "")) { break }
            Perguntar $q
        }
    }
} finally {
    Stop-Process $proc -Force -ErrorAction SilentlyContinue
    Remove-Item Env:LLAMA_API_KEY -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    Remove-Item -LiteralPath $log, "$log.out" -ErrorAction SilentlyContinue
}
