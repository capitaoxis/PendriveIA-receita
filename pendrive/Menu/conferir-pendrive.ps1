# Pendrive: confere se algum arquivo do pendrive estragou (pendrive corrompe em silencio).
# Uso: conferir-pendrive.ps1 -Gerar     (grava a lista de referencia; rode depois de mudar coisas)
#      conferir-pendrive.ps1            (confere contra a lista e mostra o que mudou)
#      conferir-pendrive.ps1 -Rapido    (so tamanho e data; nao le o conteudo dos arquivos)
# A lista fica em Ferramentas\conferencia\manifesto.tsv (fora do git, fica no proprio pendrive).
# Pastas que mudam sozinhas (dados, configuracoes, historicos, logs) ficam de fora.
param([switch]$Gerar, [switch]$Rapido, [string]$Pasta = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
# Cuidado: nao chamar esta variavel de $pasta - o PowerShell nao diferencia maiusculas e ela
# sobrescreveria o parametro -Pasta (foi assim que a conferencia devolveu "0 arquivos").
$pastaConferencia = Join-Path $root "Ferramentas\conferencia"
$manifesto = Join-Path $pastaConferencia "manifesto.tsv"

# Tudo que muda no uso normal: nao entra na conferencia.
$fora = @(
    "\\\.git\\", "\\__pycache__\\", "\\Documentos\\", "\\AnythingLLM\\dados\\", "\\Ferramentas\\conferencia\\",
    "\\Ferramentas\\[^\\]*-dados\\", "\\Ferramentas\\[^\\]*-perfil\\", "\\Ferramentas\\R-pacotes\\",
    "\\Ferramentas\\Calibre Portable\\Calibre (Library|Settings)\\", "\\Ferramentas\\NAPS2\\Data\\",
    "\\Ferramentas\\SumatraPDF\\SumatraPDF-settings\.txt$", "\\Ferramentas\\KeePassXC\\config\\",
    "\\Ferramentas\\PDFArranger\\config\.ini$", "\\Ferramentas\\EpiInfo7\\.*\\(Projects|Configuration)\\",
    "\\Studio\\app\\(chat-history|config|outputs|transcriptions|tts-outputs|tts-cache|cache|openvino-models)\\",
    "\\Studio\\app\\frontend\\node_modules\\\.vite\\", "\.log$", "\.tmp$", "\\Livros\\importados\.tsv$",
    "\\Kiwix\\zim\\.*\.part$"
)
$regexFora = ($fora -join "|")

if ($Gerar -and $Rapido) {
    # A lista gravada sem hash marca todos os arquivos com "-", e a partir dai NENHUMA conferencia
    # completa consegue mais apontar corrupcao: tudo passa como "igual".
    Write-Host "  -Gerar com -Rapido nao vale: a lista de referencia precisa do conteudo." -ForegroundColor Red
    Write-Host "  Rode 'conferir-pendrive.ps1 -Gerar' (demora, mas e a lista que detecta corrupcao)." -ForegroundColor Yellow
    exit 2
}

$de = if ($Pasta) { Join-Path $root $Pasta } else { $root }   # -Pasta confere so um pedaco
if (-not (Test-Path -LiteralPath $de)) {
    Write-Host "  Pasta nao encontrada: $de" -ForegroundColor Red
    exit 2
}
# Na raiz do pendrive $root e "X:\" (ja termina em barra); somar 1 cortaria a primeira letra de
# todo caminho ("X:\Studio\a" viraria "tudio\a") e a conferencia acusaria tudo como NOVO.
$corte = if ($root.EndsWith("\")) { $root.Length } else { $root.Length + 1 }
Write-Host ("  Lendo o pendrive{0}..." -f $(if ($Rapido) { " (modo rapido)" } else { ", arquivo por arquivo" })) -ForegroundColor Gray
$conta = 0
$bytes = [int64]0

function Linhas {
    # Em fluxo, sem guardar os 175 mil arquivos na memoria (numa maquina apertada o Windows
    # derrubava o script no meio e a lista saia pela metade).
    # SHA-256 direto pelo .NET, reaproveitando o objeto: o Get-FileHash gasta ~9 ms por arquivo,
    # o que com 175 mil arquivos vira meia hora so de chamada.
    $sha = [Security.Cryptography.SHA256]::Create()
    Get-ChildItem -LiteralPath $de -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch $regexFora } |
        ForEach-Object {
            $script:conta++
            $script:bytes += $_.Length
            if ($script:conta % 2000 -eq 0) { Write-Progress -Activity "Conferindo o pendrive" -Status ("{0:N0} arquivos, {1:N1} GB" -f $script:conta, ($script:bytes / 1GB)) }
            $hash = "-"
            if (-not $Rapido) {
                try {
                    $fs = [IO.File]::Open($_.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                    try { $hash = [BitConverter]::ToString($sha.ComputeHash($fs)).Replace("-", "").ToLower() } finally { $fs.Dispose() }
                } catch { $hash = "ilegivel" }
            }
            "{0}`t{1}`t{2}`t{3}" -f $_.FullName.Substring($corte), $_.Length, $_.LastWriteTimeUtc.Ticks, $hash
        }
    $sha.Dispose()
    Write-Progress -Activity "Conferindo o pendrive" -Completed
}

if ($Gerar) {
    New-Item -ItemType Directory -Force -Path $pastaConferencia | Out-Null
    $inicio = Get-Date
    # Grava em arquivo separado e so troca no fim: lista interrompida no meio (falta de memoria,
    # pendrive removido) nao pode virar a referencia, senao a conferencia seguinte acusa milhares
    # de arquivos "NOVOS" que sempre estiveram la.
    $novoManifesto = "$manifesto.novo"
    Linhas | Set-Content -LiteralPath $novoManifesto -Encoding UTF8
    if ($conta -eq 0) {
        Remove-Item -LiteralPath $novoManifesto -Force -ErrorAction SilentlyContinue
        Write-Host "  Nenhum arquivo foi lido em $de - a lista antiga foi mantida." -ForegroundColor Red
        exit 2
    }
    Move-Item -LiteralPath $novoManifesto -Destination $manifesto -Force
    Write-Host ("  Lista gravada em {0}: {1:N0} arquivos, {2:N1} GB ({3:N0} min)." -f `
        $manifesto, $conta, ($bytes / 1GB), ((Get-Date) - $inicio).TotalMinutes) -ForegroundColor Green
    exit 0
}

if (-not (Test-Path -LiteralPath $manifesto)) {
    Write-Host "  Ainda nao existe lista de referencia. Rode: conferir-pendrive.ps1 -Gerar" -ForegroundColor Yellow
    exit 2
}
# Guarda cada linha da referencia como um texto so ("tamanho|data|hash"): com 175 mil arquivos,
# um objeto por linha gastaria memoria demais.
$velho = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
$semHash = 0
foreach ($l in [IO.File]::ReadLines($manifesto)) {
    $c = $l -split "`t"
    if ($c.Count -lt 4) { continue }
    if ($Pasta -and -not $c[0].StartsWith($Pasta, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ($c[3] -eq "-") { $semHash++ }
    $velho[$c[0]] = "$($c[1])|$($c[2])|$($c[3])"
}
if ($velho.Count -eq 0) {
    Write-Host ("  A lista de referencia nao tem nenhum arquivo{0}." -f $(if ($Pasta) { " em '$Pasta'" })) -ForegroundColor Red
    Write-Host "  Confira o nome da pasta, ou gere a lista de novo: conferir-pendrive.ps1 -Gerar" -ForegroundColor Yellow
    exit 2
}
if ($semHash -and -not $Rapido) {
    Write-Host ("  Aviso: {0:N0} arquivos da lista estao sem conteudo gravado - neles a corrupcao nao e detectavel." -f $semHash) -ForegroundColor Yellow
}
$inicio = Get-Date
$estragados = New-Object Collections.ArrayList
$novos = New-Object Collections.ArrayList
$mudados = New-Object Collections.ArrayList
Linhas | ForEach-Object {
    $c = $_ -split "`t"
    $v = $null
    if (-not $velho.TryGetValue($c[0], [ref]$v)) { [void]$novos.Add($c[0]); return }
    $velho.Remove($c[0]) | Out-Null
    $ref = $v -split "\|"
    $mesmoTamanho = $ref[0] -eq $c[1]
    $mesmaData = $ref[1] -eq $c[2]
    $mesmoHash = $Rapido -or $ref[2] -eq "-" -or $ref[2] -eq $c[3]
    if ($mesmoTamanho -and $mesmaData -and -not $mesmoHash) { [void]$estragados.Add($c[0]) }   # mesmo arquivo, conteudo diferente
    elseif (-not ($mesmoTamanho -and $mesmaData -and $mesmoHash)) { [void]$mudados.Add($c[0]) }
}
$sumiram = @($velho.Keys)
Write-Host ""
if ($conta -eq 0) {
    Write-Host "  Nenhum arquivo foi lido em $de - nada foi conferido (isso nao e um pendrive bom)." -ForegroundColor Red
    exit 2
}
# Junçao NTFS nao e percorrida pelo Get-ChildItem -Recurse (e ele nao avisa): o conteudo delas
# entra na conferencia pelo caminho real (binary_pkgs). O que da para provar aqui e que elas
# existem e apontam para lugar existente - JASP sem elas abre sem os modulos.
$quebradas = @()
$juncoes = @(Get-ChildItem -LiteralPath $de -Recurse -Directory -Force -Attributes ReparsePoint -ErrorAction SilentlyContinue)
if ($juncoes.Count) {
    # Test-Path na propria juncao responde True mesmo quebrada (o atalho existe): quem diz a verdade
    # e o alvo. Num pendrive restaurado com a letra trocada, o alvo antigo (C:\...) nao existe mais.
    $quebradas = @($juncoes | Where-Object {
        $alvo = @($_.Target)[0]
        -not $alvo -or -not (Test-Path -LiteralPath $alvo)
    })
    if ($quebradas.Count) {
        Write-Host "  JUNCOES QUEBRADAS ($($quebradas.Count) de $($juncoes.Count)): apontam para lugar que nao existe." -ForegroundColor Red
        $quebradas | Select-Object -First 5 | ForEach-Object { Write-Host "    $($_.FullName.Substring($corte))" -ForegroundColor Red }
        Write-Host "  Recrie com: Ferramentas\JASP\JunctionTool.exe -c" -ForegroundColor Yellow
    } else {
        Write-Host ("  Juncoes: {0:N0}, todas apontando certo (o conteudo delas e conferido pelo caminho real)." -f $juncoes.Count) -ForegroundColor Gray
    }
}
if ($estragados.Count) {
    Write-Host "  ESTRAGADOS ($($estragados.Count)): mesmo tamanho e data, conteudo diferente. Isso e corrupcao." -ForegroundColor Red
    $estragados | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    Write-Host "  Recupere esses arquivos da copia no Google Drive (COMO-RESTAURAR.txt)." -ForegroundColor Red
}
if ($sumiram.Count) { Write-Host "  SUMIRAM ($($sumiram.Count)):" -ForegroundColor Yellow; $sumiram | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow } }
if ($mudados.Count) { Write-Host "  MUDARAM ($($mudados.Count)) - normal se voce mexeu neles:" -ForegroundColor Gray; $mudados | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" } }
if ($novos.Count) { Write-Host "  NOVOS ($($novos.Count)):" -ForegroundColor Gray; $novos | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" } }
if (-not ($estragados.Count -or $sumiram.Count -or $mudados.Count -or $novos.Count)) {
    Write-Host ("  Tudo certo: {0:N0} arquivos conferidos em {1:N0} min." -f $conta, ((Get-Date) - $inicio).TotalMinutes) -ForegroundColor Green
}
exit $(if ($estragados.Count -or $sumiram.Count -or $quebradas.Count) { 1 } else { 0 })
