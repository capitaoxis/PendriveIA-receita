# Busca nos livros do pendrive.
#   livros-busca.ps1 "pergunta"      -> 6 trechos [Titulo — Autor] trecho
#   livros-busca.ps1 -Indexar        -> indexa em segundo plano (log em Livros\indice\indexar.log)
param([Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Pergunta, [switch]$Indexar, [int]$MaxTrechos = 0)
$raiz = Split-Path $PSScriptRoot -Parent
$py = Join-Path $raiz 'Python\python312\python.exe'
$scr = Join-Path $PSScriptRoot 'livros-busca.py'
if ($Indexar) {
    $pasta = Join-Path $raiz 'Livros\indice'
    New-Item -ItemType Directory -Force $pasta | Out-Null
    $log = Join-Path $pasta 'indexar.log'
    $extra = ''; if ($MaxTrechos -gt 0) { $extra = " --max-trechos $MaxTrechos" }
    # cmd /c com aspas: caminho tem espaco; saida vai para o log
    $cmd = "/c `"`"$py`" -u `"$scr`" --indexar$extra > `"$log`" 2>&1`""
    if (Get-CimInstance Win32_Process -Filter "Name='python.exe'" | ? { $_.CommandLine -like '*livros-busca.py*--indexar*' }) {
        Write-Host 'Ja existe uma indexacao rodando.'; return
    }
    # Win32_Process.Create: sobrevive ao fechamento do terminal/sessao que chamou
    $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe $cmd"; ProcessStartupInformation = $si }
    Write-Host "Indexando em segundo plano (PID $($r.ProcessId)). Acompanhe: Get-Content '$log' -Wait"
    Write-Host "O resumo final aparece na linha 'RESUMO:' do log."
    return
}
$env:PYTHONIOENCODING = 'utf-8'
& $py $scr ($Pergunta -join ' ')
