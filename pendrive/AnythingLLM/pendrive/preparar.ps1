# Pendrive: prepara o AnythingLLM para rodar do pendrive.
# 1) sobe o llama-server do Studio em 127.0.0.1:10090, com chave de acesso;
# 2) cria dados\storage\.env na primeira vez (provedor, embedder, telemetria).
# O MENU.bat passa a recomendacao do hardware por variaveis de ambiente:
#   PENDRIVE_MODELO_DOCS (arquivo .gguf), PENDRIVE_CONTEXTO, PENDRIVE_BACKEND (cuda|vulkan|cpu).
$ErrorActionPreference = "Stop"

$allm      = Split-Path -Parent $PSScriptRoot
$root      = Split-Path -Parent $allm
$studioApp = Join-Path $root "Studio\app"
$dados     = Join-Path $allm "dados"
$storage   = Join-Path $dados "storage"
$port      = 10090
$modelFile = if ($env:PENDRIVE_MODELO_DOCS) { $env:PENDRIVE_MODELO_DOCS } else { "Qwen3-8B-Q4_K_M.gguf" }
$contexto  = if ($env:PENDRIVE_CONTEXTO) { [int]$env:PENDRIVE_CONTEXTO } else { 16384 }
$model     = Join-Path $studioApp "llm-models\$modelFile"

New-Item -ItemType Directory -Force -Path $storage | Out-Null

if (-not (Test-Path $model)) { throw "Modelo nao encontrado: $model" }

# Chave de acesso do llama-server: gerada uma vez e guardada no pendrive.
$keyFile = Join-Path $dados "llm-api-key.txt"
if (-not (Test-Path $keyFile)) {
    ([guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N")) | Set-Content -LiteralPath $keyFile -NoNewline -Encoding ascii
}
$key = (Get-Content -LiteralPath $keyFile -Raw).Trim()

# O .env pode ter acento no que o proprio app escreveu (nome de voz, area). Ler como ANSI e
# regravar corrompia esses valores a cada abertura; e o -Encoding utf8 do PowerShell 5.1 poe BOM,
# que o leitor de .env enxerga como parte do primeiro nome. Entao: UTF-8 sem BOM, nas duas pontas.
function Get-EnvLinhas($caminho) { @(Get-Content -LiteralPath $caminho -Encoding UTF8) }
function Set-EnvLinhas($caminho, $linhas) {
    [IO.File]::WriteAllLines($caminho, [string[]]$linhas, (New-Object Text.UTF8Encoding($false)))
}

# .env do AnythingLLM (so na primeira vez; depois o proprio app mantem).
$envFile = Join-Path $storage ".env"
if (-not (Test-Path $envFile)) {
    $iniciais = @(
        "LLM_PROVIDER='generic-openai'"
        "GENERIC_OPEN_AI_BASE_PATH='http://127.0.0.1:$port/v1'"
        "GENERIC_OPEN_AI_MODEL_PREF='$modelFile'"
        # Tem que ser o contexto do hardware deste PC: com 16384 fixo, um PC fraco (que recebe
        # PENDRIVE_CONTEXTO menor) mandava contexto demais e o modelo recusava a pergunta.
        "GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT='$contexto'"
        "GENERIC_OPEN_AI_MAX_TOKENS='2048'"
        "GENERIC_OPEN_AI_API_KEY='$key'"
        "EMBEDDING_ENGINE='native'"
        "EMBEDDING_MODEL_PREF='MintplexLabs/multilingual-e5-small'"
        "VECTOR_DB='lancedb'"
        "DISABLE_TELEMETRY='true'"
    )
    Set-EnvLinhas $envFile $iniciais
    Write-Host "Configuracao inicial criada em $envFile"
} else {
    # Modelo e contexto seguem o hardware do PC atual; o resto do .env fica como o app deixou.
    $linhas = Get-EnvLinhas $envFile
    foreach ($par in @(@("GENERIC_OPEN_AI_MODEL_PREF", $modelFile), @("GENERIC_OPEN_AI_MODEL_TOKEN_LIMIT", "$contexto"))) {
        $chave = $par[0]; $valor = "$chave='$($par[1])'"
        if ($linhas -match "^$chave=") { $linhas = $linhas -replace "^$chave=.*$", $valor } else { $linhas += $valor }
    }
    Set-EnvLinhas $envFile $linhas
}

# Servidor MCP da Wikipedia offline (openzim-mcp lendo Kiwix\zim).
# Reescrito a cada abertura com os caminhos da letra atual do pendrive;
# outros servidores MCP que estiverem no arquivo sao preservados.
$python = Join-Path $root "Python\python312\python.exe"
$zimDir = Join-Path $root "Kiwix\zim"
if ((Test-Path $python) -and (Test-Path $zimDir)) {
    $pluginsDir = Join-Path $storage "plugins"
    New-Item -ItemType Directory -Force -Path $pluginsDir | Out-Null
    $mcpFile = Join-Path $pluginsDir "anythingllm_mcp_servers.json"
    $config = $null
    if (Test-Path $mcpFile) {
        try {
            $config = Get-Content -LiteralPath $mcpFile -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        } catch {
            # Arquivo ilegivel: guarda uma copia antes de recriar, para nao perder outros servidores.
            $backup = "$mcpFile.ilegivel-$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
            Copy-Item -LiteralPath $mcpFile -Destination $backup
            Write-Host "Configuracao MCP ilegivel; copia guardada em $backup"
            $config = $null
        }
    }
    if (-not $config) { $config = [pscustomobject]@{ mcpServers = [pscustomobject]@{} } }
    if (-not $config.mcpServers) {
        $config | Add-Member -NotePropertyName mcpServers -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    $server = [pscustomobject]@{
        command = $python
        args    = @("-m", "openzim_mcp", "--mode", "simple", $zimDir)
        env     = [pscustomobject]@{
            TIKTOKEN_CACHE_DIR = (Join-Path $root "Python\tiktoken-cache")
            PYTHONIOENCODING   = "utf-8"
        }
    }
    $config.mcpServers | Add-Member -NotePropertyName "wikipedia-offline" -NotePropertyValue $server -Force
    # Livros do Calibre (Menu\livros-mcp.py, indice Livros\indice\livros.db): so leitura, sem rede.
    $livrosMcp = Join-Path $root "Menu\livros-mcp.py"
    if (Test-Path $livrosMcp) {
        $livros = [pscustomobject]@{
            command = $python
            args    = @($livrosMcp)
            env     = [pscustomobject]@{ PYTHONIOENCODING = "utf-8" }
        }
        $config.mcpServers | Add-Member -NotePropertyName "livros-offline" -NotePropertyValue $livros -Force
    }
    # JSON sem BOM: o JSON.parse do servidor nao aceita BOM.
    [IO.File]::WriteAllText($mcpFile, ($config | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}

# Voz em portugues para o AnythingLLM: voz.py em 127.0.0.1:10091, com a mesma chave do modelo, nos
# provedores "OpenAI Compatible" de fala (Piper, vozes do Studio) e de microfone (whisper.cpp com o
# modelo Whisper do Studio; o microfone "Local Whisper" do AnythingLLM baixa modelo da internet).
# Provedor e voz so sao escolhidos se ainda nao houver escolha; endereco e chave seguem o pendrive.
# Opcional: se falhar, os documentos funcionam do mesmo jeito.
$vozPorta = 10091
$vozesDir = Join-Path $studioApp "tts-models\piper"
# whisper.cpp com OpenBLAS (encoder ~30% mais rapido no processador); sem ele, o do Studio.
$whisperCli = @((Join-Path $allm "whisper\whisper-cli.exe"), (Join-Path $studioApp "speech-backend\win\cpu\whisper-cli.exe")) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
# Whisper com CUDA (~2 s por pergunta em vez de ~10 s) so com driver NVIDIA e as DLLs CUDA do Studio.
# Se a placa falhar, o voz.py volta sozinho para o do processador.
$whisperCliPlaca = Join-Path $allm "whisper-cuda\whisper-cli.exe"
$dllsCuda = Join-Path $studioApp "llm-backend\win\cuda"
$placaWhisper = (Test-Path -LiteralPath (Join-Path $env:SystemRoot "System32\nvcuda.dll")) -and
    (Test-Path -LiteralPath $whisperCliPlaca) -and (Test-Path -LiteralPath (Join-Path $dllsCuda "cublas64_12.dll"))
$whisperModelo = @(Get-Item -LiteralPath (Join-Path $studioApp "speech-models\ggml-large-v3-turbo-q5_0.bin") -ErrorAction SilentlyContinue) +
    @(Get-ChildItem -LiteralPath (Join-Path $studioApp "speech-models") -Filter "ggml-*.bin" -ErrorAction SilentlyContinue) |
    Select-Object -First 1
function Get-VozEstado {
    # $null = nada respondendo; senao o JSON do /health (ok, falar, ouvir).
    try {
        $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$vozPorta/health")
        $req.Proxy = $null
        $req.Timeout = 2000
        $resp = $req.GetResponse()
        $texto = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $resp.Close()
        return ($texto | ConvertFrom-Json)
    } catch { return $null }
}
try {
    $vozes = @(Get-ChildItem -LiteralPath $vozesDir -Filter "*.onnx" -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath ($_.FullName + ".json") } | ForEach-Object { $_.BaseName })
    if ((Test-Path $python) -and $vozes.Count) {
        $linhas = Get-EnvLinhas $envFile
        $atual = @{}
        foreach ($l in $linhas) { if ($l -match "^((TTS|STT)_[A-Z_]+)='?([^']*)'?$") { $atual[$Matches[1]] = $Matches[3] } }
        $valores = [ordered]@{
            TTS_OPEN_AI_COMPATIBLE_ENDPOINT = "http://127.0.0.1:$vozPorta/v1"
            TTS_OPEN_AI_COMPATIBLE_KEY      = $key
            TTS_OPEN_AI_COMPATIBLE_MODEL    = "piper"
        }
        if (-not $atual["TTS_PROVIDER"]) { $valores["TTS_PROVIDER"] = "generic-openai" }
        if ($vozes -notcontains $atual["TTS_OPEN_AI_COMPATIBLE_VOICE_MODEL"]) {
            $valores["TTS_OPEN_AI_COMPATIBLE_VOICE_MODEL"] = if ($vozes -contains "pt_BR-faber-medium") { "pt_BR-faber-medium" } else { $vozes[0] }
        }
        if ($whisperCli -and $whisperModelo) {
            $valores["STT_OPEN_AI_COMPATIBLE_ENDPOINT"] = "http://127.0.0.1:$vozPorta/v1"
            $valores["STT_OPEN_AI_COMPATIBLE_KEY"] = $key
            $valores["STT_OPEN_AI_COMPATIBLE_MODEL"] = $whisperModelo.BaseName
            if (-not $atual["STT_PROVIDER"]) { $valores["STT_PROVIDER"] = "generic-openai" }
        }
        foreach ($chave in $valores.Keys) {
            $valor = "$chave='$($valores[$chave])'"
            if ($linhas -match "^$chave=") { $linhas = $linhas | ForEach-Object { if ($_ -match "^$chave=") { $valor } else { $_ } } } else { $linhas += $valor }
        }
        Set-EnvLinhas $envFile $linhas

        $estado = Get-VozEstado
        $antigo = $estado -and (($whisperCli -and $whisperModelo -and -not $estado.ouvir) -or
            ($placaWhisper -and $null -eq $estado.PSObject.Properties["ouvir_na_placa"]))
        # Troca o servidor de voz quando ele e de versao anterior (so falava, ou nao usava a placa)
        # E TAMBEM quando existe mas nao responde: um voz.py travado segurava a porta 10091 e o
        # servidor novo morria sem conseguir abri-la, deixando a voz desligada para sempre.
        if ($antigo -or -not $estado) {
            $pythonDir = (Split-Path -Parent $python).TrimEnd('\') + '\'
            $parados = 0
            Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
                Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($pythonDir, [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match 'voz(-piper)?\.py' } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; $parados++ }
            if ($parados) { Start-Sleep -Seconds 1 }
            $estado = $null
        }
        $vozLog = Join-Path $dados "voz.log"
        if (-not $estado) {
            $env:PYTHONIOENCODING = "utf-8"
            $argumentos = @(
                "`"$(Join-Path $PSScriptRoot 'voz.py')`"",
                "--porta", "$vozPorta",
                "--vozes", "`"$vozesDir`"",
                "--arquivo-chave", "`"$keyFile`"",
                # Pasta de trabalho no pendrive: o ditado e a transcricao nunca vao para o %TEMP% do PC.
                "--pasta-temp", "`"$(Join-Path $dados 'voz-temp')`""
            )
            if ($whisperCli -and $whisperModelo) {
                $argumentos += @("--whisper-cli", "`"$whisperCli`"", "--whisper-modelo", "`"$($whisperModelo.FullName)`"")
                if ($placaWhisper) { $argumentos += @("--whisper-cli-placa", "`"$whisperCliPlaca`"", "--dlls-cuda", "`"$dllsCuda`"") }
            }
            $vozProc = Start-Process -FilePath $python -ArgumentList $argumentos -WindowStyle Hidden -PassThru `
                -RedirectStandardError $vozLog -RedirectStandardOutput (Join-Path $dados "voz.out.log")
            for ($i = 0; $i -lt 40; $i++) {
                Start-Sleep -Milliseconds 500
                if ($vozProc.HasExited) { break }
                $estado = Get-VozEstado
                if ($estado) { break }
            }
        }
        if (-not $estado) { Write-Host "Aviso: a voz em portugues nao subiu (veja $vozLog). O resto funciona." }
        elseif ($estado.ouvir -and $estado.ouvir_na_placa) { Write-Host "Voz em portugues pronta: leitura das respostas e microfone (na placa de video)." }
        elseif ($estado.ouvir) { Write-Host "Voz em portugues pronta: leitura das respostas e microfone (no processador, ~10 s por pergunta)." }
        else { Write-Host "Voz em portugues pronta so para ler respostas (Whisper nao encontrado: microfone desligado)." }
    }
} catch {
    Write-Host "Aviso: a voz em portugues nao foi preparada: $($_.Exception.Message)"
}

function Test-LlmReady {
    # Sem proxy: num PC com proxy/WPAD configurado a checagem local pode travar.
    try {
        $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port/health")
        $req.Proxy = $null
        $req.Timeout = 2000
        $resp = $req.GetResponse()
        $ok = [int]$resp.StatusCode -eq 200
        $resp.Close()
        return $ok
    } catch { return $false }
}

function Get-LoadedModel {
    # /v1/models do llama-server responde sem chave e diz qual arquivo esta carregado.
    try {
        $req = [Net.HttpWebRequest]::Create("http://127.0.0.1:$port/v1/models")
        $req.Proxy = $null
        $req.Timeout = 3000
        $resp = $req.GetResponse()
        $texto = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
        $resp.Close()
        $json = $texto | ConvertFrom-Json
        if ($json.data) { return [string]$json.data[0].id }
        if ($json.models) { return [string]$json.models[0].model }
    } catch {}
    return ""
}

if (Test-LlmReady) {
    $carregado = Get-LoadedModel
    if ([IO.Path]::GetFileName($carregado) -eq $modelFile) { Write-Host "Modelo ja ativo na porta ${port}: $modelFile"; exit 0 }
    Write-Host "Na porta $port esta '$carregado', mas este PC pede '$modelFile'. Trocando..."
    & (Join-Path $PSScriptRoot "parar-llm.ps1") -ManterVoz
    Start-Sleep -Seconds 2
}

$order = @()
switch ($env:PENDRIVE_BACKEND) {
    "cuda"   { $order = @("cuda", "vulkan", "cpu") }
    "vulkan" { $order = @("vulkan", "cpu") }
    "cpu"    { $order = @("cpu") }
    default  {
        if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { $order += "cuda" }
        $order += "vulkan", "cpu"
    }
}

foreach ($variant in $order) {
    $exe = Join-Path $studioApp "llm-backend\win\$variant\llama-server.exe"
    if (-not (Test-Path $exe)) { continue }
    Write-Host "Carregando o modelo ($variant)..."
    $log = Join-Path $dados "llm-$variant.log"
    $outLog = Join-Path $dados "llm-$variant.out.log"
    # Start-Process do PowerShell 5.1 nao coloca aspas: caminhos vao entre aspas aqui.
    $arguments = @(
        "-m", "`"$model`"",
        "--host", "127.0.0.1",
        "--port", "$port",
        # Chave por ARQUIVO: em --api-key ela aparece na linha de comando do processo, e qualquer
        # programa do PC emprestado a le com Get-CimInstance Win32_Process (a mesma chave da voz).
        "--api-key-file", "`"$keyFile`"",
        "--ctx-size", "$contexto",
        # Memoria do contexto em 8 bits: medido em 16/09, 55 -> 62 tokens/s e 1 GB a menos na placa.
        "--cache-type-k", "q8_0", "--cache-type-v", "q8_0",
        "--n-gpu-layers", "99",
        "--reasoning-budget", "0",
        "--no-ui"
    )
    # O Qwen3.5-4B ignora o --reasoning-budget 0 e "pensa" antes de responder: medido em 16/09,
    # gastava a resposta inteira raciocinando e devolvia texto VAZIO ao bater o limite de tokens.
    # Pelo template (variavel de ambiente, que evita briga de aspas na linha de comando) ele para
    # de pensar: 7/7 acertos e 0,8 s por resposta, contra 1,1 s do 8B.
    $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
    # Rodando de pendrive (qualquer letra fora do C:), le o modelo inteiro de uma vez para a memoria
    # em vez de ir buscando pedaco no USB durante a conversa.
    if ($root.Substring(0, 1).ToUpper() -ne "C") { $arguments += "--no-mmap" }
    # Saída e erro vão para log: o processo não herda o console/pipe de quem chamou.
    $proc = Start-Process -FilePath $exe -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardError $log -RedirectStandardOutput $outLog
    for ($i = 0; $i -lt 120; $i++) {
        Start-Sleep -Seconds 1
        if ($proc.HasExited) { break }
        if (Test-LlmReady) { Write-Host "Modelo pronto ($variant)."; exit 0 }
    }
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    Write-Host "Nao subiu com $variant (log: $log). Tentando a proxima opcao..."
}

throw "Nao foi possivel iniciar o modelo de linguagem."
