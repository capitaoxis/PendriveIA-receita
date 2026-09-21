# Monta o pendrive de IA offline a partir da receita (fontes.tsv), conferindo hash de tudo.
#
#   powershell -ExecutionPolicy Bypass -File .\montar-pendrive.ps1 -Destino E:
#   ... -Somente modelo,acervo      so alguns grupos do fontes.tsv
#   ... -SemAcervos                 pula a Wikipedia (~76 GB)
#   ... -Conferir                   nao baixa nada: confere o que ja esta la
#
# O que e AUTOMATICO: modelos, vozes, modelos de separar voz, acervos .zim e pacotes Python.
#   Todos tem hash publicado pela origem (Hugging Face e Kiwix), entao da para baixar e conferir sozinho.
# O que e SEMIAUTOMATICO: programas, motores e aplicativos (Calibre, NAPS2, LibreOffice, llama.cpp...).
#   O endereco do ARQUIVO muda a cada versao, e adivinhar da download errado ou desatualizado. O script
#   lista o que falta com a pagina oficial, voce baixa e joga em .\baixados\, e ele confere, extrai,
#   anota o SHA-256 em hashes-obtidos.tsv e segue. Rodar de novo continua de onde parou.
param(
  [Parameter(Mandatory = $true)][string]$Destino,
  [string[]]$Somente = @(),
  [switch]$SemAcervos,
  [switch]$Conferir
)
$ErrorActionPreference = "Stop"
$receita = $PSScriptRoot
$curl = Join-Path $env:WINDIR "System32\curl.exe"
if (-not (Test-Path $curl)) { throw "curl.exe nao encontrado (Windows 10 1803+ tem de fabrica)" }
$Destino = $Destino.TrimEnd('\')
if ($Destino -match '^[A-Za-z]:$') { $Destino = "$Destino\" }
$raiz = Join-Path $Destino "IA"
$baixados = Join-Path $receita "baixados"
$registro = Join-Path $receita "hashes-obtidos.tsv"
New-Item -ItemType Directory -Force $baixados | Out-Null

function Anota($t, $cor = "Gray") { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm), $t) -ForegroundColor $cor }

# ---------- conferencias de disco ----------
$vol = Get-Volume -DriveLetter $Destino[0] -ErrorAction SilentlyContinue
if (-not $vol) { throw "disco $Destino nao encontrado" }
if ($vol.FileSystem -ne "NTFS") {
  throw "o disco esta em $($vol.FileSystem): precisa ser NTFS (arquivo de modelo passa de 4 GB, o que FAT32 nao aceita)"
}
$livreGB = [math]::Round($vol.SizeRemaining / 1GB, 1)
Anota "destino $Destino ($($vol.FileSystem), $livreGB GB livres)"

# ---------- le a receita ----------
$linhas = @(Get-Content -LiteralPath (Join-Path $receita "fontes.tsv") -Encoding UTF8 | Select-Object -Skip 1 |
            Where-Object { $_.Trim() } | ForEach-Object {
              $c = $_ -split "`t"
              [pscustomobject]@{ Grupo = $c[0]; Nome = $c[1]; Destino = $c[2]; Origem = $c[3]; Verificacao = $c[4]; Tamanho = $c[5]; Licenca = $c[6] }
            })
$linhas = @($linhas | Where-Object { $_.Grupo -notlike "NAO-DISTRIBUIVEL*" })
if ($SemAcervos) { $linhas = @($linhas | Where-Object { $_.Grupo -ne "acervo" }) }
$Somente = @($Somente | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Somente.Count -gt 0) { $linhas = @($linhas | Where-Object { $Somente -contains $_.Grupo }) }
Anota "$($linhas.Count) itens na receita"

function Hash256($arquivo) { (Get-FileHash -Algorithm SHA256 -LiteralPath $arquivo).Hash.ToLowerInvariant() }

function RegistraHash($nome, $arquivo) {
  if (-not (Test-Path -LiteralPath $registro)) {
    Set-Content -LiteralPath $registro -Value "nome`tarquivo`tsha256`tbytes`tdata" -Encoding UTF8
  }
  $h = Hash256 $arquivo
  Add-Content -LiteralPath $registro -Encoding UTF8 -Value ("{0}`t{1}`t{2}`t{3}`t{4}" -f `
    $nome, (Split-Path $arquivo -Leaf), $h, (Get-Item -LiteralPath $arquivo).Length, (Get-Date -Format "yyyy-MM-dd HH:mm"))
  return $h
}

# ---------- Hugging Face: hash publicado na API ----------
function HashDoHuggingFace($repo, $caminho) {
  # a API devolve, por arquivo, o sha256 do LFS; sem ele nao ha como conferir e o item e recusado
  $t = (& $curl -sSL "https://huggingface.co/api/models/$repo/tree/main?recursive=true") -join ""
  if (-not $t) { return $null }
  foreach ($item in ($t | ConvertFrom-Json)) {
    if ($item.path -eq $caminho -and $item.lfs -and $item.lfs.oid) { return $item.lfs.oid.ToLowerInvariant() }
  }
  return $null
}

function BaixaConferindo($url, $arquivo, $esperado, $nome) {
  $parcial = "$arquivo.parcial"
  if ((Test-Path -LiteralPath $arquivo) -and $esperado -and (Hash256 $arquivo) -eq $esperado) {
    Anota "${nome}: ja esta la e conferido" "DarkGray"; return $true
  }
  New-Item -ItemType Directory -Force (Split-Path $arquivo) | Out-Null
  Anota "${nome}: baixando..."
  & $curl -fL --retry 5 -C - -o $parcial $url
  if ($LASTEXITCODE -ne 0 -and -not (Test-Path -LiteralPath $parcial)) { Anota "${nome}: FALHOU o download" "Red"; return $false }
  if ($esperado) {
    $obtido = Hash256 $parcial
    if ($obtido -ne $esperado) {
      Anota "${nome}: HASH DIFERENTE (esperado $esperado, obtido $obtido) - apagando" "Red"
      Remove-Item -LiteralPath $parcial -Force; return $false
    }
  }
  Move-Item -LiteralPath $parcial -Destination $arquivo -Force
  Anota "${nome}: OK, conferido" "Green"
  return $true
}

$ok = 0; $falhou = 0; $manual = @()

foreach ($item in $linhas) {
  $pastaDestino = Join-Path $raiz $item.Destino
  switch -Wildcard ($item.Verificacao) {

    "hf-api-sha256" {
      if ($Conferir) { continue }
      # origem: hf:<repo>/<caminho/dentro/do/repo>
      $resto = $item.Origem.Substring(3)
      $partes = $resto -split "/"
      $repo = ($partes[0..1] -join "/")
      $caminho = ($partes[2..($partes.Count - 1)] -join "/")
      $esperado = HashDoHuggingFace $repo $caminho
      if (-not $esperado) { Anota "$($item.Nome): a API do Hugging Face nao deu o sha256; PULANDO (confira a mao)" "Yellow"; $falhou++; continue }
      $arquivo = Join-Path $pastaDestino (Split-Path $caminho -Leaf)
      if (BaixaConferindo "https://huggingface.co/$repo/resolve/main/$caminho" $arquivo $esperado $item.Nome) { $ok++ } else { $falhou++ }
    }

    "kiwix-sha256" {
      if ($Conferir) { continue }
      Anota "$($item.Nome): acervos sao baixados pelo script do proprio pendrive (Kiwix\baixar-zims.ps1), que pega a versao mais nova e confere o .sha256" "DarkGray"
      $manual += "acervo $($item.Nome): rodar depois  powershell -File $raiz\Kiwix\baixar-zims.ps1"
    }

    "sha256-fixo*" {
      if ($Conferir) { continue }
      # verificacao = sha256-fixo:<hash do arquivo que importa>[:<nome dentro do pacote>]
      # O GitHub nao publica hash de release, entao o hash aqui foi medido numa copia que funcionou
      # (20/09/2026) e esta fixado: se a origem mudar o arquivo, o download e recusado.
      $p = $item.Verificacao -split ":"
      $esperado = $p[1]; $dentro = if ($p.Count -gt 2) { $p[2] } else { $null }
      # o destino pode trazer o NOME FINAL do arquivo (no pendrive o modelo de voz se chama voz.onnx,
      # nao o nome comprido da origem): sem isso o instalador baixava de novo o que ja estava la
      if ([IO.Path]::GetExtension($item.Destino)) {
        $arquivo = $pastaDestino
        $pastaDestino = Split-Path $arquivo -Parent
      } else {
        $arquivo = Join-Path $pastaDestino (Split-Path $item.Origem -Leaf)
      }
      if ($dentro) {
        # pacote: confere o hash do arquivo que importa DEPOIS de extrair
        $jaTem = Get-ChildItem -LiteralPath $pastaDestino -Recurse -Filter $dentro -ErrorAction SilentlyContinue |
                 Where-Object { (Hash256 $_.FullName) -eq $esperado } | Select-Object -First 1
        if ($jaTem) { Anota "$($item.Nome): ja esta la e conferido" "DarkGray"; $ok++; continue }
      }
      if (-not (BaixaConferindo $item.Origem $arquivo $(if ($dentro) { $null } else { $esperado }) $item.Nome)) { $falhou++; continue }
      if ($dentro) {
        $tar = Join-Path $env:WINDIR "System32	ar.exe"
        if (-not (Test-Path $tar)) { $manual += "$($item.Nome): extraia $arquivo em $pastaDestino"; continue }
        & $tar -xf $arquivo -C $pastaDestino
        $achou = Get-ChildItem -LiteralPath $pastaDestino -Recurse -Filter $dentro -ErrorAction SilentlyContinue |
                 Where-Object { (Hash256 $_.FullName) -eq $esperado } | Select-Object -First 1
        if ($achou) { Anota "$($item.Nome): extraido e conferido ($dentro)" "Green"; Remove-Item $arquivo -Force -EA SilentlyContinue; $ok++ }
        else { Anota "$($item.Nome): extraiu, mas o $dentro nao bateu com o hash esperado" "Red"; $falhou++ }
      } else { $ok++ }
    }

    "pip" {
      if ($Conferir) { continue }
      $py = Join-Path $raiz "Python\python312\python.exe"
      if (-not (Test-Path $py)) { $manual += "pacote-python: falta o Python embeddable ($($item.Destino))"; continue }
      & $py -m pip install --upgrade openzim-mcp sherpa-onnx mcp numpy piper-tts
      if ($LASTEXITCODE -eq 0) { $ok++ } else { $falhou++ }
    }

    default {
      # programas, motores e aplicativos: arquivo baixado a mao em .\baixados\
      $achado = @(Get-ChildItem -LiteralPath $baixados -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "*$(($item.Nome -split ' ')[0])*" })
      if ($achado.Count -eq 0) {
        $manual += "$($item.Grupo) $($item.Nome)  ->  baixe de $($item.Origem) e ponha em $baixados"
        continue
      }
      $arq = $achado[0].FullName
      $h = RegistraHash $item.Nome $arq
      Anota "$($item.Nome): achei $($achado[0].Name), sha256 $h (anotado em hashes-obtidos.tsv)" "Green"
      New-Item -ItemType Directory -Force $pastaDestino | Out-Null
      if ($arq -match '\.(zip|7z|tar\.bz2|tar\.gz)$') {
        $sevenzip = @("$raiz\Ferramentas\7-Zip\7z.exe", "$env:ProgramFiles\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($sevenzip) { & $sevenzip x -y -o"$pastaDestino" "$arq" | Out-Null; Anota "$($item.Nome): extraido em $pastaDestino" "Green"; $ok++ }
        else { $manual += "$($item.Nome): extraia $arq em $pastaDestino (sem 7-Zip ainda)" }
      } else {
        $manual += "$($item.Nome): e instalador/executavel - instale apontando para $pastaDestino"
      }
    }
  }
}

# ---------- nossos scripts ----------
$nossos = Join-Path $receita "pendrive"
if (Test-Path $nossos) {
  Anota "copiando os scripts da receita para o pendrive"
  robocopy $nossos $raiz /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP | Out-Null
}

# ---------- fim ----------
Anota "itens prontos: $ok | falharam: $falhou | esperando voce: $($manual.Count)" "Cyan"
if ($manual.Count) {
  Write-Host "`nFALTA FAZER (nesta ordem; o 7-Zip primeiro, que serve para extrair o resto):" -ForegroundColor Yellow
  $manual | ForEach-Object { Write-Host "  - $_" }
  Write-Host "`nDepois rode este script de novo: ele continua de onde parou." -ForegroundColor Yellow
}
$testes = Join-Path $raiz "Testes"
if (Test-Path $testes) {
  Write-Host "`nPara provar que ficou certo (com o Studio e os Documentos abertos pelo MENU.bat):" -ForegroundColor Cyan
  Write-Host "  bash $testes\ataques-studio.sh 1420      # tudo tem que dar BLOQUEOU, inclusive o T1c"
  Write-Host "  bash $testes\ataques-anythingllm.sh 3001 # A2-A4 BLOQUEOU, A5 FUNCIONA"
  Write-Host "  bash $testes\ataques-voz.sh              # V1-V5, V8, V9 BLOQUEOU; V6 e V10 FUNCIONA"
  Write-Host "  python $testes\avaliar-modos.py          # modos da IA: placar sem e com modo"
  Write-Host "  python $testes\avaliar-busca-livros.py   # busca nos livros (depois de por os seus)"
}
