# Pendrive: detecta o hardware do PC e recomenda modelo e backend.
# Uso direto: powershell -File Menu\hardware.ps1 [-TesteSemPlaca] [-TesteRamGB 8]
# (nomes diferentes dos parâmetros do menu.ps1: este arquivo é carregado com dot-source e
#  um param() com os mesmos nomes zerava as opções -Simular... do menu)
# Uso por outro script: . .\hardware.ps1; $hw = Get-PendriveHardware
param([switch]$TesteSemPlaca, [double]$TesteRamGB = 0)

function Get-VramPorRegistro {
    # Win32_VideoController.AdapterRAM estoura em 4 GB (32 bits). O registro guarda o valor em 64 bits.
    $classe = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
    $mapa = @{}
    Get-ChildItem $classe -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' } | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        $nome = $p.DriverDesc
        $bytes = $p.'HardwareInformation.qwMemorySize'
        if ($nome -and $bytes) { $mapa[$nome] = [math]::Round(([double]$bytes) / 1GB, 1) }
    }
    return $mapa
}

function Get-PendriveHardware {
    param([switch]$SemPlaca, [double]$RamGB = 0)

    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $ram = if ($RamGB -gt 0) { $RamGB } else { [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1) }

    $placas = @()
    if (-not $SemPlaca) {
        $vramRegistro = Get-VramPorRegistro
        foreach ($v in Get-CimInstance Win32_VideoController) {
            $nome = [string]$v.Name
            if ($nome -match 'Microsoft Basic|Remote Display|Virtual|Parsec|Meta Virtual') { continue }
            $fabricante = if ($nome -match 'NVIDIA') { "NVIDIA" } elseif ($nome -match 'AMD|Radeon') { "AMD" } elseif ($nome -match 'Intel') { "Intel" } else { "Outra" }
            $vram = if ($vramRegistro.ContainsKey($nome)) { $vramRegistro[$nome] } else { [math]::Round(([double]$v.AdapterRAM) / 1GB, 1) }
            $placas += [pscustomobject]@{ Nome = $nome; Fabricante = $fabricante; VramGB = $vram }
        }
        $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        if ($smi) {
            # Driver NVIDIA desatualizado faz o nvidia-smi escrever no erro padrao; com
            # $ErrorActionPreference='Stop' isso vira erro TERMINANTE mesmo indo para $null, e o
            # menu inteiro morria na abertura. Aqui o erro do programa e apenas ignorado.
            $linhas = @()
            $antes = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $linhas = @(& $smi.Source --query-gpu=name,memory.total --format=csv,noheader,nounits 2>$null)
            } catch { $linhas = @() } finally { $ErrorActionPreference = $antes }
            foreach ($l in $linhas) {
                $nome, $mib = $l.Split(",") | ForEach-Object { $_.Trim() }
                $p = $placas | Where-Object { $_.Nome -eq $nome } | Select-Object -First 1
                if ($p) { $p.VramGB = [math]::Round([double]$mib / 1024, 1) }
            }
        }
    }

    $nvidia = $placas | Where-Object { $_.Fabricante -eq "NVIDIA" } | Sort-Object VramGB -Descending | Select-Object -First 1
    # Integrada (Intel/AMD com pouca memória dedicada) não conta como placa para os modelos.
    $outra = $placas | Where-Object { $_.Fabricante -in @("AMD", "Intel") -and $_.VramGB -ge 4 } | Sort-Object VramGB -Descending | Select-Object -First 1

    $aviso = ""
    if ($nvidia -and $nvidia.VramGB -ge 7) {
        $perfil = "Placa NVIDIA com memória suficiente"; $backend = "cuda"; $camadas = -1
        $chat = "Qwen3-8B-Q4_K_M.gguf"; $contexto = 16384
    } elseif ($nvidia) {
        $perfil = "Placa NVIDIA com pouca memória"; $backend = "cuda"; $camadas = -1
        $chat = "unsloth--Qwen3.5-4B-GGUF--Qwen3.5-4B-Q4_K_M.gguf"; $contexto = 8192
    } elseif ($outra) {
        $perfil = "Placa $($outra.Fabricante) (Vulkan)"; $backend = "vulkan"; $camadas = -1
        $chat = "unsloth--Qwen3.5-4B-GGUF--Qwen3.5-4B-Q4_K_M.gguf"; $contexto = 8192
    } else {
        $perfil = "Sem placa de vídeo (só processador)"; $backend = "cpu"; $camadas = 0
        $chat = "unsloth--Qwen3.5-4B-GGUF--Qwen3.5-4B-Q4_K_M.gguf"; $contexto = 8192
        $aviso = "Sem placa de vídeo as respostas são lentas (cerca de 6 palavras por segundo num processador bom)."
    }
    if ($ram -lt 8) {
        $aviso = "Só $ram GB de RAM: os modelos podem não abrir ou deixar o PC travando. Feche outros programas."
    } elseif ($ram -lt 12 -and $backend -eq "cpu") {
        $aviso = "$ram GB de RAM e sem placa de vídeo: vai funcionar, mas devagar. Feche outros programas."
    }

    [pscustomobject]@{
        Processador   = ([string]$cpu.Name).Trim()
        Nucleos       = $cpu.NumberOfCores
        Threads       = $cpu.NumberOfLogicalProcessors
        RamGB         = $ram
        Placas        = @($placas)
        Perfil        = $perfil
        Backend       = $backend
        CamadasGPU    = $camadas
        ModeloChat    = $chat
        ModeloDocs    = $chat
        Contexto      = $contexto
        Aviso         = $aviso
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Get-PendriveHardware -SemPlaca:$TesteSemPlaca -RamGB $TesteRamGB | ConvertTo-Json -Depth 4
}
