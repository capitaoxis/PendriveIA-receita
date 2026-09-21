# Pendrive: menu único. Detecta o hardware, escolhe modelo e backend e abre cada ferramenta.
# Uso normal: MENU.bat
# Testes:     menu.ps1 -Diagnostico [-SimularSemPlaca] [-SimularRamGB 8]
#             menu.ps1 -Opcao 1          (executa uma opção e sai)
param(
    [switch]$Diagnostico,
    [switch]$SimularSemPlaca,
    [double]$SimularRamGB = 0,
    [string]$Opcao = ""
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "hardware.ps1")

$hw = Get-PendriveHardware -SemPlaca:$SimularSemPlaca -RamGB $SimularRamGB
$studioApp = Join-Path $root "Studio\app"
# Sem placa: o Qwen3-1.7B conversa bem mais rápido no processador (7/7 acertos; o 4B dá ~6 tok/s).
# ModeloDocs continua o maior (RAG precisa dele). Sem o arquivo, fica como estava.
$modeloLeve = "unsloth--Qwen3-1.7B-GGUF--Qwen3-1.7B-Q4_K_M.gguf"
if ($hw.Backend -eq "cpu" -and (Test-Path (Join-Path $studioApp "llm-models\$modeloLeve"))) {
    $hw.ModeloChat = $modeloLeve
}

function Write-Linha($texto, $cor = "Gray") { Write-Host $texto -ForegroundColor $cor }

function Show-Cabecalho {
    Clear-Host
    Write-Linha ""
    Write-Linha "  ============================================================" Cyan
    Write-Linha "   PENDRIVE IA  |  tudo roda neste computador, sem internet" Cyan
    Write-Linha "  ============================================================" Cyan
    Write-Linha ("   Processador: {0} ({1} núcleos)" -f $hw.Processador, $hw.Nucleos)
    Write-Linha ("   Memória RAM: {0} GB" -f $hw.RamGB)
    if ($hw.Placas.Count -gt 0) {
        foreach ($p in $hw.Placas) { Write-Linha ("   Placa de vídeo: {0} ({1} GB)" -f $p.Nome, $p.VramGB) }
    } else {
        Write-Linha "   Placa de vídeo: nenhuma utilizável"
    }
    Write-Linha ("   Perfil: {0}  ->  modelo {1}" -f $hw.Perfil, (Get-NomeCurto $hw.ModeloChat)) Green
    if ($hw.Aviso) { Write-Linha ("   Atenção: " + $hw.Aviso) Yellow }
    Write-Linha "  ------------------------------------------------------------" DarkGray
}

function Get-NomeCurto($arquivo) {
    $n = [IO.Path]::GetFileNameWithoutExtension($arquivo)
    if ($n.Contains("--")) { $n = $n.Substring($n.LastIndexOf("--") + 2) }
    return $n
}

# O Studio guarda, por modelo, o backend usado da última vez. Um pendrive que passou por um PC
# sem placa (ou pelos testes de CPU) abriria tudo no processador num PC com placa, e vice-versa.
function Set-BackendDoStudio {
    $cfgDir = Join-Path $studioApp "config"
    $cfgFile = Join-Path $cfgDir "llm-model-settings.json"
    New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
    $cfg = $null
    if (Test-Path $cfgFile) { try { $cfg = Get-Content -LiteralPath $cfgFile -Raw | ConvertFrom-Json } catch { $cfg = $null } }
    if (-not $cfg) { $cfg = [pscustomobject]@{ models = [pscustomobject]@{} } }
    if (-not $cfg.models) { $cfg | Add-Member -NotePropertyName models -NotePropertyValue ([pscustomobject]@{}) -Force }
    $modelos = Get-ChildItem -LiteralPath (Join-Path $studioApp "llm-models") -Filter *.gguf -File | Where-Object { $_.Name -notmatch 'mmproj' }
    foreach ($m in $modelos) {
        $atual = $cfg.models.PSObject.Properties[$m.Name]
        if (-not $atual) {
            $cfg.models | Add-Member -NotePropertyName $m.Name -NotePropertyValue ([pscustomobject]@{ preferredBackend = $hw.Backend }) -Force
        } else {
            $atual.Value | Add-Member -NotePropertyName preferredBackend -NotePropertyValue $hw.Backend -Force
        }
    }
    [IO.File]::WriteAllText($cfgFile, ($cfg | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))
}

function Invoke-Local {
    param([string]$Metodo, [string]$Url, [string]$Corpo = "", [int]$TimeoutMs = 5000)
    # Sem proxy: num PC com proxy/WPAD configurado a chamada local pode travar.
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Proxy = $null; $req.Method = $Metodo; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
    if ($Corpo) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Corpo)
        $req.ContentType = "application/json"
        $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    }
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        if (-not $_.Exception.Response) { throw }
        $resp = $_.Exception.Response
    }
    $texto = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
    $resp.Close()
    return $texto
}

function Test-Studio {
    try { $null = Invoke-Local GET "http://127.0.0.1:1420/api/health" -TimeoutMs 2000; return $true } catch { return $false }
}

function Start-Studio {
    param([switch]$CarregarModelo)
    Set-BackendDoStudio
    if (-not (Test-Studio)) {
        Write-Linha "  Abrindo o Studio (a janela preta dele precisa ficar aberta)..."
        # Sem isto o Qwen3.5-4B (o modelo dos PCs mais fracos) "pensa" antes de cada resposta:
        # medido em 16/09, gasta o tempo todo raciocinando e devolve a resposta VAZIA quando o
        # limite de tokens acaba. Desligado, acerta o mesmo que o 8B e responde em 0,8 s.
        # A variavel e herdada pelo llama-server que o Studio abre.
        $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$root\Studio\windows.bat`"" -WorkingDirectory (Join-Path $root "Studio") | Out-Null
        $fim = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $fim -and -not (Test-Studio)) { Start-Sleep -Seconds 1 }
        if (-not (Test-Studio)) { Write-Linha "  O Studio não respondeu em 2 minutos. Veja a janela dele." Red; return }
    }
    if (-not $CarregarModelo) { return }

    $querCpu = $hw.Backend -eq "cpu"
    try {
        $st = (Invoke-Local GET "http://127.0.0.1:1420/api/llm/status") | ConvertFrom-Json
        $s = $st.settings
        $mesmoBackend = ($querCpu -and $s.gpuLayers -eq 0) -or (-not $querCpu -and $s.gpuLayers -ne 0)
        if ($st.ready -and $s.model -eq $hw.ModeloChat -and $s.loadProfile -ne "safe" -and $mesmoBackend) {
            Write-Linha ("  {0} já está carregado. Use a aba Text Chat." -f (Get-NomeCurto $s.model)) Green
            return
        }
    } catch {}

    # Dois modelos na mesma placa não cabem (8B ocupa ~6 GB): desliga o modelo dos Documentos.
    if (Get-NetTCPConnection -LocalPort 10090 -State Listen -ErrorAction SilentlyContinue) {
        Write-Linha "  Desligando o modelo dos Documentos para liberar a memória..." Yellow
        & (Join-Path $root "AnythingLLM\pendrive\parar-llm.ps1") -ManterVoz
        Start-Sleep -Seconds 2
    }

    # O Studio recusa carregar um modelo com outro já carregado, e trata a recusa como falha:
    # cai no perfil "safe" (sem placa, contexto 4096) sem avisar. Por isso descarrega antes.
    try { $null = Invoke-Local POST "http://127.0.0.1:1420/api/llm/stop" "{}" -TimeoutMs 60000 } catch {}
    try { $null = Invoke-Local POST "http://127.0.0.1:1420/api/stop-backend" "{}" -TimeoutMs 60000 } catch {}

    Write-Linha ("  Carregando {0} ({1})... pode levar até 1 minuto." -f (Get-NomeCurto $hw.ModeloChat), $hw.Backend)
    $corpo = @{ model = $hw.ModeloChat; preferredBackend = $hw.Backend; gpuLayers = $hw.CamadasGPU; contextSize = $hw.Contexto } | ConvertTo-Json -Compress
    try {
        $r = (Invoke-Local POST "http://127.0.0.1:1420/api/llm/start" $corpo -TimeoutMs 300000) | ConvertFrom-Json
        if (-not $r.ok) { Write-Linha ("  O modelo não carregou: {0}" -f $r.error) Red; return }
        $s = $r.settings
        if ($s.loadProfile -eq "safe") {
            Write-Linha ("  Carregou em modo de segurança (contexto {0}, camadas na placa {1}): vai ficar lento." -f $s.contextSize, $s.gpuLayers) Yellow
            foreach ($f in @($s.backendFallbacks)) { if ($f) { Write-Linha ("    motivo: {0}" -f $f.error) DarkYellow } }
        } else {
            Write-Linha ("  Pronto: {0} em {1} (contexto {2}). Use a aba Text Chat." -f (Get-NomeCurto $s.model), $s.backendMode, $s.contextSize) Green
        }
    } catch {
        Write-Linha ("  Falha ao carregar o modelo: {0}" -f $_.Exception.Message) Red
    }
}

function Start-Bat($nome) {
    $bat = Join-Path $root $nome
    if (-not (Test-Path $bat)) { Write-Linha "  Não encontrei $nome." Red; return }
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "`"$bat`"" -WorkingDirectory $root | Out-Null
}

# Abre um .cmd numa janela própria que continua aberta (cmd /k) para ler o resultado.
function Start-Cmd {
    param([string]$Nome, [string]$Pasta = "")
    $cmd = Join-Path $root $Nome
    if (-not (Test-Path $cmd)) { Write-Linha "  $Nome não está instalado neste pendrive." Yellow; return }
    if (-not $Pasta) { $Pasta = $root }
    Start-Process -FilePath "cmd.exe" -ArgumentList "/k", "`"$cmd`"" -WorkingDirectory $Pasta | Out-Null
}

# Tela do menu por grupos. Tecla, texto e o arquivo que precisa existir (vazio = sempre mostra).
# As teclas antigas NÃO mudam: o usuario já as decorou.
$grupos = @(
    @{ Nome = "Conversar e criar"; Itens = @(
        @("1", "Conversar com a IA (Studio, já com o modelo recomendado)", "Studio\windows.bat"),
        @("2", "Gerar imagem ou transcrever áudio (Studio)", "Studio\windows.bat"),
        @("3", "Documentos e IA que consulta a Wikipédia (AnythingLLM)", "Documentos.bat"),
        @("4", "Wikipédia e acervos offline (navegador)", "Wikipedia.bat")) },
    @{ Nome = "Estudar e pesquisar"; Itens = @(
        @("5", "Livros (Calibre)", "Livros.bat"),
        @("Q", "Perguntar aos livros: a IA responde citando o livro", "Menu\livros-busca.py"),
        @("E", "Estudo: flashcards ou simulado a partir de um PDF", "ESTUDO.cmd"),
        @("A", "Flashcards para estudar (Anki)", ""),
        @("Z", "Referências e citações (Zotero)", "")) },
    @{ Nome = "Clínica"; Itens = @(
        @("K", "Consulta: gravar, transcrever e gerar resumo + SOAP", "CONSULTA.cmd"),
        @("7", "Epi Info 7", "EpiInfo.bat"),
        @("6", "Estatística (R)", "R.bat"),
        @("J", "Estatística com cliques (JASP)", "")) },
    @{ Nome = "Programar"; Itens = @(
        @("I", "IA no terminal (ia, codar, git, python, npm)", "ATIVAR-IA.cmd"),
        @("X", "Codar: programar com a IA (abre nos Documentos)", "codar.cmd"),
        @("V", "Servidor de IA para VS Code/aider (127.0.0.1:11480)", "IA-SERVIDOR.cmd")) },
    @{ Nome = "Ferramentas"; Itens = @(
        @("O", "Textos, planilhas e slides (LibreOffice)", ""),
        @("S", "Guardar senhas (KeePassXC)", ""),
        @("D", "Fazer diagramas (draw.io)", ""),
        @("P", "Ler PDF (SumatraPDF)", ""),
        @("U", "Juntar, separar e girar PDF (PDF Arranger)", ""),
        @("8", "Tornar PDF escaneado pesquisável (OCR)", "Ferramentas\NAPS2\NAPS2.Portable.exe"),
        @("9", "Guardar arquivos com senha (7-Zip)", "Ferramentas\7-Zip\7zFM.exe"),
        @("T", "Transcrever uma gravação (entrevista, aula, consulta), separando quem falou", ""),
        @("C", "Conferir se o pendrive não estragou nenhum arquivo", "")) },
    @{ Nome = "Pendrive"; Itens = @(
        @("F", "Cofre pessoal: abrir ou fechar (VeraCrypt)", "COFRE.cmd"),
        @("B", "Ver se há atualização de modelos e Wikipédia", "ATUALIZAR.cmd"),
        @("M", "Testar o pendrive neste PC (5 a 30 min)", "TESTAR.cmd"),
        @("N", "Instalar em outro pendrive", "INSTALAR-EM-OUTRO.cmd"),
        @("H", "Página de início com todos os comandos (INICIO.html)", "INICIO.html"),
        @("L", "Ler o LEIA-ME", "LEIA-ME.md")) }
)

function Show-Menu {
    foreach ($g in $grupos) {
        Write-Linha ("  -- {0} " -f $g.Nome).PadRight(62, "-") DarkCyan
        foreach ($it in $g.Itens) {
            $falta = $it[2] -and -not (Test-Path (Join-Path $root $it[2]))
            if ($falta) { Write-Linha ("   {0}  {1}  (não instalado)" -f $it[0], $it[1]) DarkGray }
            else { Write-Linha ("   {0}  {1}" -f $it[0], $it[1]) }
        }
    }
    Write-Linha "   0  Sair"
    Write-Linha ""
}

function Invoke-Opcao($escolha) {
    switch ($escolha.ToUpper()) {
        "1" { Start-Studio -CarregarModelo }
        "2" { Start-Studio }
        "3" {
            if (Test-Studio) {
                # Dois modelos na mesma placa não cabem: descarrega o do Studio (a janela dele continua aberta).
                Write-Linha "  Descarregando o modelo do Studio para liberar a memória..." Yellow
                try { $null = Invoke-Local POST "http://127.0.0.1:1420/api/llm/stop" "{}" -TimeoutMs 60000 } catch {}
                try { $null = Invoke-Local POST "http://127.0.0.1:1420/api/stop-backend" "{}" -TimeoutMs 60000 } catch {}
            }
            $env:PENDRIVE_MODELO_DOCS = $hw.ModeloDocs
            $env:PENDRIVE_CONTEXTO = [string]$hw.Contexto
            $env:PENDRIVE_BACKEND = $hw.Backend
            Start-Bat "Documentos.bat"
        }
        "4" { Start-Bat "Wikipedia.bat" }
        "5" { Start-Bat "Livros.bat" }
        "Q" {
            $pergunta = Read-Host "  O que voce quer saber? (a IA responde so com o que esta nos livros)"
            if ($pergunta) { & (Join-Path $PSScriptRoot "ia.ps1") -l $pergunta } else { Write-Linha "  Cancelado." }
        }
        "6" { Start-Bat "R.bat" }
        "7" { Start-Bat "EpiInfo.bat" }
        "8" { Start-Process -FilePath (Join-Path $root "Ferramentas\NAPS2\NAPS2.Portable.exe") | Out-Null }
        "9" { Start-Process -FilePath (Join-Path $root "Ferramentas\7-Zip\7zFM.exe") | Out-Null }
        "A" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa anki }
        "Z" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa zotero }
        "O" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa libreoffice }
        "J" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa jasp }
        "S" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa keepassxc }
        "D" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa drawio }
        "P" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa pdf }
        "U" { $null = & (Join-Path $PSScriptRoot "abrir.ps1") -Programa pdfarranger }
        "T" {
            $r = Read-Host "  Separar quem falou? Digite quantas pessoas (ex.: 2), S se nao souber, ou Enter para nao separar"
            if ($r -match '^\d+$') { & (Join-Path $PSScriptRoot "transcrever-audio.ps1") -QuemFalou -Pessoas ([int]$r) }
            elseif ($r -match '^[sS]') { & (Join-Path $PSScriptRoot "transcrever-audio.ps1") -QuemFalou }
            else { & (Join-Path $PSScriptRoot "transcrever-audio.ps1") }
        }
        "C" { & (Join-Path $PSScriptRoot "conferir-pendrive.ps1") }
        "I" { Start-Bat "ATIVAR-IA.cmd" }
        "L" { Start-Process -FilePath "notepad.exe" -ArgumentList "`"$(Join-Path $root 'LEIA-ME.md')`"" | Out-Null }
        # Comandos novos (19/09). Os de conversa ficam numa janela que não fecha sozinha.
        "K" { Start-Cmd "CONSULTA.cmd" }
        "E" { Start-Cmd "ESTUDO.cmd" }
        "X" { Start-Cmd "codar.cmd" -Pasta ([Environment]::GetFolderPath("MyDocuments")) }
        "V" { Start-Cmd "IA-SERVIDOR.cmd" }
        "F" { Start-Cmd "COFRE.cmd" }
        "B" { Start-Cmd "ATUALIZAR.cmd" }
        "M" { Start-Cmd "TESTAR.cmd" }
        "N" { Start-Cmd "INSTALAR-EM-OUTRO.cmd" }
        "H" {
            $inicio = Join-Path $root "INICIO.html"
            if (-not (Test-Path $inicio)) { Write-Linha "  Não encontrei INICIO.html." Red } else { Start-Process -FilePath $inicio | Out-Null }
        }
        "0" { return $false }
        default { Write-Linha "  Opção inválida." Yellow }
    }
    return $true
}

if ($Diagnostico) {
    $hw | ConvertTo-Json -Depth 4
    exit 0
}

if ($Opcao) {
    $null = Invoke-Opcao $Opcao
    exit 0
}

do {
    Show-Cabecalho
    Show-Menu
    $escolha = Read-Host "  Escolha"
    if ($null -eq $escolha) { break }
    try {
        $continuar = Invoke-Opcao $escolha
    } catch {
        # Falha de uma opcao (programa faltando, PC sem algo) nao pode derrubar o menu: antes o
        # erro subia ate o fim do script e a janela do MENU.bat fechava sem mostrar mensagem.
        Write-Linha ""
        Write-Linha ("  Nao deu certo: " + $_.Exception.Message) Red
        $continuar = $true
    }
    if ($continuar -and $escolha -ne "0") {
        Write-Linha ""
        $null = Read-Host "  Enter para voltar ao menu"
    }
} while ($continuar)
