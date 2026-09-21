# Pendrive: transcreve uma gravacao (entrevista, aula, consulta) para texto, sem internet.
# Uso: transcrever-audio.ps1 [-Arquivo "C:\...\entrevista.m4a"] [-Idioma pt] [-ComHorarios]
# Sem -Arquivo abre a janela para escolher. Aceita o que o ffmpeg abrir (mp3, m4a, wav, mp4, webm...).
# Usa o Whisper large-v3-turbo do Studio: na placa NVIDIA quando houver, senao no processador.
# O texto fica ao lado do arquivo original (mesmo nome, .txt).
# -QuemFalou separa as vozes ("[00:14] Pessoa 2: ...") com Menu\quem-falou.py; -Pessoas N quando se sabe quantas.
# -Nomes "Ana,Paciente" troca Pessoa 1/2 pelos nomes, na ordem em que cada um fala primeiro.
param([string]$Arquivo = "", [string]$Idioma = "pt", [switch]$ComHorarios, [switch]$QuemFalou, [int]$Pessoas = 0,
      [string]$Nomes = "")
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$ffmpeg = Join-Path $root "AnythingLLM\dados\storage\engines\ffmpeg\windows-x64\ffmpeg.exe"
$modelo = Join-Path $root "Studio\app\speech-models\ggml-large-v3-turbo-q5_0.bin"
$comPlaca = (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\nvcuda.dll")) -and
    (Test-Path -LiteralPath (Join-Path $root "AnythingLLM\whisper-cuda\whisper-cli.exe")) -and
    (Test-Path -LiteralPath (Join-Path $root "Studio\app\llm-backend\win\cuda\cublas64_12.dll"))
$cli = if ($comPlaca) { Join-Path $root "AnythingLLM\whisper-cuda\whisper-cli.exe" } else { Join-Path $root "AnythingLLM\whisper\whisper-cli.exe" }
foreach ($p in @($ffmpeg, $modelo, $cli)) { if (-not (Test-Path -LiteralPath $p)) { throw "Nao encontrei $p" } }

if (-not $Arquivo) {
    Add-Type -AssemblyName System.Windows.Forms
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Title = "Escolha a gravacao para transcrever"
    $d.Filter = "Audio e video|*.mp3;*.m4a;*.wav;*.ogg;*.opus;*.webm;*.mp4;*.mkv;*.mov;*.aac;*.flac|Todos|*.*"
    if ($d.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { Write-Host "  Cancelado."; exit 0 }
    $Arquivo = $d.FileName
}
$Arquivo = (Resolve-Path -LiteralPath $Arquivo).Path
$base = [IO.Path]::ChangeExtension($Arquivo, $null).TrimEnd('.')
# Nunca por em cima de um .txt que ja existe: "entrevista.txt" pode ser a anotacao do usuario,
# e o whisper gravaria por cima sem avisar.
$saida = $base
if (Test-Path -LiteralPath "$base.txt") {
    $saida = "$base.transcricao"
    $n = 2
    while (Test-Path -LiteralPath "$saida.txt") { $saida = "$base.transcricao-$n"; $n++ }
}
$temp = Join-Path ([IO.Path]::GetTempPath()) ("transcrever-" + [guid]::NewGuid().ToString("N") + ".wav")

Write-Host ("  Preparando o audio ({0})..." -f (Split-Path $Arquivo -Leaf)) -ForegroundColor Gray
# O audio convertido (a consulta, a entrevista) fica no %TEMP% do PC ate o fim: o try/finally
# garante que ele saia de la mesmo se algo falhar no meio ou o usuario interromper.
try {
& $ffmpeg -hide_banner -loglevel error -y -i $Arquivo -ar 16000 -ac 1 -acodec pcm_s16le $temp
if (-not (Test-Path -LiteralPath $temp)) { throw "O ffmpeg nao conseguiu ler esse arquivo." }
$segundos = ((Get-Item -LiteralPath $temp).Length - 44) / 32000
Write-Host ("  {0:N0} min de audio. Transcrevendo {1}..." -f ($segundos / 60), $(if ($comPlaca) { "na placa de video" } else { "no processador (mais lento)" }))

$argumentos = @("-m", "`"$modelo`"", "-f", "`"$temp`"", "-l", $Idioma, "-otxt", "-of", "`"$saida`"", "-t", "8")
# Sem placa, busca simples: 16% mais rapido com o mesmo acerto (medido em 16/09).
if (-not $comPlaca) { $argumentos += @("-bs", "1") }
if (-not $ComHorarios -and -not $QuemFalou) { $argumentos += "-nt" }  # -nt estraga o horario por palavra
if ($ComHorarios -or $QuemFalou) { $argumentos += "-osrt" }
# Para separar vozes: legenda palavra por palavra (-ml 1 -sow) com horario alinhado (-dtw). Blocos de
# 80 letras atravessavam a troca de pessoa ("desde quando comecou a | Pessoa 2: dor"); o -dtw pos as
# trocas a 0,0-0,5 s do gabarito (teste de 19/09). O preset tem que ser o do modelo em $modelo.
if ($QuemFalou) { $argumentos += @("-ml", "1", "-sow", "-dtw", "large.v3.turbo") }
$env:PATH = (Join-Path $root "Studio\app\llm-backend\win\cuda") + ";" + $env:PATH
$inicio = Get-Date
$p = Start-Process -FilePath $cli -ArgumentList $argumentos -WorkingDirectory (Split-Path -Parent $cli) -NoNewWindow -Wait -PassThru `
    -RedirectStandardOutput "$temp.out" -RedirectStandardError "$temp.err"
$texto = "$saida.txt"
# Saiu 0 e o arquivo existe nao basta: o arquivo tem que ter sido escrito AGORA.
$saiuAgora = { (Test-Path -LiteralPath $texto) -and ((Get-Item -LiteralPath $texto).LastWriteTime -ge $inicio) }
if ($p.ExitCode -ne 0 -or -not (& $saiuAgora)) {
    if ($comPlaca) {
        Write-Host "  A placa de video falhou; tentando no processador..." -ForegroundColor Yellow
        $p = Start-Process -FilePath (Join-Path $root "AnythingLLM\whisper\whisper-cli.exe") -ArgumentList $argumentos -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput "$temp.out" -RedirectStandardError "$temp.err"
    }
    if ($p.ExitCode -ne 0 -or -not (& $saiuAgora)) {
        Write-Host "  Nao consegui transcrever. Detalhe: $((Get-Content "$temp.err" -Tail 2) -join ' ')" -ForegroundColor Red
        exit 1
    }
}
if ($QuemFalou) {
    # Se a separacao falhar, fica a transcricao comum (ja gravada) e um aviso.
    Write-Host "  Separando quem falou..." -ForegroundColor Gray
    $python = Join-Path $root "Python\python312\python.exe"
    $extra = if ($Pessoas -gt 0) { @("--pessoas", $Pessoas) } else { @() }
    if ($Nomes) { $extra += @("--nomes", $Nomes) }
    $env:PYTHONIOENCODING = "utf-8"
    # sem isto o PowerShell le a saida do Python como cp850 e grava "par├ígrafo"
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    $falas = & $python (Join-Path $PSScriptRoot "quem-falou.py") $temp "$saida.srt" @extra 2> "$temp.err"
    if ($LASTEXITCODE -eq 0 -and $falas) {
        [IO.File]::WriteAllText($texto, (($falas -join "`n").Trim() + "`n"), (New-Object Text.UTF8Encoding($false)))
        $nPessoas = @($falas | Select-String -Pattern '\] ([^:]+):' -AllMatches | ForEach-Object { $_.Matches.Groups[1].Value } | Sort-Object -Unique).Count
        Write-Host "  $nPessoas pessoa(s) diferente(s) na gravacao." -ForegroundColor Gray
    } else {
        Write-Host "  Nao consegui separar quem falou; ficou a transcricao comum. $((Get-Content "$temp.err" -Tail 1) -join ' ')" -ForegroundColor Yellow
    }
    if (-not $ComHorarios) { Remove-Item -LiteralPath "$saida.srt" -Force -ErrorAction SilentlyContinue }
}
$palavras = ((Get-Content -LiteralPath $texto -Raw) -split '\s+').Count
Write-Host ("  Pronto em {0:N0} s: {1} ({2} palavras)" -f ((Get-Date) - $inicio).TotalSeconds, $texto, $palavras) -ForegroundColor Green
Write-Host "  Dica: para a IA resumir, abra os Documentos (menu 3) e envie esse .txt para uma area."
} finally {
    Remove-Item -LiteralPath $temp, "$temp.out", "$temp.err" -Force -ErrorAction SilentlyContinue
}
