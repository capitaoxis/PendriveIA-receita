# Programar com a IA do pendrive no terminal (cmd). A IA propoe a mudanca como diff; so aplica com o seu "s".
#   codar                              conversa na pasta atual (/ajuda mostra os comandos)
#   codar app.py                       conversa ja com app.py carregado
#   codar app.py "trate divisao por 0" uma tarefa so: mostra o diff, pergunta, aplica e sai
#   codar --continuar                  retoma a conversa salva em .codar\sessao.json desta pasta
#   codar --revisar                    revisao adversarial do git diff da pasta e sai
#   codar -m codigo14 ...              outro modelo (codigo | codigo14 | grande | normal)
# Se o IA-SERVIDOR estiver aberto (porta 11480), usa ele; senao sobe o modelo so enquanto voce usa.
# Ao aplicar, guarda a versao anterior em <arquivo>.bak (/desfazer volta). Comando so roda com "s".
# A IA pode, sozinha, LER arquivos da pasta, BUSCAR texto e consultar a DOCUMENTACAO offline (so leitura).
[CmdletBinding(PositionalBinding = $false)]
param([string]$m = "codigo", [int]$Porta = 11480, [switch]$Continuar, [switch]$Revisar,
      [Parameter(ValueFromRemainingArguments = $true)][string[]]$Resto)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
try { [Console]::InputEncoding = [Text.Encoding]::UTF8 } catch {}
$raiz = Split-Path $PSScriptRoot -Parent
$app = Join-Path $raiz "Studio\app"
$pyPendrive = Join-Path $raiz "Python\python312\python.exe"
$pasta = (Get-Location).Path
$dirSessao = Join-Path $pasta ".codar"; $arqSessao = Join-Path $dirSessao "sessao.json"

$carregados = [Collections.ArrayList]@()     # caminhos completos dos arquivos que a IA enxerga
$historico = [Collections.ArrayList]@()
$ultimos = @()                               # ultima aplicacao: @{Caminho; Criado}
$pedido = @()
foreach ($r in $Resto) {
    if ($r -in "--continuar", "-continuar") { $Continuar = $true; continue }
    if ($r -in "--revisar", "-revisar") { $Revisar = $true; continue }
    if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) { [void]$carregados.Add((Resolve-Path -LiteralPath $r).Path) } else { $pedido += $r }
}
$pedido = ($pedido -join " ").Trim()

function Cor([string]$t, [string]$c = "Gray") { Write-Host $t -ForegroundColor $c }
function Perguntar-Sim([string]$q) { Write-Host -NoNewline "$q (s/n) " -ForegroundColor Yellow; return ("$([Console]::ReadLine())".Trim().ToLower() -eq "s") }

# ---------- servidor: reaproveita o IA-SERVIDOR ou sobe um so para esta sessao ----------
$proc = $null; $url = $null; $chave = $null; $nCtx = 16384
$arqChave = Join-Path $PSScriptRoot "ia-servidor.chave"
if ((Test-Path $arqChave) -and -not $PSBoundParameters.ContainsKey('m')) {
    $k = ([IO.File]::ReadAllText($arqChave)).Trim()
    try { $mods = Invoke-RestMethod "http://127.0.0.1:$Porta/v1/models" -Headers @{ Authorization = "Bearer $k" } -TimeoutSec 3
          $url = "http://127.0.0.1:$Porta"; $chave = $k; Cor "[usando o IA-SERVIDOR aberto na porta ${Porta}: $($mods.data[0].id)]" DarkGray } catch {}
}
if (-not $url) {
    Add-Type @"
using System; using System.Runtime.InteropServices;
public static class PendriveJobCodar {
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
    $diag = & (Join-Path $PSScriptRoot "menu.ps1") -Diagnostico | Out-String | ConvertFrom-Json
    . (Join-Path $PSScriptRoot "codar-modelo.ps1")
    $pastaModelos = Join-Path $app "llm-models"
    $ctxServ = if ($diag.Backend -eq "cpu" -or -not $diag.Backend) { 8192 } else { 16384 }
    if ($m -eq "codigo") {   # escolha automatica pelo hardware (codar-modelo.ps1)
        $esc = Get-ModeloCodigo $diag $pastaModelos
        if (-not $esc) { Cor "Nenhum modelo de codigo neste pendrive."; exit 1 }
        $m = $esc.Chave; $arqModelo = $esc.Arquivo; $ctxServ = [math]::Min($esc.Ctx, 16384)
    } else {
        $extras = @{ grande = "unsloth--Qwen3-14B-GGUF--Qwen3-14B-Q4_K_M.gguf"; normal = $diag.ModeloChat }
        if ($CodarModelos.Contains($m)) { $arqModelo = $CodarModelos[$m] } elseif ($extras.ContainsKey($m)) { $arqModelo = $extras[$m] }
        else { Cor "Modelos: codigo (automatico), $(@($CodarModelos.Keys) -join ', '), grande, normal"; exit 1 }
    }
    $modelo = Get-ChildItem $pastaModelos -Recurse -Filter $arqModelo -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $modelo) { Cor "Modelo '$m' nao esta neste pendrive."; exit 1 }
    $backend = if ($diag.Backend) { $diag.Backend } else { "cpu" }
    $server = Join-Path $app "llm-backend\win\$backend\llama-server.exe"
    if (-not (Test-Path $server)) { $server = Join-Path $app "llm-backend\win\cpu\llama-server.exe"; $backend = "cpu" }
    $l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $p0 = $l.LocalEndpoint.Port; $l.Stop()
    $url = "http://127.0.0.1:$p0"; $chave = [Guid]::NewGuid().ToString("N")
    # LLAMA_API_KEY e o nome que este llama-server le (LLAMA_ARG_API_KEY e ignorado: medido 19/09)
    $env:LLAMA_API_KEY = $chave; $env:LLAMA_ARG_CHAT_TEMPLATE_KWARGS = '{"enable_thinking":false}'
    $log = Join-Path $env:TEMP "ia-codar-pendrive.log"
    Cor "[$m | $backend | carregando o modelo...]" DarkGray
    $tentativas = if ($m -eq "codigo30") { @(@("99"), @("99", "--n-cpu-moe", "24"), @("99", "--cpu-moe")) } else { @(@("99"), @("20")) }
    foreach ($t in $tentativas) {
        if ($backend -eq "cpu" -and $t -ne $tentativas[0]) { break }
        $a = @("-m", "`"$($modelo.FullName)`"", "--host", "127.0.0.1", "--port", $p0, "-c", $ctxServ, "--jinja", "-np", "1")
        if ($backend -ne "cpu") { $a += @("-ngl") + $t }
        if ($modelo.FullName -notlike "C:*") { $a += "--no-mmap" }
        $proc = Start-Process $server -ArgumentList $a -WindowStyle Hidden -PassThru -RedirectStandardError $log -RedirectStandardOutput "$log.out"
        [void][PendriveJobCodar]::Prender($proc.Handle)   # fechar a janela derruba o llama-server junto
        $ok = $false
        for ($i = 0; $i -lt 1800 -and -not $proc.HasExited; $i++) {   # ate 15 min: disco do pendrive pode estar lento; so troca de plano se o processo MORRER
            Start-Sleep -Milliseconds 500
            try { if ((Invoke-RestMethod "$url/health" -TimeoutSec 2).status -eq "ok") { $ok = $true; break } } catch {}
        }
        if ($ok) { break }
        Stop-Process $proc -Force -ErrorAction SilentlyContinue; $proc = $null
    }
    Remove-Item Env:LLAMA_API_KEY -ErrorAction SilentlyContinue
    if (-not $proc) { Cor "Falhou ao subir o modelo. Log: $log" Yellow; exit 1 }
}
try { $pr = Invoke-RestMethod "$url/props" -Headers @{ Authorization = "Bearer $chave" } -TimeoutSec 3; if ($pr.default_generation_settings.n_ctx) { $nCtx = [int]$pr.default_generation_settings.n_ctx } } catch {}
# orcamento em caracteres (~3 caracteres por token em codigo): metade p/ arquivos, 1/4 p/ conversa, resto p/ resposta
$orcArquivos = [int]($nCtx * 3 * 0.5); $orcConversa = [int]($nCtx * 3 * 0.22)

# ---------- arquivos ----------
$ignorar = '\\(\.git|\.codar|__pycache__|node_modules|\.venv|venv|dist|build|\.next)\\'
function Ler-Arquivo([string]$c) {
    $bytes = [IO.File]::ReadAllBytes($c)
    $txt = [IO.File]::ReadAllText($c, [Text.Encoding]::UTF8)
    $l = [Collections.Generic.List[string]]::new()
    foreach ($x in ($txt -split "\r?\n")) { $l.Add($x) }
    $fim = $txt.EndsWith("`n"); if ($fim) { $l.RemoveAt($l.Count - 1) }
    return @{ Linhas = $l; Nl = $(if ($txt.Contains("`r`n")) { "`r`n" } else { "`n" }); FinalNl = $fim; Bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) }
}
function Rel([string]$c) { if ($c.StartsWith($pasta + "\", "OrdinalIgnoreCase")) { $c.Substring($pasta.Length + 1) } else { $c } }
function Arquivos-Pasta { Get-ChildItem $pasta -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $ignorar -and $_.Extension -ne ".bak" } | Select-Object -First 300 }
function Indice {
    $fs = @(Arquivos-Pasta)
    if (-not $fs.Count) { return "(pasta vazia)" }
    (($fs | Select-Object -First 150 | ForEach-Object { "{0} ({1} bytes)" -f ((Rel $_.FullName) -replace '\\', '/'), $_.Length }) -join "`n") + $(if ($fs.Count -gt 150) { "`n... e mais $($fs.Count - 150) arquivos" } else { "" })
}
function Bloco-Arquivos {
    if (-not $carregados.Count) { return "(nenhum arquivo aberto ainda)" }
    $partes = @(); $usado = 0; $fora = @()
    for ($ix = $carregados.Count - 1; $ix -ge 0; $ix--) {   # do mais recente para o mais antigo
        $c = $carregados[$ix]
        if (-not (Test-Path -LiteralPath $c)) { continue }
        $i = Ler-Arquivo $c; $n = 0
        $num = ($i.Linhas | ForEach-Object { $n++; "{0,4}| {1}" -f $n, $_ }) -join "`n"
        $b = "### Arquivo: $((Rel $c) -replace '\\','/') ($($i.Linhas.Count) linhas)`n$num"
        if ($usado + $b.Length -gt $orcArquivos) { $fora += (Rel $c); continue }
        $usado += $b.Length; $partes = , $b + $partes
    }
    $s = ($partes -join "`n`n") + "`n(O numero antes de '|' so mostra a linha; NAO faz parte do arquivo.)"
    if ($fora) { $s += "`n(Nao couberam no contexto agora: $($fora -join ', '). Peca com /ler se precisar.)" }
    return $s
}
function Sistema {
@"
Voce e um programador experiente ajudando no terminal do Windows, na pasta $pasta. Responda em portugues do Brasil.
Para MUDAR ou CRIAR arquivos, responda com um bloco ``````diff contendo um diff unificado (formato do git):
--- a/NOME
+++ b/NOME
@@ -inicio,qtd +inicio,qtd @@
 linha de contexto (comeca com espaco)
-linha removida
+linha nova
Arquivo novo: use "--- /dev/null" e "+++ b/NOME" com "@@ -0,0 +1,N @@" e todas as linhas com "+".
Regras do diff: so mexa em arquivo que esta ABERTO abaixo (ou crie um novo); copie contexto e linhas removidas
EXATAMENTE como estao (mesma indentacao); NAO escreva os numeros de linha nem o '|'; 2 ou 3 linhas de contexto por trecho.
Antes do diff, no maximo 2 frases dizendo o que vai mudar. Pergunta sem mudanca: responda curto, sem diff.
FERRAMENTAS (so leitura; escreva a linha SOZINHA, fora de bloco de codigo, e PARE a resposta ali para esperar o resultado):
/ler caminho/do/arquivo      abre um arquivo da pasta
/buscar texto                procura o texto (nome de funcao, classe, variavel) em todos os arquivos
/docs termo                  documentacao offline (python, javascript, node, react, typescript, postgresql, git,
                             docker, bash, css, html, nextjs e pt.stackoverflow). Ex.: /docs python: pathlib.
NUNCA invente o conteudo de um arquivo: se ele nao esta ABERTO, use /ler antes. Quando usar /docs, cite a fonte [Fonte: ...] na resposta.
O Python daqui e o do pendrive; o usuario roda comandos com /rodar (voce nao executa nada). Nao mexa em sys.path.

Arquivos da pasta:
$(Indice)

Arquivos ABERTOS (conteudo de agora, ja com as mudancas aplicadas):
$(Bloco-Arquivos)
"@
}

# ---------- diff: leitura e aplicacao tolerante ----------
function Limpar([string]$s) { ($s -replace '^\s*\d+\| ', '') }   # modelo que copiou "  12| " do prompt
function Ler-Diff([string]$texto) {
    $m2 = [regex]::Matches($texto, '(?s)```(?:diff|patch)[^\n]*\n(.*?)```')
    if ($m2.Count) { $texto = ($m2 | ForEach-Object { $_.Groups[1].Value }) -join "`n" }
    elseif ($texto -notmatch '(?m)^@@ -\d') { return @() }
    $res = @(); $atual = $null; $hunk = $null; $novoArq = $false
    foreach ($ln in ($texto -split "\r?\n")) {
        if ($ln -match '^--- ') { $novoArq = ($ln -match '/dev/null'); continue }
        if ($ln -match '^\+\+\+ (?:b/)?(.+?)\s*$') { $atual = @{ Nome = $Matches[1].Trim(); Novo = $novoArq; Hunks = [Collections.ArrayList]@() }; $res += $atual; $hunk = $null; continue }
        if ($ln -match '^@@ -(\d+)') {
            if (-not $atual) { $atual = @{ Nome = ""; Novo = $false; Hunks = [Collections.ArrayList]@() }; $res += $atual }
            $hunk = @{ Inicio = [int]$Matches[1]; Velhas = [Collections.ArrayList]@(); Novas = [Collections.ArrayList]@() }; [void]$atual.Hunks.Add($hunk); continue }
        if (-not $hunk -or $ln.StartsWith("\") -or $ln -match '^(diff --git|index [0-9a-f]|new file mode)') { continue }
        $c = if ($ln.Length) { [string]$ln[0] } else { " " }; $corpo = if ($ln.Length) { Limpar $ln.Substring(1) } else { "" }
        if ($c -eq " ") { [void]$hunk.Velhas.Add($corpo); [void]$hunk.Novas.Add($corpo) }
        elseif ($c -eq "-") { [void]$hunk.Velhas.Add($corpo); $hunk.Mudou = $true }
        elseif ($c -eq "+") { [void]$hunk.Novas.Add($corpo); $hunk.Mudou = $true }
    }
    return $res
}
function Achar($linhas, $velhas, [int]$perto, [bool]$frouxo) {
    $n = $velhas.Count; $melhor = -1; $dist = [int]::MaxValue
    for ($i = 0; $i -le $linhas.Count; $i++) {
        $ok = $true
        for ($j = 0; $j -lt $n; $j++) {
            $y = [string]$velhas[$j]
            if ($i + $j -ge $linhas.Count) { if ($y.Trim() -eq "") { continue } else { $ok = $false; break } }   # linha vazia "depois do fim"
            $x = [string]$linhas[$i + $j]
            if ($frouxo) { $x = $x.Trim(); $y = $y.Trim() } else { $x = $x.TrimEnd(); $y = $y.TrimEnd() }
            if ($x -ne $y) { $ok = $false; break }
        }
        if ($ok -and [math]::Abs($i - $perto) -lt $dist) { $melhor = $i; $dist = [math]::Abs($i - $perto) }
    }
    return $melhor
}
function Aplicar-Hunks($linhas, $hunks) {
    $novo = [Collections.Generic.List[string]]::new(); foreach ($x in $linhas) { $novo.Add([string]$x) }
    $desloc = 0
    foreach ($h in $hunks) {
        while ($h.Velhas.Count -and $h.Novas.Count -and $h.Velhas[0] -eq "" -and $h.Novas[0] -eq "") { $h.Velhas.RemoveAt(0); $h.Novas.RemoveAt(0) }
        if ($h.Velhas.Count -eq 0) { $pos = [math]::Min([math]::Max($h.Inicio + $desloc, 0), $novo.Count) }
        else {
            $pos = Achar $novo $h.Velhas ($h.Inicio - 1 + $desloc) $false
            if ($pos -lt 0) { $pos = Achar $novo $h.Velhas ($h.Inicio - 1 + $desloc) $true }
            if ($pos -lt 0) { throw "o trecho perto da linha $($h.Inicio) nao bate com o arquivo:`n    " + ($h.Velhas -join "`n    ") }
        }
        $qt = [math]::Min($h.Velhas.Count, $novo.Count - $pos)
        $novo.RemoveRange($pos, $qt); $novo.InsertRange($pos, [string[]]@($h.Novas))
        $desloc += $h.Novas.Count - $qt
    }
    return , $novo
}
# Calcula TUDO antes de perguntar; se um trecho nao bate, nao aplica nada.
function Planejar($diff) {
    $plano = [ordered]@{}
    if (-not @($diff | ForEach-Object { $_.Hunks } | Where-Object { $_.Mudou }).Count) { throw "o diff so tem linhas de contexto: nao muda nada (faltaram as linhas com - e +)" }
    foreach ($d in $diff) {
        if (-not $d.Hunks.Count) { continue }
        $nome = $d.Nome -replace '/', '\'
        $cam = if (-not $nome) { "" } elseif ([IO.Path]::IsPathRooted($nome)) { $nome } else { Join-Path $pasta $nome }
        if (-not $d.Novo -and -not ($cam -and (Test-Path -LiteralPath $cam))) {   # nome errado: acha pelo nome do arquivo entre os abertos
            $porNome = @($carregados | Where-Object { (Split-Path $_ -Leaf) -eq (Split-Path $nome -Leaf) })
            if ($porNome.Count -eq 1) { $cam = $porNome[0] } elseif (-not $nome -and $carregados.Count -eq 1) { $cam = $carregados[0] }
        }
        if (-not $cam) { throw "o diff nao diz qual arquivo mudar" }
        $cam = [IO.Path]::GetFullPath($cam)
        if (-not $cam.StartsWith($pasta + "\", "OrdinalIgnoreCase")) { throw "o diff quer mexer fora da pasta atual: $cam" }
        if ($plano.Contains($cam)) { $meta = $plano[$cam]; $base = $meta.Linhas }
        elseif (Test-Path -LiteralPath $cam) {
            if ($d.Novo) { throw "o diff diz que $(Rel $cam) e novo, mas ele ja existe (nao vou sobrescrever)" }
            $meta = Ler-Arquivo $cam; $meta.Criado = $false; $base = $meta.Linhas
        } else { $meta = @{ Nl = "`r`n"; FinalNl = $true; Bom = $false; Criado = $true }; $base = @() }
        $meta.Linhas = Aplicar-Hunks $base $d.Hunks
        $plano[$cam] = $meta
    }
    return $plano
}
function Aplicar-Plano($plano) {
    $feitos = @()
    foreach ($cam in $plano.Keys) {
        $p = $plano[$cam]
        if (-not $p.Criado) { Copy-Item -LiteralPath $cam -Destination "$cam.bak" -Force }
        else { $dir = Split-Path $cam -Parent; if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory $dir | Out-Null } }
        $txt = ($p.Linhas -join $p.Nl); if ($p.FinalNl) { $txt += $p.Nl }
        [IO.File]::WriteAllText($cam, $txt, (New-Object Text.UTF8Encoding($p.Bom)))
        if ($carregados -notcontains $cam) { [void]$carregados.Add($cam) }
        $feitos += @{ Caminho = $cam; Criado = $p.Criado }
        Cor ("  {0} {1}" -f $(if ($p.Criado) { "criado:  " } else { "alterado:" }), (Rel $cam)) Green
    }
    return $feitos
}

# ---------- ferramentas (so leitura) ----------
function Ler-Para-IA([string]$x) {
    $x = $x.Trim().Trim('"', "'", '`')
    $c = if ([IO.Path]::IsPathRooted($x)) { $x } else { Join-Path $pasta ($x -replace '/', '\') }
    try { $c = [IO.Path]::GetFullPath($c) } catch { return "nao achei: $x" }
    if (-not $c.StartsWith($pasta + "\", "OrdinalIgnoreCase")) { return "recusado: $x esta fora da pasta do projeto" }
    if (-not (Test-Path -LiteralPath $c -PathType Leaf)) {
        $parecidos = @(Arquivos-Pasta | Where-Object { $_.Name -eq (Split-Path $x -Leaf) })
        if ($parecidos.Count -eq 1) { $c = $parecidos[0].FullName } else { return "nao achei: $x" }
    }
    if ((Get-Item -LiteralPath $c).Length -gt $orcArquivos) { return "$(Rel $c) e grande demais para o contexto ($((Get-Item -LiteralPath $c).Length) bytes); use /buscar para achar o trecho" }
    if ($carregados -notcontains $c) { [void]$carregados.Add($c) }
    Cor "  [a IA abriu $(Rel $c)]" DarkGray
    return "aberto: $(Rel $c) (o conteudo esta agora em 'Arquivos ABERTOS')"
}
function Buscar([string]$t) {
    $t = $t.Trim().Trim('"', "'", '`'); if (-not $t) { return "" }
    $rg = Get-Command rg -ErrorAction SilentlyContinue
    if ($rg) { $r = & $rg.Source -n -F -i --max-count 5 --max-columns 200 -g '!*.bak' -g '!.codar' -- $t $pasta 2>$null | Select-Object -First 40 }
    else {
        $r = Arquivos-Pasta | Where-Object { $_.Length -lt 2MB } | Select-String -SimpleMatch -Pattern $t -ErrorAction SilentlyContinue |
            Select-Object -First 40 | ForEach-Object { "{0}:{1}:{2}" -f (Rel $_.Path), $_.LineNumber, $_.Line.Trim().Substring(0, [math]::Min(200, $_.Line.Trim().Length)) }
    }
    $r = @($r | ForEach-Object { $_ -replace [regex]::Escape($pasta + "\"), '' })
    Cor "  [busca '$t': $($r.Count) linhas]" DarkGray
    if (-not $r.Count) { return "nada encontrado para '$t'" }
    return ($r -join "`n")
}
function Docs([string]$t) {
    Cor "  [consultando a documentacao offline: $t]" DarkGray
    $s = (& $pyPendrive (Join-Path $PSScriptRoot "codar-docs.py") (Join-Path $raiz "Kiwix\zim") $t 2>$null | Out-String).Trim()
    if (-not $s) { return "nada na documentacao offline para '$t'" }
    if ($s.Length -gt 5000) { $s = $s.Substring(0, 5000) + "`n(...)" }
    return $s
}

# ---------- sessao ----------
function Salvar-Sessao {
    try {
        if (-not (Test-Path $dirSessao)) { New-Item -ItemType Directory $dirSessao | Out-Null }
        $o = @{ pasta = $pasta; salvo = (Get-Date).ToString("s"); carregados = @($carregados | ForEach-Object { Rel $_ }); historico = @($historico) }
        [IO.File]::WriteAllText($arqSessao, ($o | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    } catch { Cor "  [nao consegui salvar a sessao: $($_.Exception.Message)]" DarkGray }
}
function Carregar-Sessao {
    if (-not (Test-Path $arqSessao)) { Cor "Nao ha sessao salva nesta pasta ($arqSessao)." Yellow; return }
    $o = [IO.File]::ReadAllText($arqSessao, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($r in $o.carregados) { $c = Join-Path $pasta $r; if ((Test-Path -LiteralPath $c) -and $carregados -notcontains $c) { [void]$carregados.Add($c) } }
    foreach ($h in $o.historico) { [void]$historico.Add(@{ role = $h.role; content = $h.content }) }
    Cor "Sessao de $($o.salvo) retomada: $($historico.Count) mensagens, arquivos: $(($carregados | ForEach-Object { Rel $_ }) -join ', ')" DarkGray
}

# ---------- conversa com a IA em fluxo (SSE), colorindo o diff linha a linha ----------
function Cor-Linha([string]$ln, [bool]$dentro) {
    if (-not $dentro) { if ($ln -match '^/(ler|buscar|docs)\s') { return "Magenta" }; return "Gray" }
    if ($ln -match '^(\+\+\+|---)') { "White" } elseif ($ln.StartsWith("+")) { "Green" } elseif ($ln.StartsWith("-")) { "Red" } elseif ($ln.StartsWith("@@")) { "Cyan" } else { "DarkGray" }
}
function Chamar-IA {
    # corta a conversa antiga para caber (fica sempre a ultima pergunta)
    while ($historico.Count -gt 2 -and (($historico | ForEach-Object { $_.content.Length } | Measure-Object -Sum).Sum -gt $orcConversa)) { $historico.RemoveAt(0) }
    $msgs = @(@{ role = "system"; content = (Sistema) }) + @($historico)
    $corpo = [Text.Encoding]::UTF8.GetBytes((@{ messages = $msgs; temperature = 0.1; max_tokens = 3072; stream = $true } | ConvertTo-Json -Depth 8))
    $req = [Net.HttpWebRequest]::Create("$url/v1/chat/completions")
    $req.Method = "POST"; $req.ContentType = "application/json; charset=utf-8"; $req.Timeout = 1800000; $req.ReadWriteTimeout = 1800000
    $req.Headers.Add("Authorization", "Bearer $chave")
    $st = $req.GetRequestStream(); $st.Write($corpo, 0, $corpo.Length); $st.Close()
    try { $resposta = $req.GetResponse() } catch [Net.WebException] {
        $det = try { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { "" }
        throw "o servidor recusou ($($_.Exception.Message)) $det"
    }
    $leitor = New-Object IO.StreamReader($resposta.GetResponseStream(), [Text.Encoding]::UTF8)
    $tudo = New-Object Text.StringBuilder; $linha = ""; $dentro = $false; $tps = $null
    Write-Host ""
    while (($ev = $leitor.ReadLine()) -ne $null) {
        if (-not $ev.StartsWith("data: ") -or $ev -eq "data: [DONE]") { continue }
        $j = $ev.Substring(6) | ConvertFrom-Json
        if ($j.timings) { $tps = $j.timings.predicted_per_second }
        $pedaco = $j.choices[0].delta.content
        if (-not $pedaco) { continue }
        [void]$tudo.Append($pedaco)
        $linha += $pedaco
        while (($k = $linha.IndexOf("`n")) -ge 0) {
            $ln = $linha.Substring(0, $k).TrimEnd("`r"); $linha = $linha.Substring($k + 1)
            if ($ln -match '^\s*```') { $dentro = -not $dentro; Write-Host $ln -ForegroundColor DarkGray; continue }
            Write-Host $ln -ForegroundColor (Cor-Linha $ln $dentro)
        }
    }
    $leitor.Close()
    if ($linha) { Write-Host $linha -ForegroundColor (Cor-Linha $linha $dentro) }
    if ($tps) { Cor ("[{0:0.0} tokens/s]" -f $tps) DarkGray }
    $resp = ($tudo.ToString() -replace '(?s)<think>.*?</think>\s*', '')
    [void]$historico.Add(@{ role = "assistant"; content = $resp })
    return $resp
}
# Pergunta e deixa a IA usar as ferramentas de leitura sozinha (ate 4 rodadas).
function Falar([string]$q) {
    $script:consultouDocs = $false
    # "/docs termo" escrito no meio do pedido: consulta ANTES e ja manda o resultado junto
    $pre = [regex]::Match($q, '/docs\s+([^.,;
]+)')
    if ($pre.Success -and -not $q.StartsWith("/")) { $q += "`n`nResultado de /docs $($pre.Groups[1].Value.Trim()):`n" + (Docs $pre.Groups[1].Value.Trim()); $script:consultouDocs = $true }
    [void]$historico.Add(@{ role = "user"; content = $q })
    for ($rodada = 0; $rodada -lt 4; $rodada++) {
        $resp = Chamar-IA
        $semCodigo = [regex]::Replace($resp, '(?s)```.*?```', '')
        $pedidos = @([regex]::Matches($semCodigo, '(?m)^\s*/(ler|buscar|docs)\s+(.+?)\s*$') | Select-Object -First 4)
        if (-not $pedidos.Count -or @(Ler-Diff $resp).Count) { break }
        $res = foreach ($p in $pedidos) {
            $arg = $p.Groups[2].Value
            switch ($p.Groups[1].Value) { "ler" { "/ler ${arg}: " + (Ler-Para-IA $arg) } "buscar" { "/buscar ${arg}:`n" + (Buscar $arg) } "docs" { $script:consultouDocs = $true; "/docs ${arg}:`n" + (Docs $arg) } }
        }
        [void]$historico.Add(@{ role = "user"; content = "Resultado das ferramentas:`n" + ($res -join "`n`n") + "`n`nAgora continue a tarefa original: $q" })
    }
    if (-not $script:consultouDocs -and $resp -match '(?i)fonte\s*:|docs\.python\.org|developer\.mozilla') {
        Cor "  [atencao: a IA citou fonte sem consultar a documentacao offline; pode ser inventada. Use /docs termo]" Yellow
    }
    Salvar-Sessao
    return $resp
}

# Recebe a resposta; se tiver diff, pergunta e aplica. Devolve $true se aplicou.
function Tratar-Resposta([string]$resp, [int]$tentativa = 0) {
    $diff = @(Ler-Diff $resp)
    if (-not $diff.Count) { return $false }
    try { $plano = Planejar $diff }
    catch {
        Cor "`nNao da para aplicar este diff: $($_.Exception.Message)" Yellow
        if ($tentativa -lt 2 -and (Perguntar-Sim "Pedir para a IA refazer o diff?")) {
            return (Tratar-Resposta (Falar "Seu diff nao bateu com o arquivo: $($_.Exception.Message). Refaca o diff copiando o contexto exatamente como esta no arquivo ABERTO.") ($tentativa + 1))
        }
        return $false
    }
    Write-Host ""
    if (-not (Perguntar-Sim "Aplicar?")) { Cor "Nada foi alterado."; [void]$historico.Add(@{ role = "user"; content = "(nao apliquei esse diff)" }); [void]$historico.Add(@{ role = "assistant"; content = "Ok." }); Salvar-Sessao; return $false }
    $script:ultimos = Aplicar-Plano $plano
    [void]$historico.Add(@{ role = "user"; content = "(diff aplicado)" }); [void]$historico.Add(@{ role = "assistant"; content = "Ok." })
    Salvar-Sessao
    return $true
}

function Rodar([string]$cmd) {
    if (-not $cmd) { Cor "Uso: /rodar <comando>   ex.: /rodar python test_app.py"; return }
    if (-not (Perguntar-Sim "Rodar '$cmd' em ${pasta}?")) { return }
    $antes = $env:PATH; $real = $cmd
    # Os dois Pythons do pendrive sao "embutidos" (._pth): nao poem a pasta atual no sys.path, e
    # "import calc" ao lado do teste falha. Comando python/pytest passa pelo codar-rodar.py.
    $pyProj = Join-Path $raiz "Ferramentas\python-projetos\python.exe"
    $pyExe = if (Test-Path $pyProj) { $pyProj } else { $pyPendrive }
    $env:PATH = "$(Split-Path $pyExe);$(Split-Path $pyExe)\Scripts;$env:PATH"
    $runner = Join-Path $PSScriptRoot 'codar-rodar.py'
    if ($cmd -match '^(python|py)(\.exe)?(\s+|$)(.*)$') { $real = "`"$pyExe`" `"$runner`" $($Matches[4])" }
    elseif ($cmd -match '^pytest(\s+|$)(.*)$') { $real = "`"$pyExe`" `"$runner`" -m pytest $($Matches[2])" }
    $env:PYTHONIOENCODING = "utf-8"
    # vai por um .cmd temporario: aspas e acentos passam intactos (sem a traducao de argumentos do PowerShell)
    $bat = Join-Path $env:TEMP ("codar-rodar-" + [guid]::NewGuid().ToString("N") + ".cmd")
    [IO.File]::WriteAllText($bat, "@echo off`r`nchcp 65001 >nul`r`ncd /d `"$pasta`"`r`n$real 2>&1`r`n", (New-Object Text.UTF8Encoding($false)))
    try { $saida = (& cmd.exe /d /c $bat | Out-String); $cod = $LASTEXITCODE } finally { $env:PATH = $antes; Remove-Item -LiteralPath $bat -Force -ErrorAction SilentlyContinue }
    if ($saida.Length -gt 6000) { $saida = "..." + $saida.Substring($saida.Length - 6000) }
    Write-Host $saida.TrimEnd()
    Cor "[saiu com codigo $cod]" $(if ($cod -eq 0) { "Green" } else { "Yellow" })
    if ($cod -ne 0) {
        if (Perguntar-Sim "Mandar o erro para a IA corrigir?") {
            # abre para a IA os arquivos da pasta citados no erro (senao ela inventa o conteudo)
            foreach ($f in @(Arquivos-Pasta)) { if ($saida -match [regex]::Escape($f.Name) -and $carregados -notcontains $f.FullName -and $f.Length -lt $orcArquivos / 2) { [void]$carregados.Add($f.FullName); Cor "  [abrindo $(Rel $f.FullName) para a IA]" DarkGray } }
            [void](Tratar-Resposta (Falar "Rodei: $cmd`nSaiu com codigo $cod. Saida:`n$saida`nAche a causa e corrija com um diff."))
        }
    } else { [void]$historico.Add(@{ role = "user"; content = "(rodei '$cmd': deu certo, codigo 0)" }); [void]$historico.Add(@{ role = "assistant"; content = "Otimo." }); Salvar-Sessao }
}

function Revisar-Git {
    $ErrorActionPreference = "Continue"   # git escreve avisos no stderr; nao pode derrubar a sessao
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { foreach ($g in @("Ferramentas\git\cmd\git.exe", "Ferramentas\git\bin\git.exe")) { if (Test-Path (Join-Path $raiz $g)) { $git = Get-Item (Join-Path $raiz $g); break } } }
    if (-not $git) { Cor "Nao achei o git (nem no PATH nem em Ferramentas\git). Sem ele nao ha diff para revisar." Yellow; return }
    $exe = if ($git.Source) { $git.Source } else { $git.FullName }
    & $exe -C $pasta rev-parse --is-inside-work-tree 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { Cor "Esta pasta nao e um repositorio git." Yellow; return }
    & $exe -C $pasta rev-parse --verify HEAD 2>$null | Out-Null
    $d = if ($LASTEXITCODE -eq 0) { & $exe -C $pasta -c core.quotepath=off diff HEAD --unified=5 2>&1 | Out-String } else { (& $exe -C $pasta diff --cached --unified=5 | Out-String) + (& $exe -C $pasta diff --unified=5 | Out-String) }
    $novos = @(& $exe -C $pasta ls-files --others --exclude-standard 2>$null | Where-Object { $_ -notmatch '^\.codar/|__pycache__/|\.bak$' })
    if (-not $d.Trim() -and -not $novos) { Cor "Nada mudou desde o ultimo commit." ; return }
    $lim = [int]($orcArquivos * 1.2)
    if ($d.Length -gt $lim) { Cor "[diff grande: revisando os primeiros $lim caracteres]" DarkGray; $d = $d.Substring(0, $lim) }
    Cor "[revisando $(($d -split "`n" | Where-Object { $_ -match '^\+\+\+ ' }).Count) arquivo(s) alterado(s)$(if ($novos) { " + $($novos.Count) novo(s) fora do git" })]" DarkGray
    $q = @"
Faca uma REVISAO ADVERSARIAL deste git diff (mudancas ainda nao commitadas). Seja cetico: procure o que QUEBRA.
Procure: bugs de logica, casos de borda (vazio, None/null, zero, negativo, lista grande, unicode, arquivo inexistente),
tratamento de erro que engole falha, seguranca (injecao de comando/SQL, caminho fora da pasta, segredo no codigo,
entrada do usuario sem validar), concorrencia, e teste que passa sem testar nada.
Formato: uma lista, cada item "arquivo:linha - [ALTA|MEDIA|BAIXA] problema - como corrigir". Linha = numero no arquivo NOVO.
Nao elogie. Se nao achar nada serio, diga isso em uma linha. NAO mande diff agora.
$(if ($novos) { "Arquivos novos ainda fora do git (nao estao no diff): $($novos -join ', ')" })

``````diff
$d
``````
"@
    [void](Falar $q)
}

$gravador = $null
function Voz([int]$seg = 15) {
    $ErrorActionPreference = "Continue"   # ffmpeg/whisper falam no stderr
    $ff = Join-Path $raiz "AnythingLLM\dados\storage\engines\ffmpeg\windows-x64\ffmpeg.exe"
    $modeloW = Join-Path $app "speech-models\ggml-large-v3-turbo-q5_0.bin"
    $comPlaca = (Test-Path (Join-Path $env:SystemRoot "System32\nvcuda.dll")) -and (Test-Path (Join-Path $raiz "AnythingLLM\whisper-cuda\whisper-cli.exe"))
    $cli = if ($comPlaca) { Join-Path $raiz "AnythingLLM\whisper-cuda\whisper-cli.exe" } else { Join-Path $raiz "AnythingLLM\whisper\whisper-cli.exe" }
    foreach ($p in @($ff, $modeloW, $cli)) { if (-not (Test-Path -LiteralPath $p)) { Cor "Falta $p" Yellow; return $null } }
    $lista = & $ff -hide_banner -list_devices true -f dshow -i dummy 2>&1 | Out-String
    $mics = @([regex]::Matches($lista, '"([^"]+)" \(audio\)') | ForEach-Object { $_.Groups[1].Value })
    if (-not $mics) { Cor "Nenhum microfone encontrado." Yellow; return $null }
    if ($env:CODAR_MICROFONE -and $mics -contains $env:CODAR_MICROFONE) { $mics = @($env:CODAR_MICROFONE) + $mics }
    $wav = Join-Path $env:TEMP ("codar-voz-" + [guid]::NewGuid().ToString("N") + ".wav")
    try {
        # ffmpeg com stdin redirecionado ignora o "q": grava por tempo fixo (/voz 30 = 30 s)
        $ok = $false
        foreach ($mic in $mics) {   # alguns "microfones" (virtuais) nao abrem: tenta o proximo
            Cor "  Fale agora: gravando $seg s de '$mic'..." Cyan
            & $ff -hide_banner -loglevel error -y -f dshow -i "audio=$mic" -ar 16000 -ac 1 -t $seg $wav 2>&1 | Out-Null
            if ((Test-Path $wav) -and (Get-Item $wav).Length -gt 8000) { $ok = $true; break }
        }
        if (-not $ok) { Cor "  Nenhum microfone gravou: $($mics -join ', ')" Yellow; return $null }
        Cor "  Transcrevendo..." DarkGray
        $antes = $env:PATH; $env:PATH = (Join-Path $app "llm-backend\win\cuda") + ";" + $env:PATH
        try { & $cli -m $modeloW -f $wav -l pt -nt -otxt -of $wav 2>$null | Out-Null } finally { $env:PATH = $antes }
        $txt = if (Test-Path "$wav.txt") { ([IO.File]::ReadAllText("$wav.txt", [Text.Encoding]::UTF8) -replace '\s+', ' ').Trim() } else { "" }
        if (-not $txt) { Cor "  Nao entendi o audio." Yellow; return $null }
        Cor "  Voce disse: $txt" White
        if (Perguntar-Sim "  Mandar para a IA?") { return $txt }
        return $null
    } finally { Remove-Item -LiteralPath $wav, "$wav.txt" -Force -ErrorAction SilentlyContinue }
}

function Ajuda {
    Cor "  Escreva o pedido normalmente (ex.: 'crie soma.py com uma funcao soma e um teste')." Gray
    Cor "  A IA abre arquivos, busca no projeto e consulta a documentacao sozinha (so leitura)." DarkGray
    Cor "  /ler arq [arq2]   abre arquivos para a IA            /arquivos   lista a pasta (* = aberto)" Gray
    Cor "  /buscar texto     procura no projeto                  /docs termo documentacao offline (ex.: /docs python: pathlib)" Gray
    Cor "  /rodar <comando>  roda (so com 's'), mostra a saida e, se falhar, oferece mandar o erro para a IA" Gray
    Cor "  /revisar          revisao adversarial do git diff     /voz [seg]  fala o pedido (grava 15 s)" Gray
    Cor "  /desfazer         volta a ultima mudanca (.bak)       /esquecer   fecha todos os arquivos e limpa a conversa" Gray
    Cor "  /ajuda            esta lista                          /sair       termina (a conversa fica salva: codar --continuar)" Gray
}

# ---------- principal ----------
try {
    if ($Continuar) { Carregar-Sessao }
    if ($Revisar) { Revisar-Git; exit 0 }
    if ($pedido) {   # modo uma tarefa
        if (-not $carregados.Count) { Cor 'Uso: codar arquivo1.py [arquivo2 ...] "o que mudar"   (ou so "codar" para conversar)'; exit 1 }
        $r = Falar $pedido
        if (-not @(Ler-Diff $r).Count) { Cor "A IA nao devolveu um diff." Yellow; exit 2 }
        [void](Tratar-Resposta $r); exit 0
    }
    Cor "`nCodar na pasta $pasta  (contexto $nCtx tokens; /ajuda mostra os comandos; /sair termina)" Cyan
    if ($carregados.Count) { Cor ("Arquivos abertos: " + (($carregados | ForEach-Object { Rel $_ }) -join ", ")) DarkGray }
    while ($true) {
        Write-Host -NoNewline "`ncodar> " -ForegroundColor Cyan
        $q = [Console]::ReadLine()
        if ($null -eq $q) { break }
        $q = $q.Trim(); if (-not $q) { continue }
        $cmdo, $arg = $q -split '\s+', 2
        switch ($cmdo.ToLower()) {
            { $_ -in "/sair", "sair", "exit" } { return }
            "/ajuda" { Ajuda; continue }
            "/arquivos" { Arquivos-Pasta | ForEach-Object { $mark = if ($carregados -contains $_.FullName) { "*" } else { " " }; "{0} {1,8:N0}  {2}" -f $mark, $_.Length, (Rel $_.FullName) }; continue }
            "/ler" { foreach ($x in ($arg -split '\s+' | Where-Object { $_ })) { $r = Ler-Para-IA $x; if ($r -notlike "aberto*") { Cor "  $r" Yellow } }; Salvar-Sessao; continue }
            "/buscar" { Write-Host (Buscar $arg); continue }
            "/docs" { Write-Host (Docs $arg); continue }
            "/esquecer" { $carregados.Clear(); $historico.Clear(); Salvar-Sessao; Cor "Conversa limpa; nenhum arquivo aberto."; continue }
            "/rodar" { Rodar $arg; continue }
            "/revisar" { Revisar-Git; continue }
            "/voz" { $t = Voz $(if ($arg -match '^\d+$') { [int]$arg } else { 15 }); if ($t) { [void](Tratar-Resposta (Falar $t)) }; continue }
            "/desfazer" {
                if (-not $ultimos) { Cor "Nada para desfazer."; continue }
                if (-not (Perguntar-Sim ("Desfazer: " + (($ultimos | ForEach-Object { Rel $_.Caminho }) -join ", ") + "?"))) { continue }
                foreach ($u in $ultimos) {
                    if ($u.Criado) { Remove-Item -LiteralPath $u.Caminho -Force; $carregados.Remove($u.Caminho); Cor "  apagado $(Rel $u.Caminho) (era novo)" Green }
                    else { Copy-Item -LiteralPath "$($u.Caminho).bak" -Destination $u.Caminho -Force; Cor "  voltou $(Rel $u.Caminho) do .bak" Green }
                }
                $script:ultimos = @(); [void]$historico.Add(@{ role = "user"; content = "(desfiz a ultima mudanca)" }); [void]$historico.Add(@{ role = "assistant"; content = "Ok." }); Salvar-Sessao
                continue
            }
            default {
                if ($q.StartsWith("/")) { Cor "Comando desconhecido. /ajuda"; continue }
                [void](Tratar-Resposta (Falar $q))
            }
        }
    }
} catch {
    Cor "Erro: $($_.Exception.Message)" Yellow; exit 2
} finally {
    if ($proc) { Stop-Process $proc -Force -ErrorAction SilentlyContinue }
}
