<#
  instalar-pendrive.ps1 - copia o PendriveIA para OUTRO pendrive (NTFS), recria as
  juncoes do JASP, confere SHA-256 dos arquivos > 50 MB e gera relatorio.

  NUNCA formata, particiona nem grava em disco que o usuario nao confirmou.

  Uso:
    INSTALAR-EM-OUTRO.cmd                         (pergunta tudo)
    instalar-pendrive.ps1 -Perfil enxuto -Destino X:
    instalar-pendrive.ps1 -Perfil completo -Destino X: -Simular   (so lista e soma)
  Teste (so para desenvolvimento): -Teste -Destino <pasta dentro do %TEMP%> [-SoPastas Menu,Testes]
#>
param(
  [ValidateSet('completo','enxuto')][string]$Perfil = '',
  [string]$Destino = '',
  [switch]$Simular,
  [switch]$Teste,
  [string[]]$SoPastas = @()
)
$ErrorActionPreference = 'Stop'
$Origem = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path.TrimEnd('\')
$inicio = Get-Date
$rel = New-Object System.Collections.Generic.List[string]
function Diz($t, $cor = 'Gray') { Write-Host $t -ForegroundColor $cor; $rel.Add($t) }
function Para($t) { Diz "PAREI: $t" 'Red'; exit 1 }

# ---------- perfis ----------
# Enxuto: cabe num pendrive de 64 GB (~58 GiB uteis). Fica de fora:
$foraArquivos = @(
  '*14B*.gguf', '*30B*.gguf', '*Coder*',             # modelos grandes e de codigo (inclui .parcial)
  'wikipedia_en_*.zim',                              # Wikipedia em ingles (49 GB) e recorte medicina EN
  'mdwiki_*.zim', 'wikisource_*.zim', '*stackoverflow*.zim'   # acervos medios (5 GB)
)
$foraPastas = @(
  (Join-Path $Origem 'Ferramentas\Calibre Portable\Calibre Library')  # livros (opcional)
)
$sempreFora = @('System Volume Information', '$RECYCLE.BIN')

Diz "=== Instalar o PendriveIA em outro pendrive ===" 'Cyan'
Diz "Origem: $Origem"
if (-not $Perfil) {
  Write-Host "Perfil: [1] completo (pendrive de 128 GB)   [2] enxuto (pendrive de 64 GB)"
  $r = Read-Host 'Escolha 1 ou 2'
  $Perfil = if ($r -eq '2') { 'enxuto' } elseif ($r -eq '1') { 'completo' } else { Para 'perfil nao escolhido' }
}
Diz "Perfil: $Perfil"

# ---------- destino ----------
$discoOrigem = (Get-Partition -DriveLetter $Origem.Substring(0,1) | Get-Disk).Number
if ($Teste) {
  if (-not $Destino) { Para 'no modo -Teste informe -Destino (pasta no %TEMP%)' }
  $tmp = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')
  $Destino = [IO.Path]::GetFullPath($Destino).TrimEnd('\')
  if (-not $Destino.StartsWith($tmp + '\', 'OrdinalIgnoreCase')) { Para "no modo -Teste o destino precisa estar dentro de $tmp" }
  New-Item -ItemType Directory -Force $Destino | Out-Null
  $letra = $Destino.Substring(0,1)
  Diz "MODO TESTE: destino e a pasta $Destino (nenhum disco e tocado)" 'Yellow'
} else {
  Diz ''
  Diz 'Discos USB neste PC:'
  $usb = @(Get-Disk | Where-Object BusType -eq 'USB')
  if (-not $usb) { Para 'nenhum disco USB encontrado' }
  foreach ($d in $usb) {
    $vols = @($d | Get-Partition | Where-Object DriveLetter | ForEach-Object { $v = Get-Volume -DriveLetter $_.DriveLetter; "$($_.DriveLetter): $($v.FileSystem) $([math]::Round($v.Size/1GB,1)) GB" })
    $marca = if ($d.Number -eq $discoOrigem) { '  <- ORIGEM (este pendrive)' } else { '' }
    Diz ("  Disco {0}: {1}  {2:N1} GB  [{3}]{4}" -f $d.Number, $d.FriendlyName, ($d.Size/1GB), ($vols -join '; '), $marca)
  }
  if (-not $Destino) { $Destino = Read-Host 'Digite a LETRA do pendrive de destino (ex.: F)' }
  $letra = $Destino.Trim().TrimEnd(':','\').ToUpper()
  if ($letra -notmatch '^[A-Z]$') { Para "letra invalida: $Destino" }
  $part = Get-Partition -DriveLetter $letra -ErrorAction SilentlyContinue
  if (-not $part) { Para "nao existe unidade $letra`:" }
  $disco = $part | Get-Disk
  if ($disco.Number -eq $discoOrigem) { Para "$letra`: esta no mesmo disco da origem" }
  if ($disco.BusType -ne 'USB') { Para "$letra`: nao e USB (e $($disco.BusType)); recuso" }
  $n = Read-Host "Confirme o NUMERO do disco de $letra`: ($($disco.FriendlyName), $([math]::Round($disco.Size/1GB,1)) GB)"
  if ($n.Trim() -ne "$($disco.Number)") { Para 'numero nao confere; nada foi feito' }
  $Destino = "$letra`:\"
}
$vol = Get-Volume -DriveLetter $letra
if ($vol.FileSystem -ne 'NTFS') {
  Diz "O destino esta em $($vol.FileSystem), precisa ser NTFS (o JASP usa 6.067 juncoes; exFAT/FAT32 nao aceitam)." 'Red'
  Diz 'Como resolver (VOCE faz, apaga o pendrive): Ventoy2Disk -> Opcao -> Filesystem NTFS -> Install;'
  Diz "  ou, sem Ventoy: Format-Volume -DriveLetter $letra -FileSystem NTFS -NewFileSystemLabel PENDRIVE-IA"
  exit 1
}

# ---------- capacidade real ----------
if (-not $Teste -and -not $Simular) {
  Diz ''
  Diz 'ANTES: pendrive falso ("General UDisk 244 GB") ja passou pela formatacao e corrompeu.' 'Yellow'
  Diz '  Teste a capacidade com o ValiDrive (https://www.grc.com/validrive.htm); confira que o .exe'
  Diz '  e assinado por "Gibson Research Corporation" (botao direito > Propriedades > Assinaturas).'
  if ((Read-Host 'O ValiDrive aprovou este pendrive? (S/N)') -notmatch '^[sS]') { Para 'teste de capacidade nao confirmado' }
  Diz 'Capacidade confirmada pelo usuario (ValiDrive).'
}

# ---------- robocopy ----------
function Args-Robocopy($de, $para, [switch]$Lista) {
  $a = @($de, $para, '/E', '/XJ', '/DCOPY:T', '/COPY:DT', '/R:2', '/W:5', '/MT:8', '/NP', '/NJH', '/NDL', '/NC', '/BYTES', '/FP')
  if ($Lista) { $a += '/L' }
  $xd = @($sempreFora); $xf = @()
  if ($Perfil -eq 'enxuto') { $xd += $foraPastas; $xf += $foraArquivos }
  $a += '/XD'; $a += $xd
  if ($xf) { $a += '/XF'; $a += $xf }
  $a
}
$SoPastas = @($SoPastas | ForEach-Object { $_ -split ',' } | Where-Object { $_ })   # powershell -File entrega "a,b" como 1 texto
$pares = New-Object System.Collections.Generic.List[object]   # lista explicita: 'if' desembrulharia o par
if ($SoPastas) { foreach ($s in $SoPastas) { $pares.Add(@((Join-Path $Origem $s), (Join-Path $Destino $s))) } }
else { $pares.Add(@($Origem, $Destino)) }

function Soma-Lista {
  $bytes = 0L; $qtd = 0; $grandes = New-Object System.Collections.Generic.List[string]
  $arquivos = New-Object System.Collections.Generic.List[object]   # (caminho na origem, bytes) para a conferencia final
  foreach ($p in $pares) {
    # lista contra destino inexistente: senao arquivo ja copiado some do plano e escapa da conferencia
    $saida = & robocopy @(Args-Robocopy $p[0] (Join-Path $env:TEMP 'instalar-pendrive-NAO-EXISTE') -Lista)
    foreach ($l in $saida) {
      if ($l -match '^\s+(\d+)\s+([A-Za-z]:\\.+)$') {
        $b = [int64]$Matches[1]; $bytes += $b; $qtd++
        $arquivos.Add(@($Matches[2], $b))
        if ($b -gt 50MB) { $grandes.Add($Matches[2]) }
      }
    }
  }
  [pscustomobject]@{ Bytes = $bytes; Qtd = $qtd; Grandes = $grandes; Arquivos = $arquivos }
}

Diz ''
Diz 'Somando o que sera copiado (robocopy /L, nada e gravado)...'
$plano = Soma-Lista
Diz ("Perfil {0}: {1:N0} arquivos, {2:N2} GiB ({3:N1} GB), {4} arquivos > 50 MB" -f $Perfil, $plano.Qtd, ($plano.Bytes/1GB), ($plano.Bytes/1e9), $plano.Grandes.Count) 'Cyan'
$livre = $vol.SizeRemaining
Diz ("Livre no destino: {0:N2} GiB" -f ($livre/1GB))
if ($Simular) {
  $top = $plano.Grandes | ForEach-Object { Get-Item -LiteralPath $_ } | Sort-Object Length -Descending | Select-Object -First 15
  Diz 'Maiores arquivos do perfil:'
  foreach ($f in $top) { Diz ("  {0,7:N2} GiB  {1}" -f ($f.Length/1GB), $f.FullName.Substring($Origem.Length)) }
  Diz 'SIMULACAO: nada foi copiado.' 'Green'
  exit 0
}
if ($plano.Bytes + 512MB -gt $livre) { Para ("falta espaco: precisa {0:N2} GiB, livre {1:N2} GiB" -f ($plano.Bytes/1GB), ($livre/1GB)) }

if (-not $Teste) {
  if ((Read-Host "Copiar $([math]::Round($plano.Bytes/1GB,1)) GiB para $Destino ? (S/N)") -notmatch '^[sS]') { Para 'cancelado pelo usuario' }
}

# ---------- copia ----------
$log = Join-Path $Destino ("instalar-pendrive-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Diz "Copiando... (log: $log)"
$t0 = Get-Date
foreach ($p in $pares) {
  & robocopy @(Args-Robocopy $p[0] $p[1]) "/LOG+:$log" /NFL | Out-Null
  if ($LASTEXITCODE -ge 8) { Para "robocopy saiu com codigo $LASTEXITCODE (ver $log)" }
}
$seg = ((Get-Date) - $t0).TotalSeconds
Diz ("Copia terminada em {0:N0} s ({1:N1} MB/s)" -f $seg, ($plano.Bytes/1MB/[math]::Max($seg,1))) 'Green'

# ---------- juncoes do JASP ----------
$jt = Join-Path $Destino 'Ferramentas\JASP\JunctionTool.exe'
if (Test-Path $jt) {
  $mods = Join-Path $Destino 'Ferramentas\JASP\Modules'
  $out = & $jt -c (Join-Path $Destino 'Ferramentas\JASP\junctions_map.txt') $mods $mods 2>&1 | Out-String
  $ok = if ($out -match 'Success:\s*(\d+)') { [int]$Matches[1] } else { 0 }
  Diz "Juncoes do JASP recriadas: $ok (esperado 6067; 2-3 falhas em Tools/modules-settings.json sao inofensivas)" $(if ($ok -ge 6067) { 'Green' } else { 'Red' })
} else { Diz 'JASP nao faz parte desta copia: juncoes nao se aplicam.' }

# ---------- conferencia ----------
$ruins = 0
Diz "Conferindo SHA-256 de $($plano.Grandes.Count) arquivos > 50 MB..."
foreach ($f in $plano.Grandes) {
  $rel_ = $f.Substring($Origem.Length).TrimStart('\')
  $d = Join-Path $Destino $rel_
  $ha = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
  $hb = if (Test-Path -LiteralPath $d) { (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash } else { 'FALTANDO' }
  if ($ha -ne $hb) { $ruins++; Diz "  DIFERENTE: $rel_" 'Red' } else { $rel.Add("  ok $ha  $rel_") }
}
# So os arquivos do PLANO: somar o destino inteiro deixaria sobra antiga cobrir arquivo faltando.
$contaDest = 0; $bytesDest = 0L; $faltam = 0
foreach ($a in $plano.Arquivos) {
  $d = Join-Path $Destino ($a[0].Substring($Origem.Length).TrimStart('\'))
  $fi = Get-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue
  if ($fi -and $fi.Length -eq $a[1]) { $contaDest++; $bytesDest += $fi.Length }
  else { $faltam++; if ($faltam -le 20) { Diz "  FALTANDO/TAMANHO DIFERENTE: $($a[0].Substring($Origem.Length))" 'Red' } }
}
Diz ("Destino (arquivos do plano): {0:N0} arquivos, {1:N0} bytes | plano: {2:N0} arquivos, {3:N0} bytes" -f $contaDest, $bytesDest, $plano.Qtd, $plano.Bytes)
if ($ruins -gt 0 -or $faltam -gt 0 -or $contaDest -ne $plano.Qtd -or $bytesDest -ne $plano.Bytes) { Diz "RESULTADO: FALHOU ($ruins arquivos grandes diferentes, $faltam faltando ou com tamanho diferente). Nao use este pendrive; pode ser falso." 'Red'; $fim = 1 }
else { Diz 'RESULTADO: OK. Proximo passo: rodar Menu\conferir-pendrive.ps1 -Gerar NO destino.' 'Green'; $fim = 0 }

$arq = Join-Path $Destino ("relatorio-instalacao-{0:yyyyMMdd-HHmmss}.txt" -f $inicio)
$rel | Set-Content -LiteralPath $arq -Encoding UTF8
Write-Host "Relatorio: $arq"
exit $fim
