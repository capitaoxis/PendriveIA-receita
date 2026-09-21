# Pendrive: abre os programas de estudo e escritorio guardando tudo dentro do pendrive.
# Uso: abrir.ps1 -Programa anki|zotero|libreoffice|jasp|keepassxc|drawio|pdf|pdfarranger [-Arquivo x] [-Esperar]
# Cada programa recebe onde guardar configuracao e dados (pasta *-dados em Ferramentas) e tem a
# atualizacao automatica desligada: os arquivos conferidos por hash nao devem ser trocados sozinhos.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("anki", "zotero", "libreoffice", "jasp", "keepassxc", "drawio", "pdf", "pdfarranger")]
    [string]$Programa,
    [string]$Arquivo = "",
    [switch]$Esperar
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$ferr = Join-Path $root "Ferramentas"
$semBom = New-Object Text.UTF8Encoding($false)

function Test-Exe($caminho) {
    if (-not (Test-Path -LiteralPath $caminho)) { throw "Nao encontrei $caminho" }
    return $caminho
}
function Save-SeFaltar($caminho, $conteudo) {
    if (Test-Path -LiteralPath $caminho) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $caminho) | Out-Null
    [IO.File]::WriteAllText($caminho, $conteudo, $semBom)
}

$exe = $null; $argumentos = @(); $pasta = $null
switch ($Programa) {
    "anki" {
        # -b: pasta base do Anki (perfis, colecoes, midia). Sem isso ele usa %APPDATA%\Anki2.
        $exe = Test-Exe (Join-Path $ferr "Anki\Anki.exe")
        $dados = Join-Path $ferr "Anki-dados"
        New-Item -ItemType Directory -Force -Path $dados | Out-Null
        $argumentos = @("-b", "`"$dados`"")
        # Sem isto o Qt cria %LOCALAPPDATA%\Anki\cache (cache de pipeline grafico) no computador.
        $env:QSG_RHI_DISABLE_DISK_CACHE = "1"
    }
    "zotero" {
        # -profile + -datadir profile: perfil e biblioteca (zotero.sqlite, anexos, estilos) no pendrive.
        # O resto (pastas em AppData e chaves do Firefox) quem limpa e o rodar-portatil.ps1.
        $null = Test-Exe (Join-Path $ferr "Zotero\zotero.exe")
        $perfil = Join-Path $ferr "Zotero-dados\perfil"
        Save-SeFaltar (Join-Path $perfil "user.js") (@(
            'user_pref("app.update.auto", false);'
            'user_pref("app.update.staging.enabled", false);'
            'user_pref("intl.locale.requested", "pt-BR");'
            '// Sem isto o Zotero instala o complemento dele no LibreOffice DO COMPUTADOR.'
            'user_pref("extensions.zoteroOpenOfficeIntegration.skipInstallation", true);'
        ) -join "`r`n")
        # Estilos ABNT e Vancouver copiados para a biblioteca na primeira abertura.
        $estilos = Join-Path $perfil "zotero\styles"
        New-Item -ItemType Directory -Force -Path $estilos | Out-Null
        foreach ($csl in Get-ChildItem -LiteralPath (Join-Path $ferr "Zotero-estilos") -Filter *.csl -ErrorAction SilentlyContinue) {
            $destino = Join-Path $estilos $csl.Name
            if (-not (Test-Path -LiteralPath $destino)) { Copy-Item -LiteralPath $csl.FullName -Destination $destino }
        }
        $exe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $argumentos = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$(Join-Path $PSScriptRoot 'rodar-portatil.ps1')`"", "-Programa", "zotero")
    }
    "libreoffice" {
        # -env:UserInstallation: perfil do LibreOffice no pendrive (caminho em URL file:///).
        $exe = Test-Exe (Join-Path $ferr "LibreOffice\program\soffice.exe")
        $perfil = Join-Path $ferr "LibreOffice-perfil"
        Save-SeFaltar (Join-Path $perfil "user\registrymodifications.xcu") (@(
            '<?xml version="1.0" encoding="UTF-8"?>'
            '<oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
            '<item oor:path="/org.openoffice.Office.Jobs/Jobs/org.openoffice.Office.Jobs:Job[''UpdateCheck'']/Arguments"><prop oor:name="AutoCheckEnabled" oor:op="fuse"><value>false</value></prop></item>'
            '<item oor:path="/org.openoffice.Setup/L10N"><prop oor:name="ooLocale" oor:op="fuse"><value>pt-BR</value></prop></item>'
            '<item oor:path="/org.openoffice.Office.Linguistic/General"><prop oor:name="DefaultLocale" oor:op="fuse"><value>pt-BR</value></prop></item>'
            '<item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="ShowTipOfTheDay" oor:op="fuse"><value>false</value></prop></item>'
            '</oor:items>'
        ) -join "`n")
        $url = "file:///" + ($perfil -replace '\\', '/')
        $argumentos = @("`"-env:UserInstallation=$url`"")
    }
    "jasp" {
        # O JASP nao e portatil: rodar-portatil.ps1 traz a configuracao do pendrive, espera fechar,
        # guarda de volta e limpa o PC. Roda escondido para o menu nao ficar preso.
        $null = Test-Exe (Join-Path $ferr "JASP\JASPDesktop.exe")
        # Juncao guarda caminho ABSOLUTO (letra do drive): em outra letra ou pasta os modulos somem.
        # Se a primeira juncao aponta para lugar inexistente, apaga so os links e recria no lugar atual.
        $mods = Join-Path $ferr "JASP\Modules"
        # Tambem repara quando NAO ha juncao nenhuma (ex.: reparo anterior apagou e o JunctionTool falhou).
        $mapa = Join-Path $ferr "JASP\junctions_map.txt"
        $amostra = Get-ChildItem (Join-Path $mods "module_libs") -Recurse -Depth 1 -Force -ErrorAction SilentlyContinue | Where-Object LinkType -eq 'Junction' | Select-Object -First 1
        $precisa = if ($amostra) { -not (Test-Path ($amostra.Target | Select-Object -First 1)) } else { Test-Path $mapa }
        if ($precisa) {
            Write-Host "  Ajustando os modulos do JASP para esta letra de drive (so na primeira vez)..."
            Get-ChildItem (Join-Path $mods "module_libs") -Recurse -Depth 1 -Force -ErrorAction SilentlyContinue |
                Where-Object LinkType -eq 'Junction' | ForEach-Object { [IO.Directory]::Delete($_.FullName, $false) }
            $saidaJt = & (Join-Path $ferr "JASP\JunctionTool.exe") -c $mapa $mods $mods 2>&1 | Out-String
            $okJt = if ($saidaJt -match 'Success:\s*(\d+)') { [int]$Matches[1] } else { 0 }
            if ($okJt -lt 6067) {
                Write-Host "  FALHOU o reparo dos modulos do JASP: $okJt de 6067 juncoes. O JASP pode abrir sem modulos." -ForegroundColor Red
                Write-Host "  Ele sera tentado de novo na proxima vez que abrir o JASP." -ForegroundColor Red
            }
        }
        Save-SeFaltar (Join-Path $ferr "JASP-dados\Roaming\JASP.ini") "[General]`r`npreferredLanguage=pt`r`ncheckUpdates=false`r`ncheckUpdatesAskUser=false`r`n"
        $exe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
        $argumentos = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", "`"$(Join-Path $PSScriptRoot 'rodar-portatil.ps1')`"", "-Programa", "jasp")
    }
    "keepassxc" {
        # O arquivo .portable faz o KeePassXC guardar a configuracao em KeePassXC\config.
        $exe = Test-Exe (Join-Path $ferr "KeePassXC\KeePassXC.exe")
    }
    "drawio" {
        $exe = Test-Exe (Join-Path $ferr "drawio\draw.io.exe")
        $dados = Join-Path $ferr "drawio-dados"
        $argumentos = @("--user-data-dir=`"$dados`"", "--disable-update")
    }
    "pdf" {
        # SumatraPDF portatil: guarda SumatraPDF-settings.txt ao lado do exe.
        $exe = Test-Exe (Join-Path $ferr "SumatraPDF\SumatraPDF.exe")
    }
    "pdfarranger" {
        # (O PDFsam foi testado e descartado: guarda as preferencias no registro do Windows.)
        # config.ini ao lado do exe = modo portatil do PDF Arranger.
        $exe = Test-Exe (Join-Path $ferr "PDFArranger\pdfarranger.exe")
    }
}
if ($Arquivo) {
    # Zotero e JASP sobem pelo rodar-portatil.ps1: o caminho seria anexado AQUELA linha de comando
    # e o script morreria no binding, sem abrir nada e sem mostrar erro (a janela e escondida).
    if ($Programa -in @("zotero", "jasp")) { throw "$Programa nao aceita -Arquivo: abra o programa e use o menu dele." }
    $argumentos += "`"$Arquivo`""
}
$params = @{ FilePath = $exe; WorkingDirectory = (Split-Path -Parent $exe); PassThru = $true }
if ($argumentos.Count) { $params.ArgumentList = $argumentos }
$proc = Start-Process @params
if ($Esperar) { $proc.WaitForExit() }
$proc
