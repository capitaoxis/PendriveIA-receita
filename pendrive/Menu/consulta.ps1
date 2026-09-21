# Pendrive: grava (ou recebe) o audio de uma consulta, transcreve com o Whisper do pendrive e
# pede a IA local: resumo, evolucao SOAP e pendencias. Tudo offline, tudo dentro do pendrive.
# Uso: consulta.ps1                      (pergunta: gravar ou escolher arquivo)
#      consulta.ps1 -Arquivo aula.m4a    (pula a gravacao)
#      consulta.ps1 -Gravar -Minutos 20  (grava ate 20 min; 'q' para antes)
#      -Pessoas N  quantas pessoas falam (sem ele, pergunta; Enter = descobre sozinho)
#      -SemSeparar transcricao corrida, sem "Pessoa 1/2"
#      -Nomes "Artur,Paciente"  nome no lugar de Pessoa 1/2 (ordem em que cada um fala primeiro)
param([string]$Arquivo = "", [switch]$Gravar, [int]$Minutos = 0, [string]$Microfone = "", [string]$Modelo = "",
      [int]$Pessoas = -1, [switch]$SemSeparar, [string]$Nomes = "")
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raiz = Split-Path -Parent $PSScriptRoot
$ffmpeg = Join-Path $raiz "AnythingLLM\dados\storage\engines\ffmpeg\windows-x64\ffmpeg.exe"
$pasta = Join-Path $raiz "Documentos\Consultas"
New-Item -ItemType Directory -Force $pasta | Out-Null

Write-Host ""
Write-Host "  AVISO LGPD (dado de saude e dado sensivel, art. 11):" -ForegroundColor Yellow
Write-Host "  - Grave so com o consentimento do paciente (verbal registrado ou termo assinado)." -ForegroundColor Yellow
Write-Host "  - Audio, transcricao e resumo ficam SO no pendrive ($pasta)." -ForegroundColor Yellow
Write-Host "    Nada vai para a internet. O audio passa pelo TEMP do PC so durante a transcricao e e apagado." -ForegroundColor Yellow
Write-Host "  - Depois de passar a evolucao para o prontuario, APAGUE o audio e os textos daqui." -ForegroundColor Yellow
Write-Host "  - A IA erra: confira tudo antes de assinar. O texto e rascunho, nao prontuario." -ForegroundColor Yellow
Write-Host ""

function Microfones {
    # ffmpeg lista os dispositivos no stderr: "Nome" (audio)
    $saida = & cmd /c "`"$ffmpeg`" -hide_banner -list_devices true -f dshow -i dummy 2>&1"
    @($saida | ForEach-Object { if ($_ -match '"([^"]+)"\s*\(audio\)') { $Matches[1] } })
}

if (-not $Arquivo -and -not $Gravar) {
    Write-Host "  1 - Gravar agora pelo microfone"
    Write-Host "  2 - Escolher um arquivo de audio ja gravado (celular, gravador...)"
    $op = Read-Host "  Opcao"
    if ($op -eq "1") { $Gravar = $true }
    elseif ($op -eq "2") {
        Add-Type -AssemblyName System.Windows.Forms
        $dl = New-Object Windows.Forms.OpenFileDialog
        $dl.Filter = "Audio e video|*.mp3;*.m4a;*.wav;*.ogg;*.opus;*.webm;*.mp4;*.aac;*.flac|Todos|*.*"
        if ($dl.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { Write-Host "  Cancelado."; exit 0 }
        $Arquivo = $dl.FileName
    } else { exit 0 }
}

if ($Gravar) {
    # so entra na lista o microfone que abre de verdade (o "Virtual Microphone" da ASUS aparece e nao grava)
    $mics = @(Microfones | Where-Object {
        $pp = Start-Process $ffmpeg -ArgumentList @("-hide_banner", "-loglevel", "quiet", "-f", "dshow", "-i", "audio=`"$_`"", "-t", "0.3", "-f", "null", "-") -NoNewWindow -Wait -PassThru
        $pp.ExitCode -eq 0 })
    if (-not $mics) { Write-Host "  Nenhum microfone funcionando. Ligue um e tente de novo." -ForegroundColor Red; exit 1 }
    if (-not $Microfone) {
        Write-Host "  Microfones:"
        for ($i = 0; $i -lt $mics.Count; $i++) { Write-Host ("   {0} - {1}{2}" -f ($i + 1), $mics[$i], $(if ($i -eq 0) { "  (padrao)" } else { "" })) }
        $n = Read-Host "  Numero (Enter = padrao)"
        $Microfone = if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $mics.Count) { $mics[[int]$n - 1] } else { $mics[0] }
    }
    $Arquivo = Join-Path $pasta ("consulta-" + (Get-Date -Format "yyyy-MM-dd_HHmm") + ".wav")
    $a = @("-hide_banner", "-loglevel", "error", "-stats", "-f", "dshow", "-i", "audio=`"$Microfone`"", "-ac", "1", "-ar", "16000")
    if ($Minutos -gt 0) { $a += @("-t", ($Minutos * 60)) }
    $a += "`"$Arquivo`""
    Write-Host "  Gravando de: $Microfone" -ForegroundColor Green
    Write-Host "  Aperte  q  para terminar a gravacao." -ForegroundColor Green
    $pr = Start-Process $ffmpeg -ArgumentList $a -NoNewWindow -Wait -PassThru
    if (-not (Test-Path -LiteralPath $Arquivo) -or (Get-Item -LiteralPath $Arquivo).Length -lt 32000) {
        Write-Host "  A gravacao nao saiu (ou tem menos de 1 s)." -ForegroundColor Red; exit 1 }
}

$Arquivo = (Resolve-Path -LiteralPath $Arquivo).Path
$base = [IO.Path]::ChangeExtension($Arquivo, $null).TrimEnd('.')
if (-not $SemSeparar -and $Pessoas -lt 0) {
    $r = Read-Host "  Quantas pessoas falam na gravacao? (ex.: 2 = voce e o paciente; Enter = descobrir sozinho)"
    $Pessoas = if ($r -match '^\d+$') { [int]$r } else { 0 }
}
$antes = Get-Date
if ($SemSeparar) { & (Join-Path $PSScriptRoot "transcrever-audio.ps1") -Arquivo $Arquivo }
else { & (Join-Path $PSScriptRoot "transcrever-audio.ps1") -Arquivo $Arquivo -QuemFalou -Pessoas ([Math]::Max($Pessoas, 0)) -Nomes $Nomes }
# o transcritor nunca sobrescreve: pega o .txt escrito agora ao lado do audio
$txt = Get-ChildItem -LiteralPath (Split-Path $Arquivo) -Filter "$([IO.Path]::GetFileName($base))*.txt" |
    Where-Object { $_.LastWriteTime -ge $antes -and $_.Name -notlike "*.consulta.*" } | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $txt) { Write-Host "  A transcricao nao foi gerada." -ForegroundColor Red; exit 1 }
$transc = (Get-Content -LiteralPath $txt.FullName -Raw -Encoding UTF8).Trim()
if ($transc.Length -lt 20) { Write-Host "  A transcricao ficou vazia (audio mudo?)." -ForegroundColor Red; exit 1 }

$md = "$base.consulta.md"
$separada = $transc -match '(?m)^\[\d{2}:\d{2}(:\d{2})?\] [^:]+:'
$sobreFalas = if ($separada) {
    "Cada fala comeca com [minuto] e quem falou. Quando aparece 'Pessoa N', o numero e automatico pela voz: Pessoa 1 e so quem falou primeiro, NAO necessariamente o fisioterapeuta. Deduza pelo conteudo quem e o profissional, o paciente e um eventual acompanhante, e use isso para separar o relato (S) das orientacoes (P). A separacao por voz tambem erra: se uma fala nao combinar com quem a disse, desconfie."
} else { "A transcricao nao separa quem fala." }
$pedido = @"
Voce e assistente de um fisioterapeuta. Abaixo esta a TRANSCRICAO automatica de um atendimento (pode ter erros de reconhecimento de voz). $sobreFalas
Escreva em portugues do Brasil, em Markdown, exatamente estas secoes:

## Resumo
(3 a 6 linhas)

## Evolucao (SOAP)
**S (subjetivo):** queixas e relato do paciente/familiar.
**O (objetivo):** achados de exame, medidas, testes e escalas citados (com numeros).
**A (avaliacao):** interpretacao fisioterapeutica do que foi dito. Toda suposicao que NAO foi dita na consulta (ex.: possivel lesao, causa provavel) termina com "(hipotese da IA)".
**P (plano):** condutas, frequencia, orientacoes, encaminhamentos.

## Pendencias
Lista com '- [ ]' do que ficou para fazer, conferir ou pedir.

Regras: use SO o que esta na transcricao. Se algo nao foi dito, escreva "nao relatado". Nao invente numeros, diagnosticos nem medicamentos; hipotese so no A e sempre marcada "(hipotese da IA)". Marque com (?) o que parecer erro de transcricao.
"@
$ia = Join-Path $PSScriptRoot "ia.ps1"

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
$saidaIA = "$base.consulta.ia.tmp"
$argsIA = @("-f", $txt.FullName, "-o", $saidaIA)
if ($Modelo) { $argsIA += @("-m", $Modelo) }
Write-Host "`n  Gerando resumo, SOAP e pendencias com a IA local..." -ForegroundColor Gray
ChamarIA $argsIA $pedido $pasta
if (-not (Test-Path -LiteralPath $saidaIA)) { Write-Host "  A IA nao respondeu." -ForegroundColor Red; exit 1 }
$resp = Get-Content -LiteralPath $saidaIA -Raw -Encoding UTF8; Remove-Item -LiteralPath $saidaIA
$cab = @"
> **LGPD - dado sensivel de saude.** Rascunho gerado por IA local a partir de audio. Fica so neste pendrive.
> Confira com o paciente/prontuario antes de usar e APAGUE audio, transcricao e este arquivo depois de transcrever para o prontuario.

# Atendimento - $(Get-Date -Format "dd/MM/yyyy HH:mm")
Audio: $(Split-Path $Arquivo -Leaf)  |  Transcricao: $($txt.Name)

"@
$utf8 = New-Object Text.UTF8Encoding $true
[IO.File]::WriteAllText($md, $cab + $resp + "`n`n---`n## Transcricao completa`n`n" + $transc + "`n", $utf8)
[IO.File]::WriteAllText("$base.consulta.txt", (($cab + $resp) -replace '[#*>]', ''), $utf8)
Write-Host "`n  Salvo:" -ForegroundColor Green
Write-Host "   $md"
Write-Host "   $base.consulta.txt"
Write-Host "   $($txt.FullName)  (transcricao)"
Write-Host "  Lembrete: apague audio e textos depois de passar para o prontuario." -ForegroundColor Yellow
