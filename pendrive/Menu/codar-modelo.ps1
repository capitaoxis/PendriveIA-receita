# Escolha automatica do modelo de CODIGO pelo hardware (usado por ia-codar.ps1 e ia-servidor.ps1).
# Medido em 19/09 (6 tarefas python verificaveis, CODAR.md): 14B-Q3 4/6, 7B 2/6, 1.5B 1/6, Qwen3-1.7B 0/6.
$CodarModelos = [ordered]@{
    codigo30 = "unsloth--Qwen3-Coder-30B-A3B-Instruct-GGUF--Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"   # placa 12 GB+ ou RAM 32 GB
    codigo14 = "bartowski--Qwen2.5-Coder-14B-Instruct-GGUF--Qwen2.5-Coder-14B-Instruct-Q3_K_M.gguf"   # placa 8 GB (este PC)
    codigo7  = "Qwen--Qwen2.5-Coder-7B-Instruct-GGUF--qwen2.5-coder-7b-instruct-q4_k_m.gguf"          # placa menor
    codigo3  = "Qwen--Qwen2.5-Coder-3B-Instruct-GGUF--qwen2.5-coder-3b-instruct-q4_k_m.gguf"          # sem placa (PC fraco)
    codigo1  = "Qwen--Qwen2.5-Coder-1.5B-Instruct-GGUF--qwen2.5-coder-1.5b-instruct-q8_0.gguf"        # autocompletar / ultimo recurso
}
function Get-ModeloCodigo($diag, [string]$pastaModelos) {
    $vram = [double](($diag.Placas | Measure-Object VramGB -Maximum).Maximum)
    $ram = [double]$diag.RamGB
    $cpu = ($diag.Backend -eq "cpu" -or -not $diag.Backend)
    $ordem = if (-not $cpu -and ($vram -ge 12 -or $ram -ge 31)) { "codigo30", "codigo14", "codigo7" }
             elseif (-not $cpu -and $vram -ge 7.5) { "codigo14", "codigo7" }
             elseif (-not $cpu) { "codigo7", "codigo3" }
             elseif ($ram -ge 31) { "codigo7", "codigo3", "codigo1" }        # sem placa mas muita RAM: 7B a ~5 tok/s
             else { "codigo3", "codigo1", "codigo7" }                         # PC fraco
    # RAM >= 31 sem placa tambem aguenta o 30B-A3B (MoE, ~3B ativos por token)
    if ($cpu -and $ram -ge 31) { $ordem = @("codigo30") + $ordem }
    foreach ($k in $ordem) {
        if (Test-Path (Join-Path $pastaModelos $CodarModelos[$k])) {
            $ctx = if ($cpu) { 8192 } elseif ($k -eq "codigo14" -and $vram -lt 10) { 16384 } else { 32768 }
            return @{ Chave = $k; Arquivo = $CodarModelos[$k]; Ctx = $ctx }
        }
    }
    return $null
}
