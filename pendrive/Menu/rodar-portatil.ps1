# Pendrive: roda um programa que NAO tem modo portatil sem deixar rastro no computador.
# Uso: rodar-portatil.ps1 -Programa jasp|zotero
#
# JASP grava %APPDATA%\JASP (configuracao, AutoSaves, modulos), %LOCALAPPDATA%\JASP (cache),
# Documentos\JASP_Sandbox e HKCU\Software\JASP. O Zotero (base Firefox) grava %APPDATA%\Zotero,
# %LOCALAPPDATA%\Zotero, %APPDATA%\Mozilla\Extensions e chaves em HKCU\Software\{Mozilla,Zotero}.
#
# Este script: traz do pendrive o que precisa existir, anota o que JA existia no PC, abre o
# programa, espera fechar, guarda de volta no pendrive e apaga SO o que ele mesmo criou.
# Se der um desligamento no meio, a marca em Ferramentas\<programa>-dados avisa e a limpeza
# acontece na abertura seguinte.
param([Parameter(Mandatory = $true)][ValidateSet("jasp", "zotero")][string]$Programa)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$ferr = Join-Path $root "Ferramentas"
$docs = [Environment]::GetFolderPath("MyDocuments")
$semBom = New-Object Text.UTF8Encoding($false)

$conf = switch ($Programa) {
    "jasp" {
        @{
            Exe        = Join-Path $ferr "JASP\JASPDesktop.exe"
            Argumentos = @()
            Dados      = Join-Path $ferr "JASP-dados"
            # pasta no PC = pasta guardada no pendrive (vai e volta a cada sessao)
            Sincronizar = @(@{ Pc = Join-Path $env:APPDATA "JASP"; Guardado = "Roaming" },
                            @{ Pc = Join-Path $env:LOCALAPPDATA "JASP"; Guardado = "Local" })
            Limpar     = @((Join-Path $env:APPDATA "JASP"), (Join-Path $env:LOCALAPPDATA "JASP"), (Join-Path $docs "JASP_Sandbox"))
            Chaves     = @("HKCU:\Software\JASP")
            NaoGuardar = @("JASP\cache")   # 18 MB de cache do Qt, refeito sozinho
            Ambiente   = @{ QML_DISABLE_DISK_CACHE = "1" }
        }
    }
    "zotero" {
        $perfil = Join-Path $ferr "Zotero-dados\perfil"
        @{
            Exe        = Join-Path $ferr "Zotero\zotero.exe"
            Argumentos = @("-profile", "`"$perfil`"", "-datadir", "profile", "-no-remote")
            Dados      = Join-Path $ferr "Zotero-dados"
            Sincronizar = @()   # perfil e biblioteca ja ficam no pendrive
            # A pasta Mozilla so e apagada se nao existia antes (num PC com Firefox ela fica).
            Limpar     = @((Join-Path $env:APPDATA "Zotero"), (Join-Path $env:LOCALAPPDATA "Zotero"), (Join-Path $env:APPDATA "Mozilla\Extensions"), (Join-Path $env:APPDATA "Mozilla"))
            Chaves     = @("HKCU:\Software\Zotero", "HKCU:\Software\Mozilla")
            NaoGuardar = @()
            Ambiente   = @{}
        }
    }
}
$dados = $conf.Dados
New-Item -ItemType Directory -Force -Path $dados | Out-Null
$log = Join-Path $dados "portatil.log"
$marca = Join-Path $dados ".sessao-aberta.json"
function Log($m) { Add-Content -LiteralPath $log -Value ("{0} {1}" -f (Get-Date -Format s), $m) -Encoding UTF8 }

function Copiar-Conteudo($de, $para) {
    if (-not (Test-Path -LiteralPath $de)) { return }
    New-Item -ItemType Directory -Force -Path $para | Out-Null
    Get-ChildItem -LiteralPath $de -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $para -Recurse -Force }
}
function Guardar-E-Limpar($jaExistia) {
    foreach ($s in $conf.Sincronizar) {
        if ($jaExistia -contains $s.Pc) { continue }
        $destino = Join-Path $dados $s.Guardado
        if (Test-Path -LiteralPath $s.Pc) {
            # Monta a copia nova ao lado e so troca no fim. Apagar o que esta guardado ANTES de
            # copiar significava que uma falha no meio (pendrive removido, arquivo travado) deixava
            # o pendrive sem a configuracao e sem a copia - as duas perdidas de uma vez.
            $novo = "$destino.novo"
            Remove-Item -LiteralPath $novo -Recurse -Force -ErrorAction SilentlyContinue
            Copiar-Conteudo $s.Pc $novo
            foreach ($n in $conf.NaoGuardar) { Remove-Item -LiteralPath (Join-Path $novo $n) -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $destino) { Remove-Item -LiteralPath $destino -Recurse -Force }
            Move-Item -LiteralPath $novo -Destination $destino
        }
    }
    foreach ($c in $conf.Limpar) { if ($jaExistia -notcontains $c -and (Test-Path -LiteralPath $c)) { Remove-Item -LiteralPath $c -Recurse -Force -ErrorAction SilentlyContinue } }
    foreach ($k in $conf.Chaves) { if ($jaExistia -notcontains $k -and (Test-Path $k)) { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue } }
}

# Sessao anterior interrompida (queda de energia, por exemplo): termina a limpeza dela agora.
# So se a queda foi NESTE computador e com ESTE usuario: a marca viaja no pendrive, e a lista
# "o que ja existia" e de outra maquina. Num PC que tem Firefox, limpar com a lista de um PC que
# nao tinha apagaria o perfil do Mozilla do dono - favoritos, senhas e historico.
$identidade = "$env:COMPUTERNAME\$env:USERNAME"
if (Test-Path -LiteralPath $marca) {
    $anteriorJson = Get-Content -LiteralPath $marca -Raw | ConvertFrom-Json
    if ($anteriorJson.pc -eq $identidade) {
        Log "sessao anterior nao foi encerrada: guardando e limpando agora"
        Guardar-E-Limpar @($anteriorJson.jaExistia)
    } else {
        Log "marca de sessao aberta em '$($anteriorJson.pc)'; aqui e '$identidade': nada a limpar neste PC"
    }
    Remove-Item -LiteralPath $marca -Force
}

$jaExistia = @()
foreach ($c in $conf.Limpar) { if (Test-Path -LiteralPath $c) { $jaExistia += $c } }
foreach ($k in $conf.Chaves) { if (Test-Path $k) { $jaExistia += $k } }
if ($jaExistia.Count) { Log ("este PC ja tinha: " + ($jaExistia -join ", ") + " (nao serao apagados)") }

foreach ($s in $conf.Sincronizar) {
    if ($jaExistia -contains $s.Pc) { continue }
    Copiar-Conteudo (Join-Path $dados $s.Guardado) $s.Pc
}
[IO.File]::WriteAllText($marca, (@{ pc = $identidade; jaExistia = $jaExistia; inicio = (Get-Date -Format s) } | ConvertTo-Json), $semBom)
foreach ($nome in $conf.Ambiente.Keys) { Set-Item -Path ("env:" + $nome) -Value $conf.Ambiente[$nome] }

$params = @{ FilePath = $conf.Exe; WorkingDirectory = (Split-Path -Parent $conf.Exe); PassThru = $true }
if ($conf.Argumentos.Count) { $params.ArgumentList = $conf.Argumentos }
$p = Start-Process @params
Log "$Programa aberto (pid $($p.Id))"
$p.WaitForExit()
$pasta = (Split-Path -Parent $conf.Exe).TrimEnd('\') + '\'
for ($i = 0; $i -lt 120; $i++) {
    if (-not @(Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($pasta, [StringComparison]::OrdinalIgnoreCase) }).Count) { break }
    Start-Sleep -Seconds 1
}
Start-Sleep -Seconds 2
Guardar-E-Limpar $jaExistia
Remove-Item -LiteralPath $marca -Force -ErrorAction SilentlyContinue
Log "$Programa fechado: dados no pendrive e rastros apagados do PC"
