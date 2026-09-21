# Pendrive: encerra o llama-server que o preparar.ps1 subiu para os documentos e a voz Piper.
# So mexe em llama-server.exe de dentro de Studio\app\llm-backend e na porta 10090, e no
# python.exe do pendrive que roda voz.py (fala e microfone).
# -SeAppFechado: nao desliga se ainda houver AnythingLLM do pendrive aberto. Abrir o
# Documentos.bat com o app ja aberto (inclusive escondido na bandeja) inicia uma segunda
# copia que fecha na hora; sem esta checagem o modelo do app aberto era desligado.
# -ManterVoz: desliga so o modelo (a voz roda no processador e nao ocupa a placa de video).
param([switch]$SeAppFechado, [switch]$ManterVoz)

$allm = Split-Path -Parent $PSScriptRoot

if ($SeAppFechado) {
    $appDir = (Join-Path $allm "app").TrimEnd('\') + '\'
    $aberto = Get-CimInstance Win32_Process -Filter "Name='AnythingLLM.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($appDir, [StringComparison]::OrdinalIgnoreCase) }
    if ($aberto) {
        Write-Host "AnythingLLM continua aberto; o modelo fica ligado."
        exit 0
    }
}

$backendRoot = (Join-Path (Split-Path -Parent $allm) "Studio\app\llm-backend").TrimEnd('\') + '\'
Get-CimInstance Win32_Process -Filter "Name='llama-server.exe'" |
    Where-Object {
        $_.ExecutablePath -and
        $_.ExecutablePath.StartsWith($backendRoot, [StringComparison]::OrdinalIgnoreCase) -and
        $_.CommandLine -match '--port\s+10090\b'
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (-not $ManterVoz) {
    $pythonRoot = (Join-Path (Split-Path -Parent $allm) "Python").TrimEnd('\') + '\'
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith($pythonRoot, [StringComparison]::OrdinalIgnoreCase) -and
            $_.CommandLine -match 'voz(-piper)?\.py'
        } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
