# Pendrive: baixa os arquivos ZIM do plano direto em Kiwix\zim, na versao mais recente.
# - acha a data mais nova de cada arquivo na listagem de download.kiwix.org;
# - confere o SHA-256 publicado pelo Kiwix (sem hash, nao aceita);
# - retoma download interrompido (curl -C -) e pula o que ja esta baixado e conferido;
# - para antes de encher o disco.
# Uso:  powershell -ExecutionPolicy Bypass -File Kiwix\baixar-zims.ps1 [-Somente devdocs_en_bash]
param([string[]]$Somente = @())

$ErrorActionPreference = "Stop"
$destino = Join-Path $PSScriptRoot "zim"
New-Item -ItemType Directory -Force -Path $destino | Out-Null

# "pasta no servidor/prefixo do arquivo (sem a data)".
# Texto simples e split: no PowerShell 5.1, filtrar uma lista de pares que sobra
# com um item so achata o par em dois textos.
$lista = @(
    "wikipedia/wikipedia_pt_all_maxi",
    "wikisource/wikisource_pt_all_maxi",
    "wikipedia/wikipedia_en_medicine_maxi",
    "stack_exchange/pt.stackoverflow.com_mul_all",
    "wiktionary/wiktionary_pt_all_nopic",
    "wikipedia/wikipedia_pt_medicine_nopic",
    "devdocs/devdocs_en_python", "devdocs/devdocs_en_javascript",
    "devdocs/devdocs_en_typescript", "devdocs/devdocs_en_react",
    "devdocs/devdocs_en_node", "devdocs/devdocs_en_postgresql",
    "devdocs/devdocs_en_docker", "devdocs/devdocs_en_bash",
    "devdocs/devdocs_en_git", "devdocs/devdocs_en_nextjs",
    "devdocs/devdocs_en_html", "devdocs/devdocs_en_css"
)
# Com -File, "-Somente a,b" chega como um texto so: sem separar aqui, o filtro nao casa com nada,
# o laco nao roda e o script termina dizendo "Tudo baixado e conferido" sem ter baixado nada.
$Somente = @($Somente | ForEach-Object { $_ -split "," } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($Somente.Count -gt 0) {
    $lista = @($lista | Where-Object { $Somente -contains $_.Split("/")[1] })
    if ($lista.Count -eq 0) { Write-Host "[ERRO] -Somente nao casou com nenhum arquivo do plano."; exit 1 }
}

$curl = Join-Path $env:WINDIR "System32\curl.exe"
$base = "https://download.kiwix.org/zim"
$listagens = @{}
$falhas = 0

foreach ($item in $lista) {
    $pasta, $prefixo = $item.Split("/")
    if (-not $listagens.ContainsKey($pasta)) {
        $listagens[$pasta] = (& $curl -sSL "$base/$pasta/") -join "`n"
    }
    $padrao = [regex]::Escape($prefixo) + '_(\d{4}-\d{2})\.zim"'
    # O @() e obrigatorio: com uma data so, o Sort-Object devolve texto, e $datas[0] daria "2"
    # (a primeira letra de "2026-07"), montando um nome de arquivo que nao existe no servidor.
    $datas = @([regex]::Matches($listagens[$pasta], $padrao) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique -Descending)
    if (-not $datas) { Write-Host "[ERRO] $prefixo nao encontrado em $base/$pasta/"; $falhas++; continue }

    $nome = "${prefixo}_$($datas[0]).zim"
    $url = "$base/$pasta/$nome"
    $arquivo = Join-Path $destino $nome
    $esperado = ((& $curl -sSL "$url.sha256") -join "").Trim().Split(" ")[0].ToLowerInvariant()
    if ($esperado -notmatch '^[0-9a-f]{64}$') { Write-Host "[ERRO] $nome sem SHA-256 publicado; nao baixado."; $falhas++; continue }

    if ((Test-Path $arquivo) -and ((Get-FileHash -Algorithm SHA256 -LiteralPath $arquivo).Hash.ToLowerInvariant() -eq $esperado)) {
        Write-Host "[OK] $nome ja estava baixado e conferido."
        continue
    }

    # Sem content-length (espelho em chunked, 403/404) o valor virava 0 e a trava de espaco
    # deixava passar qualquer arquivo: um ZIM de dezenas de GB num disco que nao cabe.
    $cabecalhos = @(& $curl -sSIL $url | Select-String -Pattern '^content-length:\s*(\d+)' | Select-Object -Last 1)
    if ($cabecalhos.Count -eq 0) {
        Write-Host "[ERRO] $nome : o servidor nao informou o tamanho; nao da para conferir o espaco. Pulado."
        $falhas++; continue
    }
    $tamanho = [int64]$cabecalhos[0].Matches.Groups[1].Value
    $parcial = "$arquivo.part"
    $jaBaixado = if (Test-Path $parcial) { (Get-Item $parcial).Length } else { 0 }
    $livre = (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($destino))).AvailableFreeSpace
    if (($tamanho - $jaBaixado) -gt ($livre - 500MB)) {
        Write-Host ("[ERRO] {0}: faltam {1:N1} GB, livre {2:N1} GB. Parando." -f $nome, (($tamanho - $jaBaixado) / 1GB), ($livre / 1GB))
        $falhas++; break
    }

    Write-Host ("Baixando {0} ({1:N2} GB)..." -f $nome, ($tamanho / 1GB))
    & $curl -fL --retry 5 -C - -o $parcial $url
    if ($LASTEXITCODE -ne 0) {
        # Parcial ja do tamanho total: o servidor responde 416 e o curl falha, mas o
        # arquivo pode estar completo (ou corrompido). A conferencia abaixo decide.
        $agora = if (Test-Path $parcial) { (Get-Item $parcial).Length } else { 0 }
        $parcialCompleto = $agora -eq $tamanho
        if (-not $parcialCompleto -and $agora -le $jaBaixado -and $jaBaixado -gt 0) {
            # Nao andou nada: retomar esta impossivel (espelho sem suporte a Range, parcial
            # corrompido). Sem isto, toda rodada seguinte falhava igual, para sempre.
            Write-Host "  o pedaco baixado nao serve para retomar; recomecando do zero..."
            Remove-Item -LiteralPath $parcial -Force -ErrorAction SilentlyContinue
            & $curl -fL --retry 5 -o $parcial $url
            $agora = if (Test-Path $parcial) { (Get-Item $parcial).Length } else { 0 }
            $parcialCompleto = $agora -eq $tamanho
        }
        if (-not $parcialCompleto) {
            Write-Host "[ERRO] download de $nome falhou (codigo $LASTEXITCODE); rode de novo para retomar."
            $falhas++; continue
        }
    }

    $obtido = (Get-FileHash -Algorithm SHA256 -LiteralPath $parcial).Hash.ToLowerInvariant()
    if ($obtido -ne $esperado) {
        Write-Host "[ERRO] $nome com SHA-256 diferente; arquivo parcial apagado."
        Remove-Item -LiteralPath $parcial -Force
        $falhas++; continue
    }
    Move-Item -LiteralPath $parcial -Destination $arquivo -Force
    # Versao antiga do mesmo arquivo sai depois que a nova foi conferida.
    Get-ChildItem -LiteralPath $destino -Filter "${prefixo}_*.zim" | Where-Object { $_.Name -ne $nome } | ForEach-Object {
        Write-Host "  removendo versao antiga $($_.Name)"
        Remove-Item -LiteralPath $_.FullName -Force
    }
    Write-Host "[OK] $nome conferido."
}

if ($falhas -gt 0) { Write-Host "$falhas problema(s)."; exit 1 }
Write-Host "Tudo baixado e conferido."
