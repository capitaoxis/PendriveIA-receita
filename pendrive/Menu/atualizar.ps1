# Atualizador do pendrive: CONSULTA se ha versao nova dos modelos (HuggingFace) e dos ZIMs
# (download.kiwix.org). Nao baixa nada sem perguntar.
# - Modelo "dono--repo--arquivo.gguf": compara o lfs.oid (SHA-256) do HF com o guardado em
#   Menu\versoes.json (medido uma vez; nao recalcula o hash de dezenas de GB a cada consulta).
# - ZIM "nome_AAAA-MM.zim": procura data mais nova do mesmo nome-base no Kiwix.
# - Baixa com curl -C - para um arquivo .baixando, confere o SHA-256 e so entao troca o arquivo.
# - Confere espaco livre antes. Sem internet: avisa e sai.
# Uso: ATUALIZAR.cmd            (pergunta o que baixar)
#      ATUALIZAR.cmd -SoConsultar
param([switch]$SoConsultar)

$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot
$pastaModelos = Join-Path $raiz "Studio\app\llm-models"
$pastaZim = Join-Path $raiz "Kiwix\zim"
$arqVersoes = Join-Path $PSScriptRoot "versoes.json"
$curl = Join-Path $env:WINDIR "System32\curl.exe"
$kiwix = "https://download.kiwix.org/zim"

function Pausa { if (-not $SoConsultar) { Write-Host ""; Write-Host "Aperte ENTER para sair."; [void][Console]::ReadLine() } }
function GB([double]$b) { "{0:N2} GB" -f ($b / 1GB) }
function Baixar-Texto([string]$url) {
    $t = & $curl -sSLf --max-time 60 $url 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($t -join "`n")
}

# Internet?
& $curl -sSf --max-time 15 -o NUL "https://huggingface.co/api/models/unsloth/Qwen3-1.7B-GGUF" 2>$null
$okHF = ($LASTEXITCODE -eq 0)
& $curl -sSf --max-time 15 -o NUL "$kiwix/" 2>$null
$okKiwix = ($LASTEXITCODE -eq 0)
if (-not $okHF -and -not $okKiwix) { Write-Host "Sem internet. Nada a consultar."; Pausa; exit 0 }

# Lista local de versoes (hash medido de cada modelo).
$versoes = @{}
if (Test-Path -LiteralPath $arqVersoes) {
    $j = Get-Content -LiteralPath $arqVersoes -Raw | ConvertFrom-Json
    foreach ($p in $j.PSObject.Properties) { $versoes[$p.Name] = $p.Value }
}

$itens = New-Object System.Collections.ArrayList
Write-Host "Consultando... (pode levar um minuto)"

# ---- Modelos (HuggingFace) ----
$arvores = @{}
foreach ($f in @(Get-ChildItem -LiteralPath $pastaModelos -Filter *.gguf -File | Sort-Object Name)) {
    $partes = $f.Name -split "--"
    if ($partes.Count -ne 3) { [void]$itens.Add([pscustomobject]@{Tipo="modelo"; Nome=$f.Name; Estado="sem origem no nome (dono--repo--arquivo); ignorado"; Novo=$null}); continue }
    if (-not $okHF) { [void]$itens.Add([pscustomobject]@{Tipo="modelo"; Nome=$f.Name; Estado="HuggingFace fora do ar"; Novo=$null}); continue }
    $repo = "$($partes[0])/$($partes[1])"; $arquivo = $partes[2]
    if (-not $arvores.ContainsKey($repo)) {
        $t = Baixar-Texto "https://huggingface.co/api/models/$repo/tree/main?recursive=true"
        $arvores[$repo] = if ($t) { @($t | ConvertFrom-Json) } else { $null }
    }
    $arv = $arvores[$repo]
    if ($null -eq $arv) { [void]$itens.Add([pscustomobject]@{Tipo="modelo"; Nome=$f.Name; Estado="repositorio nao respondeu"; Novo=$null}); continue }
    $remoto = @($arv | Where-Object { $_.type -eq "file" -and ($_.path -eq $arquivo -or $_.path -like "*/$arquivo") }) | Select-Object -First 1
    if (-not $remoto -or -not $remoto.lfs) { [void]$itens.Add([pscustomobject]@{Tipo="modelo"; Nome=$f.Name; Estado="arquivo sumiu do repositorio"; Novo=$null}); continue }
    $oid = $remoto.lfs.oid.ToLowerInvariant()
    $local = if ($versoes.ContainsKey($f.Name)) { $versoes[$f.Name].sha256 } else { $null }
    if (-not $local) {
        [void]$itens.Add([pscustomobject]@{Tipo="modelo"; Nome=$f.Name; Estado="sem hash em versoes.json (modelo novo: medir com Get-FileHash e anotar)"; Novo=$null}); continue
    }
    if ($local -eq $oid) {
        [void]$itens.Add([pscustomobject]@{Tipo="modelo"; Nome=$f.Name; Estado="em dia"; Novo=$null})
    } else {
        [void]$itens.Add([pscustomobject]@{Tipo="modelo"; Nome=$f.Name; Estado="MUDOU no HuggingFace"
            Novo=[pscustomobject]@{Nome=$f.Name; Url="https://huggingface.co/$repo/resolve/main/$($remoto.path)"; Sha=$oid; Tamanho=[int64]$remoto.lfs.size; Antigo=$f.FullName; Destino=$f.FullName; Atual=$f.Length}})
    }
}

# ---- ZIMs (Kiwix) ----
$listagens = @{}
$pastasConhecidas = @("wikipedia","wikisource","wiktionary","stack_exchange","devdocs","other","wikibooks","wikiversity","wikivoyage","wikiquote","wikinews","gutenberg","ted","phet","libretexts","freecodecamp","mooc","vikidia","zimit")
foreach ($f in @(Get-ChildItem -LiteralPath $pastaZim -Filter *.zim -File | Sort-Object Name)) {
    if ($f.Name -notmatch '^(.+)_(\d{4}-\d{2})\.zim$') { [void]$itens.Add([pscustomobject]@{Tipo="zim"; Nome=$f.Name; Estado="nome sem data; ignorado"; Novo=$null}); continue }
    $base = $Matches[1]; $data = $Matches[2]
    if (-not $okKiwix) { [void]$itens.Add([pscustomobject]@{Tipo="zim"; Nome=$f.Name; Estado="Kiwix fora do ar"; Novo=$null}); continue }
    # Pasta no servidor: pelo prefixo do nome (stack_exchange nao segue a regra).
    $cands = @()
    if ($base -match '\.(stackexchange|stackoverflow)\.com_' -or $base -match '^(stackoverflow|superuser|askubuntu|serverfault)') { $cands += "stack_exchange" }
    $pref = ($base -split "_")[0]
    if ($pastasConhecidas -contains $pref) { $cands += $pref }
    $cands += $pastasConhecidas
    $datas = @(); $pastaAchada = $null
    foreach ($pasta in ($cands | Select-Object -Unique)) {
        if (-not $listagens.ContainsKey($pasta)) { $listagens[$pasta] = Baixar-Texto "$kiwix/$pasta/" }
        if (-not $listagens[$pasta]) { continue }
        $padrao = '"' + [regex]::Escape($base) + '_(\d{4}-\d{2})\.zim"'
        $datas = @([regex]::Matches($listagens[$pasta], $padrao) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique -Descending)
        if ($datas.Count -gt 0) { $pastaAchada = $pasta; break }
    }
    if (-not $pastaAchada) { [void]$itens.Add([pscustomobject]@{Tipo="zim"; Nome=$f.Name; Estado="nao achado no Kiwix"; Novo=$null}); continue }
    if ($datas[0] -le $data) { [void]$itens.Add([pscustomobject]@{Tipo="zim"; Nome=$f.Name; Estado="em dia"; Novo=$null}); continue }
    $nomeNovo = "${base}_$($datas[0]).zim"
    $url = "$kiwix/$pastaAchada/$nomeNovo"
    $tam = @(& $curl -sSIL --max-time 30 $url | Select-String -Pattern '^content-length:\s*(\d+)' | Select-Object -Last 1)
    $tamanho = if ($tam.Count) { [int64]$tam[0].Matches.Groups[1].Value } else { 0 }
    [void]$itens.Add([pscustomobject]@{Tipo="zim"; Nome=$f.Name; Estado="nova: $nomeNovo"
        Novo=[pscustomobject]@{Nome=$nomeNovo; Url=$url; Sha=$null; Tamanho=$tamanho; Antigo=$f.FullName; Destino=(Join-Path $pastaZim $nomeNovo); Atual=$f.Length}})
}

# ---- Tabela ----
Write-Host ""
$n = 0
foreach ($i in $itens) {
    if ($i.Novo) {
        $n++; $i | Add-Member -NotePropertyName Num -NotePropertyValue $n
        Write-Host ("[{0}] {1,-6} {2}" -f $n, $i.Tipo, $i.Nome) -ForegroundColor Yellow
        Write-Host ("      atual {0} -> nova {1} ({2})" -f (GB $i.Novo.Atual), (GB $i.Novo.Tamanho), $i.Estado)
    } else {
        Write-Host ("    {0,-6} {1}  - {2}" -f $i.Tipo, $i.Nome, $i.Estado)
    }
}
$novos = @($itens | Where-Object { $_.Novo })
Write-Host ""
if ($novos.Count -eq 0) { Write-Host "Tudo em dia. Nada para baixar."; Pausa; exit 0 }
if ($SoConsultar) { Write-Host "$($novos.Count) atualizacao(oes) disponivel(is). Rode ATUALIZAR.cmd para escolher."; exit 0 }

$resp = Read-Host "Numeros para baixar separados por virgula, 'todos' ou ENTER/'nada' para sair"
$resp = "$resp".Trim().ToLowerInvariant()
if ($resp -eq "" -or $resp -eq "nada" -or $resp -eq "n") { Write-Host "Nada baixado."; exit 0 }
$escolha = if ($resp -eq "todos") { $novos } else {
    $nums = $resp -split "[,; ]+" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
    @($novos | Where-Object { $nums -contains $_.Num })
}
if ($escolha.Count -eq 0) { Write-Host "Nenhum numero valido. Nada baixado."; exit 0 }

$falhas = 0
foreach ($i in $escolha) {
    $d = $i.Novo
    Write-Host ""
    Write-Host "== $($d.Nome)"
    if (-not $d.Sha) {
        $t = Baixar-Texto "$($d.Url).sha256"
        $d.Sha = if ($t) { $t.Trim().Split(" ")[0].ToLowerInvariant() } else { $null }
    }
    if ($d.Sha -notmatch '^[0-9a-f]{64}$') { Write-Host "[ERRO] Sem SHA-256 publicado; nao baixado."; $falhas++; continue }
    if ($d.Tamanho -le 0) { Write-Host "[ERRO] Servidor nao informou o tamanho; nao da para conferir o espaco."; $falhas++; continue }
    $temp = "$($d.Destino).baixando"
    $ja = if (Test-Path -LiteralPath $temp) { (Get-Item -LiteralPath $temp).Length } else { 0 }
    $livre = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($d.Destino))).AvailableFreeSpace
    if (($d.Tamanho - $ja) -gt ($livre - 1GB)) {
        Write-Host ("[ERRO] Faltam {0}, livre {1} (reserva de 1 GB). Pulado." -f (GB ($d.Tamanho - $ja)), (GB $livre)); $falhas++; continue
    }
    & $curl -L -C - --retry 5 --retry-delay 5 -o $temp $d.Url
    if ($LASTEXITCODE -ne 0) { Write-Host "[ERRO] Download interrompido (curl $LASTEXITCODE). Rode de novo: continua de onde parou."; $falhas++; continue }
    Write-Host "Conferindo SHA-256..."
    $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $temp).Hash.ToLowerInvariant()
    if ($h -ne $d.Sha) {
        Write-Host "[ERRO] SHA-256 NAO confere. Arquivo novo apagado; o antigo fica."
        Remove-Item -LiteralPath $temp -Force; $falhas++; continue
    }
    # Troca so depois de conferir. Modelo: mesmo nome (substitui). ZIM: nome novo, apaga o antigo.
    if ($d.Destino -eq $d.Antigo) {
        Move-Item -LiteralPath $temp -Destination $d.Destino -Force
    } else {
        Move-Item -LiteralPath $temp -Destination $d.Destino -Force
        Remove-Item -LiteralPath $d.Antigo -Force
    }
    if ($i.Tipo -eq "modelo") {
        $versoes[$d.Nome] = [pscustomobject]@{sha256=$h; tamanho=$d.Tamanho; medido=(Get-Date -Format "yyyy-MM-dd")}
        $saida = [ordered]@{}; foreach ($k in ($versoes.Keys | Sort-Object)) { $saida[$k] = $versoes[$k] }
        $saida | ConvertTo-Json -Depth 4 | Out-File -Encoding ascii -LiteralPath $arqVersoes
    }
    Write-Host "[OK] $($d.Nome) atualizado e conferido."
}
Write-Host ""
if ($falhas) { Write-Host "$falhas item(ns) com problema (ver acima)." } else { Write-Host "Pronto." }
Pausa
