# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 05_Classes_AI_Core.ps1
# AI classes: FastMetrics, Forecaster, SystemGovernor, GPUBoundDetector, ProphetMemory, NeuralBrain, ProcessWatcher, AnomalyDetector, SelfTuner, ChainPredictor, ContextDetector, PhaseDetector, FanController, SharedAppKnowledge, ThermalPredictor, UserPatternLearner, AdaptiveTimer, SmartPriorityManager, ProBalance, PerformanceBooster, LoadPredictor, QLearningAgent, EnsembleVoter, EnergyTracker, AdaptiveThresholdManager, RAMAnalyzer, AICoordinator
# Lines 5548-12998 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
class FastMetrics {
    [System.Diagnostics.PerformanceCounter] $CpuCounter
    [System.Diagnostics.PerformanceCounter] $DiskCounter
    [double] $CachedTemp
    [int] $TempTick
    [int] $LastCPU
    [double] $LastIO
    [string] $TempSource
    [bool] $LHMAvailable
    [bool] $OHMAvailable
    [string] $LHMSensorPath
    [string] $ActiveDataSource  # LHM, OHM, SystemOnly
    #  Extended monitoring
    [hashtable] $GPU
    [hashtable] $VRM
    [hashtable] $PerCore
    [double] $RAMUsage
    [double] $CPUPower
    [double] $CPUClock
    [int] $ExtendedTick
    FastMetrics() {
        # Ustaw zrodla danych z globalnej detekcji
        $this.LHMAvailable = $Script:DataSourcesInfo.LHMAvailable
        $this.OHMAvailable = $Script:DataSourcesInfo.OHMAvailable
        $this.ActiveDataSource = $Script:DataSourcesInfo.ActiveSource
        try {
            $this.CpuCounter = [System.Diagnostics.PerformanceCounter]::new("Processor", "% Processor Time", "_Total")
            $this.DiskCounter = [System.Diagnostics.PerformanceCounter]::new("PhysicalDisk", "Disk Bytes/sec", "_Total")
            $null = $this.CpuCounter.NextValue()
            $null = $this.DiskCounter.NextValue()
        } catch {
            Write-Host "WARNING: Performance counters initialization failed: $_" -ForegroundColor Yellow
        }
        $this.CachedTemp = 0
        $this.TempTick = 0
        $this.LastCPU = 0
        $this.LastIO = 0.0
        $this.TempSource = "Unknown"
        $this.LHMSensorPath = ""
        #  Initialize extended
        $this.GPU = @{ Temp = 0; Load = 0; Power = 0; VRAM = 0; Name = "N/A"; Available = $false }
        $this.VRM = @{ Temp = 0; Available = $false }
        $this.PerCore = @{ Temps = @(); Loads = @(); Count = 0 }
        $this.RAMUsage = 0
        $this.CPUPower = 0
        $this.CPUClock = 0
        $this.ExtendedTick = 0
        $this.InitializeFromDetectedSources()
    }
    [void] InitializeFromDetectedSources() {
        # Ustaw TempSource na podstawie detekcji
        $metrics = $Script:DataSourcesInfo.AvailableMetrics
        if ($metrics.CPUTemp) {
            switch ($metrics.CPUTempSource) {
                "LHM" { $this.TempSource = "LibreHardwareMonitor" }
                "OHM" { $this.TempSource = "OpenHardwareMonitor" }
                "ACPI" { $this.TempSource = "WMI-ACPI" }
                default { $this.TempSource = "N/A" }
            }
        } else {
            $this.TempSource = "N/A"
        }
        # Sprawdz czy GPU jest dostepne
        if ($metrics.GPUTemp -or $metrics.GPULoad) {
            $this.GPU.Available = $true
        }
        # Pobierz poczatkowa temperature
        $this.UpdateTemperature()
    }
    [void] UpdateTemperature() {
        $metrics = $Script:DataSourcesInfo.AvailableMetrics
        switch ($metrics.CPUTempSource) {
            "LHM" {
                $newTemp = $this.GetTemperatureFromLHM()
                if ($newTemp -gt 0) { $this.CachedTemp = $newTemp }
            }
            "OHM" {
                $newTemp = $this.GetTemperatureFromOHM()
                if ($newTemp -gt 0) { $this.CachedTemp = $newTemp }
            }
            "ACPI" {
                $newTemp = $this.GetTemperatureFromACPI()
                if ($newTemp -gt 0) { $this.CachedTemp = $newTemp }
            }
        }
    }
    [double] GetTemperatureFromLHM() {
        try {
            $sensors = Get-LHMSensorsCached
            if ($sensors) {
                if (![string]::IsNullOrWhiteSpace($this.LHMSensorPath)) {
                    $sensor = $sensors | Where-Object { $_.Identifier -eq $this.LHMSensorPath } | Select-Object -First 1
                    if ($sensor -and $sensor.Value -gt 0) {
                        return [Math]::Round($sensor.Value, 1)
                    }
                }
                $cpuTemps = $sensors | Where-Object { 
                    $_.SensorType -eq "Temperature" -and 
                    ($_.Identifier -match "/cpu" -or $_.Name -match "CPU|Core|Package|Tctl|Tdie")
                }
                $amdTemp = $cpuTemps | Where-Object { $_.Name -match "Tdie|Tctl|Core \(Tctl" } | Select-Object -First 1
                if ($amdTemp -and $amdTemp.Value -gt 0) {
                    $this.LHMSensorPath = $amdTemp.Identifier
                    return [Math]::Round($amdTemp.Value, 1)
                }
                $packageTemp = $cpuTemps | Where-Object { $_.Name -match "Package" } | Select-Object -First 1
                if ($packageTemp -and $packageTemp.Value -gt 0) {
                    $this.LHMSensorPath = $packageTemp.Identifier
                    return [Math]::Round($packageTemp.Value, 1)
                }
                $anyTemp = $cpuTemps | Where-Object { $_.Value -gt 0 } | Select-Object -First 1
                if ($anyTemp) {
                    $this.LHMSensorPath = $anyTemp.Identifier
                    return [Math]::Round($anyTemp.Value, 1)
                }
            }
        } catch { }
        return $this.CachedTemp
    }
    [double] GetTemperatureFromOHM() {
        try {
            $sensors = Get-OHMSensorsCached
            if ($sensors) {
                $cpuTemp = $sensors | Where-Object { 
                    $_.SensorType -eq "Temperature" -and 
                    ($_.Identifier -match "/cpu" -or $_.Name -match "CPU|Core|Package")
                } | Where-Object { $_.Value -gt 0 } | Select-Object -First 1
                if ($cpuTemp) {
                    return [Math]::Round($cpuTemp.Value, 1)
                }
            }
        } catch { }
        return $this.CachedTemp
    }
    [double] GetTemperatureFromACPI() {
        try {
            $thermalZone = Get-ACPIThermalCached
            if ($thermalZone -and $thermalZone.CurrentTemperature) {
                $tempKelvin = $thermalZone.CurrentTemperature / 10
                $tempCelsius = [Math]::Round($tempKelvin - 273.15, 1)
                if ($tempCelsius -gt 0 -and $tempCelsius -lt 120) {
                    return $tempCelsius
                }
            }
        } catch { }
        return $this.CachedTemp
    }
    [hashtable] Get() {
        $cpu = 0
        $io = 0.0
        $metrics = $Script:DataSourcesInfo.AvailableMetrics
        # === CPU Load ===
        $cpu = $null
        $cpuSource = ""
        # Najpierw LHM
        if ($this.LHMAvailable) {
            try {
                $sensors = Get-LHMSensorsCached
                $cpuLoad = $sensors | Where-Object { $_.SensorType -eq "Load" -and $_.Name -eq "CPU Total" } | Select-Object -First 1
                if ($cpuLoad) {
                    $cpu = [Math]::Round($cpuLoad.Value)
                    $cpuSource = "LHM"
                    $this.LastCPU = $cpu
                }
            } catch {}
        }
        # Potem OHM jesli nie ma z LHM
        if (-not $cpu -and $this.OHMAvailable) {
            try {
                $sensors = Get-OHMSensorsCached
                $cpuLoad = $sensors | Where-Object { $_.SensorType -eq "Load" -and $_.Name -eq "CPU Total" } | Select-Object -First 1
                if ($cpuLoad) {
                    $cpu = [Math]::Round($cpuLoad.Value)
                    $cpuSource = "OHM"
                    $this.LastCPU = $cpu
                }
            } catch {}
        }
        # Potem PerfCounter jesli nie ma z LHM/OHM
        if (-not $cpu -and $this.CpuCounter) {
            try {
                $cpu = [Math]::Round($this.CpuCounter.NextValue())
                $cpuSource = "PerfCounter"
                $this.LastCPU = $cpu
            } catch {}
        }
        # Jesli nadal brak, ustaw N/A
        if (-not $cpu) {
            $cpu = $null
            $cpuSource = "N/A"
        }
        # === Disk I/O ===
        if ($metrics.DiskIOSource -eq "PerfCounter" -and $this.DiskCounter) { 
            try { 
                $io = [Math]::Round($this.DiskCounter.NextValue() / 1MB, 1)
                $this.LastIO = $io
            } catch { 
                $io = $this.LastIO 
            }
        } elseif ($metrics.DiskIOSource -eq "WMI") {
            try {
                $diskPerf = Get-DiskPerfCached
                if ($diskPerf) { 
                    $io = [Math]::Round($diskPerf.DiskBytesPersec / 1MB, 1)
                    $this.LastIO = $io 
                }
            } catch { $io = $this.LastIO }
        } else {
            $io = $this.LastIO
        }
        # === Temperature (co 5 cykli) ===
        $this.TempTick++
        if ($this.TempTick -ge 5) {
            $this.TempTick = 0
            $this.UpdateTemperature()
        }
        return @{ 
            CPU = if ($cpu -ne $null) { [Math]::Max(0, [Math]::Min(100, $cpu)) } else { $null }
            CPUSource = $cpuSource
            IO = [Math]::Max(0.0, $io)
            Temp = $this.CachedTemp
            TempSource = $this.TempSource
            DataSource = $this.ActiveDataSource
        }
    }
    [void] Cleanup() {
        if ($this.CpuCounter) {
            try { $this.CpuCounter.Dispose() } catch { }
            $this.CpuCounter = $null
        }
        if ($this.DiskCounter) {
            try { $this.DiskCounter.Dispose() } catch { }
            $this.DiskCounter = $null
        }
    }
    #  Extended metrics - wspiera LHM, OHM i System fallback
    [void] UpdateExtendedMetrics() {
        $this.ExtendedTick++
        if ($this.ExtendedTick -lt 5) { return }  #  v39.18: Co 5 cykli (~4 sek, bylo 3) - mniej WMI calls
        $this.ExtendedTick = 0
        $metrics = $Script:DataSourcesInfo.AvailableMetrics
        $sensors = $null
        # Pobierz sensory z dostepnego zrodla
        if ($this.LHMAvailable) {
            $sensors = Get-LHMSensorsCached
        } elseif ($this.OHMAvailable) {
            $sensors = Get-OHMSensorsCached
        }
        # === GPU Monitoring ===
        # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
        # FIX v40.1c: Zawsze próbuj odczytać GPU Temp jeśli są sensory (nie polegaj na detekcji)
        if ($sensors) {
            try {
                $gpuTemp = $sensors | Where-Object { 
                    $_.SensorType -eq "Temperature" -and 
                    ($_.Identifier -match "gpu" -or 
                     ($_.Identifier -match "/amdcpu" -and $_.Name -match "GPU|Graphics"))
                } | Select-Object -First 1
                if ($gpuTemp) { 
                    $this.GPU.Temp = [Math]::Round($gpuTemp.Value, 1)
                    $this.GPU.Available = $true
                }
            } catch { }
        }
        # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
        # FIX v40.1b: Preferuj "GPU Core" nad "GPU Frame Buffer" - sortuj by Name
        # FIX v40.1c: Zawsze próbuj odczytać GPU Load jeśli są sensory (nie polegaj na detekcji)
        # FIX v40.3: Bierz MAKSYMALNE obciążenie GPU (GPU Core często = 0, ale Frame Buffer ma wartość)
        if ($sensors) {
            try {
                $gpuLoads = $sensors | Where-Object { 
                    $_.SensorType -eq "Load" -and 
                    (($_.Identifier -match "gpu" -and $_.Name -match "Core|GPU|Frame|Memory") -or
                     ($_.Identifier -match "/amdcpu" -and $_.Name -match "GPU|Graphics"))
                }
                if ($gpuLoads) {
                    # Weź maksymalne obciążenie z wszystkich sensorów GPU
                    $maxLoad = ($gpuLoads | Measure-Object -Property Value -Maximum).Maximum
                    if ($maxLoad -gt 0) {
                        $this.GPU.Load = [Math]::Round($maxLoad, 0)
                        $this.GPU.Available = $true
                        # Zapisz też nazwę sensora z max load (dla debugowania)
                        $maxSensor = $gpuLoads | Where-Object { $_.Value -eq $maxLoad } | Select-Object -First 1
                        if ($maxSensor) { $this.GPU.Name = $maxSensor.Name }
                    }
                }
            } catch { }
        }
        # FIX v40.1: Fallback - WMI GPU Engine monitoring (Windows 10/11)
        # Działa gdy LibreHardwareMonitor nie dostarcza danych GPU
        if ($this.GPU.Load -eq 0) {
            try {
                # Użyj Performance Counter API dla GPU Engine
                $gpuCounters = Get-CimInstance -Namespace "root\CIMV2" -Query "SELECT Name, UtilizationPercentage FROM Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine WHERE EngineType='3D'" -ErrorAction SilentlyContinue
                if ($gpuCounters) {
                    # Suma utilization dla wszystkich silników 3D
                    $totalUtil = ($gpuCounters | Measure-Object -Property UtilizationPercentage -Sum).Sum
                    $engineCount = ($gpuCounters | Measure-Object).Count
                    if ($engineCount -gt 0 -and $totalUtil -gt 0) {
                        # Średnie użycie z wszystkich silników
                        $avgUtil = [Math]::Min(100, [Math]::Round($totalUtil / $engineCount, 0))
                        $this.GPU.Load = $avgUtil
                        $this.GPU.Available = $true
                    }
                }
            } catch { }
        }
        # FIX v40.1: Dodatkowy fallback - nvidia-smi dla NVIDIA GPU
        if ($this.GPU.Load -eq 0 -and $Script:dGPUVendor -eq "NVIDIA") {
            try {
                $nvsmi = & nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>$null
                if ($nvsmi -and $nvsmi -match '^\d+$') {
                    $this.GPU.Load = [int]$nvsmi
                    $this.GPU.Available = $true
                }
            } catch { }
        }
        # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
        if ($metrics.GPUPower -and $sensors) {
            try {
                $gpuPower = $sensors | Where-Object { 
                    $_.SensorType -eq "Power" -and 
                    ($_.Identifier -match "gpu" -or 
                     ($_.Identifier -match "/amdcpu" -and $_.Name -match "GPU|Graphics|SOC"))
                } | Select-Object -First 1
                if ($gpuPower) { $this.GPU.Power = [Math]::Round($gpuPower.Value, 1) }
            } catch { }
        }
        # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
        if ($metrics.GPUVRAM -and $sensors) {
            try {
                $gpuVRAM = $sensors | Where-Object { 
                    $_.SensorType -eq "SmallData" -and 
                    ($_.Identifier -match "gpu" -and $_.Name -match "Memory Used")
                } | Select-Object -First 1
                if ($gpuVRAM) { $this.GPU.VRAM = [Math]::Round($gpuVRAM.Value, 0) }
            } catch { }
        }
        # GPU Name
        if ($this.LHMAvailable) {
            try {
                $gpuHw = Get-LHMHardwareCached | Where-Object { $_.HardwareType -match "Gpu" } | Select-Object -First 1
                if ($gpuHw) { 
                    $this.GPU.Name = $gpuHw.Name 
                } else {
                    $cpuHw = Get-LHMHardwareCached | Where-Object { $_.HardwareType -match "Cpu" } | Select-Object -First 1
                    if ($cpuHw -and $cpuHw.Name -match "AMD") {
                        $this.GPU.Name = "AMD APU (integrated)"
                    }
                }
            } catch { }
        }
        # === VRM / Motherboard Temp ===
        if ($metrics.VRMTemp -and $sensors) {
            try {
                $vrmTemp = $sensors | Where-Object { 
                    $_.SensorType -eq "Temperature" -and 
                    ($_.Name -match "VRM|Motherboard|System|Chipset|PCH" -or $_.Identifier -match "/lpc/")
                } | Sort-Object Value -Descending | Select-Object -First 1
                if ($vrmTemp -and $vrmTemp.Value -gt 0) {
                    $this.VRM.Temp = [Math]::Round($vrmTemp.Value, 1)
                    $this.VRM.Available = $true
                }
            } catch { }
        }
        # === Per-Core Temps ===
        if ($metrics.PerCoreTemp -and $sensors) {
            try {
                $coreTemps = $sensors | Where-Object { 
                    $_.SensorType -eq "Temperature" -and 
                    $_.Identifier -match "/cpu" -and 
                    $_.Name -match "Core #\d+"
                } | Sort-Object { [int]($_.Name -replace '\D','') }
                if ($coreTemps) {
                    $this.PerCore.Temps = @($coreTemps | ForEach-Object { [Math]::Round($_.Value, 1) })
                    $this.PerCore.Count = $coreTemps.Count
                }
            } catch { }
        }
        # === Per-Core Loads ===
        if ($metrics.PerCoreLoad -and $sensors) {
            try {
                $coreLoads = $sensors | Where-Object { 
                    $_.SensorType -eq "Load" -and 
                    $_.Identifier -match "/cpu" -and 
                    $_.Name -match "CPU Core #\d+"
                } | Sort-Object { [int]($_.Name -replace '\D','') }
                if ($coreLoads) {
                    $this.PerCore.Loads = @($coreLoads | ForEach-Object { [Math]::Round($_.Value, 0) })
                }
            } catch { }
        }
        # === CPU Power ===
        if ($metrics.CPUPower -and $sensors) {
            try {
                $cpuPwrSensor = $sensors | Where-Object { 
                    $_.SensorType -eq "Power" -and 
                    $_.Identifier -match "/cpu" -and 
                    $_.Name -match "Package|CPU Package|Core"
                } | Select-Object -First 1
                if ($cpuPwrSensor) { $this.CPUPower = [Math]::Round($cpuPwrSensor.Value, 1) }
            } catch { }
        }
        # === CPU Clock ===
        if ($metrics.CPUClock) {
            try {
                if ($metrics.CPUClockSource -eq "LHM" -and $sensors) {
                    $cpuClocks = $sensors | Where-Object { 
                        $_.SensorType -eq "Clock" -and $_.Identifier -match "/cpu" -and $_.Name -match "Core" -and $_.Value -gt 100
                    }
                    if ($cpuClocks -and $cpuClocks.Count -gt 0) {
                        $avgClock = ($cpuClocks | Measure-Object -Property Value -Average).Average
                        $this.CPUClock = [Math]::Round($avgClock, 0)
                    }
                } elseif ($metrics.CPUClockSource -eq "OHM" -and $sensors) {
                    $cpuClocks = $sensors | Where-Object { 
                        $_.SensorType -eq "Clock" -and $_.Identifier -match "/cpu" -and $_.Name -match "Core" -and $_.Value -gt 100
                    }
                    if ($cpuClocks -and $cpuClocks.Count -gt 0) {
                        $avgClock = ($cpuClocks | Measure-Object -Property Value -Average).Average
                        $this.CPUClock = [Math]::Round($avgClock, 0)
                    }
                } elseif ($metrics.CPUClockSource -eq "WMI") {
                    $perfData = Get-ProcessorPerfCached  #  v39.3: Cached (bylo niebuforowane!)
                    $cpuWmi = Get-CPUInfoCached
                    if ($cpuWmi -and $perfData -and $perfData.PercentProcessorPerformance -gt 0) {
                        $this.CPUClock = [Math]::Round($cpuWmi.MaxClockSpeed * $perfData.PercentProcessorPerformance / 100, 0)
                    }
                } elseif ($metrics.CPUClockSource -eq "Registry") {
                    $regMHz = (Get-ItemProperty -Path "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -Name "~MHz" -ErrorAction SilentlyContinue)."~MHz"
                    if ($regMHz -gt 100) { $this.CPUClock = [int]$regMHz }
                }
            } catch { }
        }
        # === RAM Usage ===
        if ($metrics.RAMUsage) {
            try {
                if ($metrics.RAMUsageSource -eq "LHM" -and $sensors) {
                    $ramLoad = $sensors | Where-Object { $_.SensorType -eq "Load" -and $_.Name -match "Memory" } | Select-Object -First 1
                    if ($ramLoad) { $this.RAMUsage = [Math]::Round($ramLoad.Value, 0) }
                } else {
                    # WMI fallback
                    $os = Get-OSCached
                    if ($os -and $os.TotalVisibleMemorySize -gt 0) {
                        $this.RAMUsage = [Math]::Round((1 - ($os.FreePhysicalMemory / $os.TotalVisibleMemorySize)) * 100, 0)
                    }
                }
            } catch { }
        }
    }
    [hashtable] GetExtended() {
        $basic = $this.Get()
        $this.UpdateExtendedMetrics()
        return @{
            # Basic
            CPU = $basic.CPU
            IO = $basic.IO
            Temp = $basic.Temp
            TempSource = $basic.TempSource
            DataSource = $this.ActiveDataSource
            # Extended
            GPU = $this.GPU.Clone()
            VRM = $this.VRM.Clone()
            PerCore = @{
                Temps = $this.PerCore.Temps
                Loads = $this.PerCore.Loads
                Count = $this.PerCore.Count
            }
            RAMUsage = $this.RAMUsage
            CPUPower = $this.CPUPower
            CPUClock = $this.CPUClock
            # Info o dostepnosci metryk
            AvailableMetrics = $Script:DataSourcesInfo.AvailableMetrics
        }
    }
    # Metoda do wyswietlenia statusu zrodel danych
    [string] GetDataSourceStatus() {
        $metrics = $Script:DataSourcesInfo.AvailableMetrics
        $available = @()
        $unavailable = @()
        if ($metrics.CPUTemp) { $available += "CPU Temp ($($metrics.CPUTempSource))" } else { $unavailable += "CPU Temp" }
        if ($metrics.CPULoad) { $available += "CPU Load ($($metrics.CPULoadSource))" } else { $unavailable += "CPU Load" }
        if ($metrics.CPUClock) { $available += "CPU Clock ($($metrics.CPUClockSource))" } else { $unavailable += "CPU Clock" }
        if ($metrics.CPUPower) { $available += "CPU Power ($($metrics.CPUPowerSource))" } else { $unavailable += "CPU Power" }
        if ($metrics.GPUTemp) { $available += "GPU Temp ($($metrics.GPUTempSource))" } else { $unavailable += "GPU Temp" }
        if ($metrics.RAMUsage) { $available += "RAM ($($metrics.RAMUsageSource))" } else { $unavailable += "RAM" }
        if ($metrics.DiskIO) { $available += "Disk I/O ($($metrics.DiskIOSource))" } else { $unavailable += "Disk I/O" }
        if ($metrics.FanRPM) { $available += "Fan RPM ($($metrics.FanRPMSource))" } else { $unavailable += "Fan RPM" }
        if ($metrics.FanControl) { $available += "Fan Control ($($metrics.FanControlSource))" }
        $status = "Zrodlo: $($this.ActiveDataSource)`n"
        $status += "Dostepne: $($available -join ', ')`n"
        if ($unavailable.Count -gt 0) {
            $status += "Niedostepne: $($unavailable -join ', ')"
        }
        return $status
    }
}
# --- Funkcja pomocnicza do wyswietlenia podsumowania zrodel ---
function Show-DataSourcesSummary {
    if (-not $Script:DataSourcesInfo.DetectionDone) {
        Write-Host "  [WARN] Detekcja zrodel nie zostala przeprowadzona" -ForegroundColor Yellow
        return
    }
    $info = $Script:DataSourcesInfo
    $metrics = $info.AvailableMetrics
    Write-Host ""
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    Write-Host "  |         STATUS ZRODEL DANYCH                    |" -ForegroundColor Cyan
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    $srcIcon = switch($info.ActiveSource) {
        "LHM" { "" }
        "OHM" { "" }
        "SystemOnly" { "" }
        default { "?" }
    }
    Write-Host "  | Aktywne: $srcIcon $($info.ActiveSource)" -ForegroundColor White
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    $items = @(
        @{ N="CPU Temp"; V=$metrics.CPUTemp; S=$metrics.CPUTempSource },
        @{ N="CPU Load"; V=$metrics.CPULoad; S=$metrics.CPULoadSource },
        @{ N="CPU Clock"; V=$metrics.CPUClock; S=$metrics.CPUClockSource },
        @{ N="CPU Power"; V=$metrics.CPUPower; S=$metrics.CPUPowerSource },
        @{ N="GPU Temp"; V=$metrics.GPUTemp; S=$metrics.GPUTempSource },
        @{ N="GPU Load"; V=$metrics.GPULoad; S=$metrics.GPULoadSource },
        @{ N="RAM"; V=$metrics.RAMUsage; S=$metrics.RAMUsageSource },
        @{ N="Disk I/O"; V=$metrics.DiskIO; S=$metrics.DiskIOSource }
    )
    foreach ($item in $items) {
        $icon = if ($item.V) { "?" } else { "?" }
        $color = if ($item.V) { "Green" } else { "DarkGray" }
        Write-Host ("  | {0,-12} [{1}] {2,-12}" -f $item.N, $icon, $item.S) -ForegroundColor $color
    }
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""
}
# FORECASTER - Dynamiczna predykcja trendu CPU
class Forecaster {
    [double[]] $Buffer
    [int] $Index
    [int] $Count
    [int] $Size
    Forecaster() { 
        $this.Size = 15  # Większy bufor dla stabilniejszej predykcji (8-step ahead wymaga więcej danych)
        $this.Buffer = [double[]]::new($this.Size)
        $this.Index = 0
        $this.Count = 0 
    }
    [void] Add([double]$value) { 
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return }
        $this.Buffer[$this.Index] = $value
        $this.Index = ($this.Index + 1) % $this.Size
        if ($this.Count -lt $this.Size) { $this.Count++ }
    }
    [double] Trend() {
        if ($this.Count -lt 3) { return 0.0 }
        # POPRAWKA: Odczytuj dane w prawidłowej kolejności czasowej z circular buffer
        $sumX = 0.0; $sumY = 0.0; $sumXY = 0.0; $sumX2 = 0.0
        for ($i = 0; $i -lt $this.Count; $i++) { 
            # Prawidłowy indeks: najstarsza wartość jest na (Index - Count + Size) % Size
            $bufferIdx = ($this.Index - $this.Count + $i + $this.Size) % $this.Size
            $y = $this.Buffer[$bufferIdx]
            $sumX += $i; $sumY += $y; $sumXY += ($i * $y); $sumX2 += ($i * $i) 
        }
        $denominator = ($this.Count * $sumX2) - ($sumX * $sumX)
        if ([Math]::Abs($denominator) -lt 0.0001) { return 0.0 }
        $trend = (($this.Count * $sumXY) - ($sumX * $sumY)) / $denominator
        if ([double]::IsNaN($trend) -or [double]::IsInfinity($trend)) { return 0.0 }
        return [double]$trend
    }
    # Nowa metoda: Przewidz CPU za N iteracji
    [double] Predict([int]$stepsAhead) {
        if ($this.Count -lt 2) { return 0.0 }
        $trend = $this.Trend()
        # Ostatnia wartość
        $lastIdx = ($this.Index - 1 + $this.Size) % $this.Size
        $lastValue = $this.Buffer[$lastIdx]
        $predicted = $lastValue + ($trend * $stepsAhead)
        return [Math]::Max(0, [Math]::Min(100, $predicted))
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM GOVERNOR v44.0 - ENGINE przejmuje kontrolę od Windows
# Zarządza: CPU power, GPU/iGPU preferences, procesami, power planami
# Połączony z AILearning: uczy się GPU preferencji per-app, zapisuje do snapshot
# ═══════════════════════════════════════════════════════════════════════════════
class SystemGovernor {
    [string] $CurrentMode = "Balanced"
    [bool] $IsOverloaded = $false
    [bool] $IsGoverning = $true
    [datetime] $LastGovernAction = [datetime]::MinValue
    [int] $GovernIntervalSeconds = 3
    [int] $TotalGovernActions = 0
    [bool] $HasiGPU = $false
    [bool] $HasdGPU = $false
    [string] $iGPUName = ""
    [string] $dGPUName = ""
    [hashtable] $GPUPreferences = @{}
    [hashtable] $LearnedGPUPrefs = @{}
    [string] $GPUPrefsRegPath = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"
    [string] $GraphicsSettingsPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GraphicsSettings"
    [int] $GPUPrefChanges = 0
    [bool] $PowerOverrideActive = $false
    [string] $EnginePowerPlanGUID = ""
    [bool] $CoreParkingDisabled = $false
    [hashtable] $ActiveOverrides = @{}
    [hashtable] $AppBehaviorHistory = @{}
    [double] $OverloadThreshold = 78.0
    [int] $MaxAffinityProcesses = 15
    [System.Collections.Generic.List[string]] $GovernLog

    SystemGovernor() {
        $this.GovernLog = [System.Collections.Generic.List[string]]::new()
    }

    [void] Initialize([bool]$hasiGPU, [bool]$hasdGPU, [string]$iGPUName, [string]$dGPUName) {
        $this.HasiGPU = $hasiGPU; $this.HasdGPU = $hasdGPU
        $this.iGPUName = $iGPUName; $this.dGPUName = $dGPUName
        $this.TakeOverPowerPlan()
        $this.DisableCoreParkingIfNeeded()
        $this.Log("SystemGovernor INIT: iGPU=$hasiGPU dGPU=$hasdGPU")
    }

    # ─── GŁÓWNA METODA - wywoływana co 3s z main loop ───
    [hashtable] Govern([double]$cpuPct, [double]$gpuLoad, [double]$temp, [string]$fgApp, [string]$mode, [hashtable]$procMetrics) {
        $result = @{ ModeOverride = $null; ProcessActions = @(); GPUAction = $null; IsOverloaded = $false; OverloadReason = ""; GovernedProcesses = 0 }
        if (((Get-Date) - $this.LastGovernAction).TotalSeconds -lt $this.GovernIntervalSeconds) { return $result }
        $this.LastGovernAction = Get-Date; $this.CurrentMode = $mode

        # 1. OVERLOAD DETECTION
        $ovr = $this.DetectOverload($cpuPct, $gpuLoad, $temp, $fgApp, $procMetrics)
        $result.IsOverloaded = $ovr.IsOverloaded; $result.OverloadReason = $ovr.Reason; $this.IsOverloaded = $ovr.IsOverloaded
        if ($ovr.IsOverloaded) { $result.ModeOverride = $ovr.SuggestedMode; $result.ProcessActions = $ovr.Actions }

        # 2. GPU/iGPU GOVERNANCE
        if ($this.HasiGPU -or $this.HasdGPU) {
            $gpuR = $this.GovernGPU($fgApp, $cpuPct, $gpuLoad)
            if ($gpuR.Action) { $result.GPUAction = $gpuR }
        }

        # 3. PROCESS GOVERNANCE (priorytety, affinity)
        $procR = $this.GovernProcesses($fgApp, $cpuPct, $mode, $procMetrics)
        $result.ProcessActions += $procR.Actions; $result.GovernedProcesses = $procR.GovernedCount

        # 4. POWER PLAN - USUNIĘTE: Set-PowerMode jest jedynym autorytetem dla powercfg
        # EnforcePowerSettings powodowało konflikty - nadpisywało EPP, Min/Max CPU%,
        # boost mode ustawione przez Set-PowerMode, co blokowało poprawne działanie

        # 5. LEARN (zbieraj dane o zachowaniu aplikacji)
        $this.LearnAppBehavior($fgApp, $cpuPct, $gpuLoad)

        $this.TotalGovernActions++
        return $result
    }

    # ─── OVERLOAD DETECTION ───
    [hashtable] DetectOverload([double]$cpu, [double]$gpuLoad, [double]$temp, [string]$fgApp, [hashtable]$procMetrics) {
        $r = @{ IsOverloaded = $false; Reason = ""; SuggestedMode = $null; Actions = @() }
        # THERMAL EMERGENCY: >80°C → force Silent (v40.3: obniżone z 92 — nie czekaj na wentylatory)
        if ($temp -gt 80) {
            $r.IsOverloaded = $true; $r.Reason = "THERMAL: ${temp}C"; $r.SuggestedMode = "Silent"
            $r.Actions += @{ Type = "ThrottleAll"; Exclude = $fgApp; Priority = "Idle" }
            $this.Log("[CRITICAL] THERMAL $temp C"); return $r
        }
        # CPU OVERLOAD: >85% → throttle hogs
        if ($cpu -gt $this.OverloadThreshold) {
            $r.IsOverloaded = $true; $r.Reason = "CPU: $([int]$cpu)%"
            if ($procMetrics) {
                foreach ($k in $procMetrics.Keys) {
                    $pm = $procMetrics[$k]
                    if ($pm.Name -ne $fgApp -and $pm.CPU -gt 50) {
                        $r.Actions += @{ Type = "ThrottleProcess"; Name = $pm.Name; PID = $pm.PID; Priority = "BelowNormal" }
                    }
                }
            }
            if ($cpu -gt 90) { $r.SuggestedMode = "Turbo"; $r.Actions += @{ Type = "ThrottleAll"; Exclude = $fgApp; Priority = "BelowNormal" } }
        }
        # COMBINED: CPU>60 + GPU>70 + Temp>72 → throttle before fans (v40.3: obniżone)
        if ($cpu -gt 60 -and $gpuLoad -gt 70 -and $temp -gt 72) {
            $r.IsOverloaded = $true; $r.Reason = "COMBINED: CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% T=${temp}C"
            if (-not $r.SuggestedMode) { $r.SuggestedMode = "Balanced" }
        }
        return $r
    }

    # ─── GPU/iGPU GOVERNANCE ───
    [hashtable] GovernGPU([string]$fgApp, [double]$cpu, [double]$gpuLoad) {
        $r = @{ Action = $null; App = $fgApp; GPU = ""; Reason = "" }
        if ([string]::IsNullOrWhiteSpace($fgApp) -or $fgApp -in @("Desktop","explorer","ShellExperienceHost")) { return $r }
        $al = $fgApp.ToLower()
        if (-not ($this.HasdGPU -and $this.HasiGPU)) { return $r }
        $targetGPU = "Auto"; $reason = ""

        # 1. Learned preference (confidence > 0.7, sessions > 5)
        $learned = if ($this.LearnedGPUPrefs.ContainsKey($al)) { $this.LearnedGPUPrefs[$al] } else { $null }
        if ($learned -and $learned.Confidence -gt 0.7 -and $learned.Sessions -gt 5) {
            $targetGPU = $learned.Pref; $reason = "Learned: $targetGPU"
        } else {
            # 2. Behavior-based AI decision
            $beh = if ($this.AppBehaviorHistory.ContainsKey($al)) { $this.AppBehaviorHistory[$al] } else { $null }
            if ($beh -and $beh.Sessions -gt 3) {
                if ($beh.NeedsGPU -and $beh.AvgGPU -gt 40) { $targetGPU = "dGPU"; $reason = "AI: High GPU → dGPU" }
                elseif ($beh.AvgGPU -lt 15 -and $beh.AvgCPU -lt 30) { $targetGPU = "iGPU"; $reason = "AI: Light → iGPU" }
            } else {
                # 3. Heuristic fallback
                $browsers = @("chrome","firefox","msedge","opera","brave")
                if ($al -in $browsers) { $targetGPU = if ($gpuLoad -gt 50) { "dGPU" } else { "iGPU" }; $reason = "Browser heuristic" }
            }
        }

        if ($targetGPU -ne "Auto") {
            $cur = if ($this.GPUPreferences.ContainsKey($al)) { $this.GPUPreferences[$al] } else { "Auto" }
            if ($cur -ne $targetGPU) {
                $r.Action = "SetGPUPreference"; $r.GPU = $targetGPU; $r.Reason = $reason
                $this.ApplyGPUPreference($fgApp, $targetGPU)
                $this.GPUPreferences[$al] = $targetGPU
            }
        }
        return $r
    }

    [void] ApplyGPUPreference([string]$appName, [string]$gpuPref) {
        try {
            $exePath = $null
            try { $proc = Get-Process -Name $appName -ErrorAction SilentlyContinue | Select-Object -First 1; if ($proc) { $exePath = $proc.Path; $proc.Dispose() } } catch {}
            if (-not $exePath) { return }
            $gpuVal = switch ($gpuPref) { "iGPU" { 1 } "dGPU" { 2 } default { 0 } }
            try {
                if (-not (Test-Path $this.GraphicsSettingsPath)) { New-Item -Path $this.GraphicsSettingsPath -Force -ErrorAction SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $this.GraphicsSettingsPath -Name $exePath -Value "GpuPreference=$gpuVal" -Type String -Force -ErrorAction SilentlyContinue
            } catch {}
            try {
                if (-not (Test-Path $this.GPUPrefsRegPath)) { New-Item -Path $this.GPUPrefsRegPath -Force -ErrorAction SilentlyContinue | Out-Null }
                Set-ItemProperty -Path $this.GPUPrefsRegPath -Name $exePath -Value "GpuPreference=$gpuVal;" -Type String -Force -ErrorAction SilentlyContinue
            } catch {}
            $this.GPUPrefChanges++; $this.Log("[GPU] $appName → $gpuPref")
        } catch {}
    }

    # ─── PROCESS GOVERNANCE ───
    [hashtable] GovernProcesses([string]$fgApp, [double]$cpu, [string]$mode, [hashtable]$procMetrics) {
        $r = @{ Actions = @(); GovernedCount = 0 }
        try {
            # Foreground boost
            if ($fgApp -and $fgApp -notin @("Desktop","explorer","ShellExperienceHost","SearchHost")) {
                $tgt = switch ($mode) { "Turbo" { [System.Diagnostics.ProcessPriorityClass]::High } "Silent" { [System.Diagnostics.ProcessPriorityClass]::Normal } default { [System.Diagnostics.ProcessPriorityClass]::AboveNormal } }
                $fps = Get-Process -Name $fgApp -ErrorAction SilentlyContinue
                foreach ($fp in $fps) { try { if ($fp.PriorityClass -ne $tgt) { $fp.PriorityClass = $tgt; $r.GovernedCount++ }; $fp.Dispose() } catch { try { $fp.Dispose() } catch {} } }
            }
            # Background demotion in overload/Silent — skip when Audio/DAW active (would cause buffer underruns)
            if (($this.IsOverloaded -or $mode -eq "Silent") -and $Script:CurrentAppContext -ne "Audio") {
                $bgPri = if ($this.IsOverloaded) { [System.Diagnostics.ProcessPriorityClass]::Idle } else { [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
                $protected = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($p in @("System","Idle","Registry","smss","csrss","wininit","services","lsass","winlogon","svchost","dwm","explorer","audiodg","ctfmon","MsMpEng","powershell","pwsh","CPUManager","RuntimeBroker","ShellExperienceHost","ApplicationFrameHost","TextInputHost","ShellHost","sihost","taskhostw","dllhost")) { [void]$protected.Add($p) }
                $bgs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -ne $fgApp -and -not $protected.Contains($_.ProcessName) -and $_.WorkingSet64 -gt 50MB -and $_.PriorityClass -notin @([System.Diagnostics.ProcessPriorityClass]::Idle,[System.Diagnostics.ProcessPriorityClass]::BelowNormal) } | Sort-Object WorkingSet64 -Descending | Select-Object -First 10
                foreach ($bp in $bgs) { try { $bp.PriorityClass = $bgPri; $this.ActiveOverrides[$bp.Id] = @{ Name = $bp.ProcessName; AppliedAt = Get-Date }; $r.GovernedCount++; $bp.Dispose() } catch { try { $bp.Dispose() } catch {} } }
            }
            # Restore when calm
            if (-not $this.IsOverloaded -and $mode -ne "Silent" -and $this.ActiveOverrides.Count -gt 0) {
                foreach ($pid in @($this.ActiveOverrides.Keys)) {
                    try { $p = Get-Process -Id $pid -ErrorAction SilentlyContinue; if ($p) { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal; $p.Dispose() } } catch {}
                    $this.ActiveOverrides.Remove($pid)
                }
            }
        } catch {}
        return $r
    }

    # ─── WINDOWS POWER TAKEOVER ───
    [void] TakeOverPowerPlan() {
        try {
            $out = powercfg /getactivescheme 2>$null
            if ($out -match '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') { $this.EnginePowerPlanGUID = $matches[1] }
            if ($this.EnginePowerPlanGUID) {
                $g = $this.EnginePowerPlanGUID; $s = "54533251-82be-4824-96c1-47b60b740d00"
                # CRITICAL FIX: Autonomous Mode musi byc ON (1) dla Intel Speed Shift!
                # Gdy OFF (0), procesor NIE schodzi ponizej bazowej czestotliwosci
                powercfg /setacvalueindex $g $s "8baa4a8a-14c6-4451-8e8b-14bdbd197537" 1 2>$null  # Autonomous mode ON
                powercfg /setdcvalueindex $g $s "8baa4a8a-14c6-4451-8e8b-14bdbd197537" 1 2>$null
                powercfg /setacvalueindex $g $s "4d2b0152-7d5c-498b-88e2-34345392a2c5" 5000 2>$null  # Check interval 5s
                powercfg /setacvalueindex $g $s "619b7505-003b-4e82-b7a6-4dd29c300971" 0 2>$null  # Latency = performance
                powercfg /setactive $g 2>$null
                $this.PowerOverrideActive = $true; $this.Log("[POWER] Autonomous mode ENABLED - Intel Speed Shift active")
            }
        } catch {}
    }

    [void] DisableCoreParkingIfNeeded() {
        # Core parking jest teraz zarządzane dynamicznie przez EnforcePowerSettings() per-mode
        # Nie wymuszamy 100% na starcie - to blokowałoby oszczędzanie energii w Silent
        $this.CoreParkingDisabled = $false
    }

    [void] EnforcePowerSettings([string]$mode, [double]$cpu, [double]$temp) {
        if (-not $this.EnginePowerPlanGUID) { return }
        try {
            $g = $this.EnginePowerPlanGUID; $s = "54533251-82be-4824-96c1-47b60b740d00"
            # Min cores per mode: Silent=25% (pozwól na parkowanie), Balanced=50%, Turbo/Extreme=100%
            $mc = switch ($mode) { "Silent" { 25 } "Balanced" { 50 } "Turbo" { 100 } "Extreme" { 100 } default { 50 } }
            powercfg /setacvalueindex $g $s "0cc5b647-c1df-4637-891a-dec35c318583" $mc 2>$null
            powercfg /setdcvalueindex $g $s "0cc5b647-c1df-4637-891a-dec35c318583" $mc 2>$null
            # Processor idle disable in Turbo/Extreme
            $idle = if ($mode -in @("Turbo","Extreme")) { 1 } else { 0 }
            powercfg /setacvalueindex $g $s "5d76a2ca-e8c0-402f-a133-2158492d58ad" $idle 2>$null
            powercfg /setdcvalueindex $g $s "5d76a2ca-e8c0-402f-a133-2158492d58ad" $idle 2>$null
            powercfg /setactive $g 2>$null
        } catch {}
    }

    # ─── LEARNING ───
    [void] LearnAppBehavior([string]$app, [double]$cpu, [double]$gpuLoad) {
        if ([string]::IsNullOrWhiteSpace($app) -or $app -in @("Desktop","explorer","ShellExperienceHost")) { return }
        $al = $app.ToLower()
        if (-not $this.AppBehaviorHistory.ContainsKey($al)) {
            $this.AppBehaviorHistory[$al] = @{ AvgCPU=$cpu; AvgGPU=$gpuLoad; MaxCPU=$cpu; MaxGPU=$gpuLoad; NeedsGPU=($gpuLoad -gt 20); PrefersiGPU=$false; Sessions=1; LastSeen=[datetime]::Now }
        } else {
            $h = $this.AppBehaviorHistory[$al]; $sess = $h.Sessions + 1; $a = 1.0 / [Math]::Min(100, $sess)
            $h.AvgCPU = $h.AvgCPU * (1-$a) + $cpu * $a; $h.AvgGPU = $h.AvgGPU * (1-$a) + $gpuLoad * $a
            if ($cpu -gt $h.MaxCPU) { $h.MaxCPU = $cpu }; if ($gpuLoad -gt $h.MaxGPU) { $h.MaxGPU = $gpuLoad }
            $h.NeedsGPU = ($h.AvgGPU -gt 20 -or $h.MaxGPU -gt 50); $h.PrefersiGPU = ($h.AvgGPU -lt 15 -and $h.AvgCPU -lt 30)
            $h.Sessions = $sess; $h.LastSeen = [datetime]::Now
            # Auto-learn GPU preference when enough sessions
            if ($sess -gt 10 -and ($this.HasiGPU -and $this.HasdGPU)) {
                $pref = if ($h.NeedsGPU -and $h.AvgGPU -gt 40) { "dGPU" } elseif ($h.PrefersiGPU) { "iGPU" } else { "Auto" }
                $this.LearnedGPUPrefs[$al] = @{ Pref=$pref; Confidence=[Math]::Min(1.0,$sess/50.0); Sessions=$sess }
            }
        }
    }

    # ─── PERSISTENCE ───
    [void] SaveState([string]$configDir) {
        try {
            $state = @{
                GPUPreferences = $this.GPUPreferences
                LearnedGPUPrefs = $this.LearnedGPUPrefs
                AppBehaviorHistory = $this.AppBehaviorHistory
                TotalGovernActions = $this.TotalGovernActions
                GPUPrefChanges = $this.GPUPrefChanges
            }
            $json = $state | ConvertTo-Json -Depth 5 -Compress
            [System.IO.File]::WriteAllText((Join-Path $configDir "SystemGovernor.json"), $json, [System.Text.Encoding]::UTF8)
        } catch {}
    }

    [void] LoadState([string]$configDir) {
        try {
            $path = Join-Path $configDir "SystemGovernor.json"
            if (-not (Test-Path $path)) { return }
            $state = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($state.GPUPreferences) { $state.GPUPreferences.PSObject.Properties | ForEach-Object { $this.GPUPreferences[$_.Name] = $_.Value } }
            if ($state.LearnedGPUPrefs) {
                $state.LearnedGPUPrefs.PSObject.Properties | ForEach-Object {
                    $v = $_.Value; $this.LearnedGPUPrefs[$_.Name] = @{ Pref=$v.Pref; Confidence=[double]$v.Confidence; Sessions=[int]$v.Sessions }
                }
            }
            if ($state.AppBehaviorHistory) {
                $state.AppBehaviorHistory.PSObject.Properties | ForEach-Object {
                    $v = $_.Value; $this.AppBehaviorHistory[$_.Name] = @{
                        AvgCPU=[double]$v.AvgCPU; AvgGPU=[double]$v.AvgGPU; MaxCPU=[double]$v.MaxCPU; MaxGPU=[double]$v.MaxGPU
                        NeedsGPU=[bool]$v.NeedsGPU; PrefersiGPU=[bool]$v.PrefersiGPU; Sessions=[int]$v.Sessions; LastSeen=[datetime]::Now
                    }
                }
            }
            $this.TotalGovernActions = if ($state.TotalGovernActions) { [int]$state.TotalGovernActions } else { 0 }
            $this.GPUPrefChanges = if ($state.GPUPrefChanges) { [int]$state.GPUPrefChanges } else { 0 }
            $this.Log("Loaded: $($this.AppBehaviorHistory.Count) apps, $($this.LearnedGPUPrefs.Count) GPU prefs")
        } catch {}
    }

    # ─── CLEANUP (przywróć domyślne Windows) ───
    [void] RestoreWindowsDefaults() {
        try {
            if ($this.EnginePowerPlanGUID) {
                $g = $this.EnginePowerPlanGUID; $s = "54533251-82be-4824-96c1-47b60b740d00"
                powercfg /setacvalueindex $g $s "8baa4a8a-14c6-4451-8e8b-14bdbd197537" 1 2>$null  # Autonomous ON
                powercfg /setdcvalueindex $g $s "8baa4a8a-14c6-4451-8e8b-14bdbd197537" 1 2>$null
                powercfg /setacvalueindex $g $s "0cc5b647-c1df-4637-891a-dec35c318583" 50 2>$null
                powercfg /setacvalueindex $g $s "5d76a2ca-e8c0-402f-a133-2158492d58ad" 0 2>$null
                powercfg /setactive $g 2>$null
            }
            foreach ($pid in @($this.ActiveOverrides.Keys)) {
                try { $p = Get-Process -Id $pid -ErrorAction SilentlyContinue; if ($p) { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal; $p.Dispose() } } catch {}
            }
            $this.ActiveOverrides.Clear()
        } catch {}
    }

    [hashtable] GetStatus() {
        return @{
            IsGoverning = $this.IsGoverning; IsOverloaded = $this.IsOverloaded
            ActiveOverrides = $this.ActiveOverrides.Count; GPUPrefs = $this.LearnedGPUPrefs.Count
            AppProfiles = $this.AppBehaviorHistory.Count; TotalActions = $this.TotalGovernActions
            GPUChanges = $this.GPUPrefChanges; PowerOverride = $this.PowerOverrideActive
        }
    }

    [void] Log([string]$msg) {
        $this.GovernLog.Add("[$(Get-Date -Format 'HH:mm:ss')] GOV: $msg")
        if ($this.GovernLog.Count -gt 200) { $this.GovernLog.RemoveAt(0) }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# GPU-BOUND DETECTOR - Wykrywanie scenariuszy GPU-bound (Low CPU + High GPU)
# ═══════════════════════════════════════════════════════════════════════════════
class GPUBoundDetector {
    [int] $DetectionCount = 0
    [int] $RequiredSamples = 3  # Ile próbek potrzeba do pewności
    [double] $LastCPU = 0.0
    [double] $LastGPU = 0.0
    [bool] $IsConfident = $false
    
    # v42.5: Timer-based hysteresis dla EXIT
    [datetime] $ExitConditionStartTime = [datetime]::MinValue
    [int] $ExitDelaySeconds = 3  # CPU>50% przez 3+ sekund → exit
    [bool] $ExitConditionMet = $false
    
    # v43.12: Cooldown po EXIT - zapobiega natychmiastowemu re-entry (ping-pong)
    [datetime] $LastExitTime = [datetime]::MinValue
    [int] $ReEntryCooldownSeconds = 15  # Nie wracaj do GPU-BOUND przez 15s po exit
    # v43.14: Internal mode hold - zapobiega Silent↔Balanced ping-pong WEWNĄTRZ GPU-BOUND
    [string] $LastSuggestedMode = ""
    [datetime] $LastSuggestChangeTime = [datetime]::MinValue
    [int] $InternalHoldSeconds = 10  # Trzymaj sugerowany tryb min 10s
    
    # v43.12: Phase awareness - stabilniejszy w Gameplay
    [string] $CurrentPhase = "Idle"
    
    GPUBoundDetector() {
        $this.DetectionCount = 0
        $this.IsConfident = $false
        $this.ExitConditionStartTime = [datetime]::MinValue
        $this.ExitConditionMet = $false
        $this.LastExitTime = [datetime]::MinValue
        $this.LastSuggestedMode = ""
        $this.LastSuggestChangeTime = [datetime]::MinValue
    }
    
    # Główna metoda detekcji
    [hashtable] Detect([double]$cpu, [double]$gpuLoad, [bool]$hasGPU, [string]$gpuType) {
        $result = @{
            IsGPUBound = $false
            Confidence = 0
            Reason = ""
            SuggestedMode = ""
            CPUReduction = 0  # O ile obniżyć CPU TDP (W)
        }
        
        # Jeśli brak GPU lub GPU data - nie wykrywaj
        if (-not $hasGPU -or $gpuLoad -eq 0) {
            $result.Reason = "No GPU data"
            return $result
        }
        
        # Zapisz ostatnie wartości
        $this.LastCPU = $cpu
        $this.LastGPU = $gpuLoad
        
        # v42.5: PROGI z HYSTERESIS
        # ENTRY: CPU < 50% AND GPU > 75% (łatwiejszy wejście)
        # EXIT: CPU > 60% AND GPU < 65% (oba muszą być spełnione - zapobiega fałszywym exitom)
        # v43.14 FIX: OR→AND - CPU spike SAM nie powinien powodować EXIT (GPU nadal pracuje!)
        $entryCondition = ($cpu -lt 50 -and $gpuLoad -gt 75)
        $exitCondition = ($cpu -gt 60 -and $gpuLoad -lt 65)
        
        # v43.12: Cooldown po EXIT - nie wracaj natychmiast
        $cooldownActive = $false
        if ($this.LastExitTime -ne [datetime]::MinValue) {
            $sinceExit = ((Get-Date) - $this.LastExitTime).TotalSeconds
            if ($sinceExit -lt $this.ReEntryCooldownSeconds) {
                $cooldownActive = $true
            }
        }
        
        # v43.14 FIX: Phase-aware exit delay - DUŻO dłuższy w Gameplay
        $effectiveExitDelay = $this.ExitDelaySeconds
        if ($this.CurrentPhase -eq "Gameplay") {
            $effectiveExitDelay = 15  # v43.14: 15s w Gameplay (GPU-bound gry mają CPU spikes)
        } elseif ($this.CurrentPhase -eq "Loading") {
            $effectiveExitDelay = 8  # Loading potrzebuje więcej CPU chwilowo
        }
        
        # LOGIKA ENTRY/EXIT z timer-based hysteresis
        if (-not $this.IsConfident) {
            # Nie jesteśmy confident - sprawdź ENTRY
            if ($entryCondition -and -not $cooldownActive) {
                $this.DetectionCount++
                if ($this.DetectionCount -ge $this.RequiredSamples) {
                    $this.IsConfident = $true
                    if ($Script:DebugLogEnabled) {
                        Write-DebugLog "GPU-BOUND ENTRY: CPU=$([int]$cpu)%, GPU=$([int]$gpuLoad)% (confident after $($this.RequiredSamples) samples)" "GPU-BOUND"
                    }
                }
            } else {
                # Reset entry counter
                if ($this.DetectionCount -gt 0) { $this.DetectionCount-- }
            }
        } else {
            # Jesteśmy confident - sprawdź EXIT z DELAY
            if ($exitCondition) {
                # Exit condition spełniony - start/check timer
                if ($this.ExitConditionStartTime -eq [datetime]::MinValue) {
                    $this.ExitConditionStartTime = Get-Date
                } else {
                    # Check timer
                    $elapsed = ((Get-Date) - $this.ExitConditionStartTime).TotalSeconds
                    if ($elapsed -ge $effectiveExitDelay) {
                        # Exit confirmed
                        $this.IsConfident = $false
                        $this.DetectionCount = 0
                        $this.ExitConditionStartTime = [datetime]::MinValue
                        $this.LastExitTime = Get-Date  # v43.12: Start cooldown
                        if ($Script:DebugLogEnabled) {
                            Write-DebugLog "GPU-BOUND EXIT: CPU=$([int]$cpu)%, GPU=$([int]$gpuLoad)% (held ${elapsed}s, cooldown=$($this.ReEntryCooldownSeconds)s)" "GPU-BOUND"
                        }
                        $result.Reason = "GPU-BOUND exited"
                        return $result
                    }
                }
            } else {
                # Exit condition nie spełniony - reset timer
                $this.ExitConditionStartTime = [datetime]::MinValue
            }
        }
        
        # Jeśli confident - zwróć rekomendacje
        if ($this.IsConfident) {
            $result.IsGPUBound = $true
            $result.Confidence = 100  # Zawsze 100 gdy confident
            
            # v43.13: PHASE-AWARE GPU-BOUND MODE
            if ($this.CurrentPhase -eq "Gameplay") {
                if ($gpuLoad -gt 90 -and $cpu -gt 35) {
                    # EXTREME: GPU maxed + CPU active = gra potrzebuje WSZYSTKO
                    $result.SuggestedMode = "Turbo"
                    $result.CPUReduction = 0
                    $result.Reason = "GPU-BOUND: CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% → Turbo (Gameplay extreme)"
                } else {
                    # Gameplay: Balanced - stabilność, CPU headroom
                    $result.SuggestedMode = "Balanced"
                    $result.CPUReduction = 5
                    $result.Reason = "GPU-BOUND: CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% → Balanced (Gameplay stable)"
                }
            }
            elseif ($this.CurrentPhase -eq "Cutscene" -or $this.CurrentPhase -eq "Menu" -or $this.CurrentPhase -eq "Idle") {
                # v43.15: Jeśli GPU nadal pracuje ciężko, Balanced (Silent throttluje TDP)
                if ($gpuLoad -gt 70) {
                    $result.SuggestedMode = "Balanced"
                    $result.CPUReduction = 8
                    $result.Reason = "GPU-BOUND: CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% → Balanced ($($this.CurrentPhase) but GPU active)"
                } else {
                    # GPU odpoczął — Silent OK
                    $result.SuggestedMode = "Silent"
                    $result.CPUReduction = 15
                    $result.Reason = "GPU-BOUND: CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% → Silent ($($this.CurrentPhase))"
                }
            }
            else {
                # v43.14 FIX: Loading/Active/unknown → BALANCED zawsze!
                # Silent w GPU-BOUND powoduje TDP throttle → CPU spike → oscylacja
                # Balanced daje stabilny CPU headroom bez Turbo mocy
                if ($cpu -lt 25) {
                    $result.SuggestedMode = "Balanced"
                    $result.CPUReduction = 10
                    $result.Reason = "GPU-BOUND: CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% → Balanced (GPU dominant, stable)"
                }
                else {
                    $result.SuggestedMode = "Balanced"
                    $result.CPUReduction = 5
                    $result.Reason = "GPU-BOUND: CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% → Balanced"
                }
            }
            
            # SPECJALNE PRZYPADKI dla różnych typów GPU
            # APU (iGPU) - dzieli power budget z CPU, więc bardziej agresywnie obniżamy CPU
            if ($gpuType -eq "iGPU" -or $gpuType -eq "APU") {
                if ($cpu -lt 30 -and $this.CurrentPhase -ne "Gameplay") {
                    $result.SuggestedMode = "Silent"
                    $result.CPUReduction = 18  # Więcej dla APU (shared power)
                    $result.Reason = "GPU-BOUND (APU): CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)% → Silent (shared power budget)"
                }
            }
            
            # v43.14: INTERNAL HOLD - zapobiega ping-pong wewnątrz GPU-BOUND
            # Jeśli tryb się zmienił, ale stary trzymamy <10s → zostań przy starym
            if ($this.LastSuggestedMode -ne "" -and $result.SuggestedMode -ne $this.LastSuggestedMode) {
                $holdElapsed = ((Get-Date) - $this.LastSuggestChangeTime).TotalSeconds
                if ($holdElapsed -lt $this.InternalHoldSeconds) {
                    # Za wcześnie na zmianę - trzymaj poprzedni
                    $result.SuggestedMode = $this.LastSuggestedMode
                    $result.Reason += " [HOLD $([int]$holdElapsed)/$($this.InternalHoldSeconds)s]"
                } else {
                    # OK, czas minął - zmień i resetuj timer
                    $this.LastSuggestedMode = $result.SuggestedMode
                    $this.LastSuggestChangeTime = Get-Date
                }
            } else {
                # Pierwszy raz lub ten sam tryb - ustaw/odśwież
                if ($this.LastSuggestedMode -eq "") {
                    $this.LastSuggestChangeTime = Get-Date
                }
                $this.LastSuggestedMode = $result.SuggestedMode
            }
            
        } else {
            $result.Reason = if ($entryCondition) { 
                "GPU-bound detected, waiting for confidence ($($this.DetectionCount)/$($this.RequiredSamples))" 
            } else { 
                "Not GPU-bound (CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)%)" 
            }
        }
        

        
        return $result
    }
    
    # Reset detektora
    [void] Reset() {
        $this.DetectionCount = 0
        $this.IsConfident = $false
        $this.ExitConditionStartTime = [datetime]::MinValue
        $this.LastExitTime = [datetime]::MinValue
    }
    
    # Zwróć status
    [string] GetStatus() {
        if ($this.IsConfident) {
            return "GPU-BOUND (confident)"
        } elseif ($this.DetectionCount -gt 0) {
            return "GPU-BOUND (learning $($this.DetectionCount)/$($this.RequiredSamples))"
        } else {
            return "Balanced"
        }
    }
}

# PROPHET MEMORY
class ProphetMemory {
    [hashtable] $Apps
    [string] $LastActiveApp
    [int] $TotalSessions
    [int[]] $HourlyActivity
    [int] $MinSamplesForConfidence = 30  # Minimalna liczba próbek do pewnej kategoryzacji
    ProphetMemory() {
        $this.Apps = @{}
        $this.LastActiveApp = ""
        $this.TotalSessions = 0
        $this.HourlyActivity = [int[]]::new(24)
    }
    # ═══════════════════════════════════════════════════════════════════════════════
    # NOWA METODA: Ciągłe uczenie podczas pracy aplikacji
    # ═══════════════════════════════════════════════════════════════════════════════
    [void] UpdateRunning([string]$name, [double]$currentCPU, [double]$currentIO, [string]$displayName) {
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        
        # Utwórz wpis jeśli nie istnieje
        if (-not $this.Apps.ContainsKey($name)) {
            $this.Apps[$name] = @{
                Name = $displayName
                ProcessName = $name
                Launches = 0
                AvgCPU = $currentCPU
                AvgIO = $currentIO
                MaxCPU = $currentCPU
                MaxIO = $currentIO
                Category = "LEARNING"  # Nowy status - jeszcze się uczymy
                LastSeen = ""
                HourHits = [int[]]::new(24)
                PrevApps = @{}
                IsHeavy = $false
                Samples = 0  # NOWE: Licznik próbek
                SessionRuntime = 0.0  # NOWE: Całkowity czas działania w sekundach
                # v43.14: Per-app learned mode tracking
                ModeHistory = @{ Silent = 0; Balanced = 0; Turbo = 0 }
                ModeRewards = @{ Silent = 0.0; Balanced = 0.0; Turbo = 0.0 }
                PreferredMode = ""
                AvgGPU = 0.0
                IsGPUBound = $false
                PhasePreferred = @{}
            }
        }
        
        $app = $this.Apps[$name]
        $app.Name = if (![string]::IsNullOrWhiteSpace($displayName)) { $displayName } else { $name }
        $app.LastSeen = (Get-Date).ToString("yyyy-MM-dd HH:mm")
        
        # Inicjalizuj Samples jeśli nie istnieje (backward compatibility)
        if (-not $app.ContainsKey('Samples')) { $app.Samples = 0 }
        if (-not $app.ContainsKey('SessionRuntime')) { $app.SessionRuntime = 0.0 }
        
        $app.Samples++
        $app.SessionRuntime += 2.0  # ~2 sekundy na iterację
        
        # Szybsze uczenie na początku (50/50), później stabilizacja (90/10)
        $learningRate = if ($app.Samples -lt 20) { 0.5 } else { 0.1 }
        
        # Aktualizuj średnie z adaptive learning rate
        $app.AvgCPU = [Math]::Round(($app.AvgCPU * (1.0 - $learningRate)) + ($currentCPU * $learningRate), 2)
        $app.AvgIO = [Math]::Round(($app.AvgIO * (1.0 - $learningRate)) + ($currentIO * $learningRate), 2)
        
        # Aktualizuj maksima
        if ($currentCPU -gt $app.MaxCPU) { $app.MaxCPU = [Math]::Round($currentCPU, 2) }
        elseif ($app.Samples -gt 50) {
            # MaxCPU decay: powoli maleje jeśli nie potwierdzane (0.5% na próbkę)
            # Zapobiega: jeden spike = HEAVY na zawsze
            $app.MaxCPU = [Math]::Round($app.MaxCPU * 0.995, 2)
        }
        if ($currentIO -gt $app.MaxIO) { $app.MaxIO = [Math]::Round($currentIO, 2) }
        elseif ($app.Samples -gt 50) {
            $app.MaxIO = [Math]::Round($app.MaxIO * 0.995, 2)
        }
        
        # RE-KATEGORYZUJ na podstawie RZECZYWISTEGO użycia
        # COMBINED SCORE: CPU + IO + GPU (GPU-bound apps mają niskie CPU ale to nie znaczy że są LIGHT!)
        $avgScore = $app.AvgCPU + ($app.AvgIO * 2)
        $gpuScore = if ($app.ContainsKey('AvgGPU')) { $app.AvgGPU } else { 0 }
        # GPU-bound bonus: jeśli GPU>50% ale CPU<40% → app jest ciężka mimo niskiego CPU
        $gpuBonus = 0
        if ($gpuScore -gt 50 -and $app.AvgCPU -lt 40) {
            $gpuBonus = $gpuScore * 0.6  # GPU=80% daje +48 do avgScore
        }
        $combinedScore = $avgScore + $gpuBonus
        
        $oldCategory = $app.Category
        
        # Dopiero po MinSamplesForConfidence finalizujemy kategorię
        if ($app.Samples -ge $this.MinSamplesForConfidence) {
            # HEAVY: combinedScore>70 LUB GPU-bound LUB (CPU>25% & MaxCPU>65%)
            if ($combinedScore -gt 70 -or ($gpuScore -gt 60) -or ($app.AvgCPU -gt 25 -and $app.MaxCPU -gt 65)) { 
                $app.Category = "HEAVY"
                $app.IsHeavy = $true
            } elseif ($combinedScore -gt 35 -or ($app.AvgCPU -gt 15 -and $app.MaxCPU -gt 45) -or $gpuScore -gt 35) { 
                $app.Category = "MEDIUM"
                $app.IsHeavy = $false
            } else { 
                $app.Category = "LIGHT"
                $app.IsHeavy = $false
            }
        } else {
            # Podczas uczenia - tymczasowa kategoryzacja
            if ($combinedScore -gt 70 -or ($gpuScore -gt 60) -or ($app.AvgCPU -gt 25 -and $app.MaxCPU -gt 65)) { 
                $app.Category = "LEARNING_HEAVY"
            } elseif ($combinedScore -gt 35 -or ($app.AvgCPU -gt 15 -and $app.MaxCPU -gt 45) -or $gpuScore -gt 35) { 
                $app.Category = "LEARNING_MEDIUM"
            } else { 
                $app.Category = "LEARNING_LIGHT"
            }
        }
        
        # Log znaczących zmian kategorii (tylko po finalizacji)
        if ($oldCategory -ne $app.Category -and -not ($app.Category -match "LEARNING")) {
            # Znacząca zmiana - loguj to
            if ($oldCategory -match "LEARNING" -or $oldCategory -eq "NEW") {
                # Pierwsza finalizacja kategorii - loguj tylko w Debug
            } else {
                # Re-kategoryzacja - aplikacja się zmieniła!
                # Loguj zawsze, to ważna informacja
            }
        }
        
        $this.LastActiveApp = $name
    }
    # v43.14: Uczenie trybu - zapamiętaj jaki tryb był użyty i z jakim skutkiem
    [void] LearnMode([string]$name, [string]$mode, [double]$reward, [string]$phase, [double]$gpu) {
        if ([string]::IsNullOrWhiteSpace($name) -or -not $this.Apps.ContainsKey($name)) { return }
        if ($mode -ne "Silent" -and $mode -ne "Balanced" -and $mode -ne "Turbo") { return }
        $app = $this.Apps[$name]
        
        # Init fields if missing (backward compatibility)
        if (-not $app.ContainsKey('ModeHistory')) { $app.ModeHistory = @{ Silent = 0; Balanced = 0; Turbo = 0 } }
        if (-not $app.ContainsKey('ModeRewards')) { $app.ModeRewards = @{ Silent = 0.0; Balanced = 0.0; Turbo = 0.0 } }
        if (-not $app.ContainsKey('PhasePreferred')) { $app.PhasePreferred = @{} }
        if (-not $app.ContainsKey('AvgGPU')) { $app.AvgGPU = 0.0 }
        if (-not $app.ContainsKey('IsGPUBound')) { $app.IsGPUBound = $false }
        if (-not $app.ContainsKey('PreferredMode')) { $app.PreferredMode = "" }
        
        # Licz użycia trybu
        $app.ModeHistory[$mode]++
        
        # Exponential moving average reward per mode (nowsze doświadczenia ważniejsze)
        $lr = 0.15
        $app.ModeRewards[$mode] = $app.ModeRewards[$mode] * (1.0 - $lr) + $reward * $lr
        
        # GPU tracking
        if ($gpu -gt 0) {
            $app.AvgGPU = $app.AvgGPU * 0.9 + $gpu * 0.1
            $app.IsGPUBound = ($app.AvgGPU -gt 60 -and $app.AvgCPU -lt 50)
        }
        
        # Ustal PreferredMode = tryb z najwyższym avg reward (min 10 próbek)
        $bestMode = "Balanced"; $bestReward = -999.0
        foreach ($m in @("Silent", "Balanced", "Turbo")) {
            if ($app.ModeHistory[$m] -ge 10 -and $app.ModeRewards[$m] -gt $bestReward) {
                $bestReward = $app.ModeRewards[$m]
                $bestMode = $m
            }
        }
        if ($app.ModeHistory["Silent"] + $app.ModeHistory["Balanced"] + $app.ModeHistory["Turbo"] -ge 30) {
            $app.PreferredMode = $bestMode
        }
        
        # Per-phase learning: track rewards PER MODE per phase, wybierz najlepszy
        if ($phase -and $phase -ne "Idle") {
            if (-not $app.PhasePreferred.ContainsKey($phase)) {
                $app.PhasePreferred[$phase] = @{
                    Modes = @{ Silent = @{ Count = 0; Reward = 0.0 }; Balanced = @{ Count = 0; Reward = 0.0 }; Turbo = @{ Count = 0; Reward = 0.0 } }
                    BestMode = $mode
                    TotalCount = 0
                }
            }
            $pp = $app.PhasePreferred[$phase]
            if (-not $pp.ContainsKey('Modes')) {
                $pp.Modes = @{ Silent = @{ Count = 0; Reward = 0.0 }; Balanced = @{ Count = 0; Reward = 0.0 }; Turbo = @{ Count = 0; Reward = 0.0 } }
                $pp.TotalCount = 0
            }
            $pp.TotalCount++
            $modeData = $pp.Modes[$mode]
            $modeData.Count++
            $modeData.Reward = $modeData.Reward * (1.0 - $lr) + $reward * $lr
            
            # Wybierz BestMode = tryb z najwyższym avg reward (min 5 próbek per mode)
            if ($pp.TotalCount -ge 15) {
                $bestPM = "Balanced"; $bestPR = -999.0
                foreach ($m in @("Silent", "Balanced", "Turbo")) {
                    $md = $pp.Modes[$m]
                    if ($md.Count -ge 5 -and $md.Reward -gt $bestPR) {
                        $bestPR = $md.Reward
                        $bestPM = $m
                    }
                }
                $pp.BestMode = $bestPM
            }
        }
    }
    # v43.14: Pobierz nauczony tryb per-app per-phase
    [string] GetLearnedMode([string]$name, [string]$phase) {
        if ([string]::IsNullOrWhiteSpace($name) -or -not $this.Apps.ContainsKey($name)) { return "" }
        $app = $this.Apps[$name]
        if (-not $app.ContainsKey('PhasePreferred')) { return "" }
        if (-not $app.ContainsKey('PreferredMode')) { return "" }
        # Najpierw per-phase (bardziej specyficzne)
        if ($phase -and $app.PhasePreferred.ContainsKey($phase)) {
            $pp = $app.PhasePreferred[$phase]
            # Nowa struktura z BestMode
            if ($pp.ContainsKey('BestMode') -and $pp.ContainsKey('TotalCount') -and $pp.TotalCount -ge 15) {
                return $pp.BestMode
            }
        }
        # Fallback: ogólny PreferredMode (z ModeRewards)
        if ($app.PreferredMode) { return $app.PreferredMode }
        return ""
    }
    [void] RecordLaunch([string]$name, [double]$peakCPU, [double]$peakIO, [string]$displayName) {
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $hour = (Get-Date).Hour
        if (-not $this.Apps.ContainsKey($name)) {
            $this.Apps[$name] = @{
                Name = $displayName
                ProcessName = $name
                Launches = 0
                AvgCPU = 0.0
                AvgIO = 0.0
                MaxCPU = 0.0
                MaxIO = 0.0
                Category = "NEW"
                LastSeen = ""
                HourHits = [int[]]::new(24)
                PrevApps = @{}
                IsHeavy = $false
                Samples = 0
                SessionRuntime = 0.0
                # v43.14: Per-app learned mode tracking
                ModeHistory = @{ Silent = 0; Balanced = 0; Turbo = 0 }
                ModeRewards = @{ Silent = 0.0; Balanced = 0.0; Turbo = 0.0 }
                PreferredMode = ""
                AvgGPU = 0.0
                IsGPUBound = $false
                PhasePreferred = @{}
            }
        }
        $app = $this.Apps[$name]
        $app.Launches++
        $app.Name = if (![string]::IsNullOrWhiteSpace($displayName)) { $displayName } else { $name }
        $app.LastSeen = (Get-Date).ToString("yyyy-MM-dd HH:mm")
        
        # Inicjalizuj Samples jeśli nie istnieje
        if (-not $app.ContainsKey('Samples')) { $app.Samples = 0 }
        if (-not $app.ContainsKey('SessionRuntime')) { $app.SessionRuntime = 0.0 }
        
        if ($app.Launches -eq 1) {
            $app.AvgCPU = $peakCPU
            $app.AvgIO = $peakIO
        } else {
            # Zmniejszona dominacja starych wartości (z 0.7 na 0.6)
            $app.AvgCPU = [Math]::Round(($app.AvgCPU * 0.6) + ($peakCPU * 0.4), 2)
            $app.AvgIO = [Math]::Round(($app.AvgIO * 0.6) + ($peakIO * 0.4), 2)
        }
        if ($peakCPU -gt $app.MaxCPU) { $app.MaxCPU = [Math]::Round($peakCPU, 2) }
        if ($peakIO -gt $app.MaxIO) { $app.MaxIO = [Math]::Round($peakIO, 2) }
        $app.HourHits[$hour]++
        $this.HourlyActivity[$hour]++
        if (![string]::IsNullOrWhiteSpace($this.LastActiveApp) -and $this.LastActiveApp -ne $name) {
            if (-not $app.PrevApps.ContainsKey($this.LastActiveApp)) {
                $app.PrevApps[$this.LastActiveApp] = 0
            }
            $app.PrevApps[$this.LastActiveApp]++
        }
        
        # UWAGA: RecordLaunch to tylko początkowe dane z BOOST
        # Nie finalizujemy kategorii tutaj - UpdateRunning to zrobi
        $score = $peakCPU + ($peakIO * 2)
        if ($score -gt 70 -or $peakCPU -gt 60) { 
            $app.Category = "LEARNING_HEAVY"
        } elseif ($score -gt 35) { 
            $app.Category = "LEARNING_MEDIUM" 
        } else { 
            $app.Category = "LEARNING_LIGHT" 
        }
        
        $this.LastActiveApp = $name
        $this.TotalSessions++
    }
    [double] GetWeight([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return 0.3 }
        if (-not $this.Apps.ContainsKey($name)) { return 0.3 }
        $app = $this.Apps[$name]
        
        # Usuń prefix LEARNING_ dla kategoryzacji
        $cleanCategory = $app.Category -replace "^LEARNING_", ""
        
        switch ($cleanCategory) {
            "HEAVY" { return 1.0 }
            "MEDIUM" { return 0.6 }
            default { return 0.3 }
        }
        return 0.3
    }
    [bool] IsKnownHeavy([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return $false }
        if ($this.Apps.ContainsKey($name)) {
            $isHeavy = $this.Apps[$name].IsHeavy
            if ($null -eq $isHeavy) { return $false }
            return [bool]$isHeavy
        }
        return $false
    }
    # NOWA METODA: Czy kategoryzacja jest pewna (wystarczająco próbek)
    [bool] IsCategoryConfident([string]$name) {
        if ([string]::IsNullOrWhiteSpace($name)) { return $false }
        if (-not $this.Apps.ContainsKey($name)) { return $false }
        $app = $this.Apps[$name]
        
        # Backward compatibility
        if (-not $app.ContainsKey('Samples')) { return $true }  # Stare aplikacje = confident
        
        return $app.Samples -ge $this.MinSamplesForConfidence
    }
    [int] GetAppCount() { return $this.Apps.Count }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "ProphetMemory.json"
            $data = @{
                Apps = $this.Apps
                TotalSessions = $this.TotalSessions
                HourlyActivity = $this.HourlyActivity
                LastActiveApp = $this.LastActiveApp
                MinSamplesForConfidence = $this.MinSamplesForConfidence
            }
            [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 8 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "ProphetMemory.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.Apps) {
                    $data.Apps.PSObject.Properties | ForEach-Object {
                        $appName = $_.Name  # v39 FIX: Zachowaj nazwe PRZED wewnetrzna petla
                        $appData = $_.Value
                        $this.Apps[$appName] = @{
                            Name = $appData.Name
                            ProcessName = $appData.ProcessName
                            Launches = if ($appData.Launches) { [int]$appData.Launches } else { 0 }
                            AvgCPU = if ($appData.AvgCPU) { [double]$appData.AvgCPU } else { 0 }
                            AvgIO = if ($appData.AvgIO) { [double]$appData.AvgIO } else { 0 }
                            MaxCPU = if ($appData.MaxCPU) { [double]$appData.MaxCPU } else { 0 }
                            MaxIO = if ($appData.MaxIO) { [double]$appData.MaxIO } else { 0 }
                            Category = if ($appData.Category) { $appData.Category } else { "NEW" }
                            LastSeen = if ($appData.LastSeen) { $appData.LastSeen } else { "" }
                            HourHits = if ($appData.HourHits) { [int[]]$appData.HourHits } else { [int[]]::new(24) }
                            PrevApps = @{}
                            IsHeavy = if ($null -ne $appData.IsHeavy) { [bool]$appData.IsHeavy } else { $false }
                            Samples = if ($appData.Samples) { [int]$appData.Samples } else { 0 }
                            SessionRuntime = if ($appData.SessionRuntime) { [double]$appData.SessionRuntime } else { 0.0 }
                            # v43.14: Per-app learned mode fields
                            ModeHistory = @{ Silent = 0; Balanced = 0; Turbo = 0 }
                            ModeRewards = @{ Silent = 0.0; Balanced = 0.0; Turbo = 0.0 }
                            PreferredMode = if ($appData.PreferredMode) { $appData.PreferredMode } else { "" }
                            AvgGPU = if ($appData.AvgGPU) { [double]$appData.AvgGPU } else { 0.0 }
                            IsGPUBound = if ($null -ne $appData.IsGPUBound) { [bool]$appData.IsGPUBound } else { $false }
                            PhasePreferred = @{}
                        }
                        # v43.14: Restore ModeHistory
                        if ($appData.ModeHistory) {
                            foreach ($m in @("Silent", "Balanced", "Turbo")) {
                                if ($appData.ModeHistory.$m) { $this.Apps[$appName].ModeHistory[$m] = [int]$appData.ModeHistory.$m }
                            }
                        }
                        # v43.14: Restore ModeRewards
                        if ($appData.ModeRewards) {
                            foreach ($m in @("Silent", "Balanced", "Turbo")) {
                                if ($appData.ModeRewards.$m) { $this.Apps[$appName].ModeRewards[$m] = [double]$appData.ModeRewards.$m }
                            }
                        }
                        # v43.14: Restore PhasePreferred
                        if ($appData.PhasePreferred) {
                            $appData.PhasePreferred.PSObject.Properties | ForEach-Object {
                                $phaseName = $_.Name
                                $phaseData = $_.Value
                                $modes = @{ Silent = @{ Count = 0; Reward = 0.0 }; Balanced = @{ Count = 0; Reward = 0.0 }; Turbo = @{ Count = 0; Reward = 0.0 } }
                                if ($phaseData.Modes) {
                                    foreach ($m in @("Silent", "Balanced", "Turbo")) {
                                        if ($phaseData.Modes.$m) {
                                            $modes[$m].Count = if ($phaseData.Modes.$m.Count) { [int]$phaseData.Modes.$m.Count } else { 0 }
                                            $modes[$m].Reward = if ($phaseData.Modes.$m.Reward) { [double]$phaseData.Modes.$m.Reward } else { 0.0 }
                                        }
                                    }
                                }
                                $this.Apps[$appName].PhasePreferred[$phaseName] = @{
                                    Modes = $modes
                                    BestMode = if ($phaseData.BestMode) { $phaseData.BestMode } else { "Balanced" }
                                    TotalCount = if ($phaseData.TotalCount) { [int]$phaseData.TotalCount } else { 0 }
                                }
                            }
                        }
                        # Restore PrevApps
                        if ($appData.PrevApps) {
                            $appData.PrevApps.PSObject.Properties | ForEach-Object {
                                $prevName = $_.Name  # v39 FIX: Osobna zmienna dla wewnetrznej petli
                                $this.Apps[$appName].PrevApps[$prevName] = [int]$_.Value
                            }
                        }
                    }
                }
                if ($data.TotalSessions) { $this.TotalSessions = [int]$data.TotalSessions }
                if ($data.HourlyActivity) { $this.HourlyActivity = [int[]]$data.HourlyActivity }
                if ($data.LastActiveApp) { $this.LastActiveApp = $data.LastActiveApp }
                if ($data.MinSamplesForConfidence) { $this.MinSamplesForConfidence = [int]$data.MinSamplesForConfidence }
            }
        } catch { }
    }
}
# NEURAL BRAIN
class NeuralBrain {
    [hashtable] $Weights
    [double] $AggressionBias
    [double] $ReactivityBias
    [string] $LastLearned
    [string] $LastLearnTime
    [string] $Analyzing
    [int] $TotalDecisions
    [double] $RAMWeight              # V35: Waga dla wysokiego RAM
    [double] $LastRAM                # V35: Ostatni poziom RAM
    NeuralBrain() {
        $this.Weights = @{}
        $this.AggressionBias = 0.0
        $this.ReactivityBias = 0.5
        $this.LastLearned = ""
        $this.LastLearnTime = ""
        $this.Analyzing = ""
        $this.TotalDecisions = 0
        $this.RAMWeight = 0.3        # V35: Startowa waga RAM (0-1)
        $this.LastRAM = 0
    }
    [string] Train([string]$processName, [string]$displayName, [double]$cpu, [double]$io, [ProphetMemory]$prophet) {
        if (-not (Is-NeuralBrainEnabled)) { return "DISABLED" }
        if ([string]::IsNullOrWhiteSpace($processName)) { return "INVALID" }
        # Poprzednio powodowalo podwojne liczenie uruchomien aplikacji
        $score = $cpu + ($io * 2)
        $weight = 0.3
        if ($score -gt 50 -or $cpu -gt 40) { $weight = 1.0 }
        elseif ($score -gt 20) { $weight = 0.6 }
        $isNew = -not $this.Weights.ContainsKey($processName)
        $this.Weights[$processName] = $weight
        $this.LastLearned = if (![string]::IsNullOrWhiteSpace($displayName)) { $displayName } else { $processName }
        $this.LastLearnTime = (Get-Date).ToString("HH:mm:ss")
        $this.Analyzing = ""
        $category = "NEW"
        if ($prophet.Apps.ContainsKey($processName)) { $category = $prophet.Apps[$processName].Category }
        $status = if ($isNew) { 'NEW' } else { 'UPD' }
        return "$status [$category] CPU:$([Math]::Round($cpu))% IO:$([Math]::Round($io))"
    }
    [void] LearnRAM([double]$ram, [bool]$ramSpike, [string]$actionTaken, [bool]$wasSuccessful) {
        if (-not (Is-NeuralBrainEnabled)) { return }
        # Jesli byl spike RAM i Turbo byl skuteczny - zwieksz wage RAM
        if ($ramSpike -and $actionTaken -eq "Turbo" -and $wasSuccessful) {
            $this.RAMWeight = [Math]::Min(1.0, $this.RAMWeight + 0.05)
        }
        # Jesli byl spike RAM i Silent/Balanced byl nieefektywny - zwieksz wage RAM
        elseif ($ramSpike -and $actionTaken -ne "Turbo" -and -not $wasSuccessful) {
            $this.RAMWeight = [Math]::Min(1.0, $this.RAMWeight + 0.08)
        }
        # Jesli niski RAM i Silent dziala dobrze - zmniejsz wage RAM
        elseif ($ram -lt 50 -and $actionTaken -eq "Silent" -and $wasSuccessful) {
            $this.RAMWeight = [Math]::Max(0.1, $this.RAMWeight - 0.02)
        }
        $this.LastRAM = $ram
    }
    [void] Evolve([string]$action) {
        if (-not (Is-NeuralBrainEnabled)) { return }
        switch ($action) {
            "Turbo"    { 
                $this.AggressionBias = [Math]::Min(0.5, $this.AggressionBias + 0.08)
                $this.ReactivityBias = [Math]::Min(0.5, $this.ReactivityBias + 0.05)
            }
            "Silent"   { 
                $this.AggressionBias = [Math]::Max(-0.5, $this.AggressionBias - 0.08)
                $this.ReactivityBias = [Math]::Max(-0.5, $this.ReactivityBias - 0.05)
            }
            "Balanced" { 
                $this.AggressionBias *= 0.9
                $this.ReactivityBias *= 0.95
            }
        }
    }
    [hashtable] Decide([double]$cpu, [double]$io, [double]$trend, [ProphetMemory]$prophet, [double]$ram, [bool]$ramSpike) {
        if (-not (Is-NeuralBrainEnabled)) { return @{ Score = 0; Mode = "Silent"; Reason = "DISABLED"; Trend = 0 } }
        $this.TotalDecisions++
        $this.LastRAM = $ram
        # Bazowe cisnienie - CPU + I/O
        $ioMultiplier = 0.5 + ($this.ReactivityBias * 0.2)
        $pressure = $cpu * 0.7 + [Math]::Min(40, $io * $ioMultiplier)
        if ($ramSpike) {
            $pressure += 30 * $this.RAMWeight  # Duzy bonus przy spike
        } elseif ($ram -gt 80) {
            $pressure += 20 * $this.RAMWeight  # Bonus przy wysokim RAM
        } elseif ($ram -gt 70) {
            $pressure += 10 * $this.RAMWeight  # Maly bonus
        }
        # Trend
        if ($trend -gt 10 -and $cpu -gt 30) { $pressure += 5 }
        elseif ($trend -lt -10 -and $cpu -lt $Script:ForceSilentCPU) { $pressure -= 5 }
        # Known apps - APP NEEDS drive pressure, not current CPU
        if (![string]::IsNullOrWhiteSpace($prophet.LastActiveApp) -and $this.Weights.ContainsKey($prophet.LastActiveApp)) {
            $weight = $this.Weights[$prophet.LastActiveApp]
            # FIX: Sprawdź też kategorię z Prophet (może być bardziej aktualna)
            if ($prophet.Apps.ContainsKey($prophet.LastActiveApp)) {
                $appInfo = $prophet.Apps[$prophet.LastActiveApp]
                $cleanCategory = $appInfo.Category -replace "^LEARNING_", ""
                
                # Używaj Prophet category jeśli jest confident, inaczej używaj weight z Brain
                if ($prophet.IsCategoryConfident($prophet.LastActiveApp)) {
                    # Prophet confident - używaj jego kategoryzacji
                    switch ($cleanCategory) {
                        "HEAVY" { $pressure += 15 }
                        "MEDIUM" { $pressure += 5 }
                        "LIGHT" { $pressure -= 10 }
                    }
                } else {
                    # Prophet się jeszcze uczy - używaj Brain weight
                    if ($weight -ge 0.8) { $pressure += 15 }
                    elseif ($weight -ge 0.5) { $pressure += 5 }
                    elseif ($weight -lt 0.3) { $pressure -= 10 }
                }
            } else {
                # Brak w Prophet - używaj tylko Brain weight
                if ($weight -ge 0.8) { $pressure += 15 }
                elseif ($weight -ge 0.5) { $pressure += 5 }
                elseif ($weight -lt 0.3) { $pressure -= 10 }
            }
        }
        # AggressionBias
        $pressure += ($this.AggressionBias * 5)
        $pressure = [Math]::Max(0, [Math]::Min(100, $pressure))
        
        # ZMIANA: Nie wymuszamy trybu, tylko zwracamy Score i sugestię
        # Pozwalamy systemowi decyzyjnemu wykorzystać ten Score
        $suggestion = "Balanced"
        $reason = "Neural: pressure=$([int]$pressure)"
        
        if ($ramSpike) {
            $pressure += 15  # Extra boost dla RAM spike
            $suggestion = "Turbo"
            $reason = "Neural: RAM Spike detected"
        } elseif ($pressure -gt 75) {
            $suggestion = "Turbo"
            $reason = "Neural: High pressure ($([int]$pressure))"
        } elseif ($pressure -lt 30) {
            $suggestion = "Silent"
            $reason = "Neural: Low pressure ($([int]$pressure))"
        } else {
            $suggestion = "Balanced"
            $reason = "Neural: Medium pressure ($([int]$pressure))"
        }
        
        return @{ 
            Score = [Math]::Round($pressure, 1)
            Suggestion = $suggestion  # Sugestia, nie wymuszenie
            Reason = $reason
            Trend = [Math]::Round($trend, 2)
        }
    }
    # Kompatybilnosc wsteczna - stara sygnatura bez RAM
    [hashtable] Decide([double]$cpu, [double]$io, [double]$trend, [ProphetMemory]$prophet) {
        return $this.Decide($cpu, $io, $trend, $prophet, $this.LastRAM, $false)
    }
    [int] GetCount() {
        # Powod: Dane moga istniec nawet gdy silnik jest wylaczony
        return $this.Weights.Count
    }
    [bool] IsActive() {
        return (Is-NeuralBrainEnabled)
    }
    [void] SaveState([string]$dir) {
        try {
            # Powod: Dane moga istniec z wczesniej (silnik byl wlaczony, potem wylaczony)
            $path = Join-Path $dir "BrainState.json"
            $data = @{
                Weights = $this.Weights
                AggressionBias = $this.AggressionBias
                ReactivityBias = $this.ReactivityBias
                TotalDecisions = $this.TotalDecisions
                RAMWeight = $this.RAMWeight
                LastLearned = $this.LastLearned
            }
            [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 4 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "BrainState.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.Weights) {
                    $data.Weights.PSObject.Properties | ForEach-Object { 
                        $this.Weights[$_.Name] = [double]$_.Value 
                    }
                }
                if ($null -ne $data.AggressionBias) { $this.AggressionBias = [double]$data.AggressionBias }
                if ($null -ne $data.ReactivityBias) { $this.ReactivityBias = [double]$data.ReactivityBias }
                if ($data.TotalDecisions) { $this.TotalDecisions = [int]$data.TotalDecisions }
                if ($null -ne $data.RAMWeight) { $this.RAMWeight = [double]$data.RAMWeight }
                if ($data.LastLearned) { $this.LastLearned = $data.LastLearned }
            }
        } catch { }
    }
}
# PROCESS WATCHER - Instant Boost
class ProcessWatcher {
    [System.Collections.Generic.HashSet[int]] $KnownProcessIds
    [int] $SessionId
    [bool] $IsBoosting
    [datetime] $BoostEndTime          #  FIXED: DateTime zamiast countdown
    [string] $BoostProcessName
    [string] $BoostDisplayName
    [double] $PeakCPU
    [double] $PeakIO
    [object] $BoostProcess
    [System.Collections.Generic.Dictionary[string, datetime]] $RecentBoosts
    [int] $BoostCooldownSeconds = 15  #  FIXED: Zmniejszony cooldown z 30s do 15s (konfigurowalny)
    ProcessWatcher([int]$cooldownSeconds = 15) {
        $this.KnownProcessIds = [System.Collections.Generic.HashSet[int]]::new()
        $this.SessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        $this.RecentBoosts = [System.Collections.Generic.Dictionary[string, datetime]]::new()
        $this.IsBoosting = $false
        $this.BoostEndTime = [datetime]::MinValue
        $this.BoostProcessName = ""
        $this.BoostDisplayName = ""
        $this.PeakCPU = 0.0
        $this.PeakIO = 0.0
        $this.BoostProcess = $null
        if ($cooldownSeconds -gt 0) { $this.BoostCooldownSeconds = $cooldownSeconds }
        $this.Refresh()
    }
    [void] Refresh() {
        $this.KnownProcessIds.Clear()
        foreach ($process in [System.Diagnostics.Process]::GetProcesses()) {
            try { [void]$this.KnownProcessIds.Add($process.Id) } catch { }
        }
        $now = Get-Date
        $toRemove = @()
        foreach ($entry in $this.RecentBoosts.GetEnumerator()) {
            if (($now - $entry.Value).TotalSeconds -gt $this.BoostCooldownSeconds) {
                $toRemove += $entry.Key
            }
        }
        foreach ($key in $toRemove) { $this.RecentBoosts.Remove($key) }
    }
    [bool] IsOnCooldown([string]$processName) {
        if ($this.RecentBoosts.ContainsKey($processName)) {
            $timeSinceBoost = (Get-Date) - $this.RecentBoosts[$processName]
            if ($timeSinceBoost.TotalSeconds -lt $this.BoostCooldownSeconds) { return $true }
        }
        return $false
    }
    [bool] ScanAndBoost([System.Collections.Generic.HashSet[string]]$blacklist, [ProphetMemory]$prophet, [double]$cpuSpike = 0, [double]$systemCpu = 0) {
        $foundNew = $false
        try {
            $processes = [System.Diagnostics.Process]::GetProcesses()
            foreach ($process in $processes) {
                try {
                    if ($this.KnownProcessIds.Contains($process.Id)) { continue }
                    $processName = $process.ProcessName
                    # Dodaj do known NATYCHMIAST - zapobiega wielokrotnemu przetwarzaniu
                    [void]$this.KnownProcessIds.Add($process.Id)
                    if ($Global:DebugMode) { Add-Log "NEW PID $($process.Id): $processName" -Debug }
                    # #
                    # FILTROWANIE PROCESOW SYSTEMOWYCH I MALO WAZNYCH
                    # #
                    # 1. Filtruj procesy z innej sesji (systemowe)
                    if ($process.SessionId -ne $this.SessionId -and $process.SessionId -ne 0) { continue }
                    # 2. Sprawdz blackliste
                    if ($blacklist.Contains($processName)) { continue }
                    # 3. Sprawdz cooldown
                    if ($this.IsOnCooldown($processName)) { continue }
                    # 4. NOWE: Ignoruj procesy z typowymi nazwami systemowymi/pomocniczymi
                    $systemPatterns = @(
                        "^svc",          # svchost, svcs, etc.
                        "host$",         # RuntimeBroker host, etc.
                        "broker$",       # Various brokers
                        "service$",      # Various services
                        "^wer",          # Windows Error Reporting
                        "^dism",         # Deployment Image Servicing
                        "^msi",          # MSI Installer
                        "^wmi",          # WMI services
                        "^com",          # COM services
                        "update",        # Updaters
                        "telemetry",     # Telemetria
                        "^diag",         # Diagnostics
                        "helper$",       # Helper processes
                        "^crash",        # Crash handlers
                        "handler$",      # Various handlers
                        "worker$",       # Worker processes
                        "agent$",        # Agent processes
                        "tray$",         # Tray icons
                        "^nvidia",       # NVIDIA background
                        "^amd",          # AMD background
                        "^intel",        # Intel background
                        "^igfx",         # Intel Graphics
                        "^rtk",          # Realtek
                        "container$"     # Container processes
                    )
                    $isSystemPattern = $false
                    foreach ($pattern in $systemPatterns) {
                        if ($processName -match $pattern) { $isSystemPattern = $true; break }
                    }
                    if ($isSystemPattern) { continue }
                    # 5. NOWE: Ignoruj procesy z lokalizacji systemowych
                    try {
                        $processPath = $process.MainModule.FileName
                        if ($processPath) {
                            $systemPaths = @(
                                "\\Windows\\System32",
                                "\\Windows\\SysWOW64",
                                "\\Windows\\WinSxS",
                                "\\Windows\\servicing",
                                "\\Windows\\Microsoft.NET",
                                "\\Windows\\assembly"
                            )
                            $isSystemPath = $false
                            foreach ($sysPath in $systemPaths) {
                                if ($processPath -like "*$sysPath*") { $isSystemPath = $true; break }
                            }
                            if ($isSystemPath) { continue }
                        }
                    } catch { }
                    # #
                    # WYKRYWANIE PRAWDZIWYCH APLIKACJI
                    # #
                    # Sprawdz czy to prawdziwa aplikacja
                    $isLikelyApp = $false
                    $windowTitle = ""
                    # 1. Znana jako HEAVY w Prophet
                    if ($prophet.IsKnownHeavy($processName)) { 
                        $isLikelyApp = $true 
                    }
                    # 2. Ma okno
                    if (-not $isLikelyApp) {
                        try {
                            $process.Refresh()
                            if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
                                $isLikelyApp = $true
                                $windowTitle = $process.MainWindowTitle
                            }
                        } catch { }
                    }
                    # 3. Sciezka w Program Files / AppData / Games
                    if (-not $isLikelyApp) {
                        try {
                            $path = $process.MainModule.FileName
                            if ($path -and ($path -match "Program Files" -or $path -match "Users\\[^\\]+\\AppData" -or 
                                $path -match "Games" -or $path -match "Steam")) {
                                $isLikelyApp = $true
                            }
                        } catch { }
                    }
                    if (-not $isLikelyApp) { continue }
                    # Jesli juz boostujemy inny proces - nie startuj nowego
                    if ($this.IsBoosting) { continue }
                    
                    # v43.10 FIX: Sprawdź HardLock PRZED włączeniem BOOST
                    # Jeśli aplikacja ma HardLock w AppCategories.json, NIE BOOSTUJ - użytkownik wymusza tryb
                    $hasHardLock = $false
                    
                    if ($Script:AppCategoryPreferences -and $Script:AppCategoryPreferences.Count -gt 0) {
                        $appLower = $processName.ToLower() -replace '\.exe$', ''
                        
                        foreach ($key in $Script:AppCategoryPreferences.Keys) {
                            $keyLower = $key.ToLower() -replace '\.exe$', ''
                            
                            # v43.10b: Rozszerzone dopasowanie - też Google Chrome -> chrome
                            $matches = ($keyLower -eq $appLower) -or 
                                      ($appLower -like "*$keyLower*") -or 
                                      ($keyLower -like "*$appLower*") -or
                                      ($keyLower -eq "google chrome" -and $appLower -eq "chrome") -or
                                      ($keyLower -eq "chrome" -and $appLower -eq "chrome")
                            
                            if ($matches) {
                                $pref = $Script:AppCategoryPreferences[$key]
                                if ($pref.HardLock) {
                                    $hasHardLock = $true
                                    # Rate-limit: loguj BOOST BLOCKED max raz na 60s per app
                                    $bbKey = "BB_$processName"
                                    $bbNow = [DateTime]::UtcNow
                                    if (-not $Script:LastBoostBlockLog) { $Script:LastBoostBlockLog = @{} }
                                    if (-not $Script:LastBoostBlockLog.ContainsKey($bbKey) -or ($bbNow - $Script:LastBoostBlockLog[$bbKey]).TotalSeconds -gt 60) {
                                        $Script:LastBoostBlockLog[$bbKey] = $bbNow
                                        Write-DebugLog "BOOST BLOCKED: $processName (HardLock)" "BOOST" "DEBUG"
                                    }
                                    break
                                }
                            }
                        }
                    }
                    
                    # Pomiń BOOST jeśli aplikacja ma HardLock - NIE ustawiaj $foundNew!
                    if ($hasHardLock) { continue }
                    
                    # ZAWSZE BOOST dla nowych aplikacji (prosta logika)
                    $shouldBoost = $true
                    # Ustaw Boost
                    $this.IsBoosting = $true
                    $this.BoostEndTime = (Get-Date).AddMilliseconds($Script:BoostDuration)
                    $this.BoostProcessName = $processName
                    $this.BoostProcess = $process
                    $this.PeakCPU = 0.0
                    $this.PeakIO = 0.0
                    $this.RecentBoosts[$processName] = Get-Date
                    # Pobierz DisplayName
                    $this.BoostDisplayName = Get-ProcessDisplayName -ProcessName $processName -Process $process
                    # Dla PWA/helper - pobierz prawdziwa nazwe z tytulu okna
                    $pwaProcesses = @("pwahelper", "msedgewebview2", "applicationframehost", "wwahostgta", "electron", "cefsharp")
                    if ($pwaProcesses -contains $processName.ToLower() -or $processName -match "helper|host|webview") {
                        if (![string]::IsNullOrWhiteSpace($windowTitle) -and $windowTitle.Length -gt 1) {
                            $cleanTitle = $windowTitle -replace '\s*[----]\s*(Microsoft Edge|Google Chrome|Mozilla Firefox|Brave|Opera).*$', ''
                            $cleanTitle = $cleanTitle.Trim()
                            if ($cleanTitle -match "^(.+?)\s*[----]") { $cleanTitle = $matches[1].Trim() }
                            if ($cleanTitle.Length -gt 1 -and $cleanTitle.Length -lt 50) {
                                $this.BoostDisplayName = $cleanTitle
                            }
                        }
                    }
                    if ($this.BoostDisplayName.Length -gt 40) {
                        $this.BoostDisplayName = $this.BoostDisplayName.Substring(0, 37) + "..."
                    }
                    try { $process.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal } catch { }
                    $foundNew = $true
                    break
                } catch { continue }
            }
        } catch { }
        return [bool]$foundNew
    }
    [void] UpdateBoost([double]$cpu, [double]$io) {
        if (-not $this.IsBoosting) { return }
        if ($cpu -gt $this.PeakCPU) { $this.PeakCPU = $cpu }
        if ($io -gt $this.PeakIO) { $this.PeakIO = $io }
        # Sprobuj zaktualizowac DisplayName jesli nadal = ProcessName
        if ($this.BoostProcess -and $this.BoostDisplayName -eq $this.BoostProcessName) {
            try {
                if (-not $this.BoostProcess.HasExited) {
                    #  FIXED: Uzyj nowej funkcji Get-ProcessDisplayName
                    $this.BoostDisplayName = Get-ProcessDisplayName -ProcessName $this.BoostProcessName -Process $this.BoostProcess
                }
            } catch { }
        }
        #  FIXED: Sprawdz czas zamiast countdown - precyzyjne 15 sekund (lub z config)
        if ((Get-Date) -ge $this.BoostEndTime) { 
            $this.IsBoosting = $false 
        }
    }
    [int] GetBoostRemainingSeconds() {
        #  NEW: Metoda do wyswietlania pozostalego czasu Boost
        if (-not $this.IsBoosting) { return 0 }
        $remaining = ($this.BoostEndTime - (Get-Date)).TotalSeconds
        return [Math]::Max(0, [int]$remaining)
    }
    # #
    # #
    [void] CancelBoost() {
        $this.IsBoosting = $false
        $this.BoostEndTime = [datetime]::MinValue
        $this.BoostProcessName = ""
        $this.BoostDisplayName = ""
        $this.PeakCPU = 0.0
        $this.PeakIO = 0.0
        $this.BoostProcess = $null
    }
    [hashtable] FinishBoost() {
        if ([string]::IsNullOrWhiteSpace($this.BoostProcessName)) { return $null }
        if ($this.PeakCPU -eq 0 -and $this.PeakIO -eq 0) {
            $this.PeakCPU = 1
        }
        # Ostatnia proba pobrania DisplayName jesli nadal = ProcessName
        if ($this.BoostDisplayName -eq $this.BoostProcessName) {
            $this.BoostDisplayName = Get-ProcessDisplayName -ProcessName $this.BoostProcessName
        }
        if ($this.BoostDisplayName.Length -gt 40) {
            $this.BoostDisplayName = $this.BoostDisplayName.Substring(0, 37) + "..."
        }
        $result = @{
            ProcessName = $this.BoostProcessName
            DisplayName = $this.BoostDisplayName
            PeakCPU = $this.PeakCPU
            PeakIO = $this.PeakIO
        }
        $this.IsBoosting = $false
        $this.BoostEndTime = [datetime]::MinValue
        $this.PeakCPU = 0.0
        $this.PeakIO = 0.0
        $this.BoostProcessName = ""
        $this.BoostDisplayName = ""
        $this.BoostProcess = $null
        return $result
    }
    [void] Cleanup() {
        $this.KnownProcessIds.Clear()
        $this.RecentBoosts.Clear()
        if ($this.BoostProcess) {
            try { $this.BoostProcess.Dispose() } catch { }
            $this.BoostProcess = $null
        }
        $this.IsBoosting = $false
        $this.BoostEndTime = [datetime]::MinValue
        $this.BoostProcessName = ""
        $this.BoostDisplayName = ""
    }
}
# ANOMALY DETECTOR - FIXED z limitem historii
class AnomalyDetector {
    [hashtable] $AppProfiles
    [double[]] $CPUHistory
    [double[]] $IOHistory
    [int] $HistoryIndex
    [int] $HistoryCount
    [double] $CPUBaseline
    [double] $CPUStdDev
    [double] $IOBaseline
    [double] $IOStdDev
    [string] $LastCheckTime
    [string] $LastAnomaly
    [double] $AnomalyThreshold = 2.5
    [int] $MaxProfiles = 100
    AnomalyDetector() {
        $this.AppProfiles = @{}
        $this.CPUHistory = [double[]]::new(60)
        $this.IOHistory = [double[]]::new(60)
        $this.HistoryIndex = 0
        $this.HistoryCount = 0
        $this.CPUBaseline = 15.0
        $this.CPUStdDev = 10.0
        $this.IOBaseline = 5.0
        $this.IOStdDev = 5.0
        $this.LastCheckTime = ""
        $this.LastAnomaly = ""
    }
    [void] RecordSample([double]$cpu, [double]$io) {
        $this.CPUHistory[$this.HistoryIndex] = $cpu
        $this.IOHistory[$this.HistoryIndex] = $io
        $this.HistoryIndex = ($this.HistoryIndex + 1) % 60
        if ($this.HistoryCount -lt 60) { $this.HistoryCount++ }
        if ($this.HistoryIndex -eq 0 -and $this.HistoryCount -eq 60) {
            $this.UpdateBaselines()
        }
    }
    [void] UpdateBaselines() {
        if ($this.HistoryCount -lt 10) { return }
        $cpuSum = 0.0; $ioSum = 0.0
        for ($i = 0; $i -lt $this.HistoryCount; $i++) {
            $cpuSum += $this.CPUHistory[$i]
            $ioSum += $this.IOHistory[$i]
        }
        $this.CPUBaseline = $cpuSum / $this.HistoryCount
        $this.IOBaseline = $ioSum / $this.HistoryCount
        $cpuVariance = 0.0; $ioVariance = 0.0
        for ($i = 0; $i -lt $this.HistoryCount; $i++) {
            $cpuVariance += [Math]::Pow($this.CPUHistory[$i] - $this.CPUBaseline, 2)
            $ioVariance += [Math]::Pow($this.IOHistory[$i] - $this.IOBaseline, 2)
        }
        $this.CPUStdDev = [Math]::Max(5.0, [Math]::Sqrt($cpuVariance / $this.HistoryCount))
        $this.IOStdDev = [Math]::Max(2.0, [Math]::Sqrt($ioVariance / $this.HistoryCount))
    }
    [void] UpdateBaseline([string]$processName, [double]$cpu, [double]$io) {
        if ([string]::IsNullOrWhiteSpace($processName)) { return }
        if ($this.AppProfiles.Count -ge $this.MaxProfiles -and -not $this.AppProfiles.ContainsKey($processName)) {
            $oldest = $this.AppProfiles.GetEnumerator() | Sort-Object { $_.Value.Samples } | Select-Object -First 1
            if ($oldest) {
                $this.AppProfiles.Remove($oldest.Key)
            }
        }
        if (-not $this.AppProfiles.ContainsKey($processName)) {
            $this.AppProfiles[$processName] = @{
                Name = $processName
                Samples = 1
                AvgCPU = $cpu
                AvgIO = $io
                MaxCPU = $cpu
                MaxIO = $io
                StdCPU = 10.0
                StdIO = 5.0
                CPUHistory = [System.Collections.Generic.List[double]]::new()
                IOHistory = [System.Collections.Generic.List[double]]::new()
            }
        }
        $myProfile = $this.AppProfiles[$processName]
        $myProfile.Samples++
        $myProfile.CPUHistory.Add($cpu)
        $myProfile.IOHistory.Add($io)
        while ($myProfile.CPUHistory.Count -gt 20) { $myProfile.CPUHistory.RemoveAt(0) }
        while ($myProfile.IOHistory.Count -gt 20) { $myProfile.IOHistory.RemoveAt(0) }
        $alpha = 0.3
        $myProfile.AvgCPU = ($myProfile.AvgCPU * (1 - $alpha)) + ($cpu * $alpha)
        $myProfile.AvgIO = ($myProfile.AvgIO * (1 - $alpha)) + ($io * $alpha)
        if ($cpu -gt $myProfile.MaxCPU) { $myProfile.MaxCPU = $cpu }
        if ($io -gt $myProfile.MaxIO) { $myProfile.MaxIO = $io }
        if ($myProfile.CPUHistory.Count -ge 5) {
            $cpuMean = ($myProfile.CPUHistory | Measure-Object -Average).Average
            $cpuVariance = 0.0
            foreach ($v in $myProfile.CPUHistory) {
                $cpuVariance += [Math]::Pow($v - $cpuMean, 2)
            }
            $myProfile.StdCPU = [Math]::Max(5.0, [Math]::Sqrt($cpuVariance / $myProfile.CPUHistory.Count))
            $ioMean = ($myProfile.IOHistory | Measure-Object -Average).Average
            $ioVariance = 0.0
            foreach ($v in $myProfile.IOHistory) {
                $ioVariance += [Math]::Pow($v - $ioMean, 2)
            }
            $myProfile.StdIO = [Math]::Max(2.0, [Math]::Sqrt($ioVariance / $myProfile.IOHistory.Count))
        }
    }
    [hashtable] CheckForAnomalies([double]$cpu, [double]$io) {
        $this.LastCheckTime = (Get-Date).ToString("HH:mm:ss")
        $this.RecordSample($cpu, $io)
        $result = @{
            IsAnomaly = $false
            Type = ""
            Details = ""
            Severity = 0
        }
        if ($this.HistoryCount -lt 20) { return $result }
        $cpuZScore = 0
        if ($this.CPUStdDev -gt 0) {
            $cpuZScore = ($cpu - $this.CPUBaseline) / $this.CPUStdDev
        }
        $ioZScore = 0
        if ($this.IOStdDev -gt 0) {
            $ioZScore = ($io - $this.IOBaseline) / $this.IOStdDev
        }
        if ($cpuZScore -gt $this.AnomalyThreshold -and $cpu -gt 50) {
            $result.IsAnomaly = $true
            $result.Type = "CPU_SPIKE"
            $result.Details = "CPU $([Math]::Round($cpu))% (Z=$([Math]::Round($cpuZScore, 1)))"
            $result.Severity = [Math]::Min(10, [int]$cpuZScore)
        }
        if ($ioZScore -gt $this.AnomalyThreshold -and $io -gt 100) {
            $result.IsAnomaly = $true
            $result.Type = "IO_STORM"
            $result.Details = "I/O $([Math]::Round($io)) MB/s (Z=$([Math]::Round($ioZScore, 1)))"
            $result.Severity = [Math]::Min(10, [int]$ioZScore)
        }
        if ($cpu -gt 80 -and $io -lt 5) {
            $highCPUCount = 0
            for ($i = 0; $i -lt [Math]::Min(30, $this.HistoryCount); $i++) {
                $idx = ($this.HistoryIndex - 1 - $i + 60) % 60
                if ($this.CPUHistory[$idx] -gt 70) { $highCPUCount++ }
            }
            if ($highCPUCount -gt 20) {
                $result.IsAnomaly = $true
                $result.Type = "CRYPTO_MINER"
                $result.Details = "Sustained high CPU ($highCPUCount/30 samples > 70%)"
                $result.Severity = 9
            }
        }
        if ($result.IsAnomaly) {
            $this.LastAnomaly = $result.Type
        }
        return $result
    }
    [hashtable] FindCulpritProcess() {
        try {
            $processes = Get-Process -ErrorAction SilentlyContinue | 
                         Where-Object { $_.CPU -gt 0 } | 
                         Sort-Object CPU -Descending | 
                         Select-Object -First 5
            foreach ($proc in $processes) {
                $procCPU = 0
                try {
                    $procCPU = [Math]::Round($proc.CPU, 1)
                } catch { }
                if ($procCPU -gt 50) {
                    $result = @{
                        ProcessName = $proc.ProcessName
                        PID = $proc.Id
                        CPU = $procCPU
                        Memory = [Math]::Round($proc.WorkingSet64 / 1MB, 1)
                    }
                    $proc.Dispose()
                    return $result
                }
                $proc.Dispose()
            }
        } catch { }
        return $null
    }
    [hashtable] GetStatus() {
        return @{
            ProfileCount = $this.AppProfiles.Count
            LastCheck = $this.LastCheckTime
            LastAnomaly = $this.LastAnomaly
            CPUBaseline = [Math]::Round($this.CPUBaseline, 1)
            CPUStdDev = [Math]::Round($this.CPUStdDev, 1)
            HistorySamples = $this.HistoryCount
        }
    }
    [int] GetProfileCount() { return $this.AppProfiles.Count }
    [void] SaveProfiles([string]$configDir) {
        try {
            $path = Join-Path $configDir "AnomalyProfiles.json"
            $data = @{
                AppProfiles = @{}
                CPUBaseline = $this.CPUBaseline
                CPUStdDev = $this.CPUStdDev
                IOBaseline = $this.IOBaseline
                IOStdDev = $this.IOStdDev
            }
            foreach ($key in $this.AppProfiles.Keys) {
                $profile = $this.AppProfiles[$key]
                $data.AppProfiles[$key] = @{
                    Name = $profile.Name
                    Samples = $profile.Samples
                    AvgCPU = $profile.AvgCPU
                    AvgIO = $profile.AvgIO
                    MaxCPU = $profile.MaxCPU
                    MaxIO = $profile.MaxIO
                    StdCPU = $profile.StdCPU
                    StdIO = $profile.StdIO
                }
            }
            $json = $data | ConvertTo-Json -Depth 4 -Compress
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadProfiles([string]$configDir) {
        try {
            $path = Join-Path $configDir "AnomalyProfiles.json"
            if (Test-Path $path) {
                $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                $data = $json | ConvertFrom-Json
                if ($null -ne $data.CPUBaseline) { $this.CPUBaseline = [double]$data.CPUBaseline }
                if ($null -ne $data.CPUStdDev) { $this.CPUStdDev = [double]$data.CPUStdDev }
                if ($null -ne $data.IOBaseline) { $this.IOBaseline = [double]$data.IOBaseline }
                if ($null -ne $data.IOStdDev) { $this.IOStdDev = [double]$data.IOStdDev }
                if ($data.AppProfiles) {
                    $data.AppProfiles.PSObject.Properties | ForEach-Object {
                        $profile = $_.Value
                        $this.AppProfiles[$_.Name] = @{
                            Name = $profile.Name
                            Samples = [int]$profile.Samples
                            AvgCPU = [double]$profile.AvgCPU
                            AvgIO = [double]$profile.AvgIO
                            MaxCPU = [double]$profile.MaxCPU
                            MaxIO = [double]$profile.MaxIO
                            StdCPU = [double]$profile.StdCPU
                            StdIO = [double]$profile.StdIO
                            CPUHistory = [System.Collections.Generic.List[double]]::new()
                            IOHistory = [System.Collections.Generic.List[double]]::new()
                        }
                    }
                }
            }
        } catch { }
    }
}
# SELF-TUNING AI ENGINE
class SelfTuner {
    [hashtable] $HourlyProfiles
    [double] $TurboThreshold
    [double] $BalancedThreshold
    [System.Collections.Generic.List[hashtable]] $DecisionHistory
    [int] $MaxHistory = 100
    [double] $LearningRate = 0.1
    [int] $GoodDecisions = 0
    [int] $BadDecisions = 0
    [int] $TotalEvaluations = 0
    [double] $LastReward = 0.0  # V37.8.5: Ostatni reward (do wyswietlania w Configurator)
    SelfTuner() {
        $this.HourlyProfiles = @{}
        $this.TurboThreshold = 75.0
        $this.BalancedThreshold = 30.0
        $this.DecisionHistory = [System.Collections.Generic.List[hashtable]]::new()
        for ($h = 0; $h -lt 24; $h++) {
            $this.HourlyProfiles[$h] = @{
                TurboThreshold = 75.0
                BalancedThreshold = 30.0
                AggressionBias = 0.0
                Samples = 0
                AvgTemp = 50.0
                AvgCPU = 20.0
            }
        }
    }
    [void] RecordDecision([string]$mode, [double]$cpu, [double]$temp, [double]$pressure, [double]$io) {
        $decision = @{
            Time = Get-Date
            Hour = (Get-Date).Hour
            Mode = $mode
            CPU = $cpu
            Temp = $temp
            Pressure = $pressure
            IO = $io
            Evaluated = $false
            Score = 0.0
            CPUAfter = 0.0
            TempAfter = 0.0
        }
        $this.DecisionHistory.Add($decision)
        while ($this.DecisionHistory.Count -gt $this.MaxHistory) {
            $this.DecisionHistory.RemoveAt(0)
        }
    }
    [void] EvaluateDecisions([double]$currentCPU, [double]$currentTemp) {
        $now = Get-Date
        for ($i = 0; $i -lt $this.DecisionHistory.Count; $i++) {
            $decision = $this.DecisionHistory[$i]
            if ($decision.Evaluated) { continue }
            $age = ($now - $decision.Time).TotalSeconds
            if ($age -lt 10 -or $age -gt 60) { continue }
            $decision.CPUAfter = $currentCPU
            $decision.TempAfter = $currentTemp
            $decision.Evaluated = $true
            $score = $this.CalculateScore($decision)
            $decision.Score = $score
            $this.TotalEvaluations++
            if ($score -gt 0.6) {
                $this.GoodDecisions++
                $this.LastReward = $score  # v39: Zapisz reward
            } elseif ($score -lt 0.4) {
                $this.BadDecisions++
                $this.LastReward = -($score)  # v39: Negatywny reward
                $this.AdjustThresholds($decision, $score)
            } else {
                $this.LastReward = 0.0
            }
        }
    }
    [double] CalculateScore([hashtable]$decision) {
        $score = 0.5
        $tempDelta = $decision.TempAfter - $decision.Temp
        $cpuDelta = $decision.CPUAfter - $decision.CPU
        #  SYNC: uses variables z config.json
        switch ($decision.Mode) {
            "Turbo" {
                if ($decision.CPU -gt $Script:BalancedThreshold) { $score += 0.25 }
                elseif ($decision.CPU -lt $Script:ForceSilentCPU) { $score -= 0.25 }
                if ($decision.TempAfter -lt 80) { $score += 0.15 }
                elseif ($decision.TempAfter -gt 90) { $score -= 0.3 }
                if ($tempDelta -gt 15) { $score -= 0.2 }
            }
            "Silent" {
                if ($decision.CPU -lt $Script:ForceSilentCPU) { $score += 0.25 }
                elseif ($decision.CPU -gt $Script:BalancedThreshold) { $score -= 0.2 }
                if ($decision.TempAfter -lt 65) { $score += 0.2 }
                if ($cpuDelta -gt 20) { $score -= 0.15 }
            }
            "Balanced" {
                $score += 0.1
                if ($decision.TempAfter -lt 75) { $score += 0.1 }
            }
        }
        return [Math]::Max(0.0, [Math]::Min(1.0, $score))
    }
    [void] AdjustThresholds([hashtable]$decision, [double]$score) {
        $hour = $decision.Hour
        $profile = $this.HourlyProfiles[$hour]
        $adjustment = $this.LearningRate * (0.5 - $score)
        switch ($decision.Mode) {
            "Turbo" {
                if ($score -lt 0.4) {
                    $profile.TurboThreshold = [Math]::Min(80, $profile.TurboThreshold + $adjustment * 8)
                }
            }
            "Silent" {
                if ($score -lt 0.4 -and $decision.CPU -gt 25) {
                    $profile.BalancedThreshold = [Math]::Max(15, $profile.BalancedThreshold - $adjustment * 5)
                }
            }
        }
        $profile.Samples++
        $alpha = 0.2
        $profile.AvgTemp = ($profile.AvgTemp * (1 - $alpha)) + ($decision.Temp * $alpha)
        $profile.AvgCPU = ($profile.AvgCPU * (1 - $alpha)) + ($decision.CPU * $alpha)
    }
    [hashtable] GetCurrentProfile() {
        $hour = (Get-Date).Hour
        return $this.HourlyProfiles[$hour]
    }
    [double] GetTurboThreshold() {
        $profile = $this.GetCurrentProfile()
        if ($profile.Samples -gt 5) {
            return [Math]::Round($profile.TurboThreshold, 1)
        }
        return $this.TurboThreshold
    }
    [double] GetBalancedThreshold() {
        $profile = $this.GetCurrentProfile()
        if ($profile.Samples -gt 5) {
            return [Math]::Round($profile.BalancedThreshold, 1)
        }
        return $this.BalancedThreshold
    }
    [double] GetRecommendedBias() {
        $profile = $this.GetCurrentProfile()
        if ($profile.Samples -lt 10) { return 0.0 }
        #  SYNC: uses variables z config.json
        if ($profile.AvgCPU -gt $Script:BalancedThreshold) { return 0.15 }
        if ($profile.AvgCPU -lt $Script:ForceSilentCPU -and $profile.AvgTemp -lt 60) { return -0.1 }
        return 0.0
    }
    [double] GetEfficiency() {
        $total = $this.GoodDecisions + $this.BadDecisions
        if ($total -eq 0) { return 0.5 }
        return [Math]::Round($this.GoodDecisions / $total, 2)
    }
    [string] GetStatus() {
        $eff = [Math]::Round($this.GetEfficiency() * 100)
        $turbo = [Math]::Round($this.GetTurboThreshold())
        $balanced = [Math]::Round($this.GetBalancedThreshold())
        return "Eff:$eff% T>$turbo B>$balanced"
    }
    [void] SaveState([string]$configDir) {
        try {
            $path = Join-Path $configDir "SelfTuner.json"
            $profilesData = @{}
            for ($h = 0; $h -lt 24; $h++) {
                $profilesData["$h"] = $this.HourlyProfiles[$h]
            }
            $data = @{
                HourlyProfiles = $profilesData
                TurboThreshold = $this.TurboThreshold
                BalancedThreshold = $this.BalancedThreshold
                GoodDecisions = $this.GoodDecisions
                BadDecisions = $this.BadDecisions
                TotalEvaluations = $this.TotalEvaluations
            }
            $json = $data | ConvertTo-Json -Depth 4 -Compress
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$configDir) {
        try {
            $path = Join-Path $configDir "SelfTuner.json"
            if (Test-Path $path) {
                $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                $data = $json | ConvertFrom-Json
                if ($data.HourlyProfiles) {
                    $data.HourlyProfiles.PSObject.Properties | ForEach-Object {
                        $h = [int]$_.Name
                        $this.HourlyProfiles[$h] = @{
                            TurboThreshold = [double]$_.Value.TurboThreshold
                            BalancedThreshold = [double]$_.Value.BalancedThreshold
                            AggressionBias = [double]$_.Value.AggressionBias
                            Samples = [int]$_.Value.Samples
                            AvgTemp = [double]$_.Value.AvgTemp
                            AvgCPU = [double]$_.Value.AvgCPU
                        }
                    }
                }
                if ($null -ne $data.GoodDecisions) { $this.GoodDecisions = [int]$data.GoodDecisions }
                if ($null -ne $data.BadDecisions) { $this.BadDecisions = [int]$data.BadDecisions }
                if ($null -ne $data.TotalEvaluations) { $this.TotalEvaluations = [int]$data.TotalEvaluations }
            }
        } catch { }
    }
}
# PROCESS CHAIN PREDICTION
class ChainPredictor {
    [hashtable] $TransitionGraph
    [string] $LastApp
    [datetime] $LastAppTime
    [System.Collections.Generic.List[string]] $RecentChain
    [int] $MaxChainLength = 10
    [int] $MinConfidence = 2
    [string] $CurrentPrediction
    [double] $PredictionConfidence
    [bool] $PreBoostActive
    [string] $PreBoostTarget
    [int] $CorrectPredictions = 0
    [int] $TotalPredictions = 0
    ChainPredictor() {
        $this.TransitionGraph = @{}
        $this.LastApp = ""
        $this.LastAppTime = Get-Date
        $this.RecentChain = [System.Collections.Generic.List[string]]::new()
        $this.CurrentPrediction = ""
        $this.PredictionConfidence = 0.0
        $this.PreBoostActive = $false
        $this.PreBoostTarget = ""
    }
    [void] RecordAppLaunch([string]$appName) {
        if ([string]::IsNullOrWhiteSpace($appName)) { return }
        $now = Get-Date
        if ($this.PreBoostActive) {
            $this.TotalPredictions++
            if ($this.PreBoostTarget -eq $appName) {
                $this.CorrectPredictions++
            }
            $this.PreBoostActive = $false
            $this.PreBoostTarget = ""
        }
        if (![string]::IsNullOrWhiteSpace($this.LastApp) -and $this.LastApp -ne $appName) {
            $timeDiff = ($now - $this.LastAppTime).TotalSeconds
            if ($timeDiff -lt 600 -and $timeDiff -gt 0.5) {
                if (-not $this.TransitionGraph.ContainsKey($this.LastApp)) {
                    $this.TransitionGraph[$this.LastApp] = @{}
                }
                if (-not $this.TransitionGraph[$this.LastApp].ContainsKey($appName)) {
                    $this.TransitionGraph[$this.LastApp][$appName] = @{
                        Count = 0
                        AvgTime = $timeDiff
                        TotalTime = 0.0
                    }
                }
                $transition = $this.TransitionGraph[$this.LastApp][$appName]
                $transition.Count++
                $transition.TotalTime += $timeDiff
                $transition.AvgTime = $transition.TotalTime / $transition.Count
            }
        }
        $this.RecentChain.Add($appName)
        while ($this.RecentChain.Count -gt $this.MaxChainLength) {
            $this.RecentChain.RemoveAt(0)
        }
        $this.LastApp = $appName
        $this.LastAppTime = $now
        $this.UpdatePrediction()
    }
    [void] UpdatePrediction() {
        $this.CurrentPrediction = ""
        $this.PredictionConfidence = 0.0
        if ([string]::IsNullOrWhiteSpace($this.LastApp)) { return }
        if (-not $this.TransitionGraph.ContainsKey($this.LastApp)) { return }
        $transitions = $this.TransitionGraph[$this.LastApp]
        $totalTransitions = 0
        $bestApp = ""
        $bestCount = 0
        foreach ($app in $transitions.Keys) {
            $count = $transitions[$app].Count
            $totalTransitions += $count
            if ($count -gt $bestCount) {
                $bestCount = $count
                $bestApp = $app
            }
        }
        if ($bestCount -ge $this.MinConfidence -and $totalTransitions -gt 0) {
            $this.CurrentPrediction = $bestApp
            $this.PredictionConfidence = [Math]::Round($bestCount / $totalTransitions, 2)
        }
    }
    [double] GetExpectedTime() {
        if ([string]::IsNullOrWhiteSpace($this.LastApp)) { return 0 }
        if ([string]::IsNullOrWhiteSpace($this.CurrentPrediction)) { return 0 }
        if (-not $this.TransitionGraph.ContainsKey($this.LastApp)) { return 0 }
        if (-not $this.TransitionGraph[$this.LastApp].ContainsKey($this.CurrentPrediction)) { return 0 }
        return $this.TransitionGraph[$this.LastApp][$this.CurrentPrediction].AvgTime
    }
    [bool] ShouldPreBoost() {
        if ([string]::IsNullOrWhiteSpace($this.CurrentPrediction)) { return $false }
        [double]$minConf = 0.4
        if ($Script:ConfidenceThreshold -and $Script:ConfidenceThreshold -gt 0) { 
            $minConf = $Script:ConfidenceThreshold / 100.0 
        }
        if ($this.PredictionConfidence -lt $minConf) { return $false }
        if ($this.PreBoostActive) { return $false }
        $expectedTime = $this.GetExpectedTime()
        $timeSinceLast = ((Get-Date) - $this.LastAppTime).TotalSeconds
        if ($expectedTime -gt 3 -and $timeSinceLast -gt ($expectedTime * 0.4) -and $timeSinceLast -lt ($expectedTime * 0.85)) {
            $this.PreBoostActive = $true
            $this.PreBoostTarget = $this.CurrentPrediction
            return $true
        }
        return $false
    }
    [string] GetPredictionStatus() {
        if ([string]::IsNullOrWhiteSpace($this.CurrentPrediction)) {
            return "No prediction"
        }
        $conf = [Math]::Round($this.PredictionConfidence * 100)
        $expected = [Math]::Round($this.GetExpectedTime())
        $predName = $this.CurrentPrediction
        if ($predName.Length -gt 15) {
            $predName = $predName.Substring(0, 12) + "..."
        }
        return "$predName ($conf%, ~${expected}s)"
    }
    [double] GetAccuracy() {
        if ($this.TotalPredictions -eq 0) { return 0 }
        return [Math]::Round($this.CorrectPredictions / $this.TotalPredictions, 2)
    }
    [int] GetChainCount() {
        $count = 0
        foreach ($app in $this.TransitionGraph.Keys) {
            $count += $this.TransitionGraph[$app].Count
        }
        return $count
    }
    [string] GetRecentChainDisplay() {
        if ($this.RecentChain.Count -eq 0) { return "" }
        $display = @()
        $lastItems = $this.RecentChain | Select-Object -Last 3
        foreach ($item in $lastItems) {
            $name = $item
            if ($name.Length -gt 10) { $name = $name.Substring(0, 7) + "..." }
            $display += $name
        }
        return ($display -join " -> ")
    }
    [void] SaveState([string]$configDir) {
        try {
            $path = Join-Path $configDir "ChainPredictor.json"
            $graphData = @{}
            foreach ($fromApp in $this.TransitionGraph.Keys) {
                $graphData[$fromApp] = @{}
                foreach ($toApp in $this.TransitionGraph[$fromApp].Keys) {
                    $graphData[$fromApp][$toApp] = $this.TransitionGraph[$fromApp][$toApp]
                }
            }
            $data = @{
                TransitionGraph = $graphData
                LastApp = $this.LastApp
                CorrectPredictions = $this.CorrectPredictions
                TotalPredictions = $this.TotalPredictions
            }
            $json = $data | ConvertTo-Json -Depth 5 -Compress
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$configDir) {
        try {
            $path = Join-Path $configDir "ChainPredictor.json"
            if (Test-Path $path) {
                $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                $data = $json | ConvertFrom-Json
                if ($data.TransitionGraph) {
                    $data.TransitionGraph.PSObject.Properties | ForEach-Object {
                        $fromApp = $_.Name
                        $this.TransitionGraph[$fromApp] = @{}
                        $_.Value.PSObject.Properties | ForEach-Object {
                            $toApp = $_.Name
                            $this.TransitionGraph[$fromApp][$toApp] = @{
                                Count = [int]$_.Value.Count
                                AvgTime = [double]$_.Value.AvgTime
                                TotalTime = [double]$_.Value.TotalTime
                            }
                        }
                    }
                }
                if ($data.LastApp) { $this.LastApp = $data.LastApp }
                if ($null -ne $data.CorrectPredictions) { $this.CorrectPredictions = [int]$data.CorrectPredictions }
                if ($null -ne $data.TotalPredictions) { $this.TotalPredictions = [int]$data.TotalPredictions }
            }
        } catch { }
    }
}
# CONTEXT DETECTOR - Wykrywanie kontekstu pracy (Gaming/Coding/Multimedia/Idle)
class ContextDetector {
    [string] $CurrentContext
    [hashtable] $ContextPatterns
    [hashtable] $ActiveApps
    [datetime] $LastContextChange
    [int] $ContextStability
    ContextDetector() {
        $this.CurrentContext = "Idle"
        $this.LastContextChange = Get-Date
        $this.ContextStability = 0
        $this.ActiveApps = @{}
        # Definicje kontekstow - aplikacje charakterystyczne
        $this.ContextPatterns = @{
            Gaming = @{
                Apps = @("steam", "epicgameslauncher", "origin", "uplay", "battlenet", "gog", 
                         "csgo", "dota2", "valorant", "fortnite", "minecraft", "roblox",
                         "witcher", "cyberpunk", "gta", "apex", "overwatch", "leagueoflegends",
                         "shipping", "win64", "game", "dx11", "dx12", "vulkan", "unity",
                         "tormented", "baldur", "elden", "hogwarts", "starfield", "diablo",
                         "callisto", "resident", "evil", "souls", "palworld", "helldivers")
                CpuMin = 20
                Priority = 1
                Mode = "Turbo"  # Gaming needs performance
            }
            Audio = @{
                Apps = @("cubase", "cubase13", "cubase12", "cubase11", "cubase10",
                         "studioone", "studio one", "presonus",
                         "reaper", "reaper64",
                         "ableton", "ableton live", "live",
                         "flstudio", "fl64", "fl",
                         "bitwig", "bitwig studio",
                         "protools", "pro tools", "avid",
                         "logic", "logicpro", "garageband",
                         "ardour", "audacity", "audition", "adobe audition",
                         "reason", "lmms", "cakewalk", "sonar", "bandlab",
                         "nuendo", "wavelab", "soundforge",
                         # Native Instruments
                         "kontakt", "komplete", "reaktor", "massive", "fm8", "absynth",
                         "battery", "maschine", "guitar rig",
                         # Xfer / Popularne synthy
                         "serum", "serumfx", "lfotool", "cthulhu",
                         "omnisphere", "nexus", "sylenth", "spire", "diva", "hive",
                         "vst", "vsthost", "vstbridge", "jbridge",
                         "asio4all", "focusrite", "scarlett",
                         # ARTURIA V COLLECTION 11 - WSZYSTKIE 45
                         # Analog Lab
                         "analog lab", "analoglab", "analog lab pro",
                         # Pigments
                         "pigments", "pigments 4", "pigments 5",
                         # Pure LoFi
                         "pure lofi", "purelofi",
                         # ----- SYNTHY ANALOGOWE -----
                         # Mini V (Minimoog)
                         "mini v", "miniv", "mini v4", "minimoog",
                         # MiniBrute V
                         "minibrute", "minibrute v", "minibrutev",
                         # MiniFreak V
                         "minifreak", "minifreak v", "minifreakv",
                         # Jun-6 V (Juno-6/60)
                         "jun-6", "jun6", "jun-6 v", "jun6v", "juno",
                         # Jup-8 V (Jupiter-8)
                         "jup-8", "jup8", "jup-8 v", "jup8v", "jupiter",
                         # CS-80 V (Yamaha CS-80)
                         "cs-80", "cs80", "cs-80 v", "cs80v",
                         # Prophet-5 V
                         "prophet-5", "prophet5", "prophet-5 v", "prophet5v", "prophet v", "prophetv",
                         # Prophet-VS V
                         "prophet-vs", "prophetvs", "prophet-vs v", "prophetvsv",
                         # OB-Xa V (Oberheim)
                         "ob-xa", "obxa", "ob-xa v", "obxav", "oberheim",
                         # Matrix-12 V
                         "matrix-12", "matrix12", "matrix-12 v", "matrix12v",
                         # SEM V (Oberheim SEM)
                         "sem", "sem v", "semv",
                         # ARP 2600 V
                         "arp 2600", "arp2600", "arp 2600 v", "arp2600v",
                         # Modular V (Moog Modular)
                         "modular v", "modularv",
                         # Buchla Easel V
                         "buchla", "buchla easel", "buchla easel v",
                         # Synthi V (EMS Synthi)
                         "synthi", "synthi v", "synthiv", "ems",
                         # Vocoder V
                         "vocoder", "vocoder v", "vocoderv",
                         # Acid V (TB-303)
                         "acid v", "acidv", "acid",
                         # Synthx V (Elka Synthex)
                         "synthx", "synthx v", "synthxv", "elka", "synthex",
                         # ----- SYNTHY CYFROWE -----
                         # DX7 V (Yamaha DX7)
                         "dx7", "dx7 v", "dx7v",
                         # CZ V (Casio CZ)
                         "cz v", "czv", "casio cz",
                         # SQ80 V (Ensoniq SQ-80)
                         "sq80", "sq-80", "sq80 v", "sq80v", "ensoniq",
                         # Synclavier V
                         "synclavier", "synclavier v", "synclavierv",
                         # ----- SAMPLERY -----
                         # CMI V (Fairlight CMI)
                         "cmi", "cmi v", "cmiv", "fairlight",
                         # Emulator II V
                         "emulator", "emulator ii", "emulator ii v", "e-mu",
                         # Mellotron V
                         "mellotron", "mellotron v", "mellotronv",
                         # ----- PIANINA / ORGANY / KEYS -----
                         # Piano V
                         "piano v", "pianov",
                         # Stage-73 V (Rhodes)
                         "stage-73", "stage73", "stage-73 v", "stage73v", "rhodes",
                         # Wurli V (Wurlitzer)
                         "wurli", "wurli v", "wurliv", "wurlitzer",
                         # B-3 V (Hammond B3)
                         "b-3", "b3", "b-3 v", "b3v", "hammond",
                         # Vox Continental V
                         "vox continental", "vox", "vox continental v",
                         # Farfisa V
                         "farfisa", "farfisa v", "farfisav",
                         # Solina V (ARP Solina)
                         "solina", "solina v", "solinav",
                         # Clavinet V
                         "clavinet", "clavinet v", "clavinetv",
                         # ----- AUGMENTED SERIES -----
                         "augmented strings", "augmented voices",
                         "augmented brass", "augmented woodwinds",
                         "augmented grand piano", "augmented piano",
                         "augmented mallets", "augmented yangtze",
                         # ----- EFEKTY ARTURIA -----
                         "efx motions", "efx fragments", "efx refract",
                         "rev plate-140", "rev spring-636", "rev intensity",
                         "delay tape-201", "delay memory-brigade", "delay eternity",
                         "comp vca-65", "comp fet-76", "comp diode-609",
                         "pre trida", "pre v76", "pre 1973",
                         "filter mini", "filter sem", "filter m12",
                         "bus force", "tape mello-fi",
                         # INNE POPULARNE VST
                         "fabfilter", "fab filter", "pro-q", "pro-c", "pro-l", "pro-r", "pro-mb",
                         "izotope", "ozone", "neutron", "rx", "nectar", "vocalsynth",
                         "waves", "waveshell",
                         "soundtoys", "decapitator", "echoboy", "crystallizer",
                         "u-he", "zebra", "repro", "diva", "hive", "bazille", "ace",
                         "xfer", "lfotool", "cthulhu",
                         "spectrasonics", "keyscape", "trilian",
                         "toontrack", "superior drummer", "ezdrummer", "ezbass", "ezkeys",
                         "addictive drums", "addictive keys", "xln audio",
                         "amplitube", "bias", "helix native",
                         "melodyne", "autotune", "antares",
                         "eventide", "blackhole", "h3000", "ultratap",
                         "valhalla", "valhalla vintage", "valhalla room", "valhalla delay",
                         "slate digital", "virtual mix rack", "fg-x",
                         "plugin alliance", "brainworx",
                         "softube", "console 1", "harmonics",
                         "neural dsp", "archetype", "quad cortex")
                CpuMin = 5
                Priority = 1
                Mode = "Balanced"  # Audio = Balanced, fast response but stable
            }
            Rendering = @{
                Apps = @("blender", "premiere", "aftereffects", "davinci", "vegas", 
                         "handbrake", "ffmpeg", "obs", "streamlabs", "kdenlive")
                CpuMin = 60
                Priority = 2
                Mode = "Turbo"  # Rendering needs max performance
            }
            Coding = @{
                Apps = @("code", "visualstudio", "devenv", "idea", "pycharm", "webstorm",
                         "eclipse", "netbeans", "android studio", "xcode", "rider",
                         "powershell", "windowsterminal", "cmd", "git", "node")
                CpuMin = 10
                Priority = 3
                Mode = "Balanced"
            }
            Multimedia = @{
                Apps = @("spotify", "vlc", "netflix", "youtube", "prime video", "disney",
                         "plex", "kodi", "musicbee", "foobar2000", "winamp", "itunes")
                CpuMin = 5
                Priority = 4
                Mode = "Silent"
            }
            Browsing = @{
                Apps = @("chrome", "firefox", "opera", "brave", "vivaldi", 
                         "iexplore", "chromium", "tor")
                CpuMin = 5
                Priority = 5
                Mode = "Balanced"
            }
            Office = @{
                Apps = @("winword", "excel", "powerpnt", "outlook", "teams", "slack",
                         "zoom", "discord", "skype", "onenote", "notion", "obsidian")
                CpuMin = 5
                Priority = 6
                Mode = "Balanced"
            }
        }
    }
    [void] UpdateActiveApps([string]$foregroundApp, [double]$cpu) {
        $now = Get-Date
        $app = $foregroundApp.ToLower()
        if (-not $this.ActiveApps.ContainsKey($app)) {
            $this.ActiveApps[$app] = @{
                LastSeen = $now
                TotalTime = 0
                AvgCPU = $cpu
                Samples = 1
            }
        } else {
            $entry = $this.ActiveApps[$app]
            $entry.LastSeen = $now
            $entry.Samples++
            $entry.AvgCPU = ($entry.AvgCPU * ($entry.Samples - 1) + $cpu) / $entry.Samples
        }
        # Usun nieaktywne aplikacje (> 5 minut)
        $keysToRemove = @()
        foreach ($key in $this.ActiveApps.Keys) {
            if (($now - $this.ActiveApps[$key].LastSeen).TotalMinutes -gt 5) {
                $keysToRemove += $key
            }
        }
        foreach ($key in $keysToRemove) {
            $this.ActiveApps.Remove($key)
        }
    }
    [string] DetectContext([double]$cpu) {
        return $this.DetectContext($cpu, 0.0, 0.0)
    }
    [string] DetectContext([double]$cpu, [double]$gpu, [double]$io) {
        $detectedContext = "Idle"
        $highestPriority = 999
        # 1. NAME-BASED: sprawdź znane wzorce (istniejąca logika)
        foreach ($contextName in $this.ContextPatterns.Keys) {
            $pattern = $this.ContextPatterns[$contextName]
            foreach ($patternApp in $pattern.Apps) {
                foreach ($activeApp in $this.ActiveApps.Keys) {
                    if ($activeApp -like "*$patternApp*") {
                        if ($cpu -ge $pattern.CpuMin -and $pattern.Priority -lt $highestPriority) {
                            $detectedContext = $contextName
                            $highestPriority = $pattern.Priority
                        }
                    }
                }
            }
        }
        # 2. BEHAVIOR-BASED: jeśli name matching nie znalazł nic ciekawego,
        #    wykryj kontekst z ZACHOWANIA (GPU+CPU+IO metryki)
        if ($detectedContext -eq "Idle" -and $highestPriority -eq 999) {
            # GPU>70% + CPU>15% = coś ciężkiego graficznie (gra, render, AI)
            if ($gpu -gt 70 -and $cpu -gt 15) {
                $detectedContext = "Gaming"
                $highestPriority = 1
            }
            # GPU>50% + CPU<30% = GPU-bound rendering/game
            elseif ($gpu -gt 50 -and $cpu -lt 30) {
                $detectedContext = "Rendering"
                $highestPriority = 2
            }
            # CPU>60% + GPU<20% = heavy compute (kompilacja, encoding, nauka)
            elseif ($cpu -gt 60 -and $gpu -lt 20) {
                $detectedContext = "Coding"
                $highestPriority = 3
            }
            # I/O>100MB/s + CPU>30% = heavy loading/transfer
            elseif ($io -gt 100 -and $cpu -gt 30) {
                $detectedContext = "Work"
                $highestPriority = 4
            }
            # CPU>40% = aktywna praca (25-40% to szara strefa - mogą to być procesy tła przy Idle)
            elseif ($cpu -gt 40) {
                $detectedContext = "Work"
                $highestPriority = 5
            }
        }
        # Aktualizuj stabilnosc kontekstu
        if ($detectedContext -eq $this.CurrentContext) {
            $this.ContextStability = [Math]::Min(100, $this.ContextStability + 5)
        } else {
            $this.ContextStability = [Math]::Max(0, $this.ContextStability - 10)
            # Zmien kontekst tylko gdy stabilnosc spadnie do 0
            if ($this.ContextStability -eq 0) {
                $this.CurrentContext = $detectedContext
                $this.LastContextChange = Get-Date
                $this.ContextStability = 20
            }
        }
        return $this.CurrentContext
    }
    [string] GetRecommendedMode() {
        if ($this.ContextPatterns.ContainsKey($this.CurrentContext)) {
            return $this.ContextPatterns[$this.CurrentContext].Mode
        }
        return "Balanced"
    }
    [string] GetStatus() {
        $stability = $this.ContextStability
        return "$($this.CurrentContext) ($stability%)"
    }
    [void] SaveState([string]$dir) {
        try {
            $data = @{
                ContextPatterns = $this.ContextPatterns
            }
            $path = Join-Path $dir "ContextPatterns.json"
            $data | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding UTF8
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "ContextPatterns.json"
            if (Test-Path $path) {
                $data = Get-Content $path -Raw | ConvertFrom-Json
                if ($data.ContextPatterns) {
                    foreach ($prop in $data.ContextPatterns.PSObject.Properties) {
                        if ($this.ContextPatterns.ContainsKey($prop.Name)) {
                            $this.ContextPatterns[$prop.Name].Mode = $prop.Value.Mode
                            $this.ContextPatterns[$prop.Name].Priority = $prop.Value.Priority
                        }
                    }
                }
            }
        } catch { }
    }
}
# ═══════════════════════════════════════════════════════════════════════════════
# PHASE DETECTOR - Wykrywanie fazy działania aplikacji (Loading/Menu/Gameplay/Cutscene/Idle)
# ETAP 1: Tylko detekcja + logowanie, BEZ wpływu na decyzje
# ═══════════════════════════════════════════════════════════════════════════════
class PhaseDetector {
    [string]$CurrentPhase
    [string]$PreviousPhase
    [string]$CurrentApp
    [DateTime]$PhaseStart
    [int]$WindowSize
    [System.Collections.Generic.List[hashtable]]$MetricsWindow
    [hashtable]$AppPhaseHistory  # per-app: ile czasu w każdej fazie
    [int]$PhaseChanges
    [DateTime]$LastLogTime
    # v43.14: Pause Detection
    [double]$AppPeakGPU          # Peak GPU load gdy app była aktywna
    [double]$AppPeakCPU          # Peak CPU load
    [int]$LowActivityCount       # Ile próbek z niskim CPU+GPU (pauza?)
    [int]$PauseThresholdSamples  # Po ilu próbkach uznajemy pauzę

    PhaseDetector() {
        $this.CurrentPhase = "Idle"
        $this.PreviousPhase = "Idle"
        $this.CurrentApp = ""
        $this.PhaseStart = [DateTime]::UtcNow
        $this.WindowSize = 12  # ~24 sekund przy 2s/iter
        $this.MetricsWindow = [System.Collections.Generic.List[hashtable]]::new()
        $this.AppPhaseHistory = @{}
        $this.PhaseChanges = 0
        $this.LastLogTime = [DateTime]::MinValue
        $this.AppPeakGPU = 0
        $this.AppPeakCPU = 0
        $this.LowActivityCount = 0
        $this.PauseThresholdSamples = 5  # 5 próbek (~10s) niskiego load = pauza
    }

    [void] Update([string]$app, [double]$cpu, [double]$gpu, [double]$io, [double]$temp) {
        # Zmiana aplikacji → reset okna
        if ($app -ne $this.CurrentApp -and $app -ne "Desktop" -and $app -ne "") {
            $this.RecordPhaseTime()
            $this.MetricsWindow.Clear()
            $this.CurrentApp = $app
            $this.CurrentPhase = "Loading"  # Nowa app = zakładaj loading
            $this.PhaseStart = [DateTime]::UtcNow
            $this.AppPeakGPU = 0; $this.AppPeakCPU = 0; $this.LowActivityCount = 0
        }

        # Dodaj sample do okna
        $sample = @{
            CPU = $cpu
            GPU = $gpu
            IO = $io
            Temp = $temp
            Time = [DateTime]::UtcNow
        }
        $this.MetricsWindow.Add($sample)
        if ($this.MetricsWindow.Count -gt $this.WindowSize) {
            $this.MetricsWindow.RemoveAt(0)
        }

        # Potrzeba min 4 sampli do detekcji
        if ($this.MetricsWindow.Count -lt 4) { return }

        # Oblicz statystyki okna
        $avgCPU = ($this.MetricsWindow | ForEach-Object { $_.CPU } | Measure-Object -Average).Average
        $avgGPU = ($this.MetricsWindow | ForEach-Object { $_.GPU } | Measure-Object -Average).Average
        $avgIO = ($this.MetricsWindow | ForEach-Object { $_.IO } | Measure-Object -Average).Average
        $maxCPU = ($this.MetricsWindow | ForEach-Object { $_.CPU } | Measure-Object -Maximum).Maximum
        $maxGPU = ($this.MetricsWindow | ForEach-Object { $_.GPU } | Measure-Object -Maximum).Maximum
        
        # Zmienność CPU (odchylenie standardowe)
        $cpuValues = @($this.MetricsWindow | ForEach-Object { $_.CPU })
        $cpuVariance = 0
        if ($cpuValues.Count -gt 1) {
            $cpuMean = $avgCPU
            $cpuVariance = [Math]::Sqrt(($cpuValues | ForEach-Object { ($_ - $cpuMean) * ($_ - $cpuMean) } | Measure-Object -Average).Average)
        }

        # v43.14: PAUSE DETECTION - śledzenie peak load i nagłego spadku
        # Aktualizuj peak (zapamiętaj najwyższy load tej app)
        if ($cpu -gt $this.AppPeakCPU) { $this.AppPeakCPU = $cpu }
        if ($gpu -gt $this.AppPeakGPU) { $this.AppPeakGPU = $gpu }
        
        # Reset peak przy zmianie app (w bloku wyżej, ale tu safety)
        if ($app -ne $this.CurrentApp) { 
            $this.AppPeakGPU = 0; $this.AppPeakCPU = 0; $this.LowActivityCount = 0 
        }
        
        # Sprawdź czy app jest spauzowana:
        # Peak GPU był >50% ALE teraz GPU<15% i CPU<15% = pauza
        $isPaused = $false
        if ($this.AppPeakGPU -gt 50 -and $avgGPU -lt 15 -and $avgCPU -lt 15) {
            $this.LowActivityCount++
            if ($this.LowActivityCount -ge $this.PauseThresholdSamples) {
                $isPaused = $true
            }
        } elseif ($this.AppPeakCPU -gt 60 -and $avgCPU -lt 10 -and $avgGPU -lt 10) {
            # CPU-heavy app (np. kompilacja) spauzowana
            $this.LowActivityCount++
            if ($this.LowActivityCount -ge $this.PauseThresholdSamples) {
                $isPaused = $true
            }
        } else {
            $this.LowActivityCount = [Math]::Max(0, $this.LowActivityCount - 1)  # Powolny decay
        }

        # Wykryj fazę
        $detectedPhase = if ($isPaused) { "Paused" } else { $this.ClassifyPhase($avgCPU, $avgGPU, $avgIO, $maxCPU, $maxGPU, $cpuVariance) }

        # Zmień fazę tylko gdy stabilna (3+ sampli potwierdza)
        if ($detectedPhase -ne $this.CurrentPhase) {
            $this.PreviousPhase = $this.CurrentPhase
            $this.RecordPhaseTime()
            $this.CurrentPhase = $detectedPhase
            $this.PhaseStart = [DateTime]::UtcNow
            $this.PhaseChanges++
        }
    }

    [string] ClassifyPhase([double]$avgCPU, [double]$avgGPU, [double]$avgIO, [double]$maxCPU, [double]$maxGPU, [double]$cpuVar) {
        # LOADING: Wysoki I/O (dysk pracuje = wczytywanie)
        if ($avgIO -gt 100) {
            return "Loading"
        }
        # LOADING: Wysoki CPU + niski GPU = ładowanie assetów/shaderów
        # ALE tylko gdy GPU < 50%! Jeśli GPU jest wysoki → to Gameplay ze spike'ami CPU
        if ($avgCPU -gt 70 -and $avgGPU -lt 30) {
            return "Loading"
        }
        # CPU spike + niski GPU = start/kompilacja shaderów
        # Kluczowe: maxGPU < 50% odróżnia loading od gameplay z CPU spike'ami
        if ($maxCPU -gt 85 -and $avgGPU -lt 25 -and $maxGPU -lt 40) {
            return "Loading"
        }

        # IDLE: Niskie wszystko (CPU < 10% AND GPU < 15%)
        if ($avgCPU -lt 10 -and $avgGPU -lt 15) {
            return "Idle"
        }

        # MENU: Niski CPU, umiarkowany GPU (renderuje menu/UI), niska zmienność
        if ($avgCPU -lt 25 -and $avgGPU -gt 15 -and $avgGPU -lt 55 -and $cpuVar -lt 12) {
            return "Menu"
        }

        # CUTSCENE: GPU renderuje ale CPU stabilny i niski = pre-rendered/scripted scene
        # MUSI być PRZED Gameplay! Cutscenka ma wysoki GPU ale CPU jest spokojny
        # Kluczowe: cpuVar < 8 (bardzo stabilny) + avgCPU < 50 (CPU nie pracuje ciężko)
        # v43.15: GPU < 70% — powyżej to GPU-bound Gameplay, nie cutscene!
        if ($avgGPU -gt 30 -and $avgGPU -lt 70 -and $avgCPU -lt 50 -and $cpuVar -lt 8) {
            return "Cutscene"
        }

        # GAMEPLAY: GPU-bound — wysoki GPU + niski CPU = gra napędzana kartą graficzną
        # v43.15: EOTL (GPU=82% CPU=26%), The Medium (GPU=87% CPU=50%) etc.
        # Te gry mają stabilny niski CPU ale GPU ciężko pracuje — to GAMEPLAY nie Cutscene
        if ($avgGPU -ge 70 -and $avgCPU -lt 50) {
            return "Gameplay"
        }

        # GAMEPLAY: Wysoki GPU + CPU aktywny lub zmienny
        # GPU > 60% + (CPU > 50% LUB cpuVar > 8) = aktywna gra (fizyka, AI, input)
        if ($avgGPU -gt 60 -and ($avgCPU -gt 50 -or $cpuVar -gt 8)) {
            return "Gameplay"
        }

        # GAMEPLAY: Umiarkowany GPU + aktywny CPU + zmienność
        # v43.14: Zaostrzony - avgGPU > 40 wymagany (Chrome GPU=14% to NIE gra)
        # cpuVar > 10 odróżnia grę (zmienny CPU) od pracy (stabilny CPU)
        if ($avgGPU -gt 40 -and $avgCPU -gt 30 -and $cpuVar -gt 10) {
            return "Gameplay"
        }

        # ACTIVE: CPU aktywne ale bez GPU (kompilacja, przetwarzanie)
        if ($avgCPU -gt 35 -and $avgGPU -lt 15) {
            return "Active"
        }
        
        # ACTIVE: CPU umiarkowane + GPU umiarkowane (syntezatory audio, edytory, DAW)
        # CPU=25-60% + GPU=15-40% + cpuVar stabilny = praca kreatywna, nie gaming
        if ($avgCPU -gt 25 -and $avgGPU -ge 15 -and $avgGPU -lt 40 -and $cpuVar -lt 10) {
            return "Active"
        }

        return "Idle"
    }

    [void] RecordPhaseTime() {
        if ($this.CurrentApp -and $this.CurrentApp -ne "Desktop") {
            $duration = ([DateTime]::UtcNow - $this.PhaseStart).TotalSeconds
            if (-not $this.AppPhaseHistory.ContainsKey($this.CurrentApp)) {
                $this.AppPhaseHistory[$this.CurrentApp] = @{
                    Loading = 0.0; Menu = 0.0; Gameplay = 0.0
                    Cutscene = 0.0; Active = 0.0; Idle = 0.0
                }
            }
            if ($this.AppPhaseHistory[$this.CurrentApp].ContainsKey($this.CurrentPhase)) {
                $this.AppPhaseHistory[$this.CurrentApp][$this.CurrentPhase] += $duration
            }
        }
    }

    [string] GetStatus() {
        $dur = [int]([DateTime]::UtcNow - $this.PhaseStart).TotalSeconds
        return "$($this.CurrentApp): $($this.CurrentPhase) (${dur}s)"
    }

    [hashtable] GetAppProfile([string]$app) {
        if ($this.AppPhaseHistory.ContainsKey($app)) {
            return $this.AppPhaseHistory[$app]
        }
        return @{}
    }

    [string] GetRecommendedMode() {
        $result = "Balanced"
        switch ($this.CurrentPhase) {
            "Loading"  { $result = "Turbo" }
            "Gameplay" { $result = "Balanced" }
            "Active"   { $result = "Turbo" }
            "Menu"     { $result = "Silent" }
            "Cutscene" { $result = "Silent" }
            "Idle"     { $result = "Silent" }
            "Paused"   { $result = "Silent" }
        }
        return $result
    }

    [void] SaveState([string]$dir) {
        try {
            $data = @{
                AppPhaseHistory = $this.AppPhaseHistory
                PhaseChanges = $this.PhaseChanges
            }
            $path = Join-Path $dir "PhaseDetector.json"
            $data | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding UTF8
        } catch {}
    }

    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "PhaseDetector.json"
            if (Test-Path $path) {
                $data = Get-Content $path -Raw | ConvertFrom-Json
                if ($data.AppPhaseHistory) {
                    foreach ($prop in $data.AppPhaseHistory.PSObject.Properties) {
                        $this.AppPhaseHistory[$prop.Name] = @{}
                        foreach ($phase in $prop.Value.PSObject.Properties) {
                            $this.AppPhaseHistory[$prop.Name][$phase.Name] = [double]$phase.Value
                        }
                    }
                }
                if ($data.PhaseChanges) { $this.PhaseChanges = [int]$data.PhaseChanges }
            }
        } catch {}
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# FAN CONTROLLER - Inteligentne sterowanie wentylatorami via LHM/OHM
# Szybkie zbijanie RPM gdy temp spada (nie czekaj na EC ramp-down)
# ═══════════════════════════════════════════════════════════════════════════════
class FanController {
    [string] $Source = ""        # "LHM" lub "OHM"
    [bool] $CanControl = $false  # Czy mamy dostęp do Control sensors
    [bool] $CanRead = $false     # Czy mamy odczyt RPM
    [bool] $Enabled = $false     # Czy user włączył fan control
    [bool] $IsOverriding = $false # Czy aktualnie nadpisujemy EC
    [int] $CurrentRPM = 0
    [int] $TargetPercent = -1    # -1 = auto (EC), 0-100 = manual
    [double] $LastTemp = 0
    [double] $TempDropRate = 0   # °C/s - jak szybko temp spada
    [datetime] $LastUpdate = [datetime]::MinValue
    [datetime] $OverrideStart = [datetime]::MinValue
    [int] $MaxOverrideSeconds = 120  # Max 2min override, potem oddaj EC
    [hashtable] $FanSensorIds = @{}  # Identifier → Name mapping
    [hashtable] $ControlSensorIds = @{}
    # Learned thermal curve
    [System.Collections.Generic.List[hashtable]] $ThermalHistory
    [int] $SafeTemp = 75         # Powyżej tej temp NIGDY nie obniżaj fanów
    
    FanController() {
        $this.ThermalHistory = [System.Collections.Generic.List[hashtable]]::new()
    }
    
    # Initialize - wykryj dostępne sensory fanów
    [void] Initialize([string]$source) {
        $this.Source = $source
        if (-not $source -or $source -eq "SystemOnly") { return }
        
        $ns = if ($source -eq "LHM") { "root\LibreHardwareMonitor" } else { "root\OpenHardwareMonitor" }
        try {
            $sensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
            
            # Fan RPM sensors
            $fans = $sensors | Where-Object { $_.SensorType -eq "Fan" -and $_.Value -gt 0 }
            foreach ($f in $fans) {
                $this.FanSensorIds[$f.Identifier] = $f.Name
            }
            $this.CanRead = ($this.FanSensorIds.Count -gt 0)
            
            # Control sensors (fan %)
            $controls = $sensors | Where-Object { $_.SensorType -eq "Control" }
            foreach ($c in $controls) {
                $this.ControlSensorIds[$c.Identifier] = $c.Name
            }
            $this.CanControl = ($this.ControlSensorIds.Count -gt 0)
            
            if ($this.CanRead) {
                $this.Enabled = $true
                $this.CurrentRPM = [int]($fans | Select-Object -First 1).Value
            }
        } catch { }
    }
    
    # Odczytaj aktualne RPM i temp, oblicz trend
    [hashtable] Update([double]$temp, [string]$mode, [string]$phase) {
        $result = @{
            RPM = 0; FanPercent = -1; TempTrend = "stable"
            Action = "none"; Reason = ""
        }
        if (-not $this.Enabled -or -not $this.CanRead) { return $result }
        
        $now = Get-Date
        $ns = if ($this.Source -eq "LHM") { "root\LibreHardwareMonitor" } else { "root\OpenHardwareMonitor" }
        
        try {
            $sensors = Get-CimInstance -Namespace $ns -ClassName Sensor -ErrorAction Stop
            
            # Odczytaj RPM
            $fanSensor = $sensors | Where-Object { $_.SensorType -eq "Fan" -and $_.Value -gt 0 } | Select-Object -First 1
            if ($fanSensor) { $this.CurrentRPM = [int]$fanSensor.Value }
            $result.RPM = $this.CurrentRPM
            
            # Odczytaj aktualny % kontroli
            $ctrlSensor = $sensors | Where-Object { $_.SensorType -eq "Control" } | Select-Object -First 1
            if ($ctrlSensor) { $result.FanPercent = [int]$ctrlSensor.Value }
            
            # Oblicz temp drop rate
            if ($this.LastUpdate -ne [datetime]::MinValue) {
                $dt = ($now - $this.LastUpdate).TotalSeconds
                if ($dt -gt 0 -and $dt -lt 10) {
                    $this.TempDropRate = ($this.LastTemp - $temp) / $dt  # +wartość = temp spada
                }
            }
            $this.LastTemp = $temp
            $this.LastUpdate = $now
            
            # Trend
            $result.TempTrend = if ($this.TempDropRate -gt 0.3) { "falling" } 
                               elseif ($this.TempDropRate -lt -0.3) { "rising" } 
                               else { "stable" }
            
            # === DECYZJA: czy obniżyć fan? ===
            # SAFETY: nigdy nie obniżaj powyżej SafeTemp
            if ($temp -gt $this.SafeTemp) {
                if ($this.IsOverriding) {
                    $this.ReleaseControl($ns, $sensors)
                    $result.Action = "release"; $result.Reason = "SAFETY: temp=$([int]$temp)>$($this.SafeTemp)"
                }
                return $result
            }
            
            # Max override time - oddaj EC po 2min
            if ($this.IsOverriding) {
                $overrideDuration = ($now - $this.OverrideStart).TotalSeconds
                if ($overrideDuration -gt $this.MaxOverrideSeconds) {
                    $this.ReleaseControl($ns, $sensors)
                    $result.Action = "release"; $result.Reason = "MAX-TIME: $([int]$overrideDuration)s"
                    return $result
                }
            }
            
            # FAST RAMP DOWN: Temp spada + tryb Silent/Paused + temp<65°C
            if ($this.CanControl -and $temp -lt 65 -and $this.TempDropRate -gt 0.2) {
                if ($mode -eq "Silent" -or $phase -eq "Paused" -or $phase -eq "Idle") {
                    # Oblicz target fan% na podstawie temp
                    $targetPct = if ($temp -lt 45) { 25 }        # Prawie off
                                 elseif ($temp -lt 50) { 30 }    # Minimum
                                 elseif ($temp -lt 55) { 40 }    # Niski
                                 elseif ($temp -lt 60) { 50 }    # Umiarkowany
                                 else { 60 }                      # Jeszcze wysokawy
                    
                    # Tylko obniżaj - nigdy nie podnoś fan (EC to zrobi)
                    if ($result.FanPercent -gt $targetPct + 10) {
                        $this.SetFanPercent($ns, $sensors, $targetPct)
                        $this.IsOverriding = $true
                        if ($this.OverrideStart -eq [datetime]::MinValue) {
                            $this.OverrideStart = $now
                        }
                        $result.Action = "lower"
                        $result.Reason = "FAST-DOWN: temp=$([int]$temp) fan=$($result.FanPercent)%→$($targetPct)% drop=$([Math]::Round($this.TempDropRate,1))/s"
                    }
                }
            }
            
            # Temp wzrasta lub tryb nie-Silent → oddaj kontrolę EC
            if ($this.IsOverriding -and ($this.TempDropRate -lt -0.5 -or $mode -eq "Turbo")) {
                $this.ReleaseControl($ns, $sensors)
                $result.Action = "release"; $result.Reason = "TEMP-RISING or TURBO"
            }
            
        } catch { }
        
        return $result
    }
    
    # Ustaw fan% przez WMI (LHM)
    hidden [void] SetFanPercent([string]$ns, $sensors, [int]$percent) {
        if (-not $this.CanControl) { return }
        try {
            # LHM pozwala na set via WMI Set method na Control sensorach
            $controls = $sensors | Where-Object { $_.SensorType -eq "Control" }
            foreach ($ctrl in $controls) {
                # Użyj Set-CimInstance lub WMI method
                $ctrl | Set-CimInstance -Property @{ Value = [float]$percent } -ErrorAction SilentlyContinue
            }
            $this.TargetPercent = $percent
        } catch {
            # LHM WMI Set nie zadziałał - spróbuj inaczej
            $this.CanControl = $false
        }
    }
    
    # Oddaj kontrolę EC (reset to auto)
    hidden [void] ReleaseControl([string]$ns, $sensors) {
        if (-not $this.IsOverriding) { return }
        try {
            # Set-CimInstance z wartością "default" lub 100% → EC przejmuje
            $controls = $sensors | Where-Object { $_.SensorType -eq "Control" }
            foreach ($ctrl in $controls) {
                $ctrl | Set-CimInstance -Property @{ Value = [float]100 } -ErrorAction SilentlyContinue
            }
        } catch { }
        $this.IsOverriding = $false
        $this.TargetPercent = -1
        $this.OverrideStart = [datetime]::MinValue
    }
    
    [hashtable] GetStatus() {
        return @{
            Enabled = $this.Enabled
            Source = $this.Source
            CanControl = $this.CanControl
            CanRead = $this.CanRead
            RPM = $this.CurrentRPM
            IsOverriding = $this.IsOverriding
            TargetPercent = $this.TargetPercent
            TempDropRate = [Math]::Round($this.TempDropRate, 2)
            SafeTemp = $this.SafeTemp
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# SHARED APP KNOWLEDGE - Centralna baza wiedzy per-app
# Każdy silnik PISZE swoją wiedzę, każdy silnik CZYTA wiedzę innych
# AICoordinator czyta WSZYSTKO i podejmuje finalną decyzję z pełnym kontekstem
# ═══════════════════════════════════════════════════════════════════════════════
class SharedAppKnowledge {
    [hashtable] $Apps = @{}  # { "appName" = AppProfile }
    [string] $ConfigDir = ""
    
    # Pobierz lub utwórz profil aplikacji
    [hashtable] GetProfile([string]$app) {
        if ([string]::IsNullOrWhiteSpace($app) -or $app -eq "Desktop") {
            return $this.NewProfile()
        }
        $key = $app.ToLower()
        if (-not $this.Apps.ContainsKey($key)) {
            $this.Apps[$key] = $this.NewProfile()
        }
        return $this.Apps[$key]
    }
    
    [hashtable] NewProfile() {
        return @{
            # === OD PROPHET ===
            AvgCPU = 0.0; AvgGPU = 0.0; AvgTemp = 0.0
            BestMode = ""; Sessions = 0; TotalTime = 0.0
            # === OD Q-LEARNING ===
            QBestAction = ""; QConfidence = 0.0
            QPhaseActions = @{}  # { "Gameplay" = "Silent"; "Loading" = "Turbo" }
            # === OD GPUAI ===
            PreferredGPU = ""; IsGPUBound = $false
            AvgGPULoad = 0.0; GPUCategory = ""  # "Heavy"/"Light"/"Work"
            # === OD PHASE ===
            DominantPhase = ""; PhaseHistory = @{}
            # { "Gameplay" = 120.5; "Loading" = 10.2; "Idle" = 300.0 }
            # === OD THERMAL ===
            ThermalRisk = "Low"  # "Low"/"Medium"/"High"
            PeakTemp = 0.0; AvgTempDelta = 0.0
            # === OD CONTEXT ===
            Category = ""  # "Gaming"/"Work"/"Media"/"Browser"/"System"
            Priority = 5   # 1=highest, 6=lowest
            # === OD NETWORKAI ===
            NetworkMode = ""; AvgDownload = 0.0; AvgUpload = 0.0
            # === OD ENERGY ===
            Efficiency = 0.0  # 0-1 jak efektywnie app używa CPU
            # === META ===
            LastSeen = [datetime]::MinValue
            UpdateCount = 0
        }
    }
    
    # === WRITE METHODS - każdy silnik pisze swoją wiedzę ===
    
    [void] WriteFromProphet([string]$app, [double]$avgCPU, [double]$avgGPU, [string]$bestMode, [int]$sessions) {
        $p = $this.GetProfile($app)
        $p.AvgCPU = $avgCPU; $p.AvgGPU = $avgGPU
        $p.BestMode = $bestMode; $p.Sessions = $sessions
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='Prophet'; App=$app; AvgCPU=[double]$avgCPU; AvgGPU=[double]$avgGPU; BestMode=$bestMode; Sessions=[int]$sessions }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    [void] WriteFromQLearning([string]$app, [string]$bestAction, [double]$confidence, [string]$phase, [string]$phaseAction) {
        $p = $this.GetProfile($app)
        $p.QBestAction = $bestAction; $p.QConfidence = $confidence
        if ($phase -and $phaseAction) { $p.QPhaseActions[$phase] = $phaseAction }
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='QLearning'; App=$app; QBestAction=$bestAction; Confidence=[double]$confidence; Phase=$phase; PhaseAction=$phaseAction }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    [void] WriteFromGPUAI([string]$app, [string]$preferredGPU, [bool]$isGPUBound, [double]$avgGPULoad, [string]$category) {
        $p = $this.GetProfile($app)
        $p.PreferredGPU = $preferredGPU; $p.IsGPUBound = $isGPUBound
        $p.AvgGPULoad = $avgGPULoad; $p.GPUCategory = $category
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='GPUAI'; App=$app; PreferredGPU=$preferredGPU; IsGPUBound=[bool]$isGPUBound; AvgGPULoad=[double]$avgGPULoad; GPUCategory=$category }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    [void] WriteFromPhase([string]$app, [string]$dominantPhase, [hashtable]$phaseHistory) {
        $p = $this.GetProfile($app)
        $p.DominantPhase = $dominantPhase
        if ($phaseHistory) { $p.PhaseHistory = $phaseHistory }
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='Phase'; App=$app; DominantPhase=$dominantPhase }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    [void] WriteFromThermal([string]$app, [double]$avgTemp, [double]$peakTemp, [string]$risk) {
        $p = $this.GetProfile($app)
        $a = 0.9; $p.AvgTemp = $p.AvgTemp * $a + $avgTemp * (1 - $a)
        if ($peakTemp -gt $p.PeakTemp) { $p.PeakTemp = $peakTemp }
        $p.ThermalRisk = $risk
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='Thermal'; App=$app; AvgTemp=[double]$avgTemp; PeakTemp=[double]$peakTemp; Risk=$risk }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    [void] WriteFromContext([string]$app, [string]$category, [int]$priority) {
        $p = $this.GetProfile($app)
        $p.Category = $category; $p.Priority = $priority
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='Context'; App=$app; Category=$category; Priority=[int]$priority }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    [void] WriteFromNetwork([string]$app, [string]$mode, [double]$dl, [double]$ul) {
        $p = $this.GetProfile($app)
        $p.NetworkMode = $mode; $p.AvgDownload = $dl; $p.AvgUpload = $ul
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='Network'; App=$app; Mode=$mode; AvgDL=[double]$dl; AvgUL=[double]$ul }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    [void] WriteFromEnergy([string]$app, [double]$efficiency) {
        $p = $this.GetProfile($app)
        $p.Efficiency = $efficiency
        $p.LastSeen = Get-Date; $p.UpdateCount++
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='SharedAppKnowledge'; Component='Energy'; App=$app; Efficiency=[double]$efficiency }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    # === READ - AICoordinator i inne silniki czytają pełny profil ===
    
    # Generuj KOMPLETNY score 0-100 na podstawie CAŁEJ wiedzy o aplikacji
    [hashtable] GetAppIntelligence([string]$app, [string]$currentPhase) {
        $p = $this.GetProfile($app)
        $result = @{
            RecommendedMode = "Balanced"
            Score = 50
            Confidence = 0.0  # 0-1 ile wiemy o tej app
            Reasons = [System.Collections.Generic.List[string]]::new()
        }
        
        if ($p.UpdateCount -lt 3) {
            $result.Confidence = 0.1
            $result.Reasons.Add("NEW-APP: brak danych")
            return $result
        }
        
        # Zbierz głosy z każdego źródła wiedzy
        $votes = @{ Silent = 0.0; Balanced = 0.0; Turbo = 0.0 }
        $totalWeight = 0.0
        
        # v43.14: Detect Q-Prophet CONFLICT (Q skrzywiony na Silent z powodu starych rewards)
        $qProphetConflict = $false
        if ($p.BestMode -and $p.QBestAction -and $p.BestMode -ne $p.QBestAction) {
            $qProphetConflict = $true
        }
        
        # 1. Prophet: historyczny najlepszy tryb (waga 2.5 - NAJWYŻSZA gdy wiarygodny)
        if ($p.BestMode) {
            $prophetWeight = if ($qProphetConflict) { 3.0 } else { 2.5 }  # Wyższa przy konflikcie
            $votes[$p.BestMode] += $prophetWeight
            $totalWeight += $prophetWeight
            $result.Reasons.Add("Prophet=$($p.BestMode)")
        }
        
        # 2. Q-Learning per phase (waga 1.5 - OBNIŻONA, Q może być skrzywiony)
        if ($currentPhase -and $p.QPhaseActions.ContainsKey($currentPhase)) {
            $qMode = $p.QPhaseActions[$currentPhase]
            $qWeight = if ($qProphetConflict) { 1.0 } else { 2.0 }  # Niższa przy konflikcie
            $votes[$qMode] += $qWeight
            $totalWeight += $qWeight
            $result.Reasons.Add("Q[$currentPhase]=$qMode")
        } elseif ($p.QBestAction) {
            $votes[$p.QBestAction] += 1.0
            $totalWeight += 1.0
            $result.Reasons.Add("Q=$($p.QBestAction)")
        }
        
        # 3. GPUAI: GPU-aware scoring z eskalacją
        if ($p.IsGPUBound) {
            # GPU-bound: Balanced z wagą proporcjonalną do GPU load
            $gpuWeight = if ($p.AvgGPU -gt 85) { 3.0 }      # Ekstremalny GPU = bardzo mocny vote
                         elseif ($p.AvgGPU -gt 70) { 2.5 }
                         else { 2.0 }
            $votes["Balanced"] += $gpuWeight
            $totalWeight += $gpuWeight
            $result.Reasons.Add("GPU-BOUND($([int]$p.AvgGPU)%)→Balanced")
        } elseif ($p.GPUCategory -eq "Heavy") {
            # Heavy GPU ale nie GPU-bound (CPU też ciężki) → Turbo lub Balanced
            if ($p.AvgCPU -gt 50) {
                # CPU+GPU obydwa ciężkie = TURBO
                $votes["Turbo"] += 2.0
                $totalWeight += 2.0
                $result.Reasons.Add("GPU+CPU Heavy→Turbo")
            } else {
                $votes["Balanced"] += 1.5
                $totalWeight += 1.5
                $result.Reasons.Add("GPU=Heavy→Balanced")
            }
        } elseif ($p.AvgGPU -gt 35) {
            # Medium GPU load → Balanced (nie Silent!)
            $votes["Balanced"] += 0.8
            $totalWeight += 0.8
            $result.Reasons.Add("GPU=Medium($([int]$p.AvgGPU)%)")
        }
        
        # 4. Phase: kontekst fazy (waga 1.5)
        if ($currentPhase) {
            $phaseVote = switch ($currentPhase) {
                "Loading"  { "Turbo" }
                "Gameplay" { "Balanced" }
                "Active"   { "Balanced" }
                "Cutscene" { "Silent" }
                "Menu"     { "Silent" }
                "Idle"     { "Silent" }
                "Paused"   { "Silent" }
                default    { "Balanced" }
            }
            $votes[$phaseVote] += 1.5
            $totalWeight += 1.5
            $result.Reasons.Add("Phase=$currentPhase→$phaseVote")
        }
        
        # 5. Thermal: ryzyko (waga 1.5)
        if ($p.ThermalRisk -eq "High") {
            $votes["Silent"] += 1.5
            $totalWeight += 1.5
            $result.Reasons.Add("THERMAL-RISK")
        } elseif ($p.ThermalRisk -eq "Medium") {
            $votes["Balanced"] += 0.5
            $totalWeight += 0.5
        }
        
        # 6. Context + GPU Category: kategoria aplikacji
        # v43.14: Audio apps = Balanced minimum (realtime buffers!)
        if ($p.Category -eq "Audio") {
            $votes["Balanced"] += 2.0
            $totalWeight += 2.0
            $result.Reasons.Add("AUDIO→Balanced")
        } elseif ($p.GPUCategory -eq "Extreme" -or ($p.Category -eq "Gaming" -and $p.AvgGPU -gt 80)) {
            # Extreme GPU: Turbo (gra/render potrzebuje max mocy)
            $votes["Turbo"] += 2.5
            $totalWeight += 2.5
            $result.Reasons.Add("EXTREME-GPU→Turbo")
        } elseif ($p.Category -eq "Gaming" -or $p.Category -eq "Rendering") {
            if ($currentPhase -eq "Loading") { $votes["Turbo"] += 2.0 }
            elseif ($currentPhase -eq "Gameplay") { $votes["Balanced"] += 2.0 }
            else { $votes["Balanced"] += 1.5 }
            $totalWeight += 2.0
            $result.Reasons.Add("$($p.Category)→$($currentPhase)")
        } elseif ($p.GPUCategory -eq "Rendering") {
            # GPU rendering (GPU>60 + CPU<40) - Balanced (GPU needs power headroom)
            $votes["Balanced"] += 1.5
            $totalWeight += 1.5
            $result.Reasons.Add("GPU-Render→Balanced")
        } elseif ($p.Category -eq "Coding") {
            if ($currentPhase -eq "Active") { $votes["Balanced"] += 1.0 }
            else { $votes["Silent"] += 0.5 }
            $totalWeight += 1.0
        } elseif ($p.Category -eq "Work" -or $p.Category -eq "Browser" -or $p.Category -eq "Browsing") {
            $votes["Silent"] += 0.5
            $totalWeight += 0.5
        } elseif ($p.GPUCategory -eq "Idle" -or $p.Category -eq "Idle") {
            $votes["Silent"] += 1.0
            $totalWeight += 1.0
            $result.Reasons.Add("IDLE→Silent")
        }
        
        # 7. Energy: efektywność (waga 0.5)
        if ($p.Efficiency -gt 0.7) {
            $votes["Silent"] += 0.5  # Efektywna app - nie potrzebuje mocy
            $totalWeight += 0.5
        } elseif ($p.Efficiency -lt 0.3 -and $p.Efficiency -gt 0) {
            $votes["Turbo"] += 0.5  # Nieefektywna - potrzebuje mocy
            $totalWeight += 0.5
        }
        
        # Oblicz zwycięzcę
        if ($totalWeight -gt 0) {
            $best = "Balanced"; $bestScore = $votes["Balanced"]
            if ($votes["Silent"] -gt $bestScore) { $best = "Silent"; $bestScore = $votes["Silent"] }
            if ($votes["Turbo"] -gt $bestScore) { $best = "Turbo"; $bestScore = $votes["Turbo"] }
            $result.RecommendedMode = $best
            
            # Score 0-100 (Silent=25, Balanced=50, Turbo=75 +/- strength)
            $baseScore = switch ($best) { "Silent" { 25 } "Balanced" { 50 } "Turbo" { 75 } default { 50 } }
            $strength = if ($totalWeight -gt 0) { $bestScore / $totalWeight } else { 0.5 }
            $result.Score = [Math]::Min(100, [Math]::Max(0, [int]($baseScore + ($strength - 0.5) * 30)))
            $result.Confidence = [Math]::Min(1.0, $p.UpdateCount / 50.0)
        }
        
        return $result
    }
    
    # Save/Load
    [void] SaveState([string]$configDir) {
        try {
            $path = Join-Path $configDir "SharedAppKnowledge.json"
            $export = @{}
            foreach ($key in $this.Apps.Keys) {
                $p = $this.Apps[$key]
                $export[$key] = @{
                    AvgCPU = [Math]::Round($p.AvgCPU, 1); AvgGPU = [Math]::Round($p.AvgGPU, 1)
                    AvgTemp = [Math]::Round($p.AvgTemp, 1); BestMode = $p.BestMode; Sessions = $p.Sessions
                    QBestAction = $p.QBestAction; QConfidence = [Math]::Round($p.QConfidence, 2)
                    QPhaseActions = $p.QPhaseActions
                    PreferredGPU = $p.PreferredGPU; IsGPUBound = $p.IsGPUBound
                    GPUCategory = $p.GPUCategory; DominantPhase = $p.DominantPhase
                    PhaseHistory = $p.PhaseHistory; ThermalRisk = $p.ThermalRisk
                    PeakTemp = [Math]::Round($p.PeakTemp, 1)
                    Category = $p.Category; Priority = $p.Priority
                    NetworkMode = $p.NetworkMode; Efficiency = [Math]::Round($p.Efficiency, 2)
                    UpdateCount = $p.UpdateCount
                }
            }
            $export | ConvertTo-Json -Depth 5 -Compress | Set-Content $path -Encoding UTF8 -Force
        } catch {}
    }
    
    [void] LoadState([string]$configDir) {
        $this.ConfigDir = $configDir
        try {
            $path = Join-Path $configDir "SharedAppKnowledge.json"
            if (Test-Path $path) {
                $data = Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                foreach ($prop in $data.PSObject.Properties) {
                    $key = $prop.Name
                    $v = $prop.Value
                    $p = $this.NewProfile()
                    $p.AvgCPU = if ($v.AvgCPU) { $v.AvgCPU } else { 0 }
                    $p.AvgGPU = if ($v.AvgGPU) { $v.AvgGPU } else { 0 }
                    $p.AvgTemp = if ($v.AvgTemp) { $v.AvgTemp } else { 0 }
                    $p.BestMode = if ($v.BestMode) { $v.BestMode } else { "" }
                    $p.Sessions = if ($v.Sessions) { [int]$v.Sessions } else { 0 }
                    $p.QBestAction = if ($v.QBestAction) { $v.QBestAction } else { "" }
                    $p.QConfidence = if ($v.QConfidence) { $v.QConfidence } else { 0 }
                    $p.QPhaseActions = @{}
                    if ($v.QPhaseActions) {
                        $v.QPhaseActions.PSObject.Properties | ForEach-Object { $p.QPhaseActions[$_.Name] = $_.Value }
                    }
                    $p.PreferredGPU = if ($v.PreferredGPU) { $v.PreferredGPU } else { "" }
                    $p.IsGPUBound = if ($v.IsGPUBound) { [bool]$v.IsGPUBound } else { $false }
                    $p.GPUCategory = if ($v.GPUCategory) { $v.GPUCategory } else { "" }
                    $p.DominantPhase = if ($v.DominantPhase) { $v.DominantPhase } else { "" }
                    $p.PhaseHistory = @{}
                    if ($v.PhaseHistory) {
                        $v.PhaseHistory.PSObject.Properties | ForEach-Object { $p.PhaseHistory[$_.Name] = [double]$_.Value }
                    }
                    $p.ThermalRisk = if ($v.ThermalRisk) { $v.ThermalRisk } else { "Low" }
                    $p.PeakTemp = if ($v.PeakTemp) { $v.PeakTemp } else { 0 }
                    $p.Category = if ($v.Category) { $v.Category } else { "" }
                    $p.Priority = if ($v.Priority) { [int]$v.Priority } else { 5 }
                    $p.NetworkMode = if ($v.NetworkMode) { $v.NetworkMode } else { "" }
                    $p.Efficiency = if ($v.Efficiency) { $v.Efficiency } else { 0 }
                    $p.UpdateCount = if ($v.UpdateCount) { [int]$v.UpdateCount } else { 0 }
                    $this.Apps[$key] = $p
                }
            }
        } catch {}
    }
}

# THERMAL PREDICTOR - Przewidywanie temperatury
class ThermalPredictor {
    [System.Collections.Generic.List[double]] $TempHistory
    [System.Collections.Generic.List[double]] $CpuHistory
    [hashtable] $AppThermalProfiles
    [int] $MaxHistory
    [double] $PredictedTemp
    [double] $ThermalTrend
    [bool] $OverheatWarning
    ThermalPredictor() {
        $this.TempHistory = [System.Collections.Generic.List[double]]::new()
        $this.CpuHistory = [System.Collections.Generic.List[double]]::new()
        $this.AppThermalProfiles = @{}
        $this.MaxHistory = 60  # 2 minuty przy 2s intervals
        $this.PredictedTemp = 50
        $this.ThermalTrend = 0
        $this.OverheatWarning = $false
    }
    [void] RecordSample([double]$temp, [double]$cpu, [string]$app) {
        $this.TempHistory.Add($temp)
        $this.CpuHistory.Add($cpu)
        while ($this.TempHistory.Count -gt $this.MaxHistory) {
            $this.TempHistory.RemoveAt(0)
            $this.CpuHistory.RemoveAt(0)
        }
        # Ucz sie profilu termicznego aplikacji
        if (-not [string]::IsNullOrWhiteSpace($app)) {
            $appLower = $app.ToLower()
            if (-not $this.AppThermalProfiles.ContainsKey($appLower)) {
                $this.AppThermalProfiles[$appLower] = @{
                    AvgTemp = $temp
                    MaxTemp = $temp
                    AvgCPU = $cpu
                    ThermalRise = 0.0  # °C per minute
                    Samples = 1
                }
            } else {
                $profile = $this.AppThermalProfiles[$appLower]
                $profile.Samples++
                $profile.AvgTemp = ($profile.AvgTemp * ($profile.Samples - 1) + $temp) / $profile.Samples
                $profile.AvgCPU = ($profile.AvgCPU * ($profile.Samples - 1) + $cpu) / $profile.Samples
                if ($temp -gt $profile.MaxTemp) { $profile.MaxTemp = $temp }
            }
        }
        $this.CalculatePrediction()
    }
    [void] CalculatePrediction() {
        if ($this.TempHistory.Count -lt 10) { return }
        # Oblicz trend temperatury (ostatnie 30 sekund vs poprzednie 30 sekund)
        $recentCount = [Math]::Min(15, $this.TempHistory.Count / 2)
        $recent = $this.TempHistory | Select-Object -Last $recentCount
        $older = $this.TempHistory | Select-Object -First $recentCount
        $recentAvg = ($recent | Measure-Object -Average).Average
        $olderAvg = ($older | Measure-Object -Average).Average
        $this.ThermalTrend = $recentAvg - $olderAvg  # °C zmiana
        # Przewidywanie na 30 sekund do przodu
        $currentTemp = $this.TempHistory[-1]
        $this.PredictedTemp = $currentTemp + ($this.ThermalTrend * 2)
        # Ostrzezenie o przegrzaniu
        $this.OverheatWarning = ($this.PredictedTemp -gt 85) -or ($currentTemp -gt 80 -and $this.ThermalTrend -gt 2)
    }
    [double] GetPredictedTemp() {
        return [Math]::Round($this.PredictedTemp, 1)
    }
    [bool] ShouldThrottle() {
        # Sugeruj throttling jesli przewidywana temp > 88°C
        return $this.PredictedTemp -gt 88 -or $this.OverheatWarning
    }
    [double] GetAppThermalRisk([string]$app) {
        # Zwraca ryzyko termiczne dla aplikacji (0-100)
        if ([string]::IsNullOrWhiteSpace($app)) { return 50 }
        $appLower = $app.ToLower()
        if ($this.AppThermalProfiles.ContainsKey($appLower)) {
            $profile = $this.AppThermalProfiles[$appLower]
            $risk = ($profile.MaxTemp - 50) * 2  # 50°C = 0%, 100°C = 100%
            return [Math]::Max(0, [Math]::Min(100, $risk))
        }
        return 50
    }
    [string] GetStatus() {
        $trend = if ($this.ThermalTrend -gt 1) { "?" } elseif ($this.ThermalTrend -lt -1) { "?" } else { "->" }
        $warning = if ($this.OverheatWarning) { " [WARN]" } else { "" }
        return "Pred:$([Math]::Round($this.PredictedTemp))°C $trend$warning"
    }
    [void] SaveState([string]$dir) {
        try {
            $data = @{
                AppThermalProfiles = $this.AppThermalProfiles
            }
            $path = Join-Path $dir "ThermalProfiles.json"
            $data | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding UTF8
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "ThermalProfiles.json"
            if (Test-Path $path) {
                $data = Get-Content $path -Raw | ConvertFrom-Json
                if ($data.AppThermalProfiles) {
                    $this.AppThermalProfiles = @{}
                    foreach ($prop in $data.AppThermalProfiles.PSObject.Properties) {
                        $this.AppThermalProfiles[$prop.Name] = @{
                            AvgTemp = $prop.Value.AvgTemp
                            MaxTemp = $prop.Value.MaxTemp
                            Samples = $prop.Value.Samples
                        }
                    }
                }
            }
        } catch { }
    }
}
# USER PATTERN LEARNER - Uczenie sie wzorcow uzytkownika
class UserPatternLearner {
    [hashtable] $HourlyPatterns      # Wzorce dla kazdej godziny
    [hashtable] $DayOfWeekPatterns   # Wzorce dla dni tygodnia
    [hashtable] $AppUsagePatterns    # Kiedy uzywasz jakich aplikacji
    [System.Collections.Generic.List[hashtable]] $SessionHistory
    [int] $MaxSessions
    [datetime] $SessionStart
    [string] $LastDominantApp
    UserPatternLearner() {
        $this.HourlyPatterns = @{}
        $this.DayOfWeekPatterns = @{}
        $this.AppUsagePatterns = @{}
        $this.SessionHistory = [System.Collections.Generic.List[hashtable]]::new()
        $this.MaxSessions = 100
        $this.SessionStart = Get-Date
        $this.LastDominantApp = ""
        # Inicjalizuj wzorce godzinowe
        for ($h = 0; $h -lt 24; $h++) {
            $this.HourlyPatterns[$h] = @{
                AvgCPU = 20.0
                AvgTemp = 50.0
                DominantContext = "Idle"
                DominantMode = "Balanced"
                ActivityLevel = 0.5
                Samples = 0
            }
        }
        # Inicjalizuj wzorce dni tygodnia
        for ($d = 0; $d -lt 7; $d++) {
            $this.DayOfWeekPatterns[$d] = @{
                PeakHours = @()
                AvgSessionLength = 60
                PreferredMode = "Balanced"
                Samples = 0
            }
        }
    }
    [void] RecordSample([double]$cpu, [double]$temp, [string]$context, [string]$mode, [bool]$isActive) {
        $now = Get-Date
        $hour = $now.Hour
        $dayOfWeek = [int]$now.DayOfWeek
        # Aktualizuj wzorce godzinowe
        $hourPattern = $this.HourlyPatterns[$hour]
        $hourPattern.Samples++
        $hourPattern.AvgCPU = ($hourPattern.AvgCPU * ($hourPattern.Samples - 1) + $cpu) / $hourPattern.Samples
        $hourPattern.AvgTemp = ($hourPattern.AvgTemp * ($hourPattern.Samples - 1) + $temp) / $hourPattern.Samples
        $hourPattern.DominantContext = $context
        $hourPattern.DominantMode = $mode
        $activityValue = if ($isActive) { 1.0 } else { 0.0 }
        $hourPattern.ActivityLevel = ($hourPattern.ActivityLevel * 0.95) + ($activityValue * 0.05)
        # Aktualizuj wzorce dni tygodnia
        $dayPattern = $this.DayOfWeekPatterns[$dayOfWeek]
        $dayPattern.Samples++
        if ($cpu -gt 50 -and $hour -notin $dayPattern.PeakHours) {
            $dayPattern.PeakHours += $hour
            $dayPattern.PeakHours = $dayPattern.PeakHours | Select-Object -Unique | Sort-Object
        }
    }
    [void] RecordAppUsage([string]$app) {
        if ([string]::IsNullOrWhiteSpace($app)) { return }
        $now = Get-Date
        $hour = $now.Hour
        $appLower = $app.ToLower()
        if (-not $this.AppUsagePatterns.ContainsKey($appLower)) {
            $this.AppUsagePatterns[$appLower] = @{
                HourlyUsage = @{}
                TotalLaunches = 0
                AvgSessionMinutes = 10
                LastUsed = $now
            }
        }
        $pattern = $this.AppUsagePatterns[$appLower]
        $pattern.TotalLaunches++
        $pattern.LastUsed = $now
        if (-not $pattern.HourlyUsage.ContainsKey($hour)) {
            $pattern.HourlyUsage[$hour] = 0
        }
        $pattern.HourlyUsage[$hour]++
    }
    [string] PredictNextHourMode() {
        $nextHour = ((Get-Date).Hour + 1) % 24
        $pattern = $this.HourlyPatterns[$nextHour]
        if ($pattern.Samples -gt 10) {
            return $pattern.DominantMode
        }
        return "Unknown"
    }
    [double] GetExpectedActivityLevel() {
        $hour = (Get-Date).Hour
        return $this.HourlyPatterns[$hour].ActivityLevel
    }
    [bool] IsTypicallyActiveNow() {
        return $this.GetExpectedActivityLevel() -gt 0.5
    }
    [string[]] PredictLikelyApps() {
        $hour = (Get-Date).Hour
        $likelyApps = @()
        foreach ($app in $this.AppUsagePatterns.Keys) {
            $pattern = $this.AppUsagePatterns[$app]
            if ($pattern.HourlyUsage.ContainsKey($hour) -and $pattern.HourlyUsage[$hour] -gt 2) {
                $likelyApps += $app
            }
        }
        return $likelyApps | Select-Object -First 5
    }
    [string] GetStatus() {
        $hour = (Get-Date).Hour
        $pattern = $this.HourlyPatterns[$hour]
        $activity = [Math]::Round($pattern.ActivityLevel * 100)
        return "Act:$activity% Mode:$($pattern.DominantMode)"
    }
    [void] SaveState([string]$configDir) {
        try {
            $path = Join-Path $configDir "UserPatterns.json"
            $data = @{
                HourlyPatterns = $this.HourlyPatterns
                DayOfWeekPatterns = $this.DayOfWeekPatterns
                AppUsagePatterns = $this.AppUsagePatterns
            }
            $json = $data | ConvertTo-Json -Depth 5 -Compress
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$configDir) {
        try {
            $path = Join-Path $configDir "UserPatterns.json"
            if (Test-Path $path) {
                $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                $data = $json | ConvertFrom-Json
                if ($data.HourlyPatterns) {
                    $data.HourlyPatterns.PSObject.Properties | ForEach-Object {
                        $hour = [int]$_.Name
                        $this.HourlyPatterns[$hour] = @{
                            AvgCPU = [double]$_.Value.AvgCPU
                            AvgTemp = [double]$_.Value.AvgTemp
                            DominantContext = [string]$_.Value.DominantContext
                            DominantMode = [string]$_.Value.DominantMode
                            ActivityLevel = [double]$_.Value.ActivityLevel
                            Samples = [int]$_.Value.Samples
                        }
                    }
                }
            }
        } catch { }
    }
}
# ADAPTIVE RESPONSE TIMER - Dynamiczny czas reakcji
class AdaptiveTimer {
    [int] $CurrentInterval      # Aktualny interwal w ms
    [int] $MinInterval          # Minimum (szybka reakcja)
    [int] $MaxInterval          # Maximum (oszczednosc)
    [string] $LastContext
    [int] $StableCount
    AdaptiveTimer() {
        $this.CurrentInterval = 800   #  v39.3  #  FIXED: Domyslnie 1 sekunda (bylo 2)
        $this.MinInterval = 250       #  v39.3       #  FIXED: 0.3 sekundy dla gier (bylo 0.5)
        $this.MaxInterval = 2000      #  v39.3      #  FIXED: 3 sekundy dla idle (bylo 5)
        $this.LastContext = ""
        $this.StableCount = 0
    }
    [int] CalculateInterval([string]$context, [bool]$isActive, [bool]$isBoosting, [double]$cpu) {
        $targetInterval = $this.CurrentInterval
        # Szybka reakcja gdy:
        if ($isBoosting) {
            $targetInterval = $this.MinInterval  # Boosting = najszybciej
        }
        elseif ($context -eq "Audio") {
            $targetInterval = 250  # AUDIO/DAW = najszybsza reakcja dla MIDI!
        }
        elseif ($context -eq "Gaming") {
            $targetInterval = 250  # GAMING = maksymalna responsywnosc jak Windows (bylo 500)
        }
        elseif ($context -eq "Rendering" -or $cpu -gt 70) {
            $targetInterval = 400  # Wysokie obciazenie - szybka reakcja (bylo 700)
        }
        elseif ($isActive) {
            $targetInterval = 800   # Aktywny uzytkownik (bylo 1000)
        }
        elseif ($context -eq "Idle" -and -not $isActive) {
            $targetInterval = $this.MaxInterval  # Idle = oszczedzaj
        }
        else {
            $targetInterval = 1200  # Domyslnie (bylo 1500)
        }
        # Sprawdz zmiane kontekstu PRZED obliczeniem przesuniecia
        $contextChanged = ($context -ne $this.LastContext)
        if ($context -eq $this.LastContext) {
            $this.StableCount++
        } else {
            $this.StableCount = 0
            $this.LastContext = $context
        }
        # NATYCHMIASTOWY skok gdy kontekst sie zmienil, boosting, lub CPU wysokie (>60%)
        # Reaguj tak szybko jak Windows - bez stopniowego przyspieszania
        if ($contextChanged -or $isBoosting -or $cpu -gt 60) {
            $this.CurrentInterval = $targetInterval
        } elseif ($targetInterval -lt $this.CurrentInterval) {
            # Szybkie przyspieszanie (responsywnosc) - krok 400ms
            $this.CurrentInterval = [Math]::Max($targetInterval, $this.CurrentInterval - 400)
        } else {
            # Wolniejsze zwalnianie (stabilnosc)
            $this.CurrentInterval = [Math]::Min($targetInterval, $this.CurrentInterval + 150)
        }
        return $this.CurrentInterval
    }
    [string] GetStatus() {
        $freq = [Math]::Round(1000.0 / $this.CurrentInterval, 1)
        return "${freq}Hz"
    }
}
# SMART PRIORITY MANAGER - FIXED
# ACTIVITY DETECTOR - Wykrywanie aktywnosci uzytkownika (mysz + klawiatura)
$Script:IdleThresholdSeconds = 30
$Script:UserIsActive = $false
$Script:LastIdleSeconds = 0
$Script:LastMouseX = 0
$Script:LastMouseY = 0
$Script:ActivityMethod = "None"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)]
public struct POINT {
    public int X;
    public int Y;
}
public static class Win32Mouse {
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);
}
'@ -PassThru | Out-Null
function Get-IdleTimeSeconds {
    # Metoda 1: GetLastInputInfo (lapie wszystko: mysz, klawiatura, kolko)
    try {
        $lii = New-Object LASTINPUTINFO
        $lii.cbSize = [uint32]8
        if ([Win32]::GetLastInputInfo([ref]$lii)) {
            $currentTick = [Win32]::GetTickCount()
            $idleMs = [int]($currentTick - $lii.dwTime)
            $Script:LastIdleSeconds = [Math]::Max(0, [Math]::Floor($idleMs / 1000))
            if ($idleMs -lt 2000) {
                $Script:ActivityMethod = "Input"
            }
            return $Script:LastIdleSeconds
        }
    } catch {
        Write-Error "Error in Get-IdleTimeSeconds (GetLastInputInfo): $_"
    }
    # Metoda 2: Backup - GetCursorPos (ruch myszy)
    try {
        $point = New-Object POINT
        if ([Win32Mouse]::GetCursorPos([ref]$point)) {
            $deltaX = [Math]::Abs($point.X - $Script:LastMouseX)
            $deltaY = [Math]::Abs($point.Y - $Script:LastMouseY)
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                if ($deltaX -gt 3 -or $deltaY -gt 3) {
                    $Script:LastIdleSeconds = 0
                    $Script:ActivityMethod = "Mouse"
                }
                $Script:LastMouseX = $point.X
                $Script:LastMouseY = $point.Y
            }
        }
    } catch {
        Write-Error "Error in Get-IdleTimeSeconds (GetCursorPos): $_"
    }
    return $Script:LastIdleSeconds
}
function Update-ActivityStatus {
    $idleSeconds = Get-IdleTimeSeconds
    if ($idleSeconds -lt $Script:IdleThresholdSeconds) {
        $Script:UserIsActive = $true
        return $true
    } else {
        $Script:UserIsActive = $false
        $Script:ActivityMethod = "None"
        return $false
    }
}
function Get-UserActivityStatus {
    $idle = Get-IdleTimeSeconds
    if ($idle -lt $Script:IdleThresholdSeconds) {
        return "Active[$($Script:ActivityMethod)]"
    } else {
        return "Idle ${idle}s"
    }
}
# Funkcja pomocnicza do pobrania procesu na pierwszym planie
function Get-ForegroundProcessName {
    try {
        $hwnd = [Win32]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return "" }
        $processId = 0
        [Win32]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
        if ($processId -gt 0) {
            try {
                $process = Get-Process -Id $processId -ErrorAction Stop
                if ($process) { 
                    $processName = $process.ProcessName
                    # #
                    # IGNORUJ PROCESY SYSTEMOWE NA PIERWSZYM PLANIE
                    # AI nie reaguje na te procesy nawet gdy sa aktywne
                    # #
                    if ($Script:BlacklistSet.Contains($processName)) {
                        $process.Dispose()
                        return "Desktop"  # Traktuj jak Desktop/brak aplikacji
                    }
                    #  FIXED: Uzyj nowej funkcji Get-ProcessDisplayName (automatyczne nazwy)
                    $friendlyName = Get-ProcessDisplayName -ProcessName $processName -Process $process
                    # Dla PWA/UWP - sprobuj pobrac prawdziwa nazwe z tytulu okna
                    $pwaProcesses = @("pwahelper", "msedgewebview2", "applicationframehost", "wwahostgta", "wwahost", "electron")
                    if ($pwaProcesses -contains $processName.ToLower() -or $processName -match "helper|host|webview") {
                        $windowTitle = Get-ForegroundWindowTitle
                        if (![string]::IsNullOrWhiteSpace($windowTitle) -and $windowTitle.Length -gt 1) {
                            $friendlyName = $windowTitle
                            if ($friendlyName.Length -gt 30 -and $friendlyName -match "^([^----]+)") {
                                $friendlyName = $matches[1].Trim()
                            }
                        }
                    }
                    # Zapisz surową nazwę i ścieżkę procesu dla LearnName (anti-race-condition)
                    $Script:LastFgRawProcName = $processName
                    $Script:LastFgRawProcPath = $process.Path
                    $process.Dispose()
                    return $friendlyName
                }
            } catch {
                return ""
            }
        }
    } catch { }
    return ""
}
# Deklaracja klasy SmartPriorityManager - FIXED
class SmartPriorityManager {
    [hashtable] $OriginalPriorities
    [hashtable] $BoostedProcesses
    [string] $CurrentForeground
    [datetime] $LastUpdate
    [int] $ProcessCount
    [int] $MaxBoostedProcesses = 20
    SmartPriorityManager() {
        $this.OriginalPriorities = @{}
        $this.BoostedProcesses = @{}
        $this.CurrentForeground = ""
        $this.LastUpdate = Get-Date
        $this.ProcessCount = 0
    }
    [string] GetForegroundApp() {
        return Get-ForegroundProcessName
    }
    [void] BoostProcess([string]$processName) {
        if ([string]::IsNullOrWhiteSpace($processName)) { return }
        if ($this.BoostedProcesses.Count -ge $this.MaxBoostedProcesses) {
            $oldest = $this.BoostedProcesses.GetEnumerator() | 
                      Sort-Object { $_.Value.BoostedAt } | 
                      Select-Object -First 1
            if ($oldest) {
                $this.ResetPriority($oldest.Key)
            }
        }
        try {
            $processes = Get-Process -Name $processName -ErrorAction SilentlyContinue
            foreach ($proc in $processes) {
                try {
                    if (-not $this.OriginalPriorities.ContainsKey($proc.Id)) {
                        $this.OriginalPriorities[$proc.Id] = $proc.PriorityClass
                    }
                    $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
                    $this.BoostedProcesses[$proc.Id] = @{ Name = $processName; BoostedAt = Get-Date }
                    $proc.Dispose()
                } catch { 
                    try { $proc.Dispose() } catch { }
                }
            }
        } catch { }
    }
    [void] ResetPriority([int]$processId) {
        try {
            $proc = $null
            $proc = Get-Process -Id $processId -ErrorAction Stop
            if ($proc -and $this.OriginalPriorities.ContainsKey($processId)) {
                $proc.PriorityClass = $this.OriginalPriorities[$processId]
                $proc.Dispose()
            }
        } catch { 
            # Proces juz nie istnieje - ignorujemy
        }
        $this.OriginalPriorities.Remove($processId)
        $this.BoostedProcesses.Remove($processId)
    }
    [void] OptimizeForForeground([string]$foregroundApp, [System.Collections.Generic.HashSet[string]]$blacklist) {
        if ([string]::IsNullOrWhiteSpace($foregroundApp)) { return }
        if ($foregroundApp -eq $this.CurrentForeground) { return }
        $this.CurrentForeground = $foregroundApp
        $this.LastUpdate = Get-Date
        try {
            $existingProcs = Get-Process -Name $foregroundApp -ErrorAction SilentlyContinue
            $alreadyHigh = $false
            foreach ($ep in $existingProcs) {
                if ($ep.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::High) {
                    $alreadyHigh = $true
                }
                $ep.Dispose()
            }
            if (-not $alreadyHigh) {
                $this.BoostProcess($foregroundApp)
            }
        } catch {
            $this.BoostProcess($foregroundApp)
        }
        try {
            $bgProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object { 
                $_.ProcessName -ne $foregroundApp -and 
                -not $blacklist.Contains($_.ProcessName) -and
                $_.PriorityClass -eq [System.Diagnostics.ProcessPriorityClass]::AboveNormal
            } | Select-Object -First 10
            foreach ($proc in $bgProcesses) {
                try {
                    if ($this.BoostedProcesses.ContainsKey($proc.Id)) {
                        $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
                        $this.BoostedProcesses.Remove($proc.Id)
                    }
                    $proc.Dispose()
                } catch { 
                    try { $proc.Dispose() } catch { }
                }
            }
        } catch { }
        $this.ProcessCount = $this.BoostedProcesses.Count
    }
    [void] RefreshProcessList() {
        $toRemove = @()
        $keysToCheck = @($this.BoostedProcesses.Keys)
        foreach ($procId in $keysToCheck) {
            try {
                $proc = $null
                $proc = Get-Process -Id $procId -ErrorAction Stop
                if ($proc) {
                    $proc.Dispose()
                }
            } catch { 
                $toRemove += $procId 
            }
        }
        foreach ($procId in $toRemove) {
            $this.BoostedProcesses.Remove($procId)
            $this.OriginalPriorities.Remove($procId)
        }
        $this.ProcessCount = $this.BoostedProcesses.Count
    }
    [void] ResetAllPriorities() {
        $keysToProcess = @($this.OriginalPriorities.Keys)
        foreach ($processId in $keysToProcess) {
            try {
                $proc = $null
                $proc = Get-Process -Id $processId -ErrorAction Stop
                if ($proc) { 
                    $proc.PriorityClass = $this.OriginalPriorities[$processId] 
                    $proc.Dispose()
                }
            } catch { 
                # Proces juz nie istnieje - ignorujemy
            }
        }
        $this.OriginalPriorities.Clear()
        $this.BoostedProcesses.Clear()
        $this.ProcessCount = 0
    }
    [int] GetBoostedCount() { return $this.BoostedProcesses.Count }
}
# #
# PROBALANCE - Automatic CPU Hog Restraint (jak Process Lasso)
# #
class ProBalance {
    [hashtable] $ProcessCPU            # PID -> CPU% history
    [hashtable] $ThrottledProcesses    # PID -> {Name, OriginalPriority, ThrottledAt, CPUAtThrottle}
    [hashtable] $SystemProcesses       # Protected system processes
    [double] $ThrottleThreshold = 70.0 # CPU% threshold (obnizone z 80% - bardziej czuly)
    [int] $ThrottleDuration = 3        # Sekund wysokiego CPU zanim throttle (obnizone z 10s - szybsza reakcja)
    [int] $RestoreCooldown = 5         # Sekund niskiego CPU zanim restore (nowe)
    [int] $MaxThrottled = 10           # Max throttled processes
    [bool] $Enabled = $true
    [int] $TotalThrottles = 0
    [int] $TotalRestores = 0
    [int] $LogicalCores = 1
    [hashtable] $LastCPUTime = @{}     # PID -> LastCPUTime (do precyzyjnego obliczenia CPU%)
    ProBalance([int]$cores) {
        $this.ProcessCPU = @{}
        $this.ThrottledProcesses = @{}
        $this.LogicalCores = [Math]::Max(1, $cores)
        # Protected processes - nie throttle tych (core Windows system processes)
        $this.SystemProcesses = @{
            # Core System
            "System" = $true
            "Idle" = $true
            "Registry" = $true
            "smss" = $true
            "csrss" = $true
            "wininit" = $true
            "services" = $true
            "lsass" = $true
            "winlogon" = $true
            # Windows Subsystem — BEZ TEGO = białe ikony, znikające UI
            "svchost" = $true
            "RuntimeBroker" = $true
            "dwm" = $true              # Desktop Window Manager (GUI)
            "explorer" = $true         # File Explorer & Taskbar
            "ShellExperienceHost" = $true  # Start Menu
            "SearchHost" = $true       # Windows Search
            "StartMenuExperienceHost" = $true
            "ApplicationFrameHost" = $true # UWP frames
            "TextInputHost" = $true    # Keyboard/IME
            "ShellHost" = $true        # Quick Settings
            "sihost" = $true           # Shell Infrastructure Host
            "taskhostw" = $true        # Task Host Window
            "dllhost" = $true          # COM Surrogate
            "fontdrvhost" = $true      # Font Driver Host
            "conhost" = $true          # Console Host
            # Security & Updates
            "MsMpEng" = $true          # Windows Defender
            "SecurityHealthService" = $true
            "TrustedInstaller" = $true # Windows Updates
            "wuauclt" = $true
            "UsoClient" = $true
            # Audio & Input
            "audiodg" = $true          # Audio
            "ctfmon" = $true           # Text Input
            # Network
            "dns" = $true
            "BITS" = $true
            # Self-protection
            "CPUManager" = $true
            "powershell" = $true       # Protect PowerShell (ENGINE)
            "pwsh" = $true             # PowerShell 7+
        }
    }
    [void] Update([string]$foregroundApp) {
        if (-not $this.Enabled) { return }
        try {
            $processes = Get-Process | Where-Object { 
                $_.CPU -gt 0 -and 
                -not $this.SystemProcesses.ContainsKey($_.ProcessName)
            }
            $currentTime = [DateTime]::Now
            foreach ($proc in $processes) {
                try {
                    $processId = $proc.Id
                    $cpuPercent = 0
                    if ($this.LastCPUTime.ContainsKey($processId)) {
                        $lastInfo = $this.LastCPUTime[$processId]
                        $elapsedSec = ($currentTime - $lastInfo.Time).TotalSeconds
                        if ($elapsedSec -gt 0.1) {  # Minimum 100ms miedzy probkami
                            $cpuDelta = ($proc.TotalProcessorTime.TotalSeconds - $lastInfo.CPUTime)
                            # CPU% = (delta CPU time / elapsed time) * 100
                            $cpuPercent = [Math]::Min(100, ($cpuDelta / $elapsedSec) * 100)
                        }
                    }
                    # Zapisz aktualny CPU time
                    $this.LastCPUTime[$processId] = @{
                        CPUTime = $proc.TotalProcessorTime.TotalSeconds
                        Time = $currentTime
                    }
                    # Inicjalizuj history jesli nowy proces
                    if (-not $this.ProcessCPU.ContainsKey($processId)) {
                        $this.ProcessCPU[$processId] = @{
                            Name = $proc.ProcessName
                            History = [System.Collections.Generic.List[double]]::new()
                            HighCPUSince = $null
                            LowCPUSince = $null
                            LastUpdate = $currentTime
                        }
                    }
                    $data = $this.ProcessCPU[$processId]
                    # Dodaj tylko jesli mamy rzeczywisty pomiar
                    if ($cpuPercent -gt 0) {
                        $data.History.Add($cpuPercent)
                        # Ogranicz history do 15 punktow (~30s przy update co 2s)
                        if ($data.History.Count -gt 15) {
                            $data.History.RemoveAt(0)
                        }
                    }
                    # Srednie CPU z ostatnich 5 punktow (bardziej reaktywne niz 10)
                    $recentCount = [Math]::Min(5, $data.History.Count)
                    $avgCPU = 0
                    if ($recentCount -gt 0) {
                        for ($i = $data.History.Count - $recentCount; $i -lt $data.History.Count; $i++) {
                            $avgCPU += $data.History[$i]
                        }
                        $avgCPU /= $recentCount
                    }
                    # Czy to CPU hog- (powyzej threshold)
                    $isCPUHog = $avgCPU -gt $this.ThrottleThreshold
                    if ($isCPUHog) {
                        # CPU hog detected
                        if ($null -eq $data.HighCPUSince) {
                            $data.HighCPUSince = $currentTime
                        }
                        $data.LowCPUSince = $null  # Reset low CPU timer
                        # Throttle jesli przekroczyl duration
                        $hogDuration = ($currentTime - $data.HighCPUSince).TotalSeconds
                        if ($hogDuration -ge $this.ThrottleDuration -and 
                            -not $this.ThrottledProcesses.ContainsKey($processId) -and
                            $proc.ProcessName -ne $foregroundApp) {
                            # Don't throttle if at max
                            if ($this.ThrottledProcesses.Count -lt $this.MaxThrottled) {
                                $this.ThrottleProcess($proc, $avgCPU)
                            }
                        }
                    } else {
                        # CPU usage OK
                        $data.HighCPUSince = $null  # Reset high CPU timer
                        if ($this.ThrottledProcesses.ContainsKey($processId)) {
                            if ($null -eq $data.LowCPUSince) {
                                $data.LowCPUSince = $currentTime
                            }
                            $lowDuration = ($currentTime - $data.LowCPUSince).TotalSeconds
                            if ($lowDuration -ge $this.RestoreCooldown) {
                                $this.RestoreProcess($processId)
                            }
                        }
                    }
                    $data.LastUpdate = $currentTime
                    $proc.Dispose()
                } catch {
                    try { $proc.Dispose() } catch { }
                }
            }
            # Cleanup dead processes
            $this.CleanupDeadProcesses()
        } catch {
            # Ignore errors
        }
    }
    [void] ThrottleProcess([System.Diagnostics.Process]$proc, [double]$cpuUsage) {
        try {
            $processId = $proc.Id
            $originalPriority = $proc.PriorityClass
            # Throttle to BelowNormal (nie Idle - zbyt drastyczne)
            $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
            $this.ThrottledProcesses[$processId] = @{
                Name = $proc.ProcessName
                OriginalPriority = $originalPriority
                ThrottledAt = [DateTime]::Now
                CPUAtThrottle = [Math]::Round($cpuUsage, 1)
            }
            $this.TotalThrottles++
            # Log — rate-limit: max raz na 60s per proces
            $logKey = "PB_$($proc.ProcessName)"
            $now = [DateTime]::UtcNow
            if (-not $Script:ProBalanceLogTimes) { $Script:ProBalanceLogTimes = @{} }
            if (-not $Script:ProBalanceLogTimes.ContainsKey($logKey) -or ($now - $Script:ProBalanceLogTimes[$logKey]).TotalSeconds -gt 60) {
                $Script:ProBalanceLogTimes[$logKey] = $now
                Add-Log "- ProBalance: Throttled '$($proc.ProcessName)' (PID $processId) - CPU $([Math]::Round($cpuUsage, 1))%"
            }
        } catch {
            # Ignore errors (process may have exited)
        }
    }
    [void] RestoreProcess([int]$processId) {
        if (-not $this.ThrottledProcesses.ContainsKey($processId)) { return }
        try {
            $info = $this.ThrottledProcesses[$processId]
            $proc = Get-Process -Id $processId -ErrorAction Stop
            # Restore original priority
            $proc.PriorityClass = $info.OriginalPriority
            $duration = ([DateTime]::Now - $info.ThrottledAt).TotalSeconds
            $this.TotalRestores++
            # Log — tylko jeśli throttle trwał >30s (krótkie cykle to normalne, nie loguj)
            if ($duration -gt 30) {
                Add-Log "- ProBalance: Restored '$($info.Name)' (PID $processId) - ${([Math]::Round($duration, 0))}s"
            }
            $proc.Dispose()
        } catch {
            # Process died - OK
        }
        $this.ThrottledProcesses.Remove($processId)
    }
    [void] CleanupDeadProcesses() {
        # ProcessCPU cleanup
        $deadPIDs = @()
        foreach ($processId in $this.ProcessCPU.Keys) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction Stop
                $proc.Dispose()
            } catch {
                $deadPIDs += $processId
            }
        }
        foreach ($processId in $deadPIDs) {
            $this.ProcessCPU.Remove($processId)
            if ($this.LastCPUTime.ContainsKey($processId)) {
                $this.LastCPUTime.Remove($processId)
            }
        }
        # ThrottledProcesses cleanup
        $deadThrottled = @()
        foreach ($processId2 in $this.ThrottledProcesses.Keys) {
            try {
                $proc = Get-Process -Id $processId2 -ErrorAction Stop
                $proc.Dispose()
            } catch {
                $deadThrottled += $processId2
            }
        }
        foreach ($processId2 in $deadThrottled) {
            $this.ThrottledProcesses.Remove($processId2)
        }
    }
    [void] RestoreAll() {
        $pidsToRestore = @($this.ThrottledProcesses.Keys)
        foreach ($processId3 in $pidsToRestore) {
            $this.RestoreProcess($processId3)
        }
    }
    [string] GetStatus() {
        $throttled = $this.ThrottledProcesses.Count
        return "Throttled:$throttled Total:$($this.TotalThrottles)/$($this.TotalRestores) Enabled:$($this.Enabled)"
    }
    [hashtable] GetStats() {
        return @{
            Enabled = $this.Enabled
            CurrentlyThrottled = $this.ThrottledProcesses.Count
            TotalThrottles = $this.TotalThrottles
            TotalRestores = $this.TotalRestores
            Threshold = $this.ThrottleThreshold
            ThrottledProcesses = $this.ThrottledProcesses.Values | ForEach-Object { 
                "$($_.Name) ($($_.CPUAtThrottle)%)" 
            }
        }
    }
    # - V40: ApplyAIRecommendations - zastosuj rekomendacje ProcessAI
    [void] ApplyAIRecommendations([hashtable]$recommendations) {
        if (-not $this.Enabled -or -not $recommendations) { return }
        try {
            # Lista procesow ktore AI oznaczyl jako bezpieczne do throttle
            $safeToThrottle = $recommendations.SafeToThrottle
            # Lista procesow wysokiego priorytetu (gaming/rendering)
            $highPriority = $recommendations.HighPriority
            
            # 0. Wyczysc stare AI temporary protection (zachowaj tylko core system processes)
            $coreSystem = @("System", "Idle", "svchost", "csrss", "smss", "wininit", "services", "lsass", "dwm", "explorer", "CPUManager", "ShellExperienceHost", "ApplicationFrameHost", "TextInputHost", "ShellHost", "sihost", "taskhostw", "RuntimeBroker", "dllhost", "ctfmon", "audiodg", "powershell", "pwsh")
            $toRemove = @()
            foreach ($key in $this.SystemProcesses.Keys) {
                if ($coreSystem -notcontains $key) {
                    $toRemove += $key
                }
            }
            foreach ($key in $toRemove) {
                $this.SystemProcesses.Remove($key)
            }
            
            # 1. Dodaj AI-recommended high priority do ochrony
            if ($highPriority) {
                foreach ($appName in $highPriority) {
                    if (-not [string]::IsNullOrWhiteSpace($appName)) {
                        $this.SystemProcesses[$appName] = $true  # Temporary protection
                    }
                }
            }
            
            # 2. Throttle procesy AI-recommended dla throttlingu (jesli CPU wysoki)
            if ($safeToThrottle) {
                $processes = Get-Process | Where-Object { 
                    $safeToThrottle -contains $_.ProcessName -and
                    -not $this.ThrottledProcesses.ContainsKey($_.Id)
                }
                foreach ($proc in $processes) {
                    try {
                        if ($this.ThrottledProcesses.Count -lt $this.MaxThrottled) {
                            # Throttle tylko jezeli proces uzywa > 5% CPU (nie throttle idle)
                            if ($this.ProcessCPU.ContainsKey($proc.Id)) {
                                $data = $this.ProcessCPU[$proc.Id]
                                $recentCount = [Math]::Min(3, $data.History.Count)
                                if ($recentCount -gt 0) {
                                    $avgCPU = 0
                                    for ($i = $data.History.Count - $recentCount; $i -lt $data.History.Count; $i++) {
                                        $avgCPU += $data.History[$i]
                                    }
                                    $avgCPU /= $recentCount
                                    if ($avgCPU -gt 5.0) {  # Throttle tylko aktywne procesy
                                        $this.ThrottleProcess($proc, $avgCPU)
                                    }
                                }
                            }
                        }
                        $proc.Dispose()
                    } catch {
                        try { $proc.Dispose() } catch { }
                    }
                }
            }
        } catch {
            # Ignore errors
        }
    }
}
class PerformanceBooster {
    [hashtable] $KnownHeavyApps          # Apps wymagające boost
    [hashtable] $AppExecutablePaths      # App -> ścieżka exe dla cache warming
    [hashtable] $FrozenProcesses         # PID -> {Name, OriginalPriority, FrozenAt}
    [hashtable] $BoostedProcesses        # PID -> {Name, OriginalPriority, BoostedAt}
    [bool] $Enabled = $true
    [bool] $PreemptiveBoostEnabled = $true
    [bool] $PriorityBoostEnabled = $true
    [bool] $BackgroundFreezeEnabled = $true
    [bool] $MemoryPreallocationEnabled = $true
    [bool] $DiskCacheWarmingEnabled = $true
    [int] $PreemptiveBoostSeconds = 3     # Ile sekund przed uruchomieniem
    [int] $MaxFrozenProcesses = 15
    [int] $TotalPreemptiveBoosts = 0
    [int] $TotalPriorityBoosts = 0
    [int] $TotalFreezes = 0
    [int] $TotalCacheWarms = 0
    [datetime] $LastPreemptiveBoost = [datetime]::MinValue
    [string] $LastBoostReason = ""
    [string] $CacheFilePath = ""
    [bool] $CacheDirty = $false
    [datetime] $LastCacheSave = [datetime]::MinValue
    [datetime] $CacheLastChange = [datetime]::MinValue
    # Protected processes - nigdy nie freeze
    [hashtable] $ProtectedProcesses = @{
        "System" = $true; "Idle" = $true; "svchost" = $true; "csrss" = $true
        "smss" = $true; "wininit" = $true; "services" = $true; "lsass" = $true
        "dwm" = $true; "explorer" = $true; "winlogon" = $true; "fontdrvhost" = $true
        "sihost" = $true; "taskhostw" = $true; "RuntimeBroker" = $true
        "SearchHost" = $true; "StartMenuExperienceHost" = $true
        "powershell" = $true; "pwsh" = $true; "conhost" = $true
        "SecurityHealthService" = $true; "MsMpEng" = $true; "NisSrv" = $true
        "audiodg" = $true; "ctfmon" = $true; "dllhost" = $true
        # Shell UI — BEZ TEGO = białe ikony, znikające UI, mrugający taskbar
        "ShellExperienceHost" = $true; "ApplicationFrameHost" = $true
        "TextInputHost" = $true; "ShellHost" = $true
        "WindowsTerminal" = $true; "WmiPrvSE" = $true
        # Audio/DAW/VST — nigdy nie zamrażaj (dropout i cięcia dźwięku)
        "kontakt" = $true; "kontakt7" = $true; "kontakt6" = $true
        "vstbridge" = $true; "vstbridge64" = $true; "jbridge" = $true; "jbridge64" = $true
        "audiogridder" = $true; "audiogridder-bridge" = $true
        "cubase" = $true; "cubase13" = $true; "reaper" = $true; "reaper64" = $true
        "fl64" = $true; "flstudio" = $true; "bitwig" = $true; "ableton" = $true
        "studioone" = $true; "nuendo" = $true; "protools" = $true
    }
    # Heavy apps które wymagają boost (domyślna lista)
    [hashtable] $DefaultHeavyApps = @{
        # Gry
        "steam" = @{ Priority = "High"; NeedsCache = $true; Category = "Gaming" }
        "steamwebhelper" = @{ Priority = "Normal"; NeedsCache = $false; Category = "Gaming" }
        "EpicGamesLauncher" = @{ Priority = "High"; NeedsCache = $true; Category = "Gaming" }
        "Origin" = @{ Priority = "High"; NeedsCache = $true; Category = "Gaming" }
        "Battle.net" = @{ Priority = "High"; NeedsCache = $true; Category = "Gaming" }
        "GalaxyClient" = @{ Priority = "High"; NeedsCache = $true; Category = "Gaming" }
        # IDE / Development
        "devenv" = @{ Priority = "High"; NeedsCache = $true; Category = "Development" }
        "Code" = @{ Priority = "AboveNormal"; NeedsCache = $true; Category = "Development" }
        "rider64" = @{ Priority = "High"; NeedsCache = $true; Category = "Development" }
        "idea64" = @{ Priority = "High"; NeedsCache = $true; Category = "Development" }
        "pycharm64" = @{ Priority = "High"; NeedsCache = $true; Category = "Development" }
        "AndroidStudio" = @{ Priority = "High"; NeedsCache = $true; Category = "Development" }
        # Creative
        "Photoshop" = @{ Priority = "High"; NeedsCache = $true; Category = "Creative" }
        "AfterFX" = @{ Priority = "High"; NeedsCache = $true; Category = "Creative" }
        "Premiere Pro" = @{ Priority = "High"; NeedsCache = $true; Category = "Creative" }
        "blender" = @{ Priority = "High"; NeedsCache = $true; Category = "Creative" }
        "Unity" = @{ Priority = "High"; NeedsCache = $true; Category = "Creative" }
        "UE4Editor" = @{ Priority = "High"; NeedsCache = $true; Category = "Creative" }
        # Office
        "WINWORD" = @{ Priority = "AboveNormal"; NeedsCache = $false; Category = "Office" }
        "EXCEL" = @{ Priority = "AboveNormal"; NeedsCache = $false; Category = "Office" }
        "POWERPNT" = @{ Priority = "AboveNormal"; NeedsCache = $false; Category = "Office" }
    }
    PerformanceBooster() {
        $this.KnownHeavyApps = $this.DefaultHeavyApps.Clone()
        $this.AppExecutablePaths = @{}
        $this.FrozenProcesses = @{}
        $this.BoostedProcesses = @{}
        $this.CacheFilePath = ""
        $this.CacheDirty = $false
        $this.LastCacheSave = [datetime]::MinValue
        $this.CacheLastChange = [datetime]::MinValue
    }
    # 1. PREEMPTIVE BOOST - Boost PRZED uruchomieniem ciężkiej aplikacji
    [hashtable] CheckPreemptiveBoost([ProphetMemory]$prophet, $chainPredictor) {
        if (-not $this.PreemptiveBoostEnabled -or -not $prophet) { 
            return @{ ShouldBoost = $false } 
        }
        $now = [datetime]::Now
        $cooldown = ($now - $this.LastPreemptiveBoost).TotalSeconds
        # PREEMPTIVE ma sens tylko PRZED uruchomieniem, nie ciągle
        if ($cooldown -lt 120) { return @{ ShouldBoost = $false } }
        $isAppRunning = {
            param([string]$appName)
            if ([string]::IsNullOrWhiteSpace($appName)) { return $true }
            $procName = $appName -replace '\.exe$', ''
            $running = Get-Process -Name $procName -ErrorAction SilentlyContinue
            return ($null -ne $running -and $running.Count -gt 0)
        }
        # Sprawdź Chain prediction - use CurrentPrediction property
        if ($chainPredictor -and ![string]::IsNullOrWhiteSpace($chainPredictor.CurrentPrediction)) {
            $appName = $chainPredictor.CurrentPrediction
            $confidence = $chainPredictor.PredictionConfidence
            if (& $isAppRunning $appName) {
                return @{ ShouldBoost = $false }
            }
            if ($confidence -lt 0.7) {
                return @{ ShouldBoost = $false }
            }
            # Czy to heavy app?
            if ($this.IsHeavyApp($appName) -or ($prophet.Apps.ContainsKey($appName) -and $prophet.Apps[$appName].IsHeavy)) {
                $this.LastPreemptiveBoost = $now
                $this.TotalPreemptiveBoosts++
                $this.LastBoostReason = "Chain predicted: $appName"
                return @{
                    ShouldBoost = $true
                    App = $appName
                    Reason = "PREEMPTIVE: Chain -> $appName"
                    Confidence = $confidence
                }
            }
        }
        # Hour pattern jest zbyt agresywny i nie sprawdza rzeczywistego kontekstu
        # Zostaje tylko Chain prediction z wysokim confidence
        <#
        # Sprawdź Prophet hourly prediction
        $hour = $now.Hour
        $heavyAppsThisHour = @()
        foreach ($appKey in $prophet.Apps.Keys) {
            $app = $prophet.Apps[$appKey]
            if ($app.IsHeavy -and $app.HourHits[$hour] -gt 2) {
                $heavyAppsThisHour += @{ Name = $appKey; Hits = $app.HourHits[$hour] }
            }
        }
        if ($heavyAppsThisHour.Count -gt 0) {
            $topApp = $heavyAppsThisHour | Sort-Object { $_.Hits } -Descending | Select-Object -First 1
            $this.LastPreemptiveBoost = $now
            $this.TotalPreemptiveBoosts++
            $this.LastBoostReason = "Hourly pattern: $($topApp.Name)"
            return @{
                ShouldBoost = $true
                App = $topApp.Name
                Reason = "PREEMPTIVE: Hour pattern -> $($topApp.Name)"
                Confidence = [Math]::Min(0.9, $topApp.Hits / 10.0)
            }
        }
        #>
        return @{ ShouldBoost = $false }
    }
    # 2. PROCESS PRIORITY BOOST - Ustaw wysoki priorytet dla uruchomionej app
    [bool] BoostProcessPriority([string]$processName) {
        return $this.BoostProcessPriority($processName, 0)
    }
    [bool] BoostProcessPriority([string]$processName, [int]$processId) {
        if (-not $this.PriorityBoostEnabled) { return $false }
        try {
            $procs = if ($processId -gt 0) {
                @(Get-Process -Id $processId -ErrorAction SilentlyContinue)
            } else {
                @(Get-Process -Name $processName -ErrorAction SilentlyContinue)
            }
            foreach ($proc in $procs) {
                if ($this.BoostedProcesses.ContainsKey($proc.Id)) { continue }
                $targetPriority = [System.Diagnostics.ProcessPriorityClass]::High
                # Sprawdź czy mamy custom priority dla tej app
                if ($this.KnownHeavyApps.ContainsKey($processName)) {
                    $priorityStr = $this.KnownHeavyApps[$processName].Priority
                    $targetPriority = switch ($priorityStr) {
                        "High" { [System.Diagnostics.ProcessPriorityClass]::High }
                        "AboveNormal" { [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
                        "RealTime" { [System.Diagnostics.ProcessPriorityClass]::High }  # Safety: nie RealTime
                        default { [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
                    }
                }
                $originalPriority = $proc.PriorityClass
                $proc.PriorityClass = $targetPriority
                $this.BoostedProcesses[$proc.Id] = @{
                    Name = $processName
                    OriginalPriority = $originalPriority
                    BoostedAt = [datetime]::Now
                    TargetPriority = $targetPriority
                }
                $this.TotalPriorityBoosts++
                # Próbuj ustawić CPU affinity na P-cores (dla hybrid CPU)
                $this.SetOptimalAffinity($proc)
            }
            return $true
        } catch {
            return $false
        }
    }
    [void] SetOptimalAffinity([System.Diagnostics.Process]$proc) {
        try {
            $coreCount = [Environment]::ProcessorCount
            if ($coreCount -ge 8) {
                # Dynamiczny mask: użyj wszystkich fizycznych rdzeni (nie hardcoded 255)
                # Dla 8 cores = 0xFF, 16 cores = 0xFFFF, 24 cores = 0xFFFFFF
                $mask = [long]([Math]::Pow(2, [Math]::Min($coreCount, 64)) - 1)
                $proc.ProcessorAffinity = [IntPtr]$mask
            }
        } catch { }
    }
    # 3. BACKGROUND FREEZE - Zamroź niepotrzebne procesy w tle
    [int] FreezeBackgroundProcesses([string]$foregroundApp) {
        if (-not $this.BackgroundFreezeEnabled) { return 0 }
        # AUDIO SAFE MODE: Nigdy nie zamrażaj procesów gdy DAW/VST aktywne — cięcia dźwięku i dropout
        if ($Script:CurrentAppContext -eq "Audio") { return 0 }
        $frozenCount = 0
        try {
            # Pobierz procesy używające dużo zasobów
            $heavyBgProcesses = Get-Process | Where-Object {
                $_.WorkingSet64 -gt 100MB -and  # >100MB RAM
                $_.ProcessName -ne $foregroundApp -and
                -not $this.ProtectedProcesses.ContainsKey($_.ProcessName) -and
                -not $this.FrozenProcesses.ContainsKey($_.Id) -and
                -not $this.IsHeavyApp($_.ProcessName) -and  # Nie freeze innych heavy apps
                $_.PriorityClass -ne [System.Diagnostics.ProcessPriorityClass]::BelowNormal  # V38: Nie freeze juz throttlowanych przez ProBalance
            } | Sort-Object WorkingSet64 -Descending | Select-Object -First $this.MaxFrozenProcesses
            foreach ($proc in $heavyBgProcesses) {
                if ($this.SuspendProcess($proc)) {
                    $this.FrozenProcesses[$proc.Id] = @{
                        Name = $proc.ProcessName
                        FrozenAt = [datetime]::Now
                        MemoryMB = [Math]::Round($proc.WorkingSet64 / 1MB, 0)
                    }
                    $this.TotalFreezes++
                    $frozenCount++
                }
            }
        } catch { }
        return $frozenCount
    }
    [void] UnfreezeAllProcesses() {
        foreach ($processId in @($this.FrozenProcesses.Keys)) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc) {
                    $this.ResumeProcess($proc)
                }
            } catch { }
            $this.FrozenProcesses.Remove($processId)
        }
    }
    [bool] SuspendProcess([System.Diagnostics.Process]$proc) {
        # Setting to Idle effectively "freezes" the process for CPU scheduling
        try {
            $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Idle
            return $true
        } catch { }
        return $false
    }
    [bool] ResumeProcess([System.Diagnostics.Process]$proc) {
        try {
            $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
            return $true
        } catch { }
        return $false
    }
    # 4. MEMORY PRE-ALLOCATION - Zwolnij RAM przed uruchomieniem ciężkiej app
    [hashtable] PreallocateMemory([string]$appName) {
        if (-not $this.MemoryPreallocationEnabled) { 
            return @{ Success = $false; FreedMB = 0 } 
        }
        $beforeMB = [Math]::Round([GC]::GetTotalMemory($false) / 1MB, 1)
        try {
            # Aggressive GC - this is safe, no Win32 calls
            [GC]::Collect(2, [GCCollectionMode]::Forced, $true)
            [GC]::WaitForPendingFinalizers()
            [GC]::Collect(2, [GCCollectionMode]::Forced, $true)
            # EmptyWorkingSet would require Win32 which breaks class parsing
        } catch { }
        $afterMB = [Math]::Round([GC]::GetTotalMemory($false) / 1MB, 1)
        $freedMB = [Math]::Max(0, $beforeMB - $afterMB)
        return @{
            Success = $true
            FreedMB = $freedMB
            Reason = "Memory prepared for $appName"
        }
    }
    # 5. DISK CACHE WARMING - Wczytaj pliki aplikacji do cache
    [bool] WarmDiskCache([string]$appName) {
        return $this.WarmDiskCache($appName, "")
    }
    [bool] WarmDiskCache([string]$appName, [string]$exePath) {
        if (-not $this.DiskCacheWarmingEnabled) { return $false }
        try {
            $pathToWarm = $exePath
            # Jeśli nie mamy ścieżki, spróbuj znaleźć
            if ([string]::IsNullOrWhiteSpace($pathToWarm)) {
                if ($this.AppExecutablePaths.ContainsKey($appName)) {
                    $pathToWarm = $this.AppExecutablePaths[$appName]
                } else {
                    # Spróbuj znaleźć przez Get-Process
                    $proc = Get-Process -Name $appName -ErrorAction SilentlyContinue | Select-Object -First 1
                    if ($proc -and $proc.Path) {
                        $pathToWarm = $proc.Path
                        $this.AppExecutablePaths[$appName] = $pathToWarm
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($pathToWarm) -or -not (Test-Path $pathToWarm)) {
                return $false
            }
            # Warm the executable and DLLs in same directory
            $appDir = [System.IO.Path]::GetDirectoryName($pathToWarm)
            # Start background job to warm cache
            Start-Job -ScriptBlock {
                param($dir, $exe)
                # Read main executable
                if (Test-Path $exe) {
                    $bytes = [System.IO.File]::ReadAllBytes($exe)
                    $bytes = $null
                }
                # Read DLLs (first 20, sorted by size)
                $dlls = Get-ChildItem -Path $dir -Filter "*.dll" -ErrorAction SilentlyContinue | 
                    Sort-Object Length -Descending | 
                    Select-Object -First 20
                foreach ($dll in $dlls) {
                    try {
                        $bytes = [System.IO.File]::ReadAllBytes($dll.FullName)
                        $bytes = $null
                    } catch { }
                }
            } -ArgumentList $appDir, $pathToWarm | Out-Null
            $this.TotalCacheWarms++
            return $true
        } catch {
            return $false
        }
    }
    # HELPER METHODS
    [bool] IsHeavyApp([string]$appName) {
        return $this.KnownHeavyApps.ContainsKey($appName)
    }
    [void] LearnHeavyApp([string]$appName, [double]$peakCPU, [double]$peakRAM) {
        if ($peakCPU -gt 70 -or $peakRAM -gt 800) {  # >70% CPU lub >800MB RAM
            if (-not $this.KnownHeavyApps.ContainsKey($appName)) {
                $this.KnownHeavyApps[$appName] = @{
                    Priority = "AboveNormal"
                    NeedsCache = ($peakRAM -gt 500)
                    Category = "Learned"
                    PeakCPU = $peakCPU
                    PeakRAM = $peakRAM
                }
                # Mark cache dirty so caller can persist (debounced)
                $this.CacheDirty = $true
                $this.CacheLastChange = Get-Date
            }
        }
    }

    [void] SaveCache([string]$path) {
        try {
            if ([string]::IsNullOrWhiteSpace($path)) { return }
            $data = @{ KnownHeavyApps = $this.KnownHeavyApps; AppExecutablePaths = $this.AppExecutablePaths }
            $json = $data | ConvertTo-Json -Depth 10 -Compress
            $tmp = "$path.tmp"
            [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
            try { Move-Item -Path $tmp -Destination $path -Force -ErrorAction Stop } catch { Copy-Item -Path $tmp -Destination $path -Force; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            $this.CacheFilePath = $path
            $this.CacheDirty = $false
            $this.LastCacheSave = Get-Date
        } catch { }
    }

    [void] LoadCache([string]$path) {
        try {
            if (-not (Test-Path $path)) { return }
            $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $data = $json | ConvertFrom-Json
            if ($data -and $data.KnownHeavyApps) {
                $data.KnownHeavyApps.PSObject.Properties | ForEach-Object { $this.KnownHeavyApps[$_.Name] = $_.Value }
            }
            if ($data -and $data.AppExecutablePaths) {
                $data.AppExecutablePaths.PSObject.Properties | ForEach-Object { $this.AppExecutablePaths[$_.Name] = $_.Value }
            }
            $this.CacheFilePath = $path
            $this.CacheDirty = $false
        } catch { }
    }
    [void] RestoreAllPriorities() {
        foreach ($processId in @($this.BoostedProcesses.Keys)) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc) {
                    $original = $this.BoostedProcesses[$processId].OriginalPriority
                    $proc.PriorityClass = $original
                }
            } catch { }
            $this.BoostedProcesses.Remove($processId)
        }
    }
    [void] Cleanup() {
        # Cleanup dead processes
        $deadPIDs = @()
        foreach ($processId in $this.BoostedProcesses.Keys) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction Stop
            } catch {
                $deadPIDs += $processId
            }
        }
        foreach ($processId in $deadPIDs) {
            $this.BoostedProcesses.Remove($processId)
        }
        # Auto-unfreeze after 60 seconds
        $now = [datetime]::Now
        $toUnfreeze = @()
        foreach ($processId in $this.FrozenProcesses.Keys) {
            $info = $this.FrozenProcesses[$processId]
            if (($now - $info.FrozenAt).TotalSeconds -gt 60) {
                $toUnfreeze += $processId
            }
        }
        foreach ($processId in $toUnfreeze) {
            try {
                $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
                if ($proc) { $this.ResumeProcess($proc) }
            } catch { }
            $this.FrozenProcesses.Remove($processId)
        }
    }
    [hashtable] GetStats() {
        return @{
            Enabled = $this.Enabled
            PreemptiveBoosts = $this.TotalPreemptiveBoosts
            PriorityBoosts = $this.TotalPriorityBoosts
            Freezes = $this.TotalFreezes
            CacheWarms = $this.TotalCacheWarms
            CurrentlyBoosted = $this.BoostedProcesses.Count
            CurrentlyFrozen = $this.FrozenProcesses.Count
            LastBoostReason = $this.LastBoostReason
            KnownHeavyApps = $this.KnownHeavyApps.Count
        }
    }
    [string] GetStatus() {
        return "Boosts:$($this.TotalPriorityBoosts) Preempt:$($this.TotalPreemptiveBoosts) Frozen:$($this.FrozenProcesses.Count) Cache:$($this.TotalCacheWarms)"
    }
}
# LOAD PREDICTOR - FIXED z limitem wzorcow
class LoadPredictor {
    [double[,]] $HourlyPatterns
    [int[,]] $HourlySamples
    [double[]] $ShortTermBuffer
    [int] $BufferIndex
    [int] $BufferCount
    [hashtable] $AppLaunchPatterns
    [double] $LastPrediction
    [string] $PredictionReason
    [int] $MaxAppPatterns = 50
    LoadPredictor() {
        $this.HourlyPatterns = [double[,]]::new(24, 7)
        $this.HourlySamples = [int[,]]::new(24, 7)
        $this.ShortTermBuffer = [double[]]::new(30)
        $this.BufferIndex = 0
        $this.BufferCount = 0
        $this.AppLaunchPatterns = @{}
        $this.LastPrediction = 0
        $this.PredictionReason = ""
        for ($h = 0; $h -lt 24; $h++) {
            for ($d = 0; $d -lt 7; $d++) {
                $this.HourlyPatterns[$h, $d] = 15.0
                $this.HourlySamples[$h, $d] = 0
            }
        }
    }
    [void] RecordSample([double]$cpu, [double]$io) {
        $this.ShortTermBuffer[$this.BufferIndex] = $cpu
        $this.BufferIndex = ($this.BufferIndex + 1) % 30
        if ($this.BufferCount -lt 30) { $this.BufferCount++ }
        $hour = (Get-Date).Hour
        $dayOfWeek = [int](Get-Date).DayOfWeek
        $samples = $this.HourlySamples[$hour, $dayOfWeek]
        $currentAvg = $this.HourlyPatterns[$hour, $dayOfWeek]
        if ($samples -eq 0) {
            $this.HourlyPatterns[$hour, $dayOfWeek] = $cpu
        } else {
            $alpha = 1.0 / [Math]::Min(100, $samples + 1)
            $this.HourlyPatterns[$hour, $dayOfWeek] = ($currentAvg * (1 - $alpha)) + ($cpu * $alpha)
        }
        $this.HourlySamples[$hour, $dayOfWeek]++
    }
    [void] RecordAppLaunch([string]$appName) {
        if ([string]::IsNullOrWhiteSpace($appName)) { return }
        if ($this.AppLaunchPatterns.Count -ge $this.MaxAppPatterns -and 
            -not $this.AppLaunchPatterns.ContainsKey($appName)) {
            $oldest = $this.AppLaunchPatterns.GetEnumerator() | Select-Object -First 1
            if ($oldest) {
                $this.AppLaunchPatterns.Remove($oldest.Key)
            }
        }
        $hour = (Get-Date).Hour
        $dayOfWeek = [int](Get-Date).DayOfWeek
        $key = "$hour-$dayOfWeek"
        if (-not $this.AppLaunchPatterns.ContainsKey($appName)) {
            $this.AppLaunchPatterns[$appName] = @{}
        }
        if (-not $this.AppLaunchPatterns[$appName].ContainsKey($key)) {
            $this.AppLaunchPatterns[$appName][$key] = 0
        }
        $this.AppLaunchPatterns[$appName][$key]++
    }
    [double] PredictNextMinute() {
        $prediction = 0.0
        $reasons = @()
        $hour = (Get-Date).Hour
        $nextHour = ($hour + 1) % 24
        $dayOfWeek = [int](Get-Date).DayOfWeek
        $historicalAvg = $this.HourlyPatterns[$hour, $dayOfWeek]
        $nextHourAvg = $this.HourlyPatterns[$nextHour, $dayOfWeek]
        $minuteOfHour = (Get-Date).Minute
        $hourlyPrediction = $historicalAvg + (($nextHourAvg - $historicalAvg) * ($minuteOfHour / 60.0))
        $prediction += $hourlyPrediction * 0.4
        if ($this.BufferCount -ge 5) {
            $recentSum = 0.0
            $oldSum = 0.0
            $recentCount = [Math]::Min(5, $this.BufferCount)
            $oldCount = [Math]::Min(10, $this.BufferCount)
            for ($i = 0; $i -lt $recentCount; $i++) {
                $idx = ($this.BufferIndex - 1 - $i + 30) % 30
                $recentSum += $this.ShortTermBuffer[$idx]
            }
            for ($i = $recentCount; $i -lt $oldCount; $i++) {
                $idx = ($this.BufferIndex - 1 - $i + 30) % 30
                $oldSum += $this.ShortTermBuffer[$idx]
            }
            $recentAvg = $recentSum / $recentCount
            $oldAvg = if ($oldCount -gt $recentCount) { $oldSum / ($oldCount - $recentCount) } else { $recentAvg }
            $trend = $recentAvg - $oldAvg
            $trendPrediction = $recentAvg + ($trend * 2)
            $trendPrediction = [Math]::Max(0, [Math]::Min(100, $trendPrediction))
            $prediction += $trendPrediction * 0.6
            if ($trend -gt 5) { $reasons += "Rising trend" }
            elseif ($trend -lt -5) { $reasons += "Falling trend" }
        } else {
            $prediction += $historicalAvg * 0.6
        }
        $prediction = [Math]::Max(0, [Math]::Min(100, $prediction))
        $this.LastPrediction = [Math]::Round($prediction, 1)
        $this.PredictionReason = if ($reasons.Count -gt 0) { $reasons -join ", " } else { "Stable" }
        return $this.LastPrediction
    }
    [string[]] PredictNextApps([ProphetMemory]$prophet) {
        $predicted = @()
        $hour = (Get-Date).Hour
        $dayOfWeek = [int](Get-Date).DayOfWeek
        $key = "$hour-$dayOfWeek"
        foreach ($appName in $this.AppLaunchPatterns.Keys) {
            $pattern = $this.AppLaunchPatterns[$appName]
            if ($pattern.ContainsKey($key) -and $pattern[$key] -ge 3) {
                $predicted += $appName
            }
        }
        if ($prophet -and $prophet.Apps) {
            foreach ($appName in $prophet.Apps.Keys) {
                $app = $prophet.Apps[$appName]
                if ($app.HourHits -and $app.HourHits[$hour] -ge 3) {
                    if ($predicted -notcontains $appName) {
                        $predicted += $appName
                    }
                }
            }
        }
        return $predicted | Select-Object -First 5
    }
    [int] GetPatternCount() {
        $count = 0
        for ($h = 0; $h -lt 24; $h++) {
            for ($d = 0; $d -lt 7; $d++) {
                if ($this.HourlySamples[$h, $d] -gt 0) { $count++ }
            }
        }
        return $count
    }
    [void] SavePatterns([string]$configDir) {
        try {
            $path = Join-Path $configDir "LoadPatterns.json"
            $hourlyData = @{}
            for ($h = 0; $h -lt 24; $h++) {
                $hourlyData["$h"] = @{}
                for ($d = 0; $d -lt 7; $d++) {
                    $hourlyData["$h"]["$d"] = @{
                        Avg = $this.HourlyPatterns[$h, $d]
                        Samples = $this.HourlySamples[$h, $d]
                    }
                }
            }
            $data = @{
                HourlyData = $hourlyData
                AppLaunchPatterns = $this.AppLaunchPatterns
            }
            $json = $data | ConvertTo-Json -Depth 5 -Compress
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadPatterns([string]$configDir) {
        try {
            $path = Join-Path $configDir "LoadPatterns.json"
            if (Test-Path $path) {
                $json = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                $data = $json | ConvertFrom-Json
                if ($data.HourlyData) {
                    $data.HourlyData.PSObject.Properties | ForEach-Object {
                        $h = [int]$_.Name
                        $hourData = $_.Value  # v39 FIX: Zachowaj wartosc przed wewnetrzna petla
                        $hourData.PSObject.Properties | ForEach-Object {
                            $d = [int]$_.Name
                            $this.HourlyPatterns[$h, $d] = [double]$_.Value.Avg
                            $this.HourlySamples[$h, $d] = [int]$_.Value.Samples
                        }
                    }
                }
                if ($data.AppLaunchPatterns) {
                    $data.AppLaunchPatterns.PSObject.Properties | ForEach-Object {
                        $appName = $_.Name
                        $this.AppLaunchPatterns[$appName] = @{}
                        $_.Value.PSObject.Properties | ForEach-Object {
                            $hourName = $_.Name  # v39 FIX
                            $this.AppLaunchPatterns[$appName][$hourName] = [int]$_.Value
                        }
                    }
                }
            }
        } catch { }
    }
}
#  MEGA AI: Q-LEARNING AGENT - Reinforcement Learning
class QLearningAgent {
    [hashtable] $QTable
    [double] $LearningRate
    [double] $DiscountFactor
    [double] $ExplorationRate
    [string] $LastState
    [string] $LastAction
    [int] $TotalUpdates
    [double] $CumulativeReward
    [double] $LastReward           # V37.8.5: Ostatni reward (do wyswietlania w Configurator)
    [double] $LastRAM              # V35: Ostatni poziom RAM
    [bool] $LastRAMSpike           # V35: Czy byl spike RAM
    [string] $CurrentApp           # v43.14: Aktywna app (per-app learning)
    QLearningAgent() {
        $this.QTable = @{}
        $this.LearningRate = 0.2
        $this.DiscountFactor = 0.9
        $this.ExplorationRate = 0.15
        $this.LastState = ""
        $this.LastAction = ""
        $this.TotalUpdates = 0
        $this.CumulativeReward = 0
        $this.LastReward = 0.0
        $this.LastRAM = 0
        $this.LastRAMSpike = $false
        $this.CurrentApp = ""
    }
    [string] DiscretizeState([double]$cpu, [double]$temp, [bool]$active, [string]$context, [double]$ram, [bool]$ramSpike, [string]$phase) {
        $cpuBin = [Math]::Min(4, [Math]::Floor($cpu / 20))
        $tempBin = if ($temp -lt 60) { 0 } elseif ($temp -lt 80) { 1 } else { 2 }
        $actBin = if ($active) { 1 } else { 0 }
        $ctxBin = switch ($context) { "Gaming" { 2 } "Rendering" { 2 } "Audio" { 2 } default { if ($context -eq "Idle") { 0 } else { 1 } } }
        $ramBin = if ($ramSpike) { 4 } elseif ($ram -lt 40) { 0 } elseif ($ram -lt 60) { 1 } elseif ($ram -lt 75) { 2 } elseif ($ram -lt 85) { 3 } else { 4 }
        $phaseBin = switch ($phase) { "Loading" { "L" } "Gameplay" { "G" } "Active" { "A" } "Cutscene" { "C" } "Menu" { "M" } "Paused" { "Z" } default { "I" } }
        # v46: App w state = KATEGORIA (nie nazwa!) → zarządzalny Q-Table
        # Per-app data jest w Prophet + SharedAppKnowledge, Q-Learning uczy się WZORCÓW KATEGORII
        $appBin = "norm"
        if ($this.CurrentApp) {
            $al = $this.CurrentApp.ToLower()
            # Użyj kategorii z Prophet jeśli dostępna, inaczej inferuj z context
            if ($context -eq "Gaming" -or $context -eq "Rendering") { $appBin = "heavy" }
            elseif ($context -eq "Audio") { $appBin = "audio" }
            elseif ($context -eq "Coding") { $appBin = "code" }
            elseif ($context -eq "Idle") { $appBin = "idle" }
            else { $appBin = "norm" }
        }
        $this.LastRAM = $ram
        $this.LastRAMSpike = $ramSpike
        return "$appBin|C$cpuBin-T$tempBin-A$actBin-X$ctxBin-R$ramBin-P$phaseBin"
    }
    # Kompatybilnosc wsteczna - sygnatura bez Phase
    [string] DiscretizeState([double]$cpu, [double]$temp, [bool]$active, [string]$context, [double]$ram, [bool]$ramSpike) {
        return $this.DiscretizeState($cpu, $temp, $active, $context, $ram, $ramSpike, "Idle")
    }
    # Kompatybilnosc wsteczna - stara sygnatura bez RAM
    [string] DiscretizeState([double]$cpu, [double]$temp, [bool]$active, [string]$context) {
        return $this.DiscretizeState($cpu, $temp, $active, $context, $this.LastRAM, $false)
    }
    [void] InitState([string]$s) {
        if (-not $this.QTable.ContainsKey($s)) {
            $this.QTable[$s] = @{ "Turbo" = 0.0; "Balanced" = 0.0; "Silent" = 0.0 }
        }
    }
    [string] SelectAction([string]$state) {
        $this.InitState($state)
        $action = "Balanced"
        if ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt $this.ExplorationRate) {
            $action = @("Turbo", "Balanced", "Silent")[(Get-Random -Maximum 3)]
        } else {
            $q = $this.QTable[$state]
            # ZMIANA: Przy równych Q-values preferuj niższy tryb (Silent > Balanced > Turbo)
            # To promuje efektywność energetyczną
            $best = "Silent"; $bestV = $q["Silent"]
            if ($q["Balanced"] -gt $bestV) { $best = "Balanced"; $bestV = $q["Balanced"] }
            if ($q["Turbo"] -gt $bestV) { $best = "Turbo" }
            $action = $best
        }
        # v43.1 FIX: Zapisz LastState i LastAction dla następnej iteracji Update()
        $this.LastState = $state
        $this.LastAction = $action
        return $action
    }
    [void] Update([string]$state, [string]$action, [double]$reward, [string]$nextState) {
        $this.InitState($state); $this.InitState($nextState)
        $currentQ = $this.QTable[$state][$action]
        $maxNextQ = [Math]::Max([Math]::Max($this.QTable[$nextState]["Turbo"], $this.QTable[$nextState]["Balanced"]), $this.QTable[$nextState]["Silent"])
        $this.QTable[$state][$action] = $currentQ + $this.LearningRate * ($reward + $this.DiscountFactor * $maxNextQ - $currentQ)
        $this.TotalUpdates++
        $this.CumulativeReward += $reward
        $this.LastReward = $reward  # v39: Zapisz ostatni reward
        $this.ExplorationRate = [Math]::Max(0.05, $this.ExplorationRate * 0.9999)
        $this.LastState = $state; $this.LastAction = $action
    }
    [double] CalcReward([string]$action, [double]$cpu, [double]$temp, [double]$prevTemp, [bool]$active, [double]$ram, [bool]$ramSpike, [string]$phase) {
        $r = 0.0
        # === PHASE-AWARE REWARDS ===
        # v43.14 FIX: Zbalansowane nagrody - Silent NIE dominuje bezwarunkowo
        switch ($phase) {
            "Loading" {
                switch ($action) {
                    "Turbo"    { $r += 2.0 }
                    "Balanced" { $r += 1.0 }
                    "Silent"   { $r -= 1.5 }
                }
            }
            "Gameplay" {
                switch ($action) {
                    "Turbo"    { if ($cpu -gt 60) { $r += 1.0 } else { $r -= 0.5 } }
                    "Balanced" { $r += 1.0 }
                    "Silent"   { if ($cpu -lt 25) { $r += 0.5 } else { $r -= 0.5 } }
                }
            }
            "Cutscene" {
                switch ($action) {
                    "Turbo"    { $r -= 1.0 }
                    "Balanced" { $r += 0.5 }
                    "Silent"   { $r += 1.0 }
                }
            }
            "Menu" {
                switch ($action) {
                    "Turbo"    { $r -= 1.5 }
                    "Balanced" { $r += 0.0 }
                    "Silent"   { $r += 1.0 }
                }
            }
            "Active" {
                switch ($action) {
                    "Turbo"    { $r += 1.5 }
                    "Balanced" { $r += 1.0 }
                    "Silent"   { $r -= 1.0 }
                }
            }
            "Idle" {
                # v43.14 FIX: Mniejsze nagrody w Idle - nie dominuj Q-table
                switch ($action) {
                    "Turbo"    { $r -= 1.0 }
                    "Balanced" { $r += 0.0 }
                    "Silent"   { $r += 1.0 }
                }
            }
            "Paused" {
                switch ($action) {
                    "Turbo"    { $r -= 1.5 }
                    "Balanced" { $r -= 0.5 }
                    "Silent"   { $r += 1.5 }
                }
            }
        }
        # === NOWA FILOZOFIA: Nagradzaj MINIMALNY tryb ktory wystarcza ===
        # === RAM SPIKE - najwyzszy priorytet ===
        if ($ramSpike) {
            switch ($action) {
                "Turbo" { $r += 2.0 }      # Nagroda za Turbo przy spike RAM (zmniejszona z 3.0)
                "Balanced" { $r += 0.5 }   # Mala nagroda
                "Silent" { $r -= 2.0 }     # Kara za Silent przy spike RAM (zmniejszona z 3.0)
            }
        }
        # === Wysoki RAM (>80%) bez spike'a ===
        elseif ($ram -gt 80) {
            switch ($action) {
                "Turbo" { $r += 1.0 }
                "Balanced" { $r += 0.5 }
                "Silent" { $r -= 0.5 }
            }
        }
        # v43.14: Thermal limit for proportional penalty
        $thermalLimit = if ($null -ne $Script:ThermalLimit) { $Script:ThermalLimit } else { 90 }
        $thermalMargin = $thermalLimit - $temp
        # === Standardowa logika CPU ===
        switch ($action) {
            "Turbo" { 
                if ($cpu -gt 85) { $r += 2.5 }
                elseif ($cpu -gt $Script:TurboThreshold) { $r += 0.5 }
                elseif ($cpu -lt $Script:BalancedThreshold -and -not $ramSpike) { 
                    $r -= 2.0   # v43.14: Zmniejszona z 3.0 (mniejsza dominacja Silent)
                }
                if ($thermalMargin -lt 5 -and $cpu -lt 60) { $r -= 1.5 }
                elseif ($thermalMargin -lt 15 -and $cpu -lt 40) { $r -= 0.5 }
            }
            "Silent" { 
                # v43.14 FIX: Zmniejszone nagrody - Silent nie powinien dominować Q-table
                if ($cpu -lt 20 -and -not $active -and $ram -lt 60) { 
                    $r += 2.0   # Zmniejszona z 4.0
                } 
                elseif ($cpu -lt $Script:BalancedThreshold -and $ram -lt 70) { 
                    $r += 1.0   # Zmniejszona z 2.5
                }
                elseif ($cpu -gt $Script:TurboThreshold -or $ram -gt 80) { 
                    $r -= 1.5   # Zwiększona kara - Silent przy wysokim CPU = ZŁO
                }
                # Thermal bonus proporcjonalny
                if ($temp -lt ($thermalLimit - 35)) { $r += 0.3 }  # Tylko daleko od limitu
            }
            "Balanced" { 
                # v43.14: Balanced dostaje BAZOWY bonus (najlepszy kompromis)
                if ($cpu -ge 25 -and $cpu -le 70) { 
                    $r += 1.5
                }
                elseif ($cpu -lt 20 -and $ram -lt 60) {
                    $r -= 0.5   # Zmniejszona z 1.0 - Balanced w Idle też OK
                }
                # v43.14: Bonus za "headroom" - Balanced daje CPU headroom na burst
                if ($active) { $r += 0.5 }
            }
        }
        # === NAGRODA ZA EFEKTYWNOSC ENERGETYCZNA ===
        # v43.14 FIX: Zmniejszona nagroda - duplicated z Phase reward
        if (-not ($Script:PerfMonitor -and $Script:PerfMonitor.HasRecentStutter())) {
            switch ($action) {
                "Silent" { 
                    if ($cpu -lt 50) { $r += 0.5 }   # Zmniejszona z 1.5 (deduplikacja)
                }
                "Balanced" { 
                    if ($cpu -lt 40) { $r += 0.3 }   # Zmniejszona z 0.5
                }
            }
        }
        # === Penalizuj tryby ktore powoduja stuttering ===
        if ($Script:PerfMonitor -and $Script:PerfMonitor.HasRecentStutter()) {
            switch ($action) {
                "Silent" { 
                    # ZMNIEJSZONA kara za Silent (z 5.0 na 2.0)
                    # Stuttering moze byc z innych powodow niz brak mocy
                    $r -= 2.0
                }
                "Balanced" { 
                    $r -= 1.0   # Zmniejszona z 2.0
                }
                "Turbo" { 
                    # Bez nagrody - Turbo nie jest "nagradzany" za stuttering
                    # Powinien byc uzywany gdy potrzebny, nie gdy wystapi stutter
                }
            }
        }
        # v43.14: Context-aware reward (Audio/Gaming/Rendering)
        # Audio apps (Kontakt, Cubase, etc.) WYMAGAJĄ Balanced minimum (realtime buffers)
        if ($Script:CurrentAppContext) {
            switch ($Script:CurrentAppContext) {
                "Audio" {
                    switch ($action) {
                        "Silent"   { $r -= 1.5 }   # Audio + Silent = buffer underruns!
                        "Balanced" { $r += 1.5 }    # Audio = Balanced (stable latency)
                        "Turbo"    { $r += 0.3 }    # Turbo OK ale nie konieczny
                    }
                }
                "Rendering" {
                    switch ($action) {
                        "Silent"   { $r -= 1.0 }
                        "Balanced" { $r += 0.5 }
                        "Turbo"    { $r += 1.5 }    # Rendering needs max CPU
                    }
                }
                "Gaming" {
                    # v46: Gaming = GPU-dependent
                    switch ($action) {
                        "Turbo"    { $r += 1.0 }   # Gaming often needs CPU headroom
                        "Balanced" { $r += 0.8 }   # Stable for GPU-bound games
                        "Silent"   { $r -= 0.5 }   # Can starve CPU-side work
                    }
                }
            }
        }
        # v43.14: CPUAgressiveness modyfikuje reward
        # Aggressive (>50): bonus za Turbo, penalty za Silent
        # Conservative (<50): bonus za Silent, penalty za Turbo
        if ($null -ne $Script:CPUAgressiveness) {
            $aggrMod = ($Script:CPUAgressiveness - 50) / 100.0  # -0.5 to +0.5
            switch ($action) {
                "Turbo"    { $r += $aggrMod * 1.5 }   # aggressive: +0.75, conservative: -0.75
                "Silent"   { $r -= $aggrMod * 1.5 }   # aggressive: -0.75, conservative: +0.75
                # Balanced: neutral (no change)
            }
        }
        return $r
    }
    # Kompatybilnosc wsteczna - sygnatura bez Phase
    [double] CalcReward([string]$action, [double]$cpu, [double]$temp, [double]$prevTemp, [bool]$active, [double]$ram, [bool]$ramSpike) {
        return $this.CalcReward($action, $cpu, $temp, $prevTemp, $active, $ram, $ramSpike, "Idle")
    }
    # Kompatybilnosc wsteczna - stara sygnatura bez RAM
    [double] CalcReward([string]$action, [double]$cpu, [double]$temp, [double]$prevTemp, [bool]$active) {
        return $this.CalcReward($action, $cpu, $temp, $prevTemp, $active, $this.LastRAM, $this.LastRAMSpike, "Idle")
    }
    [string] GetStatus() { return "Q:$($this.QTable.Count) Exp:$([Math]::Round($this.ExplorationRate * 100))%" }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "QLearning.json"
            $data = @{ QTable = $this.QTable; ExplorationRate = $this.ExplorationRate; TotalUpdates = $this.TotalUpdates }
            [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 4 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "QLearning.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.QTable) {
                    $data.QTable.PSObject.Properties | ForEach-Object {
                        $stateName = $_.Name
                        $this.QTable[$stateName] = @{}
                        $_.Value.PSObject.Properties | ForEach-Object {
                            $actionName = $_.Name
                            $this.QTable[$stateName][$actionName] = [double]$_.Value
                        }
                    }
                }
                if ($data.ExplorationRate) { $this.ExplorationRate = $data.ExplorationRate }
                if ($data.TotalUpdates) { $this.TotalUpdates = $data.TotalUpdates }
            }
        } catch { }
    }
}
class EnsembleVoter {
    [hashtable] $Weights
    [hashtable] $Accuracy
    [int] $TotalVotes
    [double] $LastRAM              # V35: Ostatni poziom RAM
    [bool] $LastRAMSpike           # V35: Czy byl spike RAM
    EnsembleVoter() {
        #  WSZYSTKIE modeli z podobnymi wagami - DEMOKRATYCZNE glosowanie
        $this.Weights = @{ 
            "Brain" = 0.08
            "QLearning" = 0.08
            "Bandit" = 0.05
            "Genetic" = 0.06
            "Context" = 0.07
            "Thermal" = 0.06
            "Pattern" = 0.07
            "GPU" = 0.10           # V40.2: Zwiększona waga GPU (dGPU/iGPU reakcja)
            "Predictor" = 0.06
            "Chain" = 0.05
            "Trend" = 0.06
            "Tuner" = 0.06
            "Energy" = 0.06
            "Prophet" = 0.06
            "Anomaly" = 0.06
            "Activity" = 0.06
            "IOMonitor" = 0.08
            "RAMMonitor" = 0.08   # V35 NEW: RAM Monitor jako glos
        }
        $this.Accuracy = @{ 
            "Brain" = 0.6
            "QLearning" = 0.5
            "Bandit" = 0.4
            "Genetic" = 0.5
            "Context" = 0.6
            "Thermal" = 0.5
            "Pattern" = 0.6
            "GPU" = 0.7            # V40.2: Zwiększona accuracy GPU (hardware-based = reliable)
            "Predictor" = 0.5
            "Chain" = 0.4
            "Trend" = 0.5
            "Tuner" = 0.5
            "Energy" = 0.5
            "Prophet" = 0.5
            "Anomaly" = 0.7
            "Activity" = 0.6
            "IOMonitor" = 0.6
            "RAMMonitor" = 0.7   # V35 NEW: RAM Monitor accuracy (wysoka - spikes sa wiarygodne)
        }
        $this.TotalVotes = 0
        $this.LastRAM = 0
        $this.LastRAMSpike = $false
    }
    [string] Vote([hashtable]$decisions, [double]$ram, [bool]$ramSpike) {
        $scores = @{ "Turbo" = 0.0; "Balanced" = 0.0; "Silent" = 0.0 }
        $voteCount = @{ "Turbo" = 0; "Balanced" = 0; "Silent" = 0 }
        $this.LastRAM = $ram
        $this.LastRAMSpike = $ramSpike
        $ramVote = "Balanced"
        if ($ramSpike) {
            $ramVote = "Turbo"
        } elseif ($ram -gt 85) {
            $ramVote = "Turbo"
        } elseif ($ram -gt 70) {
            $ramVote = "Balanced"
        } elseif ($ram -lt 50) {
            $ramVote = "Silent"
        }
        # Dodaj glos RAM do decisions
        $decisions["RAMMonitor"] = $ramVote
        foreach ($m in $decisions.Keys) {
            $d = $decisions[$m]
            if (-not $d) { continue }
            $w = if ($this.Weights.ContainsKey($m)) { $this.Weights[$m] } else { 0.05 }
            $a = if ($this.Accuracy.ContainsKey($m)) { $this.Accuracy[$m] } else { 0.5 }
            if ($m -eq "RAMMonitor" -and $ramSpike) {
                $w *= 1.5  # 50% wiecej wagi przy spike
            }
            $scores[$d] += $w * $a
            $voteCount[$d]++
        }
        # ZMIENIONA LOGIKA: Faworyzuj minimalny wystarczajacy tryb
        # Sprawdzamy od Silent do Turbo - pierwszy ktory ma dobre wyniki wygrywa
        $winner = "Balanced"
        $maxS = 0.0
        
        # BONUS dla Silent przy niskim RAM - efektywnosc energetyczna
        if ($ram -lt 60 -and -not $ramSpike) {
            $scores["Silent"] += 0.1
        }
        
        if ($ramSpike) {
            $scores["Turbo"] += 0.15
        }
        
        # Wybierz tryb z najwyzszym score
        # ALE: Silent nie wymaga tylu glosow co Turbo (efektywnosc)
        if ($scores["Silent"] -gt $scores["Balanced"] -and $scores["Silent"] -gt $scores["Turbo"] * 0.9 -and -not $ramSpike) {
            # Silent wygrywa jesli ma najwyzszy score LUB jest blisko Turbo (preferuj efektywnosc)
            $winner = "Silent"
            $maxS = $scores["Silent"]
        }
        elseif ($scores["Turbo"] -gt $scores["Balanced"] -and $voteCount["Turbo"] -ge 4) {
            # Turbo wymaga >= 4 glosow (zmniejszone z 5 ale wciaz wymaga konsensusu)
            $winner = "Turbo"
            $maxS = $scores["Turbo"]
        }
        else {
            # Balanced jako fallback
            $winner = "Balanced"
            $maxS = $scores["Balanced"]
        }
        
        $this.TotalVotes++
        return $winner
    }
    # Kompatybilnosc wsteczna - stara sygnatura bez RAM
    [string] Vote([hashtable]$decisions) {
        return $this.Vote($decisions, $this.LastRAM, $this.LastRAMSpike)
    }
    [void] UpdateAccuracy([string]$model, [bool]$correct) {
        if (-not $this.Accuracy.ContainsKey($model)) { return }
        if ($correct) { $this.Accuracy[$model] = [Math]::Min(0.95, $this.Accuracy[$model] * 1.02 + 0.01) }
        else { $this.Accuracy[$model] = [Math]::Max(0.3, $this.Accuracy[$model] * 0.98) }
    }
    [void] UpdateRAMAccuracy([bool]$ramWasHelpful) {
        if ($ramWasHelpful) {
            $this.Accuracy["RAMMonitor"] = [Math]::Min(0.95, $this.Accuracy["RAMMonitor"] * 1.03 + 0.02)
        } else {
            $this.Accuracy["RAMMonitor"] = [Math]::Max(0.4, $this.Accuracy["RAMMonitor"] * 0.97)
        }
    }
    [string] GetStatus() {
        $best = "Brain"; $bestA = 0
        foreach ($m in $this.Accuracy.Keys) { if ($this.Accuracy[$m] -gt $bestA) { $bestA = $this.Accuracy[$m]; $best = $m } }
        return "Best:$best($([Math]::Round($bestA * 100))%)"
    }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "EnsembleWeights.json"
            [System.IO.File]::WriteAllText($path, (@{ Weights = $this.Weights; Accuracy = $this.Accuracy; TotalVotes = $this.TotalVotes } | ConvertTo-Json -Depth 3 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "EnsembleWeights.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.Weights) { $data.Weights.PSObject.Properties | ForEach-Object { $this.Weights[$_.Name] = [double]$_.Value } }
                if ($data.Accuracy) { $data.Accuracy.PSObject.Properties | ForEach-Object { $this.Accuracy[$_.Name] = [double]$_.Value } }
                if ($data.TotalVotes) { $this.TotalVotes = $data.TotalVotes }
            }
        } catch { }
    }
}
#  MEGA AI: ENERGY TRACKER - Efficiency monitoring
class EnergyTracker {
    [double] $TotalScore
    [int] $Samples
    [double] $CurrentEfficiency
    [hashtable] $ModeStats
    EnergyTracker() {
        $this.TotalScore = 0; $this.Samples = 0; $this.CurrentEfficiency = 0.5
        $this.ModeStats = @{ "Turbo" = @{ S = 0; T = 0.0 }; "Balanced" = @{ S = 0; T = 0.0 }; "Silent" = @{ S = 0; T = 0.0 } }
    }
    [void] Record([string]$mode, [double]$cpu, [double]$temp, [bool]$active) {
        $eff = 0.5
        #  SYNC: uses variables z config.json
        switch ($mode) {
            "Turbo" { $eff = if ($cpu -gt $Script:TurboThreshold) { 0.9 } elseif ($cpu -gt 30) { 0.6 } else { 0.2 } }
            "Silent" { $eff = if ($cpu -lt $Script:ForceSilentCPU -and -not $active) { 0.95 } elseif ($cpu -lt 30) { 0.7 } else { 0.3 } }
            "Balanced" { $eff = if ($cpu -gt 20 -and $cpu -lt $Script:TurboThreshold) { 0.8 } else { 0.6 } }
        }
        if ($temp -gt 85) { $eff *= 0.7 } elseif ($temp -gt 75) { $eff *= 0.9 }
        $this.TotalScore += $eff; $this.Samples++
        $this.ModeStats[$mode].S++; $this.ModeStats[$mode].T += $eff
        $this.CurrentEfficiency = ($this.CurrentEfficiency * 0.9) + ($eff * 0.1)
    }
    [double] GetEfficiency() { if ($this.Samples -eq 0) { return 0.5 } else { return [Math]::Round($this.TotalScore / $this.Samples, 3) } }
    [string] GetStatus() { return "Eff:$([Math]::Round($this.CurrentEfficiency * 100))%" }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "EnergyStats.json"
            [System.IO.File]::WriteAllText($path, (@{ TotalScore = $this.TotalScore; Samples = $this.Samples; ModeStats = $this.ModeStats } | ConvertTo-Json -Depth 3 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "EnergyStats.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.TotalScore) { $this.TotalScore = $data.TotalScore }
                if ($data.Samples) { $this.Samples = $data.Samples }
            }
        } catch { }
    }
}
# Odpowiedzialnosci:
# 1. Dynamicznie dostosowuje progi spike detection na podstawie temperatury CPU
# 2. Zimny CPU (< 60°C) -> nizsze progi (agresywna detekcja, szybsza reakcja)
# 3. Goracy CPU (> 75°C) -> wyzsze progi (ostrozna detekcja, less boost)
# 4. Zapobiega przegrzaniu podczas intensywnego uzycia
class AdaptiveThresholdManager {
    # Bazowe progi (standardowe)
    [double] $BaseSpikeThreshold = 8.0
    [double] $BaseAccelThreshold = 3.0
    # Strefy temperatur (°C)
    [double] $TempCool = 60.0      # Ponizej = zimny CPU
    [double] $TempNormal = 75.0    # 60-75 = normalny
    [double] $TempWarm = 85.0      # 75-85 = cieply
    # Powyzej 85°C = goracy
    # Mnozniki progow dla kazdej strefy
    [hashtable] $ThresholdMultipliers = @{
        COOL = @{ Spike = 0.5; Accel = 0.67 }   # 50% nizej spike, 67% nizej accel
        NORMAL = @{ Spike = 1.0; Accel = 1.0 }  # Bazowe wartosci
        WARM = @{ Spike = 1.25; Accel = 1.33 }  # 25% wyzej spike, 33% wyzej accel
        HOT = @{ Spike = 1.875; Accel = 2.0 }   # 87.5% wyzej spike, 100% wyzej accel
    }
    # Statystyki
    [int] $TotalAdjustments = 0
    [string] $LastZone = "NORMAL"
    [datetime] $LastAdjustmentTime = [datetime]::MinValue
    AdaptiveThresholdManager() {
        # Konstruktor - inicjalizacja
    }
    # #
    # GLOWNA METODA - Oblicz adaptive thresholds
    # #
    [hashtable] GetAdaptiveThresholds([double]$currentTemp, [string]$currentMode) {
        # Okresl strefe temperatury
        $zone = $this.DetermineTemperatureZone($currentTemp)
        # Pobierz mnozniki dla strefy
        $multipliers = $this.ThresholdMultipliers[$zone]
        # Oblicz adaptive thresholds
        $adaptiveSpikeThreshold = $this.BaseSpikeThreshold * $multipliers.Spike
        $adaptiveAccelThreshold = $this.BaseAccelThreshold * $multipliers.Accel
        # Statystyki
        if ($zone -ne $this.LastZone) {
            $this.TotalAdjustments++
            $this.LastZone = $zone
            $this.LastAdjustmentTime = [datetime]::Now
        }
        # Okresl kolor i ikone dla UI
        $uiInfo = $this.GetUIInfo($zone)
        return @{
            SpikeThreshold = [Math]::Round($adaptiveSpikeThreshold, 1)
            AccelThreshold = [Math]::Round($adaptiveAccelThreshold, 1)
            Zone = $zone
            Temperature = [Math]::Round($currentTemp, 1)
            Reason = $uiInfo.Reason
            Icon = $uiInfo.Icon
            Color = $uiInfo.Color
            Multiplier = $multipliers.Spike
        }
    }
    # #
    # Okresl strefe temperatury
    # #
    [string] DetermineTemperatureZone([double]$temp) {
        if ($temp -lt $this.TempCool) {
            return "COOL"
        } elseif ($temp -lt $this.TempNormal) {
            return "NORMAL"
        } elseif ($temp -lt $this.TempWarm) {
            return "WARM"
        } else {
            return "HOT"
        }
        # Fallback (nigdy nie powinno sie wykonac)
        return "NORMAL"
    }
    # #
    # UI Info dla kazdej strefy
    # #
    [hashtable] GetUIInfo([string]$zone) {
        switch ($zone) {
            "COOL" {
                return @{
                    Reason = "Cool CPU - Aggressive detection enabled"
                    Icon = "?"
                    Color = "Cyan"
                }
            }
            "NORMAL" {
                return @{
                    Reason = "Normal CPU - Standard detection"
                    Icon = ""
                    Color = "Green"
                }
            }
            "WARM" {
                return @{
                    Reason = "Warm CPU - Conservative detection"
                    Icon = ""
                    Color = "Yellow"
                }
            }
            "HOT" {
                return @{
                    Reason = "Hot CPU - Critical-only detection"
                    Icon = ""
                    Color = "Red"
                }
            }
            default {
                return @{
                    Reason = "Unknown zone"
                    Icon = "?"
                    Color = "Gray"
                }
            }
        }
        # Fallback (nigdy nie powinno sie wykonac, ale PowerShell wymaga)
        return @{
            Reason = "Unknown zone"
            Icon = "?"
            Color = "Gray"
        }
    }
    # #
    # Statystyki do logowania
    # #
    [string] GetStats() {
        return "Adjustments: $($this.TotalAdjustments) | Current Zone: $($this.LastZone)"
    }
}
# Odpowiedzialnosci:
# 1. Monitoruje RAM i wykrywa nagle skoki (spike detection)
# 2. Adaptacyjne progi - dostosowuje sie do wzorcow uzytkownika
# 3. Wykrywa trendy (powolny ale ciagly wzrost)
# 4. Uczy sie aplikacji ktore potrzebuja boost'a -> PRE-BOOST
# 5. NATYCHMIASTOWA reakcja - nie czeka na AI
class RAMAnalyzer {
    # Aktualne dane
    [double] $CurrentRAM                # Aktualne uzycie RAM (%)
    [double] $PreviousRAM               # Poprzednia probka
    [double] $Delta                     # Roznica (CurrentRAM - PreviousRAM) - pierwsza pochodna
    [double] $Acceleration              # Zmiana delta (Delta[n] - Delta[n-1])
    [double] $PreviousDelta             # Poprzednia delta (do obliczenia acceleration)
    [System.Collections.Generic.List[double]] $AccelerationHistory  # Historia przyspieszen
    [double] $AccelerationThreshold     # Prog przyspieszenia (>3%)
    [string] $TrendType                 # "EXPONENTIAL", "LINEAR", "DECEL", "NONE"
    [int] $ExponentialStreak            # Ile probek z przyspieszeniem
    # Historia do analizy
    [System.Collections.Generic.List[double]] $RAMHistory        # Historia uzycia RAM
    [System.Collections.Generic.List[double]] $DeltaHistory      # Historia zmian (delt)
    [int] $HistorySize                  # Max rozmiar historii
    # Statystyki adaptacyjne
    [double] $AvgDelta                  # Srednia delta
    [double] $StdDevDelta               # Odchylenie standardowe delt
    [double] $SpikeThreshold            # Adaptacyjny prog spike'a
    [double] $MinSpikeThreshold         # Minimalny prog (nie nizszy niz)
    # Wykrywanie trendu
    [int] $ConsecutiveRises             # Ile probek z rzedu rosnie
    [double] $TrendSum                  # Suma wzrostow w trendzie
    [int] $TrendThresholdCount          # Po ilu probkach uznajemy trend
    [double] $TrendThresholdSum         # Jaka suma wzrostow = trend
    # Stan spike/boost
    [bool] $SpikeDetected               # Czy wykryto spike
    [bool] $TrendDetected               # Czy wykryto trend wzrostowy
    [string] $BoostReason               # Powod boost'a
    [datetime] $LastBoostTime           # Kiedy ostatni boost
    [int] $BoostCooldown                # Sekundy miedzy boost'ami (anty-spam)
    # Uczenie sie aplikacji
    [hashtable] $AppPatterns            # { "app.exe" = @{ BoostCount; TotalSeen; AvgSpike; NeedsBoost } }
    [string] $CurrentApp                # Aktualnie aktywna aplikacja
    [int] $LearningThreshold            # Po ilu obserwacjach "znamy" app
    # Statystyki
    [int] $TotalSpikesDetected
    [int] $TotalTrendsDetected
    [int] $TotalPreBoosts
    [AdaptiveThresholdManager] $ThresholdManager
    RAMAnalyzer() {
        $this.CurrentRAM = 0
        $this.PreviousRAM = 0
        $this.Delta = 0
        $this.Acceleration = 0
        $this.PreviousDelta = 0
        $this.AccelerationHistory = [System.Collections.Generic.List[double]]::new()
        $this.AccelerationThreshold = 3.0    # Przyspieszenie >3% = eksponencjalne
        $this.TrendType = "NONE"
        $this.ExponentialStreak = 0
        $this.RAMHistory = [System.Collections.Generic.List[double]]::new()
        $this.DeltaHistory = [System.Collections.Generic.List[double]]::new()
        $this.HistorySize = 30  # ~60 sekund historii przy 2s iteracji
        $this.AvgDelta = 0
        $this.StdDevDelta = 2.0  # Startowe odchylenie
        $this.SpikeThreshold = 5.0  # V38 FIX: Obnizony startowy prog z 8% do 5%
        $this.MinSpikeThreshold = 3.0  # V38 FIX: Obnizony minimalny prog z 5% do 3%
        $this.ConsecutiveRises = 0
        $this.TrendSum = 0
        $this.TrendThresholdCount = 4  # V38: 4 probki rosnace = trend (kompromis)
        $this.TrendThresholdSum = 8.0  # V38: Suma >8% = trend (kompromis)
        $this.SpikeDetected = $false
        $this.TrendDetected = $false
        $this.BoostReason = ""
        $this.LastBoostTime = [datetime]::MinValue
        $this.BoostCooldown = 10  # Min 10s miedzy boost'ami
        $this.AppPatterns = @{}
        $this.CurrentApp = ""
        $this.LearningThreshold = 5  # Po 5 obserwacjach znamy app
        $this.TotalSpikesDetected = 0
        $this.TotalTrendsDetected = 0
        $this.TotalPreBoosts = 0
        $this.ThresholdManager = [AdaptiveThresholdManager]::new()
    }
    # #
    # GLOWNA METODA: Aktualizuj i analizuj RAM
    # #
    [hashtable] Update([string]$activeApp, [double]$currentTemp, [string]$currentMode) {
        $this.CurrentApp = $activeApp
        $this.SpikeDetected = $false
        $this.TrendDetected = $false
        $this.BoostReason = ""
        $thresholdInfo = $this.ThresholdManager.GetAdaptiveThresholds($currentTemp, $currentMode)
        $this.SpikeThreshold = $thresholdInfo.SpikeThreshold
        $this.AccelerationThreshold = $thresholdInfo.AccelThreshold
        # 1. Odczytaj aktualne RAM z systemu
        $this.PreviousRAM = $this.CurrentRAM
        $this.CurrentRAM = $this.GetSystemRAM()
        # 2. Oblicz delte
        if ($this.PreviousRAM -gt 0) {
            $this.Delta = $this.CurrentRAM - $this.PreviousRAM
        } else {
            $this.Delta = 0
        }
        if ($this.PreviousDelta -ne 0 -or $this.Delta -ne 0) {
            $this.Acceleration = $this.Delta - $this.PreviousDelta
        } else {
            $this.Acceleration = 0
        }
        $this.PreviousDelta = $this.Delta  # Zapisz dla nastepnej iteracji
        # 2b. Dodaj do historii acceleration
        $this.AccelerationHistory.Add($this.Acceleration)
        if ($this.AccelerationHistory.Count -gt $this.HistorySize) {
            $this.AccelerationHistory.RemoveAt(0)
        }
        # 3. Aktualizuj historie
        $this.UpdateHistory()
        # 4. Przelicz statystyki adaptacyjne
        $this.UpdateAdaptiveStats()
        $this.DetectTrendType()
        # 5. Sprawdz PRE-BOOST (znana ciezka aplikacja)
        $preBoostNeeded = $this.CheckPreBoost($activeApp)
        if ($preBoostNeeded) {
            return @{
                RAM = [int]$this.CurrentRAM
                Delta = [Math]::Round($this.Delta, 1)
                Spike = $false
                Trend = $false
                PreBoost = $true
                BoostNeeded = "Turbo"
                Reason = " PRE-BOOST: $activeApp (learned)"
                Threshold = [Math]::Round($this.SpikeThreshold, 1)
                Acceleration = [Math]::Round($this.Acceleration, 1)
                TrendType = $this.TrendType
                ThresholdZone = $thresholdInfo.Zone
                ThresholdIcon = $thresholdInfo.Icon
                ThresholdReason = $thresholdInfo.Reason
            }
        }
        $earlySpikeResult = $this.CheckEarlySpike()
        if ($earlySpikeResult) {
            $this.RecordAppSpike($activeApp)
            $boostLevel = $this.GetBoostLevel()
            return @{
                RAM = [int]$this.CurrentRAM
                Delta = [Math]::Round($this.Delta, 1)
                Spike = $true
                Trend = $false
                PreBoost = $false
                BoostNeeded = $boostLevel  # TURBO lub EXTREME
                Reason = " EARLY SPIKE: Accel +$([Math]::Round($this.Acceleration, 1))% (Exponential)"
                Threshold = [Math]::Round($this.SpikeThreshold, 1)
                Acceleration = [Math]::Round($this.Acceleration, 1)
                TrendType = $this.TrendType
                ThresholdZone = $thresholdInfo.Zone
                ThresholdIcon = $thresholdInfo.Icon
                ThresholdReason = $thresholdInfo.Reason
            }
        }
        # 6. Sprawdz SPIKE (nagly skok)
        $spikeResult = $this.CheckSpike()
        if ($spikeResult) {
            $this.RecordAppSpike($activeApp)
            $boostLevel = $this.GetBoostLevel()  # v39: moze byc EXTREME
            return @{
                RAM = [int]$this.CurrentRAM
                Delta = [Math]::Round($this.Delta, 1)
                Spike = $true
                Trend = $false
                PreBoost = $false
                BoostNeeded = $boostLevel
                Reason = " SPIKE: +$([Math]::Round($this.Delta, 1))% (prog: $([Math]::Round($this.SpikeThreshold, 1))%)"
                Threshold = [Math]::Round($this.SpikeThreshold, 1)
                Acceleration = [Math]::Round($this.Acceleration, 1)
                TrendType = $this.TrendType
                ThresholdZone = $thresholdInfo.Zone
                ThresholdIcon = $thresholdInfo.Icon
                ThresholdReason = $thresholdInfo.Reason
            }
        }
        # 7. Sprawdz TREND (powolny wzrost)
        $trendResult = $this.CheckTrend()
        if ($trendResult) {
            $this.RecordAppSpike($activeApp)
            return @{
                RAM = [int]$this.CurrentRAM
                Delta = [Math]::Round($this.Delta, 1)
                Spike = $false
                Trend = $true
                PreBoost = $false
                BoostNeeded = "Balanced"  # Trend = lagodniejszy boost
                Reason = " TREND: +$([Math]::Round($this.TrendSum, 1))% w $($this.ConsecutiveRises) probkach"
                Threshold = [Math]::Round($this.SpikeThreshold, 1)
                Acceleration = [Math]::Round($this.Acceleration, 1)
                TrendType = $this.TrendType
                ThresholdZone = $thresholdInfo.Zone
                ThresholdIcon = $thresholdInfo.Icon
                ThresholdReason = $thresholdInfo.Reason
            }
        }
        # 8. Brak potrzeby boost'a
        return @{
            RAM = [int]$this.CurrentRAM
            Delta = [Math]::Round($this.Delta, 1)
            Spike = $false
            Trend = $false
            PreBoost = $false
            BoostNeeded = "None"
            Reason = ""
            Threshold = [Math]::Round($this.SpikeThreshold, 1)
            Acceleration = [Math]::Round($this.Acceleration, 1)
            TrendType = $this.TrendType
            ThresholdZone = $thresholdInfo.Zone
            ThresholdIcon = $thresholdInfo.Icon
            ThresholdReason = $thresholdInfo.Reason
        }
    }
    # #
    # ODCZYT RAM Z SYSTEMU
    # #
    [double] GetSystemRAM() {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -Property FreePhysicalMemory, TotalVisibleMemorySize
            $totalKB = $os.TotalVisibleMemorySize
            $freeKB = $os.FreePhysicalMemory
            $usedKB = $totalKB - $freeKB
            $usedPercent = ($usedKB / $totalKB) * 100
            return [Math]::Round($usedPercent, 1)
        } catch {
            return $this.CurrentRAM  # Zwroc poprzednia wartosc przy bledzie
        }
    }
    # #
    # AKTUALIZACJA HISTORII
    # #
    [void] UpdateHistory() {
        # Dodaj do historii RAM
        $this.RAMHistory.Add($this.CurrentRAM)
        if ($this.RAMHistory.Count -gt $this.HistorySize) {
            $this.RAMHistory.RemoveAt(0)
        }
        # Dodaj do historii delt (tylko jesli mamy poprzednia probke)
        if ($this.PreviousRAM -gt 0) {
            $this.DeltaHistory.Add($this.Delta)
            if ($this.DeltaHistory.Count -gt $this.HistorySize) {
                $this.DeltaHistory.RemoveAt(0)
            }
        }
    }
    # #
    # STATYSTYKI ADAPTACYJNE
    # #
    [void] UpdateAdaptiveStats() {
        if ($this.DeltaHistory.Count -lt 5) { return }  # Za malo danych
        # Oblicz srednia delte
        $sum = 0.0
        foreach ($d in $this.DeltaHistory) { $sum += [Math]::Abs($d) }
        $this.AvgDelta = $sum / $this.DeltaHistory.Count
        # Oblicz odchylenie standardowe
        $sumSq = 0.0
        foreach ($d in $this.DeltaHistory) {
            $diff = [Math]::Abs($d) - $this.AvgDelta
            $sumSq += ($diff * $diff)
        }
        $this.StdDevDelta = [Math]::Sqrt($sumSq / $this.DeltaHistory.Count)
        # Oblicz adaptacyjny prog spike'a
        # Prog = srednia + (2 x odchylenie), minimum MinSpikeThreshold
        $calculatedThreshold = $this.AvgDelta + (2.0 * $this.StdDevDelta)
        $this.SpikeThreshold = [Math]::Max($this.MinSpikeThreshold, $calculatedThreshold)
    }
    # #
    # WYKRYWANIE SPIKE'A
    # #
    [bool] CheckSpike() {
        # Czy delta przekracza prog?
        if ($this.Delta -gt $this.SpikeThreshold) {
            # Sprawdz cooldown (anty-spam)
            $timeSinceLastBoost = ([datetime]::Now - $this.LastBoostTime).TotalSeconds
            if ($timeSinceLastBoost -lt $this.BoostCooldown) {
                return $false
            }
            $this.SpikeDetected = $true
            $this.TotalSpikesDetected++
            $this.LastBoostTime = [datetime]::Now
            $this.BoostReason = "SPIKE +$([Math]::Round($this.Delta, 1))%"
            # Reset trendu (spike ma priorytet)
            $this.ConsecutiveRises = 0
            $this.TrendSum = 0
            return $true
        }
        return $false
    }
    # #
    # WYKRYWANIE TRENDU
    # #
    [bool] CheckTrend() {
        # Czy RAM rosnie? V38: Obnizono prog z 0.5% do 0.3%
        if ($this.Delta -gt 0.3) {  # Minimalny wzrost 0.3%
            $this.ConsecutiveRises++
            $this.TrendSum += $this.Delta
        } else {
            # Reset jesli nie rosnie
            $this.ConsecutiveRises = 0
            $this.TrendSum = 0
            return $false
        }
        # Czy mamy trend?
        if ($this.ConsecutiveRises -ge $this.TrendThresholdCount -and $this.TrendSum -ge $this.TrendThresholdSum) {
            # Sprawdz cooldown
            $timeSinceLastBoost = ([datetime]::Now - $this.LastBoostTime).TotalSeconds
            if ($timeSinceLastBoost -lt $this.BoostCooldown) {
                return $false
            }
            $this.TrendDetected = $true
            $this.TotalTrendsDetected++
            $this.LastBoostTime = [datetime]::Now
            $this.BoostReason = "TREND +$([Math]::Round($this.TrendSum, 1))%"
            # Reset po wykryciu
            $this.ConsecutiveRises = 0
            $this.TrendSum = 0
            return $true
        }
        return $false
    }
    # #
    # UCZENIE SIE APLIKACJI
    # #
    [void] RecordAppSpike([string]$app) {
        if ([string]::IsNullOrWhiteSpace($app)) { return }
        # Wyciagnij nazwe exe (bez sciezki)
        $appName = [System.IO.Path]::GetFileName($app)
        if ([string]::IsNullOrWhiteSpace($appName)) { $appName = $app }
        if (-not $this.AppPatterns.ContainsKey($appName)) {
            $this.AppPatterns[$appName] = @{
                BoostCount = 0
                TotalSeen = 0
                TotalSpike = 0.0
                AvgSpike = 0.0
                NeedsBoost = $false
            }
        }
        $pattern = $this.AppPatterns[$appName]
        $pattern.BoostCount++
        $pattern.TotalSeen++
        $pattern.TotalSpike += [Math]::Abs($this.Delta)
        $pattern.AvgSpike = $pattern.TotalSpike / $pattern.BoostCount
        # Czy app "potrzebuje boost'a"?
        # Jesli >60% obserwacji to spike/trend -> NeedsBoost = true
        if ($pattern.TotalSeen -ge $this.LearningThreshold) {
            $boostRatio = $pattern.BoostCount / $pattern.TotalSeen
            $pattern.NeedsBoost = ($boostRatio -gt 0.6)
        }
    }
    [void] RecordAppNormal([string]$app) {
        if ([string]::IsNullOrWhiteSpace($app)) { return }
        $appName = [System.IO.Path]::GetFileName($app)
        if ([string]::IsNullOrWhiteSpace($appName)) { $appName = $app }
        if ($this.AppPatterns.ContainsKey($appName)) {
            $this.AppPatterns[$appName].TotalSeen++
            # Przelicz czy nadal NeedsBoost
            $pattern = $this.AppPatterns[$appName]
            if ($pattern.TotalSeen -ge $this.LearningThreshold) {
                $boostRatio = $pattern.BoostCount / $pattern.TotalSeen
                $pattern.NeedsBoost = ($boostRatio -gt 0.6)
            }
        }
    }
    # #
    # PRE-BOOST (dla nauczonych aplikacji)
    # #
    [bool] CheckPreBoost([string]$app) {
        if ([string]::IsNullOrWhiteSpace($app)) { return $false }
        $appName = [System.IO.Path]::GetFileName($app)
        if ([string]::IsNullOrWhiteSpace($appName)) { return $false }
        if ($this.AppPatterns.ContainsKey($appName)) {
            $pattern = $this.AppPatterns[$appName]
            # Czy app wymaga pre-boost I czy RAM jeszcze nie skoczyl znaczaco?
            if ($pattern.NeedsBoost -and $this.Delta -lt 3) {
                # Sprawdz cooldown
                $timeSinceLastBoost = ([datetime]::Now - $this.LastBoostTime).TotalSeconds
                if ($timeSinceLastBoost -lt $this.BoostCooldown * 2) {  # Dluzszy cooldown dla pre-boost
                    return $false
                }
                $this.TotalPreBoosts++
                $this.LastBoostTime = [datetime]::Now
                return $true
            }
        }
        return $false
    }
    # #
    # POMOCNICZE
    # #
    [string] GetStatus() {
        return "RAM:$([int]$this.CurrentRAM)% D:$([Math]::Round($this.Delta,1)) T:$([Math]::Round($this.SpikeThreshold,1)) Spk:$($this.TotalSpikesDetected)"
    }
    [int] GetLearnedAppsCount() {
        return $this.AppPatterns.Count
    }
    [int] GetAppsNeedingBoostCount() {
        $count = 0
        foreach ($app in $this.AppPatterns.Keys) {
            if ($this.AppPatterns[$app].NeedsBoost) { $count++ }
        }
        return $count
    }
    [string[]] GetLearnedApps() {
        $apps = @()
        foreach ($app in $this.AppPatterns.Keys) {
            if ($this.AppPatterns[$app].NeedsBoost) {
                $apps += $app
            }
        }
        return $apps
    }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "RAMAnalyzer.json"
            $data = @{
                AppPatterns = $this.AppPatterns
                TotalSpikesDetected = $this.TotalSpikesDetected
                TotalTrendsDetected = $this.TotalTrendsDetected
                TotalPreBoosts = $this.TotalPreBoosts
                AvgDelta = $this.AvgDelta
                StdDevDelta = $this.StdDevDelta
            }
            [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 4 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "RAMAnalyzer.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.TotalSpikesDetected) { $this.TotalSpikesDetected = $data.TotalSpikesDetected }
                if ($data.TotalTrendsDetected) { $this.TotalTrendsDetected = $data.TotalTrendsDetected }
                if ($data.TotalPreBoosts) { $this.TotalPreBoosts = $data.TotalPreBoosts }
                if ($data.AvgDelta) { $this.AvgDelta = $data.AvgDelta }
                if ($data.StdDevDelta) { $this.StdDevDelta = $data.StdDevDelta }
                # Odtworz AppPatterns
                if ($data.AppPatterns) {
                    $data.AppPatterns.PSObject.Properties | ForEach-Object {
                        $this.AppPatterns[$_.Name] = @{
                            BoostCount = $_.Value.BoostCount
                            TotalSeen = $_.Value.TotalSeen
                            TotalSpike = $_.Value.TotalSpike
                            AvgSpike = $_.Value.AvgSpike
                            NeedsBoost = $_.Value.NeedsBoost
                        }
                    }
                }
            }
        } catch { }
    }
    # #
    # #
    [void] DetectTrendType() {
        if ($this.AccelerationHistory.Count -lt 3) {
            $this.TrendType = "NONE"
            return
        }
        # Wez ostatnie 3 wartosci acceleration
        $recentCount = [Math]::Min(3, $this.AccelerationHistory.Count)
        $recent = $this.AccelerationHistory.GetRange(
            $this.AccelerationHistory.Count - $recentCount, 
            $recentCount
        )
        # Oblicz srednia acceleration
        $avgAccel = 0.0
        foreach ($a in $recent) { $avgAccel += $a }
        $avgAccel = $avgAccel / $recent.Count
        # KLASYFIKACJA TRENDU:
        if ($avgAccel -gt $this.AccelerationThreshold) {
            # Przyspieszenie rosnie -> EKSPONENCJALNY
            $this.TrendType = "EXPONENTIAL"
            $this.ExponentialStreak++
        } elseif ($avgAccel -lt -2.0) {
            # Przyspieszenie maleje -> DECELERATION (stabilizacja)
            $this.TrendType = "DECEL"
            $this.ExponentialStreak = 0
        } elseif ($this.Delta -gt 1.0 -and [Math]::Abs($avgAccel) -lt 1.0) {
            # Delta dodatnia, ale przyspieszenie ~0 -> LINIOWY
            $this.TrendType = "LINEAR"
            $this.ExponentialStreak = 0
        } else {
            $this.TrendType = "NONE"
            $this.ExponentialStreak = 0
        }
    }
    # #
    # #
    [bool] CheckEarlySpike() {
        # NOWY: Wykryj spike WCZESNIEJ przy wysokim acceleration
        if ($this.Acceleration -gt $this.AccelerationThreshold -and 
            $this.ExponentialStreak -ge 2) {
            # Sprawdz cooldown
            $timeSinceLastBoost = ([datetime]::Now - $this.LastBoostTime).TotalSeconds
            if ($timeSinceLastBoost -lt $this.BoostCooldown) {
                return $false
            }
            $this.SpikeDetected = $true
            $this.LastBoostTime = [datetime]::Now
            $this.BoostReason = "EARLY SPIKE (Accel: +$([Math]::Round($this.Acceleration, 1))%)"
            return $true
        }
        return $false
    }
    # #
    # #
    [string] GetBoostLevel() {
        switch ($this.TrendType) {
            "EXPONENTIAL" {
                # Bardzo szybkie przyspieszenie -> EXTREME
                if ($this.Acceleration -gt 5.0) {
                    return "EXTREME"
                } else {
                    return "TURBO"
                }
            }
            "LINEAR" {
                # Staly wzrost -> BALANCED
                return "BALANCED"
            }
            "DECEL" {
                # Zwalnianie -> lagodny lub brak
                if ($this.Delta -gt 5.0) {
                    return "BALANCED"
                } else {
                    return "NONE"
                }
            }
            default {
                # Brak trendu
                if ($this.Delta -gt $this.SpikeThreshold) {
                    return "TURBO"
                } else {
                    return "NONE"
                }
            }
        }
        # Fallback (nigdy nie powinno sie tu dotrzec)
        return "NONE"
    }
}
#  AI COORDINATOR - Lightweight Engine Manager & Knowledge Transfer
# Odpowiedzialnosci:
# 1. Decyduje ktory silnik AI powinien byc aktywny (na podstawie obciazenia)
# 2. Zarzadza transferem wiedzy miedzy silnikami
# 3. QLearning zawsze dziala w tle jako "kregoslup"
# 4. Wydaje INTENCJE - nie manipuluje CPU bezposrednio
class AICoordinator {
    # Stan koordynatora
    [string] $ActiveEngine              # Aktualnie uzywany silnik decyzyjny
    [string] $PreviousEngine            # Poprzedni silnik (do logowania zmian)
    [bool] $NeuralBrainEnabled          # Czy NeuralBrain wlaczony przez uzytkownika
    [bool] $EnsembleEnabled             # Czy Ensemble wlaczony przez uzytkownika
    # Metryki obciazenia
    [double] $CurrentCPU                # Aktualne obciazenie CPU
    [double] $CurrentTemp               # Aktualna temperatura
    [double] $AvgCPU                    # Srednie CPU (rolling)
    [int] $HighLoadCount                # Ile razy z rzedu wysokie obciazenie
    [int] $LowLoadCount                 # Ile razy z rzedu niskie obciazenie
    # Transfer wiedzy
    [datetime] $LastTransferTime        # Kiedy ostatni transfer
    [int] $TransferCount                # Ile transferow wykonano
    [int] $MinTransferInterval          # Minimalny czas miedzy transferami (sekundy)
    [int] $QLearningUpdatesThreshold    # Po ilu updatech QLearning transferowac
    # Statystyki
    [hashtable] $EngineUsageTime        # Ile czasu kazdy silnik byl aktywny
    [hashtable] $EngineDecisionCount    # Ile decyzji podjal kazdy silnik
    [System.Collections.Generic.List[string]] $ActivityLog  # Log aktywnosci
    # v43.14: Adaptive weights
    [hashtable] $AdaptiveWeights        # Per-engine accuracy multiplier (0.5-1.5)
    [hashtable] $LastModelScores        # Scores z poprzedniej iteracji (do nagradzania)
    [string] $LastDecidedMode           # Tryb wybrany w poprzedniej iteracji
    AICoordinator() {
        $this.ActiveEngine = "QLearning"
        $this.PreviousEngine = "QLearning"
        # Beda synchronizowane ze skryptem przez SetNeuralBrainEnabled/SetEnsembleEnabled
        $this.NeuralBrainEnabled = $false
        $this.EnsembleEnabled = $false
        $this.CurrentCPU = 0
        $this.CurrentTemp = 0
        $this.AvgCPU = 30
        $this.HighLoadCount = 0
        $this.LowLoadCount = 0
        $this.LastTransferTime = [datetime]::Now
        $this.TransferCount = 0
        $this.MinTransferInterval = 300  # 5 minut minimum miedzy transferami
        $this.QLearningUpdatesThreshold = 50  # Transfer po 50 updatech QLearning
        $this.EngineUsageTime = @{
            "QLearning" = 0
            "NeuralBrain" = 0
            "Ensemble" = 0
            "Hybrid" = 0  # QLearning + NeuralBrain
        }
        $this.EngineDecisionCount = @{
            "QLearning" = 0
            "NeuralBrain" = 0
            "Ensemble" = 0
            "Hybrid" = 0
        }
        $this.ActivityLog = [System.Collections.Generic.List[string]]::new()
    }
    # #
    # GLOWNA METODA: Wybierz optymalny silnik na podstawie warunkow
    # #
    [string] DecideActiveEngine([double]$cpu, [double]$temp, [string]$context, [int]$qLearningUpdates) {
        $this.CurrentCPU = $cpu
        $this.CurrentTemp = $temp
        # Rolling average CPU (wygladzanie)
        $this.AvgCPU = ($this.AvgCPU * 0.8) + ($cpu * 0.2)
        # Zliczaj okresy wysokiego/niskiego obciazenia
        if ($cpu -gt 70) {
            $this.HighLoadCount++
            $this.LowLoadCount = 0
        } elseif ($cpu -lt 25) {
            $this.LowLoadCount++
            $this.HighLoadCount = 0
        } else {
            # Srednie obciazenie - powolny reset
            $this.HighLoadCount = [Math]::Max(0, $this.HighLoadCount - 1)
            $this.LowLoadCount = [Math]::Max(0, $this.LowLoadCount - 1)
        }
        $newEngine = $this.ActiveEngine
        $reason = ""
        # ??- LOGIKA WYBORU SILNIKA ???
        # PRIORYTET 1: Bardzo wysokie obciazenie (>85%) lub temperatura (>90°C)
        # -> Tylko QLearning (najlzejszy)
        if ($cpu -gt 85 -or $temp -gt 90 -or $this.HighLoadCount -gt 10) {
            $newEngine = "QLearning"
            $reason = "Critical load (CPU:$([int]$cpu)% Temp:$([int]$temp)C) - lightweight mode"
        }
        # PRIORYTET 2: Wysokie obciazenie (>70%) przez dluzszy czas
        # -> QLearning + NeuralBrain (bez Ensemble - najciezszy)
        elseif ($cpu -gt 70 -or $this.HighLoadCount -gt 5) {
            if ($this.NeuralBrainEnabled) {
                $newEngine = "Hybrid"  # QLearning + NeuralBrain
                $reason = "High load ($([int]$cpu)%) - Hybrid mode (no Ensemble)"
            } else {
                $newEngine = "QLearning"
                $reason = "High load ($([int]$cpu)%) - QLearning only"
            }
        }
        # PRIORYTET 3: Srednie obciazenie (25-70%)
        # -> Pelna moc AI jesli wlaczone
        elseif ($cpu -ge 25 -and $cpu -le 70) {
            if ($this.EnsembleEnabled) {
                $newEngine = "Ensemble"
                $reason = "Normal load ($([int]$cpu)%) - Ensemble voting"
            } elseif ($this.NeuralBrainEnabled) {
                $newEngine = "NeuralBrain"
                $reason = "Normal load ($([int]$cpu)%) - NeuralBrain active"
            } else {
                $newEngine = "QLearning"
                $reason = "Normal load ($([int]$cpu)%) - QLearning (others disabled)"
            }
        }
        # PRIORYTET 4: Niskie obciazenie (<25%)
        # -> Mozna uzyc pelnej mocy AI (system ma zasoby)
        else {
            if ($this.EnsembleEnabled) {
                $newEngine = "Ensemble"
                $reason = "Low load ($([int]$cpu)%) - Ensemble voting available"
            } elseif ($this.NeuralBrainEnabled) {
                $newEngine = "NeuralBrain"
                $reason = "Low load ($([int]$cpu)%) - NeuralBrain active"
            } else {
                $newEngine = "QLearning"
                $reason = "Low load ($([int]$cpu)%) - QLearning only"
            }
        }
        # Specjalny kontekst: Gaming/Rendering -> preferuj szybsze decyzje
        if ($context -eq "Gaming" -or $context -eq "Rendering") {
            if ($newEngine -eq "Ensemble" -and $cpu -gt 50) {
                $newEngine = "Hybrid"
                $reason = "$context context - faster decisions (Hybrid)"
            }
        }
        # Loguj zmiane silnika
        if ($newEngine -ne $this.ActiveEngine) {
            $this.LogActivity(" Engine switch: $($this.ActiveEngine) -> $newEngine | $reason")
            $this.PreviousEngine = $this.ActiveEngine
        }
        # Aktualizuj statystyki
        $this.ActiveEngine = $newEngine
        $this.EngineDecisionCount[$newEngine]++
        return $newEngine
    }
    # #
    # TRANSFER WIEDZY: QLearning -> NeuralBrain/Ensemble
    # #
    [bool] ShouldTransferKnowledge([int]$qLearningUpdates) {
        # Warunki transferu:
        # 1. Minal minimalny czas od ostatniego transferu
        # 2. QLearning zebral wystarczajaco duzo nowych danych
        # 3. System nie jest przeciazony
        $timeSinceLastTransfer = ([datetime]::Now - $this.LastTransferTime).TotalSeconds
        if ($timeSinceLastTransfer -lt $this.MinTransferInterval) {
            return $false
        }
        if ($qLearningUpdates -lt $this.QLearningUpdatesThreshold) {
            return $false
        }
        #  SYNC: uses variables z config.json
        if ($this.CurrentCPU -gt $Script:TurboThreshold) {
            return $false  # Nie transferuj przy wysokim obciazeniu
        }
        return $true
    }
    [hashtable] TransferFromQLearning($qLearning) {
        # Wyciagnij najistotniejsze dane z QLearning
        $transferData = @{
            # Preferencje trybow dla roznych stanow CPU
            ModePreferences = @{
                "HighCPU" = "Turbo"      # Default
                "MediumCPU" = "Balanced"
                "LowCPU" = "Silent"
            }
            # Skutecznosc trybow (z Q-values)
            ModeEffectiveness = @{
                "Turbo" = 0.5
                "Balanced" = 0.5
                "Silent" = 0.5
            }
            # Konteksty nauczone
            ContextPatterns = @{}
            # Timestamp
            TransferTime = [datetime]::Now
            UpdateCount = 0
        }
        if ($null -eq $qLearning -or $null -eq $qLearning.QTable) {
            return $transferData
        }
        $transferData.UpdateCount = $qLearning.TotalUpdates
        # Analizuj Q-Table aby wyciagnac preferencje
        $turboSum = 0.0; $balancedSum = 0.0; $silentSum = 0.0
        $turboCount = 0; $balancedCount = 0; $silentCount = 0
        foreach ($state in $qLearning.QTable.Keys) {
            $qValues = $qLearning.QTable[$state]
            if ($null -eq $qValues) { continue }
            # Sumuj Q-values dla kazdego trybu
            if ($qValues.ContainsKey("Turbo")) { $turboSum += $qValues["Turbo"]; $turboCount++ }
            if ($qValues.ContainsKey("Balanced")) { $balancedSum += $qValues["Balanced"]; $balancedCount++ }
            if ($qValues.ContainsKey("Silent")) { $silentSum += $qValues["Silent"]; $silentCount++ }
            # Wyciagnij kontekst ze stanu (format: C0-T0-A0-X0)
            if ($state -match "C(\d)-.*-X(\d)") {
                $cpuBin = [int]$matches[1]
                $ctxBin = [int]$matches[2]
                # Znajdz najlepszy tryb dla tego stanu
                $bestMode = "Balanced"
                $bestQ = $qValues["Balanced"]
                if ($qValues["Turbo"] -gt $bestQ) { $bestMode = "Turbo"; $bestQ = $qValues["Turbo"] }
                if ($qValues["Silent"] -gt $bestQ) { $bestMode = "Silent" }
                # Zapisz wzorzec kontekstowy
                $ctxName = switch ($ctxBin) { 0 { "Idle" } 1 { "Work" } 2 { "Heavy" } default { "Unknown" } }
                $cpuRange = switch ($cpuBin) { 0 { "0-20%" } 1 { "20-40%" } 2 { "40-60%" } 3 { "60-80%" } 4 { "80-100%" } default { "?" } }
                $key = "$ctxName-$cpuRange"
                $transferData.ContextPatterns[$key] = $bestMode
            }
        }
        # Oblicz srednia skutecznosc trybow (znormalizowana 0-1)
        if ($turboCount -gt 0) { 
            $avg = $turboSum / $turboCount
            $transferData.ModeEffectiveness["Turbo"] = [Math]::Max(0, [Math]::Min(1, ($avg + 5) / 10))
        }
        if ($balancedCount -gt 0) { 
            $avg = $balancedSum / $balancedCount
            $transferData.ModeEffectiveness["Balanced"] = [Math]::Max(0, [Math]::Min(1, ($avg + 5) / 10))
        }
        if ($silentCount -gt 0) { 
            $avg = $silentSum / $silentCount
            $transferData.ModeEffectiveness["Silent"] = [Math]::Max(0, [Math]::Min(1, ($avg + 5) / 10))
        }
        # Ustal preferencje na podstawie danych
        $best = $transferData.ModeEffectiveness.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
        $transferData.ModePreferences["Default"] = $best.Key
        $this.LastTransferTime = [datetime]::Now
        $this.TransferCount++
        $this.LogActivity(" Knowledge transfer #$($this.TransferCount): QLearning -> AI ($($transferData.ContextPatterns.Count) patterns)")
        return $transferData
    }
    # Aplikuj wiedze do NeuralBrain
    [void] ApplyToNeuralBrain($brain, [hashtable]$transferData) {
        if ($null -eq $brain -or $null -eq $transferData) { return }
        try {
            # Dostosuj wagi NeuralBrain na podstawie skutecznosci trybow
            foreach ($mode in $transferData.ModeEffectiveness.Keys) {
                $effectiveness = $transferData.ModeEffectiveness[$mode]
                # Delikatna korekta wag (nie nadpisuj calkowicie)
                if ($brain.Weights.ContainsKey($mode)) {
                    $currentWeight = $brain.Weights[$mode]
                    $brain.Weights[$mode] = ($currentWeight * 0.7) + ($effectiveness * 100 * 0.3)
                }
            }
            $this.LogActivity(" NeuralBrain updated with QLearning knowledge")
        } catch {
            $this.LogActivity("[WARN] Failed to apply knowledge to NeuralBrain")
        }
    }
    # Aplikuj wiedze do Ensemble
    [void] ApplyToEnsemble($ensemble, [hashtable]$transferData) {
        if ($null -eq $ensemble -or $null -eq $transferData) { return }
        try {
            # Dostosuj accuracy modeli na podstawie skutecznosci
            foreach ($mode in $transferData.ModeEffectiveness.Keys) {
                $effectiveness = $transferData.ModeEffectiveness[$mode]
                # Ensemble accuracy to jak dobrze model przewiduje
                # QLearning pokazuje ktore tryby dzialaja najlepiej
                if ($ensemble.Accuracy.ContainsKey("QLearning")) {
                    $ensemble.Accuracy["QLearning"] = [Math]::Max($ensemble.Accuracy["QLearning"], $effectiveness)
                }
            }
            # Zwieksz wage QLearning w Ensemble jesli zbiera dobre dane
            if ($ensemble.Weights.ContainsKey("QLearning")) {
                $avgEffectiveness = ($transferData.ModeEffectiveness.Values | Measure-Object -Average).Average
                if ($avgEffectiveness -gt 0.6) {
                    $ensemble.Weights["QLearning"] = [Math]::Min(1.5, $ensemble.Weights["QLearning"] + 0.1)
                }
            }
            $this.LogActivity(" Ensemble updated with QLearning accuracy data")
        } catch {
            $this.LogActivity("[WARN] Failed to apply knowledge to Ensemble")
        }
    }
    # #
    # ZARZADZANIE STANEM SILNIKOW (wlaczanie/wylaczanie przez uzytkownika)
    # #
    [void] SetNeuralBrainEnabled([bool]$enabled) {
        if ($this.NeuralBrainEnabled -ne $enabled) {
            $this.NeuralBrainEnabled = $enabled
            $status = if ($enabled) { "ENABLED" } else { "DISABLED" }
            $this.LogActivity(" NeuralBrain $status by user")
            # Jesli wylaczono, przelacz na QLearning
            if (-not $enabled -and $this.ActiveEngine -eq "NeuralBrain") {
                $this.ActiveEngine = "QLearning"
                $this.LogActivity(" Switched to QLearning (NeuralBrain disabled)")
            }
        }
    }
    [void] SetEnsembleEnabled([bool]$enabled) {
        if ($this.EnsembleEnabled -ne $enabled) {
            $this.EnsembleEnabled = $enabled
            $status = if ($enabled) { "ENABLED" } else { "DISABLED" }
            $this.LogActivity(" Ensemble $status by user")
            # Jesli wylaczono, przelacz na nizszy poziom
            if (-not $enabled -and $this.ActiveEngine -eq "Ensemble") {
                if ($this.NeuralBrainEnabled) {
                    $this.ActiveEngine = "NeuralBrain"
                } else {
                    $this.ActiveEngine = "QLearning"
                }
                $this.LogActivity(" Switched to $($this.ActiveEngine) (Ensemble disabled)")
            }
        }
    }
    # #
    # POMOCNICZE
    # #
    [void] LogActivity([string]$message) {
        $timestamp = (Get-Date).ToString("HH:mm:ss")
        $logEntry = "[$timestamp] $message"
        # Dodaj do wewnetrznego logu (max 50 wpisow)
        $this.ActivityLog.Add($logEntry)
        if ($this.ActivityLog.Count -gt 50) {
            $this.ActivityLog.RemoveAt(0)
        }
    }
    [string] GetStatus() {
        $brainStatus = if ($this.NeuralBrainEnabled) { "ON" } else { "OFF" }
        $ensembleStatus = if ($this.EnsembleEnabled) { "ON" } else { "OFF" }
        return "Engine:$($this.ActiveEngine) | Brain:$brainStatus Ensemble:$ensembleStatus | Transfers:$($this.TransferCount)"
    }
    [string] GetActiveEngineName() {
        return $this.ActiveEngine
    }
    [hashtable] GetEngineStats() {
        return @{
            ActiveEngine = $this.ActiveEngine
            NeuralBrainEnabled = $this.NeuralBrainEnabled
            EnsembleEnabled = $this.EnsembleEnabled
            TransferCount = $this.TransferCount
            AvgCPU = [Math]::Round($this.AvgCPU, 1)
            HighLoadCount = $this.HighLoadCount
            DecisionCounts = $this.EngineDecisionCount
        }
    }
    # #
    # NOWE V37.7.5: SAVE TRANSFER STATE - Zawsze zapisuj transfer
    # #
    [void] SaveTransferState([hashtable]$transferData, [string]$dir) {
        <#
        Zapisuje dane transferu do JSON ZAWSZE, niezaleznie czy Advanced engines ON
        Gdy sie wlacza - czytaja ze stanu i maja dostep do wszystkich danych
        #>
        try {
            if (-not $transferData) { return }
            # Zapisz ostatni transfer do cache
            $cacheFile = Join-Path $dir "TransferCache.json"
            $cacheData = @{
                Timestamp = (Get-Date).ToString("o")
                ModePreferences = $transferData.ModePreferences
                ModeEffectiveness = $transferData.ModeEffectiveness
                ContextPatterns = $transferData.ContextPatterns
                AppPatterns = $transferData.AppPatterns
            }
            [System.IO.File]::WriteAllText($cacheFile, ($cacheData | ConvertTo-Json -Depth 3 -Compress), [System.Text.Encoding]::UTF8)
            # Zaktualizuj EnsembleWeights.json niezaleznie od statusu
            $ensemblePath = Join-Path $dir "EnsembleWeights.json"
            if (Test-Path $ensemblePath) {
                try {
                    $existingEnsemble = [System.IO.File]::ReadAllText($ensemblePath) | ConvertFrom-Json
                    # Zaktualizuj accuracy na podstawie transferu
                    foreach ($mode in $transferData.ModeEffectiveness.Keys) {
                        $effectiveness = $transferData.ModeEffectiveness[$mode]
                        if (-not $existingEnsemble.Accuracy) { $existingEnsemble | Add-Member -Name Accuracy -Value @{} -MemberType NoteProperty }
                        $existingEnsemble.Accuracy[$mode] = [Math]::Max($existingEnsemble.Accuracy[$mode], $effectiveness)
                    }
                    [System.IO.File]::WriteAllText($ensemblePath, ($existingEnsemble | ConvertTo-Json -Depth 3 -Compress), [System.Text.Encoding]::UTF8)
                } catch { }
            }
            # Zaktualizuj BrainState.json niezaleznie od statusu
            $brainPath = Join-Path $dir "BrainState.json"
            if (Test-Path $brainPath) {
                try {
                    $existingBrain = [System.IO.File]::ReadAllText($brainPath) | ConvertFrom-Json
                    # Zaktualizuj weights na podstawie transferu
                    if (-not $existingBrain.Weights) { $existingBrain | Add-Member -Name Weights -Value @{} -MemberType NoteProperty }
                    foreach ($mode in $transferData.ModeEffectiveness.Keys) {
                        $effectiveness = $transferData.ModeEffectiveness[$mode]
                        $existingBrain.Weights[$mode] = ($existingBrain.Weights[$mode] * 0.7) + ($effectiveness * 100 * 0.3)
                    }
                    [System.IO.File]::WriteAllText($brainPath, ($existingBrain | ConvertTo-Json -Depth 3 -Compress), [System.Text.Encoding]::UTF8)
                } catch { }
            }
            $this.LogActivity(" Transfer state saved (cache + Ensemble + Brain)")
        } catch { }
    }
    # #
    # LOAD TRANSFER CACHE - Laduj ostatni transfer dla nowych engines
    # #
    [hashtable] LoadTransferCache([string]$dir) {
        <#
        Laduje ostatni transfer z cache - uzywane gdy Advanced engine sie wlacza
        #>
        try {
            $cacheFile = Join-Path $dir "TransferCache.json"
            if (Test-Path $cacheFile) {
                $data = [System.IO.File]::ReadAllText($cacheFile) | ConvertFrom-Json
                return @{
                    ModePreferences = $data.ModePreferences
                    ModeEffectiveness = $data.ModeEffectiveness
                    ContextPatterns = $data.ContextPatterns
                    AppPatterns = $data.AppPatterns
                }
            }
        } catch { }
        return @{ ModePreferences = @{}; ModeEffectiveness = @{} }
    }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "AICoordinator.json"
            $data = @{
                ActiveEngine = $this.ActiveEngine
                TransferCount = $this.TransferCount
                EngineDecisionCount = $this.EngineDecisionCount
                NeuralBrainEnabled = $this.NeuralBrainEnabled
                EnsembleEnabled = $this.EnsembleEnabled
                LastTransferTime = $this.LastTransferTime.ToString("o")
                AvgCPU = [Math]::Round($this.AvgCPU, 1)
            }
            [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 3 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "AICoordinator.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.ActiveEngine) { $this.ActiveEngine = $data.ActiveEngine }
                if ($data.TransferCount) { $this.TransferCount = $data.TransferCount }
                if ($data.NeuralBrainEnabled -ne $null) { $this.NeuralBrainEnabled = $data.NeuralBrainEnabled }
                if ($data.EnsembleEnabled -ne $null) { $this.EnsembleEnabled = $data.EnsembleEnabled }
                if ($data.AvgCPU) { $this.AvgCPU = $data.AvgCPU }
                if ($data.LastTransferTime) { 
                    try { $this.LastTransferTime = [datetime]::Parse($data.LastTransferTime, [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
                }
                if ($data.EngineDecisionCount) {
                    $data.EngineDecisionCount.PSObject.Properties | ForEach-Object {
                        $this.EngineDecisionCount[$_.Name] = [int]$_.Value
                    }
                }
            }
        } catch { }
    }
    # ═══════════════════════════════════════════════════════════════════════════
    # v43.8: EXTENDED KNOWLEDGE TRANSFER - integracja Prophet, GPUBound, Bandit, Genetic
    # ═══════════════════════════════════════════════════════════════════════════
    [void] IntegrateProphetData($prophet, [hashtable]$transferData) {
        if ($null -eq $prophet -or $prophet.Apps.Count -eq 0) { return }
        try {
            if (-not $transferData.ContainsKey("ProphetProfiles")) {
                $transferData.ProphetProfiles = @{}
            }
            $profileCount = 0
            foreach ($appName in $prophet.Apps.Keys) {
                $app = $prophet.Apps[$appName]
                if ($app.ContainsKey('Samples') -and $app.Samples -ge 30) {
                    $category = $app.Category -replace "^LEARNING_", ""
                    $preferredMode = switch ($category) {
                        "HEAVY" { "Turbo" }
                        "MEDIUM" { "Balanced" }
                        "LIGHT" { "Silent" }
                        default { "Balanced" }
                    }
                    $transferData.ProphetProfiles[$appName] = @{
                        Category = $category
                        PreferredMode = $preferredMode
                        Confidence = [Math]::Min(1.0, $app.Samples / 100.0)
                        AvgCPU = $app.AvgCPU
                    }
                    $profileCount++
                }
            }
            $this.LogActivity("   Prophet: $profileCount app profiles integrated")
        } catch {
            $this.LogActivity("[WARN] Prophet integration failed")
        }
    }
    [void] IntegrateGPUBoundData($gpuBound, [hashtable]$transferData) {
        if ($null -eq $gpuBound) { return }
        try {
            if (-not $transferData.ContainsKey("GPUBoundScenarios")) {
                $transferData.GPUBoundScenarios = @{}
            }
            if ($gpuBound.IsConfident) {
                $transferData.GPUBoundScenarios["Detected"] = @{
                    IsActive = $true
                    PreferredMode = "Balanced"
                    Reason = "GPU-bound: CPU<50% + GPU>75% = nie Turbo"
                    Confidence = $gpuBound.Confidence
                }
                $this.LogActivity("   GPU-Bound: scenario detected and integrated")
            }
        } catch {
            $this.LogActivity("[WARN] GPU-Bound integration failed")
        }
    }
    [void] IntegrateBanditData($bandit, [hashtable]$transferData) {
        if ($null -eq $bandit -or $bandit.TotalPulls -lt 50) { return }
        try {
            if (-not $transferData.ContainsKey("BanditStats")) {
                $transferData.BanditStats = @{}
            }
            foreach ($arm in $bandit.Arms.Keys) {
                $successes = $bandit.Successes[$arm]
                $failures = $bandit.Failures[$arm]
                $total = $successes + $failures
                if ($total -gt 10) {
                    $successRate = $successes / $total
                    $transferData.BanditStats[$arm] = @{
                        SuccessRate = $successRate
                        TotalPulls = $total
                        Confidence = [Math]::Min(1.0, $total / 100.0)
                    }
                }
            }
            $this.LogActivity("   Bandit: Thompson Sampling stats integrated")
        } catch {
            $this.LogActivity("[WARN] Bandit integration failed")
        }
    }
    [void] IntegrateGeneticData($genetic, [hashtable]$transferData) {
        if ($null -eq $genetic -or $genetic.Generation -lt 10) { return }
        try {
            if (-not $transferData.ContainsKey("GeneticParams")) {
                $transferData.GeneticParams = @{}
            }
            $bestParams = $genetic.GetCurrentParams()
            if ($bestParams.TurboThreshold) {
                $transferData.GeneticParams = @{
                    TurboThreshold = $bestParams.TurboThreshold
                    BalancedThreshold = $bestParams.BalancedThreshold
                    Generation = $genetic.Generation
                    Fitness = $genetic.BestFitness
                }
                $this.LogActivity("   Genetic: evolved thresholds integrated (gen $($genetic.Generation))")
            }
        } catch {
            $this.LogActivity("[WARN] Genetic integration failed")
        }
    }
    [void] ApplyEnrichedToEnsemble($ensemble, [hashtable]$transferData) {
        if ($null -eq $ensemble) { return }
        try {
            # Aplikuj bazowe dane QLearning (używa istniejącej metody)
            $this.ApplyToEnsemble($ensemble, $transferData)
            # Rozszerz o Prophet profiles
            if ($transferData.ContainsKey("ProphetProfiles")) {
                foreach ($appName in $transferData.ProphetProfiles.Keys) {
                    $profile = $transferData.ProphetProfiles[$appName]
                    $modelKey = "Prophet_$appName"
                    $targetWeight = switch ($profile.PreferredMode) {
                        "Turbo" { 0.8 }
                        "Silent" { 0.3 }
                        default { 0.5 }
                    }
                    if (-not $ensemble.Weights.ContainsKey($modelKey)) {
                        $ensemble.Weights[$modelKey] = 0.5
                    }
                    $ensemble.Weights[$modelKey] = ($ensemble.Weights[$modelKey] * 0.7) + ($targetWeight * $profile.Confidence * 0.3)
                }
            }
            # Rozszerz o GPU-Bound scenarios
            if ($transferData.ContainsKey("GPUBoundScenarios") -and $transferData.GPUBoundScenarios.ContainsKey("Detected")) {
                $modelKey = "GPUBound_Scenario"
                if (-not $ensemble.Weights.ContainsKey($modelKey)) {
                    $ensemble.Weights[$modelKey] = 0.5
                }
                $ensemble.Weights[$modelKey] = ($ensemble.Weights[$modelKey] * 0.7) + (0.5 * 0.3)
            }
            # Rozszerz o Bandit stats
            if ($transferData.ContainsKey("BanditStats")) {
                foreach ($arm in $transferData.BanditStats.Keys) {
                    $stats = $transferData.BanditStats[$arm]
                    $modelKey = "Bandit_$arm"
                    if (-not $ensemble.Weights.ContainsKey($modelKey)) {
                        $ensemble.Weights[$modelKey] = 0.5
                    }
                    $ensemble.Weights[$modelKey] = ($ensemble.Weights[$modelKey] * 0.7) + ($stats.SuccessRate * 0.3)
                }
            }
            # Rozszerz o Genetic params
            if ($transferData.ContainsKey("GeneticParams")) {
                $params = $transferData.GeneticParams
                $turboWeight = 1.0 - (($params.TurboThreshold - 70) / 30.0)
                $modelKey = "Genetic_Turbo"
                if (-not $ensemble.Weights.ContainsKey($modelKey)) {
                    $ensemble.Weights[$modelKey] = 0.5
                }
                $ensemble.Weights[$modelKey] = ($ensemble.Weights[$modelKey] * 0.8) + ($turboWeight * 0.2)
            }
            $sources = @()
            if ($transferData.ContainsKey("ProphetProfiles")) { $sources += "Prophet" }
            if ($transferData.ContainsKey("GPUBoundScenarios")) { $sources += "GPU-Bound" }
            if ($transferData.ContainsKey("BanditStats")) { $sources += "Bandit" }
            if ($transferData.ContainsKey("GeneticParams")) { $sources += "Genetic" }
            if ($sources.Count -gt 0) {
                $this.LogActivity(" Ensemble enriched with: $($sources -join ', ')")
            }
        } catch {
            $this.LogActivity("[WARN] Enriched Ensemble application failed")
        }
    }
    [void] TransferBackFromEnsemble($ensemble, $qLearning, $prophet) {
        if ($null -eq $ensemble) { return }
        try {
            $topModels = $ensemble.Weights.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5
            $boostCount = 0
            # Ensemble → Q-Learning: boost najlepszych trybów
            if ($qLearning -and $topModels) {
                foreach ($model in $topModels) {
                    if ($model.Key -match "QLearning_") {
                        $weight = $model.Value
                        foreach ($state in $qLearning.QTable.Keys) {
                            $bestMode = ($qLearning.QTable[$state].GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
                            $boostFactor = 1.0 + ($weight * 0.2)
                            $qLearning.QTable[$state][$bestMode] *= $boostFactor
                            $boostCount++
                        }
                    }
                }
            }
            # Ensemble → Prophet: przyspiesz finalizację
            if ($prophet -and $topModels) {
                foreach ($model in $topModels) {
                    if ($model.Key -match "Prophet_(\w+)") {
                        $appName = $matches[1]
                        if ($prophet.Apps.ContainsKey($appName) -and $prophet.Apps[$appName].Category -match "^LEARNING_") {
                            $prophet.Apps[$appName].Samples += 5
                        }
                    }
                }
            }
            if ($boostCount -gt 0) {
                $this.LogActivity(" Ensemble → QLearning: $boostCount Q-value boosts")
            }
        } catch {
            $this.LogActivity("[WARN] Transfer back from Ensemble failed")
        }
    }
    [void] TransferBackFromBrain($brain, $qLearning) {
        if ($null -eq $brain -or $null -eq $qLearning) { return }
        try {
            $bias = $brain.AggressionBias
            $boostCount = 0
            if ($bias -ne 0) {
                foreach ($state in $qLearning.QTable.Keys) {
                    if ($bias -gt 0) {
                        $qLearning.QTable[$state]["Turbo"] *= (1.0 + $bias * 0.1)
                    } else {
                        $qLearning.QTable[$state]["Silent"] *= (1.0 + [Math]::Abs($bias) * 0.1)
                    }
                    $boostCount++
                }
                $biasDirection = if ($bias -gt 0) { "Turbo" } else { "Silent" }
                $this.LogActivity(" Brain → QLearning: AggressionBias=$([Math]::Round($bias,2)) boosted $biasDirection ($boostCount states)")
            }
        } catch {
            $this.LogActivity("[WARN] Transfer back from Brain failed")
        }
    }
    # ═══════════════════════════════════════════════════════════════════════════
    # GŁÓWNA METODA DECYZYJNA: Waży głosy WSZYSTKICH silników AI
    # Wywoływana w main loop zamiast hardcoded hierarchii
    # ═══════════════════════════════════════════════════════════════════════════
    [hashtable] DecideMode([hashtable]$modelScores, [double]$cpu, [double]$gpu, [double]$temp, [string]$prevMode, [string]$qAction, [string]$foregroundApp, [string]$phase) {
        # Wagi bazowe silników
        $baseWeights = @{
            "QLearning" = 2.0; "Prophet" = 1.8; "Context" = 1.5; "Thermal" = 1.5
            "Phase" = 1.6; "GPU" = 1.3; "Energy" = 1.2; "Trend" = 1.2
            "IOMonitor" = 1.0; "NetworkAI" = 0.8; "Pattern" = 1.0; "Brain" = 1.0
            "Chain" = 0.8; "Predictor" = 0.7
            "Anomaly" = 0.8; "Activity" = 0.6; "PowerBoost" = 0.5
            "AppIntel" = 2.5
        }
        
        # v43.14: Adaptive weights - silniki które trafnie głosują dostają wyższą wagę
        if (-not $this.AdaptiveWeights) { $this.AdaptiveWeights = @{} }
        $weights = @{}
        foreach ($engine in $baseWeights.Keys) {
            $base = $baseWeights[$engine]
            $adaptive = if ($this.AdaptiveWeights.ContainsKey($engine)) { $this.AdaptiveWeights[$engine] } else { 1.0 }
            # Adaptive range: 0.5x to 1.5x base weight (nie za ekstremalny)
            $weights[$engine] = $base * [Math]::Min(1.5, [Math]::Max(0.5, $adaptive))
        }
        
        # Dodaj Phase score do modelScores
        if ($phase -and -not $modelScores.ContainsKey("Phase")) {
            # v43.14: Jeśli AppIntel jest w modelScores i ma learned data,
            # Phase score powinien respektować to co silniki nauczyły się o tej app
            # Hardcoded wartości jako FALLBACK gdy brak learned data
            $phaseScore = switch ($phase) {
                "Loading"  { 80 }  # Potrzebuje mocy (uniwersalne)
                "Gameplay" { 55 }  # v43.14: Obniżone z 62 - GPU-bound games NIE potrzebują CPU
                "Active"   { 70 }  # CPU-intensive task
                "Cutscene" { 30 }  # Stabilne, niskie wymagania CPU
                "Menu"     { 25 }  # Minimalne wymagania
                "Idle"     { 20 }  # Nic nie robi
                "Paused"   { 15 }  # App spauzowana - minimum mocy
                default    { 50 }
            }
            $modelScores["Phase"] = $phaseScore
            
            # v43.15: GPU LOAD FLOOR — jeśli GPU pracuje ciężko, Phase score nie może być za niski
            # Zapobiega: Phase=Cutscene(score=30) + GPU=100% → Silent (throttle/stutter)
            if ($gpu -gt 70 -and $phaseScore -lt 50) {
                $modelScores["Phase"] = 50  # Minimum Balanced gdy GPU aktywny
            }
            # DESKTOP IDLE FIX: gdy foreground=Desktop i użytkownik nieaktywny,
            # faza "Active" (score=70) pochodzi od procesów tła Windows (Defender, OneDrive itp.),
            # a nie od faktycznej pracy użytkownika → obniż score do 35 (nie blokuje Silent)
            if (($foregroundApp -eq 'Desktop' -or $foregroundApp -eq 'explorer') -and
                $phaseScore -gt 35 -and (-not $Script:UserIsActive)) {
                $modelScores["Phase"] = 35  # Procesy tła nie potrzebują wydajności CPU
            }
        }
        
        # Oblicz ważoną średnią score
        # CRITICAL: Silniki ze score=50 (neutralnym/domyślnym) NIE głosują!
        # Bez tego: 10 silników z "brak danych=50" rozmywa decyzje aktywnych silników
        # Wynik: IDLE daje Balanced zamiast Silent (efekt placebo)
        $totalWeight = 0.0
        $weightedScore = 0.0
        foreach ($engine in $modelScores.Keys) {
            $w = if ($weights.ContainsKey($engine)) { $weights[$engine] } else { 0.5 }
            $score = $modelScores[$engine]
            if ($score -ne $null -and $score -ge 0) {
                # Silnik z realnym sygnałem (odchylenie >5 od neutralnego 50) głosuje normalnie
                # Silnik bez danych (score=50 ±5) ma zredukowaną wagę do 10%
                if ([Math]::Abs($score - 50) -le 5) {
                    $w = $w * 0.1  # Prawie brak wpływu na decyzję
                }
                $weightedScore += $score * $w
                $totalWeight += $w
            }
        }
        $finalScore = if ($totalWeight -gt 0) { $weightedScore / $totalWeight } else { 50 }
        
        # v43.14: CPUAgressiveness bias na finalScore
        # 0=conservative (score obniżony → Silent częściej), 50=neutral, 100=aggressive (→Turbo częściej)
        $aggrBias = 0.0
        if ($null -ne $Script:CPUAgressiveness) {
            $aggrBias = ($Script:CPUAgressiveness - 50) / 100.0  # -0.5 do +0.5
            # Bias przesuwa score: aggressive +5..+15 punktów, conservative -5..-15
            $finalScore += $aggrBias * 25.0
        }
        
        # v43.14: User per-app Bias z AppCategories (ProcessAI.json)
        # Jeśli user ustawił Bias per-app, wpływa na score
        if ($Script:AppCategoryPreferences -and $foregroundApp) {
            foreach ($key in $Script:AppCategoryPreferences.Keys) {
                $keyLower = $key.ToLower() -replace '\.exe$', ''
                $appLower = $foregroundApp.ToLower() -replace '\.exe$', ''
                if ($keyLower -eq $appLower -or $appLower -like "*$keyLower*") {
                    $pref = $Script:AppCategoryPreferences[$key]
                    if (-not $pref.HardLock -and $null -ne $pref.Bias) {
                        # Bias 0=Silent, 0.5=Balanced, 1.0=Turbo
                        $userBias = ($pref.Bias - 0.5) * 30.0  # -15 do +15 punktów
                        $finalScore += $userBias
                    }
                    break
                }
            }
        }
        
        # Q-Learning override: jeśli Q-Learning ma mocne przekonanie, wzmocnij jego głos
        if ($qAction) {
            $qMode = $qAction
            if ($qMode -eq "Silent" -and $finalScore -lt 45) {
                $finalScore = $finalScore * 0.85
            }
            elseif ($qMode -eq "Turbo" -and $finalScore -gt 60) {
                $finalScore = $finalScore * 1.1
            }
        }
        
        # Clamp
        $finalScore = [Math]::Min(100, [Math]::Max(0, $finalScore))
        
        # CPU FLOOR GUARD: jeśli CPU jest aktywnie używany, nie pozwól na Silent
        # Zapobiega: Desktop z CPU=60% → Silent (score=33 bo Phase=Idle)
        if ($cpu -gt 40 -and $finalScore -lt 45) {
            $finalScore = 45  # Minimum Balanced gdy CPU aktywny
        }
        
        # EXPLORER SPIKE GUARD: jeśli foreground=Desktop/Explorer a CPU>30%
        # to prawdopodobnie Explorer odświeża ikony/thumbnails — to nie jest
        # "prawdziwa" aktywność użytkownika, nie wchodź w Turbo/Balanced
        # Sprawdź ile CPU żre sam explorer.exe (nie systemowy spike)
        $explorerCPU = 0
        try {
            $explorerProcs = Get-Process -Name explorer -ErrorAction SilentlyContinue
            if ($explorerProcs) {
                $explorerCPU = ($explorerProcs | Measure-Object CPU -Sum).Sum
                # CPU z Get-Process to sekundy użycia — przelicz na % (przybliżenie)
                # Jeśli Explorer ma dużo CPU a foreground=Desktop → to odświeżanie ikon
            }
        } catch {}
        if (($foregroundApp -eq 'Desktop' -or $foregroundApp -eq 'explorer') -and $cpu -gt 30) {
            # Sprawdź czy to Explorer dominuje CPU (>50% systemu idzie na explorer)
            # Jeśli tak — ignoruj ten spike, nie podnoś trybu
            $explorerDominant = $false
            try {
                $expProc = Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($expProc) {
                    $explorerPct = [Math]::Round(($expProc.CPU / ([Environment]::ProcessorCount * 1.0)) * 2, 1)
                    if ($explorerPct -gt 15) { $explorerDominant = $true }
                }
            } catch {}
            if ($explorerDominant) {
                # Explorer odświeża ikony — zbij score do Silent/Balanced bez Turbo
                $finalScore = [Math]::Min($finalScore, 54)
                Write-RCLog "EXPLORER SPIKE: score capped (explorer refreshing icons, CPU=$cpu%)"
            }
        }
        
        # Konwersja score → tryb z HYSTERESIS
        # v43.14: Progi adaptowane do CPUAgressiveness
        # aggressive=łatwiej Turbo (niższy próg), conservative=łatwiej Silent
        $silentExitUp = 55 - ($aggrBias * 10)    # aggressive: 50, conservative: 60
        $turboEntryDown = 65 - ($aggrBias * 10)   # aggressive: 60, conservative: 70
        $turboExitDown = 58 - ($aggrBias * 8)     # aggressive: 54, conservative: 62
        $silentEntryUp = 38 + ($aggrBias * 8)     # aggressive: 42, conservative: 34
        
        $newMode = "Balanced"
        $reason = ""
        
        # Progi zależne od obecnego trybu (hysteresis zapobiega ping-pong)
        if ($prevMode -eq "Silent") {
            if ($finalScore -gt ($turboEntryDown + 7)) { $newMode = "Turbo"; $reason = "EXIT-SILENT→TURBO" }
            elseif ($finalScore -gt $silentExitUp) { $newMode = "Balanced"; $reason = "EXIT-SILENT" }
            else { $newMode = "Silent"; $reason = "HOLD-SILENT" }
        }
        elseif ($prevMode -eq "Turbo") {
            if ($finalScore -lt ($silentEntryUp - 3)) { $newMode = "Silent"; $reason = "EXIT-TURBO→SILENT" }
            elseif ($finalScore -lt $turboExitDown) { $newMode = "Balanced"; $reason = "EXIT-TURBO" }
            else { $newMode = "Turbo"; $reason = "HOLD-TURBO" }
        }
        else {
            if ($finalScore -gt $turboEntryDown) { $newMode = "Turbo"; $reason = "SCORE-HIGH" }
            elseif ($finalScore -lt $silentEntryUp) { $newMode = "Silent"; $reason = "SCORE-LOW" }
            else { $newMode = "Balanced"; $reason = "SCORE-MID" }
        }
        
        # Aktualizuj statystyki
        $engineUsed = "Coordinator"
        $this.EngineDecisionCount[$this.ActiveEngine]++
        
        # v46: OUTCOME-BASED adaptive weights (nie circular!)
        # Nie nagradzamy silników za ZGODNOŚĆ z koordynatorem (echo chamber),
        # a za TRAFNOŚĆ PRZEWIDYWANIA — mierzymy EFEKT poprzedniej decyzji:
        # - Czy temp spadła/stabilna? → decyzja OK
        # - Czy CPU headroom był wystarczający? → nie za dużo, nie za mało
        # - Czy nie było stutteringu? → decyzja OK
        if ($this.LastModelScores -and $this.LastDecidedMode) {
            $lr = 0.02
            # Outcome score: jak DOBRE było to co koordynator zdecydował?
            $outcomeGood = $true
            $penalty = 0.0
            # Thermal check: jeśli po Turbo temp wzrosła >85°C → zła decyzja
            if ($this.LastDecidedMode -eq "Turbo" -and $temp -gt 85) { $outcomeGood = $false; $penalty = 0.3 }
            # Silent check: jeśli po Silent CPU>70% → zła decyzja (app potrzebowała mocy)
            if ($this.LastDecidedMode -eq "Silent" -and $cpu -gt 70) { $outcomeGood = $false; $penalty = 0.3 }
            # Stutter check
            if ($Script:PerfMonitor -and $Script:PerfMonitor.HasRecentStutter()) { $outcomeGood = $false; $penalty = 0.2 }
            
            foreach ($engine in $this.LastModelScores.Keys) {
                $engineScore = $this.LastModelScores[$engine]
                if ($null -eq $engineScore) { continue }
                if (-not $this.AdaptiveWeights) { $this.AdaptiveWeights = @{} }
                $current = if ($this.AdaptiveWeights.ContainsKey($engine)) { $this.AdaptiveWeights[$engine] } else { 1.0 }
                
                $decidedScore = switch ($this.LastDecidedMode) { "Silent" { 20 } "Balanced" { 50 } "Turbo" { 80 } default { 50 } }
                $engineAgreed = ([Math]::Abs($engineScore - $decidedScore) -lt 25)
                
                if ($outcomeGood) {
                    # Dobry outcome: nagradzaj silniki które ZGADZAŁY SIĘ z decyzją
                    if ($engineAgreed) { $current = $current * (1.0 - $lr) + 1.1 * $lr }
                } else {
                    # Zły outcome: karaj silniki które głosowały ZA złą decyzją
                    if ($engineAgreed) { $current = $current * (1.0 - $lr) + (0.7 - $penalty) * $lr }
                    # Nagradzaj silniki które OSTRZEGAŁY (głosowały inaczej)
                    else { $current = $current * (1.0 - $lr) + 1.15 * $lr }
                }
                $this.AdaptiveWeights[$engine] = [Math]::Min(1.5, [Math]::Max(0.5, $current))
            }
        }
        $this.LastModelScores = $modelScores.Clone()
        $this.LastDecidedMode = $newMode
        
        return @{
            Mode = $newMode
            Score = [Math]::Round($finalScore, 1)
            Reason = "AI-COORD($reason): score=$([Math]::Round($finalScore,1)) app=$foregroundApp Q=$qAction P=$phase"
        }
    }
}