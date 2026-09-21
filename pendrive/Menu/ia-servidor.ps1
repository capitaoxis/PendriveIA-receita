# Servidor de IA local compativel com OpenAI, para plugar editores (VS Code + Continue, aider).
#   IA-SERVIDOR.cmd               -> modelo de codigo, porta 11480
#   IA-SERVIDOR.cmd -m normal     -> outro modelo (normal|leve|grande|codigo30|codigo14|codigo7|codigo3|saude)
#   IA-SERVIDOR.cmd -m autocompletar -> modelo pequeno p/ o Tab do VS Code, porta 11481
#   IA-SERVIDOR.cmd -NovaChave    -> gera outra chave (a antiga para de funcionar)
# So escuta em 127.0.0.1 (ninguem da rede acessa). Fica aberto ate Ctrl+C ou fechar a janela.
# A chave fica em Menu\ia-servidor.chave (dentro do pendrive) e vai ao llama-server por
# variavel de ambiente, nunca na linha de comando do processo.
[CmdletBinding(PositionalBinding = $false)]
param([string]$m = "codigo", [int]$Porta = 11480, [int]$Contexto = 32768, [switch]$NovaChave)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$raiz = Split-Path $PSScriptRoot -Parent
$app = Join-Path $raiz "Studio\app"
$diag = & (Join-Path $PSScriptRoot "menu.ps1") -Diagnostico | Out-String | ConvertFrom-Json
. (Join-Path $PSScriptRoot "codar-modelo.ps1")
$pastaModelos = Join-Path $app "llm-models"
$arquivos = @{
    normal   = $diag.ModeloChat
    leve     = "unsloth--Qwen3-1.7B-GGUF--Qwen3-1.7B-Q4_K_M.gguf"
    grande   = "unsloth--Qwen3-14B-GGUF--Qwen3-14B-Q4_K_M.gguf"
    saude    = "unsloth--medgemma-1.5-4b-it-GGUF--medgemma-1.5-4b-it-Q4_K_M.gguf"
    autocompletar = $CodarModelos.codigo1      # FIM para o Tab do VS Code (porta 11481)
}
foreach ($k in $CodarModelos.Keys) { $arquivos[$k] = $CodarModelos[$k] }
if ($m -eq "autocompletar") {
    if (-not $PSBoundParameters.ContainsKey('Porta')) { $Porta = 11481 }
    if (-not $PSBoundParameters.ContainsKey('Contexto')) { $Contexto = 4096 }
}
if ($m -eq "codigo") {   # escolha automatica pelo hardware (codar-modelo.ps1)
    $esc = Get-ModeloCodigo $diag $pastaModelos
    if (-not $esc) { Write-Host "Nenhum modelo de codigo neste pendrive."; exit 1 }
    $arquivos.codigo = $esc.Arquivo
    if (-not $PSBoundParameters.ContainsKey('Contexto')) { $Contexto = $esc.Ctx }
    Write-Host "[codigo -> $($esc.Chave) escolhido pelo hardware]" -ForegroundColor DarkGray
}
if (-not $arquivos.ContainsKey($m)) { Write-Host "Modelos: $($arquivos.Keys -join ', ')"; exit 1 }
$modelo = Get-ChildItem $pastaModelos -Recurse -Filter $arquivos[$m] -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $modelo) { Write-Host "Modelo '$m' ($($arquivos[$m])) nao esta neste pendrive."; exit 1 }

$backend = if ($diag.Backend) { $diag.Backend } else { "cpu" }
$server = Join-Path $app "llm-backend\win\$backend\llama-server.exe"
if (-not (Test-Path $server)) { $server = Join-Path $app "llm-backend\win\cpu\llama-server.exe"; $backend = "cpu" }

# porta fixa: se ja tem alguem nela, avisa em vez de brigar
try { $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Porta); $l.Start(); $l.Stop() }
catch { Write-Host "A porta $Porta ja esta em uso (outro IA-SERVIDOR aberto?). Feche-o ou use -Porta 11481." -ForegroundColor Yellow; exit 1 }

# chave persistente (o editor e configurado uma vez so)
$arqChave = Join-Path $PSScriptRoot "ia-servidor.chave"
if ($NovaChave -or -not (Test-Path $arqChave)) {
    $b = New-Object byte[] 24; [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
    $novo = "pendrive-" + (($b | ForEach-Object { $_.ToString("x2") }) -join "")
    [IO.File]::WriteAllText($arqChave, $novo)
}
$chave = ([IO.File]::ReadAllText($arqChave)).Trim()
$env:LLAMA_API_KEY = $chave          # nome que ESTE llama-server le (o --help diz "env: LLAMA_API_KEY")
$env:LLAMA_ARG_API_KEY = $chave      # nome antigo, por via das duvidas
$env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
$log = Join-Path $env:TEMP "ia-servidor-pendrive.log"

# Job Object com KILL_ON_JOB_CLOSE: quando este PowerShell morre (Ctrl+C, X da janela),
# o Windows fecha o handle do job e mata o llama-server junto. Sem isso ele ficava orfao na placa.
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class PendriveJob {
  [StructLayout(LayoutKind.Sequential)] struct BASIC { public long a; public long b; public uint LimitFlags; public UIntPtr c; public UIntPtr d; public uint e; public UIntPtr f; public uint g; public uint h; }
  [StructLayout(LayoutKind.Sequential)] struct IOC { public ulong a,b,c,d,e,f; }
  [StructLayout(LayoutKind.Sequential)] struct EXT { public BASIC Basic; public IOC Io; public UIntPtr p1, p2, p3, p4; }
  [DllImport("kernel32.dll")] static extern IntPtr CreateJobObject(IntPtr a, string n);
  [DllImport("kernel32.dll")] static extern bool SetInformationJobObject(IntPtr j, int c, ref EXT i, int l);
  [DllImport("kernel32.dll")] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
  static IntPtr job = IntPtr.Zero;
  public static bool Prender(IntPtr proc) {
    if (job == IntPtr.Zero) { job = CreateJobObject(IntPtr.Zero, null); var e = new EXT(); e.Basic.LimitFlags = 0x2000;
      SetInformationJobObject(job, 9, ref e, Marshal.SizeOf(typeof(EXT))); }
    return AssignProcessToJobObject(job, proc);
  }
}
"@

function Subir([string]$camadas, [int]$ctx) {
    $a = @("-m", "`"$($modelo.FullName)`"", "--host", "127.0.0.1", "--port", $Porta, "-c", $ctx, "--jinja", "--alias", $m, "-np", "1")
    if ($backend -ne "cpu") { $a += @("-ngl", $camadas) }
    if ($modelo.FullName -notlike "C:*") { $a += "--no-mmap" }
    if ($m -eq "saude") { $a += "--special" }
    $p = Start-Process $server -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardError $log -RedirectStandardOutput "$log.out"
    [void][PendriveJob]::Prender($p.Handle)   # fechar a janela no X tambem derruba o llama-server
    for ($i = 0; $i -lt 1800; $i++) {   # ate 15 min: disco do pendrive pode estar lento; so troca de plano se o processo MORRER
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { return $null }
        try { if ((Invoke-RestMethod "http://127.0.0.1:$Porta/health" -TimeoutSec 2).status -eq "ok") { return $p } } catch {}
    }
    Stop-Process $p -Force -ErrorAction SilentlyContinue; return $null
}

Write-Host "[$m | $backend | carregando $($modelo.Name)...]" -ForegroundColor DarkGray
$proc = $null; $ctxUsado = 0; $camUsadas = ""
foreach ($t in @(@("99", $Contexto), @("99", 16384), @("20", 16384), @("20", 8192))) {
    if ($backend -eq "cpu" -and $t[0] -eq "20") { continue }
    $proc = Subir $t[0] $t[1]
    if ($proc) { $ctxUsado = $t[1]; $camUsadas = $t[0]; break }
    Write-Host "[nao coube com contexto $($t[1]) e -ngl $($t[0]); tentando menor]" -ForegroundColor DarkGray
}
if (-not $proc) { Write-Host "Falhou ao subir o modelo. Log: $log"; exit 1 }

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   SERVIDOR DE IA LIGADO (so neste computador, sem internet)" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   apiBase : http://127.0.0.1:$Porta/v1"
Write-Host "   model   : $m"
Write-Host "   apiKey  : $chave" -ForegroundColor Yellow
Write-Host "   contexto: $ctxUsado tokens   placa: $backend (-ngl $camUsadas)"
Write-Host "   Configuracao do VS Code/Continue e do aider: CODAR.md"
Write-Host "   Para desligar: Ctrl+C ou feche esta janela." -ForegroundColor DarkGray
Write-Host ""
try {
    while (-not $proc.HasExited) { Start-Sleep -Seconds 1 }
    Write-Host "O servidor parou sozinho. Log: $log" -ForegroundColor Yellow
} finally {
    if (-not $proc.HasExited) { Stop-Process $proc -Force -ErrorAction SilentlyContinue }
    Remove-Item Env:LLAMA_API_KEY, Env:LLAMA_ARG_API_KEY -ErrorAction SilentlyContinue
    Write-Host "Servidor desligado." -ForegroundColor DarkGray
}
