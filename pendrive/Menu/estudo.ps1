# Pendrive: estudo com a IA local, sem internet.
# Flashcards para o Anki:  estudo.ps1 -Modo flashcards -Arquivo apostila.pdf [-N 15]
# Simulado no terminal:    estudo.ps1 -Modo simulado  -Arquivo edital.pdf  [-N 10]
# Aceita .pdf, .txt, .md, .docx. Sem -Arquivo abre a janela para escolher.
# Saidas ao lado do arquivo: <nome>.anki.txt  |  <nome>.simulado-<data>.md (nota e erros para revisar)
param([ValidateSet("", "flashcards", "simulado")][string]$Modo = "", [string]$Arquivo = "", [int]$N = 10,
      [string]$Modelo = "", [string]$Respostas = "", [int]$MaxCaracteres = 24000)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raiz = Split-Path -Parent $PSScriptRoot
$ia = Join-Path $PSScriptRoot "ia.ps1"
$utf8 = New-Object Text.UTF8Encoding $false

if (-not $Modo) {
    Write-Host "  1 - Flashcards para o Anki"
    Write-Host "  2 - Simulado (questoes de multipla escolha, com nota)"
    $op = Read-Host "  Opcao"
    $Modo = switch ($op) { "1" { "flashcards" } "2" { "simulado" } default { exit 0 } }
    $q = Read-Host "  Quantas? (Enter = 10)"; if ($q -match '^\d+$') { $N = [int]$q }
}
if (-not $Arquivo) {
    Add-Type -AssemblyName System.Windows.Forms
    $dl = New-Object Windows.Forms.OpenFileDialog
    $dl.InitialDirectory = Join-Path $raiz "Documentos"
    $dl.Filter = "Textos|*.pdf;*.txt;*.md;*.docx|Todos|*.*"
    if ($dl.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { Write-Host "  Cancelado."; exit 0 }
    $Arquivo = $dl.FileName
}
$Arquivo = (Resolve-Path -LiteralPath $Arquivo).Path
$base = [IO.Path]::ChangeExtension($Arquivo, $null).TrimEnd('.')

# texto do arquivo (o modelo leve tem memoria curta: corta em $MaxCaracteres)
$ext = [IO.Path]::GetExtension($Arquivo).ToLower()
if ($ext -eq ".pdf") {
    $pdftotext = Join-Path $raiz "Ferramentas\Calibre Portable\Calibre\app\bin\pdftotext.exe"
    $tmp = [IO.Path]::GetTempFileName(); & $pdftotext -enc UTF-8 $Arquivo $tmp 2>$null
    $conteudo = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8); Remove-Item $tmp
} elseif ($ext -eq ".docx") {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Arquivo); $e = $z.GetEntry("word/document.xml")
    $x = (New-Object IO.StreamReader($e.Open())).ReadToEnd(); $z.Dispose()
    $conteudo = [Net.WebUtility]::HtmlDecode(($x -replace '</w:p>', "`n" -replace '<[^>]+>', ''))
} else { $conteudo = [IO.File]::ReadAllText($Arquivo, [Text.Encoding]::UTF8) }
$conteudo = ($conteudo -replace '[ \t]+', ' ' -replace '(\r?\n\s*){3,}', "`n`n").Trim()
if ($conteudo.Length -lt 200) { Write-Host "  Quase nao ha texto nesse arquivo (PDF escaneado? passe pelo OCR, tecla 8)." -ForegroundColor Red; exit 1 }
if ($conteudo.Length -gt $MaxCaracteres) {
    Write-Host ("  [arquivo grande: usando os primeiros {0:N0} de {1:N0} caracteres]" -f $MaxCaracteres, $conteudo.Length) -ForegroundColor DarkGray
    $conteudo = $conteudo.Substring(0, $MaxCaracteres) }
$fonte = Join-Path $env:TEMP ("estudo-" + [Guid]::NewGuid().ToString("N") + ".txt")
[IO.File]::WriteAllText($fonte, $conteudo, $utf8)
$saidaIA = "$fonte.resp"

# Chama o ia.ps1 em outro processo com o pedido pela entrada padrao (sem problema de aspas na
# linha de comando e sem travar quando este script roda com a entrada redirecionada)
function ChamarIA([string[]]$argsIA, [string]$pedido, [string]$pastaTmp) {
    $pf = Join-Path $pastaTmp ("pedido-" + [Guid]::NewGuid().ToString("N") + ".txt")
    [IO.File]::WriteAllText($pf, $pedido, (New-Object Text.UTF8Encoding $false))
    $lista = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$ia`"") +
        @($argsIA | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) + "`"Siga as instrucoes abaixo.`""
    try { Start-Process powershell -ArgumentList $lista -NoNewWindow -Wait -RedirectStandardInput $pf }
    finally { Remove-Item -LiteralPath $pf -ErrorAction SilentlyContinue }
}

function PerguntarIA([string]$pedido) {
    $a = @("-f", $fonte, "-o", $saidaIA, "-s")
    if ($Modelo) { $a += @("-m", $Modelo) }
    ChamarIA $a $pedido $env:TEMP
    if (-not (Test-Path $saidaIA)) { return "" }
    $r = [IO.File]::ReadAllText($saidaIA, [Text.Encoding]::UTF8); Remove-Item $saidaIA; return $r
}

try {
if ($Modo -eq "flashcards") {
    Write-Host "  Gerando $N flashcards (a IA trabalha em silencio; leva alguns minutos)..." -ForegroundColor Gray
    $r = PerguntarIA @"
Crie $N flashcards de estudo em portugues sobre os pontos mais importantes do texto (datas, prazos, definicoes, numeros, criterios).
Cada cartao em duas linhas, com uma linha em branco entre cartoes, sem markdown:
P: pergunta
R: resposta curta (ate 25 palavras)
Nao repita cartoes.
"@
    # monta "frente;verso" aqui (o modelo pequeno se perde no formato de ponto e virgula)
    $cartoes = @(); $frente = ""
    foreach ($l in ($r -replace '\*\*', '' -split "`r?`n")) {
        if ($l -match '^\s*(P|Pergunta|Frente)\s*\d*\s*[:.)-]\s*(.+)') { $frente = $Matches[2].Trim() }
        elseif ($l -match '^\s*(R|Resposta|Verso)\s*[:.)-]\s*(.+)' -and $frente) {
            $c = ($frente -replace ';', ',') + ";" + ($Matches[2].Trim() -replace ';', ',')
            if ($cartoes -notcontains $c) { $cartoes += $c }; $frente = "" }
    }
    if (-not $cartoes) {
        [IO.File]::WriteAllText("$base.anki-bruto.txt", $r, $utf8)
        Write-Host "  A IA nao devolveu cartoes no formato (resposta crua em $base.anki-bruto.txt). Tente de novo ou com -Modelo grande." -ForegroundColor Red; exit 1 }
    $saida = "$base.anki.txt"
    [IO.File]::WriteAllText($saida, "#separator:semicolon`n#html:false`n" + ($cartoes -join "`n") + "`n", $utf8)
    Write-Host ("  {0} cartoes salvos em {1}" -f $cartoes.Count, $saida) -ForegroundColor Green
    Write-Host "  No Anki: Arquivo > Importar > escolha esse .txt (ja vem com separador ';')."
    $cartoes | Select-Object -First 3 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    exit 0
}

# ---- simulado ----
Write-Host "  Gerando $N questoes (a IA trabalha em silencio para nao mostrar o gabarito)..." -ForegroundColor Gray
$r = PerguntarIA @"
Crie $N questoes de multipla escolha em portugues sobre o texto, cada uma com 4 alternativas e UMA so correta, baseada no que esta escrito.
Varie a letra correta. Use EXATAMENTE este formato, sem markdown, com uma linha em branco entre questoes:
Q: enunciado
A) alternativa
B) alternativa
C) alternativa
D) alternativa
R: letra correta
E: explicacao em uma frase, citando o trecho do texto
"@
$questoes = @()
foreach ($bloco in ($r -replace '\*\*', '' -split '(?m)^\s*(?=Q\s*\d*\s*[:.)])')) {
    $q = [ordered]@{ Q = ""; A = ""; B = ""; C = ""; D = ""; R = ""; E = "" }
    foreach ($l in ($bloco -split "`r?`n")) {
        if ($l -match '^\s*Q\s*\d*\s*[:.)]\s*(.+)') { $q.Q = $Matches[1].Trim() }
        elseif ($l -match '^\s*([ABCD])\s*[).:-]\s*(.+)') { $q[$Matches[1]] = $Matches[2].Trim() }
        elseif ($l -match '^\s*R\s*[:.)]\s*\(?([ABCD])\b') { $q.R = $Matches[1] }
        elseif ($l -match '^\s*E\s*[:.)]\s*(.+)') { $q.E = $Matches[1].Trim() }
    }
    if ($q.Q -and $q.A -and $q.B -and $q.C -and $q.D -and $q.R) {
        # o modelo pequeno quase sempre poe a certa na A: embaralha as alternativas aqui
        $certa = $q[$q.R]; $alts = @($q.A, $q.B, $q.C, $q.D) | Get-Random -Count 4
        $k = 0; foreach ($L in "A", "B", "C", "D") { $q[$L] = $alts[$k]; if ($alts[$k] -eq $certa) { $q.R = $L }; $k++ }
        $q.E = $q.E -replace '(?i)^a (resposta|alternativa) correta [eé] [ABCD]\b[,.]?\s*', ''
        $questoes += , $q }
}
if (-not $questoes) { Write-Host "  A IA nao devolveu questoes no formato. Tente de novo ou com -Modelo grande." -ForegroundColor Red; exit 1 }
Write-Host ("  {0} questoes prontas. Responda com A, B, C ou D (Enter pula).`n" -f $questoes.Count) -ForegroundColor Green
$acertos = 0; $erros = @(); $i = 0
foreach ($q in $questoes) {
    Write-Host ("Questao {0}/{1}: {2}" -f ($i + 1), $questoes.Count, $q.Q) -ForegroundColor Cyan
    foreach ($L in "A", "B", "C", "D") { Write-Host "  $L) $($q[$L])" }
    $resp = if ($Respostas) { if ($i -lt $Respostas.Length) { [string]$Respostas[$i] } else { "" } } else { Read-Host "  Sua resposta" }
    $resp = $resp.Trim().ToUpper()
    if ($Respostas) { Write-Host "  Sua resposta: $resp" }
    if ($resp -eq $q.R) { $acertos++; Write-Host "  Certo!" -ForegroundColor Green }
    else {
        Write-Host "  Errado. Correta: $($q.R)) $($q[$q.R])" -ForegroundColor Red
        $erros += , @{ q = $q; sua = $resp }
    }
    if ($q.E) { Write-Host "  $($q.E)" -ForegroundColor DarkGray }
    Write-Host ""; $i++
}
$nota = [math]::Round(10 * $acertos / $questoes.Count, 1)
Write-Host ("  Nota: {0} ({1} de {2})" -f $nota, $acertos, $questoes.Count) -ForegroundColor Yellow
$saida = "$base.simulado-" + (Get-Date -Format "yyyy-MM-dd_HHmm") + ".md"
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine("# Simulado - $(Split-Path $Arquivo -Leaf) - $(Get-Date -Format 'dd/MM/yyyy HH:mm')")
[void]$sb.AppendLine("Nota: **$nota** ($acertos de $($questoes.Count)). Questoes geradas por IA local: confira o gabarito no texto original.`n")
[void]$sb.AppendLine("## Erros para revisar`n")
if (-not $erros) { [void]$sb.AppendLine("Nenhum. :)") }
foreach ($e in $erros) {
    $q = $e.q
    [void]$sb.AppendLine("**$($q.Q)**`n")
    foreach ($L in "A", "B", "C", "D") { [void]$sb.AppendLine("- $L) $($q[$L])") }
    [void]$sb.AppendLine("`nSua resposta: $(if ($e.sua) { $e.sua } else { '(em branco)' })  |  Correta: **$($q.R)**`n")
    if ($q.E) { [void]$sb.AppendLine("> $($q.E)`n") }
}
[IO.File]::WriteAllText($saida, $sb.ToString(), (New-Object Text.UTF8Encoding $true))
Write-Host "  Erros salvos para revisao: $saida" -ForegroundColor Green
} finally { Remove-Item -LiteralPath $fonte, $saidaIA -ErrorAction SilentlyContinue }
