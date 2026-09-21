# Cofre pessoal do pendrive (VeraCrypt portatil).
# - Sem Pessoal.hc na raiz: explica e abre o assistente do VeraCrypt para o usuario criar.
# - Com Pessoal.hc fechado: monta numa letra livre e abre o Explorer (a senha e pedida pela
#   janela do proprio VeraCrypt; este script nunca ve, recebe ou grava senha).
# - Com o cofre aberto: fecha (desmonta).
# O VeraCrypt precisa carregar um driver no Windows: isso exige administrador. Sem admin, pede
# elevacao (UAC). Em PC alheio sem senha de administrador, o cofre NAO abre.
param([string]$Ocupadas = "")
$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot
$cofre = Join-Path $raiz "Pessoal.hc"
$marca = Join-Path $raiz "Menu\cofre.letra"   # so a letra da unidade aberta, nada secreto
$pasta = Join-Path $raiz "Ferramentas\VeraCrypt"
$sufixo = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$vc = Join-Path $pasta "VeraCrypt-$sufixo.exe"
$vcFormat = Join-Path $pasta "VeraCrypt Format-$sufixo.exe"

function Pausa { Write-Host ""; Write-Host "Aperte ENTER para sair."; [void][Console]::ReadLine() }

if (-not (Test-Path -LiteralPath $vc)) { Write-Host "[ERRO] VeraCrypt nao encontrado em $pasta"; Pausa; exit 1 }

# Letras de rede do USUARIO: a sessao elevada nao as ve. Lidas aqui, antes de elevar, e passadas adiante.
function Letras-Usuario {
    $l = @()
    try { $l += Get-ChildItem HKCU:\Network -ErrorAction Stop | ForEach-Object { $_.PSChildName } } catch {}
    try { $l += Get-SmbMapping -ErrorAction Stop | ForEach-Object { $_.LocalPath } } catch {}
    $l += [IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name }
    ($l | ForEach-Object { "$_".Substring(0, 1).ToUpperInvariant() } | Where-Object { $_ -match "^[A-Z]$" } | Select-Object -Unique) -join ","
}
# Dispositivo por tras de uma letra (\Device\VeraCryptVolumeX quando e cofre montado).
Add-Type -Namespace Cofre -Name K32 -MemberDefinition '[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern uint QueryDosDevice(string d, System.Text.StringBuilder t, uint m);'
function E-VeraCrypt([string]$letra) {
    $sb = New-Object System.Text.StringBuilder 1024
    if ([Cofre.K32]::QueryDosDevice("$($letra):", $sb, 1024) -eq 0) { return $false }
    return ($sb.ToString() -match "VeraCrypt")
}

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    Write-Host "O cofre usa o VeraCrypt, que precisa de permissao de ADMINISTRADOR"
    Write-Host "para carregar o driver de criptografia neste PC."
    Write-Host "O Windows vai perguntar (UAC). Se este PC nao for seu e voce nao tiver"
    Write-Host "a senha de administrador, o cofre nao abre aqui."
    Write-Host ""
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Ocupadas $(Letras-Usuario)"
    } catch {
        Write-Host "[AVISO] Permissao recusada. Cofre nao aberto."
        Pausa
    }
    exit 0
}

# Cofre ja aberto? Entao fecha.
if (Test-Path -LiteralPath $marca) {
    $letra = ((Get-Content -LiteralPath $marca -Raw) -replace '[^A-Za-z]', '').ToUpperInvariant()
    if ($letra.Length -eq 1 -and (E-VeraCrypt $letra)) {
        Write-Host "Fechando o cofre ($($letra):)... feche antes os arquivos abertos dele."
        $p = Start-Process -FilePath $vc -ArgumentList "/dismount $letra /quit /silent" -PassThru -Wait
        if (Test-Path "$($letra):\") {
            Write-Host "[AVISO] Nao fechou: algum arquivo do cofre ainda esta aberto. Feche e rode de novo."
            Pausa; exit 1
        }
        Remove-Item -LiteralPath $marca -Force
        Write-Host "[OK] Cofre fechado. Pode tirar o pendrive."
        Start-Sleep -Seconds 3
        exit 0
    }
    # Marca velha (pendrive tirado com o cofre aberto, ou outro PC): a letra nao e cofre montado aqui.
    Remove-Item -LiteralPath $marca -Force
}

if (-not (Test-Path -LiteralPath $cofre)) {
    Write-Host "Ainda nao existe o cofre pessoal: $cofre"
    Write-Host ""
    Write-Host "Vai abrir o assistente do VeraCrypt. Nele escolha:"
    Write-Host "  1. 'Criar um conteiner de arquivo criptografado' -> Volume padrao"
    Write-Host "  2. Arquivo: $cofre   (exatamente este nome, na raiz do pendrive)"
    Write-Host "  3. AES / SHA-512 (padrao) e o tamanho que quiser (ex.: 2 GB)"
    Write-Host "  4. Uma senha LONGA que so voce sabe. Sem ela, NINGUEM recupera os arquivos."
    Write-Host "     Guarde a senha no KeePassXC ou num papel em lugar seguro."
    Write-Host "  5. Sistema de arquivos: exFAT (arquivos grandes, abre em qualquer Windows)."
    Write-Host "Depois de criar, rode COFRE.cmd de novo para abrir."
    Start-Process -FilePath $vcFormat
    Pausa; exit 0
}

$usadas = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $_.Name.Substring(0, 1).ToUpperInvariant() }) + @($Ocupadas -split "," | Where-Object { $_ })
$letra = [char[]](80..90) + [char[]](71..79) | ForEach-Object { [string]$_ } | Where-Object { $usadas -notcontains $_ } | Select-Object -First 1
if (-not $letra) { Write-Host "[ERRO] Nenhuma letra de unidade livre."; Pausa; exit 1 }

Write-Host "Abrindo o cofre na unidade $($letra):  - digite a senha na janela do VeraCrypt."
$p = Start-Process -FilePath $vc -ArgumentList "/volume `"$cofre`" /letter $letra /explore /quit" -PassThru -Wait
if (Test-Path "$($letra):\") {
    Set-Content -LiteralPath $marca -Value $letra -Encoding ascii
    Write-Host "[OK] Cofre aberto em $($letra):  Para fechar, rode COFRE.cmd de novo."
    Write-Host "     NUNCA tire o pendrive com o cofre aberto."
    Start-Sleep -Seconds 4
} else {
    Write-Host "[AVISO] O cofre nao foi aberto (senha errada ou cancelado)."
    Pausa
}
