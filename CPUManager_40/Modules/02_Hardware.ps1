# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 02_Hardware.ps1
# CPU/GPU detection, logging, Win32 types, hardware profile
# Lines 151-787 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
function Validate-TDP {
    param(
        [hashtable]$TDPProfile,
        [string]$Mode = "Unknown"
    )
    $safe = $true
    $warnings = @()
    # Walidacja STAPM
    if ($TDPProfile.STAPM -gt $Script:TDP_HARD_LIMITS.MaxSTAPM) {
        $warnings += "[WARN] $Mode STAPM $($TDPProfile.STAPM)W exceeds HARD LIMIT $($Script:TDP_HARD_LIMITS.MaxSTAPM)W - CAPPED"
        $TDPProfile.STAPM = $Script:TDP_HARD_LIMITS.MaxSTAPM
        $safe = $false
    }
    if ($TDPProfile.STAPM -lt $Script:TDP_HARD_LIMITS.MinSTAPM) {
        $warnings += "[WARN] $Mode STAPM $($TDPProfile.STAPM)W below minimum - set to $($Script:TDP_HARD_LIMITS.MinSTAPM)W"
        $TDPProfile.STAPM = $Script:TDP_HARD_LIMITS.MinSTAPM
    }
    # Walidacja Fast
    if ($TDPProfile.Fast -gt $Script:TDP_HARD_LIMITS.MaxFast) {
        $warnings += "[WARN] $Mode Fast $($TDPProfile.Fast)W exceeds HARD LIMIT $($Script:TDP_HARD_LIMITS.MaxFast)W - CAPPED"
        $TDPProfile.Fast = $Script:TDP_HARD_LIMITS.MaxFast
        $safe = $false
    }
    # Walidacja Slow
    if ($TDPProfile.Slow -gt $Script:TDP_HARD_LIMITS.MaxSlow) {
        $warnings += "[WARN] $Mode Slow $($TDPProfile.Slow)W exceeds HARD LIMIT $($Script:TDP_HARD_LIMITS.MaxSlow)W - CAPPED"
        $TDPProfile.Slow = $Script:TDP_HARD_LIMITS.MaxSlow
        $safe = $false
    }
    # Walidacja Tctl
    if ($TDPProfile.Tctl -gt $Script:TDP_HARD_LIMITS.MaxTctl) {
        $warnings += " CRITICAL: $Mode Tctl $($TDPProfile.Tctl)°C exceeds THERMAL SAFETY LIMIT $($Script:TDP_HARD_LIMITS.MaxTctl)°C"
        if ($Script:TDP_HARD_LIMITS.AutoAdjustTctl) {
            $warnings += "[WARN] $Mode Tctl $($TDPProfile.Tctl)°C above maximum - lowering to $($Script:TDP_HARD_LIMITS.MaxTctl)°C"
            $TDPProfile.Tctl = $Script:TDP_HARD_LIMITS.MaxTctl
        } else {
            $warnings += " CRITICAL: EMERGENCY CAP applied ($($Script:TDP_HARD_LIMITS.MaxTctl)°C)"
            $TDPProfile.Tctl = $Script:TDP_HARD_LIMITS.MaxTctl
        }
        $safe = $false
    }
    if ($TDPProfile.Tctl -lt $Script:TDP_HARD_LIMITS.MinTctl) {
        if ($Script:TDP_HARD_LIMITS.AutoAdjustTctl) {
            $warnings += "[WARN] $Mode Tctl $($TDPProfile.Tctl)°C below minimum - raising to $($Script:TDP_HARD_LIMITS.MinTctl)°C"
            $TDPProfile.Tctl = $Script:TDP_HARD_LIMITS.MinTctl
        } else {
            $warnings += "[WARN] $Mode Tctl $($TDPProfile.Tctl)°C below minimum $($Script:TDP_HARD_LIMITS.MinTctl)°C - NOT modifying value"
            # Nie podnosimy automatycznie Tctl; tylko logujemy ostrzezenie
        }
    }
    # Logika spojnosci: Fast >= Slow >= STAPM
    if ($TDPProfile.Fast -lt $TDPProfile.Slow) {
        $warnings += "[WARN] $Mode Fast ($($TDPProfile.Fast)) < Slow ($($TDPProfile.Slow)) - correcting"
        $TDPProfile.Fast = $TDPProfile.Slow
    }
    if ($TDPProfile.Slow -lt $TDPProfile.STAPM) {
        $warnings += "[WARN] $Mode Slow ($($TDPProfile.Slow)) < STAPM ($($TDPProfile.STAPM)) - correcting"
        $TDPProfile.Slow = $TDPProfile.STAPM
    }
    # Log ostrzezen
    foreach ($warn in $warnings) {
        Write-Log $warn "TDP-SAFETY"
    }
    return @{ Safe = $safe; Warnings = $warnings; Profile = $TDPProfile }
}
# #
# CPU DETECTION (Intel + AMD)
# #
$Script:IsHybridCPU = $false
$Script:PCoreCount = 0
$Script:ECoreCount = 0
$Script:HybridArchitecture = "Unknown"
$Script:CPUVendor = "Unknown"
$Script:CPUModel = "Unknown"
$Script:CPUGeneration = "Unknown"
$Script:TotalCores = 0
$Script:TotalThreads = 0
function Detect-CPU {
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cpuName = $cpu.Name
        $Script:TotalCores = $cpu.NumberOfCores
        $Script:TotalThreads = $cpu.NumberOfLogicalProcessors
        # ...existing code...
        # #
        # INTEL DETECTION
        # #
        if ($cpuName -match "Intel") {
            $Script:CPUVendor = "Intel"
            $Script:CPUType = "Intel"  # Synchronizacja ze starsza zmienna
            # Intel Alder Lake (12th gen) - Hybrid P+E cores
            if ($cpuName -match "12\d\d\d") {
                $Script:IsHybridCPU = $true
                $Script:HybridArchitecture = "Alder Lake (12th Gen)"
                $Script:CPUGeneration = "12th Gen"
                # Typowe konfiguracje Alder Lake
                if ($Script:TotalCores -ge 16) {
                    $Script:PCoreCount = 8; $Script:ECoreCount = $Script:TotalCores - 8
                } elseif ($Script:TotalCores -ge 12) {
                    $Script:PCoreCount = 6; $Script:ECoreCount = $Script:TotalCores - 6
                } elseif ($Script:TotalCores -ge 10) {
                    $Script:PCoreCount = 6; $Script:ECoreCount = 4
                } else {
                    $Script:PCoreCount = [Math]::Floor($Script:TotalCores * 0.5)
                    $Script:ECoreCount = $Script:TotalCores - $Script:PCoreCount
                }
                # ...existing code...
            }
            # Intel Raptor Lake (13th gen) - Hybrid P+E cores
            elseif ($cpuName -match "13\d\d\d") {
                $Script:IsHybridCPU = $true
                $Script:HybridArchitecture = "Raptor Lake (13th Gen)"
                $Script:CPUGeneration = "13th Gen"
                if ($Script:TotalCores -ge 24) {
                    $Script:PCoreCount = 8; $Script:ECoreCount = $Script:TotalCores - 8
                } elseif ($Script:TotalCores -ge 16) {
                    $Script:PCoreCount = 8; $Script:ECoreCount = $Script:TotalCores - 8
                } elseif ($Script:TotalCores -ge 12) {
                    $Script:PCoreCount = 6; $Script:ECoreCount = $Script:TotalCores - 6
                } else {
                    $Script:PCoreCount = [Math]::Floor($Script:TotalCores * 0.5)
                    $Script:ECoreCount = $Script:TotalCores - $Script:PCoreCount
                }
                # ...existing code...
            }
            # Intel Raptor Lake Refresh (14th gen) - Hybrid P+E cores
            elseif ($cpuName -match "14\d\d\d") {
                $Script:IsHybridCPU = $true
                $Script:HybridArchitecture = "Raptor Lake Refresh (14th Gen)"
                $Script:CPUGeneration = "14th Gen"
                if ($Script:TotalCores -ge 24) {
                    $Script:PCoreCount = 8; $Script:ECoreCount = $Script:TotalCores - 8
                } elseif ($Script:TotalCores -ge 16) {
                    $Script:PCoreCount = 8; $Script:ECoreCount = $Script:TotalCores - 8
                } elseif ($Script:TotalCores -ge 12) {
                    $Script:PCoreCount = 6; $Script:ECoreCount = $Script:TotalCores - 6
                } else {
                    $Script:PCoreCount = [Math]::Floor($Script:TotalCores * 0.5)
                    $Script:ECoreCount = $Script:TotalCores - $Script:PCoreCount
                }
                # ...existing code...
            }
            # Starsze generacje Intel (10th, 11th) - brak hybrid
            elseif ($cpuName -match "10\d\d\d|11\d\d\d") {
                $Script:HybridArchitecture = if ($cpuName -match "10\d\d\d") { "Comet Lake (10th Gen)" } else { "Rocket Lake (11th Gen)" }
                $Script:CPUGeneration = if ($cpuName -match "10\d\d\d") { "10th Gen" } else { "11th Gen" }
                # ...existing code...
            }
            else {
                # ...existing code...
            }
            # Wykryj model (i3/i5/i7/i9)
            if ($cpuName -match "i9") { $Script:CPUModel = "Core i9" }
            elseif ($cpuName -match "i7") { $Script:CPUModel = "Core i7" }
            elseif ($cpuName -match "i5") { $Script:CPUModel = "Core i5" }
            elseif ($cpuName -match "i3") { $Script:CPUModel = "Core i3" }
            return $true
        }
        # #
        # AMD DETECTION
        # #
        elseif ($cpuName -match "AMD") {
            $Script:CPUVendor = "AMD"
            $Script:CPUType = "AMD"  # Synchronizacja ze starsza zmienna
            $Script:IsHybridCPU = $false  # AMD nie ma P/E cores
            # AMD Ryzen 9000 Series (Zen 5)
            if ($cpuName -match "9\d\d\d") {
                $Script:HybridArchitecture = "Zen 5"
                $Script:CPUGeneration = "Ryzen 9000"
                if ($cpuName -match "X3D") {
                    # ...existing code...
                } else {
                    # ...existing code...
                }
            }
            # AMD Ryzen 7000 Series (Zen 4)
            elseif ($cpuName -match "7\d\d\d") {
                $Script:HybridArchitecture = "Zen 4"
                $Script:CPUGeneration = "Ryzen 7000"
                if ($cpuName -match "X3D") {
                    # ...existing code...
                } else {
                    # ...existing code...
                }
            }
            # AMD Ryzen 5000 Series (Zen 3)
            elseif ($cpuName -match "5\d\d\d") {
                $Script:HybridArchitecture = "Zen 3"
                $Script:CPUGeneration = "Ryzen 5000"
                if ($cpuName -match "X3D") {
                    # ...existing code...
                } else {
                    # ...existing code...
                }
            }
            # AMD Ryzen 3000 Series (Zen 2)
            elseif ($cpuName -match "3\d\d\d") {
                $Script:HybridArchitecture = "Zen 2"
                $Script:CPUGeneration = "Ryzen 3000"
                # ...existing code...
            }
            # Starsze AMD
            else {
                # ...existing code...
            }
            # Wykryj model (Ryzen 3/5/7/9)
            if ($cpuName -match "Ryzen 9") { $Script:CPUModel = "Ryzen 9" }
            elseif ($cpuName -match "Ryzen 7") { $Script:CPUModel = "Ryzen 7" }
            elseif ($cpuName -match "Ryzen 5") { $Script:CPUModel = "Ryzen 5" }
            elseif ($cpuName -match "Ryzen 3") { $Script:CPUModel = "Ryzen 3" }
            elseif ($cpuName -match "Threadripper") { $Script:CPUModel = "Threadripper" }
            return $true
        }
        # Nieznany producent
        else {
            # ...existing code...
            return $false
        }
    } catch {
        # ...existing code...
        return $false
    }
}
# Alias dla kompatybilnosci wstecznej
function Detect-HybridCPU { return Detect-CPU }

# ═══════════════════════════════════════════════════════════════════════════════
# CENTRALNY PROFIL HARDWARE — $Script:HW
# Jedno miejsce z CAŁĄ wiedzą o maszynie. Wypełniany po Detect-CPU + RAM detect.
# Używany przez: RAMCache, Q-Learning, Prophet, PerformanceBooster, TDP AI
# ═══════════════════════════════════════════════════════════════════════════════
function Build-HardwareProfile {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $totalRAM_MB = [Math]::Round($os.TotalVisibleMemorySize / 1KB)
        $freeRAM_MB  = [Math]::Round($os.FreePhysicalMemory / 1KB)
        $totalRAM_GB = [Math]::Round($totalRAM_MB / 1024, 1)
    } catch {
        $totalRAM_MB = 8192; $freeRAM_MB = 4096; $totalRAM_GB = 8
    }
    
    # Storage type detection (NVMe vs SSD vs HDD)
    $storageType = "Unknown"
    try {
        $sysDisk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq 0 } | Select-Object -First 1
        if ($sysDisk) {
            if ($sysDisk.BusType -eq 'NVMe' -or $sysDisk.MediaType -eq 'SSD') {
                $storageType = if ($sysDisk.BusType -eq 'NVMe') { "NVMe" } else { "SSD" }
            } else { $storageType = "HDD" }
        }
    } catch {
        # Fallback: sprawdź czy seek time wskazuje na SSD
        try {
            $diskPerf = Get-Counter '\PhysicalDisk(0 *)\Avg. Disk sec/Read' -ErrorAction Stop
            $avgRead = $diskPerf.CounterSamples[0].CookedValue
            $storageType = if ($avgRead -lt 0.001) { "NVMe" } elseif ($avgRead -lt 0.005) { "SSD" } else { "HDD" }
        } catch { $storageType = "SSD" }  # assume SSD if can't detect
    }
    
    # Tier: określa ogólną "klasę" maszyny dla AI decisions
    # Tier 1: High-end (≥32GB, ≥8 cores, NVMe/SSD) → agresywny cache, więcej preloadów
    # Tier 2: Mid-range (16-31GB, 4-7 cores) → standardowy cache
    # Tier 3: Low-end (<16GB, <4 cores lub HDD) → ostrożny cache, oszczędzaj RAM
    $tier = 2
    if ($totalRAM_GB -ge 32 -and $Script:TotalCores -ge 6) { $tier = 1 }
    elseif ($totalRAM_GB -lt 16 -or $Script:TotalCores -lt 4 -or $storageType -eq "HDD") { $tier = 3 }
    
    $hw = @{
        # CPU
        Vendor       = $Script:CPUVendor
        Model        = $Script:CPUModel
        Generation   = $Script:CPUGeneration
        Cores        = $Script:TotalCores
        Threads      = $Script:TotalThreads
        IsHybrid     = $Script:IsHybridCPU
        PCores       = $Script:PCoreCount
        ECores       = $Script:ECoreCount
        Architecture = $Script:HybridArchitecture
        # RAM
        TotalRAM_MB  = $totalRAM_MB
        TotalRAM_GB  = $totalRAM_GB
        FreeRAM_MB   = $freeRAM_MB
        # Storage
        StorageType  = $storageType  # "NVMe" | "SSD" | "HDD"
        # GPU (wypełniane później po Detect-GPU)
        HasdGPU      = $false
        dGPUVendor   = ""
        # Tier
        Tier         = $tier         # 1=High-end, 2=Mid, 3=Low-end
        # Computed cache strategy
        # Tier 1: agresywny preload, duży cache, dużo apps w startup
        # Tier 2: standardowy
        # Tier 3: ostrożny, mały cache, priorytetyzuj tylko heavy apps
        CacheStrategy = switch ($tier) {
            1 { @{ MaxStartupApps = 15; MaxIdlePreload = 10; MaxModules = 200; MaxSavedFiles = 200; BatchSize = 128MB; CachePercent = 0.50 } }
            2 { @{ MaxStartupApps = 8;  MaxIdlePreload = 6;  MaxModules = 120; MaxSavedFiles = 100; BatchSize = 64MB;  CachePercent = 0.40 } }
            3 { @{ MaxStartupApps = 3;  MaxIdlePreload = 2;  MaxModules = 40;  MaxSavedFiles = 35;  BatchSize = 16MB;  CachePercent = 0.30 } }
        }
    }
    
    # Bonus: HDD → cache jest KRYTYCZNY (dysk wolny), zwiększ priorytet cache
    if ($storageType -eq "HDD") {
        $hw.CacheStrategy.CachePercent = [Math]::Min(0.60, $hw.CacheStrategy.CachePercent + 0.15)
        $hw.CacheStrategy.MaxStartupApps = [Math]::Min(12, $hw.CacheStrategy.MaxStartupApps + 3)
    }
    
    return $hw
}

# #
# GPU DETECTION (iGPU vs dGPU - Intel/AMD/NVIDIA)
# #
$Script:GPUList = @()           # Lista wszystkich GPU
$Script:HasiGPU = $false        # Czy jest zintegrowana grafika
$Script:HasdGPU = $false        # Czy jest dedykowana karta
$Script:PrimaryGPU = $null      # Główny GPU (dla gier)
$Script:iGPUName = ""           # Nazwa iGPU
$Script:dGPUName = ""           # Nazwa dGPU
$Script:dGPUVendor = ""         # NVIDIA/AMD

# ═══════════════════════════════════════════════════════════════════════════════
# DEBUG LOGGING TO FILE - GPU-BOUND DETECTION TRACKER
# ═══════════════════════════════════════════════════════════════════════════════
$Script:DebugLogPath = "C:\Temp\CPUManager_GPU-Debug.log"  # Debug/Info/GPU-Bound logi
$Script:DebugLogEnabled = $true
$Script:DebugLogIterationCounter = 0

function Write-DebugLog {
    param(
        [string]$Message,
        [string]$Type = "INFO",  # INFO, GPU-BOUND, MODE, METRICS, EVENT
        [string]$Source = "ENGINE"  # ENGINE lub CONFIGURATOR
    )
    
    if (-not $Script:DebugLogEnabled) { return }
    
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logLine = "[$timestamp] [$Source] [$Type] $Message"
        
        # Upewnij się że folder istnieje
        $logDir = Split-Path $Script:DebugLogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        
        # Append do pliku (thread-safe jeśli możliwe)
        # Limit 200KB - gdy przekroczy, zacznij od nowa
        if (Test-Path $Script:DebugLogPath) {
            $fileSize = (Get-Item $Script:DebugLogPath -ErrorAction SilentlyContinue).Length
            if ($fileSize -gt 204800) {
                Set-Content -Path $Script:DebugLogPath -Value "[$timestamp] [ENGINE] [INFO] === LOG ROTATED (exceeded 200KB) ===" -Encoding UTF8 -ErrorAction SilentlyContinue
            }
        }
        Add-Content -Path $Script:DebugLogPath -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Cichy błąd - nie przerywaj ENGINE jeśli logging fails
    }
}

# ═══════════════════════════════════════════════════════════════
# RAMCache Debug Log — dedykowany plik logów do C:\Temp\RAMCache-Debug.log
# ═══════════════════════════════════════════════════════════════
$Script:RAMCacheLogPath = "C:\Temp\RAMCache-Debug.log"
function Write-RCLog {
    param([string]$Message)
    try {
        $timestamp = Get-Date -Format "HH:mm:ss.fff"
        $line = "[$timestamp] $Message"
        $dir = Split-Path $Script:RAMCacheLogPath -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        # Rotacja >500KB
        if (Test-Path $Script:RAMCacheLogPath) {
            $size = (Get-Item $Script:RAMCacheLogPath -ErrorAction SilentlyContinue).Length
            if ($size -gt 500KB) {
                Set-Content -Path $Script:RAMCacheLogPath -Value "[$timestamp] === LOG ROTATED ===" -Encoding UTF8
            }
        }
        Add-Content -Path $Script:RAMCacheLogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } catch {}
}

function Write-ErrorLog {
    param(
        [string]$Component = "ENGINE",  # ENGINE, CONFIGURATOR, GPU-BOUND, PROPHET, etc.
        [string]$ErrorMessage,
        [string]$Details = ""
    )
    try {
        $msg = if ($Details) { "$Component ERROR: $ErrorMessage | $Details" } else { "$Component ERROR: $ErrorMessage" }
        Write-DebugLog $msg "ERROR" $Component
    } catch {}
}

function Initialize-DebugLog {
    try {
        # Sprawdź czy folder istnieje
        $logDir = Split-Path $Script:DebugLogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        
        # Nagłówek nowej sesji
        $separator = "=" * 80
        $header = @"

$separator
CPUManager ENGINE v42.4 DEBUG - GPU-BOUND FULL FIX + DEBUG - New Session Started
$(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
$separator

"@
        Add-Content -Path $Script:DebugLogPath -Value $header -Encoding UTF8
        Write-DebugLog "Debug logging initialized to: $Script:DebugLogPath" "INFO"
        Write-Host "  [DEBUG] Logging to: $Script:DebugLogPath" -ForegroundColor Yellow
    }
    catch {
        Write-Host "  [DEBUG] Failed to initialize log file: $_" -ForegroundColor Red
        $Script:DebugLogEnabled = $false
    }
}

function Detect-GPU {
    try {
        $allGPUs = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        $Script:GPUList = @()
        
        foreach ($gpu in $allGPUs) {
            $gpuInfo = @{
                Name = $gpu.Name
                VideoProcessor = $gpu.VideoProcessor
                AdapterRAM = $gpu.AdapterRAM
                Status = $gpu.Status
                Type = "Unknown"
                Vendor = "Unknown"
                IsPrimary = $false
            }
            
            $gpuName = $gpu.Name
            $ramGB = [Math]::Round($gpu.AdapterRAM / 1GB, 2)
            
            # #
            # KLASYFIKACJA: iGPU (Zintegrowana)
            # V40.2: Rozszerzone wzorce dla AMD APU (Vega, RDNA2, RDNA3 integrated)
            # #
            if ($gpuName -match "Intel.*UHD|Intel.*HD|Intel.*Iris|Intel.*Graphics") {
                $gpuInfo.Type = "iGPU"
                $gpuInfo.Vendor = "Intel"
                $Script:HasiGPU = $true
                $Script:iGPUName = $gpuName
                Write-Host "  [GPU] Intel iGPU: $gpuName ($ramGB GB)" -ForegroundColor Cyan
            }
            # AMD APU - różne warianty nazewnictwa
            # "AMD Radeon Graphics", "AMD Radeon(TM) Graphics", "Radeon Vega 8", "Radeon 680M", "Radeon 780M"
            elseif ($gpuName -match "AMD.*Graphics|Radeon.*Graphics|Radeon.*Vega|Radeon\s+\d{3}M" -and $gpuName -notmatch "Radeon.*RX|Radeon.*Pro|Radeon.*VII") {
                # AMD APU (np. Ryzen z Vega/RDNA Graphics)
                $gpuInfo.Type = "iGPU"
                $gpuInfo.Vendor = "AMD"
                $Script:HasiGPU = $true
                $Script:iGPUName = $gpuName
                Write-Host "  [GPU] AMD iGPU (APU): $gpuName ($ramGB GB)" -ForegroundColor Cyan
            }
            # #
            # KLASYFIKACJA: dGPU (Dedykowana)
            # V40 FIX: Rozszerzone wzorce dla AMD dGPU (RX 6xxx, RX 7xxx, WX, W-series)
            # #
            elseif ($gpuName -match "NVIDIA|GeForce|RTX|GTX|Quadro|Tesla") {
                $gpuInfo.Type = "dGPU"
                $gpuInfo.Vendor = "NVIDIA"
                $gpuInfo.IsPrimary = $true  # NVIDIA = primary dla gier
                $Script:HasdGPU = $true
                $Script:dGPUName = $gpuName
                $Script:dGPUVendor = "NVIDIA"
                $Script:PrimaryGPU = $gpuInfo
                Write-Host "  [GPU] NVIDIA dGPU: $gpuName ($ramGB GB) PRIMARY" -ForegroundColor Green
            }
            elseif ($gpuName -match "Radeon\s*(RX|Pro|VII|WX|W\d)|AMD.*RX\s*\d{4}") {
                $gpuInfo.Type = "dGPU"
                $gpuInfo.Vendor = "AMD"
                $gpuInfo.IsPrimary = $true  # AMD dGPU = primary dla gier
                $Script:HasdGPU = $true
                $Script:dGPUName = $gpuName
                $Script:dGPUVendor = "AMD"
                $Script:PrimaryGPU = $gpuInfo
                Write-Host "  [GPU] AMD dGPU: $gpuName ($ramGB GB) PRIMARY" -ForegroundColor Green
            }
            else {
                # Nieznany GPU - spróbuj jeszcze raz dla AMD
                if ($gpuName -match "Radeon|AMD") {
                    # Prawdopodobnie AMD APU z niestandardową nazwą
                    $gpuInfo.Type = "iGPU"
                    $gpuInfo.Vendor = "AMD"
                    $Script:HasiGPU = $true
                    $Script:iGPUName = $gpuName
                    Write-Host "  [GPU] AMD iGPU (fallback): $gpuName ($ramGB GB)" -ForegroundColor Cyan
                } else {
                    $gpuInfo.Type = "Unknown"
                    Write-Host "  [GPU] Unknown GPU: $gpuName ($ramGB GB)" -ForegroundColor Yellow
                }
            }
            
            $Script:GPUList += $gpuInfo
        }
        
        # Podsumowanie
        if ($Script:HasiGPU -and $Script:HasdGPU) {
            Write-Host "  [GPU] Hybrid Graphics: iGPU + dGPU detected (switchable)" -ForegroundColor Magenta
        }
        elseif ($Script:HasdGPU) {
            Write-Host "  [GPU] Dedicated Graphics Only: $($Script:dGPUVendor)" -ForegroundColor Green
        }
        elseif ($Script:HasiGPU) {
            Write-Host "  [GPU] Integrated Graphics Only" -ForegroundColor Cyan
        }
        
        return $true
    }
    catch {
        $errorMsg = $_.Exception.Message
        Write-Host "  [GPU] Detection failed: $errorMsg" -ForegroundColor Red
        Write-ErrorLog -Component "ENGINE-GPU" -ErrorMessage "GPU Detection failed" -Details $errorMsg
        return $false
    }
}
# #
# PowerShell parses classes at compile time, so [Win32] must exist first
# #
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
$win32SignatureEarly = @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO {
    public uint cbSize;
    public uint dwTime;
}
public static class Win32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("kernel32.dll")]
    public static extern uint GetTickCount();
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("psapi.dll")]
    public static extern int EmptyWorkingSet(IntPtr hwProc);
    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtSuspendProcess(IntPtr processHandle);
    [DllImport("ntdll.dll", SetLastError = true)]
    public static extern int NtResumeProcess(IntPtr processHandle);
    // SetProcessWorkingSetSizeEx — HARD_MIN enforcement (nie tylko hint!)
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessWorkingSetSizeEx(
        IntPtr hProcess, IntPtr dwMinimumWorkingSetSize,
        IntPtr dwMaximumWorkingSetSize, uint Flags);
    public const uint QUOTA_LIMITS_HARDWS_MIN_ENABLE  = 0x00000001;
    public const uint QUOTA_LIMITS_HARDWS_MIN_DISABLE = 0x00000002;
    public const uint QUOTA_LIMITS_HARDWS_MAX_ENABLE  = 0x00000004;
    public const uint QUOTA_LIMITS_HARDWS_MAX_DISABLE = 0x00000008;
}
public static class ConsoleWindow {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("kernel32.dll")]
    public static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handler, bool add);
    public delegate bool ConsoleCtrlDelegate(int ctrlType);
    [DllImport("user32.dll")]
    public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);
    [DllImport("user32.dll")]
    public static extern bool DeleteMenu(IntPtr hMenu, uint uPosition, uint uFlags);
    public const uint SC_CLOSE = 0xF060;
    public const uint MF_BYCOMMAND = 0x00000000;
}
public static class IntelPowerAPI {
    // === Power Throttling (EcoQoS / Efficiency Mode) ===
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetProcessInformation(
        IntPtr hProcess, int ProcessInformationClass,
        IntPtr ProcessInformation, uint ProcessInformationSize);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
    
    // === Job Object CPU Rate Control ===
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetInformationJobObject(
        IntPtr hJob, int JobObjectInfoClass,
        IntPtr lpJobObjectInfo, uint cbJobObjectInfoLength);
    
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
    
    // Constants
    public const int ProcessPowerThrottling = 4;
    public const uint PROCESS_SET_INFORMATION = 0x0200;
    public const uint PROCESS_ALL_ACCESS = 0x1F0FFF;
    public const int JobObjectCpuRateControlInformation = 15;
    public const uint JOB_OBJECT_CPU_RATE_CONTROL_ENABLE = 0x1;
    public const uint JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP = 0x4;
}
'@
Add-Type -Language CSharp -TypeDefinition $win32SignatureEarly -ErrorAction Stop
}
# Helper function: SetProcessWorkingSetSizeEx z HARD_MIN flag
# Zdefiniowana po Add-Type — [Win32] dostępny w runtime, nie może być wewnątrz klasy (parse-time)
function Set-HardMinWorkingSet {
    param([IntPtr]$Handle, [long]$MinWS, [long]$MaxWS)
    try {
        # QUOTA_LIMITS_HARDWS_MIN_ENABLE = 0x1
        return [Win32]::SetProcessWorkingSetSizeEx($Handle, [IntPtr]$MinWS, [IntPtr]$MaxWS, [uint32]1)
    } catch { return $false }
}
# ═══════════════════════════════════════════════════════════════════════════════
# CACHE RELOCATOR - Cache Relocator zintegrowany z ENGINE
# ═══════════════════════════════════════════════════════════════════════════════
# ProBalance Class - Throttle High-CPU Processes
# #
# PERFORMANCE MONITORING - Frame Time & Stuttering Detection
# #