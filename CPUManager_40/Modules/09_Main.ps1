# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 09_Main.ps1
# Main function + session summary
# Lines 20438-24890 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
function Main {
    Clear-Host
    Write-Host "`n  #" -ForegroundColor Cyan
    Write-Host "    CPU Manager v40 - STARTING" -ForegroundColor Yellow
    Write-Host "  #" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Initializing CPU Manager AI ULTRA..." -ForegroundColor Cyan
    Write-Host "  Config: $Script:ConfigDir" -ForegroundColor Gray
    
    # Initialize DEBUG logging
    Initialize-DebugLog
    Write-DebugLog "=== CPUManager ENGINE v42.6 FINAL Started ===" "INFO"
    Write-DebugLog "Config directory: $Script:ConfigDir" "INFO"
    
    # CRITICAL: Sprawdź czy folder config istnieje (RAM dysk może nie być gotowy)
    if (-not (Test-Path $Script:ConfigDir)) {
        Write-Host ""
        Write-Host "  [!] OSTRZEŻENIE: Folder $Script:ConfigDir nie istnieje!" -ForegroundColor Red
        Write-Host "  [!] Tworzę folder..." -ForegroundColor Yellow
        try {
            $null = Ensure-DirectoryExists $Script:ConfigDir
            if (Test-Path $Script:ConfigDir) {
                Write-Host "  [OK] Folder utworzony pomyślnie" -ForegroundColor Green
            } else {
                Write-Host "  [!] BŁĄD: Nie można utworzyć folderu!" -ForegroundColor Red
                Write-Host "  [!] Czy RAM dysk jest zamontowany?" -ForegroundColor Yellow
                Write-Host "  [!] Sprawdź przekierowanie C:\CPUManager" -ForegroundColor Yellow
                Start-Sleep -Seconds 3
            }
        } catch {
            Write-Host "  [!] BŁĄD: $_" -ForegroundColor Red
            Start-Sleep -Seconds 3
        }
    }
    
    # === LADOWANIE CONFIG.JSON (HOT-RELOAD) ===
    Write-Host ""
    Load-ExternalConfig | Out-Null
    Apply-ConfiguratorSettings
    Write-Host ""
    # === SYSTEM TRAY DLA GLOWNEGO PROCESU ===
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    # Funkcja do ukrywania/pokazywania okna konsoli
    $consolePtr = [ConsoleWindow]::GetConsoleWindow()
    $Global:ConsoleVisible = $true
    # Przycisk X w konsoli dziala normalnie (zamyka program)
    function Hide-Console {
        [ConsoleWindow]::ShowWindow($consolePtr, 0) | Out-Null
        $Global:ConsoleVisible = $false
        $Script:MainTray.ShowBalloonTip(1500, "CPU Manager AI", "Program dziala w tle. Kliknij 2x na ikone AI aby przywrocic.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
    function Show-Console {
        [ConsoleWindow]::ShowWindow($consolePtr, 5) | Out-Null
        [ConsoleWindow]::SetForegroundWindow($consolePtr) | Out-Null
        $Global:ConsoleVisible = $true
    }
    # NotifyIcon juz utworzony na poczatku skryptu
    # Menu kontekstowe
    $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $menuShow = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuShow.Text = "- Pokaz konsole"
    $menuShow.Add_Click({ Show-Console })
    $menuHide = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuHide.Text = "- Ukryj konsole"
    $menuHide.Add_Click({ Hide-Console })
    $menuDash = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuDash.Text = " Dashboard"
    $menuDash.Add_Click({ Start-Process "http://localhost:8080" | Out-Null })
    $menuWidget = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuWidget.Text = "- Pokaz Widget"
    $menuWidget.Add_Click({
        # Widget uruchomiony zewnetrznie - wyslij komende SHOW (async)
        $widgetCmd = Join-Path $Script:ConfigDir 'WidgetCommand.txt'
        Start-BackgroundWrite $widgetCmd "SHOW" 'UTF8'
    })
    $menuMini = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuMini.Text = "- Pokaz Mini Widget"
    $menuMini.Add_Click({
        $miniScript = Join-Path $Script:ConfigDir 'MiniWidget_v40.ps1'
        if (Test-Path $miniScript) {
            Start-Process pwsh.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $miniScript | Out-Null
        }
    })
    $menuConfig = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuConfig.Text = " Konfiguracja"
    $menuConfig.Add_Click({
        $configRunspace = [runspacefactory]::CreateRunspace()
        $configRunspace.ApartmentState = "STA"
        $configRunspace.Open()
        $configPS = New-TrackedPowerShell 'ConfigUI'
        $configPS.Runspace = $configRunspace
        $null = $configPS.AddScript({ Show-ConfigUI })
        $null = $configPS.BeginInvoke()
    })
    $menuSep1 = New-Object System.Windows.Forms.ToolStripSeparator
    # === SUBMENU TRYBOW ===
    $menuModes = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuModes.Text = "- Tryb pracy"
    $menuSilent = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuSilent.Text = "- Silent"
    $menuSilent.Add_Click({
        $Global:AI_Active = $false
        Send-TrayCommand "SILENT"
    })
    $menuModes.DropDownItems.Add($menuSilent)
    $menuBalanced = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuBalanced.Text = "- Balanced"
    $menuBalanced.Add_Click({
        $Global:AI_Active = $false
        Send-TrayCommand "BALANCED"
    })
    $menuModes.DropDownItems.Add($menuBalanced)
    $menuTurbo = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuTurbo.Text = " Turbo"
    $menuTurbo.Add_Click({
        $Global:AI_Active = $false
        Send-TrayCommand "TURBO"
    })
    $menuModes.DropDownItems.Add($menuTurbo)
    $menuModes.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $menuAI = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuAI.Text = " Toggle AI"
    $menuAI.Add_Click({
        $Global:AI_Active = -not $Global:AI_Active
    })
    $menuModes.DropDownItems.Add($menuAI)
    $menuSep2 = New-Object System.Windows.Forms.ToolStripSeparator
    $menuExit = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuExit.Text = "- Zamknij program"
    $menuExit.Add_Click({
        $Global:ExitRequested = $true
        $Script:MainTray.Visible = $false
        $Script:MainTray.Dispose()
    })
    $menuSep3 = New-Object System.Windows.Forms.ToolStripSeparator
    # === KILL ALL ===
    $menuKillAll = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuKillAll.Text = "- KILL ALL"
    $menuKillAll.BackColor = [System.Drawing.Color]::FromArgb(80, 20, 20)
    $menuKillAll.ForeColor = [System.Drawing.Color]::Red
    $menuKillAll.Add_Click({
        $Script:MainTray.Visible = $false
        Send-TrayCommand "EXIT"
        Start-BackgroundWrite (Join-Path $Script:ConfigDir 'MiniWidgetCommand.txt') "EXIT" 'UTF8'
        Start-Sleep -Milliseconds 200
        Get-Process powershell,pwsh,powershell_ise -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -match "CPU|Widget|Mini" } | Stop-Process -Force -ErrorAction SilentlyContinue
        $Global:ExitRequested = $true
    })
    $trayMenu.Items.Add($menuShow)
    $trayMenu.Items.Add($menuHide)
    $trayMenu.Items.Add($menuDash)
    $trayMenu.Items.Add($menuWidget)
    $trayMenu.Items.Add($menuMini)
    $trayMenu.Items.Add($menuConfig)
    $trayMenu.Items.Add($menuSep1)
    $trayMenu.Items.Add($menuModes)
    $trayMenu.Items.Add($menuSep2)
    $trayMenu.Items.Add($menuExit)
    $trayMenu.Items.Add($menuSep3)
    $trayMenu.Items.Add($menuKillAll)
    # Menu juz przypisane na poczatku skryptu (Script:TrayMenu)
    # Podwojne klikniecie na tray - pokaz/ukryj konsole
    $Script:MainTray.Add_DoubleClick({
        if ($Global:ConsoleVisible) { Hide-Console } else { Show-Console }
    })
    # Komunikat powitalny z informacja o CPU
    $cpuInfo = if ($Script:CPUName -ne "Unknown") { $Script:CPUName } else { $Script:CPUType }
    $Script:MainTray.ShowBalloonTip(4000, "CPU Manager AI", "Wykryto: $cpuInfo`nTyp: $($Script:CPUType)`nTryb: AI AUTO", [System.Windows.Forms.ToolTipIcon]::Info)
    # DEBUG TRACE: startup point - MainTray created
    try { Write-Host "[DEBUG] Engine: MainTray created, CPU=$cpuInfo, CPUType=$($Script:CPUType)" -ForegroundColor Yellow } catch { }
    # Global flags for tray/dashboard
    $Global:ExitRequested = $false
    $Global:ManualOverride = $null
    # Zmienne pomocnicze cache - inicjalizacja przed petla glowna
    $Script:LastFgHwndRaw = [IntPtr]::Zero
    $Script:LastFgRawPN = $null
    $Script:NetAdaptersAsyncPS = $null
    $Script:NetAdaptersAsyncResult = $null
    # Obsluga Ctrl+C - traktuj jako input, nie jako przerwanie
    try { [Console]::TreatControlCAsInput = $true } catch { }
    # - DETEKCJA ZRODEL DANYCH - wykryj dostepne LHM/OHM/System
    Detect-DataSources | Out-Null
    $metrics = [FastMetrics]::new()
    # Pokaz podsumowanie zrodel danych
    Show-DataSourcesSummary
    # --- Metrics updater using WinForms Timer (runs on UI thread) ---
    try {
        $Script:MetricsLock = New-Object System.Object
        $Script:LatestMetrics = $metrics.GetExtended()
        $Script:MetricsTimer = New-Object System.Windows.Forms.Timer
        $Script:MetricsTimer.Interval = 500  # v40.4: Skrocono z 1000ms - swiezsze dane dla petli
        $Script:MetricsTimer.Add_Tick({
            try {
                # V40.3 FIX: Użyj GetExtended() zamiast Get() żeby mieć GPU data!
                $m = $null
                try { $m = $metrics.GetExtended() } catch { $m = $null }
                if ($m) {
                    if ([System.Threading.Monitor]::TryEnter($Script:MetricsLock, 50)) {
                        try { $Script:LatestMetrics = $m } finally { [System.Threading.Monitor]::Exit($Script:MetricsLock) }
                    }
                }
            } catch { }
        })
        $Script:MetricsTimer.Start()
        try { Add-Log "Metrics timer started (UI thread)" } catch { }
        # Background sensor poller (runs on ThreadPool thread) - offloads heavy WMI/Get-CimInstance calls
        try {
            if (-not $Script:SensorPollMs) { $Script:SensorPollMs = 800 }  # v40.4: Skrocono z 1500ms
            if (-not $Script:SensorErrorCount) { $Script:SensorErrorCount = 0 }
            $Script:SensorTimer = New-Object System.Timers.Timer($Script:SensorPollMs)
            $Script:SensorTimer.AutoReset = $true
            $Script:SensorTimer.add_Elapsed({
                try {
                    $m = $metrics.GetExtended()
                    if ($m) {
                        if ([System.Threading.Monitor]::TryEnter($Script:MetricsLock, 200)) {
                            try { $Script:LatestMetrics = $m } finally { [System.Threading.Monitor]::Exit($Script:MetricsLock) }
                        }
                    }
                    # Periodic RyzenAdj info refresh (non-blocking)
                    try {
                        if ($Script:RyzenAdjAvailable) {
                            $elapsed = ([DateTime]::Now - $Script:LastRyzenInfoPollTime).TotalMilliseconds
                            if ($elapsed -ge $Script:RyzenInfoPollMs) {
                                Start-RyzenAdjInfoRefresh | Out-Null
                                $Script:LastRyzenInfoPollTime = [DateTime]::Now
                            }
                        }
                    } catch { }
                    # reset error counter on success
                    $Script:SensorErrorCount = 0
                } catch {
                    try { $Script:SensorErrorCount = [int]($Script:SensorErrorCount + 1) } catch { $Script:SensorErrorCount = 1 }
                    if ($Script:SensorErrorCount -gt 5) {
                        # exponential backoff up to 60s
                        $new = [int]::Min(60000, [int]($Script:SensorPollMs * 2))
                        $Script:SensorPollMs = $new
                        try { $Script:SensorTimer.Interval = $new } catch { }
                        try { Add-Log "Sensor poll errors; backing off to $new ms" } catch { }
                    }
                }
            })
            $Script:SensorTimer.Start()
            try { Add-Log "Sensor timer started (background thread), interval=${Script:SensorPollMs}ms" } catch { }
        } catch { }
    } catch { }
    $loaded = Load-State
    $brain = $loaded.Brain
    $prophet = $loaded.Prophet
    $gpuBound = $loaded.GPUBound  # v42.1: GPU-Bound Detector
    # Apply CPUAgressiveness from config to Brain's AggressionBias
    # CPUAgressiveness: 0=conservative, 50=neutral, 100=aggressive
    # Maps to AggressionBias: -0.5 to +0.5
    if ($brain -and $null -ne $Script:CPUAgressiveness) {
        $brain.AggressionBias = ($Script:CPUAgressiveness - 50) / 100.0
        Write-Host "  Brain AggressionBias set to $($brain.AggressionBias) from CPUAgressiveness=$($Script:CPUAgressiveness)" -ForegroundColor Gray
    }
    # v40.2 FIX: CPUAgressiveness wpływa RÓWNIEŻ na QLearning i SelfTuner (NeuralBrain domyślnie OFF)
    if ($qLearning -and $null -ne $Script:CPUAgressiveness) {
        # Agresywność wpływa na ExplorationRate: conservative=więcej eksploracji, aggressive=więcej eksploatacji
        $qLearning.ExplorationRate = [Math]::Max(0.05, 0.25 - ($Script:CPUAgressiveness / 100.0) * 0.20)
    }
    if ($selfTuner -and $null -ne $Script:CPUAgressiveness) {
        # Agresywność wpływa na progi SelfTunera
        $aggrBias = ($Script:CPUAgressiveness - 50) / 100.0  # -0.5 do +0.5
        $profile = $selfTuner.GetCurrentProfile()
        if ($profile) {
            $profile.AggressionBias = $aggrBias
        }
    }
    # BiasInfluence: 0=AI ignores user, 25=balanced, 40=AI strongly follows user
    if ($brain -and $null -ne $Script:BiasInfluence) {
        $biasMultiplier = $Script:BiasInfluence / 25.0  # 0 -> 0.0, 25 -> 1.0, 40 -> 1.6
        $brain.AggressionBias += ($biasMultiplier - 1.0) * 0.1  # Slight adjustment based on user preference
        $brain.AggressionBias = [Math]::Max(-0.5, [Math]::Min(0.5, $brain.AggressionBias))
        Write-Host "  BiasInfluence=$($Script:BiasInfluence) applied (multiplier=$biasMultiplier)" -ForegroundColor Gray
    }
    if (-not (Test-Path $Script:ProphetPath)) {
        try {
            $emptyProphet = @{ Apps = @{}; LastActiveApp = ""; TotalSessions = 0; HourlyActivity = [int[]]::new(24) }
            $json = $emptyProphet | ConvertTo-Json -Depth 3 -Compress
            [System.IO.File]::WriteAllText($Script:ProphetPath, $json, [System.Text.Encoding]::UTF8)
            Add-Log " Created empty ProphetMemory.json"
        } catch { }
    }
    if (-not (Test-Path $Script:BrainPath)) {
        try {
            $emptyBrain = @{ Weights = @{}; AggressionBias = 0.5; ReactivityBias = 0.5; LastLearned = ""; TotalDecisions = 0; RAMWeight = 0.3 }
            $json = $emptyBrain | ConvertTo-Json -Depth 3 -Compress
            [System.IO.File]::WriteAllText($Script:BrainPath, $json, [System.Text.Encoding]::UTF8)
            Add-Log " Created empty BrainState.json"
        } catch { }
    }
    $aiEngineFiles = @(
        @{ Name = "EnsembleWeights.json"; Data = @{ Weights = @{}; Accuracy = @{}; TotalVotes = 0 } }
        @{ Name = "QLearning.json"; Data = @{ QTable = @{}; TotalUpdates = 0 } }
        @{ Name = "Bandit.json"; Data = @{ Arms = @(); TotalPulls = 0; BestArm = "" } }
        @{ Name = "Genetic.json"; Data = @{ Population = @(); Generation = 0; BestFitness = 0 } }
        @{ Name = "AnomalyProfiles.json"; Data = @{ Profiles = @{} } }
        @{ Name = "LoadPatterns.json"; Data = @{ Patterns = @{} } }
        @{ Name = "SelfTuner.json"; Data = @{ DecisionHistory = @(); Adjustments = 0 } }
        @{ Name = "ChainPredictor.json"; Data = @{ Chains = @{}; TotalPredictions = 0 } }
        @{ Name = "UserPatterns.json"; Data = @{ Patterns = @{} } }
        @{ Name = "ContextPatterns.json"; Data = @{ Contexts = @{} } }
        @{ Name = "ThermalProfiles.json"; Data = @{ Profiles = @{} } }
        @{ Name = "DecisionExplainer.json"; Data = @{ Decisions = @() } }
        @{ Name = "ThermalGuardian.json"; Data = @{ ThermalEvents = @(); ProtectionCount = 0 } }
        @{ Name = "EnergyStats.json"; Data = @{ TotalScore = 0; Samples = 0; CurrentEfficiency = 0.5 } }
        @{ Name = "AICoordinator.json"; Data = @{ TransferCount = 0; ActiveEngine = "QLearning" } }
        @{ Name = "RAMAnalyzer.json"; Data = @{ SpikeHistory = @(); AppRAM = @{} } }
    )
    $createdCount = 0
    foreach ($file in $aiEngineFiles) {
        $filePath = Join-Path $Script:ConfigDir $file.Name
        if (-not (Test-Path $filePath)) {
            try {
                $json = $file.Data | ConvertTo-Json -Depth 3 -Compress
                [System.IO.File]::WriteAllText($filePath, $json, [System.Text.Encoding]::UTF8)
                $createdCount++
            } catch { }
        }
    }
    if ($createdCount -gt 0) {
        Add-Log " Created $createdCount empty AI engine files"
    }
    $initialCooldown = [Math]::Max(5, [int]$Script:BoostCooldown)
    $watcher = [ProcessWatcher]::new($initialCooldown)
    $Script:ProcessWatcherInstance = $watcher
    # --------------------------- AILearning storage helpers ---------------------------
    # Kompaktowa pamięć AI — zbiera wiedzę ze WSZYSTKICH silników do jednego pliku
    # AILearningState.json = per-app profil (BestMode, AvgCPU, GPU, Phase, Thermal...)
    # Bufor w RAM → flush przy auto-save (co 5 min) i shutdown. ZERO timerów.
    if (-not $Script:ConfigDir) { $Script:ConfigDir = "C:\CPUManager" }
    if (-not $Script:AILearningSnapshotPath) { $Script:AILearningSnapshotPath = Join-Path $Script:ConfigDir 'AILearningState.json' }
    if (-not $Script:AILearningMaxApps) { $Script:AILearningMaxApps = 200 }

    $Script:AILearningBuffer = @{}
    $Script:AILearningDirty = $false

    # Załaduj istniejący stan przy starcie
    try {
        if (Test-Path $Script:AILearningSnapshotPath) {
            $existingData = Get-Content $Script:AILearningSnapshotPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($existingData.Apps) {
                foreach ($prop in $existingData.Apps.PSObject.Properties) {
                    $v = $prop.Value
                    $Script:AILearningBuffer[$prop.Name] = @{
                        AvgCPU=[double]$(if($v.AvgCPU){$v.AvgCPU}else{0}); AvgGPU=[double]$(if($v.AvgGPU){$v.AvgGPU}else{0})
                        AvgTemp=[double]$(if($v.AvgTemp){$v.AvgTemp}else{0}); BestMode=$(if($v.BestMode){$v.BestMode}else{""})
                        Sessions=[int]$(if($v.Sessions){$v.Sessions}else{0}); Category=$(if($v.Category){$v.Category}else{""})
                        ThermalRisk=$(if($v.ThermalRisk){$v.ThermalRisk}else{"Low"}); PeakTemp=[double]$(if($v.PeakTemp){$v.PeakTemp}else{0})
                        PreferredGPU=$(if($v.PreferredGPU){$v.PreferredGPU}else{""}); IsGPUBound=[bool]$(if($v.IsGPUBound){$v.IsGPUBound}else{$false})
                        DominantPhase=$(if($v.DominantPhase){$v.DominantPhase}else{""}); Efficiency=[double]$(if($v.Efficiency){$v.Efficiency}else{0})
                        QBestAction=$(if($v.QBestAction){$v.QBestAction}else{""}); QConfidence=[double]$(if($v.QConfidence){$v.QConfidence}else{0})
                        NetworkMode=$(if($v.NetworkMode){$v.NetworkMode}else{""}); UpdateCount=[int]$(if($v.UpdateCount){$v.UpdateCount}else{0})
                        LastSeen=$(if($v.LastSeen){$v.LastSeen}else{""})
                    }
                }
                Write-Host "  [AILearning] Loaded $($Script:AILearningBuffer.Count) app profiles" -ForegroundColor Green
            }
        }
    } catch { }

    function Append-AILearningEntry {
        param([Parameter(Mandatory=$true)][object]$Entry)
        try {
            $app = $Entry.App
            if ([string]::IsNullOrWhiteSpace($app) -or $app -eq "Desktop") { return }
            $key = $app.ToLower()
            if (-not $Script:AILearningBuffer.ContainsKey($key)) {
                $Script:AILearningBuffer[$key] = @{
                    AvgCPU=0; AvgGPU=0; AvgTemp=0; BestMode=""; Sessions=0; Category=""
                    ThermalRisk="Low"; PeakTemp=0; PreferredGPU=""; IsGPUBound=$false
                    DominantPhase=""; Efficiency=0; QBestAction=""; QConfidence=0
                    NetworkMode=""; UpdateCount=0; LastSeen=""
                }
            }
            $p = $Script:AILearningBuffer[$key]
            $p.LastSeen = (Get-Date).ToString('o')
            $p.UpdateCount++
            switch ($Entry.Component) {
                "Prophet"   { if($Entry.AvgCPU){$p.AvgCPU=[Math]::Round([double]$Entry.AvgCPU,1)}; if($Entry.AvgGPU){$p.AvgGPU=[Math]::Round([double]$Entry.AvgGPU,1)}; if($Entry.BestMode){$p.BestMode=$Entry.BestMode}; if($Entry.Sessions){$p.Sessions=[int]$Entry.Sessions} }
                "QLearning" { if($Entry.QBestAction){$p.QBestAction=$Entry.QBestAction}; if($Entry.Confidence){$p.QConfidence=[Math]::Round([double]$Entry.Confidence,2)} }
                "GPUAI"     { if($Entry.PreferredGPU){$p.PreferredGPU=$Entry.PreferredGPU}; if($null-ne$Entry.IsGPUBound){$p.IsGPUBound=[bool]$Entry.IsGPUBound}; if($Entry.GPUCategory){$p.Category=$Entry.GPUCategory} }
                "Phase"     { if($Entry.DominantPhase){$p.DominantPhase=$Entry.DominantPhase} }
                "Thermal"   { if($Entry.AvgTemp){$p.AvgTemp=[Math]::Round([double]$Entry.AvgTemp,1)}; if($Entry.PeakTemp-and[double]$Entry.PeakTemp-gt$p.PeakTemp){$p.PeakTemp=[Math]::Round([double]$Entry.PeakTemp,1)}; if($Entry.Risk){$p.ThermalRisk=$Entry.Risk} }
                "Context"   { if($Entry.Category){$p.Category=$Entry.Category} }
                "Network"   { if($Entry.Mode){$p.NetworkMode=$Entry.Mode} }
                "Energy"    { if($Entry.Efficiency){$p.Efficiency=[Math]::Round([double]$Entry.Efficiency,2)} }
                "Governor"  { if($Entry.PreferredGPU){$p.PreferredGPU=$Entry.PreferredGPU} }
            }
            $Script:AILearningDirty = $true
        } catch { }
    }

    function Flush-AILearningBuffer {
        param([switch]$Force)
        if (-not $Script:AILearningDirty -and -not $Force) { return }
        try {
            $buf = $Script:AILearningBuffer
            if (-not $buf -or $buf.Count -eq 0) { return }
            # Ogranicz do max apps — usuń najstarsze
            if ($buf.Count -gt $Script:AILearningMaxApps) {
                $sorted = $buf.GetEnumerator() | Sort-Object { $_.Value.LastSeen } -Descending | Select-Object -First $Script:AILearningMaxApps
                $newBuf = @{}; foreach ($item in $sorted) { $newBuf[$item.Key] = $item.Value }
                $Script:AILearningBuffer = $newBuf; $buf = $newBuf
            }
            $snapshot = @{ Version = "1.0"; SavedAt = (Get-Date).ToString('o'); TotalApps = $buf.Count; Apps = $buf }
            $json = $snapshot | ConvertTo-Json -Depth 4 -Compress
            [System.IO.File]::WriteAllText($Script:AILearningSnapshotPath, $json, [System.Text.Encoding]::UTF8)
            $Script:AILearningDirty = $false
        } catch { }
    }

    # Stub-y zachowane dla kompatybilności — nic nie robią, zero timerów
    function Start-AILearningFlushTimer { param([int]$IntervalSeconds = 10) }
    function Stop-AILearningFlushTimer { }
    function Rotate-AILearningLog { }
    function Save-AILearningSnapshot { param([int]$Lines = 0); Flush-AILearningBuffer -Force }
    function Start-AILearningMaintenance { param([int]$IntervalMinutes = 10) }
    function Stop-AILearningMaintenance { }

    # By default do not start maintenance automatically — caller may enable if desired.
    # Example to enable maintenance in background: Start-AILearningMaintenance -IntervalMinutes 10

    $forecaster = [Forecaster]::new()
    $anomalyDetector = [AnomalyDetector]::new()
    $priorityManager = [SmartPriorityManager]::new()
    $proBalance = [ProBalance]::new($Script:TotalThreads)  # v39.15: ProBalance (CPU hog restraint)
    $performanceBooster = [PerformanceBooster]::new()  # V38 NEW: Advanced performance booster
    # Load persisted performance cache (KnownHeavyApps, AppExecutablePaths)
    try {
        $performanceCachePath = Join-Path $Script:ConfigDir "PerformanceCache.json"
        $performanceBooster.LoadCache($performanceCachePath)
        $Script:PerformanceCachePath = $performanceCachePath
        if (-not $Script:PerformanceCacheDebounceSec) { $Script:PerformanceCacheDebounceSec = 60 }
    } catch { }
    try {
        $pbConfigPath = Join-Path $Script:ConfigDir "ProBalanceConfig.json"
        if (Test-Path $pbConfigPath) {
            $pbConfig = Get-Content $pbConfigPath -Raw | ConvertFrom-Json
            if ($pbConfig.ThrottleThreshold) {
                $newThreshold = [Math]::Max(20, [Math]::Min(90, $pbConfig.ThrottleThreshold))
                $proBalance.ThrottleThreshold = [double]$newThreshold
                Add-Log "- ProBalance: Loaded custom threshold $newThreshold%"
            }
        }
    } catch { }
    $loadPredictor = [LoadPredictor]::new()
    # Komponenty AI v9.0
    $selfTuner = [SelfTuner]::new()
    $chainPredictor = [ChainPredictor]::new()
    $contextDetector = [ContextDetector]::new()
    $phaseDetector = [PhaseDetector]::new()
    $sharedKnowledge = [SharedAppKnowledge]::new()
    $sharedKnowledge.LoadState($Script:ConfigDir)
    $fanController = [FanController]::new()
    $fanController.Initialize($Script:DataSourcesInfo.ActiveSource)
    if ($fanController.Enabled) {
        Add-Log "FanController: $($fanController.Source) | Read=$($fanController.CanRead) Control=$($fanController.CanControl) | Fans=$($fanController.FanSensorIds.Count)"
    }
    $thermalPredictor = [ThermalPredictor]::new()
    $userPatterns = [UserPatternLearner]::new()
    $adaptiveTimer = [AdaptiveTimer]::new()
    #  MEGA AI Components
    $qLearning = [QLearningAgent]::new()
    $ensemble = [EnsembleVoter]::new()
    $energyTracker = [EnergyTracker]::new()
    #  ULTRA AI Components
    $bandit = [MultiArmedBandit]::new()
    $genetic = [GeneticOptimizer]::new()
    $explainer = [DecisionExplainer]::new()
    $thermalGuard = [ThermalGuardian]::new()
    $webDashboard = [WebDashboard]::new($Global:WebDashboardPort)
    $desktopWidget = [DesktopWidget]::new()
    $aiCoordinator = [AICoordinator]::new()
    # v43.6: Zmienna do śledzenia zmian stanu Ensemble (knowledge transfer)
    $Script:LastEnsembleState = (Is-EnsembleEnabled)
    # - V35 NEW: RAM Analyzer - wykrywanie skokow RAM i uczenie sie aplikacji
    $ramAnalyzer = [RAMAnalyzer]::new()
    # - V37.8.2 NEW: Network Optimizer - optymalizacja sieci dla gier i przegladarek
    $networkOptimizer = [NetworkOptimizer]::new($Script:ConfigDir)
    $Script:NetworkOptimizerInstance = $networkOptimizer  # FIX v40.1: Zapisz jako Script scope dla hot-reload
    $networkAI = [NetworkAI]::new()
    # - V40 NEW: Process AI - uczenie sie zachowan procesow dla inteligentnego throttlingu
    $processAI = [ProcessAI]::new()
    # Zapisz stan ProcessAI od razu aby CONFIGURATOR mógł go odczytać bez czekania 5 minut
    [void]$processAI.SaveState($Script:ConfigDir)
    # v44.0: SystemGovernor - centralne zarządzanie CPU/GPU/procesami
    $systemGovernor = [SystemGovernor]::new()
    $systemGovernor.Initialize($Script:HasiGPU, $Script:HasdGPU, $Script:iGPUName, $Script:dGPUName)
    $systemGovernor.LoadState($Script:ConfigDir)
    Write-Host "  - SystemGovernor: ACTIVE (GPU/iGPU/Process/Power control)" -ForegroundColor Green
    # - V40 NEW: GPU AI - inteligentne zarządzanie GPU (iGPU/dGPU + power control)
    $gpuAI = [GPUAI]::new($Script:HasiGPU, $Script:HasdGPU, $Script:iGPUName, $Script:dGPUName, $Script:dGPUVendor)
    # V40.3 FIX: Nie zapisuj stanu od razu - najpierw załaduj stare dane!
    # LoadState zostanie wywołane poniżej (linia ~13431)
    # Widget uruchamiany zewnetrznie przez Widget_v40.ps1 (START_ALL.bat)
    # Klasa DesktopWidget uzywana tylko do zapisu danych do WidgetData.json
    # History for charts
    $cpuHistory = [System.Collections.Generic.List[int]]::new()
    $tempHistory = [System.Collections.Generic.List[int]]::new()
    # Load all states
    # Usunieto: $prophet.LoadState() i $brain.LoadState() - powodowaly podwojne wczytywanie
    $anomalyDetector.LoadProfiles($Script:ConfigDir)
    $loadPredictor.LoadPatterns($Script:ConfigDir)
    $selfTuner.LoadState($Script:ConfigDir)
    $chainPredictor.LoadState($Script:ConfigDir)
    $userPatterns.LoadState($Script:ConfigDir)
    $qLearning.LoadState($Script:ConfigDir)
    $ensemble.LoadState($Script:ConfigDir)
    $energyTracker.LoadState($Script:ConfigDir)
    $bandit.LoadState($Script:ConfigDir)
    $genetic.LoadState($Script:ConfigDir)
    # v43.14: Zastosuj Genetic learned thresholds (jeśli fitness > 0.5 = wiarygodne)
    if (Is-GeneticEnabled -and $genetic.BestGenome -and $genetic.BestFitness -gt 0.5) {
        $genTurbo = $genetic.BestGenome.TurboThreshold
        $genBalanced = $genetic.BestGenome.BalancedThreshold
        if ($genTurbo -and $genTurbo -ge 60 -and $genTurbo -le 95) {
            $Script:TurboThreshold = [int]$genTurbo
            Write-Host "  Genetic TurboThreshold applied: $genTurbo% (fitness=$([Math]::Round($genetic.BestFitness*100))%)" -ForegroundColor Cyan
        }
        if ($genBalanced -and $genBalanced -ge 20 -and $genBalanced -le 55) {
            $Script:BalancedThreshold = [int]$genBalanced
            Write-Host "  Genetic BalancedThreshold applied: $genBalanced% (fitness=$([Math]::Round($genetic.BestFitness*100))%)" -ForegroundColor Cyan
        }
    }
    $contextDetector.LoadState($Script:ConfigDir)
    $phaseDetector.LoadState($Script:ConfigDir)
    $thermalPredictor.LoadState($Script:ConfigDir)
    $explainer.LoadState($Script:ConfigDir)
    $thermalGuard.LoadState($Script:ConfigDir)
    # v43.14: Sync ThermalGuardian with config ThermalLimit
    if ($Script:ThermalLimit -and $Script:ThermalLimit -gt 60 -and $Script:ThermalLimit -lt 100) {
        $thermalGuard.CPULimit = $Script:ThermalLimit
        Write-Host "  ThermalGuardian CPULimit synced to config: $($Script:ThermalLimit)°C" -ForegroundColor Cyan
    }
    $aiCoordinator.LoadState($Script:ConfigDir)
    $ramAnalyzer.LoadState($Script:ConfigDir)
    # - V37.8.2: Network Optimizer - zaladuj stan i zainicjalizuj optymalizacje
    $networkOptimizer.LoadState($Script:ConfigDir)
    # - V40: Process AI - zaladuj stan
    $processAI.LoadState($Script:ConfigDir)
    # - V40: GPU AI - zaladuj stan
    $gpuAI.LoadState($Script:ConfigDir)
    if ($Script:NetworkOptimizerEnabled) {
        Write-Host "  [v40] NetworkOptimizer ENABLED - stosowanie optymalizacji sieci..." -ForegroundColor Cyan
        $networkOptimizer.Initialize()
        if (-not $Script:NetworkOptimizeDNS) {
            # Jeśli DNS ma być wyłączony, przywróć oryginalne
            $networkOptimizer.RestoreDNS()
            Write-Host "    DNS Cloudflare: WYŁĄCZONY (używam oryginalnego DNS)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [v40] NetworkOptimizer DISABLED - pomijam optymalizacje sieci" -ForegroundColor Yellow
        # Przywróć oryginalne ustawienia jeśli były zmienione
        $networkOptimizer.Restore()
    }
    $networkAI.LoadState($Script:ConfigDir)
    $networkAI.SaveState($Script:ConfigDir)

    # Merge AILearningState.json → SharedAppKnowledge (uzupełnij wiedzę z poprzedniej sesji)
    function Merge-AILearningSnapshot {
        param($SharedKnowledge, $ProcessAI, $NetworkAI)
        try {
            if (-not $Script:AILearningBuffer -or $Script:AILearningBuffer.Count -eq 0) { return }
            if (-not $SharedKnowledge) { return }
            $merged = 0
            foreach ($key in $Script:AILearningBuffer.Keys) {
                $v = $Script:AILearningBuffer[$key]
                $p = $SharedKnowledge.GetProfile($key)
                if ($v.AvgCPU -and $p.AvgCPU -eq 0) { $p.AvgCPU = [double]$v.AvgCPU }
                if ($v.AvgGPU -and $p.AvgGPU -eq 0) { $p.AvgGPU = [double]$v.AvgGPU }
                if ($v.BestMode -and -not $p.BestMode) { $p.BestMode = $v.BestMode }
                if ($v.Sessions -and $p.Sessions -eq 0) { $p.Sessions = [int]$v.Sessions }
                if ($v.QBestAction -and -not $p.QBestAction) { $p.QBestAction = $v.QBestAction }
                if ($v.QConfidence -and $p.QConfidence -eq 0) { $p.QConfidence = [double]$v.QConfidence }
                if ($v.Category -and -not $p.Category) { $p.Category = $v.Category }
                if ($v.PreferredGPU -and -not $p.PreferredGPU) { $p.PreferredGPU = $v.PreferredGPU }
                if ($v.DominantPhase -and -not $p.DominantPhase) { $p.DominantPhase = $v.DominantPhase }
                if ($v.ThermalRisk -and $v.ThermalRisk -ne "Low") { $p.ThermalRisk = $v.ThermalRisk }
                if ($v.PeakTemp -and [double]$v.PeakTemp -gt $p.PeakTemp) { $p.PeakTemp = [double]$v.PeakTemp }
                if ($v.Efficiency -and $p.Efficiency -eq 0) { $p.Efficiency = [double]$v.Efficiency }
                $SharedKnowledge.Apps[$key] = $p
                $merged++
            }
            if ($merged -gt 0) {
                Write-Host "  [AILearning] Merged $merged app profiles into SharedKnowledge" -ForegroundColor Green
            }
        } catch { }
    }

    # Merge przy starcie — uzupełnij SharedKnowledge wiedzą z AILearningState.json
    try { Merge-AILearningSnapshot -SharedKnowledge $sharedKnowledge -ProcessAI $processAI -NetworkAI $networkAI } catch {}

    # ═══════════════════════════════════════════════════════════════════════════
    # 1. MemoryAgressiveness (0-100) -> RAMAnalyzer SpikeThreshold
    # 0=conservative (threshold 12%), 50=neutral (8%), 100=aggressive (4%)
    if ($Script:MemoryAgressiveness -ne 30) {
        $memAggr = [Math]::Max(0, [Math]::Min(100, $Script:MemoryAgressiveness))
        # Map: 0->12, 50->8, 100->4
        $newSpikeThreshold = 12 - ($memAggr / 100.0) * 8
        $ramAnalyzer.SpikeThreshold = [Math]::Max(4, $newSpikeThreshold)
        $ramAnalyzer.MinSpikeThreshold = [Math]::Max(3, $newSpikeThreshold - 2)
        Write-Host "  RAMAnalyzer: SpikeThreshold=$([Math]::Round($ramAnalyzer.SpikeThreshold,1))% (MemoryAgressiveness=$memAggr)" -ForegroundColor Gray
    }
    # v40.2 FIX: MemoryCompression - obniża progi RAM spike i zwiększa wagę RAM w decyzjach AI
    if ($Script:MemoryCompression) {
        # Obniż spike threshold o 2% (bardziej czuły na wzrost RAM)
        $ramAnalyzer.SpikeThreshold = [Math]::Max(3, $ramAnalyzer.SpikeThreshold - 2)
        $ramAnalyzer.MinSpikeThreshold = [Math]::Max(2, $ramAnalyzer.MinSpikeThreshold - 1)
        # Zwiększ wagę RAM w Ensemble voting
        if ($ensemble -and $ensemble.Weights.ContainsKey("RAMMonitor")) {
            $ensemble.Weights["RAMMonitor"] = [Math]::Min(2.0, $ensemble.Weights["RAMMonitor"] + 0.3)
        }
        # ProBalance bardziej agresywnie ogranicza procesy zjadające RAM
        if ($proBalance) {
            $proBalance.ThrottleThreshold = [Math]::Max(50, $proBalance.ThrottleThreshold - 10)
        }
        Write-Host "  MemoryCompression: ACTIVE - spike=$([Math]::Round($ramAnalyzer.SpikeThreshold,1))%, ProBalance thr=$($proBalance.ThrottleThreshold)%" -ForegroundColor Cyan
    }
    # 2. IOPriority (1-5) -> IOCheckInterval
    # 1=slow (2000ms), 3=normal (1200ms), 5=fast (600ms)
    if ($Script:IOPriority -ne 3) {
        $ioPri = [Math]::Max(1, [Math]::Min(5, $Script:IOPriority))
        # Map: 1->2000, 3->1200, 5->600
        $Script:IOCheckInterval = [int](2000 - ($ioPri - 1) * 350)
        Write-Host "  I/O: CheckInterval=$($Script:IOCheckInterval)ms (IOPriority=$ioPri)" -ForegroundColor Gray
    }
    # 3. CacheSize -> Prophet max apps limit
    $Script:ProphetCacheLimit = [Math]::Max(20, [Math]::Min(200, $Script:CacheSize))
    if ($Script:CacheSize -ne 50) {
        Write-Host "  Prophet: CacheLimit=$($Script:ProphetCacheLimit) apps" -ForegroundColor Gray
    }
    # 4. PreBoostDuration -> stored for ChainPredictor/LoadPredictor
    if ($Script:PreBoostDuration -ne 15000) {
        Write-Host "  PreBoost: Duration=$($Script:PreBoostDuration)ms" -ForegroundColor Gray
    }
    # 5. Log optimization toggles status
    $optStatus = @()
    if ($Script:PreloadEnabled) { $optStatus += "Preload" }
    if ($Script:SmartPreload) { $optStatus += "SmartPreload" }
    if ($Script:PredictiveBoostEnabled) { $optStatus += "PredictiveBoost" }
    if ($Script:PredictiveIO) { $optStatus += "PredictiveIO" }
    if ($Script:MemoryCompression) { $optStatus += "MemCompress" }
    if ($Script:PowerBoost) { $optStatus += "PowerBoost" }
    if ($optStatus.Count -gt 0) {
        Write-Host "  Optimization: $($optStatus -join ', ')" -ForegroundColor Cyan
    }
    Write-Host "  Brain: $($brain.GetCount()) weights" -ForegroundColor Green
    Write-Host "  Prophet: $($prophet.GetAppCount()) apps" -ForegroundColor Green
    Write-Host "  Self-Tuner: $($selfTuner.GetStatus())" -ForegroundColor Green
    Write-Host "   Q-Learning: $($qLearning.GetStatus())" -ForegroundColor Magenta
    Write-Host "  - Bandit: $($bandit.GetStatus())" -ForegroundColor Magenta
    Write-Host "  - Genetic: $($genetic.GetStatus())" -ForegroundColor Magenta
    Write-Host "   Energy: $($energyTracker.GetStatus())" -ForegroundColor Magenta
    Write-Host "   AICoordinator: $($aiCoordinator.GetStatus())" -ForegroundColor Cyan
    Write-Host "  - RAMAnalyzer: $($ramAnalyzer.GetStatus())" -ForegroundColor Cyan
    Write-Host "  - ThermalGuard: Active (CPU<$($thermalGuard.CPULimit)C VRM<$($thermalGuard.VRMLimit)C)" -ForegroundColor Cyan
    Write-Host "  - ProBalance: Active (Threshold: $($proBalance.ThrottleThreshold)% CPU)" -ForegroundColor Yellow
    Write-Host "  - NetworkOptimizer: $($networkOptimizer.GetStatus())" -ForegroundColor Green
    Write-Host "   NetworkAI: $($networkAI.GetStatus())" -ForegroundColor Green
    Write-Host "   Explainer: Ready" -ForegroundColor Cyan
    # Extended metrics check
    try {
        # Prefer async-updated metrics when available
        if ($Script:LatestMetrics) { $extTest = $Script:LatestMetrics } else { $extTest = $metrics.GetExtended() }
        if ($extTest.GPU -and $extTest.GPU.Name -ne "N/A") {
            Write-Host "   GPU: $($extTest.GPU.Name)" -ForegroundColor Green
        } else {
            Write-Host "   GPU: Not detected (iGPU or no LHM)" -ForegroundColor Yellow
        }
        if ($extTest.VRM -and $extTest.VRM.Available) {
            Write-Host "  - VRM: Monitoring active" -ForegroundColor Green
        }
    } catch {
        Write-Host "   Extended metrics: Init failed" -ForegroundColor Yellow
    }
    # Start Web Dashboard
    Write-Host "  - Starting Web Dashboard on port $($Global:WebDashboardPort)..." -ForegroundColor Cyan
    try {
        $webDashboard.Start()
        if ($webDashboard.Running) {
            Write-Host "   Dashboard: http://localhost:$($Global:WebDashboardPort)" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Dashboard failed to start (port may be in use)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  [WARN] Dashboard error: $_" -ForegroundColor Yellow
    }
    # Check auto-start
    $autoStartEnabled = Test-CPUManagerTaskExists
    Write-Host "  - Auto-start: $(if($autoStartEnabled){'Enabled'}else{'Disabled'}) (press 9 to toggle)" -ForegroundColor $(if($autoStartEnabled){"Green"}else{"Gray"})
    # Pokaz info o zrodle danych
    $dataSourceInfo = $Script:DataSourcesInfo
    $srcColor = switch($dataSourceInfo.ActiveSource) { "LHM" {"Green"} "OHM" {"Yellow"} "SystemOnly" {"Red"} default {"Gray"} }
    Write-Host "  - Data source: $($dataSourceInfo.ActiveSource) | Temp: $($metrics.TempSource)" -ForegroundColor $srcColor
    Write-Host "`n  Press any key to start..." -ForegroundColor Yellow
    Start-Sleep -Milliseconds 1500
    $null = $metrics.Get()
    Start-Sleep -Milliseconds 500
    $manualMode = if ($Script:SavedManualMode) { $Script:SavedManualMode } else { "Balanced" }
    $iteration = 0
    $Script:LastWidgetWriteIteration = 0
    $Script:LastWidgetJSON = ""
    $Script:WidgetWriteThrottle = 2  # Zapisuj co 2 iteracje (~1.6-2s zamiast co 0.8s)
    $lastSave = 0
    $lastPriorityUpdate = 0
    $lastAnomalyCheck = 0
    $lastPrediction = 0
    $lastGC = 0
    $lastSelfTuneEval = 0
    $lastChainCheck = 0
    $lastDashboardUpdate = 0
    $lastGeneticEval = 0
    $lastProBalanceUpdate = 0
    $predictedLoad = 0
    $predictedApps = @()
    $anomalyAlert = ""
    $chainPrediction = ""
    $preBoostReason = ""
    $lastForegroundApp = ""
    $currentActiveApp = ""  # Aktualna aplikacja dla tooltip
    $currentState = "Balanced"
    $currentContext = "Idle"
    $isUserActive = $false
    $dynamicInterval = 800
    $prophetLastAutosave = [DateTime]::Now
    $prophetLastSavedSessions = $prophet.TotalSessions
    # Network monitoring
    $lastNetTime = [DateTime]::Now
    $netDownloadSpeed = 0
    $netUploadSpeed = 0
    $cpuCurrentMHz = 0
    # Extended monitoring for widget
    # === NETWORK TOTALS (Get-NetAdapterStatistics) ===
    $totalBytesRecv = [int64]0
    $totalBytesSent = [int64]0
    $ramUsedPercent = 0
    $diskReadSpeed = 0.0
    $diskWriteSpeed = 0.0
    $cpuLoadLHM = 0
    $Script:PersistentNetDL = [int64]0
    $Script:PersistentNetUL = [int64]0
    $networkStatsPath = Join-Path $Script:ConfigDir "NetworkStats.json"
    try {
        if (Test-Path $networkStatsPath) {
            $netStats = Get-Content $networkStatsPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($netStats) {
                $Script:PersistentNetDL = if ($netStats.TotalDownloaded) { [int64]$netStats.TotalDownloaded } else { 0 }
                $Script:PersistentNetUL = if ($netStats.TotalUploaded) { [int64]$netStats.TotalUploaded } else { 0 }
                Add-Log " NetworkStats loaded: DL=$([Math]::Round($Script:PersistentNetDL/1GB, 2))GB UL=$([Math]::Round($Script:PersistentNetUL/1GB, 2))GB"
            }
        }
    } catch { }
    $lastNetStatsSave = [DateTime]::Now
    # Smoothing variables (wygladzanie danych)
    $smoothNetDL = 0.0
    $smoothNetUL = 0.0
    $smoothDiskRead = 0.0
    $smoothDiskWrite = 0.0
    $smoothFactor = 0.3  # 0.1 = bardzo gladkie, 0.5 = szybka reakcja
    # MEGA AI State tracking
    $qState = ""
    $prevState = ""
    $prevTemp = 50.0
    Clear-Host
    [Console]::CursorVisible = $false
    Write-Host "`n#" -ForegroundColor DarkCyan
    Write-Host "  - CPU Detection" -ForegroundColor Cyan
    Write-Host "#" -ForegroundColor DarkCyan
    Detect-HybridCPU | Out-Null
    
    # ═══ BUILD CENTRAL HARDWARE PROFILE ═══
    $Script:HW = Build-HardwareProfile
    # Update GPU info po Detect-GPU (jeśli już było)
    if ($Script:HasdGPU) { $Script:HW.HasdGPU = $true; $Script:HW.dGPUVendor = $Script:dGPUVendor }
    Write-Host "  [HW] Tier $($Script:HW.Tier): $($Script:HW.Vendor) $($Script:HW.Model) $($Script:HW.Generation) ($($Script:HW.Cores)C/$($Script:HW.Threads)T) RAM=$($Script:HW.TotalRAM_GB)GB Storage=$($Script:HW.StorageType)" -ForegroundColor Yellow
    
    Write-Host ""
# Network adapters cache (v39.3 - fix busy cursor)
$Script:CachedNetAdapters = $null
$Script:PreviousNeuralBrainEnabled = $false
$Script:PreviousEnsembleEnabled = $false
    # ═══════════════════════════════════════════════════════════════
    # DISK WRITE CACHE — PrimoCache-like write-back
    # Wszystkie SaveState trafiają do RAM, flush 1-2 pliki/tick
    # ═══════════════════════════════════════════════════════════════
    $diskCache = [DiskWriteCache]::new($Script:ConfigDir)
    $Script:DiskWriteCache = $diskCache
    Write-Host "  [CACHE] DiskWriteCache: RAM write-back enabled (flush every 30s per file)" -ForegroundColor Cyan
    # ═══ APP RAM CACHE — prawdziwy preload aplikacji do RAM ═══
    $appRAMCache = [AppRAMCache]::new()
    $Script:AppRAMCache = $appRAMCache
    
    # Ustaw DiskCacheDir
    if ($Script:CacheDir) { $appRAMCache.DiskCacheDir = $Script:CacheDir }
    
    # Przekaż hardware profile — RAMCache dostosowuje strategię do maszyny
    if ($Script:HW) { 
        $appRAMCache.HW = $Script:HW
        $appRAMCache.ApplyHardwareProfile()
    }
    
    # 1. Załaduj poprzednią wiedzę (jeśli RAMCache.json istnieje)
    $appRAMCache.LoadState($Script:ConfigDir)
    Write-RCLog "═══ ENGINE START ═══"
    Write-RCLog "RAM: $([Math]::Round($appRAMCache.TotalSystemRAM/1024,1))GB detected → MaxCache=$($appRAMCache.MaxCacheMB)MB Guard=$($appRAMCache.GuardBandMB)/$($appRAMCache.GuardBandHeavyMB)MB Free=$([int]$appRAMCache.LastAvailableMB)MB"
    Write-RCLog "LoadState: Paths=$($appRAMCache.AppPaths.Count) Class=$($appRAMCache.AppClassification.Count) Aggr=$([Math]::Round($appRAMCache.Aggressiveness,2))"
    $rcJsonPath = Join-Path $Script:ConfigDir "RAMCache.json"
    $rcJsonExists = Test-Path $rcJsonPath
    $prophetAppsForCache = if ($prophet) { $prophet.Apps } else { $null }
    
    # 2. BOOTSTRAP: Skanuj running procesy — ucz się ścieżek i modułów OD RAZU
    $bootstrapCount = $appRAMCache.BootstrapScan($prophetAppsForCache)
    
    # 3. Zapisz RAMCache.json TYLKO gdy coś się zmieniło lub plik nie istnieje
    if ($appRAMCache.IsDirty -or -not $rcJsonExists) {
        $appRAMCache.SaveState($Script:ConfigDir)
        $appRAMCache.IsDirty = $false
    }
    $rcJsonNow = Test-Path $rcJsonPath
    
    if (-not $rcJsonExists -and $rcJsonNow) {
        Write-Host "  [CACHE] RAMCache.json CREATED — $bootstrapCount apps profiled at startup" -ForegroundColor Green
    }
    Write-Host "  [CACHE] AppRAMCache: RAM=$([Math]::Round($appRAMCache.TotalSystemRAM/1024,1))GB MaxCache=$($appRAMCache.MaxCacheMB)MB Guard=$($appRAMCache.GuardBandMB)/$($appRAMCache.GuardBandHeavyMB)MB Aggr=$([Math]::Round($appRAMCache.Aggressiveness,2)) Paths=$($appRAMCache.AppPaths.Count)" -ForegroundColor Cyan
    
    # 4. Startup preload — załaduj heavy apps typowe dla tej godziny (korzysta z nowo-nauczonej wiedzy)
    if ($prophet -and $chainPredictor) {
        $appRAMCache.StartupPreload($prophet.Apps, $prophet.HourlyActivity, $chainPredictor.TransitionGraph)
        if ($appRAMCache.CachedApps.Count -gt 0 -or $appRAMCache.BatchQueue.Count -gt 0) {
            Write-Host "  [CACHE] Startup preload: $($appRAMCache.CachedApps.Count) apps, $($appRAMCache.BatchQueue.Count) files queued" -ForegroundColor Green
        }
    }
    
    # 5. WARMUP — załaduj WSZYSTKIE znane apps z LEARNED profilem do RAM
    # Filozofia: wolny RAM = zmarnowany RAM. 500MB cache z 20GB limitu to marnowanie.
    # Bezpieczny: sprawdza RAM przed każdym preload, zatrzymuje się przy <25% free
    $warmupCount = $appRAMCache.WarmupAllKnown()
    if ($warmupCount -gt 0) {
        Write-Host "  [CACHE] Warmup: $warmupCount additional apps loaded, total cache=$([int]$appRAMCache.TotalCachedMB)MB/$($appRAMCache.MaxCacheMB)MB" -ForegroundColor Green
    }
    # ═══════════════════════════════════════════════════════════════
    # LAUNCH RACE: Śledzenie nowych procesów przez polling Get-Process
    # Niezawodne — nie wymaga WMI ani specjalnych uprawnień.
    # Co 2 iteracje (~1.6s) porównuje PID-y znanych appów z poprzednią
    # iteracją. Nowy PID = nowy proces = Launch Race start.
    # ═══════════════════════════════════════════════════════════════
    # Słownik: ProcessName → HashSet<int> znanych PID-ów z ostatniego sprawdzenia
    $lcRaceKnownPIDs = @{}
    # Cold-start: pierwsze 15s od startu ENGINE — procesy już działające są tylko
    # katalogowane. Po 15s KAŻDA nowa detekcja = świeże uruchomienie = Launch Race.
    $lcRaceColdUntil = [datetime]::Now.AddSeconds(15)
    Write-Host "  [CACHE] Launch Race: Process polling monitor active (~1.6s detection, 15s cold-start)" -ForegroundColor Cyan

    try {
        Write-Host "[DEBUG] Engine: starting main loop" -ForegroundColor Yellow
        while (-not $Global:ExitRequested) {
            # v43.14: Suppress non-terminating errors in main loop (Windows shutdown/sleep)
            $ErrorActionPreference = 'SilentlyContinue'

            # ── LAUNCH RACE: Wykrywanie nowych procesów przez polling ──
            # Co 2 iteracje (~1.6s): porównaj aktualne PID-y z poprzednimi.
            # Cold-start (pierwsze 15s): tylko kataloguj istniejące procesy.
            # Po cold-start: KAŻDA nowa detekcja app = właśnie uruchomiona = Launch Race.
            if ($appRAMCache -and $appRAMCache.Enabled -and ($iteration % 2 -eq 0)) {
                try {
                    $lcIsInColdStart = ([datetime]::Now -lt $lcRaceColdUntil)
                    $knownNames = @($appRAMCache.AppPaths.Keys) | Where-Object {
                        $_ -notmatch '^(pwsh|powershell|conhost|WindowsTerminal|ShellHost|explorer|dwm|svchost|csrss|lsass|winlogon|services|RuntimeBroker|SearchHost|StartMenuExperienceHost)$'
                    }
                    if ($knownNames.Count -gt 0) {
                        $currentKnownProcs = Get-Process -Name $knownNames -ErrorAction SilentlyContinue
                        foreach ($proc in $currentKnownProcs) {
                            $pName = $proc.ProcessName
                            $pId   = $proc.Id
                            if (-not $lcRaceKnownPIDs.ContainsKey($pName)) {
                                $lcRaceKnownPIDs[$pName] = [System.Collections.Generic.HashSet[int]]::new()
                                $lcRaceKnownPIDs[$pName].Add($pId) | Out-Null
                                # Cold-start: app działała przed ENGINE — tylko kataloguj
                                # Po cold-start: NOWA detekcja = użytkownik właśnie ją uruchomił
                                if (-not $lcIsInColdStart) {
                                    $prophetAppsRef2 = if ($prophet) { $prophet.Apps } else { $null }
                                    $appRAMCache.OnProcessLaunch($pName, $prophetAppsRef2)
                                }
                            } elseif (-not $lcRaceKnownPIDs[$pName].Contains($pId)) {
                                # Nowy PID dla już-śledzonej app = nowa instancja = restart/relaunch
                                $lcRaceKnownPIDs[$pName].Add($pId) | Out-Null
                                $prophetAppsRef2 = if ($prophet) { $prophet.Apps } else { $null }
                                $appRAMCache.OnProcessLaunch($pName, $prophetAppsRef2)
                            }
                        }
                        # Wyczyść martwe PID-y
                        foreach ($pName in @($lcRaceKnownPIDs.Keys)) {
                            $stillAlive = $currentKnownProcs | Where-Object { $_.ProcessName -eq $pName }
                            if ($stillAlive) {
                                $alivePIDs = [System.Collections.Generic.HashSet[int]]::new()
                                foreach ($p in $stillAlive) { $alivePIDs.Add($p.Id) | Out-Null }
                                $lcRaceKnownPIDs[$pName] = $alivePIDs
                            } else {
                                $lcRaceKnownPIDs.Remove($pName) | Out-Null
                            }
                        }
                    }
                } catch {}

                # ── LAUNCH RACE TICK: Agresywny preload podczas startu app ──
                if ($appRAMCache.IsInLaunchRace) {
                    $prophetAppsRef2 = if ($prophet) { $prophet.Apps } else { $null }
                    $appRAMCache.LaunchRaceTick($prophetAppsRef2) | Out-Null
                }
            }

            # Aktualizuj statystyki sieci co 10 iteracji (~10s) - totale sesji nie musza byc co sekunde
            if ($iteration % 10 -eq 0) {
            try {
                $adapters = Get-NetAdapterStatistics -ErrorAction SilentlyContinue | Where-Object { $_.ReceivedBytes -gt 0 -or $_.SentBytes -gt 0 }
                if ($adapters) {
                    $totalBytesRecv = ($adapters | Measure-Object -Property ReceivedBytes -Sum).Sum
                    $totalBytesSent = ($adapters | Measure-Object -Property SentBytes -Sum).Sum
                }
            } catch {
                # Windows shutting down / sleep / network unavailable - ignore
            }
            }
            # Process WinForms events for tray icon responsiveness
            [System.Windows.Forms.Application]::DoEvents()
            # Sprawdz czy uzytkownik chce wyjsc (z menu tray)
            if ($Global:ExitRequested) {
                Write-Host "`n  Zamykanie programu..." -ForegroundColor Yellow
                break
            }
            # === HOT-RELOAD CONFIG ===
            # v43.1: -Silent żeby nie zaśmiecać UI
            Check-ConfigReload -Silent | Out-Null
            # === CHECK AI ENGINES CONFIG + CPU CONFIG ===
            if (($iteration % 5) -eq 0) {
                #  Co 5 iteracji (~10 sekund) sprawdz AIEngines/CPU config (optymalizacja)
                $prevEnsemble = $Script:AIEngines.Ensemble
                $prevProphet = $Script:AIEngines.Prophet
                $prevNeuralBrain = $Script:AIEngines.NeuralBrain
                Load-AIEnginesConfig | Out-Null
                if ($Script:AIEngines.Ensemble -ne $prevEnsemble) {
                    $status = if ($Script:AIEngines.Ensemble) { "ON" } else { "OFF" }
                    Add-Log " AI Engine: Ensemble = $status"
                    
                    # v43.7: KNOWLEDGE TRANSFER - przekazanie wiedzy między silnikami AI
                    if ($Script:AIEngines.Ensemble) {
                        # ENSEMBLE WŁĄCZONY → pobierz wiedzę ze wszystkich aktywnych silników
                        try {
                            # v43.8: Używamy AICoordinator zamiast oddzielnych funkcji
                            $transferData = $aiCoordinator.TransferFromQLearning($qLearning)
                            $aiCoordinator.IntegrateProphetData($prophet, $transferData)
                            $aiCoordinator.IntegrateGPUBoundData($gpuBound, $transferData)
                            $aiCoordinator.IntegrateBanditData($bandit, $transferData)
                            $aiCoordinator.IntegrateGeneticData($genetic, $transferData)
                            $aiCoordinator.ApplyEnrichedToEnsemble($ensemble, $transferData)
                            
                            Add-Log "   Knowledge Transfer → Ensemble: QLearning + extensions"
                        } catch {
                            Add-Log "[WARN] Knowledge transfer → Ensemble failed: $_" -Warning
                        }
                    } else {
                        # ENSEMBLE WYŁĄCZONY → przekaż wiedzę z powrotem do podstawowych silników
                        try {
                            # v43.8: Używamy AICoordinator zamiast oddzielnych funkcji
                            $aiCoordinator.TransferBackFromEnsemble($ensemble, $qLearning, $prophet)
                            
                            Add-Log "   Knowledge Transfer Ensemble →: Q-Learning, Prophet"
                        } catch {
                            Add-Log "[WARN] Knowledge transfer Ensemble → failed: $_" -Warning
                        }
                    }
                }
                if ($Script:AIEngines.Prophet -ne $prevProphet) {
                    $status = if ($Script:AIEngines.Prophet) { "ON" } else { "OFF" }
                    Add-Log " AI Engine: Prophet = $status"
                }
                if ($Script:AIEngines.NeuralBrain -ne $prevNeuralBrain) {
                    $status = if ($Script:AIEngines.NeuralBrain) { "ON" } else { "OFF" }
                    Add-Log " AI Engine: NeuralBrain = $status"
                    
                    # v43.8: KNOWLEDGE TRANSFER - NeuralBrain
                    if ($Script:AIEngines.NeuralBrain) {
                        # NEURAL BRAIN WŁĄCZONY → pobierz wiedzę
                        try {
                            # v43.8: Używamy AICoordinator zamiast oddzielnych funkcji
                            $transferData = $aiCoordinator.TransferFromQLearning($qLearning)
                            $aiCoordinator.IntegrateProphetData($prophet, $transferData)
                            $aiCoordinator.ApplyToNeuralBrain($brain, $transferData)
                            
                            Add-Log "   Knowledge Transfer → NeuralBrain: Q-Learning, Prophet"
                        } catch {
                            Add-Log "[WARN] Knowledge transfer → NeuralBrain failed: $_" -Warning
                        }
                    } else {
                        # NEURAL BRAIN WYŁĄCZONY → przekaż wiedzę z powrotem
                        try {
                            # v43.8: Używamy AICoordinator zamiast oddzielnych funkcji
                            $aiCoordinator.TransferBackFromBrain($brain, $qLearning)
                            
                            Add-Log "   Knowledge Transfer NeuralBrain →: Q-Learning"
                        } catch {
                            Add-Log "[WARN] Knowledge transfer NeuralBrain → failed: $_" -Warning
                        }
                    }
                }
                # Sync AICoordinator enabled flags z $Script:AIEngines (zawsze, nie tylko przy zmianie)
                if ($aiCoordinator) {
                    $aiCoordinator.SetEnsembleEnabled((Is-EnsembleEnabled))
                    $aiCoordinator.SetNeuralBrainEnabled((Is-NeuralBrainEnabled))
                }
                # Sprawdz czy zmieniono typ CPU
                if (Test-Path $Script:CPUConfigPath) {
                    try {
                        $cpuCfg = Get-Content $Script:CPUConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
                        if ($cpuCfg.CPUType -and $cpuCfg.CPUType -ne $Script:CPUType) {
                            $Script:CPUType = $cpuCfg.CPUType
                            Add-Log "- CPU: Zmieniono na $($Script:CPUType)"
                        }
                    } catch {}
                }
            }
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            # Get metrics with error handling (extended for GPU/VRM)
            try {
                # Read latest async metrics with a short try-enter lock fallback
                if ($Script:LatestMetrics -and [System.Threading.Monitor]::TryEnter($Script:MetricsLock, 20)) {
                    try { $currentMetrics = $Script:LatestMetrics } finally { [System.Threading.Monitor]::Exit($Script:MetricsLock) }
                } else {
                    # FIX v40.1: Fallback musi używać GetExtended() żeby mieć GPU data!
                    $currentMetrics = $metrics.GetExtended()
                }
            } catch {
                # Blok catch dodany automatycznie (naprawa krytycznego bledu skladni)
                $currentMetrics = @{ CPU = 10; Temp = 50; IO = 0; GPU = @{Temp=0;Load=0}; VRM = @{Temp=0}; RAMUsage = 0 }
            }
            # ThermalGuardian: usunięty z pętli (v43.13) - duplikował ThermalPredictor
            # Ochronę termiczną zapewnia: hardcoded Temp>90→Silent + ThermalPredictor score
            # - Network speed monitoring + Total counters
            try {
                # Eliminacja busy cursor przy starcie ENGINE
                # Najpierw: odbierz wynik poprzedniego async query jesli gotowy
                if ($Script:NetAdaptersAsyncPS -and $Script:NetAdaptersAsyncResult) {
                    try {
                        if ($Script:NetAdaptersAsyncResult.IsCompleted) {
                            try {
                                $result = $Script:NetAdaptersAsyncPS.EndInvoke($Script:NetAdaptersAsyncResult)
                                if ($result) { $Script:CachedNetAdapters = $result }
                            } catch { }
                            $Script:NetAdaptersAsyncPS.Dispose()
                            $Script:NetAdaptersAsyncPS = $null
                            $Script:NetAdaptersAsyncResult = $null
                        }
                    } catch {
                        try { $Script:NetAdaptersAsyncPS.Dispose() } catch { }
                        $Script:NetAdaptersAsyncPS = $null
                        $Script:NetAdaptersAsyncResult = $null
                    }
                }
                if (($iteration % 5) -eq 0 -or -not $Script:CachedNetAdapters) {
                    # Asynchroniczny update cache - tylko gdy poprzedni juz skonczony
                    if (-not $Script:NetAdaptersAsyncPS) {
                    try {
                        $psNet = [powershell]::Create()
                        $null = $psNet.AddScript({
                            try {
                                $adapters = Get-CimInstance -ClassName Win32_PerfRawData_Tcpip_NetworkInterface -ErrorAction SilentlyContinue |
                                    Where-Object {
                                        ($_.Name -notmatch 'loopback|virtual|vmware|tunnel|teredo|pseudo|isatap|bluetooth|miniport|hyper-v|container' -and
                                        $_.BytesReceivedPersec -ge 0 -and $_.BytesSentPersec -ge 0)
                                    }
                                return $adapters
                            } catch {
                                return $null
                            }
                        })
                        # BeginInvoke - asynchroniczne wykonanie (NIE blokuje!)
                        $Script:NetAdaptersAsyncPS = $psNet
                        $Script:NetAdaptersAsyncResult = $psNet.BeginInvoke()
                    } catch {
                        # W razie bledu - uzyj starego cache
                        if ($psNet) { try { $psNet.Dispose() } catch {} }
                    }
                    }
                }
                $netAdapters = $Script:CachedNetAdapters
                if ($netAdapters) {
                    # BytesReceivedPersec i BytesSentPersec to juz wartosci per second!
                    # Nie trzeba obliczac roznicy ani dzielic przez czas
                    $currentRecv = ($netAdapters | Measure-Object -Property BytesReceivedPersec -Sum).Sum
                    $currentSent = ($netAdapters | Measure-Object -Property BytesSentPersec -Sum).Sum
                    $currentTime = [DateTime]::Now
                    $timeDiff = ($currentTime - $lastNetTime).TotalSeconds
                    if ($timeDiff -gt 0.5) {
                        # Predkosc: uzywaj bezposrednio Persec values
                        $rawDL = [math]::Max(0, $currentRecv)
                        $rawUL = [math]::Max(0, $currentSent)
                        # Wygladzanie eksponencjalne (EMA) - minimalizuje skoki
                        $smoothNetDL = $smoothNetDL * (1 - $smoothFactor) + $rawDL * $smoothFactor
                        $smoothNetUL = $smoothNetUL * (1 - $smoothFactor) + $rawUL * $smoothFactor
                        $netDownloadSpeed = $smoothNetDL
                        $netUploadSpeed = $smoothNetUL
                        # Win32_PerfRawData_Tcpip_NetworkInterface NIE MA BytesReceived (tylko Persec)
                        # Musimy sami sumowac: bytes = rate * time
                        $bytesRecvThisInterval = [int64]($currentRecv * $timeDiff)
                        $bytesSentThisInterval = [int64]($currentSent * $timeDiff)
                        if ($bytesRecvThisInterval -gt 0 -or $bytesSentThisInterval -gt 0) {
                            $totalBytesRecv += $bytesRecvThisInterval
                            $totalBytesSent += $bytesSentThisInterval
                        }
                        if ($iteration % 60 -eq 0) {
                            $adaptersCount = if ($netAdapters) { @($netAdapters).Count } else { 0 }
                            Add-Log "- Network: Adapters=$adaptersCount DL=$([Math]::Round($smoothNetDL/1MB, 2))MB/s UL=$([Math]::Round($smoothNetUL/1MB, 2))MB/s Raw=$([Math]::Round($currentRecv/1MB, 2))/$([Math]::Round($currentSent/1MB, 2)) Session=$([Math]::Round($totalBytesRecv/1MB, 0))MB" -Debug
                        }
                    }
                    $lastNetTime = $currentTime
                } else {
                    if ($iteration % 60 -eq 0) {
                        Add-Log "[WARN] Network: No adapters found (all filtered out?)" -Debug
                    }
                }
            } catch { }
            #  RAM usage monitoring
            try {
                $os = Get-OSCached
                if ($os) {
                    $totalMem = $os.TotalVisibleMemorySize
                    $freeMem = $os.FreePhysicalMemory
                    $ramUsedPercent = [int](100 - ($freeMem / $totalMem * 100))
                }
            } catch { }
            # - Disk Read/Write speed monitoring (bytes/s)
            try {
                $diskPerf = Get-DiskPerfCached
                if ($diskPerf) {
                    # Osobno Read i Write - z null check
                    $rawDiskRead = if ($null -ne $diskPerf.DiskReadBytesPersec) { [int64]$diskPerf.DiskReadBytesPersec } else { 0 }
                    $rawDiskWrite = if ($null -ne $diskPerf.DiskWriteBytesPersec) { [int64]$diskPerf.DiskWriteBytesPersec } else { 0 }
                    # Wygladzanie eksponencjalne
                    $smoothDiskRead = $smoothDiskRead * (1 - $smoothFactor) + $rawDiskRead * $smoothFactor
                    $smoothDiskWrite = $smoothDiskWrite * (1 - $smoothFactor) + $rawDiskWrite * $smoothFactor
                    $diskReadSpeed = [int64]$smoothDiskRead
                    $diskWriteSpeed = [int64]$smoothDiskWrite
                }
            } catch {
                # Fallback: Try alternative method
                try {
                    $diskIO = Get-DiskCounterCached  #  v39.3: Cached
                    if ($diskIO) {
                        $rawDisk = $diskIO.CounterSamples[0].CookedValue
                        $smoothDiskRead = $smoothDiskRead * (1 - $smoothFactor) + ($rawDisk / 2) * $smoothFactor
                        $smoothDiskWrite = $smoothDiskWrite * (1 - $smoothFactor) + ($rawDisk / 2) * $smoothFactor
                        $diskReadSpeed = [int64]$smoothDiskRead
                        $diskWriteSpeed = [int64]$smoothDiskWrite
                    }
                } catch { }
            }
            #  CPU current speed - NAPRAWIONA METODA dla AMD/Intel
            try {
                $cpuCurrentMHz = 0
                # Metoda 1: LibreHardwareMonitor - PRIORYTET (najdokladniejsze)
                try {
                    $lhmSensors = Get-LHMSensorsCached
                    if ($lhmSensors) {
                        # Filtruj TYLKO sensory CPU Clock
                        $cpuClocks = $lhmSensors | Where-Object { 
                            $_.SensorType -eq "Clock" -and 
                            ($_.Identifier -match "/amdcpu/|/intelcpu/") -and
                            $_.Name -match "Core #\d" -and
                            $_.Value -gt 100
                        }
                        if ($cpuClocks -and $cpuClocks.Count -gt 0) {
                            $avgClock = ($cpuClocks | Measure-Object -Property Value -Average).Average
                            if ($avgClock -gt 100) {
                                $cpuCurrentMHz = [int]$avgClock
                            }
                        }
                        # Pobierz CPU Load z LHM
                        $lhmLoad = $lhmSensors | Where-Object { 
                            $_.SensorType -eq "Load" -and $_.Name -eq "CPU Total"
                        } | Select-Object -First 1
                        if ($lhmLoad) {
                            $cpuLoadLHM = [int]$lhmLoad.Value
                        }
                    }
                } catch { }
                # Metoda 2: PercentProcessorPerformance * MaxClock (najlepsza bez LHM!)
                if ($cpuCurrentMHz -eq 0 -or $cpuCurrentMHz -lt 100) {
                    try {
                        $cpuWmi = Get-CPUInfoCached
                        $perfData = Get-ProcessorPerfCached  #  v39.3: Cached (bylo niebuforowane!)
                        if ($cpuWmi -and $perfData -and $perfData.PercentProcessorPerformance -gt 0) {
                            $maxClock = $cpuWmi.MaxClockSpeed
                            $perfPercent = $perfData.PercentProcessorPerformance
                            $cpuCurrentMHz = [int]($maxClock * $perfPercent / 100)
                        }
                    } catch { }
                }
                # Metoda 3: Registry - bazowa czestotliwosc
                if ($cpuCurrentMHz -eq 0 -or $cpuCurrentMHz -lt 100) {
                    try {
                        $regPath = "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0"
                        $regMHz = (Get-ItemProperty -Path $regPath -Name "~MHz" -ErrorAction SilentlyContinue)."~MHz"
                        if ($regMHz -and $regMHz -gt 100) {
                            $cpuCurrentMHz = [int]$regMHz
                        }
                    } catch { }
                }
                # Metoda 4: Performance Counter - Processor Frequency
                if ($cpuCurrentMHz -eq 0 -or $cpuCurrentMHz -lt 100) {
                    try {
                        $counter = Get-Counter '\Processor Information(_Total)\Processor Frequency' -ErrorAction SilentlyContinue
                        if ($counter -and $counter.CounterSamples[0].CookedValue -gt 100) {
                            $cpuCurrentMHz = [int]$counter.CounterSamples[0].CookedValue
                        }
                    } catch { }
                }
                # Metoda 5: CurrentClockSpeed z WMI
                if ($cpuCurrentMHz -eq 0 -or $cpuCurrentMHz -lt 100) {
                    try {
                        $cpuInfo = Get-CPUInfoCached
                        if ($cpuInfo -and $cpuInfo.CurrentClockSpeed -gt 0) {
                            $cpuCurrentMHz = [int]$cpuInfo.CurrentClockSpeed
                        }
                    } catch { }
                }
                # Metoda 6: Fallback - MaxClockSpeed
                if ($cpuCurrentMHz -eq 0 -or $cpuCurrentMHz -lt 100) {
                    try {
                        $cpuInfo = Get-CPUInfoCached
                        if ($cpuInfo) {
                            $cpuCurrentMHz = [int]$cpuInfo.MaxClockSpeed
                        }
                    } catch { }
                }
            } catch { }
            $cpuForForecaster = if ($cpuLoadLHM -gt 0) { $cpuLoadLHM } else { [int]$currentMetrics.CPU }
            [void]$forecaster.Add($cpuForForecaster)
            # Update history for dashboard
            [void]$cpuHistory.Add([int]$cpuForForecaster)
            [void]$tempHistory.Add([int]$currentMetrics.Temp)
            if ($cpuHistory.Count -gt 60) { $cpuHistory.RemoveAt(0) }
            if ($tempHistory.Count -gt 60) { $tempHistory.RemoveAt(0) }
            # Chain Predictor - sledz zmiany aplikacji na pierwszym planie
            $currentForeground = Get-ForegroundProcessName
            if (-not [string]::IsNullOrWhiteSpace($currentForeground) -and 
                $currentForeground -ne $lastForegroundApp -and
                -not $Script:BlacklistSet.Contains($currentForeground)) {
                # v42.6: Sprawdź czy Chain włączone
                if (Is-ChainEnabled) {
                    [void]$chainPredictor.RecordAppLaunch($currentForeground)
                }
                [void]$userPatterns.RecordAppUsage($currentForeground)
                    # v47.3: #5 Anti-AltTab — chroń poprzednią app po przełączeniu
                    if ($appRAMCache -and -not [string]::IsNullOrWhiteSpace($lastForegroundApp)) {
                        $appRAMCache.RecordFocusChange($currentForeground, $lastForegroundApp)
                    }
                $lastForegroundApp = $currentForeground
                    # v47.3: RAMCache — sprawdź hit + ucz się mapowania nazw
                    if ($appRAMCache -and $appRAMCache.Enabled) {
                        # Ucz się mapowania DisplayName → ProcessName
                        # Używamy danych zapisanych przez Get-ForegroundProcessName (anti-race-condition)
                        # zamiast ponownego GetForegroundWindow() który mógłby dostać już inną app
                        try {
                            $procName = $Script:LastFgRawProcName
                            $procPath = $Script:LastFgRawProcPath
                            if (-not [string]::IsNullOrWhiteSpace($procName)) {
                                $appRAMCache.LearnName($currentForeground, $procName)
                                # Ucz się ścieżki pod ProcessName (nie DisplayName)
                                # v43.15: pomijaj junk paths (VS Code extensions, temp instalatory)
                                if (-not $appRAMCache.AppPaths.ContainsKey($procName) -and $procPath -and
                                    -not $appRAMCache.IsJunkExePath($procPath)) {
                                    $appRAMCache.AppPaths[$procName] = @{ ExePath = $procPath; Dir = [System.IO.Path]::GetDirectoryName($procPath) }
                                }
                            }
                        } catch {}
                        
                        if ($appRAMCache.IsAppCached($currentForeground)) {
                            if ($Global:DebugMode) { Add-Log "- RAMCache: HIT '$currentForeground' (was preloaded)" }
                            # HIT: app jest w cache, ale mogą być jeszcze pliki w BatchQueue
                            # Przesuń je do PriorityQueue — zostaną załadowane jak najszybciej
                            $appRAMCache.ElevateToPriority($currentForeground)
                            # v47.4: HIT parent → załaduj/elevate znane dzieci
                            $appRAMCache.PreloadChildApps($currentForeground)
                        } else {
                            # MISS — załaduj pod resolved name
                            $resolved = $appRAMCache.ResolveAppName($currentForeground)
                            if ($resolved -ne "Desktop" -and $resolved -notmatch '^(pwsh|powershell)$') {
                                # PRIORYTET 1: DiskCache (instant — pliki z C:\CPUManager\Cache\)
                                $loadedFromDisk = $appRAMCache.LoadAppFromDiskCache($resolved)

                                if (-not $loadedFromDisk) {
                                    # PRIORYTET 2: PreloadApp z oryginalnych ścieżek (wolniejsze)
                                    $exePath = ""
                                    if ($appRAMCache.AppPaths.ContainsKey($resolved)) {
                                        $exePath = $appRAMCache.AppPaths[$resolved].ExePath
                                    } elseif ($performanceBooster -and $performanceBooster.AppExecutablePaths.ContainsKey($currentForeground)) {
                                        $exePath = $performanceBooster.AppExecutablePaths[$currentForeground]
                                    }
                                    if ($exePath) {
                                        $appRAMCache.PreloadApp($resolved, $exePath, 1.0) | Out-Null
                                    }
                                }
                                # Po załadowaniu do BatchQueue — natychmiast przesuń do PriorityQueue
                                # Pliki aktywnej app będą załadowane w NASTĘPNYM ticku, nie za kilkanaście
                                $appRAMCache.ElevateToPriority($resolved)
                                # Profiluj moduły (uczy się DLL → SaveAppToDiskCache przy BatchTick complete)
                                $appRAMCache.ProfileAppModules($resolved)
                                # v47.4: MISS parent → załaduj znane dzieci
                                $appRAMCache.PreloadChildApps($resolved)
                            }
                        }
                    }
                    if ($performanceBooster.IsHeavyApp($currentForeground) -or 
                    ($prophet.Apps.ContainsKey($currentForeground) -and $prophet.Apps[$currentForeground].IsHeavy)) {
                    # 1. Priority Boost
                    [void]$performanceBooster.BoostProcessPriority($currentForeground)
                    # 2. Memory pre-allocation
                    [void]$performanceBooster.PreallocateMemory($currentForeground)
                    # 3. Disk cache warming (safe wrapper to avoid duplicates)
                    SafeWarm $currentForeground
                    # 4. Freeze background processes (aggressive mode for games)
                    if ($performanceBooster.BackgroundFreezeEnabled) {
                        $frozenCount = $performanceBooster.FreezeBackgroundProcesses($currentForeground)
                        if ($frozenCount -gt 0) {
                            Add-Log "- PERF: Froze $frozenCount bg processes for $currentForeground"
                        }
                    }
                    Add-Log "- PERF: Boosted $currentForeground (Pri+Cache+Mem)"
                }
                if ($Global:DebugMode) {
                    Add-Log "- CHAIN: $currentForeground" -Debug
                }
            }
            if ($iteration % 5 -eq 0) {  # Co 5 iteracji (~10s)
                $preemptiveResult = $performanceBooster.CheckPreemptiveBoost($prophet, $chainPredictor)
                if ($preemptiveResult.ShouldBoost) {
                    # Pre-boost: przygotuj system PRZED uruchomieniem
                    [void]$performanceBooster.PreallocateMemory($preemptiveResult.App)
                    SafeWarm $preemptiveResult.App
                    # Jeśli AI aktywne, włącz Turbo preemptively
                    if ($Global:AI_Active -and $currentState -ne "Turbo") {
                        Set-PowerMode -Mode "Balanced" -CurrentCPU $currentMetrics.CPU
                        Add-Log "- PREEMPT: $($preemptiveResult.Reason)"
                    }
                }
                # Cleanup PerformanceBooster
                $performanceBooster.Cleanup()
            }
            # Aktualizuj nowe komponenty AI
            [void]$contextDetector.UpdateActiveApps($currentForeground, $currentMetrics.CPU)
            # Dodaj raw ProcessName do ActiveApps (np. "TormentedSouls2-Win64-Shipping")
            # Cache: sprawdzaj Get-Process tylko gdy zmienil sie uchwyt okna
            try {
                $hwnd2 = [Win32]::GetForegroundWindow()
                if ($hwnd2 -ne [IntPtr]::Zero) {
                    if ($hwnd2 -ne $Script:LastFgHwndRaw) {
                        $Script:LastFgHwndRaw = $hwnd2
                        $pid3 = 0; [Win32]::GetWindowThreadProcessId($hwnd2, [ref]$pid3) | Out-Null
                        $Script:LastFgRawPN = if ($pid3 -gt 0) { (Get-Process -Id $pid3 -ErrorAction SilentlyContinue).ProcessName } else { $null }
                    }
                    if ($Script:LastFgRawPN -and $Script:LastFgRawPN -ne $currentForeground) {
                        [void]$contextDetector.UpdateActiveApps($Script:LastFgRawPN, $currentMetrics.CPU)
                    }
                }
            } catch {}
            $ctxGpuLoad = if ($currentMetrics.GPU) { $currentMetrics.GPU.Load } else { 0 }
            $ctxIoTotal = $diskReadMB + $diskWriteMB
            $currentContext = $contextDetector.DetectContext($currentMetrics.CPU, $ctxGpuLoad, $ctxIoTotal)
            $Script:CurrentAppContext = $currentContext  # v43.14: Expose to CalcReward for Audio/Gaming awareness
            
            # v43.14: Periodic Knowledge Transfer (every 150 iterations ≈ 5 min)
            # Transfers Q-Learning + Prophet → TransferCache, NIEZALEŻNIE od Ensemble
            if (($iteration % 150) -eq 0 -and $iteration -gt 0) {
                try {
                    if ($aiCoordinator.ShouldTransferKnowledge($qLearning.TotalUpdates)) {
                        $transferData = $aiCoordinator.TransferFromQLearning($qLearning)
                        $aiCoordinator.IntegrateProphetData($prophet, $transferData)
                        $aiCoordinator.IntegrateGPUBoundData($gpuBound, $transferData)
                        $aiCoordinator.IntegrateBanditData($bandit, $transferData)
                        $aiCoordinator.IntegrateGeneticData($genetic, $transferData)
                        # Save TransferCache
                        $transferData | ConvertTo-Json -Depth 5 | Set-Content "$($Script:ConfigDir)\TransferCache.json" -Encoding UTF8 -Force
                        Add-Log "  PERIODIC Knowledge Transfer #$($aiCoordinator.TransferCount): Q→Prophet→SK"
                    }
                } catch {}
            }
            # PhaseDetector - wykrywanie fazy aplikacji (Loading/Gameplay/Menu/Cutscene/Idle)
            $ioForPhase = $diskReadMB + $diskWriteMB
            $gpuForPhase = if ($currentMetrics.GPU) { $currentMetrics.GPU.Load } else { 0 }
            $phaseDetector.Update($currentForeground, $currentMetrics.CPU, $gpuForPhase, $ioForPhase, $currentMetrics.Temp)
            [void]$thermalPredictor.RecordSample($currentMetrics.Temp, $currentMetrics.CPU, $currentForeground)
            
            # NetworkAI - przewidywanie optymalnej konfiguracji sieci (co 5 iteracji ~10s)
            if ($iteration % 5 -eq 0 -and ![string]::IsNullOrWhiteSpace($currentForeground)) {
                try {
                    $isGaming = ($currentContext -eq "Gaming")
                    $networkResult = $networkAI.Update($currentForeground, $netDownloadSpeed, $netUploadSpeed, $currentContext, $isGaming)
                    # v43.13: Zachowaj wynik NetworkAI do użycia w modelScores
                    if ($networkResult -and $networkResult.PredictedMode) {
                        $Script:LastNetworkAIMode = $networkResult.PredictedMode
                    }
                    
                    # Debug log co 60 iteracji (~2 minuty) 
                    if ($Global:DebugMode -and $iteration % 60 -eq 0) {
                        $dlMBps = [Math]::Round($netDownloadSpeed / 1MB, 2)
                        $ulMBps = [Math]::Round($netUploadSpeed / 1MB, 2)
                        Add-Log "- NetworkAI: $currentForeground Mode=$($networkResult.PredictedMode) Type=$($networkResult.NetworkType) DL=${dlMBps}MB/s UL=${ulMBps}MB/s" -Debug
                    }
                } catch {
                    # Silent fail - nie przerywaj glownej petli
                }
            }
            
            # ═══════════════════════════════════════════════════════════════════════════
            # PROPHET CONTINUOUS LEARNING - Ciągłe uczenie podczas pracy aplikacji
            # Co 5 iteracji (~10 sekund) aktualizuj dane o aktywnej aplikacji
            # ═══════════════════════════════════════════════════════════════════════════
            if ($iteration % 5 -eq 0 -and (Is-ProphetEnabled) -and $currentForeground -and 
                -not [string]::IsNullOrWhiteSpace($currentForeground) -and
                -not $Script:BlacklistSet.Contains($currentForeground)) {
                try {
                    # Pobierz DisplayName dla czytelności logów
                    $displayName = Get-FriendlyAppName -ProcessName $currentForeground
                    
                    # Aktualizuj Prophet z bieżącymi metrykami
                    $prophet.UpdateRunning($currentForeground, $currentMetrics.CPU, $currentMetrics.IO, $displayName)
                    
                    # Debug log co 30 iteracji (~1 minuta)
                    if ($Global:DebugMode -and $iteration % 30 -eq 0 -and $prophet.Apps.ContainsKey($currentForeground)) {
                        $appInfo = $prophet.Apps[$currentForeground]
                        $cleanCategory = $appInfo.Category -replace "^LEARNING_", ""
                        $confidence = if ($prophet.IsCategoryConfident($currentForeground)) { "CONF" } else { "LEARN" }
                        $samples = if ($appInfo.ContainsKey('Samples')) { $appInfo.Samples } else { 0 }
                        Add-Log "- Prophet Update: $displayName = $cleanCategory ($confidence) Samples=$samples AvgCPU=$([Math]::Round($appInfo.AvgCPU))% MaxCPU=$([Math]::Round($appInfo.MaxCPU))%" -Debug
                    }
                } catch {
                    # Silent fail - nie przerywaj głównej pętli
                }
            }
            
            $isUserActive = Update-ActivityStatus
            [void]$userPatterns.RecordSample($currentMetrics.CPU, $currentMetrics.Temp, $currentContext, $currentState, $isUserActive)
            # UWAGA: Wymuszenie Silent w Idle przeniesiono na koniec pętli (po decyzji AI)
            # Poprzednia wersja tutaj była nadpisywana przez reset $aiDecision/$currentState = "Balanced"
            # Oblicz dynamiczny interwal
            $dynamicInterval = $adaptiveTimer.CalculateInterval($currentContext, $isUserActive, $watcher.IsBoosting, $currentMetrics.CPU)
            [void]$loadPredictor.RecordSample($currentMetrics.CPU, $currentMetrics.IO)
            $cpuSpike = [Math]::Max(0, $currentMetrics.CPU - $Script:LastCPU)
            $Script:LastCPU = [int][Math]::Round($currentMetrics.CPU)
            # v40.4: SPIKE OVERRIDE - gwaltowny skok CPU (>25pp) wymusza natychmiastowe krotkie okno
            # Reaguje jak Windows scheduler - nie czeka na nastepny cykl AdaptiveTimer
            if ($cpuSpike -gt 25 -and $dynamicInterval -gt 300 -and -not ($currentContext -eq "Idle" -and -not $isUserActive)) {
                $dynamicInterval = 200
            }
            if ($iteration - $lastPrediction -ge 30) {
                $lastPrediction = $iteration
                $predictedLoad = $loadPredictor.PredictNextMinute()
                $predictedApps = $loadPredictor.PredictNextApps($prophet)
                if ($predictedLoad -gt 60 -and -not $watcher.IsBoosting) {
                    if ($Global:DebugMode) {
                        Add-Log " PREDICT: High load ($([Math]::Round($predictedLoad)))% - pre-boost" -Debug
                    }
                    # Nie podnoś trybu jeśli Idle wymusza Silent
                    if (!($currentContext -eq "Idle" -and -not $isUserActive)) {
                        Set-PowerMode -Mode "Balanced" -CurrentCPU $currentMetrics.CPU
                    }
                }
            }
            #  FIXED: Boost dziala ZAWSZE - niezaleznie od stanu AI!
            # Uzytkownik w trybie manualnym tez powinien miec Boost dla nowych aplikacji
            if (-not $watcher.IsBoosting) {
                $newFound = $watcher.ScanAndBoost($Script:BlacklistSet, $prophet, $cpuSpike, $currentMetrics.CPU)
                if ($newFound) {
                    #  FIXED: BOOST nowej aplikacji = TURBO natychmiast!
                    Set-PowerMode -Mode "Turbo" -CurrentCPU $currentMetrics.CPU
                    $boostSecs = $watcher.GetBoostRemainingSeconds()
                    Add-Log " BOOST: $($watcher.BoostDisplayName) (${boostSecs}s)"
                    [void]$loadPredictor.RecordAppLaunch($watcher.BoostProcessName)
                    $isHeavy = $performanceBooster.IsHeavyApp($watcher.BoostProcessName) -or 
                               ($prophet.Apps.ContainsKey($watcher.BoostProcessName) -and $prophet.Apps[$watcher.BoostProcessName].IsHeavy)
                        if ($isHeavy) {
                        # Heavy app: High priority + affinity + cache + memory + freeze
                        [void]$performanceBooster.BoostProcessPriority($watcher.BoostProcessName)
                        [void]$performanceBooster.PreallocateMemory($watcher.BoostProcessName)
                        SafeWarm $watcher.BoostProcessName
                        [void]$performanceBooster.FreezeBackgroundProcesses($watcher.BoostProcessName)
                    } else {
                        # Normal app: AboveNormal priority only
                        $priorityManager.BoostProcess($watcher.BoostProcessName)
                    }
                }
            }
            if ($watcher.IsBoosting) {
                [void]$watcher.UpdateBoost($currentMetrics.CPU, $currentMetrics.IO)
                #  FIXED: Utrzymuj TURBO przez caly czas BOOST
                Set-PowerMode -Mode "Turbo" -CurrentCPU $currentMetrics.CPU
            }
            if (-not $watcher.IsBoosting -and ![string]::IsNullOrWhiteSpace($watcher.BoostProcessName)) {
                $learnData = $watcher.FinishBoost()
                if ($learnData) {
                    # AI uczy sie po ProcessName (stabilne), ale wyswietla DisplayName (czytelne)
                    if (Is-NeuralBrainEnabled) {
                        $result = $brain.Train(
                            $learnData.ProcessName, 
                            $learnData.DisplayName, 
                            $learnData.PeakCPU, 
                            $learnData.PeakIO, 
                            $prophet
                        )
                        #  POPRAWKA: Rozroznienie komunikatow dla nowych i znanych aplikacji
                        if ($result -match "^NEW") {
                            Add-Log " LEARNED: $($learnData.DisplayName) -> $result"
                        } else {
                            Add-Log " KNOWN: $($learnData.DisplayName) -> $result"
                        }
                    }
                    # ProphetMemory uczy sie niezaleznie od NeuralBrain
                    if (Is-ProphetEnabled) {
                        [void]$prophet.RecordLaunch($learnData.ProcessName, $learnData.PeakCPU, $learnData.PeakIO, $learnData.DisplayName)
                        Add-Log " Prophet: Nauczono aplikacje: $($learnData.DisplayName)" -Debug
                    }
                    # Chain Predictor - NIE rejestruj tutaj (app juz zarejestrowana przy foreground switch, linia 14905)
                    # Duplikat RecordAppLaunch psul TransitionGraph (ta sama app 2x = false transitions)
                    $chainPrediction = $chainPredictor.GetPredictionStatus()
                    [void]$anomalyDetector.UpdateBaseline(
                        $learnData.ProcessName,
                        $learnData.PeakCPU,
                        $learnData.PeakIO
                    )
                    $peakRAM = if ($learnData.PeakRAM) { $learnData.PeakRAM } else { 0 }
                    $performanceBooster.LearnHeavyApp($learnData.ProcessName, $learnData.PeakCPU, $peakRAM)
                    # Unfreeze background processes after BOOST finished
                    $performanceBooster.UnfreezeAllProcesses()
                    $learnSaveSuccess = Save-State -Brain $brain -Prophet $prophet
                    if ($learnSaveSuccess) {
                        $prophetLastAutosave = [DateTime]::Now
                        $prophetLastSavedSessions = $prophet.TotalSessions
                    }
                }
            }
            $startupBoostEntry = Update-StartupBoostState
            if ($iteration - $lastAnomalyCheck -ge 10) {
                $lastAnomalyCheck = $iteration
                $anomalyResult = $anomalyDetector.CheckForAnomalies($currentMetrics.CPU, $currentMetrics.IO)
                if ($anomalyResult.IsAnomaly) {
                    $anomalyAlert = $anomalyResult.Type
                    Add-Log "[WARN] ANOMALY: $($anomalyResult.Type) - $($anomalyResult.Details)"
                    switch ($anomalyResult.Type) {
                        "CPU_SPIKE" {
                            $culprit = $anomalyDetector.FindCulpritProcess()
                            if ($culprit) {
                                Add-Log "   Culprit: $($culprit.ProcessName) (CPU: $($culprit.CPU)%)" 
                            }
                        }
                        "CRYPTO_MINER" {
                            Add-Log " ALERT: Possible crypto miner detected!"
                        }
                        "MEMORY_LEAK" {
                            Add-Log "- Memory leak suspected in: $($anomalyResult.Details)"
                        }
                    }
                } else {
                    $anomalyAlert = ""
                }
            }
            # - Pobierz aktywna aplikacje dla tooltip (kazda iteracja)
            $rawAppName = ""
            try {
                $rawAppName = $priorityManager.GetForegroundApp()
                if ([string]::IsNullOrWhiteSpace($rawAppName)) { 
                    $currentActiveApp = "Desktop" 
                } else {
                    $currentActiveApp = Get-FriendlyAppName -ProcessName $rawAppName
                }
            } catch { $currentActiveApp = "Unknown" }
            if ($iteration - $lastPriorityUpdate -ge 15) {
                $lastPriorityUpdate = $iteration
                # Uzyj oryginalnej nazwy procesu dla optymalizacji
                if (![string]::IsNullOrWhiteSpace($rawAppName) -and $rawAppName -ne "Desktop") {
                    $priorityManager.OptimizeForForeground($rawAppName, $Script:BlacklistSet)
                    if ($Global:DebugMode) {
                        Add-Log " Priority: Boosted $currentActiveApp ($rawAppName)" -Debug
                    }
                }
            }
            # - V37.7.15: ProBalance - CPU Hog Restraint (co 5 iteracji = ~10s)
            if ($iteration - $lastProBalanceUpdate -ge 5) {
                $lastProBalanceUpdate = $iteration
                try {
                    $proBalance.Update($currentActiveApp)
                    # - V40: Zastosuj rekomendacje ProcessAI
                    $throttleRecs = $processAI.GetThrottleRecommendations($currentForeground)
                    $proBalance.ApplyAIRecommendations($throttleRecs)
                    # Zapisz punkt historii
                    $pbHistoryPoint = @{
                        Time = (Get-Date).ToString("HH:mm:ss")
                        Throttled = $proBalance.ThrottledProcesses.Count
                        TotalThrottles = $proBalance.TotalThrottles
                        TotalRestores = $proBalance.TotalRestores
                        Threshold = $proBalance.ThrottleThreshold
                        CPU = [int]$currentMetrics.CPU
                    }
                    $Script:ProBalanceHistory.Insert(0, $pbHistoryPoint)
                    while ($Script:ProBalanceHistory.Count -gt $Script:ProBalanceHistoryMaxSize) {
                        $Script:ProBalanceHistory.RemoveAt($Script:ProBalanceHistoryMaxSize)
                    }
                } catch { }
            }
            $aiDecision = @{ Score = 0; Mode = "Balanced"; Reason = "Init"; Trend = 0 }
            $currentState = "Balanced"
            # #
            # #
            if ($startupBoostEntry -and -not $Script:SilentLockMode) {
                $boostAppName = $startupBoostEntry.ProcessName
                
                # v43.10 FIX: Sprawdź HardLock PRZED wymuszeniem StartupBoost
                $hasHardLock = $false
                if ($Script:AppCategoryPreferences) {
                    $appLower = $boostAppName.ToLower() -replace '\.exe$', ''
                    foreach ($key in $Script:AppCategoryPreferences.Keys) {
                        $keyLower = $key.ToLower() -replace '\.exe$', ''
                        
                        # v43.10b: Rozszerzone dopasowanie
                        $matches = ($keyLower -eq $appLower) -or 
                                  ($appLower -like "*$keyLower*") -or 
                                  ($keyLower -like "*$appLower*") -or
                                  ($keyLower -eq "google chrome" -and $appLower -eq "chrome") -or
                                  ($keyLower -eq "chrome" -and $appLower -eq "chrome")
                        
                        if ($matches) {
                            $pref = $Script:AppCategoryPreferences[$key]
                            if ($pref.HardLock) {
                                $hasHardLock = $true
                                break
                            }
                        }
                    }
                }
                
                if ($hasHardLock) {
                    # Aplikacja ma HardLock - NIE STOSUJ StartupBoost
                    if ($Global:DebugMode) {
                        Add-Log " STARTUP BOOST SKIPPED: $boostAppName has HardLock (user enforced mode)" -Debug
                    }
                    # Usuń z Activity Boost Apps
                    if ($Script:ActivityBoostApps -and $startupBoostEntry.Pid) {
                        $Script:ActivityBoostApps.Remove($startupBoostEntry.Pid)
                    }
                    # Nie zmieniaj $currentState - niech HardLock logika określi tryb
                }
                # Sprawdz czy to proces systemowy
                elseif (Test-IsSystemProcess -ProcessName $boostAppName) {
                    # Ignoruj procesy systemowe
                    if ($Global:DebugMode) {
                        Add-Log "- Startup Boost SKIP (system): $boostAppName" -Debug
                    }
                } elseif ($Script:SilentModeActive) {
                    # W trybie SILENT - pytaj uzytkownika
                    $userApproved = Show-BoostNotification -AppName $boostAppName -CPUUsage ([int]$currentMetrics.CPU) -RecommendedMode "Turbo"
                    if ($userApproved) {
                        $remainingStartup = [Math]::Max(0, [int][Math]::Ceiling(($startupBoostEntry.Until - (Get-Date)).TotalSeconds))
                        $currentState = "Turbo"
                        $aiDecision = @{
                            Score = 95
                            Mode = "Turbo"
                            Reason = "Startup Boost (approved): $boostAppName (${remainingStartup}s)"
                            Trend = 0
                        }
                    }
                    # Jesli nie zatwierdzono - zostan w domyslnym trybie
                } else {
                    # BALANCED/TURBO - normalny boost
                    $remainingStartup = [Math]::Max(0, [int][Math]::Ceiling(($startupBoostEntry.Until - (Get-Date)).TotalSeconds))
                    $currentState = "Turbo"
                    $aiDecision = @{
                        Score = 95
                        Mode = "Turbo"
                        Reason = "Startup Boost: $boostAppName (${remainingStartup}s)"
                        Trend = 0
                    }
                }
            }
            # #
            # #
            elseif ($watcher.IsBoosting -and -not $Script:SilentLockMode) {
                $boostAppName = $watcher.BoostProcessName
                
                # v43.10 FIX: Sprawdź HardLock - jeśli aplikacja ma HardLock, ANULUJ BOOST
                $hasHardLock = $false
                if ($Script:AppCategoryPreferences) {
                    $appLower = $boostAppName.ToLower() -replace '\.exe$', ''
                    foreach ($key in $Script:AppCategoryPreferences.Keys) {
                        $keyLower = $key.ToLower() -replace '\.exe$', ''
                        
                        # v43.10b: Rozszerzone dopasowanie
                        $matches = ($keyLower -eq $appLower) -or 
                                  ($appLower -like "*$keyLower*") -or 
                                  ($keyLower -like "*$appLower*") -or
                                  ($keyLower -eq "google chrome" -and $appLower -eq "chrome") -or
                                  ($keyLower -eq "chrome" -and $appLower -eq "chrome")
                        
                        if ($matches) {
                            $pref = $Script:AppCategoryPreferences[$key]
                            if ($pref.HardLock) {
                                $hasHardLock = $true
                                break
                            }
                        }
                    }
                }
                
                if ($hasHardLock) {
                    # Aplikacja ma HardLock - anuluj boost i użyj HardLock mode
                    $watcher.CancelBoost()
                    if ($Global:DebugMode) {
                        Add-Log " BOOST CANCELLED: $boostAppName has HardLock (user enforced mode)" -Debug
                    }
                    # Nie zmieniaj $currentState - niech HardLock logika (wyżej w hierarchii) określi tryb
                }
                # Sprawdz czy to proces systemowy
                elseif (Test-IsSystemProcess -ProcessName $boostAppName) {
                    # Ignoruj procesy systemowe - anuluj boost
                    $watcher.CancelBoost()
                    if ($Global:DebugMode) {
                        Add-Log "- Watcher Boost SKIP (system): $boostAppName" -Debug
                    }
                } elseif ($Script:SilentModeActive) {
                    # W trybie SILENT - pytaj uzytkownika (tylko raz na aplikacje)
                    if (-not $Script:UserApprovedBoosts.Contains($boostAppName)) {
                        $userApproved = Show-BoostNotification -AppName $boostAppName -CPUUsage ([int]$currentMetrics.CPU) -RecommendedMode "Turbo"
                        if (-not $userApproved) {
                            $watcher.CancelBoost()
                        }
                    }
                    # Jesli zatwierdzono lub auto-approved
                    if ($Script:UserApprovedBoosts.Contains($boostAppName) -or $watcher.IsBoosting) {
                        $currentState = "Turbo"
                        $aiDecision = @{ 
                            Score = 90
                            Mode = "Turbo"
                            Reason = " BOOST (approved) $($watcher.GetBoostRemainingSeconds())s"
                            Trend = 0 
                        }
                    }
                } else {
                    # BALANCED/TURBO - normalny boost
                    $currentState = "Turbo"
                    $aiDecision = @{ 
                        Score = 90
                        Mode = "Turbo"
                        Reason = " BOOST $($watcher.GetBoostRemainingSeconds())s"
                        Trend = 0 
                    }
                }
            } elseif (![string]::IsNullOrWhiteSpace($anomalyAlert) -and $anomalyAlert -eq "CRYPTO_MINER") {
                $currentState = "Silent"
                $aiDecision = @{
                    Score = 10
                    Mode = "Silent"
                    Reason = "SECURITY"
                    Trend = 0
                }
            } elseif ($Global:AI_Active) {
                # Pobierz progi z Self-Tuner
                $turboThreshold = $selfTuner.GetTurboThreshold()
                $balancedThreshold = $selfTuner.GetBalancedThreshold()
                $ramInfo = $ramAnalyzer.Update($currentForeground, $currentMetrics.Temp, $currentState)
                $ramUsage = if ($ramInfo) { $ramInfo.RAM } else { 0 }
                $ramSpike = if ($ramInfo) { $ramInfo.Spike -or $ramInfo.Trend } else { $false }
                # - V40: ProcessAI - ucz sie zachowan procesow
                if ($currentForeground) {
                    try { $processAI.Learn($currentForeground, $currentMetrics.CPU, $ramUsage) } catch { }
                }
                # - V40: GPU AI - rekomendacja GPU na podstawie trybu i aplikacji
                $gpuRecommendation = $null
                if ($Script:HasiGPU -or $Script:HasdGPU) {
                    # Aktualny tryb będzie znany po decyzji AI, więc używamy poprzedniego
                    $gpuRecommendation = $gpuAI.GetGPURecommendation($currentState, $currentForeground, $currentMetrics.CPU)
                    
                    # V40.2 FIX: Ulepszone wykrywanie GPU Load i typu aktywnego GPU
                    $gpuLoad = 0
                    $activeGPU = "Unknown"
                    
                    # Pobierz rzeczywiste obciążenie GPU z currentMetrics
                    if ($currentMetrics.GPU -and $currentMetrics.GPU.Load) {
                        $gpuLoad = $currentMetrics.GPU.Load
                    }
                    
                    # V40.2 FIX: Ulepszone wykrywanie aktywnego GPU
                    if ($gpuLoad -gt 5) {
                        $gpuName = if ($currentMetrics.GPU.Name) { $currentMetrics.GPU.Name } else { "" }
                        
                        # Sprawdź typ GPU na podstawie nazwy z sensorów
                        # V40 FIX: Rozszerzone wzorce dla AMD dGPU
                        if ($gpuName -match "NVIDIA|GeForce|RTX|GTX|Quadro") {
                            $activeGPU = "dGPU"
                        }
                        elseif ($gpuName -match "Radeon\s*(RX|Pro|VII|WX|W\d)|AMD.*RX\s*\d{4}") {
                            $activeGPU = "dGPU"  # AMD dedicated
                        }
                        elseif ($gpuName -match "Intel.*UHD|Intel.*HD|Intel.*Iris|Intel.*Graphics") {
                            $activeGPU = "iGPU"  # Intel integrated
                        }
                        elseif ($gpuName -match "AMD.*Graphics|Radeon.*Graphics|Radeon\s+\d{3}M|Vega|APU") {
                            $activeGPU = "iGPU"  # AMD APU integrated (Vega, 680M, 780M etc.)
                        }
                        # Fallback: użyj danych z detekcji hardware
                        elseif ($Script:HasdGPU -and $Script:dGPUName -and $gpuName -match $Script:dGPUName.Split(' ')[0]) {
                            $activeGPU = "dGPU"
                        }
                        elseif ($Script:HasiGPU -and $Script:iGPUName -and $gpuName -match $Script:iGPUName.Split(' ')[0]) {
                            $activeGPU = "iGPU"
                        }
                        # Ostateczny fallback: jeśli tylko jeden GPU
                        elseif ($Script:HasdGPU -and -not $Script:HasiGPU) {
                            $activeGPU = "dGPU"
                        }
                        elseif ($Script:HasiGPU -and -not $Script:HasdGPU) {
                            $activeGPU = "iGPU"
                        }
                        else {
                            $activeGPU = "Auto"  # Hybrid - nie wiadomo które
                        }
                    }
                    
                    # GPU Learning - ucz się preferencji aplikacji
                    if ($currentForeground -and $gpuLoad -gt 0) {
                        try { 
                            $gpuAI.Learn($currentForeground, $gpuLoad, $activeGPU, $currentMetrics.CPU, $currentMetrics.Temp) 
                        } catch { }
                    }
                    
                    # Log co 30 iteracji gdy GPU aktywne
                    if ($iteration % 30 -eq 0 -and $gpuLoad -gt 20) {
                        Add-Log "- GPU AI: Load=$gpuLoad% Active=$activeGPU App=$currentForeground" -Debug
                    }
                }
                #  1. BRAIN - Neural Network Decision (V35: z RAM)
                if (Is-NeuralBrainEnabled) {
                    $brainDecision = $brain.Decide(
                        $currentMetrics.CPU, 
                        $currentMetrics.IO, 
                        $forecaster.Trend(), 
                        $prophet,
                        $ramUsage,      # V35 NEW
                        $ramSpike       # V35 NEW
                    )
                    # Brain daje Score, nie wymusza trybu
                    $aiDecision = @{ 
                        Score = $brainDecision.Score
                        Mode = "Balanced"  # Placeholder, zostanie ustalony przez kombinację
                        Reason = $brainDecision.Reason
                        Trend = $brainDecision.Trend
                        BrainSuggestion = $brainDecision.Suggestion  # Sugestia do użycia w kombinacji
                    }
                } else {
                    $aiDecision = @{ Score = 0; Mode = "Silent"; Reason = "DISABLED"; Trend = 0; BrainSuggestion = "Balanced" }
                }
                #  2. Q-LEARNING - Reinforcement Learning (V35: z RAM)
                # v43.1 FIX: Update() musi być PRZED SelectAction() żeby nagrodzić poprzednią akcję
                if (Is-QLearningEnabled) {
                    # v43.14: Per-app learning - Q-Learning zna aktywną aplikację
                    $qLearning.CurrentApp = if ($currentForeground) { $currentForeground } else { "" }
                    $newQState = $qLearning.DiscretizeState($currentMetrics.CPU, $currentMetrics.Temp, $isUserActive, $currentContext, $ramUsage, $ramSpike, $phaseDetector.CurrentPhase)
                    # Najpierw Update - nagradzamy poprzednią akcję (LastAction z poprzedniej iteracji)
                    if ($qState -and $qLearning.LastAction) {
                        $reward = $qLearning.CalcReward($qLearning.LastAction, $currentMetrics.CPU, $currentMetrics.Temp, $prevTemp, $isUserActive, $ramUsage, $ramSpike, $phaseDetector.CurrentPhase)
                        [void]$qLearning.Update($qState, $qLearning.LastAction, $reward, $newQState)
                    }
                    # Potem SelectAction - wybieramy nową akcję (zapisuje LastAction dla następnej iteracji)
                    $qAction = $qLearning.SelectAction($newQState)
                    $qState = $newQState
                }
                # - 3. MULTI-ARMED BANDIT - Thompson Sampling
                # v42.6: Sprawdź czy włączone
                $banditAction = if (Is-BanditEnabled) { $bandit.SelectArm() } else { "Balanced" }
                # - 4. GENETIC OPTIMIZER - Evolving Parameters
                # v42.6: Sprawdź czy włączone
                $geneticParams = if (Is-GeneticEnabled) { $genetic.GetCurrentParams() } else { @{ TurboThreshold = 75; BalancedThreshold = 35 } }
                $geneticMode = "Balanced"
                if ($geneticParams.TurboThreshold -and $aiDecision.Score -gt $geneticParams.TurboThreshold -and $currentMetrics.CPU -gt 40) {
                    $geneticMode = "Turbo"
                } elseif ($geneticParams.BalancedThreshold -and ($aiDecision.Score -lt $geneticParams.BalancedThreshold -or $currentMetrics.CPU -lt 20)) {
                    $geneticMode = "Silent"
                }
                #  5. CONTEXT DETECTOR - Application Context
                $contextMode = $contextDetector.GetRecommendedMode()
                # v43.14: Context + Prophet learned = inteligentny score
                # Jeśli Prophet zna lepszy tryb per-app, użyj go zamiast hardcoded
                $contextLearnedMode = ""
                if ($prophet -and $currentForeground -and (Is-ProphetEnabled)) {
                    $contextLearnedMode = $prophet.GetLearnedMode($currentForeground, $phaseDetector.CurrentPhase)
                }
                $contextEffective = if ($contextLearnedMode) { $contextLearnedMode } else { $contextMode }
                $contextScore = switch ($contextEffective) {
                    "Turbo" { 75 }
                    "Balanced" { 50 }
                    "Silent" { 25 }
                    default { 50 }
                }
                
                # - 6. THERMAL PREDICTOR - Temperature Trend (votes carefully)
                #  FIXED: Thermal glosuje score na podstawie temperatury
                $thermalScore = 50  # Neutralny
                if ($thermalPredictor.ShouldThrottle()) { 
                    $thermalScore = 20  # Silnie obniż score przy przegrzaniu
                } elseif ($currentMetrics.Temp -lt 50 -and $currentMetrics.CPU -gt 40) {
                    $thermalScore = 70  # Zimny CPU + wysokie obciążenie = pozwól na wyższy score
                } elseif ($currentMetrics.Temp -lt 45 -and $currentMetrics.CPU -lt 20) {
                    $thermalScore = 25  # Zimny CPU + niskie obciążenie = niski score
                }
                
                #  7. USER PATTERNS - Activity Patterns
                # v47: Pattern score wielowymiarowy — godzina + aktywność + kontekst + CPU history
                $patternScore = 50
                $hourNow = (Get-Date).Hour
                # 1. Czy ta godzina jest typowo aktywna?
                $hourActive = $userPatterns.IsTypicallyActiveNow()
                # 2. Jaki kontekst dominuje o tej godzinie? (z Prophet HourlyActivity)
                $hourlyHeavy = $false
                if ($prophet -and $prophet.HourlyActivity -and $prophet.HourlyActivity[$hourNow] -gt 3) {
                    $hourlyHeavy = $true  # O tej godzinie zwykle ciężkie aplikacje
                }
                # 3. Ostatni trend CPU (rosnący = app się rozgrzewa)
                $recentCPUHigh = ($currentMetrics.CPU -gt 40 -or ($trend -and $trend -gt 10))
                
                if (-not $isUserActive -and -not $hourActive -and $currentMetrics.CPU -lt 15) {
                    $patternScore = 15   # Nocna cisza, nic nie działa
                } elseif ($hourlyHeavy -and $hourActive) {
                    $patternScore = 65   # Ta godzina = zwykle ciężka praca
                } elseif ($isUserActive -and $recentCPUHigh) {
                    $patternScore = 70   # Aktywny + CPU rośnie
                } elseif ($hourActive -and -not $recentCPUHigh) {
                    $patternScore = 45   # Aktywna godzina ale CPU niski
                } elseif (-not $hourActive) {
                    $patternScore = 25   # Nietypowa godzina
                }
                
                #  8. GPU MONITOR - Graphics Load + GPU Type + AI Learning drives score
                $gpuLoad = if ($currentMetrics.GPU) { $currentMetrics.GPU.Load } else { 0 }
                $gpuScore = 50  # Neutralny
                
                # v43.14: GPU score ODWROTNY do CPU potrzeb!
                # Wysokie GPU load = GPU robi robotę = CPU NIE potrzebuje Turbo
                if ($gpuAI -and $currentForeground) {
                    $gpuLearnedMode = $gpuAI.GetRecommendedMode($currentForeground, $gpuLoad)
                    if ($gpuLearnedMode) {
                        $gpuScore = switch ($gpuLearnedMode) {
                            "Turbo" { 80 }
                            "Balanced" { 50 }
                            "Silent" { 25 }
                            default { 50 }
                        }
                    }
                }
                
                # GPU-BOUND logic: wysoki GPU + niski CPU = nie potrzeba Turbo CPU
                if ($gpuLoad -gt 60 -and $currentMetrics.CPU -lt 50) {
                    # GPU robi robotę - CPU score w DÓŁ
                    $gpuScore = [Math]::Min($gpuScore, 30)
                } elseif ($gpuLoad -lt 20 -and $gpuScore -eq 50) {
                    # Brak GPU = CPU-intensive - użyj raw CPU jako indicator
                    $gpuScore = [Math]::Min(100, [Math]::Max(20, $currentMetrics.CPU))
                }
                
                #  9. LOAD PREDICTOR - Future Load Prediction
                # Prediction drives decision - prepare BEFORE load hits
                $predictorScore = 50  # Neutralny
                if ($Script:PredictiveBoostEnabled) {
                    # Zamiast wymuszać tryb, dajemy score proporcjonalny do predykcji
                    $predictorScore = [Math]::Min(100, [Math]::Max(0, $predictedLoad))
                }
                #  10. CHAIN PREDICTOR - App Launch Prediction (v43.14: per-app learned)
                $chainScore = 50  # Neutralny
                if ($Script:PreloadEnabled -or $Script:SmartPreload) {
                    if ($chainPredictor.ShouldPreBoost()) {
                        # v43.14: Sprawdź czy predicted app ma learned mode
                        $predictedApp = $chainPredictor.CurrentPrediction
                        $chainLearnedMode = ""
                        if ($predictedApp -and $prophet -and (Is-ProphetEnabled)) {
                            $chainLearnedMode = $prophet.GetLearnedMode($predictedApp, "Loading")
                        }
                        if ($chainLearnedMode) {
                            $chainScore = switch ($chainLearnedMode) {
                                "Turbo" { 80 }
                                "Balanced" { 55 }
                                "Silent" { 30 }
                                default { 65 }
                            }
                        } else {
                            $chainScore = 70
                        }
                        # v47.2: DEPTH-2 CHAIN PRELOAD — A→B(full) + B→C(warm)
                        if ($predictedApp -and $appRAMCache -and $appRAMCache.Enabled) {
                            $chainConf = if ($chainPredictor.PredictionConfidence -gt 0) { $chainPredictor.PredictionConfidence } else { 0.5 }
                            $chainTrans = $chainPredictor.TransitionGraph
                            $exePaths = if ($performanceBooster) { $performanceBooster.AppExecutablePaths } else { @{} }
                            $appRAMCache.ChainPreload($predictedApp, $chainConf, $chainTrans, $exePaths)
                        }
                    } elseif ($currentContext -eq "Idle" -and $currentMetrics.CPU -lt 20) { 
                        $chainScore = 20
                    }
                }
                #  11. FORECASTER - CPU Trend Analysis
                #  SYNC: uses variables z config.json
                $trend = $forecaster.Trend()
                $trendScore = 50
                # v47: Wzmocniony wpływ trendu — trend to REALNY sygnał czasu rzeczywistego
                # Trend +20 = CPU rośnie szybko → score +25 (przygotuj moc)
                # Trend -20 = CPU spada → score -25 (zwalniaj)
                $trendScore += ($trend * 1.25)  # Trend ±20 = ±25 score
                $trendScore = [Math]::Min(100, [Math]::Max(0, $trendScore))
                
                #  12. SELF-TUNER - Dynamic Thresholds
                #  SYNC: uses variables z config.json
                # (Tuner usunięty z modelScores — był kopią Brain score)
                
                #  13. ENERGY TRACKER - Efficiency Focus
                $energyScore = 50  # Neutralny
                $efficiency = $energyTracker.CurrentEfficiency
                # Wysoka efektywność przy niskim CPU = preferuj Silent
                # Niska efektywność przy wysokim CPU = preferuj Turbo
                if ($efficiency -gt 0.8 -and $currentMetrics.CPU -lt 30) { 
                    $energyScore = 25  # Zachęcaj do Silent
                } elseif ($efficiency -lt 0.4 -and $currentMetrics.CPU -gt $Script:TurboThreshold) { 
                    $energyScore = 80  # Zachęcaj do Turbo
                }
                
                #  14. PROPHET MEMORY - App History (v43.14: LEARNED per-app per-phase)
                $prophetScore = 50  # Neutralny
                if ($prophet.LastActiveApp -and (Is-ProphetEnabled)) {
                    $currentPhase = $phaseDetector.CurrentPhase
                    # v43.14: Najpierw sprawdź NAUCZONY tryb per-app per-phase
                    $learnedMode = $prophet.GetLearnedMode($prophet.LastActiveApp, $currentPhase)
                    if ($learnedMode) {
                        # Learned mode → score: Silent=20, Balanced=50, Turbo=80
                        $prophetScore = switch ($learnedMode) {
                            "Silent"   { 20 }
                            "Balanced" { 50 }
                            "Turbo"    { 80 }
                            default    { 50 }
                        }
                    } else {
                        # Nie ma jeszcze learned mode - użyj category ale z GPU-bound korektą
                        $appWeight = $prophet.GetWeight($prophet.LastActiveApp)
                        $prophetScore = $appWeight * 100
                        # GPU-bound korekta: HEAVY + GPU-bound → NIE dawaj Turbo
                        $appData = $prophet.Apps[$prophet.LastActiveApp]
                        if ($appData -and $appData.ContainsKey('IsGPUBound') -and $appData.IsGPUBound) {
                            $prophetScore = [Math]::Min($prophetScore, 40)  # Cap at Balanced
                        }
                    }
                }
                
                #  15. ANOMALY DETECTOR - Security Check
                # v47: Anomaly score — wielowymiarowe wykrywanie anomalii
                $anomalyScore = 50
                if ($anomalyAlert -eq "CRYPTO_MINER") { 
                    $anomalyScore = 10  # Crypto miner → prawie Silent
                }
                # CPU anomaly: wysoki CPU bez aktywnej app użytkownika = podejrzane
                elseif ($currentMetrics.CPU -gt 70 -and (-not $currentForeground -or $currentForeground -eq "Desktop") -and -not $isUserActive) {
                    $anomalyScore = 20  # Coś ciężkiego w tle bez wiedzy usera
                }
                # GPU anomaly: wysoki GPU bez rozpoznanej app = podejrzane
                elseif ($gpuLoad -gt 60 -and (-not $currentForeground -or $currentForeground -eq "Desktop")) {
                    $anomalyScore = 25  # GPU działa ale user nic nie robi
                }
                # Thermal anomaly: temp rośnie szybko przy niskim CPU = problem chłodzenia
                elseif ($currentMetrics.Temp -gt 80 -and $currentMetrics.CPU -lt 30) {
                    $anomalyScore = 20  # Przegrzanie bez obciążenia → obniż
                }
                # Wszystko OK: nie modyfikuj score (=50 neutralne)
                
                # - 16. ACTIVITY MONITOR - User Presence
                $activityScore = 50  # Neutralny
                if (-not $isUserActive -and $currentMetrics.CPU -lt 25) { 
                    $activityScore = 25  # Użytkownik nieaktywny = niższy score
                } elseif ($isUserActive -and $currentMetrics.CPU -gt 70) { 
                    $activityScore = 75  # Użytkownik aktywny + wysokie CPU = wyższy score
                }
                # - 17. I/O MONITOR - Disk Activity Reaction (NOWE!)
                $ioScore = 50  # Neutralny
                if ($Script:PredictiveIO) {
                    $diskReadMB = $diskReadSpeed / 1MB
                    $diskWriteMB = $diskWriteSpeed / 1MB
                    # Zastosuj czulosc (1-10) jako mnoznik progow
                    # Sens 10 = x1.0 (najbardziej czuly), Sens 1 = x1.9 (najmniej czuly)
                    $sensitivityMultiplier = 1.0 + ((10 - $Script:IOSensitivity) * 0.1)
                    $effectiveReadThreshold = $Script:IOReadThreshold * $sensitivityMultiplier
                    $effectiveWriteThreshold = $Script:IOWriteThreshold * $sensitivityMultiplier
                    # Sprawdz czy aktywnosc I/O wymaga reakcji
                    if ($diskReadMB -gt $effectiveReadThreshold -or $diskWriteMB -gt $effectiveWriteThreshold) {
                        $Script:LastIOThresholdEvent = [DateTime]::Now
                        # Aktywuj IO Boost jesli jeszcze nie aktywny
                        if (-not $Script:IOBoostActive) {
                            $Script:IOBoostActive = $true
                            $Script:IOBoostStartTime = [DateTime]::Now
                            Add-Log "- I/O Boost: Read=$([int]$diskReadMB)MB/s Write=$([int]$diskWriteMB)MB/s"
                        }
                        # Bardzo wysoka aktywnosc I/O = wysoki score
                        if ($diskReadMB -gt ($effectiveReadThreshold * 2) -or $diskWriteMB -gt ($effectiveWriteThreshold * 2)) {
                            $ioScore = 85  # Wysoki score, nie wymuszenie Turbo
                        } else {
                            $ioScore = 60  # Średni score
                        }
                    } else {
                        # Niska aktywnosc I/O - sprawdz czy zakonczyc boost
                        if ($Script:IOBoostActive) {
                            $ioBoostDuration = ([DateTime]::Now - $Script:IOBoostStartTime).TotalMilliseconds
                            if ($ioBoostDuration -gt $Script:BoostDuration) {
                                $Script:IOBoostActive = $false
                            }
                        }
                        # Brak aktywnosci I/O i niskie CPU = niski score
                        if ($currentMetrics.CPU -lt 30 -and -not $Script:IOBoostActive) {
                            $ioScore = 25  # Niski score
                        }
                    }
                } else {
                    # PredictiveIO disabled - still calculate disk metrics for display
                    $diskReadMB = $diskReadSpeed / 1MB
                    $diskWriteMB = $diskWriteSpeed / 1MB
                }
                # v43.13: 18. NETWORK AI - Network-aware mode prediction
                $networkScore = 50  # Neutralny
                if ($Script:LastNetworkAIMode) {
                    $networkScore = switch ($Script:LastNetworkAIMode) {
                        "Turbo" { 75 }
                        "Balanced" { 50 }
                        "Silent" { 25 }
                        default { 50 }
                    }
                }
                # #
                # AI LEARNING LOG - tylko w trybie DEBUG (aby nie spowalniac)
                # #
                if ($Global:DebugMode -and $iteration % 30 -eq 0) {
                    Write-Log "AI LEARNING | LoadPred=$($predictedLoad)% | Trend=$($trend)% | Temp=$($currentMetrics.Temp)°C" "INFO"
                    if ($predictedLoad -gt 75) {
                        Write-Log "    LoadPredictor: High load predicted!" "INFO"
                    }
                    if ($trend -gt 20) {
                        Write-Log "    TrendForecaster: CPU rising!" "INFO"
                    } elseif ($trend -lt -15) {
                        Write-Log "    TrendForecaster: CPU falling!" "INFO"
                    }
                }
                # - MEGA AI: Ensemble voting - WSZYSTKIE 17 modeli glosuja!
                # Context priority wplywa na wagi: Priority 1 (Gaming/Audio) = waga x2, Priority 6 (Background) = waga x0.5
                $powerBoostScore = 50  # Neutralny
                if ($Script:PowerBoost) {
                    # PowerBoost gives extra push when CPU > 60% or RAM spike
                    if ($currentMetrics.CPU -gt 60 -or $ramSpike) {
                        $powerBoostScore = 80  # Wysoki score
                        if ($Global:DebugMode -and $iteration % 30 -eq 0) {
                            Add-Log "- PowerBoost: Active (CPU=$([int]$currentMetrics.CPU)% RAMSpike=$ramSpike)"
                        }
                    } elseif ($currentMetrics.CPU -lt 15) {
                        $powerBoostScore = 20  # Niski score
                    }
                }
                $contextPriority = if ($contextDetector.ContextPatterns.ContainsKey($currentContext)) {
                    $contextDetector.ContextPatterns[$currentContext].Priority
                } else { 6 }
                $contextWeight = 3.0 - ($contextPriority * 0.4)  # Priority 1 = 2.6x, Priority 6 = 0.6x
                #  SYNC: Filtruj glosy Q-Learning i Bandit - uses variables z config.json
                # ZMIANA: Zwiększony score dla Silent (z 15 na 25) - lepsza reprezentacja w kombinacji
                $qScore = switch ($qAction) {
                    "Turbo" { 85 }
                    "Balanced" { 50 }
                    "Silent" { 25 }
                    default { 50 }
                }
                
                # Filtr Q-Learning przy niskim CPU
                if ($currentMetrics.CPU -lt $Script:BalancedThreshold -and $qScore -gt 70) { $qScore = 55 }
                if ($currentMetrics.CPU -lt $Script:ForceSilentCPU) { $qScore = [Math]::Min($qScore, 30) }
                
                # (Bandit i Genetic usunięte z modelScores — Bandit nadal się uczy w tle)
                
                # AICoordinator: wybierz aktywny silnik na podstawie warunków
                if ($aiCoordinator) {
                    try { [void]$aiCoordinator.DecideActiveEngine($currentMetrics.CPU, $currentMetrics.Temp, $currentContext, $qLearning.TotalUpdates) } catch {}
                }
                
                # v43.14: Prophet LearnMode - CO ITERACJĘ uczy się jaki tryb działa per-app per-phase
                if ($currentForeground -and $currentForeground -ne "Desktop" -and (Is-ProphetEnabled)) {
                    try {
                        # Reward: używamy tego samego co Q-Learning (spójność)
                        $prophetReward = if ($qLearning.LastReward) { $qLearning.LastReward } else { 0.0 }
                        $prophet.LearnMode($currentForeground, $currentState, $prophetReward, $phaseDetector.CurrentPhase, $gpuLoad)
                    } catch {}
                }
                
                # v43.14: SharedAppKnowledge - silniki PISZĄ wiedzę per-app (co 5 iteracji)
                # Umieszczone PO obliczeniu score'ów - qAction, gpuLoad, context dostępne
                if ($iteration % 5 -eq 0 -and $currentForeground -and $currentForeground -ne "Desktop") {
                    try {
                        $phDom = $phaseDetector.CurrentPhase
                        $phHist = @{}
                        if ($phaseDetector.AppPhaseHistory.ContainsKey($currentForeground)) {
                            $phHist = $phaseDetector.AppPhaseHistory[$currentForeground]
                        }
                        $sharedKnowledge.WriteFromPhase($currentForeground, $phDom, $phHist)
                        
                        $thermalRisk = if ($currentMetrics.Temp -gt 85) { "High" } elseif ($currentMetrics.Temp -gt 70) { "Medium" } else { "Low" }
                        $sharedKnowledge.WriteFromThermal($currentForeground, $currentMetrics.Temp, $currentMetrics.Temp, $thermalRisk)
                        
                        $ctxPriority = if ($contextDetector.ContextPatterns.ContainsKey($currentContext)) { $contextDetector.ContextPatterns[$currentContext].Priority } else { 5 }
                        $sharedKnowledge.WriteFromContext($currentForeground, $currentContext, $ctxPriority)
                        
                        $gpuCat = if ($gpuLoad -gt 85) { "Extreme" }
                                   elseif ($gpuLoad -gt 60 -and $currentMetrics.CPU -gt 40) { "Heavy" }
                                   elseif ($gpuLoad -gt 60) { "Rendering" }
                                   elseif ($gpuLoad -gt 30) { "Work" }
                                   elseif ($currentMetrics.CPU -gt 60 -and $gpuLoad -lt 20) { "Heavy" }
                                   elseif ($gpuLoad -lt 10 -and $currentMetrics.CPU -lt 15) { "Idle" }
                                   else { "Light" }
                        $gpuBoundNow = ($gpuBound -and $gpuBound.IsConfident)
                        $prefGPU = if ($gpuAI -and $gpuAI.GetRecommendation) { try { ($gpuAI.GetRecommendation($currentForeground)).PreferredGPU } catch { "" } } else { "" }
                        $sharedKnowledge.WriteFromGPUAI($currentForeground, $prefGPU, $gpuBoundNow, $gpuLoad, $gpuCat)
                        
                        $propBestMode = ""
                        if ($prophet) {
                            # v43.14: Najpierw per-phase learned, potem global PreferredMode
                            $propBestMode = $prophet.GetLearnedMode($currentForeground, $phDom)
                            if (-not $propBestMode -and $prophet.Apps.ContainsKey($currentForeground)) {
                                $pa = $prophet.Apps[$currentForeground]
                                $propBestMode = if ($pa.ContainsKey('PreferredMode') -and $pa.PreferredMode) { $pa.PreferredMode } else { "" }
                            }
                        }
                        $sharedKnowledge.WriteFromProphet($currentForeground, $currentMetrics.CPU, $gpuLoad, $propBestMode, 0)
                        
                        if ($qAction -and $phDom) {
                            $qConf = if ($qLearning.TotalUpdates -gt 100) { 0.8 } elseif ($qLearning.TotalUpdates -gt 20) { 0.5 } else { 0.2 }
                            $sharedKnowledge.WriteFromQLearning($currentForeground, $qAction, $qConf, $phDom, $qAction)
                        }
                        
                        if ($energyTracker) {
                            $eff = if ($currentMetrics.CPU -gt 5) { [Math]::Min(1.0, 50.0 / $currentMetrics.CPU) } else { 1.0 }
                            $sharedKnowledge.WriteFromEnergy($currentForeground, $eff)
                        }
                        
                        if ($Script:LastNetworkAIMode) {
                            $sharedKnowledge.WriteFromNetwork($currentForeground, $Script:LastNetworkAIMode, $netDownloadSpeed, $netUploadSpeed)
                        }
                    } catch {}
                }
                
                # NOWA STRUKTURA: modelScores — TYLKO silniki z unikalnym sygnałem
                # Usunięte placebo: Tuner (=kopia Brain), Genetic (=Brain+progi), Bandit (=globalny szum)
                $modelScores = @{
                    "Brain" = $aiDecision.Score
                    "QLearning" = $qScore
                    "Context" = $contextScore
                    "Thermal" = $thermalScore
                    "Pattern" = $patternScore
                    "GPU" = $gpuScore
                    "Predictor" = $predictorScore
                    "Chain" = $chainScore
                    "Trend" = $trendScore
                    "Energy" = $energyScore
                    "Prophet" = $prophetScore
                    "Anomaly" = $anomalyScore
                    "Activity" = $activityScore
                    "IOMonitor" = $ioScore
                    "NetworkAI" = $networkScore
                    "PowerBoost" = $powerBoostScore
                }
                
                # v43.14: SharedAppKnowledge - INTELIGENCJA per-app (najwyższa waga!)
                # Zbiera wiedzę WSZYSTKICH silników o tej aplikacji i daje score
                $appIntel = $null
                if ($sharedKnowledge -and $currentForeground -and $currentForeground -ne "Desktop") {
                    try {
                        $appIntel = $sharedKnowledge.GetAppIntelligence($currentForeground, $phaseDetector.CurrentPhase)
                        if ($appIntel -and $appIntel.Confidence -gt 0.2) {
                            $modelScores["AppIntel"] = $appIntel.Score
                        }
                    } catch {}
                }
                # Ensemble Vote: gdy włączony, głosuje na tryb i dodaje score do modelScores
                # Bez tego wywołania ensemble.Vote() silnik Ensemble nie ma żadnego wpływu na $newMode
                if ($ensemble -and (Is-EnsembleEnabled)) {
                    try {
                        $ensembleDecisions = @{}
                        foreach ($engKey in $modelScores.Keys) {
                            $s = $modelScores[$engKey]
                            $ensembleDecisions[$engKey] = if ($s -gt 70) { "Turbo" } elseif ($s -lt 35) { "Silent" } else { "Balanced" }
                        }
                        $ensembleVote = $ensemble.Vote($ensembleDecisions, $ramUsage, $ramSpike)
                        $modelScores["Ensemble"] = switch ($ensembleVote) { "Turbo" { 82 } "Silent" { 22 } default { 50 } }
                    } catch {}
                }
                $modelWeights = @{
                    "Context" = $contextWeight  # Dynamiczne wagi
                    "PowerBoost" = if ($Script:PowerBoost) { 1.5 } else { 0.5 }  # V38: Higher weight when enabled
                }
                # #
                #  HOT-RELOAD: ForceMode z konfiguratora
                # #
                # Inicjalizacja zmiennych dostępnych we WSZYSTKICH ścieżkach (ForceMode, I/O, AI)
                if (-not $Script:V42_PrevMode) { $Script:V42_PrevMode = "Balanced" }
                $prevMode = $Script:V42_PrevMode
                $newMode = $prevMode  # Domyślnie: trzymaj obecny tryb
                $reason = ""
                # Sprawdz czy I/O moze nadpisac ForceMode
                $currentIOTotal = $diskReadMB + $diskWriteMB
                $ioCanOverride = $Script:IOOverrideForceMode -and $currentIOTotal -gt $Script:IOTurboThreshold
                $forceModeValue = $Script:ForceModeFromConfig
                $hasForceMode = $forceModeValue -and $forceModeValue -ne ""
                $forceModeUpper = if ($hasForceMode) { $forceModeValue.ToUpper() } else { "" }
                $forceModeAllowed = $hasForceMode -and -not $ioCanOverride
                if ($forceModeAllowed -and $forceModeUpper -eq "EXTREME") {
                    $quietSeconds = if ($Script:LastIOThresholdEvent -eq [DateTime]::MinValue) {
                        [double]::PositiveInfinity
                    } else {
                        ([DateTime]::Now - $Script:LastIOThresholdEvent).TotalSeconds
                    }
                    if ($Script:IOBoostActive -or $quietSeconds -lt $Script:IOExtremeGraceSeconds) {
                        $forceModeAllowed = $false
                        if ($Global:DebugMode) {
                            $quietInfo = if ($quietSeconds -eq [double]::PositiveInfinity) { "?" } else { "${([Math]::Round($quietSeconds,1))}s" }
                            Write-Log " ForceMode=Extreme wstrzymany po I/O (cisza: $quietInfo)" "INFO"
                        }
                    }
                }
                if ($forceModeAllowed) {
                    if ($forceModeUpper -eq "SILENT LOCK") {
                        $currentState = "Silent"
                        $newMode = "Silent"
                        $aiDecision.Mode = "Silent"
                        $aiDecision.Reason = "ForceMode: Silent Lock (total)"
                        $Script:SilentLockMode = $true
                    }
                    # Balanced Lock
                    elseif ($forceModeUpper -eq "BALANCED LOCK") {
                        $currentState = "Balanced"
                        $newMode = "Balanced"
                        $aiDecision.Mode = "Balanced"
                        $aiDecision.Reason = "ForceMode: Balanced Lock (total)"
                        $Script:BalancedLockMode = $true
                    }
                    # Extreme = staly Turbo (max wydajnosc)
                    elseif ($forceModeUpper -eq "EXTREME") {
                        $currentState = "Turbo"
                        $newMode = "Turbo"
                        $aiDecision.Mode = "Turbo"
                        $aiDecision.Reason = "ForceMode: Extreme (Turbo)"
                    } else {
                        $currentState = $Script:ForceModeFromConfig
                        $newMode = $Script:ForceModeFromConfig
                        $aiDecision.Mode = $Script:ForceModeFromConfig
                        $aiDecision.Reason = "ForceMode: $($Script:ForceModeFromConfig)"
                    }
                    $aiDecision.Score = 50
                    # SKIP: AI decision + debounce — ForceMode jest absolutny
                } elseif ($ioCanOverride) {
                    # - I/O OVERRIDE: Wysoki I/O nadpisuje ForceMode!
                    $currentState = "Turbo"
                    $aiDecision.Mode = "Turbo"
                    $aiDecision.Reason = "- I/O Override: $([int]$currentIOTotal) MB/s > $($Script:IOTurboThreshold) MB/s"
                    $aiDecision.Score = 90
                } else {
                # ═══════════════════════════════════════════════════════════════════════════
                # V42 → V45: AI-FIRST DECISION + SAFETY OVERRIDES
                # AI Coordinator waży 18 silników ZAWSZE, hardcoded reguły tylko jako safety net
                # ═══════════════════════════════════════════════════════════════════════════
                
                $gpuLoad = if ($currentMetrics.GPU) { $currentMetrics.GPU.Load } else { 0 }
                $ioTotal = $diskReadMB + $diskWriteMB
                
                if (-not $Script:V42_PrevMode) { $Script:V42_PrevMode = "Balanced" }
                if (-not $Script:LastHardLockApp) { $Script:LastHardLockApp = $null }
                
                $silentExitThreshold = if ($null -ne $Script:BalancedThreshold) { $Script:BalancedThreshold } else { 35 }
                $turboEntryThreshold = if ($null -ne $Script:TurboThreshold) { $Script:TurboThreshold } else { 70 }
                $turboExitThreshold = [Math]::Max(30, $turboEntryThreshold - 30)
                
                $prevMode = $Script:V42_PrevMode
                $newMode = "Balanced"
                $reason = "DEFAULT"
                
                # ═══════════════════════════════════════════════════════════════════════════
                # 0. HARDLOCK - ABSOLUTNY PRIORYTET (user wymusza tryb per-app)
                # ═══════════════════════════════════════════════════════════════════════════
                $hardLockBlocked = $false
                if ($currentForeground -and $currentForeground -notin @("Desktop", "explorer", "Explorer", "ShellExperienceHost", "StartMenuExperienceHost", "SearchHost", "Widgets")) {
                    $appLower = $currentForeground.ToLower() -replace '\.exe$', ''
                    $rawProcessName = ""
                    try {
                        $hwnd = [Win32]::GetForegroundWindow()
                        if ($hwnd -ne [IntPtr]::Zero) {
                            $pid2 = 0; [Win32]::GetWindowThreadProcessId($hwnd, [ref]$pid2) | Out-Null
                            if ($pid2 -gt 0) { $rawProcessName = (Get-Process -Id $pid2 -ErrorAction SilentlyContinue).ProcessName.ToLower() -replace '\.exe$', '' }
                        }
                    } catch {}
                    foreach ($key in $Script:AppCategoryPreferences.Keys) {
                        $keyLower = $key.ToLower() -replace '\.exe$', ''
                        $matchFound = ($keyLower -eq $rawProcessName) -or
                                  ($keyLower -eq $appLower) -or
                                  ($appLower -like "*$keyLower*") -or
                                  ($keyLower -like "*$appLower*") -or
                                  ($keyLower -eq "google chrome" -and $appLower -eq "chrome") -or
                                  ($keyLower -eq "chrome" -and $appLower -eq "chrome")
                        if ($matchFound) {
                            $pref = $Script:AppCategoryPreferences[$key]
                            if ($pref.HardLock) {
                                $hardLockBias = $pref.Bias
                                $hardLockMode = if ($hardLockBias -le 0.2) { "Silent" } 
                                               elseif ($hardLockBias -ge 0.8) { "Turbo" } 
                                               else { "Balanced" }
                                $newMode = $hardLockMode
                                $reason = "HARDLOCK: $currentForeground=$hardLockMode key=$key bias=$([Math]::Round($hardLockBias,2))"
                                $hardLockBlocked = $true
                                if ($currentMetrics.Temp -gt 95 -and $hardLockMode -ne "Silent") {
                                    $newMode = "Silent"
                                    $reason = "THERMAL-SAFETY: $([int]$currentMetrics.Temp)C overrides HARDLOCK ($hardLockMode)"
                                }
                                break
                            }
                        }
                    }
                }
                
                # v42.5 FIX: GPU-BOUND detection — wywoływaj ZAWSZE (nie tylko gdy confident!)
                # Detect() buduje confidence wewnętrznie — musi być wywoływany co tick
                $gpuBoundHandled = $false
                $gpuBoundResult = $null
                
                if (-not $hardLockBlocked -and $gpuBound -and $gpuLoad -gt 0) {
                    try {
                        $gpuType = "dGPU"
                        if ($Script:HasiGPU -and -not $Script:HasdGPU) { $gpuType = "iGPU" }
                        elseif ($Script:HasiGPU -and $Script:HasdGPU) { $gpuType = if ($gpuLoad -gt 50) { "dGPU" } else { "iGPU" } }
                        $gpuBound.CurrentPhase = $phaseDetector.CurrentPhase
                        $gpuBoundResult = $gpuBound.Detect($currentMetrics.CPU, $gpuLoad, ($Script:HasiGPU -or $Script:HasdGPU), $gpuType)
                        if ($gpuBoundResult.IsGPUBound) {
                            $gpuBoundHandled = $true
                            $newMode = $gpuBoundResult.SuggestedMode
                            $reason = $gpuBoundResult.Reason
                        }
                    } catch { $gpuBoundHandled = $false }
                }
                
                # ═══════════════════════════════════════════════════════════════════════════
                # GŁÓWNA DECYZJA: AI COORDINATOR — waży WSZYSTKIE 18 silników
                # Safety overrides interweniują TYLKO w ekstremalnych sytuacjach
                # ═══════════════════════════════════════════════════════════════════════════
                if (-not $hardLockBlocked -and -not ($gpuBoundHandled -and $gpuBoundResult -and $gpuBoundResult.IsGPUBound)) {
                    
                    # SAFETY OVERRIDE 1: THERMAL EMERGENCY (>90°C) — bezpieczeństwo sprzętu
                    if ($currentMetrics.Temp -gt 90) {
                        $newMode = "Silent"
                        $reason = "THERMAL: $([int]$currentMetrics.Temp)C"
                    }
                    # SAFETY OVERRIDE 2: HEAVY I/O BURST (>300MB/s + CPU>60%) — nie blokuj dysków
                    elseif ($ioTotal -gt 300 -and $currentMetrics.CPU -gt 60) {
                        $newMode = "Turbo"
                        $reason = "HEAVY I/O: $([int]$ioTotal)MB CPU=$([int]$currentMetrics.CPU)%"
                    }
                    # AI COORDINATOR — pełna inteligencja 18 silników
                    else {
                        try {
                            $coordResult = $aiCoordinator.DecideMode(
                                $modelScores,
                                $currentMetrics.CPU,
                                $gpuLoad,
                                $currentMetrics.Temp,
                                $prevMode,
                                $qAction,
                                $currentForeground,
                                $phaseDetector.CurrentPhase
                            )
                            $newMode = $coordResult.Mode
                            $reason = $coordResult.Reason
                        } catch {
                            try { Add-Content -Path "$Script:ConfigDir\ErrorLog.txt" -Value "[AI-COORD ERROR] $($_.Exception.Message)" -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
                            if ($currentMetrics.CPU -gt $turboEntryThreshold) { $newMode = "Turbo"; $reason = "FALLBACK-HIGH" }
                            elseif ($currentMetrics.CPU -lt 20) { $newMode = "Silent"; $reason = "FALLBACK-LOW" }
                            else { $newMode = "Balanced"; $reason = "FALLBACK-ERR" }
                        }
                    }
                }
                
                # ═══════════════════════════════════════════════════════════════
                # MODE STABILITY SYSTEM - anty-pingpong debounce
                # Zapobiega: Silent→Balanced→Turbo→Silent co 1-2 sekundy
                # Typowe przy przeglądaniu stron (CPU skacze 15-40%)
                # SKIP: Nie stosuj debounce gdy ForceMode/I/O override aktywne!
                # ═══════════════════════════════════════════════════════════════
                if (-not $forceModeAllowed -and -not $ioCanOverride -and -not $hardLockBlocked) {
                if (-not $Script:ModeHoldStart) { $Script:ModeHoldStart = [DateTime]::UtcNow }
                if (-not $Script:ModeHoldConfirmCount) { $Script:ModeHoldConfirmCount = 0 }
                if (-not $Script:ModeHoldCandidate) { $Script:ModeHoldCandidate = $null }
                
                $modeHoldSeconds = ([DateTime]::UtcNow - $Script:ModeHoldStart).TotalSeconds
                $modeMinHoldTime = $Script:ModeHoldTime  # Konfigurowalne (domyslnie 6s)
                
                if ($newMode -ne $prevMode) {
                    # Wyjątki - natychmiastowa zmiana (bez debounce):
                    $instantChange = ($reason -match "^THERMAL|^HARDLOCK|^GAMING|^HEAVY") -or
                                     ($newMode -eq "Silent" -and $currentMetrics.CPU -lt $Script:ForceSilentCPU) -or
                                     ($newMode -eq "Turbo"  -and $currentMetrics.CPU -ge $turboEntryThreshold) -or
                                     ($newMode -eq "Silent" -and $prevMode -eq "Turbo" -and $currentMetrics.CPU -lt 25)
                    
                    if ($instantChange) {
                        # Krytyczne - zmień natychmiast
                        $Script:ModeHoldStart = [DateTime]::UtcNow
                        $Script:ModeHoldConfirmCount = 0
                        $Script:ModeHoldCandidate = $null
                    }
                    elseif ($modeHoldSeconds -lt $modeMinHoldTime) {
                        # Za wcześnie na zmianę - trzymaj obecny tryb
                        # Ale licz potwierdzenia (jeśli ten sam kandydat wraca)
                        if ($Script:ModeHoldCandidate -eq $newMode) {
                            $Script:ModeHoldConfirmCount++
                        } else {
                            $Script:ModeHoldCandidate = $newMode
                            $Script:ModeHoldConfirmCount = 1
                        }
                        
                        # Jeśli 3+ potwierdzenia tego samego trybu - pozwól zmienić wcześniej
                        if ($Script:ModeHoldConfirmCount -ge 3) {
                            $Script:ModeHoldStart = [DateTime]::UtcNow
                            $Script:ModeHoldConfirmCount = 0
                            $Script:ModeHoldCandidate = $null
                            $reason = "$reason [CONFIRMED x4]"
                        } else {
                            $newMode = $prevMode  # BLOKUJ zmianę
                            $reason = "HOLD($([int]$modeHoldSeconds)s/$($modeMinHoldTime)s): wanted $($Script:ModeHoldCandidate) x$($Script:ModeHoldConfirmCount)"
                        }
                    }
                    else {
                        # Minął hold time - pozwól zmienić
                        $Script:ModeHoldStart = [DateTime]::UtcNow
                        $Script:ModeHoldConfirmCount = 0
                        $Script:ModeHoldCandidate = $null
                    }
                }
                # ═══════════════════════════════════════════════════════════════
                
                # v43.14: GLOBAL MINIMUM HOLD TIME - zapobiega ping-pong
                # WYJĄTKI: THERMAL, HARDLOCK, safety overrides
                if (-not $Script:LastModeChangeTime) { $Script:LastModeChangeTime = [datetime]::MinValue }
                if ($newMode -ne $prevMode) {
                    $holdElapsed = ((Get-Date) - $Script:LastModeChangeTime).TotalSeconds
                    $isSafetyOverride = ($reason -match "THERMAL|HARDLOCK|GPU-BOUND|PAUSED|ForceMode|HEAVY I/O|CONFIRMED")
                    $globalHoldSecs = [Math]::Max(4, [int]($Script:ModeHoldTime * 0.8))
                    if ($holdElapsed -lt $globalHoldSecs -and -not $isSafetyOverride) {
                        $newMode = $prevMode
                        $reason = "HOLD-MIN-TIME: $([int]$holdElapsed)/$($globalHoldSecs)s (blocked: $reason)"
                    } else {
                        $Script:LastModeChangeTime = Get-Date
                    }
                }
                
                $aiDecision.Mode = $newMode
                $aiDecision.Reason = $reason
                $aiDecision.Score = switch ($newMode) { "Turbo"{85} "Silent"{25} default{50} }
                }  # KONIEC if (-not $forceModeAllowed -and -not $ioCanOverride -and -not $hardLockBlocked)
                
                # Log tylko przy ZMIANIE trybu
                if ($newMode -ne $prevMode) { 
                    Add-Log "V42: $prevMode -> $newMode | $reason"
                    Write-DebugLog "MODE CHANGE: $prevMode -> $newMode | Reason: $reason | CPU=$([int]$currentMetrics.CPU)%, GPU=$([int]$gpuLoad)% | Phase=$($phaseDetector.CurrentPhase) Suggest=$($phaseDetector.GetRecommendedMode())" "MODE"
                }
                
                # Zapisz dla następnej iteracji
                $Script:V42_PrevMode = $newMode
                
                $currentState = $newMode
                
                # v44.0: SYSTEM GOVERNOR - przejęcie kontroli od Windows
                if ($systemGovernor -and $systemGovernor.IsGoverning) {
                    try {
                        $govPM = @{}
                        if ($proBalance -and $proBalance.ProcessCPU.Count -gt 0) {
                            foreach ($pid in $proBalance.ProcessCPU.Keys) {
                                $pD = $proBalance.ProcessCPU[$pid]
                                if ($pD.History.Count -gt 0) {
                                    $govPM[$pid] = @{ Name = $pD.Name; PID = $pid; CPU = $pD.History[$pD.History.Count - 1] }
                                }
                            }
                        }
                        $govR = $systemGovernor.Govern($currentMetrics.CPU, $gpuLoad, $currentMetrics.Temp, $currentForeground, $currentState, $govPM)
                        if ($govR.ModeOverride -and $govR.IsOverloaded -and -not $hardLockBlocked) {
                            $prevSt = $currentState; $currentState = $govR.ModeOverride; $newMode = $currentState; $Script:V42_PrevMode = $newMode
                            $aiDecision.Reason = "GOVERNOR: $($govR.OverloadReason)"
                            if ($prevSt -ne $currentState) { Add-Log "- GOVERNOR: $prevSt → $currentState | $($govR.OverloadReason)" }
                        }
                        if ($govR.GPUAction -and $govR.GPUAction.Action) { Add-Log " GOV-GPU: $($govR.GPUAction.App) → $($govR.GPUAction.GPU) ($($govR.GPUAction.Reason))" }
                    } catch {}
                }
                
                # v42.6 FIX BUG #3: Energy Tracker - zapisuj efektywność decyzji
                if ($energyTracker -and (Is-EnergyEnabled)) {
                    $energyTracker.Record($newMode, $currentMetrics.CPU, $currentMetrics.Temp, $isUserActive)
                }
                
                # v42.6 FIX BUG #4: SelfTuner - zapisuj decyzje do późniejszej ewaluacji
                if ($selfTuner -and (Is-SelfTunerEnabled)) {
                    $selfTuner.RecordDecision($newMode, $currentMetrics.CPU, $currentMetrics.Temp, $aiDecision.Score, $ioTotal)
                }
                
                # Brain Evolve feedback - ucz AggressionBias z finalnej decyzji AI (tylko przy zmianie trybu)
                if ($brain -and (Is-NeuralBrainEnabled) -and $newMode -ne $prevMode) {
                    $brain.Evolve($newMode)
                }
                
                # v40.2 FIX: Bandit feedback - ocen czy wybrany arm był trafny
                if ($bandit -and (Is-BanditEnabled) -and $banditAction) {
                    # Success = tryb bandita zgadza się z finalną decyzją LUB był odpowiedni dla CPU
                    $banditSuccess = ($banditAction -eq $newMode) -or
                        ($banditAction -eq "Turbo" -and $currentMetrics.CPU -gt 60) -or
                        ($banditAction -eq "Silent" -and $currentMetrics.CPU -lt 25) -or
                        ($banditAction -eq "Balanced" -and $currentMetrics.CPU -ge 25 -and $currentMetrics.CPU -le 60)
                    $bandit.Update($banditAction, $banditSuccess)
                }
                
                # v40.2 FIX: Ensemble feedback - ocen które modele trafiły z finalną decyzją
                if ($ensemble -and (Is-EnsembleEnabled) -and $modelScores) {
                    foreach ($modelKey in $modelScores.Keys) {
                        $modelMode = if ($modelScores[$modelKey] -gt 70) { "Turbo" } elseif ($modelScores[$modelKey] -lt 35) { "Silent" } else { "Balanced" }
                        $ensemble.UpdateAccuracy($modelKey, ($modelMode -eq $newMode))
                    }
                }
                }
            } else {
                $currentState = $manualMode
                $aiDecision = @{ 
                    Score = 0
                    Mode = $manualMode
                    Reason = "Manual"
                    Trend = 0 
                }
            }
            # #
            # #
            # AUDIO SAFE MODE: Minimum Balanced gdy DAW/VST aktywne — Silent w czasie gry = dropout
            if ($currentContext -eq "Audio" -and $currentState -eq "Silent" -and -not $Script:SilentLockMode -and -not $Script:UserForcedMode) {
                $currentState = "Balanced"
                if ($aiDecision) { $aiDecision.Reason = "AUDIO-SAFE: min Balanced (dropout prevention)" }
            }
            # IDLE FORCE SILENT - finalny override po decyzji AI
            # Naprawia: procesy tła Windows (Phase=Active CPU=25-40%) wybijają PC z Silent
            # Warunki: użytkownik nieaktywny + CPU poniżej progu + brak boost/hardlock
            if (-not $isUserActive `
                -and $currentMetrics.CPU -lt $Script:ForceSilentCPU `
                -and (-not $watcher.IsBoosting) `
                -and ($null -eq $startupBoostEntry) `
                -and (-not $hardLockBlocked) `
                -and (-not $Script:UserForcedMode -or $Script:UserForcedMode -eq "")) {
                if ($currentState -ne "Silent") {
                    Add-Log "IDLE→Silent: $currentState nadpisane (CPU=$([int]$currentMetrics.CPU)%<$($Script:ForceSilentCPU)%, nieaktywny)"
                    if ($aiDecision) { $aiDecision.Reason = "IDLE-FORCE: CPU=$([int]$currentMetrics.CPU)%<$($Script:ForceSilentCPU)%, inactive" }
                }
                $currentState = "Silent"
            }
            # v43.14: HardLock flag → wyłącza dynamiczne skalowanie (strict Min/Max)
            $isHardLocked = $hardLockBlocked -or $Script:SilentLockMode -or $Script:BalancedLockMode -or ($Script:UserForcedMode -and $Script:UserForcedMode -ne "")
            # 1. USER FORCED MODE - uzytkownik wybral tryb, AI sie uczy ale nie zmienia trybu
            if ($Script:UserForcedMode -and $Script:UserForcedMode -ne "") {
                $aiSuggestion = $currentState  # Zapisz co AI sugerowalo
                $currentState = $Script:UserForcedMode
                $aiDecision.Reason = "User locked: $($Script:UserForcedMode) (AI suggests: $aiSuggestion)"
                Set-PowerMode -Mode $currentState -CurrentCPU $currentMetrics.CPU -HardLock:$isHardLocked
            }
            # 2. SILENT LOCK - calkowita cisza, AI wylaczone
            elseif ($Script:SilentLockMode) {
                $currentState = "Silent"
                $aiDecision.Reason = "Silent Lock (enforced)"
                Set-PowerMode -Mode "Silent" -CurrentCPU $currentMetrics.CPU -HardLock
            }
            # 3. BALANCED LOCK - AI wylaczone, zawsze Balanced
            elseif ($Script:BalancedLockMode) {
                $currentState = "Balanced"
                $aiDecision.Reason = "Balanced Lock (enforced)"
                Set-PowerMode -Mode "Balanced" -CurrentCPU $currentMetrics.CPU -HardLock
            }
            # 4. SILENT MODE (legacy) - AI sugeruje ale zostajemy w Silent
            elseif ($Script:SilentModeActive -and $currentState -ne "Silent") {
                $currentApp = if ($watcher.BoostProcessName) { $watcher.BoostProcessName } else { $currentActiveApp }
                if ($currentApp -and $Script:UserApprovedBoosts.Contains($currentApp)) {
                    Set-PowerMode -Mode $currentState -CurrentCPU $currentMetrics.CPU
                } else {
                    $aiDecision.Reason = "AI suggests: $currentState (Silent enforced)"
                    $currentState = "Silent"
                    Set-PowerMode -Mode "Silent" -CurrentCPU $currentMetrics.CPU -HardLock
                }
            }
            # 5. PELNE AI - AI decyduje o trybie
            else {
                Set-PowerMode -Mode $currentState -CurrentCPU $currentMetrics.CPU -HardLock:$hardLockBlocked
            }
            # UWAGA: NIE resetuj BalancedLockMode/SilentLockMode tutaj!
            # Te flagi są zarządzane TYLKO przez config reload (linie 3243-3267)
            
            # v43.14: FAN CONTROLLER - szybkie zbijanie RPM przy Silent/Paused
            if ($fanController -and $fanController.Enabled) {
                try {
                    $fanResult = $fanController.Update($currentMetrics.Temp, $currentState, $phaseDetector.CurrentPhase)
                    if ($fanResult.Action -ne "none" -and $Global:DebugMode) {
                        Add-Log "FAN: $($fanResult.Action) RPM=$($fanResult.RPM) $($fanResult.Reason)" -Debug
                    }
                } catch { }
            }
            
            Render-UI -Metrics $currentMetrics `
                     -State $currentState `
                     -AIDecision $aiDecision `
                     -Watcher $watcher `
                     -Brain $brain `
                     -Prophet $prophet `
                     -TempSource $metrics.TempSource `
                     -PredictedLoad $predictedLoad `
                     -AnomalyAlert $anomalyAlert `
                     -PriorityCount $priorityManager.GetBoostedCount() `
                     -SelfTunerStatus $selfTuner.GetStatus() `
                     -ChainPrediction $chainPrediction `
                     -TurboThreshold $selfTuner.GetTurboThreshold() `
                     -BalancedThreshold $selfTuner.GetBalancedThreshold() `
                     -ActivityStatus (Get-UserActivityStatus) `
                     -ContextStatus $contextDetector.GetStatus() `
                     -ThermalStatus $thermalPredictor.GetStatus() `
                     -UserPatternStatus $userPatterns.GetStatus() `
                     -TimerStatus $adaptiveTimer.GetStatus() `
                     -GPUInfo $currentMetrics.GPU `
                     -VRMTemp $(if ($currentMetrics.VRM) { $currentMetrics.VRM.Temp } else { 0 }) `
                     -CPUPower $currentMetrics.CPUPower `
                     -ExplainerReason $aiDecision.Reason
            $iteration++
            
            # DISK WRITE CACHE: Flush 1-2 dirty plików na dysk (rozłożone I/O)
            try { $diskCache.Tick() | Out-Null } catch { }
            # v47.3: RAMCache AI tick — full v2 integration (13 features)
            try { 
                if ($appRAMCache) { 
                    $prophetApps = if ($prophet) { $prophet.Apps } else { $null }
                    $chainTrans = if ($chainPredictor) { $chainPredictor.TransitionGraph } else { $null }
                    $ctxGpuLoad = if ($currentMetrics.GPU) { [double]$currentMetrics.GPU.Load } else { 0 }
                    
                    # #3: Heavy Mode — update co tick
                    if (-not [string]::IsNullOrWhiteSpace($currentForeground)) {
                        $appRAMCache.UpdateHeavyMode($currentForeground, $currentMetrics.CPU, $ctxGpuLoad, $prophetApps)
                    }
                    # Profile app modules — co 30 iters gdy brak danych; re-scan co 300 (normal) lub 100 (heavy)
                    # Re-scan wychwytuje nowe podprogramy/pluginy załadowane przez użytkownika w tej sesji
                    if ($iteration % 30 -eq 0 -and -not [string]::IsNullOrWhiteSpace($currentForeground)) {
                        $hasLearned = ($appRAMCache.AppPaths.ContainsKey($currentForeground) -and 
                                       $appRAMCache.AppPaths[$currentForeground].ContainsKey('LearnedFiles') -and 
                                       $appRAMCache.AppPaths[$currentForeground].LearnedFiles -and 
                                       $appRAMCache.AppPaths[$currentForeground].LearnedFiles.Count -gt 0)
                        # v47.4: HEAVY apps re-scan co ~3 min (100 iters) zamiast ~10 min — łapie nowe VST pluginy
                        $rescanInterval = if ($appRAMCache.HeavyMode -and $currentForeground -eq $appRAMCache.HeavyModeApp) { 100 } else { 300 }
                        if (-not $hasLearned -or ($iteration % $rescanInterval -eq 0 -and $iteration -gt 0)) {
                            $appRAMCache.ProfileAppModules($currentForeground)
                        }
                    }
                    # LATE PROFILE QUEUE — obsługa re-skanów odroczonych przez ProfileAppModules
                    # (np. Studio Pro z vstservice.dll → re-profil 90s po starcie gdy pluginy są załadowane)
                    # LaunchRaceTick obsługuje tę kolejkę podczas wyścigu startowego (~15s),
                    # tutaj obsługujemy pozycje które nie wymagają aktywnego wyścigu.
                    if ($appRAMCache.PendingProfileQueue.Count -gt 0 -and -not $appRAMCache.IsInLaunchRace) {
                        $lateNow = [datetime]::Now
                        $lateRemove = [System.Collections.Generic.List[hashtable]]::new()
                        foreach ($lp in $appRAMCache.PendingProfileQueue) {
                            if ($lateNow -ge $lp.ProfileAfter) { $lateRemove.Add($lp) }
                        }
                        foreach ($lr in $lateRemove) {
                            $appRAMCache.PendingProfileQueue.Remove($lr) | Out-Null
                            $appRAMCache.ProfileAppModules($lr.AppName)
                        }
                    }
                    # #8: Session detection
                    $appRAMCache.DetectSession($currentContext, $ctxGpuLoad)
                    
                    # Core: AI Tick (guard band, page fault, eviction, pressure)
                    # v43.15: Przekazujemy score/mode/context z silnika AI do RAMCache
                    $appRAMCache.AITick($prophetApps, $chainTrans, [double]$aiDecision.Score, $currentState, $currentContext)
                    # Core: Batch tick — pliki w porcjach
                    $appRAMCache.BatchTick() | Out-Null
                    
                    # Periodic save — co 100 iteracji (~3 min) zapisz learned data JEŚLI coś się zmieniło
                    if ($iteration % 100 -eq 0 -and $iteration -gt 0) {
                        if ($appRAMCache.IsDirty) {
                            $appRAMCache.SaveState($Script:ConfigDir)
                            $appRAMCache.IsDirty = $false
                            if ($Global:DebugMode) {
                                Add-Log "- RAMCache SAVED: Paths=$($appRAMCache.AppPaths.Count) Class=$($appRAMCache.AppClassification.Count) → C:\CPUManager\RAMCache.json"
                            }
                        }
                    }
                    
                    # Proactive idle cache + idle learning (co 15 iteracji w idle)
                    if (-not $isUserActive -and $currentMetrics.CPU -lt 15 -and $iteration % 15 -eq 0) {
                        $exePaths = if ($performanceBooster) { $performanceBooster.AppExecutablePaths } else { $null }
                        $onBattery = $false
                        try {
                            $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
                            if ($battery -and $battery.BatteryStatus -eq 1) { $onBattery = $true }
                        } catch {}
                        $appRAMCache.ProactiveCacheIdle($prophetApps, $chainTrans, $exePaths, $currentMetrics.Temp, $onBattery, $currentState)
                        $learnResult = $appRAMCache.IdleLearn()
                        if ($learnResult -and $Global:DebugMode) {
                            Add-Log "- RAMCache LEARN: Hit=$($learnResult.HitRate)% Waste=$($learnResult.WasteRate)% Aggr=$($learnResult.Aggressiveness) MaxMB=$($learnResult.MaxCacheMB) Session=$($appRAMCache.CurrentSession) Heavy=$($appRAMCache.HeavyMode)"
                        }
                    }
                } 
            } catch { }
            
            # DEBUG: Log metrics snapshot every 100 iterations (~3-4 minutes)
            if ($Script:DebugLogEnabled -and $iteration % 100 -eq 0) {
                $gpuLoadCurrent = if ($currentMetrics.GPU) { [int]$currentMetrics.GPU.Load } else { 0 }
                Write-DebugLog "METRICS SNAPSHOT [Iter $iteration]: CPU=$([int]$currentMetrics.CPU)%, GPU=$gpuLoadCurrent%, Temp=$([int]$currentMetrics.Temp)C, Mode=$currentState, App=$currentForeground, Phase=$($phaseDetector.CurrentPhase)" "METRICS"
            }
            
            try {
                $storageManager.AutoBackup()
            } catch { }
            # - MEGA DEBUG: Potwierdzenie ze petla dziala (ZAWSZE)
            if ($iteration -eq 1 -or $iteration % 10 -eq 0) {
            }
            # - ULTRA: Update Web Dashboard data
            if ($webDashboard.Running -and $iteration % 3 -eq 0) {
                $dashMetrics = @{
                    CPU = [int]$currentMetrics.CPU
                    Temp = [int]$currentMetrics.Temp
                    Mode = $currentState
                    Activity = Get-UserActivityStatus
                    Context = $currentContext
                    Iteration = $iteration  # v43.15 FIX: monotonic tick counter
                    CPUHistory = $cpuHistory.ToArray()
                    TempHistory = $tempHistory.ToArray()
                    RAM = $ramUsedPercent
                    DiskIO = [Math]::Round(($diskReadSpeed + $diskWriteSpeed) / 1MB, 1)
                    DiskRead = [Math]::Round($diskReadSpeed / 1MB, 1)
                    DiskWrite = [Math]::Round($diskWriteSpeed / 1MB, 1)
                    IOBoost = $Script:IOBoostActive
                    NetDL = [int64]$smoothNetDL
                    NetUL = [int64]$smoothNetUL
                    CpuMHz = $cpuCurrentMHz
                    AI = $aiStatus
                }
                $dashAI = @{
                    Brain = "$($brain.GetCount())w"
                    QLearning = $qLearning.GetStatus()
                    Bandit = $bandit.GetStatus()
                    Genetic = $genetic.GetStatus()
                    Ensemble = $ensemble.GetStatus()
                    Energy = $energyTracker.GetStatus()
                    ModeSwitches = $Global:ModeChangeCount
                    AppsDetected = (Get-Process | Where-Object { $_.MainWindowTitle } | Measure-Object).Count
                    Runtime = [math]::Round($stopwatch.Elapsed.TotalMinutes, 1)
                    CPUType = $Script:CPUType
                    CPUName = $Script:CPUName
                    Engines = $Script:AIEngines
                }
                # Polacz metrics i AI w jeden obiekt
                $combinedDashData = $dashMetrics.Clone()
                foreach ($key in $dashAI.Keys) {
                    $combinedDashData[$key] = $dashAI[$key]
                }
                try {
                    [void]$webDashboard.UpdateData($combinedDashData)
                } catch {
                    # Ignore dashboard errors to prevent freezing
                }
            }
            # - Update Desktop Widget (kazda iteracja) - ZAWSZE zapisuj dane
            try {
                # DEBUG: Sprawdz czy ten block w ogole sie wykonuje
                if ($iteration % 20 -eq 0) {
                }
                $aiStatus = if ($Global:AI_Active) { "ON" } else { "OFF" }
                $activityStatus = if ($isUserActive) { "Active" } else { "Idle" }
                # Uzyj CPU z LHM jesli dostepne, inaczej standardowe
                $cpuToShow = if ($cpuLoadLHM -gt 0) { $cpuLoadLHM } else { [int]$currentMetrics.CPU }
                try {
                    # Ensure DecisionHistory is initialized
                    if (-not $Script:DecisionHistory) {
                        $Script:DecisionHistory = [System.Collections.Generic.List[hashtable]]::new()
                    }
                    # DEBUG: Potwierdzenie ze blok sie wykonuje (log co 10 iteracji)
                    if ($iteration % 10 -eq 0) {
                    }
                    # Pobierz Prophet prediction jesli dostepne
                    # v47 FIX: PRAWDZIWA PREDYKCJA — nie echo CPU, a wiedza o aplikacji
                    $prophetPrediction = 0
                    $prophetDebug = "N/A"
                    $cpuTrend = $forecaster.Trend()
                    
                    if ($prophet -and $currentActiveApp -and $prophet.Apps.ContainsKey($currentActiveApp)) {
                        $appData = $prophet.Apps[$currentActiveApp]
                        $learnedAvgCPU = if ($appData.AvgCPU -gt 0) { [double]$appData.AvgCPU } else { $cpuToShow }
                        $learnedMaxCPU = if ($appData.MaxCPU -gt 0) { [double]$appData.MaxCPU } else { $cpuToShow }
                        $appCategory = $appData.Category
                        $samples = if ($appData.Samples) { $appData.Samples } else { 0 }
                        
                        # ═══ PRAWDZIWA PREDYKCJA: bazuj na WIEDZY, nie na aktualnym CPU ═══
                        # 1. Jeśli CPU ROŚNIE → cel to learnedMaxCPU (app się rozgrzewa)
                        # 2. Jeśli CPU SPADA → cel to learnedAvgCPU (app się stabilizuje)
                        # 3. Jeśli CPU STABILNY → cel to learnedAvgCPU (steady state)
                        
                        if ($cpuTrend -gt 2.0) {
                            # CPU rośnie szybko → przewiduj szczyt na podstawie historii
                            $trendStrength = [Math]::Min(0.8, $cpuTrend / 8.0)
                            $prophetPrediction = [int]($cpuToShow * (1 - $trendStrength) + $learnedMaxCPU * $trendStrength)
                        }
                        elseif ($cpuTrend -gt 0.5) {
                            # CPU rośnie wolno → przewiduj między avg a max
                            $midTarget = ($learnedAvgCPU + $learnedMaxCPU) / 2
                            $prophetPrediction = [int]($cpuToShow * 0.5 + $midTarget * 0.5)
                        }
                        elseif ($cpuTrend -lt -2.0) {
                            # CPU spada szybko → przewiduj dół na podstawie avg
                            $dropTarget = $learnedAvgCPU * 0.7
                            $trendStrength = [Math]::Min(0.7, [Math]::Abs($cpuTrend) / 8.0)
                            $prophetPrediction = [int]($cpuToShow * (1 - $trendStrength) + $dropTarget * $trendStrength)
                        }
                        else {
                            # CPU stabilny → przewiduj learnedAvgCPU (steady state)
                            if ($samples -ge 10) {
                                $prophetPrediction = [int]($cpuToShow * 0.3 + $learnedAvgCPU * 0.7)
                            } else {
                                $prophetPrediction = [int]$cpuToShow  # Za mało danych
                            }
                        }
                        
                        # Sygnały dodatkowe (RAM spike, I/O, ProBalance, Chain)
                        $signalBoost = 0
                        if ($ramAnalyzer -and $ramAnalyzer.SpikeDetected) { $signalBoost += 12 }
                        if ($ramAnalyzer -and $ramAnalyzer.TrendDetected) { $signalBoost += 6 }
                        if ($proBalance -and $proBalance.ThrottledProcesses.Count -gt 0) { 
                            $signalBoost += [Math]::Min(15, $proBalance.ThrottledProcesses.Count * 5) 
                        }
                        if ($Script:IOBoostActive) { $signalBoost += 8 }
                        
                        # Chain Predictor: następna app jest cięższa?
                        if ($chainPredictor -and $chainPredictor.PredictionConfidence -gt 0.3) {
                            $nextApp = $chainPredictor.CurrentPrediction
                            if ($nextApp -and $prophet.Apps.ContainsKey($nextApp)) {
                                $nextAvgCPU = [int]$prophet.Apps[$nextApp].AvgCPU
                                if ($nextAvgCPU -gt $learnedAvgCPU + 15) {
                                    $signalBoost += [Math]::Min(15, [int](($nextAvgCPU - $learnedAvgCPU) * $chainPredictor.PredictionConfidence * 0.4))
                                }
                            }
                        }
                        
                        $prophetPrediction += $signalBoost
                        $prophetPrediction = [Math]::Max(2, [Math]::Min(100, $prophetPrediction))
                        $prophetDebug = "$currentActiveApp=$appCategory(T:$([Math]::Round($cpuTrend,1)),P:$prophetPrediction,A:$([int]$learnedAvgCPU),M:$([int]$learnedMaxCPU))"
                    }
                    elseif ($prophet -and $currentActiveApp) {
                        # Nieznana app — fallback na ekstrapolację trendu
                        $basePrediction = $forecaster.Predict(8)
                        $prophetPrediction = [int][Math]::Max(5, [Math]::Min(95, $basePrediction))
                        $prophetDebug = "$currentActiveApp=Unknown(T:$([Math]::Round($cpuTrend,1)))"
                    }
                    else {
                        # Brak aktywnej app
                        $basePrediction = $forecaster.Predict(8)
                        $prophetPrediction = [int][Math]::Max(5, [Math]::Min(95, $basePrediction))
                        $prophetDebug = "NoApp-T:$([Math]::Round($cpuTrend,1))"
                    }
                    # Pobierz aktualne TDP/Power
                    $currentPower = if ($currentMetrics.CPUPower -and $currentMetrics.CPUPower -gt 0) {
                        [int]$currentMetrics.CPUPower
                    } else {
                        # Szacuj power z mode
                        switch ($currentState) {
                            "Extreme" { 45 }
                            "Turbo" { 35 }
                            "Balanced" { 25 }
                            "Silent" { 15 }
                            default { 20 }
                        }
                    }
                    # Dodaj punkt do historii
                    $anyBoostActive = (
                        ($Script:ActiveStartupBoost -ne $null) -or  # Activity-Based Boost
                        ($Script:IOBoostActive -eq $true) -or       # I/O Boost
                        ($Script:BoostActive -eq $true) -or         # General Boost flag
                        ($manualBoostOverride -eq $true) -or        # Manual Boost
                        ($currentState -eq "Turbo") -or             # Turbo mode = boost
                        ($currentState -eq "Extreme")               # Extreme mode = boost
                    )
                    $historyPoint = @{
                        Time = (Get-Date)
                        CPU = [int]$cpuToShow
                        Mode = $currentState
                        Power = $currentPower
                        Predicted = $prophetPrediction
                        ActivityBoost = $anyBoostActive  # v40: Shows when ANY boost is active
                    }
                    $Script:DecisionHistory.Insert(0, $historyPoint)
                    # Ogranicz do 60 ostatnich punktow (60 sekund)
                    while ($Script:DecisionHistory.Count -gt $Script:DecisionHistoryMaxSize) {
                        $Script:DecisionHistory.RemoveAt($Script:DecisionHistoryMaxSize)
                    }
                    # DEBUG: Log co 5 iteracji (~10s)
                    if ($iteration % 5 -eq 0) {
                    }
                    try {
                        $ramHistoryPoint = @{
                            Time = (Get-Date)
                            RAM = if ($ramInfo) { $ramInfo.RAM } else { 0 }
                            Delta = if ($ramInfo) { $ramInfo.Delta } else { 0 }
                            Acceleration = if ($ramInfo) { $ramInfo.Acceleration } else { 0 }
                            TrendType = if ($ramInfo) { $ramInfo.TrendType } else { "NONE" }
                            Spike = if ($ramInfo) { $ramInfo.Spike } else { $false }
                            Trend = if ($ramInfo) { $ramInfo.Trend } else { $false }
                            App = $currentActiveApp
                            ThresholdZone = if ($ramInfo) { $ramInfo.ThresholdZone } else { "NORMAL" }
                            ThresholdIcon = if ($ramInfo) { $ramInfo.ThresholdIcon } else { "" }
                            ThresholdReason = if ($ramInfo) { $ramInfo.ThresholdReason } else { "" }
                            ThresholdValue = if ($ramInfo) { $ramInfo.Threshold } else { 8.0 }
                            RewardGiven = $false
                            RewardSource = ""
                            RewardValue = 0.0
                        }
                        # Sprawdz czy ktorys z AI engines dal reward w tej iteracji
                        if ($qLearning -and $qLearning.LastReward -ne $null -and $qLearning.LastReward -gt 0) {
                            $ramHistoryPoint.RewardGiven = $true
                            $ramHistoryPoint.RewardSource = "QLearning"
                            $ramHistoryPoint.RewardValue = [Math]::Round($qLearning.LastReward, 2)
                        }
                        elseif ($genetic -and $genetic.LastFitnessImprovement -ne $null -and $genetic.LastFitnessImprovement -gt 0) {
                            $ramHistoryPoint.RewardGiven = $true
                            $ramHistoryPoint.RewardSource = "Genetic"
                            $ramHistoryPoint.RewardValue = [Math]::Round($genetic.LastFitnessImprovement, 2)
                        }
                        elseif ($selfTuner -and $selfTuner.LastReward -ne $null -and $selfTuner.LastReward -gt 0) {
                            $ramHistoryPoint.RewardGiven = $true
                            $ramHistoryPoint.RewardSource = "SelfTuner"
                            $ramHistoryPoint.RewardValue = [Math]::Round($selfTuner.LastReward, 2)
                        }
                        $Script:RAMIntelligenceHistory.Insert(0, $ramHistoryPoint)
                        # Ogranicz do 30 ostatnich punktow
                        while ($Script:RAMIntelligenceHistory.Count -gt $Script:RAMIntelligenceMaxSize) {
                            $Script:RAMIntelligenceHistory.RemoveAt($Script:RAMIntelligenceMaxSize)
                        }
                        if ($iteration % 30 -eq 0 -and $Script:RAMIntelligenceHistory.Count -gt 0) {
                            Add-Log " RAM Intelligence: $($Script:RAMIntelligenceHistory.Count) points, Latest: RAM=$($ramHistoryPoint.RAM)% D=$($ramHistoryPoint.Delta) Reward=$($ramHistoryPoint.RewardGiven)" -Debug
                        }
                    } catch {
                        # Jesli blad, nie przerywaj glownej petli
                    }
                } catch {
                }
                # Skroc nazwe aplikacji dla wyswietlania
                $appDisplay = if ($currentActiveApp.Length -gt 15) { $currentActiveApp.Substring(0,12) + "..." } else { $currentActiveApp }
                
                # v43.3 FIX KRYTYCZNY: Zmienne muszą być PRZED hashtable, nie wewnątrz!
                $neuralBrainEnabledUser = Is-NeuralBrainEnabled
                $ensembleEnabledUser = Is-EnsembleEnabled
                
                $widgetData = @{
                    CPU = $cpuToShow
                    Temp = [int]$currentMetrics.Temp
                    Mode = $currentState
                    AI = $aiStatus
                    Context = $currentContext
                    Phase = $phaseDetector.CurrentPhase
                    PhaseSuggest = $phaseDetector.GetRecommendedMode()
                    Activity = $activityStatus
                    CpuMHz = $cpuCurrentMHz
                    DL = [int64]$smoothNetDL
                    UL = [int64]$smoothNetUL
                    TotalDownloaded = ($Script:PersistentNetDL + $totalBytesRecv)
                    TotalUploaded = ($Script:PersistentNetUL + $totalBytesSent)
                    RAM = $ramUsedPercent
                    Disk = [Math]::Round(($diskReadSpeed + $diskWriteSpeed) / 1MB, 1)
                    DiskRead = [Math]::Round($diskReadSpeed / 1MB, 1)
                    DiskWrite = [Math]::Round($diskWriteSpeed / 1MB, 1)
                    IOBoost = $Script:IOBoostActive
                    #  Extended metrics
                    GPUTemp = if ($currentMetrics.GPU) { $currentMetrics.GPU.Temp } else { 0 }
                    GPULoad = if ($currentMetrics.GPU) { $currentMetrics.GPU.Load } else { 0 }
                    VRMTemp = if ($currentMetrics.VRM) { $currentMetrics.VRM.Temp } else { 0 }
                    CPUPower = if ($currentMetrics.CPUPower) { $currentMetrics.CPUPower } else { 0 }
                    CPUVendor = $Script:CPUVendor
                    CPUModel = $Script:CPUModel
                    CPUGeneration = $Script:CPUGeneration
                    CPUArchitecture = $Script:HybridArchitecture
                    CPUCores = $Script:TotalCores
                    CPUThreads = $Script:TotalThreads
                    IsHybridCPU = $Script:IsHybridCPU
                    PCoreCount = $Script:PCoreCount
                    ECoreCount = $Script:ECoreCount
                    Reason = $aiDecision.Reason
                    App = $currentActiveApp
                    Iteration = $iteration  # v43.15 FIX: monotonic tick counter (was AI-sum that could plateau causing SELF-HEAL loops)
                    ActivityLog = @($Script:ActivityLog | Select-Object -First 5)
                    DecisionHistory = @($Script:DecisionHistory | Select-Object -First 30)
                    RAMIntelligenceHistory = @($Script:RAMIntelligenceHistory | Select-Object -First 30)
                    # - V37.7.15: ProBalance data
                    ProBalanceEnabled = if ($proBalance) { $proBalance.Enabled } else { $false }
                    ProBalanceThrottled = if ($proBalance) { $proBalance.ThrottledProcesses.Count } else { 0 }
                    ProBalanceTotalThrottles = if ($proBalance) { $proBalance.TotalThrottles } else { 0 }
                    ProBalanceTotalRestores = if ($proBalance) { $proBalance.TotalRestores } else { 0 }
                    ProBalanceThreshold = if ($proBalance) { $proBalance.ThrottleThreshold } else { 80 }
                    ProBalanceThrottledList = if ($proBalance -and $proBalance.ThrottledProcesses.Count -gt 0) { 
                        @($proBalance.ThrottledProcesses.Values | ForEach-Object { "$($_.Name) ($($_.CPUAtThrottle)%)" })
                    } else { @() }
                    ProBalanceHistory = @($Script:ProBalanceHistory | Select-Object -First 30)
                    PerfBoosterEnabled = if ($performanceBooster) { $performanceBooster.Enabled } else { $false }
                    PerfBoosterPreemptiveBoosts = if ($performanceBooster) { $performanceBooster.TotalPreemptiveBoosts } else { 0 }
                    PerfBoosterPriorityBoosts = if ($performanceBooster) { $performanceBooster.TotalPriorityBoosts } else { 0 }
                    PerfBoosterFreezes = if ($performanceBooster) { $performanceBooster.TotalFreezes } else { 0 }
                    PerfBoosterCacheWarms = if ($performanceBooster) { $performanceBooster.TotalCacheWarms } else { 0 }
                    PerfBoosterCurrentlyFrozen = if ($performanceBooster) { $performanceBooster.FrozenProcesses.Count } else { 0 }
                    # v47: AppRAMCache stats
                    RAMCacheSizeMB = if ($appRAMCache) { [int]$appRAMCache.TotalCachedMB } else { 0 }
                    RAMCacheMaxMB = if ($appRAMCache) { $appRAMCache.MaxCacheMB } else { 0 }
                    RAMCacheApps = if ($appRAMCache) { $appRAMCache.CachedApps.Count } else { 0 }
                    RAMCacheHits = if ($appRAMCache) { $appRAMCache.TotalHits } else { 0 }
                    RAMCachePreloads = if ($appRAMCache) { $appRAMCache.TotalPreloads } else { 0 }
                    RAMCacheMisses = if ($appRAMCache) { $appRAMCache.TotalMisses } else { 0 }
                    RAMCacheWasted = if ($appRAMCache) { $appRAMCache.TotalWastedPreloads } else { 0 }
                    RAMCacheAggressiveness = if ($appRAMCache) { [Math]::Round($appRAMCache.Aggressiveness, 2) } else { 0 }
                    RAMCacheMemPressure = if ($appRAMCache) { [Math]::Round($appRAMCache.MemoryPressure, 2) } else { 0 }
                    RAMCacheBatchPending = if ($appRAMCache) { $appRAMCache.BatchQueue.Count } else { 0 }
                    RAMCacheHeavyMode = if ($appRAMCache) { $appRAMCache.HeavyMode } else { $false }
                    RAMCacheHeavyApp = if ($appRAMCache) { $appRAMCache.HeavyModeApp } else { "" }
                    RAMCacheSession = if ($appRAMCache) { $appRAMCache.CurrentSession } else { "N/A" }
                    RAMCacheProtectedApps = if ($appRAMCache) { $appRAMCache.ProtectedApps.Count } else { 0 }
                    RAMCacheAltTabProtected = if ($appRAMCache) { $appRAMCache.AltTabProtection.Count } else { 0 }
                    RAMCacheGuardBandMB = if ($appRAMCache) { if ($appRAMCache.HeavyMode) { $appRAMCache.GuardBandHeavyMB } else { $appRAMCache.GuardBandMB } } else { 0 }
                    RAMCacheStatus = if ($appRAMCache) { $appRAMCache.GetStatus() } else { "N/A" }
                    PerfBoosterKnownHeavyApps = if ($performanceBooster) { $performanceBooster.KnownHeavyApps.Count } else { 0 }
                    PerfBoosterLastReason = if ($performanceBooster) { $performanceBooster.LastBoostReason } else { "" }
                    OptimizationCacheSize = if ($prophet) { $prophet.GetAppCount() } else { 0 }
                    FastBootAppsCount = if ($chainPredictor -and $chainPredictor.TransitionGraph) { $chainPredictor.TransitionGraph.Count } else { 0 }
                    LaunchHistorySize = if ($loadPredictor -and $loadPredictor.AppLaunchPatterns) { $loadPredictor.AppLaunchPatterns.Count } else { 0 }
                    SilentMode = $Script:SilentModeActive
                    SilentLock = $Script:SilentLockMode
                    UserForcedMode = $Script:UserForcedMode
                    AutoRestoreIn = 0
                    # #
                    # AI Engine Status (zmienne zdefiniowane przed hashtable)
                    # #
                    Brain = if ($neuralBrainEnabledUser) {
                        if ($brain -and $brain.GetCount() -gt 0) { 
                            "$($brain.GetCount()) wag" 
                        } else { 
                            "ON (waiting)"  # Pokazuje ze jest wlaczony ale czeka na decyzje
                        }
                    } else {
                        if ($brain -and $brain.GetCount() -gt 0) {
                            "$($brain.GetCount()) wag (OFF)"  # Dane istnieja ale silnik wylaczony
                        } else {
                            "OFF"
                        }
                    }
                    QLearning = if ($qLearning) { "Q:$($qLearning.QTable.Count) Upd:$($qLearning.TotalUpdates)" } else { "Q:0 Upd:0" }
                    Bandit = if ($bandit) { $bandit.GetStatus() } else { "T:0% B:0% S:0%" }
                    Genetic = if ($genetic) { "Gen:$($genetic.Generation) Fit:$([Math]::Round($genetic.BestFitness, 2))" } else { "Gen:0 Fit:0" }
                    Ensemble = if ($ensembleEnabledUser) {
                        if ($ensemble -and $ensemble.TotalVotes -gt 0) { 
                            $ensemble.GetStatus() 
                        } else { 
                            "ON (waiting)"  # Pokazuje ze jest wlaczony ale czeka na uzycie
                        }
                    } else { 
                        "OFF" 
                    }
                    Energy = if ($energyTracker) { $energyTracker.GetStatus() } else { "Eff:0%" }
                    Prophet = if ($prophet) { "$($prophet.GetAppCount()) apps" } else { "0 apps" }
                    SelfTuner = if ($selfTuner -and $selfTuner.DecisionHistory) { $selfTuner.GetStatus() } else { "Good:0/0" }
                    Chain = if ($chainPredictor) { "$($chainPredictor.TotalPredictions) pred" } else { "0 pred" }
                    Anomaly = if ([string]::IsNullOrWhiteSpace($anomalyAlert)) { "OK" } else { $anomalyAlert }
                    Thermal = if ($currentMetrics.Temp -gt 0) { "Pred:$([int]($currentMetrics.Temp + 2))C" } else { "N/A" }
                    Patterns = if ($isUserActive) { "Active" } else { "Idle" }
                    # #
                    # #
                    AIMetrics = @{
                        Brain = if ($brain) { [Math]::Min(100, $brain.GetCount()) } else { 0 }
                        # Prophet: Apps count normalized (max 100 apps = 100%)
                        Prophet = if ($prophet) { [Math]::Min(100, $prophet.GetAppCount()) } else { 0 }
                        # QLearning: States + Updates combined (max ~200 = 100%)
                        QLearning = if ($qLearning) { [Math]::Min(100, [int](($qLearning.QTable.Count + $qLearning.TotalUpdates / 10) / 2)) } else { 0 }
                        # Bandit: Success rate for best arm (already 0-100%)
                        Bandit = if ($bandit) { [int]([Math]::Max($bandit.GetArmProbability("Turbo"), [Math]::Max($bandit.GetArmProbability("Balanced"), $bandit.GetArmProbability("Silent"))) * 100) } else { 0 }
                        # Genetic: Generation + Fitness combined (max Gen 50 + Fit 1.0 = 100%)
                        Genetic = if ($genetic) { [Math]::Min(100, [int]($genetic.Generation * 2 + $genetic.BestFitness * 50)) } else { 0 }
                        # Ensemble: Best model accuracy (already 0-100%) - V37.7.5 FIX: 0 jesli OFF
                        Ensemble = if ($ensembleEnabledUser) { 
                            if ($ensemble) { [int](($ensemble.Accuracy.Values | Measure-Object -Maximum).Maximum * 100) } else { 0 } 
                        } else { 
                            0 
                        }
                        # Energy: Efficiency (already 0-100%)
                        Energy = if ($energyTracker) { [int]($energyTracker.CurrentEfficiency * 100) } else { 50 }
                        # SelfTuner: Good decisions ratio (0-100%)
                        SelfTuner = if ($selfTuner -and $selfTuner.DecisionHistory.Count -gt 0) { 
                            $good = ($selfTuner.DecisionHistory | Where-Object { $_.Score -gt 50 }).Count
                            [Math]::Min(100, [int]($good / [Math]::Max(1, $selfTuner.DecisionHistory.Count) * 100))
                        } else { 50 }
                        # Chain: Predictions made normalized (max 500 = 100%)
                        Chain = if ($chainPredictor) { [Math]::Min(100, [int]($chainPredictor.TotalPredictions / 5)) } else { 0 }
                        # Anomaly: Inverted (0 = healthy = 100%, high = problem = low%)
                        Anomaly = if ([string]::IsNullOrWhiteSpace($anomalyAlert)) { 100 } else { 20 }
                        # Thermal: Temperature health (cold = 100%, hot = 0%)
                        Thermal = if ($currentMetrics.Temp -gt 0) { [Math]::Max(0, 100 - [int](($currentMetrics.Temp - 30) * 1.4)) } else { 50 }
                        # Patterns: User activity detection confidence
                        Patterns = if ($isUserActive) { 80 } else { 30 }
                    }
                    TopModel = if ($ensembleDecision -and $ensembleEnabled) { "Ensemble" } 
                               elseif ($manualBoostOverride) { "Prophet" }
                               elseif ($aiDecision.Mode -eq $currentState) { "Brain" }
                               else { "Rules" }
                    ActiveEngine = if ($aiCoordinator) { $aiCoordinator.ActiveEngine } else { "QLearning" }
                    CoordinatorStatus = if ($aiCoordinator) { $aiCoordinator.GetStatus() } else { "N/A" }
                    TransferCount = if ($aiCoordinator) { $aiCoordinator.TransferCount } else { 0 }
                    RAMUsage = if ($ramInfo) { $ramInfo.RAM } else { 0 }
                    RAMDelta = if ($ramInfo) { $ramInfo.Delta } else { 0 }
                    RAMSpike = if ($ramInfo) { $ramInfo.Spike } else { $false }
                    RAMTrend = if ($ramInfo) { $ramInfo.Trend } else { $false }
                    RAMThreshold = if ($ramInfo) { $ramInfo.Threshold } else { 8 }
                    ProphetLearnedApps = if ($prophet) { $prophet.GetAppCount() } else { 0 }
                    ProphetTotalSessions = if ($prophet) { $prophet.TotalSessions } else { 0 }
                    RAMAnalyzerSpikes = if ($ramAnalyzer) { $ramAnalyzer.TotalSpikesDetected } else { 0 }
                    RAMAnalyzerTrends = if ($ramAnalyzer) { $ramAnalyzer.TotalTrendsDetected } else { 0 }
                    RAMAnalyzerPreBoosts = if ($ramAnalyzer) { $ramAnalyzer.TotalPreBoosts } else { 0 }
                    RAMAnalyzerStatus = if ($ramAnalyzer) { $ramAnalyzer.GetStatus() } else { "N/A" }
                    # Legacy compatibility
                    RAMLearnedApps = if ($ramAnalyzer) { $ramAnalyzer.GetLearnedAppsCount() } else { 0 }
                    RAMAppsNeedingBoost = if ($ramAnalyzer) { $ramAnalyzer.GetAppsNeedingBoostCount() } else { 0 }
                    RAMSpikesTotal = if ($ramAnalyzer) { $ramAnalyzer.TotalSpikesDetected } else { 0 }
                    RAMTrendsTotal = if ($ramAnalyzer) { $ramAnalyzer.TotalTrendsDetected } else { 0 }
                    RAMPreBoostsTotal = if ($ramAnalyzer) { $ramAnalyzer.TotalPreBoosts } else { 0 }
                    RAMStatus = if ($ramAnalyzer) { $ramAnalyzer.GetStatus() } else { "N/A" }
                    # - V35 NEW: EcoMode
                    EcoMode = $Global:EcoMode
                    TotalAIActivity = 0  # Obliczone ponizej
                    ModeSwitches = if ($Global:ModeChangeCount) { $Global:ModeChangeCount } else { 0 }
                    Runtime = if ($Script:StartTime) { [Math]::Round(([DateTime]::Now - $Script:StartTime).TotalMinutes, 1) } else { 0 }
                    DataSources = @{
                        LHMAvailable = $Script:DataSourcesInfo.LHMAvailable
                        OHMAvailable = $Script:DataSourcesInfo.OHMAvailable
                        ActiveSource = $Script:DataSourcesInfo.ActiveSource
                        DetectedSensors = $Script:DataSourcesInfo.DetectedSensors
                    }
                    RAMManagerStats = if ($Script:SharedRAM) {
                        try {
                            $Script:SharedRAM.GetTelemetry()
                        } catch {
                            @{ QueueSize = 0; QueueDrops = 0; BackgroundWrites = 0; BackgroundRetries = 0; IsInitialized = $false }
                        }
                    } else {
                        @{ QueueSize = 0; QueueDrops = 0; BackgroundWrites = 0; BackgroundRetries = 0; IsInitialized = $false }
                    }
                }
                # Oblicz TotalAIActivity jako srednia znormalizowanych metryk
                if ($widgetData.AIMetrics) {
                    $sumActivity = 0
                    foreach ($key in $widgetData.AIMetrics.Keys) {
                        $sumActivity += $widgetData.AIMetrics[$key]
                    }
                    $widgetData.TotalAIActivity = [int]($sumActivity / 12)
                }
                try {
                    if ($null -ne $widgetData) {
                        $prophetVal = $widgetData.Prophet
                        $chainVal = $widgetData.Chain
                        # Check if Prophet contains "pred" (wrong - should be from Chain)
                        if ($prophetVal -match "pred" -and $prophetVal -notmatch "apps") {
                            Add-Log " SYNC ERROR: Prophet='$prophetVal' contains 'pred'! Swapping with Chain='$chainVal'" -Error
                            # Force correct values
                            $widgetData.Prophet = if ($prophet) { "$($prophet.GetAppCount()) apps" } else { "0 apps" }
                            $widgetData.Chain = if ($chainPredictor) { "$($chainPredictor.TotalPredictions) pred" } else { "0 pred" }
                            Add-Log "- FIXED: Prophet='$($widgetData.Prophet)' | Chain='$($widgetData.Chain)'" -Success
                        }
                        # Check if Prophet is empty
                        elseif ([string]::IsNullOrEmpty($prophetVal) -or $prophetVal -eq "---") {
                            Add-Log "[WARN]  Prophet field is empty! Recalculating..." -Warning
                            $widgetData.Prophet = if ($prophet) { "$($prophet.GetAppCount()) apps" } else { "0 apps" }
                        }
                    }
                    $jsonForWidget = $widgetData | ConvertTo-Json -Depth 20 -Compress
                    if ($Script:UseRAMStorage -and $Script:SharedRAM) {
                        try {
                            $Script:SharedRAM.Write("WidgetData", $widgetData)
                        } catch {
                            try { Add-Content -Path 'C:\CPUManager\ErrorLog.txt' -Value "$(Get-Date -Format 'HH:mm:ss') - SharedRAM write error: $_" -Encoding UTF8 } catch {}
                        }
                    }
                    # JSON mode: always write to JSON
                    # RAM mode: JSON backup handled by AutoBackup (every 5 min)
                    # BOTH mode: JSON backup handled by AutoBackup (every 1 min)
                    $shouldWriteJSON = switch ($Script:StorageMode) {
                        "JSON" { $true }
                        "BOTH" { $false }  # AutoBackup handles JSON writes
                        "RAM" { $false }   # AutoBackup handles JSON writes
                        default { $true }
                    }
                    # Throttling: zapisuj co N iteracji (~1.6-2s zamiast co 0.8s)
                    # Change detection: zapisuj tylko gdy dane sie zmienily
                    if ($shouldWriteJSON) {
                        $shouldActuallyWrite = $false
                        # Warunek 1: Minal throttle interval
                        if (($iteration - $Script:LastWidgetWriteIteration) -ge $Script:WidgetWriteThrottle) {
                            # Warunek 2: Dane sie zmienily (porownanie JSON)
                            if ($jsonForWidget -ne $Script:LastWidgetJSON) {
                                $shouldActuallyWrite = $true
                            }
                        }
                        # Pierwsza iteracja - zawsze zapisz
                        if ($iteration -le 2) {
                            $shouldActuallyWrite = $true
                        }
                        if ($shouldActuallyWrite) {
                            try {
                                # ASYNCHRONICZNY ZAPIS - bez blokowania glownego watku!
                                # Uzyj prostego runspace (NIE tworzy procesu, tylko thread w tym samym procesie)
                                $ps = [powershell]::Create()
                                $null = $ps.AddScript({
                                    param($outPath, $json)
                                    try {
                                        $tmp = "$outPath.tmp"
                                        [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
                                        try { 
                                            Move-Item -Path $tmp -Destination $outPath -Force -ErrorAction Stop
                                        } catch { 
                                            Copy-Item -Path $tmp -Destination $outPath -Force
                                            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
                                        }
                                    } catch { }
                                }).AddArgument($desktopWidget.DataFile).AddArgument($jsonForWidget)
                                # BeginInvoke = asynchroniczne wykonanie (NIE BLOKUJE glownego watku!)
                                $null = $ps.BeginInvoke()
                                # Update tracking
                                $Script:LastWidgetWriteIteration = $iteration
                                $Script:LastWidgetJSON = $jsonForWidget
                            } catch {
                                # Silent fail
                            }
                        }
                    }
                } catch { }
                # - Update TDP Learning (AI dla RyzenADJ)
                if ($Script:RyzenAdjAvailable) {
                    $aiScore = if ($Script:AI_Active -and $aiScore) { $aiScore } else { 50 }
                    Update-TDPLearning -Mode $currentState -CPU $cpuToShow -Temp $currentMetrics.Temp -Score $aiScore
                }
                # - Dynamic tray tooltip - pokazuje dane po najechaniu na ikone
                $gpuInfo = if ($widgetData.GPULoad -gt 0) { " | GPU:$($widgetData.GPULoad)%" } else { "" }
                $cpuGHz = [Math]::Round($cpuCurrentMHz / 1000, 2)
                $trayTip = "CPU:$cpuToShow% ${cpuGHz}GHz $([int]$currentMetrics.Temp)C`n"
                $trayTip += "App: $appDisplay`n"
                $trayTip += "$currentState | AI:$aiStatus$gpuInfo"
                if ($Script:MainTray) { $Script:MainTray.Text = $trayTip }
            } catch { }
            # Self-Tuner ewaluacja (co 15 iteracji = ~30 sekund)
            # v42.6: Sprawdź czy włączone w CONFIGURATOR
            if ($iteration - $lastSelfTuneEval -ge 15 -and (Is-SelfTunerEnabled)) {
                $lastSelfTuneEval = $iteration
                $selfTuner.EvaluateDecisions($currentMetrics.CPU, $currentMetrics.Temp)
                #  Szybkie zapisywanie decyzji SelfTunera (co 45 iteracji = ~90 sekund)
                # Zapobiega utracie nauczonego stanu przy naglym wylaczeniu
                if ($iteration % 45 -eq 0) {
                    [void]$selfTuner.SaveState($Script:ConfigDir)
                }
                if ($Global:DebugMode) {
                    Add-Log " Self-Tune: $($selfTuner.GetStatus())" -Debug
                }
            }
            # v42.6 FIX BUG #2: Genetic Optimizer evaluation + evolution (co 30 iteracji = ~60 sekund)
            # v42.6: Sprawdź czy włączone w CONFIGURATOR
            if ($iteration - $lastGeneticEval -ge 30 -and (Is-GeneticEnabled)) {
                $lastGeneticEval = $iteration
                # Oblicz metryki wydajności dla fitness
                $performance = [Math]::Min(1.0, $currentMetrics.CPU / 100.0)
                $efficiency = if (Is-EnergyEnabled) { $energyTracker.CurrentEfficiency } else { 0.5 }
                $thermal = [Math]::Max(0, 1.0 - (($currentMetrics.Temp - 50) / 50.0))  # 50°C=1.0, 100°C=0.0
                # Ewaluuj obecny genom (index 0 = najlepszy z poprzedniej generacji)
                $genetic.EvaluateFitness(0, $performance, $efficiency, $thermal)
                # Evolve co 5 ewaluacji (150 iteracji = ~5 minut)
                if ($genetic.Population[0].Fitness -gt 0 -and $iteration % 150 -eq 0) {
                    $genetic.Evolve()
                    if ($Global:DebugMode) {
                        Add-Log " Genetic evolved: $($genetic.GetStatus())" -Debug
                    }
                }
            }
            # Chain Predictor update (co 20 iteracji)
            if ($iteration - $lastChainCheck -ge 20) {
                $lastChainCheck = $iteration
                $chainPrediction = $chainPredictor.GetPredictionStatus()
            }
            if ($Script:ProphetAutosaveSeconds -gt 0) {
                $secondsSinceProphetSave = ([DateTime]::Now - $prophetLastAutosave).TotalSeconds
                if ($prophet.TotalSessions -gt $prophetLastSavedSessions -and $secondsSinceProphetSave -ge $Script:ProphetAutosaveSeconds) {
                    if (Save-State -Brain $brain -Prophet $prophet) {
                        $prophetLastAutosave = [DateTime]::Now
                        $prophetLastSavedSessions = $prophet.TotalSessions
                        if ($Global:DebugMode) {
                            Add-Log " Prophet autosave tick ($($prophet.GetAppCount()) apps)" -Debug
                        }
                    }
                }
            }
            # Debounced save for PerformanceBooster cache (learned heavy apps)
            try {
                if ($Script:PerformanceCachePath -and $performanceBooster.CacheDirty) {
                    $now = Get-Date
                    $lastChange = $performanceBooster.CacheLastChange
                    if ($lastChange -ne [datetime]::MinValue) {
                        $elapsed = ($now - $lastChange).TotalSeconds
                        if ($elapsed -ge $Script:PerformanceCacheDebounceSec) {
                            try { $performanceBooster.SaveCache($Script:PerformanceCachePath) } catch {}
                        }
                    }
                }
            } catch { }
            # (Zostaje tylko szybki zapis co iteracje ponizej)
            # Iteracja trwa ~800ms-1s, wiec 300 iteracji = ~5 minut
            $backupInterval = switch ($Script:StorageMode) {
                "JSON" { 300 }     # 5 minut
                "RAM" { 300 }      # 5 minut
                "BOTH" { 300 }     # 5 minut
                default { 300 }    # 5 minut
            }
            if ($iteration - $lastSave -ge $backupInterval) {
                $lastSave = $iteration
                # #
                # #
                # Poprzednio: SaveState bylo w if ($StorageMode -eq "RAM" or "BOTH")
                # Problem: W trybie "JSON only" AI engines NIE zapisywaly danych na biezaco
                # Rozwiazanie: Zapis AI poza warunkiem Storage Mode
                # Storage Mode dotyczy tylko WidgetData.json, nie plikow AI (EnsembleWeights.json, etc)
                # Poprzednio: prophet.SaveState() + brain.SaveState() + Save-State() = 3x zapis!
                # Teraz: tylko Save-State() = 1x zapis
                $saveSuccess = Save-State -Brain $brain -Prophet $prophet
                # ═══════════════════════════════════════════════════════════════
                # DISK WRITE CACHE: Zapisz wszystkie komponenty AI do RAM cache
                # Cache flushuje 1-2 pliki/tick zamiast 27 naraz
                # ═══════════════════════════════════════════════════════════════
                try {
                    # Helper: serializuj i zapisz do cache
                    $cacheWrite = {
                        param([string]$file, [object]$data, [int]$depth = 5)
                        try {
                            $json = $data | ConvertTo-Json -Depth $depth -Compress
                            $diskCache.Write($file, $json)
                        } catch {}
                    }
                    # Core AI
                    & $cacheWrite "AnomalyProfiles.json" @{ Profiles = $anomalyDetector.Profiles } 4
                    & $cacheWrite "LoadPatterns.json" @{ Patterns = $loadPredictor.HourlyPatterns; DayPatterns = $loadPredictor.DayOfWeekPatterns } 4
                    & $cacheWrite "SelfTuner.json" @{ History = $selfTuner.TuningHistory; CurrentParams = $selfTuner.CurrentParams }
                    & $cacheWrite "ChainPredictor.json" @{ TransitionMatrix = $chainPredictor.TransitionMatrix }
                    & $cacheWrite "UserPatterns.json" @{ HourlyPatterns = $userPatterns.HourlyPatterns; DayOfWeekPatterns = $userPatterns.DayOfWeekPatterns; AppUsagePatterns = $userPatterns.AppUsagePatterns }
                    # Mega AI
                    & $cacheWrite "QLearning.json" @{ QTable = $qLearning.QTable; ExplorationRate = $qLearning.ExplorationRate; TotalUpdates = $qLearning.TotalUpdates }
                    & $cacheWrite "EnsembleWeights.json" @{ Weights = $ensemble.Weights; Accuracy = $ensemble.Accuracy }
                    & $cacheWrite "EnergyStats.json" @{ ModeStats = $energyTracker.ModeStats; HourlyStats = $energyTracker.HourlyStats }
                    # Ultra AI
                    & $cacheWrite "Bandit.json" @{ Successes = $bandit.Successes; Failures = $bandit.Failures; TotalPulls = $bandit.TotalPulls }
                    & $cacheWrite "Genetic.json" @{ Population = $genetic.Population; Generation = $genetic.Generation }
                    & $cacheWrite "ContextPatterns.json" @{ ContextPatterns = $contextDetector.ContextPatterns }
                    # Phase, Thermal, Explainer, ThermalGuard, AICoordinator, RAMAnalyzer
                    try { $phaseDetector.SaveState($Script:ConfigDir) } catch {}
                    try { $thermalPredictor.SaveState($Script:ConfigDir) } catch {}
                    try { $explainer.SaveState($Script:ConfigDir) } catch {}
                    try { $thermalGuard.SaveState($Script:ConfigDir) } catch {}
                    try { $aiCoordinator.SaveState($Script:ConfigDir) } catch {}
                    try { $ramAnalyzer.SaveState($Script:ConfigDir) } catch {}
                    # Shared knowledge + Network
                    try { $sharedKnowledge.SaveState($Script:ConfigDir) } catch {}
                    try { $networkOptimizer.SaveState($Script:ConfigDir) } catch {}
                    try { $networkAI.Train() } catch {}
                    try { $networkAI.SaveState($Script:ConfigDir) } catch {}
                    # Process AI, GPU AI, SystemGovernor
                    try { $processAI.SaveState($Script:ConfigDir) } catch {}
                    try { $gpuAI.SaveState($Script:ConfigDir) } catch {}
                    try { $systemGovernor.SaveState($Script:ConfigDir) } catch {}
                } catch { }
                if ($systemGovernor -and $systemGovernor.LearnedGPUPrefs.Count -gt 0) {
                    try {
                        foreach ($appKey in $systemGovernor.LearnedGPUPrefs.Keys) {
                            $gp = $systemGovernor.LearnedGPUPrefs[$appKey]
                            if ($gp.Sessions -gt 5) {
                                Append-AILearningEntry @{
                                    Timestamp = (Get-Date).ToString('o')
                                    Source = 'SharedAppKnowledge'; Component = 'Governor'
                                    App = $appKey; PreferredGPU = $gp.Pref
                                    GPUConfidence = [Math]::Round($gp.Confidence, 2)
                                    Sessions = $gp.Sessions
                                }
                            }
                        }
                    } catch {}
                }
                # After saving all AI states, append lightweight NDJSON entries so learning events are persisted incrementally
                function Write-AIAppendAfterSave {
                    param([string]$Name, $Obj)
                    try {
                        $summary = @{}
                        $summary.Timestamp = (Get-Date).ToString('o')
                        if ($Obj -ne $null) {
                            try { $summary.Status = if ($Obj.PSObject.Methods['GetStatus']) { $Obj.GetStatus() } else { $null } } catch { }
                            try { $summary.AppCount = if ($Obj.PSObject.Methods['GetAppCount']) { $Obj.GetAppCount() } else { $null } } catch { }
                            try { $summary.Total = if ($Obj.PSObject.Properties['TotalLearnings']) { $Obj.TotalLearnings } else { $null } } catch { }
                        }
                        $entry = @{ Source = 'AutoSave'; Component = $Name; Summary = $summary }
                        Append-AILearningEntry $entry
                    } catch {
                        # ignore
                    }
                }

                $components = @{
                    'Prophet' = $prophet; 'Brain' = $brain; 'AnomalyDetector' = $anomalyDetector; 'LoadPredictor' = $loadPredictor;
                    'SelfTuner' = $selfTuner; 'ChainPredictor' = $chainPredictor; 'UserPatterns' = $userPatterns; 'QLearning' = $qLearning;
                    'Ensemble' = $ensemble; 'EnergyTracker' = $energyTracker; 'Bandit' = $bandit; 'Genetic' = $genetic;
                    'ContextDetector' = $contextDetector; 'PhaseDetector' = $phaseDetector; 'ThermalPredictor' = $thermalPredictor;
                    'Explainer' = $explainer; 'ThermalGuard' = $thermalGuard; 'AICoordinator' = $aiCoordinator; 'RAMAnalyzer' = $ramAnalyzer;
                    'SharedKnowledge' = $sharedKnowledge; 'NetworkOptimizer' = $networkOptimizer; 'NetworkAI' = $networkAI; 'ProcessAI' = $processAI; 'GPUAI' = $gpuAI
                }
                foreach ($k in $components.Keys) { Write-AIAppendAfterSave -Name $k -Obj $components[$k] }
                # AILearning: flush kompaktowej pamięci do AILearningState.json
                try { Flush-AILearningBuffer -Force } catch { }
                # #
                # BACKUP WIDGETDATA - tylko w RAM/BOTH mode
                # #
                if ($Script:StorageMode -eq "RAM" -or $Script:StorageMode -eq "BOTH") {
                    $backupLabel = if ($Script:StorageMode -eq "RAM") { "5-min" } else { "1-min" }
                    # Backup WidgetData.json w trybie RAM (co 5 min) lub BOTH (co 1 min)
                    if ($widgetData) {
                        try {
                            $jsonBackup = $widgetData | ConvertTo-Json -Depth 10 -Compress
                            [System.IO.File]::WriteAllText($desktopWidget.DataFile, $jsonBackup, [System.Text.Encoding]::UTF8)
                        } catch { }
                    }
                    if ($saveSuccess) { 
                        Add-Log " Auto-save ($backupLabel backup) | Gen:$($genetic.Generation) | $($bandit.GetStatus()) | RAM:$($ramAnalyzer.GetStatus())" 
                    }
                } else {
                    # JSON only mode - AI zapisany, bez WidgetData backup
                    if ($saveSuccess) {
                        Add-Log " Auto-save (AI engines - JSON mode) | Iter:$iteration | Gen:$($genetic.Generation) | $($bandit.GetStatus())"
                    }
                }
                $prophetLastAutosave = [DateTime]::Now
                $prophetLastSavedSessions = $prophet.TotalSessions
            }
            # Rotacja ErrorLog co 600 iteracji (~20 minut)
            if ($iteration % 600 -eq 0) {
                Rotate-ErrorLog
            }
            try {
                $networkStatsPath = Join-Path $Script:ConfigDir "NetworkStats.json"
                $netStats = @{
                    TotalDownloaded = $totalBytesRecv
                    TotalUploaded = $totalBytesSent
                    LastUpdate = (Get-Date).ToString("o")
                }
                $jsonNet = $netStats | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText($networkStatsPath, $jsonNet, [System.Text.Encoding]::UTF8)
            } catch {
                # Ignore errors
            }
            # === SELF-OPTIMIZING RAM v40 ===
            # Aggressive GC when memory usage exceeds threshold
            $currentMemMB = [Math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
            $shouldOptimize = ($iteration - $lastGC -ge 100) -or ($currentMemMB -gt 150)
            if ($shouldOptimize) {
                $lastGC = $iteration
                [System.GC]::Collect(2, [System.GCCollectionMode]::Optimized, $false)
                [System.GC]::WaitForPendingFinalizers()
                # v43.15: USUNIĘTO EmptyWorkingSet — NISZCZYŁO RAMCache!
                # EmptyWorkingSet wyrzuca WSZYSTKIE strony z working set ENGINE
                # w tym MMF-cached pliki apps (1-10GB) → trafiają do Standby List
                # → Windows je zwalnia → RAM "wraca" do poziomu startowego
                # GC.Collect wystarczy do zarządzania managed heap
                if ($Global:DebugMode) {
                    $afterMemMB = [Math]::Round([System.GC]::GetTotalMemory($false) / 1MB, 1)
                    Add-Log "- GC: $currentMemMB MB -> $afterMemMB MB" -Debug
                }
            }
            if ($iteration % 300 -eq 0 -and $iteration -gt 0) {
                # v43.15: USUNIĘTO EmptyWorkingSet — chronij RAMCache working set
                # v43.14: Periodic save SharedAppKnowledge
                try { $sharedKnowledge.SaveState($Script:ConfigDir) } catch {}
            }
            if ($iteration % 200 -eq 0) { 
                $watcher.Refresh()
                $priorityManager.RefreshProcessList()
            }
            if ($iteration % 100 -eq 0 -and $metrics.TempSource -eq "N/A") {
                try {
                    $metrics.InitializeFromDetectedSources()
                    if ($metrics.TempSource -ne "N/A") {
                        Add-Log "- Temperature source found: $($metrics.TempSource)"
                    }
                } catch {
                    # Brak zrodla temperatury - kontynuuj bez bledu
                }
            }
            # === WIDGET COMMAND HANDLING ===
            $cmdFile = Join-Path $Script:ConfigDir 'WidgetCommand.txt'
            if (Test-Path $cmdFile) {
                try {
                    $cmd = Get-Content $cmdFile -Raw -ErrorAction SilentlyContinue
                    if ($cmd) {
                        $cmd = $cmd.Trim().ToUpper()
                        Remove-ExistingFiles @($cmdFile)
                        switch ($cmd) {
                            "SILENT" {
                                # SILENT = AI uczy sie, ale tryb wymuszony na Silent
                                $Global:AI_Active = $true
                                $Script:UserForcedMode = "Silent"
                                $manualMode = "Silent"
                                $Script:SilentModeActive = $false
                                $Script:SilentLockMode = $false
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Silent")
                                Set-PowerMode -Mode "Silent" -CurrentCPU $currentMetrics.CPU
                                Add-Log "- Widget: SILENT (AI learns, mode locked)"
                            }
                            "SILENT_LOCK" {
                                # SILENT LOCK = AI wylaczone, totalna cisza
                                $Global:AI_Active = $false
                                $Script:UserForcedMode = "Silent"
                                $manualMode = "Silent"
                                $Script:SilentModeActive = $false
                                $Script:SilentLockMode = $true
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Silent")
                                Set-PowerMode -Mode "Silent" -CurrentCPU $currentMetrics.CPU
                                Add-Log "- Widget: SILENT LOCK (AI off, total silence)"
                            }
                            "BALANCED" {
                                # BALANCED = AI uczy sie, ale tryb wymuszony na Balanced
                                $Global:AI_Active = $true
                                $Script:UserForcedMode = "Balanced"
                                $manualMode = "Balanced"
                                $Script:SilentModeActive = $false
                                $Script:SilentLockMode = $false
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Balanced")
                                Set-PowerMode -Mode "Balanced" -CurrentCPU $currentMetrics.CPU
                                Add-Log "- Widget: BALANCED (AI learns, mode locked)"
                            }
                            "TURBO" {
                                # TURBO = AI uczy sie, ale tryb wymuszony na Turbo
                                $Global:AI_Active = $true
                                $Script:UserForcedMode = "Turbo"
                                $manualMode = "Turbo"
                                $Script:SilentModeActive = $false
                                $Script:SilentLockMode = $false
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Turbo")
                                Set-PowerMode -Mode "Turbo" -CurrentCPU $currentMetrics.CPU
                                Add-Log " Widget: TURBO (AI learns, mode locked)"
                            }
                            "EXTREME" {
                                # EXTREME = AI wylaczone, maksymalna wydajnosc
                                $Global:AI_Active = $false
                                $Script:UserForcedMode = "Turbo"
                                $manualMode = "Turbo"
                                $Script:SilentModeActive = $false
                                $Script:SilentLockMode = $false
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Turbo")
                                Set-PowerMode -Mode "Turbo" -CurrentCPU $currentMetrics.CPU
                                Set-RyzenAdjMode "Turbo" | Out-Null
                                Add-Log " Widget: EXTREME (AI off, max performance)"
                            }
                            "DEBUG" {
                                $Global:DebugMode = -not $Global:DebugMode
                                Add-Log "- Widget: Debug $(if($Global:DebugMode){'ON'}else{'OFF'})"
                            }
                            "ECO" {
                                # - V35 NEW: Toggle EcoMode
                                $Global:EcoMode = -not $Global:EcoMode
                                Reset-TurboDelay
                                if ($Global:EcoMode) {
                                    Add-Log "- EcoMode: ON (aggressive Silent, delayed Turbo)"
                                } else {
                                    Add-Log " EcoMode: OFF (normal thresholds)"
                                }
                            }
                            "SAVE" {
                                $null = Save-State -Brain $brain -Prophet $prophet
                                [void]$anomalyDetector.SaveProfiles($Script:ConfigDir)
                                [void]$loadPredictor.SavePatterns($Script:ConfigDir)
                                Add-Log " Widget: State saved"
                            }
                            "RESET" {
                                if ($selfTuner) {
                                    for ($h = 0; $h -lt 24; $h++) {
                                        $selfTuner.HourlyProfiles[$h].TurboThreshold = 75.0
                                        $selfTuner.HourlyProfiles[$h].BalancedThreshold = 30.0
                                    }
                                }
                                $Script:UserApprovedBoosts.Clear()
                                Add-Log "- Widget: AI reset"
                            }
                            "FORCE" {
                                $Global:AI_Active = $false
                                Add-Log "- Widget: Force mode locked"
                            }
                            "SHOW_CONSOLE" {
                                try {
                                    $consolePtr = [Console.Window]::GetConsoleWindow()
                                    [Console.Window]::ShowWindow($consolePtr, 5) # SW_SHOW
                                } catch { }
                                Add-Log "- Widget: Console shown"
                            }
                            "HIDE_CONSOLE" {
                                try {
                                    $consolePtr = [Console.Window]::GetConsoleWindow()
                                    [Console.Window]::ShowWindow($consolePtr, 0) # SW_HIDE
                                } catch { }
                                Add-Log "- Widget: Console hidden"
                            }
                            "AI" {
                                $Global:AI_Active = -not $Global:AI_Active
                                if ($Global:AI_Active) {
                                    # AI wlaczone = pelna kontrola, wyczysc wymuszony tryb
                                    $Script:UserForcedMode = ""
                                }
                                $Script:SilentModeActive = $false
                                $Script:SilentLockMode = $false
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                Add-Log " Widget: AI $(if($Global:AI_Active){'ON (full control)'}else{'OFF'})"
                            }
                            "EXIT" {
                                Add-Log "- Widget: EXIT requested"
                                Request-Shutdown -Reason "Widget command EXIT"
                            }
                            default {
                                if ($cmd -match '^PROBALANCETHRESHOLD:(\d+)$') {
                                    $newThreshold = [int]$Matches[1]
                                    if ($newThreshold -ge 20 -and $newThreshold -le 90) {
                                        if ($proBalance) {
                                            $proBalance.ThrottleThreshold = [double]$newThreshold
                                            Add-Log "- ProBalance: Threshold changed to $newThreshold%"
                                            # Zapisz do pliku konfiguracyjnego
                                            $pbConfigPath = Join-Path $Script:ConfigDir "ProBalanceConfig.json"
                                            $pbConfig = @{
                                                ThrottleThreshold = $newThreshold
                                                LastModified = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
                                            }
                                            $pbJson = $pbConfig | ConvertTo-Json -Depth 3 -Compress
                                            try {
                                                [System.IO.File]::WriteAllText($pbConfigPath, $pbJson, [System.Text.Encoding]::UTF8)
                                            } catch { }
                                        }
                                    }
                                }
                            }
                            "SHOW" {
                                if ($desktopWidget -and -not $desktopWidget.IsRunning()) {
                                    $desktopWidget.Start()
                                    Add-Log "Widget: SHOW"
                                }
                            }
                            "HIDE" {
                                if ($desktopWidget -and $desktopWidget.IsRunning()) {
                                    $desktopWidget.Stop()
                                    Add-Log "Widget: HIDE"
                                }
                            }
                            "TOGGLE" {
                                if ($desktopWidget) {
                                    $desktopWidget.Toggle()
                                    Add-Log "Widget: TOGGLE"
                                }
                            }
                            "PROFILE_GAMING" {
                                # GAMING: Turbo + szybkie silniki AI
                                $Global:AI_Active = $true
                                $manualMode = "Turbo"
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Turbo")
                                # Wlacz tylko szybkie silniki
                                $Script:AIEngines = @{
                                    QLearning = $true
                                    Ensemble = $false
                                    Prophet = $false
                                    NeuralBrain = $true
                                    AnomalyDetector = $true
                                    SelfTuner = $false
                                    ChainPredictor = $false
                                    LoadPredictor = $true
                                }
                                Save-AIEnginesConfig | Out-Null
                                Add-Log " PROFILE: GAMING (Turbo + Fast AI)"
                            }
                            "PROFILE_WORK" {
                                # WORK: Balanced + wszystkie silniki AI
                                $Global:AI_Active = $true
                                $manualMode = "Balanced"
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Balanced")
                                   Set-RyzenAdjMode "Balanced" | Out-Null
                                # Wlacz wszystkie silniki
                                $Script:AIEngines = @{
                                    QLearning = $true
                                    Ensemble = $true
                                    Prophet = $true
                                    NeuralBrain = $true
                                    AnomalyDetector = $true
                                    SelfTuner = $true
                                    ChainPredictor = $true
                                    LoadPredictor = $true
                                }
                                Save-AIEnginesConfig | Out-Null
                                Add-Log "- PROFILE: WORK (Balanced + All AI)"
                            }
                            "PROFILE_MOVIE" {
                                # MOVIE: Silent + minimalne AI
                                $Global:AI_Active = $true
                                $manualMode = "Silent"
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                $brain.Evolve("Silent")
                                   Set-RyzenAdjMode "Silent" | Out-Null
                                # Tylko podstawowe silniki
                                $Script:AIEngines = @{
                                    QLearning = $false
                                    Ensemble = $false
                                    Prophet = $false
                                    NeuralBrain = $false
                                    AnomalyDetector = $true
                                    SelfTuner = $false
                                    ChainPredictor = $false
                                    LoadPredictor = $false
                                }
                                Save-AIEnginesConfig | Out-Null
                                Add-Log "- PROFILE: MOVIE (Silent + Minimal AI)"
                            }
                            "CPU_AMD" {
                                Set-CPUTypeManual "AMD"
                                Add-Log "- CPU: Ustawiono AMD Ryzen"
                            }
                            "CPU_INTEL" {
                                Set-CPUTypeManual "Intel"
                                Add-Log "- CPU: Ustawiono Intel Core"
                            }
                            "RESET_LEARNING" {
                                # - Reset wszystkich nauczonych profili per-app
                                Add-Log "- RESET_LEARNING: Rozpoczynam reset profili..."
                                # Reset ProphetMemory
                                if ($prophet -and $prophet.Apps) {
                                    foreach ($appKey in @($prophet.Apps.Keys)) {
                                        $app = $prophet.Apps[$appKey]
                                        if ($app.ManualOverride) { $app.ManualOverride = $false }
                                        if ($app.ManualMode) { $app.ManualMode = "" }
                                        if ($app.ManualTimestamp) { $app.ManualTimestamp = "" }
                                        if ($app.ManualFeedback) { $app.ManualFeedback = @() }
                                        if ($app.LearnedPreference) { $app.LearnedPreference = "" }
                                        if ($app.ManualInterventions) { $app.ManualInterventions = 0 }
                                    }
                                }
                                # Reset SelfTuner
                                if ($selfTuner) {
                                    for ($h = 0; $h -lt 24; $h++) {
                                        $selfTuner.HourlyProfiles[$h].TurboThreshold = 75.0
                                        $selfTuner.HourlyProfiles[$h].BalancedThreshold = 30.0
                                        $selfTuner.HourlyProfiles[$h].AggressionBias = 0.0
                                        $selfTuner.HourlyProfiles[$h].Samples = 0
                                    }
                                    $selfTuner.GoodDecisions = 0
                                    $selfTuner.BadDecisions = 0
                                    $selfTuner.TotalEvaluations = 0
                                }
                                # Zapisz zmiany
                                $null = Save-State -Brain $brain -Prophet $prophet
                                if ($selfTuner) { $selfTuner.SaveState($Script:ConfigDir) }
                                Add-Log "- RESET_LEARNING: Wszystkie profile per-app wyczyszczone"
                            }
                            "AI_RESTORE" {
                                #  Przywroc AI dla aktualnej aplikacji (bez toggle globalnego)
                                $Global:AI_Active = $true
                                $manualMode = ""
                                $Script:LastPowerMode = ""
                                $Script:LastPowerMax = -1
                                # Wyczysc manual override dla aktualnej aplikacji
                                if ($prophet -and $currentActiveApp) {
                                    $appKey = $currentActiveApp.ToLower()
                                    if ($prophet.Apps.ContainsKey($appKey)) {
                                        $prophet.Apps[$appKey].ManualOverride = $false
                                    }
                                }
                                Add-Log " AI_RESTORE: Przywrocono AI dla $currentActiveApp"
                            }
                        }
                    }
                } catch {
                    if ($_.Exception.Message -eq "EXIT") { Request-Shutdown -Reason "Nested EXIT" }
                }
            }
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                switch ($key.KeyChar) {
                    '1' { 
                        # TURBO = AI uczy sie, tryb wymuszony
                        $Global:AI_Active = $true
                        $Script:UserForcedMode = "Turbo"
                        $manualMode = "Turbo"
                        $Script:LastPowerMode = ""
                        $Script:LastPowerMax = -1
                        $brain.Evolve("Turbo")
                        Set-PowerMode -Mode "Turbo" -CurrentCPU $currentMetrics.CPU
                        Add-Log " TURBO (AI learns, mode locked)" 
                    }
                    '2' { 
                        # BALANCED = AI uczy sie, tryb wymuszony
                        $Global:AI_Active = $true
                        $Script:UserForcedMode = "Balanced"
                        $manualMode = "Balanced"
                        $Script:LastPowerMode = ""
                        $Script:LastPowerMax = -1
                        $brain.Evolve("Balanced")
                        Set-PowerMode -Mode "Balanced" -CurrentCPU $currentMetrics.CPU
                        Add-Log "- BALANCED (AI learns, mode locked)" 
                    }
                    '3' { 
                        # SILENT = AI uczy sie, tryb wymuszony
                        $Global:AI_Active = $true
                        $Script:UserForcedMode = "Silent"
                        $manualMode = "Silent"
                        $Script:LastPowerMode = ""
                        $Script:LastPowerMax = -1
                        $brain.Evolve("Silent")
                        Set-PowerMode -Mode "Silent" -CurrentCPU $currentMetrics.CPU
                        Add-Log "- SILENT (AI learns, mode locked)" 
                    }
                    '5' { 
                        $Global:AI_Active = -not $Global:AI_Active
                        if ($Global:AI_Active) {
                            $Script:UserForcedMode = ""
                        }
                        $Script:LastPowerMode = ""
                        $Script:LastPowerMax = -1
                        Add-Log " AI: $(if($Global:AI_Active){'ON (full control)'}else{'OFF'})" 
                    }
                    'd' { 
                        $Global:DebugMode = -not $Global:DebugMode
                        Add-Log "- Debug: $(if($Global:DebugMode){'ON'}else{'OFF'})" 
                    }
                    'D' { 
                        $Global:DebugMode = -not $Global:DebugMode
                        Add-Log "- Debug: $(if($Global:DebugMode){'ON'}else{'OFF'})" 
                    }
                    's' { 
                        $manualSave = Save-State -Brain $brain -Prophet $prophet
                        if ($manualSave) {
                            $prophetLastAutosave = [DateTime]::Now
                            $prophetLastSavedSessions = $prophet.TotalSessions
                            $anomalyDetector.SaveProfiles($Script:ConfigDir)
                            $loadPredictor.SavePatterns($Script:ConfigDir)
                            Add-Log " Saved OK (all components)"
                        } else {
                            Add-Log "- Save failed"
                        }
                    }
                    'S' { 
                        $manualSave = Save-State -Brain $brain -Prophet $prophet
                        if ($manualSave) {
                            $prophetLastAutosave = [DateTime]::Now
                            $prophetLastSavedSessions = $prophet.TotalSessions
                            $anomalyDetector.SaveProfiles($Script:ConfigDir)
                            $loadPredictor.SavePatterns($Script:ConfigDir)
                            Add-Log " Saved OK (all components)"
                        } else {
                            Add-Log "- Save failed"
                        }
                    }
                    't' {
                        try { $metrics.InitializeFromDetectedSources() } catch {}
                        Add-Log "- Temp source: $($metrics.TempSource) = $($metrics.CachedTemp)°C"
                    }
                    'T' {
                        try { $metrics.InitializeFromDetectedSources() } catch {}
                        Add-Log "- Temp source: $($metrics.TempSource) = $($metrics.CachedTemp)°C"
                    }
                    'p' {
                        Add-Log " Predicted load: $([Math]::Round($predictedLoad))%"
                        if ($predictedApps.Count -gt 0) {
                            Add-Log "   Expected apps: $($predictedApps -join ', ')"
                        }
                    }
                    'P' {
                        Add-Log " Predicted load: $([Math]::Round($predictedLoad))%"
                        if ($predictedApps.Count -gt 0) {
                            Add-Log "   Expected apps: $($predictedApps -join ', ')"
                        }
                    }
                    'a' {
                        $status = $anomalyDetector.GetStatus()
                        Add-Log "- Anomaly profiles: $($status.ProfileCount), Last check: $($status.LastCheck)"
                    }
                    'A' {
                        $status = $anomalyDetector.GetStatus()
                        Add-Log "- Anomaly profiles: $($status.ProfileCount), Last check: $($status.LastCheck)"
                    }
                    'c' {
                        # Chain Predictor status
                        Add-Log "- Chain: $($chainPredictor.GetRecentChainDisplay())"
                        Add-Log "   Next: $($chainPredictor.GetPredictionStatus())"
                        Add-Log "   Accuracy: $([Math]::Round($chainPredictor.GetAccuracy() * 100))% ($($chainPredictor.GetChainCount()) chains)"
                    }
                    'C' {
                        Add-Log "- Chain: $($chainPredictor.GetRecentChainDisplay())"
                        Add-Log "   Next: $($chainPredictor.GetPredictionStatus())"
                        Add-Log "   Accuracy: $([Math]::Round($chainPredictor.GetAccuracy() * 100))% ($($chainPredictor.GetChainCount()) chains)"
                    }
                    'e' {
                        # Self-Tuner efficiency
                        $profile = $selfTuner.GetCurrentProfile()
                        Add-Log "- Self-Tuner: $($selfTuner.GetStatus())"
                        Add-Log "   Good: $($selfTuner.GoodDecisions) | Bad: $($selfTuner.BadDecisions)"
                        Add-Log "   Hour profile: Samples=$($profile.Samples) AvgCPU=$([Math]::Round($profile.AvgCPU))%"
                    }
                    'E' {
                        $profile = $selfTuner.GetCurrentProfile()
                        Add-Log "- Self-Tuner: $($selfTuner.GetStatus())"
                        Add-Log "   Good: $($selfTuner.GoodDecisions) | Bad: $($selfTuner.BadDecisions)"
                        Add-Log "   Hour profile: Samples=$($profile.Samples) AvgCPU=$([Math]::Round($profile.AvgCPU))%"
                    }
                    'w' {
                        # Open Web Dashboard
                        Start-Process "http://localhost:$Global:WebDashboardPort" | Out-Null
                        Add-Log "- Opening Dashboard in browser..."
                    }
                    'W' {
                        Start-Process "http://localhost:$Global:WebDashboardPort" | Out-Null
                        Add-Log "- Opening Dashboard in browser..."
                    }
                    '9' {
                        # Toggle Auto-Start
                        $exists = Test-CPUManagerTaskExists
                        if ($exists) {
                            Register-CPUManagerTask -ScriptPath $MyInvocation.MyCommand.Path -Remove
                            Add-Log "- Auto-start DISABLED"
                        } else {
                            Register-CPUManagerTask -ScriptPath $MyInvocation.MyCommand.Path
                            Add-Log "- Auto-start ENABLED"
                        }
                    }
                    { $_ -eq 'h' -or $_ -eq 'H' } {
                        # Toggle Desktop Widget (zewnetrzny)
                        $widgetCmd = Join-Path $Script:ConfigDir 'WidgetCommand.txt'
                        Start-BackgroundWrite $widgetCmd "TOGGLE" 'UTF8'
                        Add-Log "- Desktop Widget: TOGGLE"
                    }
                    'x' {
                        # Explainer and Thermal status
                        Add-Log " DECISION EXPLAINER"
                        Add-Log "   Current: $($explainer.GetExplanation())"
                        $stats = $explainer.GetStats()
                        Add-Log "   Stats: Silent=$($stats.Silent)% Balanced=$($stats.Balanced)% Turbo=$($stats.Turbo)%"
                        Add-Log "- THERMAL GUARDIAN"
                        Add-Log "   $($thermalGuard.GetStatus())"
                        if ($thermalGuard.ThrottleActive) {
                            Add-Log "   [WARN] THROTTLE ACTIVE: $($thermalGuard.ThrottleReason)"
                        }
                        if ($currentMetrics.GPU) {
                            Add-Log " GPU: $($currentMetrics.GPU.Temp)C | $($currentMetrics.GPU.Load)% | $($currentMetrics.GPU.Power)W"
                        }
                        if ($currentMetrics.VRM -and $currentMetrics.VRM.Available) {
                            Add-Log "- VRM: $($currentMetrics.VRM.Temp)C"
                        }
                    }
                    'X' {
                        Add-Log " DECISION EXPLAINER"
                        Add-Log "   Current: $($explainer.GetExplanation())"
                        $stats = $explainer.GetStats()
                        Add-Log "   Stats: Silent=$($stats.Silent)% Balanced=$($stats.Balanced)% Turbo=$($stats.Turbo)%"
                        Add-Log "- THERMAL GUARDIAN"
                        Add-Log "   $($thermalGuard.GetStatus())"
                        if ($thermalGuard.ThrottleActive) {
                            Add-Log "   [WARN] THROTTLE ACTIVE: $($thermalGuard.ThrottleReason)"
                        }
                        if ($currentMetrics.GPU) {
                            Add-Log " GPU: $($currentMetrics.GPU.Temp)C | $($currentMetrics.GPU.Load)% | $($currentMetrics.GPU.Power)W"
                        }
                        if ($currentMetrics.VRM -and $currentMetrics.VRM.Available) {
                            Add-Log "- VRM: $($currentMetrics.VRM.Temp)C"
                        }
                    }
                    'g' {
                        # Genetic Algorithm status
                        Add-Log "- Genetic: $($genetic.GetStatus())"
                        $params = $genetic.GetCurrentParams()
                        Add-Log "   TurboThr: $($params.TurboThreshold) | BalancedThr: $($params.BalancedThreshold)"
                    }
                    'G' {
                        Add-Log "- Genetic: $($genetic.GetStatus())"
                        $params = $genetic.GetCurrentParams()
                        Add-Log "   TurboThr: $($params.TurboThreshold) | BalancedThr: $($params.BalancedThreshold)"
                    }
                    'b' {
                        # Bandit status
                        Add-Log "- Bandit: $($bandit.GetStatus())"
                        Add-Log "   Total pulls: $($bandit.TotalPulls)"
                    }
                    'B' {
                        Add-Log "- Bandit: $($bandit.GetStatus())"
                        Add-Log "   Total pulls: $($bandit.TotalPulls)"
                    }
                    '0' {
                        # Return to AUTO mode - pelna kontrola AI
                        $Global:AI_Active = $true
                        $Script:UserForcedMode = ""
                        $Script:LastPowerMode = ""
                        $Script:LastPowerMax = -1
                        Add-Log " AUTO mode (AI full control)"
                    }
                    'i' {
                        # Show detailed INFO
                        Add-Log "# DETAILED AI INFO #"
                        Add-Log " Brain: $($brain.GetCount()) weights"
                        Add-Log " Prophet: $($prophet.GetAppCount()) apps, $($prophet.TotalSessions) sessions"
                        Add-Log " Q-Learning: $($qLearning.GetStatus())"
                        Add-Log "- Bandit: $($bandit.GetStatus())"
                        Add-Log "- Genetic: $($genetic.GetStatus())"
                        Add-Log " Ensemble: $($ensemble.GetStatus())"
                        Add-Log "- Energy: $($energyTracker.GetStatus())"
                        Add-Log " Context: $($contextDetector.GetStatus())"
                        Add-Log "- Thermal: $($thermalPredictor.GetStatus())"
                        Add-Log "- Chain: $($chainPredictor.GetChainCount()) chains"
                        Add-Log "- Patterns: $($userPatterns.GetStatus())"
                        Add-Log "- Self-Tune: $($selfTuner.GetStatus())"
                        Add-Log "- ThermalGuard: $($thermalGuard.GetStatus())"
                        Add-Log " Explainer: $($explainer.GetStatus())"
                        Add-Log "#"
                    }
                    'I' {
                        Add-Log "# DETAILED AI INFO #"
                        Add-Log " Brain: $($brain.GetCount()) weights"
                        Add-Log " Prophet: $($prophet.GetAppCount()) apps, $($prophet.TotalSessions) sessions"
                        Add-Log " Q-Learning: $($qLearning.GetStatus())"
                        Add-Log "- Bandit: $($bandit.GetStatus())"
                        Add-Log "- Genetic: $($genetic.GetStatus())"
                        Add-Log " Ensemble: $($ensemble.GetStatus())"
                        Add-Log "- Energy: $($energyTracker.GetStatus())"
                        Add-Log " Context: $($contextDetector.GetStatus())"
                        Add-Log "- Thermal: $($thermalPredictor.GetStatus())"
                        Add-Log "- Chain: $($chainPredictor.GetChainCount()) chains"
                        Add-Log "- Patterns: $($userPatterns.GetStatus())"
                        Add-Log "- Self-Tune: $($selfTuner.GetStatus())"
                        Add-Log "- ThermalGuard: $($thermalGuard.GetStatus())"
                        Add-Log " Explainer: $($explainer.GetStatus())"
                        Add-Log "#"
                    }
                    'l' {
                        # Show recent logs
                        Add-Log "# RECENT LOGS #"
                        $recentLogs = $Script:ActivityLog | Select-Object -Last 15
                        foreach ($logEntry in $recentLogs) {
                            Add-Log "  $logEntry"
                        }
                        Add-Log "#"
                    }
                    'L' {
                        Add-Log "# RECENT LOGS #"
                        $recentLogs = $Script:ActivityLog | Select-Object -Last 15
                        foreach ($logEntry in $recentLogs) {
                            Add-Log "  $logEntry"
                        }
                        Add-Log "#"
                    }
                    'r' {
                        if (-not (Is-NeuralBrainEnabled)) { return }
                        $path = Join-Path $dir "BrainState.json"
                        $data = @{ Weights = $this.Weights; AggressionBias = $this.AggressionBias; ReactivityBias = $this.ReactivityBias; LastLearned = $this.LastLearned; LastLearnTime = $this.LastLearnTime; TotalDecisions = $this.TotalDecisions }
                        [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 4 -Compress), [System.Text.Encoding]::UTF8)
                    }
                    'R' {
                        $brain.Weights.Clear()
                        Add-Log " Neural Brain RESET - all weights cleared"
                    }
                    'q' { Request-Shutdown -Reason "Console key q" }
                    'Q' { Request-Shutdown -Reason "Console key Q" }
                }
                # Handle special keys
                if ($key.Key -eq [ConsoleKey]::F12) { 
                    Show-Database -Prophet $prophet 
                }
                if ($key.Key -eq [ConsoleKey]::Escape) {
                    Request-Shutdown -Reason "Console Escape"
                }
                # Ctrl+C
                if ($key.Key -eq [ConsoleKey]::C -and $key.Modifiers -band [ConsoleModifiers]::Control) {
                    Request-Shutdown -Reason "Ctrl+C"
                }
            }
            # (W przyszlosci mozna podpiac pod rzeczywiste FPS z gier)
            if ($Script:PerfMonitor) {
                $estimatedFrameTime = 16.67  # 60 FPS baseline (ms)
                # Przeciazenie CPU = dluzsze frame times
                if ($currentMetrics.CPU -gt 90) {
                    $estimatedFrameTime += 8.0
                } elseif ($currentMetrics.CPU -gt 80) {
                    $estimatedFrameTime += 5.0
                } elseif ($currentMetrics.CPU -gt 70) {
                    $estimatedFrameTime += 2.0
                }
                # Thermal throttling = spike w frame time
                if ($currentMetrics.Temp -gt 90) {
                    $estimatedFrameTime += 10.0
                } elseif ($currentMetrics.Temp -gt 85) {
                    $estimatedFrameTime += 5.0
                } elseif ($currentMetrics.Temp -gt 80) {
                    $estimatedFrameTime += 2.0
                }
                # Silent mode przy obciazeniu = mozliwe stuttery
                #  SYNC: uses variables z config.json
                if ($currentState -eq "Silent" -and $currentMetrics.CPU -gt $Script:TurboThreshold) {
                    $estimatedFrameTime += 3.0
                }
                $Script:PerfMonitor.RecordFrame($estimatedFrameTime)
            }
            $elapsed = $stopwatch.ElapsedMilliseconds
            $sleepTime = [Math]::Max(100, $dynamicInterval - $elapsed)
            # Obsluga zdarzen tray icon - krotkie sleepy z DoEvents
            $remaining = [int]$sleepTime
            while ($remaining -gt 0 -and -not $Global:ExitRequested) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds ([Math]::Min(50, $remaining))
                $remaining -= 50
            }
            if ($Global:ExitRequested) { break }
        }
        Write-Host "[DEBUG] Engine: main loop exited (ExitRequested=$Global:ExitRequested)" -ForegroundColor Yellow
    } catch {
        # Blok catch dodany automatycznie (naprawa krytycznego bledu skladni)
        if ($_.Exception.Message -ne "EXIT") {
            Write-Host "`nError: $_" -ForegroundColor Red
            Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed
        }
    } finally {
        # DISK WRITE CACHE: Flush wszystkich pending plików na dysk (shutdown)
        try {
            $flushed = $diskCache.FlushAll()
            $stats = $diskCache.GetStats()
            Write-Host "[CACHE] Shutdown flush: $flushed files | Total writes: $($stats.TotalWrites) | Cache hits: $($stats.CacheHits) ($($stats.HitRate)%)" -ForegroundColor Cyan
        } catch { }
        # Przywroc normalny stan konsoli
        try { [Console]::CursorVisible = $true } catch { }
        try { [Console]::TreatControlCAsInput = $false } catch { }
        try { $global:ErrorActionPreference = "Continue" } catch { }
        # - Przywroc domyslne plany zasilania Windows
        try { $powerRestored = Restore-DefaultPowerPlans } catch { $powerRestored = $false }
        try { $priorityManager.ResetAllPriorities() } catch { }
        # Intel Power Manager: przywróć pełną wydajność przy zamknięciu
        if ($Script:IntelPM -and $Script:IntelPM.Available) {
            try { Reset-IntelPowerManager $Script:IntelPM; Write-Host "  [IntelPM] Restored defaults" -ForegroundColor Green } catch {}
        # AppRAMCache: zwolnij wszystkie cached pliki
        if ($appRAMCache) {
            try { 
                $appRAMCache.SaveState($Script:ConfigDir)  # Persist learned data
                $stats = "$($appRAMCache.TotalPreloads) preloads, $($appRAMCache.TotalHits) hits"
                $appRAMCache.Cleanup()
                Write-Host "  [RAMCache] Saved state + freed all ($stats)" -ForegroundColor Green
            } catch {}
        }
        }
        # v44.0: Governor - przywróć Windows defaults i zapisz stan
        try { $systemGovernor.RestoreWindowsDefaults() } catch { }
        try { $systemGovernor.SaveState($Script:ConfigDir) } catch { }
        try { $null = Save-State -Brain $brain -Prophet $prophet } catch { }
        try { $anomalyDetector.SaveProfiles($Script:ConfigDir) } catch { }
        try { $loadPredictor.SavePatterns($Script:ConfigDir) } catch { }
        try { $selfTuner.SaveState($Script:ConfigDir) } catch { }
        try { $userPatterns.SaveState($Script:ConfigDir) } catch { }
        try { $chainPredictor.SaveState($Script:ConfigDir) } catch { }
        #  MEGA AI components
        try { $qLearning.SaveState($Script:ConfigDir) } catch { }
        try { $ensemble.SaveState($Script:ConfigDir) } catch { }
        try { $energyTracker.SaveState($Script:ConfigDir) } catch { }
        #  ULTRA AI components
        try { $bandit.SaveState($Script:ConfigDir) } catch { }
        try { $genetic.SaveState($Script:ConfigDir) } catch { }
        try { $aiCoordinator.SaveState($Script:ConfigDir) } catch { }
        # - V35 NEW: RAMAnalyzer
        try { $ramAnalyzer.SaveState($Script:ConfigDir) } catch { }
        # - V37.8.2: Network Optimizer + Network AI
        try { $networkOptimizer.SaveState($Script:ConfigDir) } catch { }
        try { $networkAI.SaveState($Script:ConfigDir) } catch { }
        # - V40 FIX: Brakujące komponenty w finally (ProcessAI, GPUAI, ContextDetector, etc.)
        try { $processAI.SaveState($Script:ConfigDir) } catch { }
        try { $gpuAI.SaveState($Script:ConfigDir) } catch { }
        try { $contextDetector.SaveState($Script:ConfigDir) } catch { }
        try { $phaseDetector.SaveState($Script:ConfigDir) } catch { }
        try { $thermalPredictor.SaveState($Script:ConfigDir) } catch { }
        try { $explainer.SaveState($Script:ConfigDir) } catch { }
        try { $thermalGuard.SaveState($Script:ConfigDir) } catch { }
        # AILearning: ostateczny zapis pamięci przy zamykaniu
        try { Flush-AILearningBuffer -Force } catch { }
        #  Zapisz ustawienia programu
        try {
            $programSettings = @{
                AI_Active = $Global:AI_Active
                DebugMode = $Global:DebugMode
                EcoMode = $Global:EcoMode
                ManualMode = $manualMode
                LastSaved = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            }
            $programSettings | ConvertTo-Json | Set-Content $Script:SettingsPath -Force
        } catch { }
        # - Stop Web Dashboard
        try { $webDashboard.Stop() } catch { }
        # - Zamknij zewnetrzne widgety
        try {
            Send-TrayCommand "EXIT"
            Start-BackgroundWrite (Join-Path $Script:ConfigDir 'MiniWidgetCommand.txt') "EXIT" 'UTF8'
        } catch { }
        try { $metrics.Cleanup() } catch { }
        try { $watcher.Cleanup() } catch { }
        # Stop metrics timer if running
        try {
            if ($Script:MetricsTimer) {
                try { $Script:MetricsTimer.Stop() } catch { }
                try { $Script:MetricsTimer.Dispose() } catch { }
                try { Add-Log "Metrics timer stopped" } catch { }
            }
        } catch { }
        # Ukryj i usun tray icon glownego procesu
        try {
            if ($Script:MainTray) {
                $Script:MainTray.Visible = $false
                $Script:MainTray.Dispose()
            }
        } catch { }
        # - V37.7.15: Restore all throttled processes
        try { $proBalance.RestoreAll() } catch { }
        try {
            [System.GC]::Collect()
            [System.GC]::WaitForPendingFinalizers()
            [System.GC]::Collect()
        } catch { }
        Clear-Host
        Write-Host "`n  CPU Manager AI ULTRA stopped." -ForegroundColor Yellow
        Write-Host ""
        # - Status przywrocenia planow zasilania
        Write-Host "  - POWER PLANS" -ForegroundColor Yellow
        if ($powerRestored) {
            Write-Host "     Plan 'Balanced' przywrocony (CPU: 5-100%)" -ForegroundColor Green
        } else {
            Write-Host "     Nie udalo sie przywrocic planow" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "   AI STATUS" -ForegroundColor Cyan
        Write-Host "     Prophet: $($prophet.GetAppCount()) apps" -ForegroundColor Gray
        Write-Host "     Brain: $($brain.GetCount()) weights" -ForegroundColor Gray
        Write-Host "     Self-Tuner: $($selfTuner.GetStatus())" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   MEGA AI STATUS" -ForegroundColor Magenta
        Write-Host "     Q-Learning: $($qLearning.GetStatus())" -ForegroundColor Gray
        Write-Host "     Ensemble: $($ensemble.GetStatus())" -ForegroundColor Gray
        Write-Host "     Energy: $($energyTracker.GetStatus())" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   ULTRA AI STATUS" -ForegroundColor Blue
        Write-Host "     Bandit: $($bandit.GetStatus())" -ForegroundColor Gray
        Write-Host "     Genetic: $($genetic.GetStatus())" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   V40 AI STATUS" -ForegroundColor Green
        Write-Host "     GPU AI: $($gpuAI.GetStatus())" -ForegroundColor Gray
        Write-Host "     Process AI: $($processAI.GetStatus())" -ForegroundColor Gray
        Write-Host "     Network AI: $($networkAI.GetStatus())" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  Files saved to: $Script:ConfigDir" -ForegroundColor DarkGray
        Write-Host ""
        # Pokaz konsole jesli byla ukryta
        try {
            $consolePtr = [ConsoleWindow]::GetConsoleWindow()
            [ConsoleWindow]::ShowWindow($consolePtr, 5) | Out-Null
        } catch { }
        try { [Console]::CursorVisible = $true } catch { }
    }
}
# Wywolanie glownej funkcji z error handling
try {
    Main
    # Wyczysc konsole po wyjsciu i pokaz komunikat
    Clear-Host
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "    CPU MANAGER AI - ZAMKNIETO" -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Nacisnij dowolny klawisz aby zamknac okno..." -ForegroundColor Gray
Write-Host ""
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
} catch {
    # Fatal error - log i restart (chyba ze to normalne wyjscie)
    if ($Script:ShutdownRequested -or $_.Exception.Message -eq "EXIT" -or $_.Exception.Message -match "break") {
        break
    }
    $msg = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - FATAL ERROR: $($_.Exception.Message)`n$($_.ScriptStackTrace)`n"
    try { Add-Content -Path $Script:ErrorLogPath -Value $msg } catch { }
    Write-Host ""
    Write-Host "  [WARN] Fatal Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Restarting in 5 seconds... (Ctrl+C to abort)" -ForegroundColor Yellow
    Start-Sleep -Seconds 5
}
# Po wyjsciu z petli - przywroc normalny stan PowerShell
try {
    $global:ErrorActionPreference = "Continue"
    [Console]::CursorVisible = $true
    [Console]::TreatControlCAsInput = $false
} catch { }
# Pokaz konsole
try {
    $consolePtr = [ConsoleWindow]::GetConsoleWindow()
    [ConsoleWindow]::ShowWindow($consolePtr, 5) | Out-Null
} catch { }
# Nie robimy Clear-Host - zachowujemy podsumowanie z finally
Write-Host ""
Write-Host "  ---------------------------------------------" -ForegroundColor DarkGray
Write-Host "  Program zakonczony. PowerShell gotowy." -ForegroundColor Green
Write-Host ""
Write-Host "  Nacisnij ENTER aby zamknac lub wpisz komendy..." -ForegroundColor DarkGray
Read-Host
# #
# PODSUMOWANIE SESJI
# #
function Write-SessionSummary {
    $SessionEndTime = Get-Date
    $SessionDuration = $SessionEndTime - $Global:SessionStartTime
    Write-Log "" "INFO"
    Write-Log "#" "INFO"
    Write-Log "-                 SESJA ZAKONCZONA - PODSUMOWANIE                                  ?" "INFO"
    Write-Log "#" "INFO"
    Write-Log "Czas trwania: $([Math]::Round($SessionDuration.TotalMinutes, 2)) minut" "INFO"
    Write-Log "Zmian trybu: $($Global:ModeChangeCount)" "INFO"
    Write-Log "Aktywacji BOOST: $($Global:BoostCount)" "INFO"
    Write-Log "Log zapisany: $Global:LogFile" "INFO"
}
$null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    Write-SessionSummary
}