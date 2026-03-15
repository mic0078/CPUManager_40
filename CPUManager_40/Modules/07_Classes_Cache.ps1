# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 07_Classes_Cache.ps1
# Cache layer: DiskWriteCache, AppRAMCache
# Lines 15752-19291 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
class DiskWriteCache {
    [hashtable] $Cache            # filename → json string (dane w RAM)
    [hashtable] $DirtyFlags       # filename → $true jeśli zmieniony od ostatniego flush
    [hashtable] $LastFlushTime    # filename → datetime ostatniego zapisu na dysk
    [string] $BaseDir             # katalog docelowy (C:\CPUManager)
    [int] $FlushBatchSize         # ile plików flushować per tick
    [int] $MinFlushIntervalSec    # min sekund między flush tego samego pliku
    [int] $TotalWrites            # łączna liczba zapisów z cache do dysku
    [int] $TotalCacheHits         # ile razy uniknięto zapisu (dane nie zmienione)
    [int] $TotalBytesWritten      # łączny rozmiar danych zapisanych
    [datetime] $LastTickTime      # kiedy ostatni tick
    [System.Collections.Generic.Queue[string]] $FlushQueue  # kolejka FIFO plików do zapisu

    DiskWriteCache([string]$baseDir) {
        $this.Cache = @{}
        $this.DirtyFlags = @{}
        $this.LastFlushTime = @{}
        $this.BaseDir = $baseDir
        $this.FlushBatchSize = 2       # 2 pliki per tick (co ~2s = ~1 plik/s)
        $this.MinFlushIntervalSec = 30 # min 30s między flush tego samego pliku
        $this.TotalWrites = 0
        $this.TotalCacheHits = 0
        $this.TotalBytesWritten = 0
        $this.LastTickTime = [datetime]::Now
        $this.FlushQueue = [System.Collections.Generic.Queue[string]]::new()
    }

    # WRITE: Zapisz dane do cache (RAM) — natychmiastowe, zero I/O
    [void] Write([string]$filename, [string]$jsonContent) {
        if ([string]::IsNullOrEmpty($filename) -or [string]::IsNullOrEmpty($jsonContent)) { return }
        $prev = $null
        if ($this.Cache.ContainsKey($filename)) { $prev = $this.Cache[$filename] }
        # Nie zapisuj jeśli dane się nie zmieniły
        if ($prev -eq $jsonContent) {
            $this.TotalCacheHits++
            return
        }
        $this.Cache[$filename] = $jsonContent
        # Oznacz jako dirty i dodaj do kolejki flush (jeśli jeszcze nie w kolejce)
        if (-not $this.DirtyFlags.ContainsKey($filename) -or -not $this.DirtyFlags[$filename]) {
            $this.DirtyFlags[$filename] = $true
            $this.FlushQueue.Enqueue($filename)
        }
    }

    # READ: Odczytaj z cache (RAM) — jeśli brak, odczytaj z dysku
    [string] Read([string]$filename) {
        if ($this.Cache.ContainsKey($filename)) {
            return $this.Cache[$filename]
        }
        # Fallback: odczytaj z dysku i załaduj do cache
        $path = Join-Path $this.BaseDir $filename
        if (Test-Path $path) {
            try {
                $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
                $this.Cache[$filename] = $content
                $this.DirtyFlags[$filename] = $false
                return $content
            } catch { return $null }
        }
        return $null
    }

    # TICK: Wywoływany co iterację main loop (~2s). Flushuje 1-2 dirty pliki na dysk.
    [hashtable] Tick() {
        $flushed = 0
        $errors = 0
        $now = [datetime]::Now
        $this.LastTickTime = $now
        $attempts = [Math]::Min($this.FlushQueue.Count, $this.FlushBatchSize)
        for ($i = 0; $i -lt $attempts; $i++) {
            if ($this.FlushQueue.Count -eq 0) { break }
            $filename = $this.FlushQueue.Dequeue()
            # Sprawdź czy nadal dirty
            if (-not $this.DirtyFlags.ContainsKey($filename) -or -not $this.DirtyFlags[$filename]) {
                continue
            }
            # Sprawdź min interval
            if ($this.LastFlushTime.ContainsKey($filename)) {
                $elapsed = ($now - $this.LastFlushTime[$filename]).TotalSeconds
                if ($elapsed -lt $this.MinFlushIntervalSec) {
                    # Za wcześnie — wrzuć z powrotem na koniec kolejki
                    $this.FlushQueue.Enqueue($filename)
                    continue
                }
            }
            # FLUSH na dysk
            try {
                $path = Join-Path $this.BaseDir $filename
                $content = $this.Cache[$filename]
                [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::UTF8)
                $this.DirtyFlags[$filename] = $false
                $this.LastFlushTime[$filename] = $now
                $this.TotalWrites++
                $this.TotalBytesWritten += $content.Length
                $flushed++
            } catch {
                $errors++
                # Retry: wrzuć z powrotem do kolejki
                $this.FlushQueue.Enqueue($filename)
            }
        }
        return @{ Flushed = $flushed; Errors = $errors; Pending = $this.FlushQueue.Count }
    }

    # FLUSH ALL: Wymuś zapis WSZYSTKICH dirty plików (shutdown, emergency)
    [int] FlushAll() {
        $flushed = 0
        foreach ($filename in @($this.Cache.Keys)) {
            if ($this.DirtyFlags.ContainsKey($filename) -and $this.DirtyFlags[$filename]) {
                try {
                    $path = Join-Path $this.BaseDir $filename
                    [System.IO.File]::WriteAllText($path, $this.Cache[$filename], [System.Text.Encoding]::UTF8)
                    $this.DirtyFlags[$filename] = $false
                    $this.LastFlushTime[$filename] = [datetime]::Now
                    $this.TotalWrites++
                    $this.TotalBytesWritten += $this.Cache[$filename].Length
                    $flushed++
                } catch { }
            }
        }
        return $flushed
    }

    # STATS: Statystyki cache
    [hashtable] GetStats() {
        $dirty = 0; $cached = $this.Cache.Count
        foreach ($f in $this.DirtyFlags.Keys) { if ($this.DirtyFlags[$f]) { $dirty++ } }
        return @{
            CachedFiles = $cached
            DirtyFiles = $dirty
            PendingQueue = $this.FlushQueue.Count
            TotalWrites = $this.TotalWrites
            CacheHits = $this.TotalCacheHits
            BytesWritten = $this.TotalBytesWritten
            HitRate = if (($this.TotalWrites + $this.TotalCacheHits) -gt 0) {
                [Math]::Round($this.TotalCacheHits / ($this.TotalWrites + $this.TotalCacheHits) * 100, 1)
            } else { 0 }
        }
    }
}
# ═══════════════════════════════════════════════════════════════════════════════
# APP RAM CACHE v2 — AI-driven predictive cache z 10 ulepszeniami
# 1. Time-decay scoring — priorytety wygasają wykładniczo
# 2. Confidence-based preload — 60%=full, 40-60%=partial, <30%=skip
# 3. Smart DLL sorting — rozmiar × cold-start impact
# 4. Battery/thermal awareness — nie drenuj baterii w tle
# 5. Batch preload — małe porcje bez skoków I/O
# 6. Depth-2 chain prediction — A→B(full) + B→C(warm)
# 7. Real memory pressure — commit ratio + page faults, nie % RAM
# 8. Adaptive aggressiveness — uczy się ile preloadować
# 9. Recency boost — ostatnio używane nie wylatują
# 10. Idle learning phase — refleksja i rewizja score'ów
# ═══════════════════════════════════════════════════════════════════════════════
class AppRAMCache {
    # ── Core state ──
    [hashtable] $CachedApps          # appName → @{ Files, SizeMB, CachedAt, LastAccess, HitCount, FileCount, PreloadLevel }
    [hashtable] $AppPaths            # appName → @{ ExePath, Dir }
    [string] $DiskCacheDir           # C:\CPUManager\Cache — persistent file cache on disk
    [double] $TotalCachedMB
    [double] $MaxCacheMB
    [int] $MaxAppsInCache
    [bool] $Enabled
    [datetime] $LastEvictionCheck
    [datetime] $LastIdleLearn
    
    # ── Stats ──
    [int] $TotalPreloads
    [int] $TotalHits
    [int] $TotalMisses
    [int] $TotalEvictions
    [int] $TotalWastedPreloads
    
    # ── Adaptive aggressiveness ──
    [double] $Aggressiveness
    [double] $AggressivenessMin
    [double] $AggressivenessMax
    [double] $RetentionTolerance       # Osobny parametr — jak długo trzymać w cache (0.0=czyść szybko, 1.0=trzymaj zawsze)
    
    # ── Batch preload ──
    [System.Collections.Generic.Queue[hashtable]] $BatchQueue
    [System.Collections.Generic.Queue[hashtable]] $PriorityQueue  # Foreground app — przetwarzany PRZED BatchQueue
    [int] $BatchSizeBytes
    [datetime] $LastBatchTick
    
    # ── Memory pressure + trend (pkt 8: trend-based, nie punktowy) ──
    [double] $LastCommitRatio
    [double] $LastAvailableMB
    [double] $LastAvailablePercent       # Available / Total * 100
    [int] $LastPageFaultsPerSec
    [DateTime] $_LastWMICheck = [DateTime]::MinValue
    [double] $MemoryPressure
    [System.Collections.Generic.List[double]] $PressureHistory  # ostatnie N odczytów (trend)
    
    # ── NEW: Heavy/Light classification (#1) ──
    [hashtable] $AppClassification    # appName → "Heavy" | "Light"
    
    # ── NEW: Working Set Protection (#2) ──
    [hashtable] $ProtectedApps        # appName → @{ PID, MinWS, StableWS, ProtectedAt }
    
    # ── NEW: Heavy Mode (#3) ──
    [bool] $HeavyMode                 # Globalny tryb stabilności
    [string] $HeavyModeApp            # Która app włączyła Heavy Mode
    [datetime] $HeavyModeActivated
    
    # ── NEW: Guard Band RAM (#4) ──
    [double] $GuardBandMB             # Min wolny RAM w MB (dynamiczny)
    [double] $GuardBandHeavyMB        # Większy bufor gdy heavy app (dynamiczny)
    [double] $TotalSystemRAM           # Zainstalowany RAM w MB (auto-detected)
    
    # ── NEW: Anti-AltTab Protection (#5) ──
    [hashtable] $AltTabProtection     # appName → @{ ProtectedUntil, WasFullscreen }
    [string] $LastFullscreenApp
    [datetime] $LastFocusChange
    
    # ── NEW: Negative Learning (#7) ──
    [hashtable] $NegativeScores       # appName → @{ PreloadCount, HitCount, PenaltyUntil }
    
    # ── NEW: Session type (#8) ──
    [string] $CurrentSession          # "Gaming" | "Work" | "Browsing" | "Mixed"
    
    # ── NEW: DisplayName → ProcessName mapping ──
    [hashtable] $NameMap              # "Google Chrome" → "chrome", "Total Commander" → "TOTALCMD"
    
    # ── NEW: Hardware Profile (wypełniane przez ENGINE po Detect-CPU) ──
    [hashtable] $HW                   # CPU/RAM/Storage info od ENGINE
    
    # ── NEW: Dirty flag — SaveState only when data changed ──
    [bool] $IsDirty = $false

    # ── LAUNCH RACE: Agresywny preload gdy wykryto start procesu ──
    [bool]     $IsInLaunchRace    # Trwa wyścig — pomiń 200ms timer w BatchTick
    [string]   $LaunchRaceApp     # Nazwa app dla której trwa wyścig
    [datetime] $LaunchRaceUntil   # Deadline wyścigu (max 15s od startu procesu)
    # Odroczone profilowanie modułów (po 2s gdy proces załadował już DLL)
    [System.Collections.Generic.List[hashtable]] $PendingProfileQueue

    # ── NoPathCache: nazwy bez exe — nie loguj SKIP za każdym razem ──
    [System.Collections.Generic.HashSet[string]] $NoPathCache

    # ── ManifestSaveTimes: cooldown — nie zapisuj manifestu dwa razy w ciągu 2s ──
    [hashtable] $ManifestSaveTimes

    # ── #3 Adaptive Batch Sizing ──
    [long]   $BatchSizeMin       # Dolny próg BatchSizeBytes (zależny od RAM)
    [long]   $BatchSizeMax       # Górny próg BatchSizeBytes (zależny od RAM)
    [double] $LastBatchTickMs    # Czas ostatniego BatchTick w ms (do adaptacji)

    # ── #4 Startup Time Learning ──
    [hashtable] $AppStartupMs    # appName → mediana czasu startu w ms (lista próbek)
    [datetime]  $LaunchRaceStart # Kiedy wyścig wystartował (mierzy czas startu)

    # ── v43.15: AI Engine feedback ──
    [double] $LastAIScore        # Ostatni score silnika AI (0-100); wysoki = heavy load
    [string] $LastAIMode         # Ostatni tryb AI: Turbo/Balanced/Silent
    [string] $LastAIContext      # Ostatni kontekst: Gaming/Work/Music/Browsing/Mixed/Idle
    # ── AI Prophet reference — żywy widok danych Prophet (aktualizowany co AITick) ──
    [hashtable] $ProphetAppsRef  # Referencja do prophet.Apps; $null gdy Prophet nieaktywny

    # ── v47.4: Child Apps — parentApp → @{ childProcName → @{ ExePath, Dir, LearnedFiles, LastSeen } } ──
    [hashtable] $ChildApps        # Persystentna mapa parent→dzieci (zapisywana w manifecie)
    
    AppRAMCache() {
        $this.CachedApps = @{}
        $this.AppPaths = @{}
        $this.DiskCacheDir = "C:\CPUManager\Cache"
        $this.TotalCachedMB = 0
        $this.MaxAppsInCache = 30
        $this.TotalPreloads = 0
        $this.TotalHits = 0
        $this.TotalMisses = 0
        $this.TotalEvictions = 0
        $this.TotalWastedPreloads = 0
        $this.Enabled = $true
        $this.LastEvictionCheck = [datetime]::Now
        $this.LastIdleLearn = [datetime]::Now
        
        # Aggressiveness = preload intensity + learning speed (NIE steruje eviction!)
        $this.Aggressiveness = 0.6
        $this.AggressivenessMin = 0.3
        $this.AggressivenessMax = 0.95
        $this.RetentionTolerance = 1.0
        
        # Batch preload
        $this.BatchQueue = [System.Collections.Generic.Queue[hashtable]]::new()
        $this.PriorityQueue = [System.Collections.Generic.Queue[hashtable]]::new()
        $this.BatchSizeBytes = 32MB
        $this.LastBatchTick = [datetime]::Now
        
        # Memory pressure + trend
        $this.LastCommitRatio = 0
        $this.LastAvailableMB = 4096
        $this.LastAvailablePercent = 80
        $this.LastPageFaultsPerSec = 0
        $this.MemoryPressure = 0
        $this.PressureHistory = [System.Collections.Generic.List[double]]::new()
        
        $this.AppClassification = @{}
        $this.ProtectedApps = @{}
        $this.HeavyMode = $false
        $this.HeavyModeApp = ""
        $this.HeavyModeActivated = [datetime]::MinValue
        $this.AltTabProtection = @{}
        $this.LastFullscreenApp = ""
        $this.LastFocusChange = [datetime]::Now
        $this.NegativeScores = @{}
        $this.CurrentSession = "Mixed"
        $this.NameMap = @{}
        $this.HW = @{}  # Wypełniane przez ENGINE po Detect-CPU via SetHardwareProfile

        # Launch Race
        $this.IsInLaunchRace = $false
        $this.LaunchRaceApp = ""
        $this.LaunchRaceUntil = [datetime]::MinValue
        $this.PendingProfileQueue = [System.Collections.Generic.List[hashtable]]::new()
        $this.NoPathCache = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.ManifestSaveTimes = @{}

        # #3 Adaptive Batch Sizing — progi zależne od RAM
        $totalGB2 = [Math]::Round($this.TotalSystemRAM / 1024, 1)
        if ($totalGB2 -ge 64) {
            $this.BatchSizeMin = 32MB;  $this.BatchSizeMax = 512MB
        } elseif ($totalGB2 -ge 32) {
            $this.BatchSizeMin = 16MB;  $this.BatchSizeMax = 256MB
        } elseif ($totalGB2 -ge 16) {
            $this.BatchSizeMin = 8MB;   $this.BatchSizeMax = 128MB
        } else {
            $this.BatchSizeMin = 4MB;   $this.BatchSizeMax = 32MB
        }
        $this.LastBatchTickMs = 0

        # #4 Startup Time Learning
        $this.AppStartupMs = @{}
        $this.LaunchRaceStart = [datetime]::MinValue
        $this.ProphetAppsRef = $null  # Wypełniane przez AITick co tick
        $this.ChildApps = @{}             # v47.4: parent → children mapping
        
        # ═══ SKALOWANIE DO HARDWARE (pkt 1,6,9 instrukcji) ═══
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $this.TotalSystemRAM = [Math]::Round($os.TotalVisibleMemorySize / 1KB)  # MB
            $freeRAM = [Math]::Round($os.FreePhysicalMemory / 1KB)                  # MB
            $totalGB = [Math]::Round($this.TotalSystemRAM / 1024, 1)
            
            # Guard Band = % RAM (pkt 1: procent, nie stała)
            if ($totalGB -ge 32) {
                $this.GuardBandMB = [int]($this.TotalSystemRAM * 0.08)
                $this.GuardBandHeavyMB = [int]($this.TotalSystemRAM * 0.10)
            } elseif ($totalGB -ge 16) {
                $this.GuardBandMB = [int]($this.TotalSystemRAM * 0.10)
                $this.GuardBandHeavyMB = [int]($this.TotalSystemRAM * 0.14)
            } else {
                $this.GuardBandMB = [int]($this.TotalSystemRAM * 0.12)
                $this.GuardBandHeavyMB = [int]($this.TotalSystemRAM * 0.18)
            }
            
            # MaxCacheMB = % RAM — zależne od Tier (ustawiane po otrzymaniu HW)
            # Default 50% — zostanie skorygowane gdy HW.CacheStrategy dostępne
            $this.MaxCacheMB = [int]($this.TotalSystemRAM * 0.50)
            
            $this.LastAvailableMB = [Math]::Round($freeRAM)
            
            # BatchSize skalowany do RAM
            if ($totalGB -ge 32) { $this.BatchSizeBytes = 128MB }
            elseif ($totalGB -ge 16) { $this.BatchSizeBytes = 64MB }
            else { $this.BatchSizeBytes = 16MB }
            
        } catch { 
            $this.TotalSystemRAM = 8192
            $this.MaxCacheMB = 2048
            $this.GuardBandMB = 1024
            $this.GuardBandHeavyMB = 1536
            $this.LastAvailableMB = 4096
        }
    }
    
    # ═══ Wywołaj PO ustawieniu $this.HW przez ENGINE ═══
    # Dostosowuje parametry cache na podstawie pełnego profilu hardware
    [void] ApplyHardwareProfile() {
        if (-not $this.HW -or $this.HW.Count -eq 0) { return }
        $cs = $this.HW.CacheStrategy
        if (-not $cs) { return }
        
        # MaxCacheMB z CacheStrategy (Tier-dependent %)
        $this.MaxCacheMB = [int]($this.TotalSystemRAM * $cs.CachePercent)
        $this.BatchSizeBytes = $cs.BatchSize
        
        # HDD → cache KRYTYCZNY — potrzebujemy agresywnego preloadu
        # NVMe → cache pomocny ale mniej krytyczny — dysk jest szybki
        $storageType = if ($this.HW.StorageType) { $this.HW.StorageType } else { "SSD" }
        if ($storageType -eq "HDD") {
            # HDD: zwiększ retencję, zmniejsz eviction — trzymaj jak najwięcej w RAM
            $this.RetentionTolerance = [Math]::Min(1.0, $this.RetentionTolerance + 0.3)
            $this.Aggressiveness = [Math]::Min($this.AggressivenessMax, $this.Aggressiveness + 0.2)
        } elseif ($storageType -eq "NVMe") {
            # NVMe: standardowa retencja, eviction OK — dysk szybki
            $this.RetentionTolerance = [Math]::Max(0.3, $this.RetentionTolerance - 0.1)
        }
        
        $tier = if ($this.HW.Tier) { $this.HW.Tier } else { 2 }
        Write-RCLog "HW PROFILE: Tier=$tier $($this.HW.Vendor) $($this.HW.Cores)C/$($this.HW.Threads)T RAM=$($this.HW.TotalRAM_GB)GB Storage=$storageType → MaxCache=$($this.MaxCacheMB)MB Batch=$([int]($this.BatchSizeBytes/1MB))MB Aggr=$([Math]::Round($this.Aggressiveness,2))"
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #1 TIME-DECAY PRIORITY — score maleje wykładniczo z czasem
    # halfLife = 10 min → po 10 min priorytet = 50%, po 20 min = 25%
    # #9 RECENCY BOOST — <30s = +40, <5min = +20
    # ═══════════════════════════════════════════════════════════════
    [double] GetDecayedPriority([string]$appName, [hashtable]$prophetApps, [hashtable]$transitions) {
        $basePriority = 0.0
        
        # #7: Negative learning penalty
        if ($this.IsNegativePenalty($appName)) { return 0.0 }
        
        # Prophet knowledge
        if ($prophetApps -and $prophetApps.ContainsKey($appName)) {
            $app = $prophetApps[$appName]
            if ($app.IsHeavy) { $basePriority += 30 }
            if ($app.Samples) { $basePriority += [Math]::Min(20, [double]$app.Samples / 5.0) }
            if ($app.AvgCPU -gt 40) { $basePriority += 10 }
        }
        
        # Chain transitions
        if ($transitions) {
            foreach ($src in $transitions.Keys) {
                if ($transitions[$src].ContainsKey($appName)) {
                    $basePriority += [Math]::Min(15, $transitions[$src][$appName].Count * 3)
                }
            }
        }
        
        # #10: Cost efficiency bonus
        $efficiency = $this.GetCostEfficiency($appName, $prophetApps)
        $basePriority += [Math]::Min(10, $efficiency * 0.5)

        # v43.15: Context-aware bonus — silnik AI wie czym zajmuje się teraz user
        # Gaming → boost gier; Work → boost IDE/przeglądarki; Music → boost DAW/audio
        if (-not [string]::IsNullOrWhiteSpace($this.LastAIContext)) {
            $appLower = $appName.ToLower()
            $isGameContext  = $this.LastAIContext -match 'Gaming|Game'
            $isWorkContext  = $this.LastAIContext -match 'Work|IDE|Code|Office'
            $isMusicContext = $this.LastAIContext -match 'Music|Audio|DAW'
            $isBrowse       = $this.LastAIContext -match 'Browsing|Browse'

            $contextBonus = 0
            if ($isGameContext  -and ($appLower -match 'soma|game|steam|epic|galax|gog|unity|unreal|godot|hl2|csgo')) { $contextBonus = 20 }
            if ($isWorkContext  -and ($appLower -match 'code|idea|rider|visual|chrome|firefox|edge|word|excel|teams|slack|notion')) { $contextBonus = 18 }
            if ($isMusicContext -and ($appLower -match 'ableton|fl.studio|reaper|audacity|vocoder|asio|vst|cubase|studio.one|reason')) { $contextBonus = 18 }
            if ($isBrowse      -and ($appLower -match 'chrome|firefox|edge|opera|brave')) { $contextBonus = 12 }
            $basePriority += $contextBonus
        }
        
        # Cache hits + time decay
        if ($this.CachedApps.ContainsKey($appName)) {
            $entry = $this.CachedApps[$appName]
            $basePriority += [Math]::Min(25, $entry.HitCount * 5)
            
            # #6: Heavy = wolniejszy decay (halfLife 50 min), Light = szybszy (8 min)
            # Heavy apps (gry, DAW, heavy software) zostają w cache przez ~50 min bez dostępu
            $appClass = $this.ClassifyApp($appName, $prophetApps)
            $halfLife = if ($appClass -eq "Heavy") { 50.0 } else { 8.0 }
            
            $minutesSinceAccess = ([datetime]::Now - $entry.LastAccess).TotalMinutes
            $decayFactor = [Math]::Pow(0.5, $minutesSinceAccess / $halfLife)
            $basePriority *= $decayFactor
            
            # #9 Recency boost + #5 Anti-AltTab
            $secsSinceAccess = ([datetime]::Now - $entry.LastAccess).TotalSeconds
            if ($secsSinceAccess -lt 30) { $basePriority += 40 }
            elseif ($secsSinceAccess -lt 300) { $basePriority += 20 }
            
            # #5: Anti-AltTab protection bonus
            if ($this.IsAltTabProtected($appName)) { $basePriority += 50 }
        }
        
        return $basePriority
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #7 REAL MEMORY PRESSURE — commit ratio + available MB + page faults
    # Zwraca 0.0 (brak presji) → 1.0 (krytyczna presja)
    # ═══════════════════════════════════════════════════════════════
    [double] MeasureMemoryPressure() {
        try {
            # PERFORMANCE FIX: Cache WMI — max raz na 2 sekundy (WMI = 50-100ms per call)
            $now = [DateTime]::UtcNow
            if ($this.LastAvailableMB -gt 0 -and $this._LastWMICheck -and ($now - $this._LastWMICheck).TotalSeconds -lt 2.0) {
                return $this.MemoryPressure
            }
            $this._LastWMICheck = $now
            
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $availableMB = [Math]::Round($os.FreePhysicalMemory / 1KB, 0)
            $totalMB = [Math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
            $availablePercent = if ($totalMB -gt 0) { ($availableMB / $totalMB) * 100.0 } else { 50.0 }
            $commitRatio = if ($totalMB -gt 0) { 1.0 - ($availableMB / $totalMB) } else { 0.5 }
            
            # PERFORMANCE FIX: Skip Get-Counter (100ms+ per call) — use cached value
            # Page faults updated only every 30s in main loop via separate call
            
            $this.LastAvailableMB = $availableMB
            $this.LastAvailablePercent = $availablePercent
            $this.LastCommitRatio = $commitRatio
            
            # ═══ PRESSURE SKALOWANE DO % RAM (pkt 1) ═══
            # Progi zależne od ilości RAM:
            $totalGB = $this.TotalSystemRAM / 1024.0
            # Eviction threshold (pkt 1):
            # >=32GB: eviction gdy Available < 20%
            # 16-32GB: eviction gdy Available < 25%  
            # <16GB: eviction gdy Available < 30%
            $criticalPercent = if ($totalGB -ge 32) { 15 } elseif ($totalGB -ge 16) { 20 } else { 25 }
            $warnPercent = if ($totalGB -ge 32) { 20 } elseif ($totalGB -ge 16) { 25 } else { 30 }
            
            $pressureAvail = 0.0
            if ($availablePercent -lt $criticalPercent) {
                $pressureAvail = 0.5 + (($criticalPercent - $availablePercent) / $criticalPercent) * 0.5
            } elseif ($availablePercent -lt $warnPercent) {
                $pressureAvail = (($warnPercent - $availablePercent) / ($warnPercent - $criticalPercent)) * 0.5
            }
            
            $pressurePF = [Math]::Min(1.0, $this.LastPageFaultsPerSec / 500.0)
            
            $instantPressure = [Math]::Min(1.0, ($pressureAvail * 0.7) + ($pressurePF * 0.3))
            
            # ═══ TREND TRACKING (pkt 8: trend-based, nie punktowy) ═══
            $this.PressureHistory.Add($instantPressure)
            if ($this.PressureHistory.Count -gt 6) { $this.PressureHistory.RemoveAt(0) }  # Ostatnie 6 odczytów (~90s)
            
            # Pressure = średnia z historii (wygładza szumy)
            $avg = 0.0; foreach ($p in $this.PressureHistory) { $avg += $p }
            $avg /= [Math]::Max(1, $this.PressureHistory.Count)
            
            # Trend: rosnący = ostrzeżenie, malejący = bezpiecznie
            $trend = 0.0
            if ($this.PressureHistory.Count -ge 3) {
                $recent = $this.PressureHistory[$this.PressureHistory.Count - 1]
                $older = $this.PressureHistory[0]
                $trend = $recent - $older  # >0 = rośnie, <0 = maleje
            }
            
            # Końcowa pressure = średnia, ale z bonusem za rosnący trend
            $this.MemoryPressure = [Math]::Min(1.0, $avg + [Math]::Max(0, $trend * 0.3))
            
            return $this.MemoryPressure
        } catch {
            return $this.MemoryPressure
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #2 CONFIDENCE-BASED PRELOAD
    # #3 SMART DLL SORTING (rozmiar × priorytet rozszerzenia)
    # #5 BATCH PRELOAD — kolejkuje pliki w porcjach
    # ═══════════════════════════════════════════════════════════════
    [bool] PreloadApp([string]$appName, [string]$exePath, [double]$confidence) {
        if (-not $this.Enabled) { return $false }
        
        # Blacklist: Desktop, system procesy, UWP shell apps — nie preloaduj, nie loguj
        if ($appName -eq "Desktop" -or $appName -match '^(pwsh|powershell|conhost|WindowsTerminal|ShellHost|explorer|dwm|WinStore\.App|ApplicationFrameHost|SystemSettings)$') { return $false }
        
        # #7: Negative learning — skip apps z penalty
        if ($this.IsNegativePenalty($appName)) { return $false }
        
        # #4: Guard band — sprawdź czy jest miejsce
        if (-not $this.HasGuardBandSpace()) { 
            $avPct = if ($this.TotalSystemRAM -gt 0) { [int](($this.LastAvailableMB / $this.TotalSystemRAM) * 100) } else { 0 }
            Write-RCLog "PRELOAD SKIP '$appName': guard band (avail=$([int]$this.LastAvailableMB)MB=$avPct% heavy=$($this.HeavyMode))"
            return $false 
        }
        
        # #3: Heavy Mode — w gaming session nie preloaduj light apps
        if ($this.HeavyMode -and $this.CurrentSession -eq "Gaming" -and $appName -ne $this.HeavyModeApp) {
            # W heavy mode pozwól tylko na heavy apps
            if ($this.AppClassification.ContainsKey($appName) -and $this.AppClassification[$appName] -eq "Light") {
                return $false
            }
        }
        
        # Confidence check
        $effectiveConfidence = $confidence * $this.Aggressiveness
        if ($effectiveConfidence -lt 0.25) { return $false }  # Za niska pewność → skip
        
        # Już w cache → odśwież
        if ($this.CachedApps.ContainsKey($appName)) {
            $this.CachedApps[$appName].LastAccess = [datetime]::Now
            return $true
        }
        
        # Memory pressure check
        if ($this.MemoryPressure -gt 0.7) { Write-RCLog "PRELOAD SKIP '$appName': pressure=$([Math]::Round($this.MemoryPressure,2))"; return $false }
        if ($this.TotalCachedMB -ge $this.MaxCacheMB) {
            $avPct = if ($this.TotalSystemRAM -gt 0) { ($this.LastAvailableMB / $this.TotalSystemRAM) * 100.0 } else { 0 }
            if ($avPct -gt 25) {
                # Wolny RAM >25% → podnieś limit (max 60% total RAM)
                $this.MaxCacheMB = [Math]::Min([int]($this.TotalSystemRAM * 0.60), $this.MaxCacheMB + 512)
            } else {
                Write-RCLog "PRELOAD SKIP '$appName': cache full ($([int]$this.TotalCachedMB)/$($this.MaxCacheMB)MB, avail=$([int]$avPct)%)"
                return $false
            }
        }
        
        # Determine preload level based on confidence (#2)
        $preloadLevel = "full"     # ≥60%: exe + top DLL + configs
        if ($effectiveConfidence -lt 0.6) {
            $preloadLevel = "partial"  # 40-60%: exe + top 5 DLL
        }
        if ($effectiveConfidence -lt 0.4) {
            $preloadLevel = "warm"     # 25-40%: exe only
        }
        
        # Find exe path — kaskadowo: podany exePath → AppPaths → Get-Process
        $targetPath = ""
        
        # Próba 1: podany exePath (jeśli istnieje na dysku)
        if (-not [string]::IsNullOrWhiteSpace($exePath) -and (Test-Path $exePath -ErrorAction SilentlyContinue)) {
            $targetPath = $exePath
        }
        
        # Próba 2: AppPaths (zapisany z poprzedniej sesji)
        if ([string]::IsNullOrWhiteSpace($targetPath) -and $this.AppPaths.ContainsKey($appName)) {
            $saved = $this.AppPaths[$appName].ExePath
            if (-not [string]::IsNullOrWhiteSpace($saved) -and (Test-Path $saved -ErrorAction SilentlyContinue)) {
                $targetPath = $saved
            }
        }
        
        # Próba 3: szukaj running procesu (działa np. po update exe, np. Claude/Electron apps)
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            try {
                $proc = Get-Process -Name $appName -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc -and $proc.Path -and (Test-Path $proc.Path)) { 
                    $targetPath = $proc.Path
                    # Update AppPaths z nową ścieżką
                    if (-not $this.AppPaths.ContainsKey($appName)) {
                        $this.AppPaths[$appName] = @{ ExePath = $proc.Path; Dir = [System.IO.Path]::GetDirectoryName($proc.Path) }
                    } else {
                        $this.AppPaths[$appName].ExePath = $proc.Path
                        $this.AppPaths[$appName].Dir = [System.IO.Path]::GetDirectoryName($proc.Path)
                    }
                }
            } catch {}
        }
        
        if ([string]::IsNullOrWhiteSpace($targetPath)) {
            # v43.15: jeśli mamy LearnedFiles — preloaduj je bezpośrednio bez exe
            # (exe mógł zmienić lokalizację po update, ale DLL-e/moduły są nadal ważne)
            $hasLearned = ($this.AppPaths.ContainsKey($appName) -and
                           $this.AppPaths[$appName].LearnedFiles -and
                           $this.AppPaths[$appName].LearnedFiles.Count -ge 2)
            if (-not $hasLearned) {
                if (-not $this.NoPathCache.Contains($appName)) {
                    Write-RCLog "PRELOAD SKIP '$appName': no valid path (exePath='$exePath', inAppPaths=$($this.AppPaths.ContainsKey($appName)))"
                    $this.NoPathCache.Add($appName) | Out-Null
                }
                return $false
            }
            # Mamy learned files — załaduj je (tryb LEARNED-ONLY, bez exe)
            $lf = $this.AppPaths[$appName].LearnedFiles
            $maxModPerApp = 50
            if ($this.HW -and $this.HW.CacheStrategy) { $maxModPerApp = $this.HW.CacheStrategy.MaxModules }
            else {
                $totalGB2b = $this.TotalSystemRAM / 1024.0
                $maxModPerApp = if ($totalGB2b -ge 32) { 30 } elseif ($totalGB2b -ge 16) { 20 } else { 12 }
            }
            $filesToLoadLO = [System.Collections.Generic.List[hashtable]]::new()
            $countLO = 0
            foreach ($f in $lf) {
                if ($countLO -ge $maxModPerApp) { break }
                if ([string]::IsNullOrWhiteSpace($f.Path) -or -not (Test-Path $f.Path -ErrorAction SilentlyContinue)) { continue }
                $budgetLeft = ($this.MaxCacheMB - $this.TotalCachedMB) * 1MB
                $currentBatchSz = 0; foreach ($bf in $filesToLoadLO) { $currentBatchSz += $bf.Size }
                if (($currentBatchSz + $f.Size) -gt $budgetLeft) { break }
                $lfp2 = [string]$f.Path
                $lfType2 = if ($lfp2 -match '\\(Plugins|Extensions|VST2?|VST3|CLAP|LV2|Components)\\' -or
                                $lfp2 -match '\.(vst3|clap|component)$' -or
                                $lfp2 -match 'Common.Files\\(VST2?|CLAP|LV2)') { "plugin" } else { "learned" }
                $filesToLoadLO.Add(@{ Path = $lfp2; Size = $f.Size; Type = $lfType2 })
                $countLO++
            }
            if ($filesToLoadLO.Count -eq 0) {
                if (-not $this.NoPathCache.Contains($appName)) {
                    Write-RCLog "PRELOAD SKIP '$appName': no valid path and all LearnedFiles missing from disk"
                    $this.NoPathCache.Add($appName) | Out-Null
                }
                return $false
            }
            $totalSizeLO = 0; foreach ($f in $filesToLoadLO) { $totalSizeLO += $f.Size }
            $sizeMBLO = [Math]::Round($totalSizeLO / 1MB, 1)
            $this.CachedApps[$appName] = @{
                Files = [System.Collections.Generic.List[object]]::new()
                SizeMB = $sizeMBLO
                CachedAt = [datetime]::Now
                LastAccess = [datetime]::Now
                HitCount = 0
                FileCount = $filesToLoadLO.Count
                PreloadLevel = $preloadLevel
                LoadComplete = $false
                FilesLoaded = 0
            }
            $this.TotalCachedMB += $sizeMBLO
            $this.TotalPreloads++
            $this.RecordPreloadAttempt($appName)
            Write-RCLog "PRELOAD '$appName' [$preloadLevel/LEARNED-ONLY]: $($filesToLoadLO.Count) files ($sizeMBLO MB) conf=$([Math]::Round($confidence,2)) [exe path stale/missing]"
            foreach ($fileInfo in $filesToLoadLO) {
                $this.BatchQueue.Enqueue(@{
                    AppName = $appName
                    Path = $fileInfo.Path
                    Size = $fileInfo.Size
                    Type = $fileInfo.Type
                    LargeFile = ($fileInfo.Size -ge 200MB)
                    TouchedOffset = [long]0
                })
            }
            return $true
        }
        
        $appDir = [System.IO.Path]::GetDirectoryName($targetPath)
        
        # GAME ROOT DETECTION: UE4/UE5 exe w Binaries/Win64 → assets w Content/Paks
        # Szukaj game root idąc w górę od exe dir
        $gameRoot = $appDir
        $testDir = $appDir
        for ($up = 0; $up -lt 4; $up++) {
            $parent = [System.IO.Path]::GetDirectoryName($testDir)
            if (-not $parent -or $parent -eq $testDir) { break }
            # Sprawdź czy parent zawiera typowe game assets
            if ((Test-Path (Join-Path $parent "Content") -ErrorAction SilentlyContinue) -or
                (Test-Path (Join-Path $parent "Engine") -ErrorAction SilentlyContinue) -or
                (Get-ChildItem $parent -Filter "*.pak" -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                $gameRoot = $parent
                break
            }
            $testDir = $parent
        }
        
        # Zbierz listę plików do załadowania
        $filesToLoad = [System.Collections.Generic.List[hashtable]]::new()
        
        # 1. Główny EXE (zawsze)
        try {
            $exeInfo = Get-Item $targetPath -ErrorAction Stop
            if ($exeInfo.Length -lt 200MB) {
                $filesToLoad.Add(@{ Path = $targetPath; Size = $exeInfo.Length; Type = "exe" })
            }
        } catch {}
        
        # 2. DLL/Modules — użyj LEARNED FILES jeśli dostępne, inaczej skanuj katalog
        $usedLearned = $false
        if ($preloadLevel -ne "warm") {
            # Skaluj maxFiles do HW Tier
            $maxModPerApp = 50  # default (Tier 1 = 80, Tier 2 = 50)
            if ($this.HW -and $this.HW.CacheStrategy) { $maxModPerApp = $this.HW.CacheStrategy.MaxModules }
            else {
                $totalGB2 = $this.TotalSystemRAM / 1024.0
                $maxModPerApp = if ($totalGB2 -ge 32) { 30 } elseif ($totalGB2 -ge 16) { 20 } else { 12 }
            }
            $maxFiles = if ($preloadLevel -eq "full") { $maxModPerApp } else { [Math]::Max(5, [int]($maxModPerApp * 0.4)) }
            
            # PRIORYTET 1: Learned files z profilu (rzeczywiste moduły procesu)
            if ($this.AppPaths.ContainsKey($appName) -and $this.AppPaths[$appName].LearnedFiles -and $this.AppPaths[$appName].LearnedFiles.Count -gt 0) {
                $learnedFiles = $this.AppPaths[$appName].LearnedFiles
                $count = 0
                foreach ($lf in $learnedFiles) {
                    if ($count -ge $maxFiles) { break }
                    if ($lf.Path -eq $targetPath) { continue }  # Skip exe (już dodany)
                    if (-not (Test-Path $lf.Path -ErrorAction SilentlyContinue)) { continue }  # Plik usunięty
                    $budgetLeft = ($this.MaxCacheMB - $this.TotalCachedMB) * 1MB
                    $currentBatch = 0; foreach ($f in $filesToLoad) { $currentBatch += $f.Size }
                    if (($currentBatch + $lf.Size) -gt $budgetLeft) { break }
                    $lfpM = [string]$lf.Path
                    $lfTypeM = if ($lfpM -match '\\(Plugins|Extensions|VST2?|VST3|CLAP|LV2|Components)\\' -or
                                    $lfpM -match '\.(vst3|clap|component)$' -or
                                    $lfpM -match 'Common.Files\\(VST2?|CLAP|LV2)') { "plugin" } else { "learned" }
                    $filesToLoad.Add(@{ Path = $lfpM; Size = $lf.Size; Type = $lfTypeM })
                    $count++
                }
                $usedLearned = ($count -gt 0)
            }
            
            # FALLBACK: Skanuj katalog jeśli brak learned files
            if (-not $usedLearned) {
                try {
                    $dlls = Get-ChildItem -Path $appDir -Filter "*.dll" -ErrorAction SilentlyContinue |
                        Where-Object { $_.Length -gt 10KB -and $_.Length -lt 100MB }
                    $scoredDlls = foreach ($dll in $dlls) {
                        $weight = 1.0
                        $name = $dll.Name.ToLower()
                        if ($name -match 'runtime|core|clr|jit|v8|electron|cef|qt5core|libcef') { $weight = 3.0 }
                        elseif ($name -match 'framework|system\.|microsoft\.|wpf|winforms|gtk|sdl') { $weight = 2.0 }
                        elseif ($name -match 'd3d|vulkan|opengl|dxgi|nvapi|cuda|opencl') { $weight = 2.5 }
                        $sizeScore = [Math]::Log10([Math]::Max(1, $dll.Length / 1KB))
                        @{ File = $dll; Score = $weight * $sizeScore }
                    }
                    $sorted = $scoredDlls | Sort-Object { $_.Score } -Descending | Select-Object -First $maxFiles
                    foreach ($item in $sorted) {
                        $budgetLeft = ($this.MaxCacheMB - $this.TotalCachedMB) * 1MB
                        $currentBatch = 0; foreach ($f in $filesToLoad) { $currentBatch += $f.Size }
                        if (($currentBatch + $item.File.Length) -gt $budgetLeft) { break }
                        $filesToLoad.Add(@{ Path = $item.File.FullName; Size = $item.File.Length; Type = "dll" })
                    }
                } catch {}
            }
        }
        
        # 3. Config files (tylko full preload)
        if ($preloadLevel -eq "full") {
            try {
                $configs = Get-ChildItem -Path $appDir -Include "*.json","*.xml","*.ini","*.cfg" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -lt 1MB } | Select-Object -First 5
                foreach ($cfg in $configs) {
                    $filesToLoad.Add(@{ Path = $cfg.FullName; Size = $cfg.Length; Type = "cfg" })
                }
            } catch {}
        }
        
        # 4. DEEP ASSET SCAN — ładuj game assets, shaders, pak files
        # To jest KLUCZOWE: DLLs to <5% pamięci gry. Reszta to assets/shaders/textures
        # Budget: 90% MaxCacheMB (było 70% — marnowało 20% pojemności cache)
        # Limit pliku: MaxCacheMB/8 (dynamiczny wg RAM) zamiast hardcoded 500MB
        if ($preloadLevel -ne "warm" -and $this.TotalCachedMB -lt $this.MaxCacheMB * 0.9) {
            try {
                $budgetLeftMB = ($this.MaxCacheMB * 0.9) - $this.TotalCachedMB
                $currentBatch = 0; foreach ($f in $filesToLoad) { $currentBatch += $f.Size }
                # Max budget per app: połowa wolnego miejsca (nie blokuj innych appów)
                $assetBudget = [Math]::Min([long]($budgetLeftMB * 0.5 * 1MB), ($budgetLeftMB * 1MB) - $currentBatch)
                # Dynamiczny limit rozmiaru pojedynczego pliku na podstawie MaxCacheMB
                # 32GB RAM→MaxCache~16GB→maxFile=2GB | 16GB→1GB | 8GB→512MB
                $maxAssetFileBytes = [Math]::Max(512MB, [long]($this.MaxCacheMB / 8) * 1MB)

                if ($assetBudget -gt 50MB) {
                    # Skanuj pliki gier/aplikacji: shaders, paki, textury, bazy danych
                    # Użyj gameRoot (nie appDir!) — UE4 paki są w Content/Paks
                    $assetExts = "*.pak","*.pck","*.bank","*.wem","*.ushaderbytecode","*.shaderbundle","*.upk","*.uasset","*.umap","*.cache","*.dat","*.db","*.sqlite","*.bin","*.oodle"
                    $scanDir = if ($gameRoot -and $gameRoot -ne $appDir) { $gameRoot } else { $appDir }
                    $assetFiles = Get-ChildItem -Path $scanDir -Include $assetExts -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                        Where-Object { $_.Length -gt 100KB -and $_.Length -lt $maxAssetFileBytes } |
                        Sort-Object Length -Descending
                    
                    $assetLoaded = 0
                    $assetBytes = 0
                    foreach ($asset in $assetFiles) {
                        if ($assetBytes + $asset.Length -gt $assetBudget) { break }
                        # Skip files already in list
                        $already = $false
                        foreach ($f in $filesToLoad) { if ($f.Path -eq $asset.FullName) { $already = $true; break } }
                        if ($already) { continue }
                        $filesToLoad.Add(@{ Path = $asset.FullName; Size = $asset.Length; Type = "asset" })
                        $assetBytes += $asset.Length
                        $assetLoaded++
                    }
                    
                    if ($assetLoaded -gt 0) {
                        Write-RCLog "DEEP SCAN '$appName': +$assetLoaded asset files ($([Math]::Round($assetBytes/1MB, 1))MB)"
                    }
                }
            } catch {}
        }
        
        if ($filesToLoad.Count -eq 0) { return $false }
        
        # Oblicz total size
        $totalSize = 0; foreach ($f in $filesToLoad) { $totalSize += $f.Size }
        $sizeMB = [Math]::Round($totalSize / 1MB, 1)
        
        # Utwórz cache entry (pliki będą ładowane w batchach)
        $this.CachedApps[$appName] = @{
            Files = [System.Collections.Generic.List[object]]::new()
            SizeMB = $sizeMB
            CachedAt = [datetime]::Now
            LastAccess = [datetime]::Now
            HitCount = 0
            FileCount = $filesToLoad.Count
            PreloadLevel = $preloadLevel
            LoadComplete = $false
            FilesLoaded = 0
        }
        if (-not $this.AppPaths.ContainsKey($appName)) {
            $this.AppPaths[$appName] = @{ ExePath = $targetPath; Dir = $appDir }
        } else {
            $this.AppPaths[$appName]['ExePath'] = $targetPath
            $this.AppPaths[$appName]['Dir']     = $appDir
        }
        $this.TotalCachedMB += $sizeMB
        $this.TotalPreloads++
        $this.RecordPreloadAttempt($appName)
        $usedType = if ($usedLearned) { "LEARNED" } else { "SCAN" }
        Write-RCLog "PRELOAD '$appName' [$preloadLevel/$usedType]: $($filesToLoad.Count) files ($sizeMB MB) conf=$([Math]::Round($confidence,2))"
        
        # BATCH PRELOAD (#5): kolejkuj pliki w porcjach zamiast ładować naraz
        # LargeFile=true → BatchTick przetwarza chunkami (nie blokuje głównej pętli)
        foreach ($fileInfo in $filesToLoad) {
            $this.BatchQueue.Enqueue(@{
                AppName = $appName
                Path = $fileInfo.Path
                Size = $fileInfo.Size
                Type = $fileInfo.Type
                LargeFile = ($fileInfo.Size -ge 200MB)
                TouchedOffset = [long]0
            })
        }
        
        return $true
    }
    
    # Backwards-compatible overload (confidence=1.0)
    [bool] PreloadApp([string]$appName, [string]$exePath) {
        return $this.PreloadApp($appName, $exePath, 1.0)
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #5 BATCH TICK — ładuj pliki w porcjach per tick
    # Wywoływany co iterację main loop
    # NOWE: PriorityQueue (foreground app) przetwarzana PRZED BatchQueue
    # NOWE: Pliki >=200MB ladowane chunkami (nie blokuja glownej petli)
    # ═══════════════════════════════════════════════════════════════
    [int] BatchTick() {
        if ($this.PriorityQueue.Count -eq 0 -and $this.BatchQueue.Count -eq 0) { return 0 }
        $now = [datetime]::Now
        if (($now - $this.LastBatchTick).TotalMilliseconds -lt 200) { return 0 }
        $this.LastBatchTick = $now
        $batchTickSw = [System.Diagnostics.Stopwatch]::StartNew()

        $loaded = 0
        $bytesThisTick = 0
        # Dynamiczny limit: MaxCacheMB/8 (min 200MB) — spójny z PreloadApp i LoadAppFromDiskCache
        $maxFileMB = [Math]::Max(200, [int]($this.MaxCacheMB / 8))

        # PriorityQueue (foreground app) PRZED normalną kolejką
        foreach ($queue in @($this.PriorityQueue, $this.BatchQueue)) {
            while ($queue.Count -gt 0 -and $bytesThisTick -lt $this.BatchSizeBytes) {
                $item = $queue.Dequeue()
                $appName = $item.AppName

                if (-not $this.CachedApps.ContainsKey($appName)) {
                    # App evicted w trakcie ładowania — zwolnij otwarte uchwyty
                    if ($item.ContainsKey('Accessor') -and $item.Accessor) { try { $item.Accessor.Dispose() } catch {} }
                    if ($item.ContainsKey('MMF') -and $item.MMF) { try { $item.MMF.Dispose() } catch {} }
                    continue
                }

                try {
                    if (-not (Test-Path $item.Path)) {
                        $this.CachedApps[$appName].FilesLoaded++
                        continue
                    }
                    $fileSize = $item.Size

                    if ($item.ContainsKey('LargeFile') -and $item.LargeFile) {
                        # ═══ DUŻY PLIK (>=200MB): chunked MMF — nie blokuje głównej pętli ═══
                        # MMF mapuje te same strony co kernel file cache (zero duplikacji RAM)
                        if ($fileSize -gt ($maxFileMB * 1MB)) {
                            # Za duży nawet dla chunked — policz jako przetworzony, pomiń
                            $this.CachedApps[$appName].FilesLoaded++
                            continue
                        }
                        # Otwórz MMF raz przy pierwszym chunku
                        if (-not $item.ContainsKey('Accessor') -or -not $item.Accessor) {
                            $mmfL = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile(
                                $item.Path, [System.IO.FileMode]::Open, $null, 0,
                                [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
                            $accL = $mmfL.CreateViewAccessor(0, $fileSize,
                                [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
                            $item['MMF'] = $mmfL
                            $item['Accessor'] = $accL
                            if (-not $item.ContainsKey('TouchedOffset')) { $item['TouchedOffset'] = [long]0 }
                        }
                        # Stride zależy od rozmiaru: większy plik = rzadsza siatka dotknięć
                        # <512MB → 64KB stride (kernel cache warmed co 16 stron)
                        # >=512MB → 256KB stride (szybsze, kernel i tak buforuje sekwencyjnie)
                        $stride = if ($fileSize -ge 512MB) { 262144 } else { 65536 }
                        $startOff = [long]$item.TouchedOffset
                        $chunkEnd = [Math]::Min($startOff + $this.BatchSizeBytes, $fileSize)
                        $dummyByte = [byte]0
                        for ($off = $startOff; $off -lt $chunkEnd; $off += $stride) {
                            $dummyByte = $item.Accessor.ReadByte($off)
                        }
                        $item['TouchedOffset'] = $chunkEnd
                        $bytesThisTick += ($chunkEnd - $startOff)

                        if ($chunkEnd -lt $fileSize) {
                            # Nie skończono — wróć do tej samej kolejki (priorytet zachowany)
                            $queue.Enqueue($item)
                        } else {
                            # Ostatni chunk — dodaj do CachedApps.Files i oznacz jako załadowany
                            $this.CachedApps[$appName].Files.Add(@{
                                Path = $item.Path; MMF = $item.MMF; Accessor = $item.Accessor
                                SizeBytes = $fileSize; Type = $item.Type; LargeFile = $true
                            })
                            $this.CachedApps[$appName].FilesLoaded++
                            $loaded++
                        }

                    } else {
                        # ═══ NORMALNY PLIK (<200MB): MMF + touch co 4KB ═══
                        # MMF mapuje TE SAME strony co kernel file cache (zero duplikacji!)
                        # Trzymanie Accessor = strony PINNED w RAM (working set ENGINE)
                        # Gdy app startuje → Windows daje jej TE SAME fizyczne strony = instant
                        if ($fileSize -lt 200MB -and $fileSize -gt 0) {
                            $mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile(
                                $item.Path, [System.IO.FileMode]::Open, $null, 0,
                                [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
                            $accessor = $mmf.CreateViewAccessor(0, $fileSize,
                                [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::Read)
                            $dummyByte = [byte]0
                            for ($offset = 0; $offset -lt $fileSize; $offset += 4096) {
                                $dummyByte = $accessor.ReadByte($offset)
                            }
                            $this.CachedApps[$appName].Files.Add(@{
                                Path = $item.Path; MMF = $mmf; Accessor = $accessor
                                SizeBytes = $fileSize; Type = $item.Type
                            })
                        }
                        $this.CachedApps[$appName].FilesLoaded++
                        $bytesThisTick += $fileSize
                        $loaded++
                    }
                } catch {
                    # Policz jako przetworzony — nie blokuj LoadComplete całej app
                    if ($this.CachedApps.ContainsKey($appName)) { $this.CachedApps[$appName].FilesLoaded++ }
                    continue
                }
            }
        }

        # Oznacz completed apps + zapisz na dysk
        foreach ($appName in @($this.CachedApps.Keys)) {
            $entry = $this.CachedApps[$appName]
            if (-not $entry.LoadComplete -and $entry.FilesLoaded -ge $entry.FileCount) {
                $entry.LoadComplete = $true
                $this.SaveAppToDiskCache($appName)
            }
        }

        # #3 ADAPTIVE BATCH SIZING — dostosuj na podstawie czasu tego ticka
        $batchTickSw.Stop()
        $tickMs = $batchTickSw.Elapsed.TotalMilliseconds
        $this.LastBatchTickMs = $tickMs
        if ($tickMs -gt 300) {
            # Tick zajął za dużo — zmniejsz batch (nie zakłócaj I/O gier/foreground)
            $newSize = [long]($this.BatchSizeBytes * 0.75)
            $this.BatchSizeBytes = [Math]::Max($this.BatchSizeMin, $newSize)
        } elseif ($tickMs -lt 80 -and $this.MemoryPressure -lt 0.35) {
            # Tick szybki, ciśnienie niskie — zwiększ batch (max zależny od RAM)
            $newSize = [long]($this.BatchSizeBytes * 1.15)
            $this.BatchSizeBytes = [Math]::Min($this.BatchSizeMax, $newSize)
        }

        return $loaded
    }
    
    # ═══════════════════════════════════════════════════════════════
    # DISK CACHE — buforuj pliki na dysk C:\CPUManager\Cache\
    # Zapobiega utracie cache po restarcie lub gdy Windows zwalnia standby list
    # ═══════════════════════════════════════════════════════════════
    [void] SaveAppToDiskCache([string]$appName) {
        if (-not $this.DiskCacheDir) { return }
        # Cooldown: nie zapisuj dwa razy tego samego manifestu w ciągu 2s (zapobiega podwójnemu MANIFEST SAVED)
        $now2 = [datetime]::Now
        if ($this.ManifestSaveTimes.ContainsKey($appName) -and ($now2 - $this.ManifestSaveTimes[$appName]).TotalSeconds -lt 2) { return }
        $this.ManifestSaveTimes[$appName] = $now2
        try {
            $manifest = @{
                AppName = $appName
                SavedAt = [datetime]::Now.ToString("o")
                Files = [System.Collections.Generic.List[hashtable]]::new()
            }
            
            # Zbierz pliki z OBU źródeł, wybierz BOGATSZE
            $cachedFiles = [System.Collections.Generic.List[hashtable]]::new()
            $learnedFiles = [System.Collections.Generic.List[hashtable]]::new()
            
            # Źródło 1: CachedApps.Files
            if ($this.CachedApps.ContainsKey($appName)) {
                foreach ($f in $this.CachedApps[$appName].Files) {
                    if ($f.Path -and (Test-Path $f.Path -ErrorAction SilentlyContinue)) {
                        $cachedFiles.Add(@{ Path = [string]$f.Path; Size = [long]$f.SizeBytes; Type = [string]$f.Type })
                    }
                }
            }
            
            # Źródło 2: AppPaths.LearnedFiles
            if ($this.AppPaths.ContainsKey($appName)) {
                $ap = $this.AppPaths[$appName]
                if ($ap.ExePath -and (Test-Path $ap.ExePath -ErrorAction SilentlyContinue)) {
                    $learnedFiles.Add(@{ Path = [string]$ap.ExePath; Size = [long](Get-Item $ap.ExePath -EA SilentlyContinue).Length; Type = "exe" })
                }
                if ($ap.ContainsKey('LearnedFiles') -and $ap.LearnedFiles) {
                    foreach ($lf in $ap.LearnedFiles) {
                        if ($lf.Path -and $lf.Path -ne $ap.ExePath -and (Test-Path $lf.Path -EA SilentlyContinue)) {
                            # Wykryj wtyczki: VST2/VST3/CLAP/LV2 lub katalogi Plugins/Extensions
                            $lfp = [string]$lf.Path
                            $lfType = if ($lfp -match '\\(Plugins|Extensions|VST2?|VST3|CLAP|LV2|Components)\\' -or
                                           $lfp -match '\.(vst3|clap|component)$' -or
                                           $lfp -match 'Common.Files\\(VST2?|CLAP|LV2)') { "plugin" } else { "learned" }
                            $learnedFiles.Add(@{ Path = $lfp; Size = [long]$lf.Size; Type = $lfType })
                        }
                    }
                }
            }
            
            # Wybierz źródło z WIĘKSZĄ liczbą plików
            $manifest.Files = if ($cachedFiles.Count -ge $learnedFiles.Count) { $cachedFiles } else { $learnedFiles }
            
            if ($manifest.Files.Count -gt 0) {
                $totalSize = 0; foreach ($f in $manifest.Files) { $totalSize += $f.Size }
                $manifest.SizeMB = [Math]::Round($totalSize / 1MB, 1)
                # v47.4: Dołącz listę znanych children (nazwy + exe paths)
                if ($this.ChildApps.ContainsKey($appName) -and $this.ChildApps[$appName].Count -gt 0) {
                    $manifest.ChildApps = [System.Collections.Generic.List[hashtable]]::new()
                    foreach ($cn in $this.ChildApps[$appName].Keys) {
                        $ci = $this.ChildApps[$appName][$cn]
                        $manifest.ChildApps.Add(@{
                            Name    = [string]$cn
                            ExePath = [string]$ci.ExePath
                            Dir     = [string]$ci.Dir
                        })
                    }
                }
                $manifestPath = Join-Path $this.DiskCacheDir "$appName.json"
                $json = $manifest | ConvertTo-Json -Depth 4 -Compress
                [System.IO.File]::WriteAllText($manifestPath, $json, [System.Text.Encoding]::UTF8)
                Write-RCLog "MANIFEST SAVED '$appName': $($manifest.Files.Count) files → $manifestPath"
            }
        } catch {}
    }
    
    [bool] LoadAppFromDiskCache([string]$appName) {
        if (-not $this.DiskCacheDir) { return $false }
        if ($this.CachedApps.ContainsKey($appName)) { return $true }  # Already in RAM
        
        # Szukaj manifestu (lista ORYGINALNYCH ścieżek do preload)
        $manifestPath = Join-Path $this.DiskCacheDir "$appName.json"
        if (-not (Test-Path $manifestPath)) { return $false }
        
        try {
            $json = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8)
            $manifest = $json | ConvertFrom-Json -ErrorAction Stop
            if (-not $manifest.Files -or $manifest.Files.Count -eq 0) { return $false }
            
            # Najpierw policz pliki i dodaj do kolejki
            $fileCount = 0
            $estimatedMB = 0.0
            $queuedItems = [System.Collections.Generic.List[hashtable]]::new()
            
            # Dynamiczny limit: MaxCacheMB/8 (min 200MB) — spójny z BatchTick i PreloadApp
            # 32GB RAM→MaxCache~16GB → max plik 2GB | 16GB→1GB | 8GB→512MB
            $diskCacheMaxBytes = [Math]::Max(200MB, [long]($this.MaxCacheMB / 8) * 1MB)
            foreach ($f in $manifest.Files) {
                $origPath = [string]$f.Path
                if (-not $origPath -or -not (Test-Path $origPath -ErrorAction SilentlyContinue)) { continue }
                $fileSize = [long]$f.Size
                if ($fileSize -le 0 -or $fileSize -gt $diskCacheMaxBytes) { continue }
                $isLarge = ($fileSize -ge 200MB)
                $queuedItems.Add(@{
                    AppName = $appName; Path = $origPath; Size = $fileSize; Type = [string]$f.Type
                    LargeFile = $isLarge; TouchedOffset = [long]0
                })
                $fileCount++
                $estimatedMB += $fileSize / 1MB
            }
            
            if ($fileCount -eq 0) { return $false }
            
            # Utwórz CachedApps z POPRAWNYM FileCount OD RAZU (nie 0!)
            $this.CachedApps[$appName] = @{
                Files = [System.Collections.Generic.List[hashtable]]::new()
                SizeMB = [Math]::Round($estimatedMB, 1); CachedAt = [datetime]::Now; LastAccess = [datetime]::Now
                HitCount = 0; FilesLoaded = 0; FileCount = $fileCount; PreloadLevel = "manifest"
                LoadComplete = $false
            }
            
            # Teraz dodaj do BatchQueue
            foreach ($item in $queuedItems) {
                $this.BatchQueue.Enqueue($item)
            }
            
            $this.TotalCachedMB += [Math]::Round($estimatedMB, 1)
            $this.TotalPreloads++
            Write-RCLog "MANIFEST QUEUE '$appName': $fileCount files (~$([int]$estimatedMB)MB) → BatchQueue"
            # v47.4: Odtwórz ChildApps z manifestu (jeśli zapisane)
            if ($manifest.ChildApps -and $manifest.ChildApps.Count -gt 0) {
                if (-not $this.ChildApps.ContainsKey($appName)) { $this.ChildApps[$appName] = @{} }
                foreach ($ca in $manifest.ChildApps) {
                    $cn = [string]$ca.Name
                    if (-not $this.ChildApps[$appName].ContainsKey($cn)) {
                        $this.ChildApps[$appName][$cn] = @{
                            ExePath = [string]$ca.ExePath; Dir = [string]$ca.Dir
                            LastSeen = [datetime]::MinValue
                            LearnedFiles = [System.Collections.Generic.List[hashtable]]::new()
                        }
                    }
                }
            }
            return $true
        } catch { 
            if ($this.CachedApps.ContainsKey($appName)) { $this.CachedApps.Remove($appName) }
            return $false 
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # HIT/MISS tracking
    # ═══════════════════════════════════════════════════════════════
    [bool] IsAppCached([string]$appName) {
        # Ignoruj Desktop i procesy ENGINE — nie licz jako hit/miss
        if ($appName -eq "Desktop" -or $appName -match '^(pwsh|powershell|conhost|WindowsTerminal)$') { return $false }
        $resolved = $this.ResolveAppName($appName)
        if ($resolved -match '^(pwsh|powershell|conhost|WindowsTerminal)$') { return $false }
        if ($this.CachedApps.ContainsKey($resolved)) {
            $this.CachedApps[$resolved].LastAccess = [datetime]::Now
            $this.CachedApps[$resolved].HitCount++
            $this.TotalHits++
            # IsDirty NIE ustawiany na HIT — countery to nie dane strukturalne
            $this.AdjustAggressiveness($true)
            $this.RecordPreloadHit($resolved)
            Write-RCLog "HIT '$appName' → resolved='$resolved' (hitCount=$($this.CachedApps[$resolved].HitCount), totalHits=$($this.TotalHits))"
            return $true
        }
        $this.TotalMisses++
        $this.IsDirty = $true
        # Penalizuj aggressiveness TYLKO gdy MISS na znanej app (powinna być w cache)
        # First-contact MISS (nowa app) jest normalny — nie karać!
        $isKnownApp = $this.AppPaths.ContainsKey($resolved)
        if ($isKnownApp) {
            $this.AdjustAggressiveness($false)  # MISS na znanej app → decrease
        }
        # else: first-contact → no penalty
        Write-RCLog "MISS '$appName' → resolved='$resolved' (totalMisses=$($this.TotalMisses), firstContact=$(-not $isKnownApp), cached=[$(@($this.CachedApps.Keys) -join ',')])"
        return $false
    }
    
    # ═══════════════════════════════════════════════════════════════
    # EVICTION — po decayed priority (nie LRU)
    # ═══════════════════════════════════════════════════════════════
    # ═══════════════════════════════════════════════════════════════
    # EVICTION SCORING (pkt 3,7 instrukcji)
    # Score = (HitWeight × hitCount) + (RecentWeight × recency) + (HeavyBonus) - (SizePenalty)
    # Wyższy score = ważniejszy = evictuj OSTATNI
    # ═══════════════════════════════════════════════════════════════
    [double] GetEvictionScore([string]$appName, [hashtable]$prophetApps) {
        if (-not $this.CachedApps.ContainsKey($appName)) { return 0.0 }
        $entry = $this.CachedApps[$appName]
        $score = 0.0
        
        # Hit weight — każdy hit = +10 punktów (pkt 3: ochrona hitCount>3)
        $score += $entry.HitCount * 10.0
        
        # Recency — ile minut od ostatniego dostępu
        $minutesSinceAccess = ([datetime]::Now - $entry.LastAccess).TotalMinutes
        if ($minutesSinceAccess -lt 2) { $score += 30 }
        elseif ($minutesSinceAccess -lt 5) { $score += 20 }
        elseif ($minutesSinceAccess -lt 15) { $score += 10 }
        elseif ($minutesSinceAccess -lt 30) { $score += 5 }
        # >30 min = 0 bonus
        
        # Heavy app bonus (pkt 7: wyższy retention weight)
        $class = if ($this.AppClassification.ContainsKey($appName)) { $this.AppClassification[$appName] } else { "Light" }
        if ($class -eq "Heavy") { $score += 25 }
        
        # Running process bonus — nigdy nie evictuj running
        $running = Get-Process -Name $appName -ErrorAction SilentlyContinue
        if ($running) { $score += 1000 }
        
        # AltTab protected bonus
        if ($this.IsAltTabProtected($appName)) { $score += 100 }
        
        # Size penalty — większe pliki = droższe w ponownym załadowaniu (mały bonus za duże)
        if ($entry.SizeMB -gt 100) { $score += 5 }  # Duże = drogie do reload

        # #4 STARTUP TIME BONUS — app z długim startem jest droższa do wyrzucenia
        # Skalowanie: 0ms=0pkt, 1000ms=5pkt, 3000ms=15pkt, 8000ms=25pkt (cap)
        if ($this.AppStartupMs.ContainsKey($appName) -and $this.AppStartupMs[$appName] -gt 0) {
            $startupBonus = [Math]::Min(25, [Math]::Round([double]$this.AppStartupMs[$appName] / 320.0, 0))
            $score += $startupBonus
        }
        
        return $score
    }
    
    [void] EvictLowest([hashtable]$prophetApps, [hashtable]$transitions) {
        if ($this.CachedApps.Count -eq 0) { return }
        $lowestApp = $null
        $lowestScore = [double]::MaxValue
        foreach ($appName in @($this.CachedApps.Keys)) {
            $score = $this.GetEvictionScore($appName, $prophetApps)
            if ($score -lt 1000 -and $score -lt $lowestScore) {  # <1000 = nie running
                $lowestScore = $score
                $lowestApp = $appName
            }
        }
        if ($lowestApp) { 
            Write-RCLog "EVICT-SCORE '$lowestApp': score=$([Math]::Round($lowestScore,1)) hits=$($this.CachedApps[$lowestApp].HitCount) free=$([int]$this.LastAvailableMB)MB"
            $this.EvictApp($lowestApp) 
        }
    }
    
    [void] EvictApp([string]$appName) {
        if (-not $this.CachedApps.ContainsKey($appName)) { return }
        $entry = $this.CachedApps[$appName]
        # Sprawdź czy to wasted preload (0 hits)
        if ($entry.HitCount -eq 0) {
            $this.TotalWastedPreloads++
            # NIE zmieniamy Aggressiveness przy eviction — to osobna metryka
        }
        foreach ($f in $entry.Files) {
            try {
                if ($f.ContainsKey('Accessor') -and $f.Accessor) { $f.Accessor.Dispose() }
                if ($f.ContainsKey('MMF') -and $f.MMF) { $f.MMF.Dispose() }
                if ($f.ContainsKey('Stream') -and $f.Stream) { $f.Stream.Dispose() }
                if ($f.ContainsKey('Data')) { $f.Data = $null }
            } catch {}
        }
        $this.TotalCachedMB -= $entry.SizeMB
        if ($this.TotalCachedMB -lt 0) { $this.TotalCachedMB = 0 }
        # Usuń pending batch items z BatchQueue (z cleanup large file MMF handles)
        $remaining = [System.Collections.Generic.Queue[hashtable]]::new()
        while ($this.BatchQueue.Count -gt 0) {
            $item = $this.BatchQueue.Dequeue()
            if ($item.AppName -eq $appName) {
                # Zwolnij otwarte uchwyty MMF dużych plików w trakcie ładowania
                if ($item.ContainsKey('Accessor') -and $item.Accessor) { try { $item.Accessor.Dispose() } catch {} }
                if ($item.ContainsKey('MMF') -and $item.MMF) { try { $item.MMF.Dispose() } catch {} }
            } else { $remaining.Enqueue($item) }
        }
        $this.BatchQueue = $remaining
        # Usuń też z PriorityQueue (foreground queue) z tym samym cleanup
        $remainingP = [System.Collections.Generic.Queue[hashtable]]::new()
        while ($this.PriorityQueue.Count -gt 0) {
            $item = $this.PriorityQueue.Dequeue()
            if ($item.AppName -eq $appName) {
                if ($item.ContainsKey('Accessor') -and $item.Accessor) { try { $item.Accessor.Dispose() } catch {} }
                if ($item.ContainsKey('MMF') -and $item.MMF) { try { $item.MMF.Dispose() } catch {} }
            } else { $remainingP.Enqueue($item) }
        }
        $this.PriorityQueue = $remainingP
        $this.CachedApps.Remove($appName)
        $this.TotalEvictions++
        Write-RCLog "EVICT '$appName' (hits=$($entry.HitCount), wasted=$($entry.HitCount -eq 0), totalEvictions=$($this.TotalEvictions))"
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #8 ADAPTIVE AGGRESSIVENESS — uczy się ile preloadować
    # ═══════════════════════════════════════════════════════════════
    [void] AdjustAggressiveness([bool]$wasHit) {
        # Natural decay: ciągnij 1% w stronę baseline (0.7)
        $baseline = 0.7
        $this.Aggressiveness += ($baseline - $this.Aggressiveness) * 0.01
        
        if ($wasHit) {
            # Hit → bonus (+0.02 nad baseline, +0.04 poniżej) — zachęca do preloadowania
            $bonus = if ($this.Aggressiveness -gt $baseline) { 0.02 } else { 0.04 }
            $this.Aggressiveness = [Math]::Min($this.AggressivenessMax, $this.Aggressiveness + $bonus)
        } else {
            # FIX: Poprzednie -0.12 było 4-6x większe niż nagroda za HIT (+0.02-0.04).
            # Po kilku first-contact MISS (normalne dla nowych appów) system stawał się
            # zbyt zachowawczy i przestawał preloadować. Teraz -0.05 = proporcjonalne.
            $this.Aggressiveness = [Math]::Max($this.AggressivenessMin, $this.Aggressiveness - 0.05)
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #4 PROACTIVE IDLE CACHE z battery/thermal awareness
    # #6 DEPTH-2 CHAIN PREDICTION (A→B full, B→C warm)
    # ═══════════════════════════════════════════════════════════════
    [void] ProactiveCacheIdle([hashtable]$prophetApps, [hashtable]$transitions, [hashtable]$appPaths, [double]$cpuTemp, [bool]$onBattery, [string]$currentMode) {
        if (-not $this.Enabled) { return }
        if ($this.TotalCachedMB -ge $this.MaxCacheMB * 0.8) { return }
        if ($this.MemoryPressure -gt 0.5) { return }
        
        # v43.15: AI Score wysoki → system zajęty, nie preloaduj w tle (oszczędź I/O)
        if ($this.LastAIScore -ge 70) { return }
        
        # #4: Battery/thermal/mode awareness
        if ($onBattery) { return }                         # Na baterii → nie preloaduj w idle
        if ($cpuTemp -gt 70) { return }                    # CPU gorący → pauza
        if ($currentMode -eq "Turbo") { return }           # Dopiero po boost → pauza
        
        # Zbierz kandydatów z Prophet
        $candidates = @{}
        if ($prophetApps) {
            foreach ($appName in $prophetApps.Keys) {
                if ($this.CachedApps.ContainsKey($appName)) { continue }
                $prio = $this.GetDecayedPriority($appName, $prophetApps, $transitions)
                if ($prio -ge 10) {
                    $candidates[$appName] = $prio
                }
            }
        }
        if ($candidates.Count -eq 0) { return }
        
        # Preload top kandydatów — skaluj do HW Tier
        $baseMax = 4  # default
        if ($this.HW -and $this.HW.CacheStrategy) {
            $baseMax = $this.HW.CacheStrategy.MaxIdlePreload
        } else {
            $totalGB = $this.TotalSystemRAM / 1024.0
            $baseMax = if ($totalGB -ge 32) { 8 } elseif ($totalGB -ge 16) { 5 } else { 3 }
        }
        $maxToPreload = [Math]::Max(2, [int]($this.Aggressiveness * $baseMax))
        $sorted = $candidates.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $maxToPreload
        
        foreach ($entry in $sorted) {
            $appName = $this.ResolveAppName($entry.Name)
            # PRIORYTET: DiskCache (instant load)
            if ($this.LoadAppFromDiskCache($appName)) { continue }
            # FALLBACK: PreloadApp z oryginalnych ścieżek
            $exePath = ""
            if ($this.AppPaths.ContainsKey($appName)) { $exePath = $this.AppPaths[$appName].ExePath }
            elseif ($appPaths -and $appPaths.ContainsKey($entry.Name)) { $exePath = $appPaths[$entry.Name] }
            $conf = [Math]::Min(1.0, $entry.Value / 60.0)
            $this.PreloadApp($appName, $exePath, $conf) | Out-Null
        }

        # CHILD PATTERN PRELOAD — dla kandydatów preloaduj też child procs tej sesji
        # Np. znając Reaper → preloaduj vstbridge który zawsze towarzyszy w Gaming
        if ($this.MemoryPressure -le 0.4) {
            $idleSession = $this.CurrentSession
            foreach ($entry2 in $sorted) {
                $parentApp = $this.ResolveAppName($entry2.Name)
                if (-not $this.AppPaths.ContainsKey($parentApp)) { continue }
                $ap2 = $this.AppPaths[$parentApp]
                if (-not $ap2.ContainsKey('ChildPatterns')) { continue }
                if (-not $ap2.ChildPatterns.ContainsKey($idleSession)) { continue }
                $childMap = $ap2.ChildPatterns[$idleSession]
                $topChildren = $childMap.GetEnumerator() | Where-Object { $_.Value -ge 2 } | Sort-Object Value -Descending | Select-Object -First 3
                foreach ($ce in $topChildren) {
                    $childApp = $ce.Key
                    if ($this.CachedApps.ContainsKey($childApp)) { continue }
                    if ($this.MemoryPressure -gt 0.5) { break }
                    $cExe = if ($this.AppPaths.ContainsKey($childApp)) { $this.AppPaths[$childApp].ExePath } else { "" }
                    $cConf = [Math]::Min(0.9, [double]$ce.Value / 10.0)
                    if (-not $this.LoadAppFromDiskCache($childApp)) {
                        $this.PreloadApp($childApp, $cExe, $cConf) | Out-Null
                    }
                    Write-RCLog "CHILD IDLE PRELOAD '$childApp' (child of '$parentApp' w $idleSession, seen=$($ce.Value)x)"
                }
            }
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #6 DEPTH-2 CHAIN PRELOAD — wywołaj gdy ChainPredictor ma prediction
    # B = pełny preload, C = warm only
    # ═══════════════════════════════════════════════════════════════
    [void] ChainPreload([string]$predictedB, [double]$confB, [hashtable]$transitions, [hashtable]$appPaths) {
        if (-not $this.Enabled -or $this.MemoryPressure -gt 0.6) { return }
        
        $resolvedB = $this.ResolveAppName($predictedB)
        if (-not [string]::IsNullOrWhiteSpace($resolvedB) -and $confB -ge 0.3) {
            if (-not $this.CachedApps.ContainsKey($resolvedB)) {
                # PRIORYTET: DiskCache (instant)
                if (-not $this.LoadAppFromDiskCache($resolvedB)) {
                    # FALLBACK: PreloadApp z oryginalnych ścieżek
                    $exeB = ""
                    if ($this.AppPaths.ContainsKey($resolvedB)) { $exeB = $this.AppPaths[$resolvedB].ExePath }
                    elseif ($appPaths -and $appPaths.ContainsKey($predictedB)) { $exeB = $appPaths[$predictedB] }
                    $this.PreloadApp($resolvedB, $exeB, $confB) | Out-Null
                }
            }
            
            if ($transitions -and $transitions.ContainsKey($predictedB)) {
                $bestC = ""; $bestCount = 0; $totalTrans = 0
                foreach ($c in $transitions[$predictedB].Keys) {
                    $count = $transitions[$predictedB][$c].Count
                    $totalTrans += $count
                    if ($count -gt $bestCount) { $bestCount = $count; $bestC = $c }
                }
                if ($bestC -and $totalTrans -gt 0) {
                    $resolvedC = $this.ResolveAppName($bestC)
                    $confC = [Math]::Round($bestCount / $totalTrans, 2) * $confB * 0.5
                    if ($confC -ge 0.2 -and -not $this.CachedApps.ContainsKey($resolvedC)) {
                        # PRIORYTET: DiskCache
                        if (-not $this.LoadAppFromDiskCache($resolvedC)) {
                            $exeC = ""
                            if ($this.AppPaths.ContainsKey($resolvedC)) { $exeC = $this.AppPaths[$resolvedC].ExePath }
                            elseif ($appPaths -and $appPaths.ContainsKey($bestC)) { $exeC = $appPaths[$bestC] }
                            $this.PreloadApp($resolvedC, $exeC, $confC) | Out-Null
                        }
                    }
                }
            }
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # AI TICK — główna pętla eviction/pressure
    # ═══════════════════════════════════════════════════════════════
    [void] AITick([hashtable]$prophetApps, [hashtable]$transitions) {
        $this.AITick($prophetApps, $transitions, $this.LastAIScore, $this.LastAIMode, $this.LastAIContext)
    }

    [void] AITick([hashtable]$prophetApps, [hashtable]$transitions, [double]$aiScore, [string]$aiMode, [string]$aiContext) {
        if (-not $this.Enabled) { return }

        # v43.15: Zapisz feedback od silników AI (widoczny we wszystkich metodach)
        if ($aiScore -gt 0) { $this.LastAIScore = $aiScore }
        if (-not [string]::IsNullOrWhiteSpace($aiMode))    { $this.LastAIMode = $aiMode }
        if (-not [string]::IsNullOrWhiteSpace($aiContext)) { $this.LastAIContext = $aiContext }
        # Zaktualizuj żywy widok danych Prophet (używany w ProfileAppModules do sortowania)
        if ($prophetApps -and $prophetApps.Count -gt 0) { $this.ProphetAppsRef = $prophetApps }

        # v43.15: Gdy AI Score wysoki (Turbo / heavy load) → natychmiast chroń foreground app WS
        # AI wie że system jest pod obciążeniem — nie czekaj co 30s na ReassertProtectedWorkingSets
        if ($aiScore -ge 75 -and $this.HeavyMode -and -not [string]::IsNullOrWhiteSpace($this.HeavyModeApp)) {
            # Ustaw BatchSize na minimum — nie marnuj I/O czasu procesora na ładowanie w tle
            $this.BatchSizeBytes = $this.BatchSizeMin
        } elseif ($aiScore -lt 30 -and $this.BatchSizeBytes -lt $this.BatchSizeMax) {
            # Niskie obciążenie → wróć do agresywnego preload
            $this.BatchSizeBytes = [Math]::Min($this.BatchSizeMax, $this.BatchSizeBytes + 2MB)
        }

        # v43.15: Turbo = blokada eviction (nie wyrzucaj cache gdy CPU/GPU pod pełnym obciążeniem)
        if ($aiMode -eq "Turbo" -and $this.HeavyMode) {
            # Tylko BatchTick + WS re-assert — pomiń całą resztę (eviction, resize, itp.)
            $this.BatchTick() | Out-Null
            if (-not $this.PSObject.Properties['_LastReassertTime']) {
                $this | Add-Member -NotePropertyName '_LastReassertTime' -NotePropertyValue ([datetime]::MinValue) -Force
            }
            if (([datetime]::Now - $this._LastReassertTime).TotalSeconds -ge 15) {
                $this._LastReassertTime = [datetime]::Now
                $this.ReassertProtectedWorkingSets()
            }
            return
        }

        $now = [datetime]::Now
        if (($now - $this.LastEvictionCheck).TotalSeconds -lt 15) { return }
        $this.LastEvictionCheck = $now
        
        # Batch tick
        $this.BatchTick() | Out-Null
        
        # Zmierz memory pressure
        $this.MeasureMemoryPressure() | Out-Null
        
        # ═══ DYNAMIC CACHE RESIZE ═══
        # Filozofia: wolny RAM = zmarnowany RAM. Cache rośnie do limitu wolnego RAM.
        $guardReq = if ($this.HeavyMode) { $this.GuardBandHeavyMB } else { $this.GuardBandMB }
        $freeAfterGuard = $this.LastAvailableMB - $guardReq
        $absMax = [int]($this.TotalSystemRAM * 0.60)  # Absolutny max = 60% RAM
        
        if ($freeAfterGuard -gt 1024 -and $this.MemoryPressure -lt 0.3) {
            # Dużo wolnego RAM → cache rośnie agresywnie
            # Rośnie o 512MB per tick (co 15s) aż do wolny RAM - guard band
            $targetMax = [Math]::Min($absMax, [int]($this.TotalCachedMB + $freeAfterGuard * 0.5))
            $newMax = [Math]::Min($targetMax, $this.MaxCacheMB + 512)
            if ($newMax -gt $this.MaxCacheMB) {
                $old = $this.MaxCacheMB
                $this.MaxCacheMB = $newMax
                if ($newMax - $old -ge 256) {
                    Write-RCLog "RESIZE UP: MaxCache $($old)→$($this.MaxCacheMB)MB (free=$([int]$this.LastAvailableMB)MB guard=$([int]$guardReq)MB)"
                }
            }
        } elseif ($this.MemoryPressure -gt 0.5 -or $freeAfterGuard -lt 256) {
            # RAM ciasno → zmniejszaj cache, oddaj pamięć systemowi
            $shrink = if ($this.MemoryPressure -gt 0.7) { 1024 } else { 512 }
            $newMax = [Math]::Max(256, $this.MaxCacheMB - $shrink)
            if ($newMax -lt $this.MaxCacheMB) {
                $old = $this.MaxCacheMB
                $this.MaxCacheMB = $newMax
                Write-RCLog "RESIZE DOWN: MaxCache $($old)→$($this.MaxCacheMB)MB (free=$([int]$this.LastAvailableMB)MB pressure=$([Math]::Round($this.MemoryPressure,2)))"
            }
        }
        
        # #4: Guard Band enforcement — JEDYNY powód do eviction przy niskim RAM
        if (-not $this.HasGuardBandSpace()) {
            $this.EnforceGuardBand($prophetApps, $transitions)
        }
        
        # #9: Page Fault response
        if ($this.LastPageFaultsPerSec -gt 200 -and $this.HeavyMode) {
            $this.PageFaultResponse($this.HeavyModeApp, $prophetApps, $transitions)
        }
        
        # #2: Cleanup dead protected apps
        $this.CleanupProtectedApps()
        
        # RE-ASSERT WorkingSet co ~30s — Windows trim'uje WS nawet przy MinWorkingSet ustawionym
        if (-not $this.PSObject.Properties['_LastReassertTime']) {
            $this | Add-Member -NotePropertyName '_LastReassertTime' -NotePropertyValue ([datetime]::MinValue) -Force
        }
        if (([datetime]::Now - $this._LastReassertTime).TotalSeconds -ge 30) {
            $this._LastReassertTime = [datetime]::Now
            $this.ReassertProtectedWorkingSets()
        }
        
        # RETOUCH: zapobiega WS trim — cache widoczny jako "In Use" nie "Available"
        $this.RetouchCachedPages()
        
        if ($this.CachedApps.Count -eq 0) { return }
        
        # ═══════════════════════════════════════════════════════════
        # NOWA POLITYKA EVICTION: wolny RAM > 25% total → ZERO eviction
        # Eviction TYLKO gdy system naprawdę potrzebuje pamięci
        # ═══════════════════════════════════════════════════════════
        $freePercent = if ($this.TotalSystemRAM -gt 0) { $this.LastAvailableMB / $this.TotalSystemRAM } else { 0.5 }
        
        # TWARDY PRÓG: dopóki wolny RAM > 25% total → nic nie ruszaj
        if ($freePercent -gt 0.25) { return }
        
        # 15-25% free: lekka eviction — tylko nie-running apps z 0 hitów i stare >30 min
        if ($freePercent -gt 0.15) {
            foreach ($appName in @($this.CachedApps.Keys)) {
                if ($this.IsAltTabProtected($appName)) { continue }
                $running = Get-Process -Name $appName -ErrorAction SilentlyContinue
                if ($running) { continue }
                $entry = $this.CachedApps[$appName]
                $age = ($now - $entry.LastAccess).TotalMinutes
                # Tylko evictuj app z 0 hitów i starsze niż 30 min (było 10 min)
                # Apps z hitami TRZYMAJ — user je używa, wróci do nich
                if ($entry.HitCount -eq 0 -and $age -gt 30) {
                    # Zapisz na dysk ZANIM evictujesz (szybki reload potem)
                    $this.SaveAppToDiskCache($appName)
                    Write-RCLog "EVICT-STALE '$appName': 0 hits, age=$([int]$age)min → saved to DiskCache"
                    $this.EvictApp($appName)
                }
            }
            return
        }
        
        # <15% free: agresywna eviction — evictuj najniższy priorytet ALE zapisz na dysk
        Write-RCLog "LOW RAM EVICT: free=$([int]$this.LastAvailableMB)MB ($([int]($freePercent*100))%) pressure=$([Math]::Round($this.MemoryPressure,2))"
        while ($freePercent -lt 0.20 -and $this.CachedApps.Count -gt 0) {
            # Przed eviction: save to disk (instant reload later)
            $lowestApp = $null; $lowestScore = [double]::MaxValue
            foreach ($a in @($this.CachedApps.Keys)) {
                $score = $this.GetEvictionScore($a, $prophetApps)
                if ($score -lt 1000 -and $score -lt $lowestScore) { $lowestScore = $score; $lowestApp = $a }
            }
            if ($lowestApp) { $this.SaveAppToDiskCache($lowestApp) }
            $this.EvictLowest($prophetApps, $transitions)
            $this._LastWMICheck = [DateTime]::MinValue  # Force fresh measurement
            $this.MeasureMemoryPressure() | Out-Null
            $freePercent = if ($this.TotalSystemRAM -gt 0) { $this.LastAvailableMB / $this.TotalSystemRAM } else { 0.5 }
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # RETOUCH CACHED PAGES — zapobiega Windows working set trimming
    # Windows trimuje nieaktywne strony do Standby List po ~60s
    # Standby = "Available" w Task Manager → user myśli że RAM wolny
    # Re-touch co 120s = strony zostają w Working Set = widoczne jako "In Use"
    # ═══════════════════════════════════════════════════════════════
    [datetime] $LastRetouchTime = [datetime]::MinValue
    
    [void] RetouchCachedPages() {
        $now = [datetime]::Now
        # BUG FIX: Windows trimuje strony do Standby po ~60s nieaktywności.
        # Poprzednie 120s tworzyło okno gdzie strony były wyrzucane. Teraz 55s = zawsze przed trimem.
        if (($now - $this.LastRetouchTime).TotalSeconds -lt 55) { return }
        $this.LastRetouchTime = $now

        # Nie rób retouch przy memory pressure
        if ($this.MemoryPressure -gt 0.4) { return }

        $touchedApps = 0
        $touchedMB = 0
        foreach ($appName in @($this.CachedApps.Keys)) {
            $entry = $this.CachedApps[$appName]
            if (-not $entry.Files -or $entry.Files.Count -eq 0) { continue }

            foreach ($f in $entry.Files) {
                try {
                    if ($f.ContainsKey('Accessor') -and $f.Accessor -and $f.ContainsKey('SizeBytes')) {
                        $size = $f.SizeBytes
                        $dummyByte = [byte]0
                        # Dynamiczny stride: małe pliki (<200MB) co 64KB, duże co 512KB.
                        # Zapobiega blokującym spiком CPU przy wielogigabajtowym cache.
                        $retouchStride = if ($size -gt 200MB) { 524288 } else { 65536 }
                        for ($offset = 0; $offset -lt $size; $offset += $retouchStride) {
                            $dummyByte = $f.Accessor.ReadByte($offset)
                        }
                    }
                } catch { continue }
            }
            $touchedApps++
            $touchedMB += $entry.SizeMB
        }

        if ($touchedApps -gt 0) {
            Write-RCLog "RETOUCH: $touchedApps apps ($([int]$touchedMB)MB) — pages kept in working set"
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # #10 IDLE LEARNING PHASE — refleksja i rewizja score'ów
    # Wywoływane gdy idle >60s
    # ═══════════════════════════════════════════════════════════════
    [hashtable] IdleLearn() {
        $now = [datetime]::Now
        if (($now - $this.LastIdleLearn).TotalSeconds -lt 60) { return $null }
        $this.LastIdleLearn = $now
        
        $totalOps = $this.TotalHits + $this.TotalMisses
        $hitRate = if ($totalOps -gt 0) { [Math]::Round($this.TotalHits / $totalOps * 100, 1) } else { 0 }
        $wasteRate = if ($this.TotalPreloads -gt 0) { [Math]::Round($this.TotalWastedPreloads / $this.TotalPreloads * 100, 1) } else { 0 }
        
        # Auto-adjust aggressiveness based on performance
        if ($totalOps -ge 10) {
            if ($hitRate -gt 70 -and $wasteRate -lt 30) {
                # Dobre trafienia, mało odpadów → zwiększ agresję
                $this.Aggressiveness = [Math]::Min($this.AggressivenessMax, $this.Aggressiveness + 0.02)
            }
            elseif ($hitRate -lt 30 -or $wasteRate -gt 60) {
                # Słabe trafienia lub dużo odpadów → zmniejsz
                $this.Aggressiveness = [Math]::Max($this.AggressivenessMin, $this.Aggressiveness - 0.03)
            }
        }
        
        # Auto-adjust MaxCacheMB — NIGDY nie zmniejszaj poniżej dynamicznego minimum
        # Dynamic resize jest już w AITick — tu NIE ruszamy MaxCacheMB
        # (stary kod miał hard cap 1536MB co sabotowało 20GB cache)
        
        return @{
            HitRate = $hitRate
            WasteRate = $wasteRate
            Aggressiveness = [Math]::Round($this.Aggressiveness, 2)
            MaxCacheMB = $this.MaxCacheMB
            MemoryPressure = [Math]::Round($this.MemoryPressure, 2)
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # ELEVATE TO PRIORITY — przesuń pliki app z BatchQueue → PriorityQueue
    # Wywołaj gdy użytkownik przełącza się na tę aplikację (foreground change).
    # Pliki tej app będą załadowane w NASTĘPNYM BatchTick zamiast czekać w kolejce.
    # ═══════════════════════════════════════════════════════════════
    [void] ElevateToPriority([string]$appName) {
        if (-not $this.Enabled -or [string]::IsNullOrWhiteSpace($appName)) { return }
        $resolved = $this.ResolveAppName($appName)
        $elevated = 0
        $remaining = [System.Collections.Generic.Queue[hashtable]]::new()
        while ($this.BatchQueue.Count -gt 0) {
            $item = $this.BatchQueue.Dequeue()
            if ($item.AppName -eq $resolved) {
                $this.PriorityQueue.Enqueue($item)
                $elevated++
            } else {
                $remaining.Enqueue($item)
            }
        }
        $this.BatchQueue = $remaining
        if ($elevated -gt 0) {
            Write-RCLog "ELEVATE '$resolved': $elevated items → PriorityQueue (will load next tick)"
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # v47.4: PRELOAD CHILD APPS — załaduj znane dzieci rodzica
    # Wywoływane przy HIT/MISS/WARMUP rodzica
    # ═══════════════════════════════════════════════════════════════
    [void] PreloadChildApps([string]$parentApp) {
        if (-not $this.Enabled -or [string]::IsNullOrWhiteSpace($parentApp)) { return }
        $resolved = $this.ResolveAppName($parentApp)
        if (-not $this.ChildApps.ContainsKey($resolved)) { return }
        $children = $this.ChildApps[$resolved]
        if ($children.Count -eq 0) { return }
        # Guard band check — nie ładuj dzieci gdy brak RAM
        if (-not $this.HasGuardBandSpace()) { return }
        $loadedChildren = 0
        foreach ($childName in @($children.Keys)) {
            # Skip jeśli dziecko już w cache
            if ($this.CachedApps.ContainsKey($childName)) {
                # Ale elevate jeśli są pliki w BatchQueue
                $this.ElevateToPriority($childName)
                continue
            }
            $childInfo = $children[$childName]
            # Priorytet 1: DiskCache manifest (szybko)
            if ($this.LoadAppFromDiskCache($childName)) {
                $this.ElevateToPriority($childName)
                $loadedChildren++
                continue
            }
            # Priorytet 2: LearnedFiles z ChildApps (zebrane podczas profilu)
            if ($childInfo.LearnedFiles -and $childInfo.LearnedFiles.Count -gt 2) {
                # Zarejestruj w AppPaths i preloaduj
                if (-not $this.AppPaths.ContainsKey($childName)) {
                    $this.AppPaths[$childName] = @{ ExePath = $childInfo.ExePath; Dir = $childInfo.Dir }
                }
                $this.AppPaths[$childName].LearnedFiles = $childInfo.LearnedFiles
                $this.PreloadApp($childName, $childInfo.ExePath, 0.8) | Out-Null
                $this.ElevateToPriority($childName)
                $loadedChildren++
                continue
            }
            # Priorytet 3: PreloadApp z exe path (fallback — wolne, skanuje katalog)
            if ($childInfo.ExePath -and (Test-Path $childInfo.ExePath -ErrorAction SilentlyContinue)) {
                $this.PreloadApp($childName, $childInfo.ExePath, 0.7) | Out-Null
                $this.ElevateToPriority($childName)
                $loadedChildren++
            }
        }
        if ($loadedChildren -gt 0) {
            Write-RCLog "CHILD PRELOAD '$resolved': $loadedChildren/$($children.Count) children loaded"
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # FORCE BATCH TICK — pomija 200ms timer, używany w Launch Race
    # ═══════════════════════════════════════════════════════════════
    [int] ForceBatchTick() {
        $this.LastBatchTick = [datetime]::MinValue
        return $this.BatchTick()
    }

    # ── #4 Helper: zapisz próbkę czasu startu, oblicz medianę z ostatnich 5 pomiarów ──
    [void] _RecordStartupMs([string]$appName, [int]$ms) {
        if ([string]::IsNullOrWhiteSpace($appName) -or $ms -le 0 -or $ms -gt 120000) { return }
        if (-not $this.AppStartupMs.ContainsKey($appName)) {
            $this.AppStartupMs[$appName] = $ms
        } else {
            # Wygładzanie wykładnicze (EMA α=0.3) — odporne na outliers, nie wymaga listy próbek
            $prev = [double]$this.AppStartupMs[$appName]
            $this.AppStartupMs[$appName] = [int]($prev * 0.7 + $ms * 0.3)
        }
        $this.IsDirty = $true
    }

    # ═══════════════════════════════════════════════════════════════
    # ON PROCESS LAUNCH — wywoływane gdy WMI wykryje start nowego procesu
    #
    # MECHANIZM WYŚCIGU (Launch Race):
    # Użytkownik klika dwukrotnie aplikację → Windows tworzy proces →
    # WMI wykrywa (w ~500ms) → CPUManager NATYCHMIAST ładuje wszystkie
    # znane pliki (DLL, PAK, shadery) do kernel file cache przez MMF.
    # Proces loader aplikacji ładuje DLL sekwencyjnie — CPUManager
    # ładuje je RÓWNOLEGLE z wyprzedzeniem. Gdy loader pyta OS o plik,
    # OS oddaje go z RAM zamiast czytać z dysku. Zero I/O wait.
    # ═══════════════════════════════════════════════════════════════
    [void] OnProcessLaunch([string]$procName, [hashtable]$prophetApps) {
        if (-not $this.Enabled) { return }
        $resolved = $this.ResolveAppName($procName)
        if ([string]::IsNullOrWhiteSpace($resolved)) { return }

        # Blacklist: system procesy, UWP shell, ENGINE sam
        if ($resolved -match '^(pwsh|powershell|conhost|WindowsTerminal|ShellHost|explorer|dwm|WinStore\.App|ApplicationFrameHost|SystemSettings|svchost|csrss|lsass|winlogon|services|RuntimeBroker|SearchHost|StartMenuExperienceHost)$') { return }

        # Nie reaguj jeśli już trwa wyścig dla tej samej app
        if ($this.IsInLaunchRace -and $this.LaunchRaceApp -eq $resolved) { return }

        Write-RCLog "LAUNCH RACE START '$resolved' — preemptive preload before process init"

        # ── Krok 1: Załaduj z disk cache (najszybsza ścieżka — manifest JSON) ──
        $loaded = $false
        if (-not $this.CachedApps.ContainsKey($resolved)) {
            $loaded = $this.LoadAppFromDiskCache($resolved)
            if (-not $loaded) {
                # Fallback: PreloadApp ze znanych ścieżek (skanuje dir + LearnedFiles)
                $exePath = if ($this.AppPaths.ContainsKey($resolved)) { $this.AppPaths[$resolved].ExePath } else { "" }
                if (-not [string]::IsNullOrWhiteSpace($exePath)) {
                    $loaded = $this.PreloadApp($resolved, $exePath, 1.0)
                }
            }
        } else {
            $loaded = $true  # Już w cache
        }

        # ── Krok 2: Przesuń wszystkie pliki tej app do PriorityQueue ──
        $this.ElevateToPriority($resolved)

        # ── Krok 3: Aktywuj Launch Race — main loop będzie wywoływał ForceBatchTick ──
        $this.IsInLaunchRace = $true
        $this.LaunchRaceApp = $resolved
        $this.LaunchRaceStart = [datetime]::Now  # #4 Mierz czas startu
        # Okno wyścigu: dynamiczne — bazowe 15s, ale jeśli znamy historyczny startup to 2× mediana (min 8s max 30s)
        $knownStartupMs = if ($this.AppStartupMs.ContainsKey($resolved) -and $this.AppStartupMs[$resolved] -gt 0) { [int]$this.AppStartupMs[$resolved] } else { 0 }
        $raceWindowSec = if ($knownStartupMs -gt 0) { [Math]::Max(8, [Math]::Min(30, [int]($knownStartupMs * 2 / 1000))) } else { 15 }
        $this.LaunchRaceUntil = [datetime]::Now.AddSeconds($raceWindowSec)

        # ── Krok 4: Zaplanuj odroczone profilowanie modułów (+2s) ──
        # Po 2s proces załadował już większość DLL → profileAppModules dostanie pełną listę
        $this.PendingProfileQueue.Add(@{
            AppName     = $resolved
            ProfileAfter = [datetime]::Now.AddSeconds(2)
        })

        Write-RCLog "LAUNCH RACE ARMED '$resolved': PriorityQ=$($this.PriorityQueue.Count) items, DiskLoaded=$loaded, RaceUntil=$($this.LaunchRaceUntil.ToString('HH:mm:ss'))"
    }

    # ═══════════════════════════════════════════════════════════════
    # LAUNCH RACE TICK — wywoływany z main loop gdy IsInLaunchRace=true
    # Przetwarza pliki z PriorityQueue bez 200ms opóźnień.
    # Zwraca $true gdy wyścig nadal trwa.
    # ═══════════════════════════════════════════════════════════════
    [bool] LaunchRaceTick([hashtable]$prophetApps) {
        if (-not $this.IsInLaunchRace) { return $false }

        # Sprawdź deadline
        if ([datetime]::Now -gt $this.LaunchRaceUntil) {
            # #4 Zapisz czas startu przy timeout (startup trwał tyle ile okno race)
            if ($this.LaunchRaceStart -ne [datetime]::MinValue) {
                $startupMs = [int]([datetime]::Now - $this.LaunchRaceStart).TotalMilliseconds
                $this._RecordStartupMs($this.LaunchRaceApp, $startupMs)
            }
            Write-RCLog "LAUNCH RACE END '$($this.LaunchRaceApp)' — timeout, PriorityQ=$($this.PriorityQueue.Count) remaining"
            $this.IsInLaunchRace = $false
            $this.LaunchRaceApp = ""
            $this.LaunchRaceStart = [datetime]::MinValue
            return $false
        }

        # Sprawdź odroczone profilowania
        $now = [datetime]::Now
        $toRemove = [System.Collections.Generic.List[hashtable]]::new()
        foreach ($pending in $this.PendingProfileQueue) {
            if ($now -ge $pending.ProfileAfter) {
                $this.ProfileAppModules($pending.AppName)
                $toRemove.Add($pending)
            }
        }
        foreach ($r in $toRemove) { $this.PendingProfileQueue.Remove($r) | Out-Null }

        # Jeśli PriorityQueue pusta → wyścig wygrany
        if ($this.PriorityQueue.Count -eq 0) {
            # #4 Zapisz czas startu — WIN = app faktycznie załadowana przed/w trakcie inicjalizacji
            if ($this.LaunchRaceStart -ne [datetime]::MinValue) {
                $startupMs = [int]([datetime]::Now - $this.LaunchRaceStart).TotalMilliseconds
                $this._RecordStartupMs($this.LaunchRaceApp, $startupMs)
                Write-RCLog "LAUNCH RACE WIN '$($this.LaunchRaceApp)' — all files loaded into RAM (startup~${startupMs}ms)"
            } else {
                Write-RCLog "LAUNCH RACE WIN '$($this.LaunchRaceApp)' — all files loaded into RAM"
            }
            $this.IsInLaunchRace = $false
            $this.LaunchRaceApp = ""
            $this.LaunchRaceStart = [datetime]::MinValue
            return $false
        }

        # Agresywny batch — ignoruj 200ms timer
        $this.ForceBatchTick() | Out-Null
        return $true
    }

    # ═══════════════════════════════════════════════════════════════
    # NAME RESOLUTION: DisplayName ↔ ProcessName
    # currentForeground = "Google Chrome" → CachedApps key = "chrome"
    # ═══════════════════════════════════════════════════════════════
    [string] ResolveAppName([string]$name) {
        # Bezpośredni klucz?
        if ($this.CachedApps.ContainsKey($name)) { return $name }
        if ($this.AppPaths.ContainsKey($name)) { return $name }
        # Mapping DisplayName → ProcessName?
        if ($this.NameMap.ContainsKey($name)) { return $this.NameMap[$name] }
        # Reverse: może to ProcessName a ktoś szuka DisplayName
        foreach ($displayName in $this.NameMap.Keys) {
            if ($this.NameMap[$displayName] -eq $name) { return $name }
        }
        # Case-insensitive fallback — np. Thunderbird vs thunderbird
        $nameLower = $name.ToLower()
        foreach ($key in $this.CachedApps.Keys) {
            if ($key.ToLower() -eq $nameLower) { return $key }
        }
        foreach ($key in $this.AppPaths.Keys) {
            if ($key.ToLower() -eq $nameLower) { return $key }
        }
        foreach ($displayName in $this.NameMap.Keys) {
            if ($this.NameMap[$displayName].ToLower() -eq $nameLower) { return $this.NameMap[$displayName] }
        }
        return $name  # Zwróć jak jest
    }
    
    [void] LearnName([string]$displayName, [string]$processName) {
        if ([string]::IsNullOrWhiteSpace($displayName) -or [string]::IsNullOrWhiteSpace($processName)) { return }
        if ($displayName -eq $processName) { return }
        # Ignoruj Desktop i procesy ENGINE
        if ($displayName -eq "Desktop" -or $processName -match '^(pwsh|powershell|conhost|WindowsTerminal)$') { return }
        if (-not $this.NameMap.ContainsKey($displayName)) {
            $this.NameMap[$displayName] = $processName
            Write-RCLog "NAME MAP: '$displayName' → '$processName'"
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # #1 CLASSIFY APP — Heavy vs Light na podstawie Prophet data
    # ═══════════════════════════════════════════════════════════════
    [string] ClassifyApp([string]$appName, [hashtable]$prophetApps) {
        if ($this.AppClassification.ContainsKey($appName)) { return $this.AppClassification[$appName] }
        $class = "Light"
        if ($prophetApps -and $prophetApps.ContainsKey($appName)) {
            $app = $prophetApps[$appName]
            $avgCPU = if ($app.AvgCPU) { [double]$app.AvgCPU } else { 0 }
            $isHeavy = if ($app.IsHeavy) { $app.IsHeavy } else { $false }
            $samples = if ($app.Samples) { [int]$app.Samples } else { 0 }
            # Heavy: IsHeavy flag OR avgCPU>50% z >20 samples
            if ($isHeavy -or ($avgCPU -gt 50 -and $samples -gt 20)) { $class = "Heavy" }
        }
        # v43.15: LearnedFiles size jako sygnał Heavy (app z >80MB modułów = ciężka)
        # Ważne: działa nawet gdy Prophet nie ma jeszcze danych (nowa instalacja)
        if ($class -eq "Light" -and $this.AppPaths.ContainsKey($appName)) {
            $lf = $this.AppPaths[$appName].LearnedFiles
            if ($lf -and $lf.Count -gt 0) {
                $lfSizeMB = 0; foreach ($f in $lf) { $lfSizeMB += $f.Size }
                $lfSizeMB = $lfSizeMB / 1MB
                if ($lfSizeMB -gt 80) { $class = "Heavy" }  # >80MB modułów = Heavy
            }
        }
        # Runtime check: czy process ma duży working set?
        try {
            $proc = Get-Process -Name $appName -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($proc -and $proc.WorkingSet64 -gt 1500MB) { $class = "Heavy" }
        } catch {}
        $this.AppClassification[$appName] = $class
        return $class
    }

    # ═══════════════════════════════════════════════════════════════
    # #2 WORKING SET PROTECTION — monituj i chroń heavy apps
    # ═══════════════════════════════════════════════════════════════
    [void] ProtectWorkingSet([string]$appName) {
        try {
            $procs = Get-Process -Name $appName -ErrorAction SilentlyContinue
            if (-not $procs) { return }
            
            # Zbierz procesy do ochrony: główny + potomne (VST bridge, plugin hosts)
            $procsToProtect = [System.Collections.Generic.List[object]]::new()
            foreach ($p in $procs) { $procsToProtect.Add($p) }
            
            $childPluginNames = @('vstbridge','vsthost','jbridge','audiogridder',
                'pluginval','vst3scanner','vstscanner','bridgeserver','clap-bridge',
                'reaper_host','reaper_vst','bitwig-engine','bitwig-bridge',
                'audiopluginhost','pluginhost','sforzando','xlnaudio')
            try {
                $mainPids = $procs | Select-Object -ExpandProperty Id
                $allProcs = Get-Process -ErrorAction SilentlyContinue
                foreach ($cp in $allProcs) {
                    $isChild = $false
                    try {
                        $wmiP = Get-CimInstance Win32_Process -Filter "ProcessId=$($cp.Id)" -ErrorAction SilentlyContinue
                        if ($wmiP -and $mainPids -contains $wmiP.ParentProcessId) { $isChild = $true }
                    } catch {}
                    if (-not $isChild) {
                        $cpn = $cp.ProcessName.ToLower()
                        foreach ($ph in $childPluginNames) { if ($cpn -like "*$ph*") { $isChild = $true; break } }
                    }
                    if ($isChild) { $procsToProtect.Add($cp) }
                }
            } catch {}
            
            foreach ($proc in $procsToProtect) {
                $ws = $proc.WorkingSet64
                if ($ws -lt 50MB) { continue }  # Nie chronimy bardzo małych
                $key = "$appName`:$($proc.Id)"
                if ($this.ProtectedApps.ContainsKey($key)) {
                    # Update stable WS (slow moving average)
                    $entry = $this.ProtectedApps[$key]
                    $entry.StableWS = [long]($entry.StableWS * 0.9 + $ws * 0.1)
                } else {
                    $this.ProtectedApps[$key] = @{
                        PID = $proc.Id
                        AppName = "$appName[$($proc.ProcessName)]"
                        MinWS = $ws
                        StableWS = $ws
                        ProtectedAt = [datetime]::Now
                    }
                }
                # SetProcessWorkingSetSizeEx z flagą HARD_MIN — wymusza min WS w RAM (nie tylko hint!)
                try {
                    $minWS = [Math]::Max(50MB, [long]($ws * 0.70))  # 70% WS jako twardy min
                    $maxWS = [Math]::Max($minWS + 128MB, [long]($ws * 1.30))  # Max = 130% WS
                    $ok = Set-HardMinWorkingSet -Handle $proc.Handle -MinWS $minWS -MaxWS $maxWS
                    if (-not $ok) {
                        # Fallback do miękkiego hintu gdy brak uprawnień
                        $proc.MinWorkingSet = [IntPtr]$minWS
                    }
                } catch {
                    try { $proc.MinWorkingSet = [IntPtr]([Math]::Max(50MB, [long]($ws * 0.7))) } catch {}
                }
            }
        } catch {}
    }

    # Re-assertuje MinWS na chronionych procesach (wywołuj co ~30s z głównej pętli)
    # Windows regularnie trim'uje WS nawet przy ustawionym MinWorkingSet — to kontruje ten efekt
    [void] ReassertProtectedWorkingSets() {
        foreach ($key in @($this.ProtectedApps.Keys)) {
            $entry = $this.ProtectedApps[$key]
            try {
                $proc = Get-Process -Id $entry.PID -ErrorAction Stop
                $currentWS = $proc.WorkingSet64
                $minWS = [Math]::Max(50MB, [long]($entry.StableWS * 0.70))
                $maxWS = [Math]::Max($minWS + 128MB, [long]($entry.StableWS * 1.30))
                # Czy Windows już ztruncował WS poniżej naszego minimum?
                if ($currentWS -lt $minWS) {
                    $ok = Set-HardMinWorkingSet -Handle $proc.Handle -MinWS $minWS -MaxWS $maxWS
                    if (-not $ok) { $proc.MinWorkingSet = [IntPtr]$minWS }
                    Write-RCLog "REASSERT WS '$($entry.AppName)' PID=$($entry.PID): was=$([int]($currentWS/1MB))MB → min=$([int]($minWS/1MB))MB"
                }
                # Aktualizuj StableWS
                $entry.StableWS = [long]($entry.StableWS * 0.9 + $currentWS * 0.1)
            } catch {
                $this.ProtectedApps.Remove($key)  # Proces zakończony
            }
        }
    }
    
    [void] CleanupProtectedApps() {
        foreach ($key in @($this.ProtectedApps.Keys)) {
            $entry = $this.ProtectedApps[$key]
            try {
                $proc = Get-Process -Id $entry.PID -ErrorAction Stop
            } catch {
                $this.ProtectedApps.Remove($key)  # Process died
            }
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # #3 HEAVY MODE — global stabilization mode
    # ═══════════════════════════════════════════════════════════════
    [void] UpdateHeavyMode([string]$foregroundApp, [double]$cpu, [double]$gpuLoad, [hashtable]$prophetApps) {
        # Ignoruj Desktop i ENGINE procesy
        if ($foregroundApp -eq "Desktop" -or $foregroundApp -match '^(pwsh|powershell|conhost|WindowsTerminal)$') { return }
        $appClass = $this.ClassifyApp($foregroundApp, $prophetApps)
        $shouldBeHeavy = $false
        # Warunki aktywacji: heavy app na pierwszym planie + CPU>60% LUB GPU>60%
        if ($appClass -eq "Heavy" -and ($cpu -gt 60 -or $gpuLoad -gt 60)) {
            $shouldBeHeavy = $true
        }
        # Aktywacja
        if ($shouldBeHeavy -and -not $this.HeavyMode) {
            $this.HeavyMode = $true
            $this.HeavyModeApp = $foregroundApp
            $this.HeavyModeActivated = [datetime]::Now
            $this.ProtectWorkingSet($foregroundApp)
            # v47.4: HEAVY MODE → natychmiastowy re-profil (łapie VST pluginy załadowane po starcie DAW)
            $this.ProfileAppModules($foregroundApp)
            Write-RCLog "HEAVY MODE ON: '$foregroundApp' (CPU=$([int]$cpu)% GPU=$([int]$gpuLoad)%)"
        }
        # Deaktywacja: heavy app nie jest już foreground przez >2 min
        elseif ($this.HeavyMode -and $foregroundApp -ne $this.HeavyModeApp) {
            if (([datetime]::Now - $this.HeavyModeActivated).TotalMinutes -gt 2) {
                # Sprawdź czy heavy app jeszcze działa
                $stillRunning = Get-Process -Name $this.HeavyModeApp -ErrorAction SilentlyContinue
                if (-not $stillRunning) {
                    $this.HeavyMode = $false
                    $this.HeavyModeApp = ""
                }
                # Jeśli działa ale nie jest foreground >5 min → wyłącz heavy mode
                elseif (([datetime]::Now - $this.HeavyModeActivated).TotalMinutes -gt 5) {
                    $this.HeavyMode = $false
                }
            }
        }
        # Odśwież WS protection w heavy mode
        if ($this.HeavyMode) {
            $this.ProtectWorkingSet($this.HeavyModeApp)
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # #4 GUARD BAND RAM — nie spadaj poniżej min free RAM
    # Zwraca $true jeśli jest wystarczająco dużo wolnego RAM
    # ═══════════════════════════════════════════════════════════════
    [bool] HasGuardBandSpace() {
        if ($this.LastAvailableMB -le 0) { $this.MeasureMemoryPressure() | Out-Null }
        
        $required = if ($this.HeavyMode) { $this.GuardBandHeavyMB } else { $this.GuardBandMB }
        $totalGB = $this.TotalSystemRAM / 1024.0
        $availPercent = if ($this.TotalSystemRAM -gt 0) { ($this.LastAvailableMB / $this.TotalSystemRAM) * 100.0 } else { 50.0 }
        
        # Przy dużym RAM i >30% available → ZAWSZE pozwól (pkt 4,6)
        if ($totalGB -ge 32 -and $availPercent -gt 30) { return $true }
        if ($totalGB -ge 16 -and $availPercent -gt 35) { return $true }
        
        return ($this.LastAvailableMB -ge $required)
    }
    
    [void] EnforceGuardBand([hashtable]$prophetApps, [hashtable]$transitions) {
        $required = if ($this.HeavyMode) { $this.GuardBandHeavyMB } else { $this.GuardBandMB }
        if ($this.LastAvailableMB -ge $required) { return }
        Write-RCLog "GUARD BAND ENFORCE: avail=$([int]$this.LastAvailableMB)MB < required=$([int]$required)MB"
        while ($this.LastAvailableMB -lt $required -and $this.CachedApps.Count -gt 0) {
            $this.EvictLowest($prophetApps, $transitions)
            $this.MeasureMemoryPressure() | Out-Null
            if ($this.CachedApps.Count -eq 0) { break }
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # #5 ANTI-ALTTAB PROTECTION
    # Po alt-tab z fullscreen: chroni app przez 3 minuty
    # ═══════════════════════════════════════════════════════════════
    [void] RecordFocusChange([string]$newApp, [string]$oldApp) {
        $now = [datetime]::Now
        $this.LastFocusChange = $now
        # Jeśli stara app była chroniona → przedłuż ochronę
        if (-not [string]::IsNullOrWhiteSpace($oldApp)) {
            $this.AltTabProtection[$oldApp] = @{
                ProtectedUntil = $now.AddMinutes(5)  # 5 min ochrona po opuszczeniu
                SwitchedAt = $now
            }
            # Chroń working set starej app
            $this.ProtectWorkingSet($oldApp)
        }
        # AGRESYWNY PRELOAD gdy użytkownik WRACA do heavy app (AltTab powrót)
        # Jeśli nowa app była chroniona AltTab — znaczy powracał z innej apki do tej
        if (-not [string]::IsNullOrWhiteSpace($newApp)) {
            $isReturn = $this.IsAltTabProtected($newApp)
            if ($isReturn) {
                # Natychmiastowy preload do PriorityQueue
                $this.ElevateToPriority($newApp)
                # Re-assert WS dla powracającej app
                $this.ProtectWorkingSet($newApp)
                # Preload known children (VST plugins, service hosts, etc.)
                $this.PreloadChildApps($newApp)
                Write-RCLog "ALTTAB RETURN '$newApp': elevated to PriorityQ + WS re-asserted + children preloaded"
            }
        }
        # Czyść wygasłe ochrony
        foreach ($app in @($this.AltTabProtection.Keys)) {
            if ($this.AltTabProtection[$app].ProtectedUntil -lt $now) {
                $this.AltTabProtection.Remove($app)
            }
        }
    }
    
    [bool] IsAltTabProtected([string]$appName) {
        if (-not $this.AltTabProtection.ContainsKey($appName)) { return $false }
        return ($this.AltTabProtection[$appName].ProtectedUntil -gt [datetime]::Now)
    }

    # ═══════════════════════════════════════════════════════════════
    # #6 TIME-DECAY: wolniejszy dla Heavy, szybszy dla Light
    # (modyfikacja istniejącej GetDecayedPriority)
    # ═══════════════════════════════════════════════════════════════
    # Already integrated in GetDecayedPriority — uses ClassifyApp to set halfLife

    # ═══════════════════════════════════════════════════════════════
    # #7 NEGATIVE LEARNING — kara za złe przewidywania
    # ═══════════════════════════════════════════════════════════════
    [void] RecordPreloadAttempt([string]$appName) {
        if (-not $this.NegativeScores.ContainsKey($appName)) {
            $this.NegativeScores[$appName] = @{ PreloadCount = 0; HitCount = 0; PenaltyUntil = [datetime]::MinValue }
        }
        $this.NegativeScores[$appName].PreloadCount++
    }
    
    [void] RecordPreloadHit([string]$appName) {
        if ($this.NegativeScores.ContainsKey($appName)) {
            $this.NegativeScores[$appName].HitCount++
        }
    }
    
    [bool] IsNegativePenalty([string]$appName) {
        if (-not $this.NegativeScores.ContainsKey($appName)) { return $false }
        $ns = $this.NegativeScores[$appName]
        # Penalty aktywna?
        if ($ns.PenaltyUntil -gt [datetime]::Now) { return $true }
        # Sprawdź historię: >5 preloadów i <20% hitRate → nakładaj penalty
        if ($ns.PreloadCount -ge 5) {
            $hitRate = $ns.HitCount / $ns.PreloadCount
            if ($hitRate -lt 0.2) {
                $ns.PenaltyUntil = [datetime]::Now.AddMinutes(10)  # 10 min penalty
                return $true
            }
        }
        return $false
    }

    # ═══════════════════════════════════════════════════════════════
    # #8 SESSION-AWARE — wykryj typ sesji
    # ═══════════════════════════════════════════════════════════════
    [void] DetectSession([string]$context, [double]$gpuLoad) {
        if ($context -eq "Gaming" -or $gpuLoad -gt 70) {
            $this.CurrentSession = "Gaming"
        } elseif ($context -eq "Coding" -or $context -eq "Office") {
            $this.CurrentSession = "Work"
        } elseif ($context -eq "Browsing" -or $context -eq "Media") {
            $this.CurrentSession = "Browsing"
        } else {
            $this.CurrentSession = "Mixed"
        }
    }

    # ═══════════════════════════════════════════════════════════════
    # #9 PAGE FAULT ALARM — reaguj na nagły wzrost page faults
    # ═══════════════════════════════════════════════════════════════
    [void] PageFaultResponse([string]$heavyApp, [hashtable]$prophetApps, [hashtable]$transitions) {
        if ($this.LastPageFaultsPerSec -lt 200) { return }  # Normalny poziom
        # Alarm: page faults > 200/s → system pod presją
        # 1. Zatrzymaj batch preload
        # (BatchTick sam sprawdza pressure, ale tu wymuszamy)
        # 2. Boost priority heavy app
        if (-not [string]::IsNullOrWhiteSpace($heavyApp)) {
            try {
                $proc = Get-Process -Name $heavyApp -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($proc) { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
            } catch {}
        }
        # 3. Agresywna eviction light apps
        $this.EnforceGuardBand($prophetApps, $transitions)
    }

    # ═══════════════════════════════════════════════════════════════
    # #10 MEMORY COST EFFICIENCY — priorytet = zysk / koszt_RAM
    # ═══════════════════════════════════════════════════════════════
    [double] GetCostEfficiency([string]$appName, [hashtable]$prophetApps) {
        $sizeMB = 1.0  # Default
        if ($this.CachedApps.ContainsKey($appName)) {
            $sizeMB = [Math]::Max(1, $this.CachedApps[$appName].SizeMB)
        }
        # Zysk = estimated startup time saved (based on avgCPU + IsHeavy)
        $benefit = 10.0  # Default benefit
        if ($prophetApps -and $prophetApps.ContainsKey($appName)) {
            $app = $prophetApps[$appName]
            if ($app.IsHeavy) { $benefit += 30 }
            if ($app.AvgCPU -gt 50) { $benefit += 20 }
            elseif ($app.AvgCPU -gt 30) { $benefit += 10 }
            if ($app.Samples -gt 50) { $benefit += 5 }  # Dobrze znana app
        }
        return $benefit / $sizeMB  # Wyższy = lepszy stosunek zysk/koszt
    }

    # ═══════════════════════════════════════════════════════════════
    # Status / Cleanup
    # ═══════════════════════════════════════════════════════════════
    [string] GetStatus() {
        $hitRate = 0
        $total = $this.TotalHits + $this.TotalMisses
        if ($total -gt 0) { $hitRate = [Math]::Round($this.TotalHits / $total * 100, 0) }
        $mode = if ($this.HeavyMode) { "HEAVY:$($this.HeavyModeApp)" } else { $this.CurrentSession }
        return "RAMCache:$([int]$this.TotalCachedMB)/$($this.MaxCacheMB)MB Apps:$($this.CachedApps.Count) Hit:$hitRate% Aggr:$([Math]::Round($this.Aggressiveness,1)) Ret:$([Math]::Round($this.RetentionTolerance,1)) Free:$([int]$this.LastAvailableMB)MB [$mode]"
    }
    
    [void] Cleanup() {
        $count = $this.CachedApps.Count
        foreach ($appName in @($this.CachedApps.Keys)) {
            $entry = $this.CachedApps[$appName]
            foreach ($f in $entry.Files) {
                try { 
                    if ($f.ContainsKey('Accessor') -and $f.Accessor) { $f.Accessor.Dispose() }
                    if ($f.ContainsKey('MMF') -and $f.MMF) { $f.MMF.Dispose() }
                    if ($f.ContainsKey('Stream') -and $f.Stream) { $f.Stream.Dispose() }
                    if ($f.ContainsKey('Data')) { $f.Data = $null }
                } catch {}
            }
        }
        $this.CachedApps.Clear()
        $this.TotalCachedMB = 0
        while ($this.BatchQueue.Count -gt 0) { $this.BatchQueue.Dequeue() | Out-Null }
        Write-RCLog "CLEANUP: Released $count cached apps (ENGINE shutdown)"
    }
    
    # ═══════════════════════════════════════════════════════════════
    # PERSISTENCE: SaveState / LoadState — zapamiętuj wiedzę między restarty
    # Zapisuje: AppClassification, NegativeScores, AppPaths + LearnedFiles per app
    # ═══════════════════════════════════════════════════════════════
    
    # ═══════════════════════════════════════════════════════════════
    # HELPER: sprawdź czy ścieżka exe to śmieć (temp instalator, VS Code extension, itp.)
    # ═══════════════════════════════════════════════════════════════
    hidden [bool] IsJunkExePath([string]$exePath) {
        if ([string]::IsNullOrWhiteSpace($exePath)) { return $false }
        return ($exePath -match '\\(Temp|TEMP|tmp)\\' -or
                $exePath -match '\.tmp$' -or
                $exePath -match '\\is-[A-Z0-9]+\.tmp\\' -or
                $exePath -match '\\\.vscode\\extensions\\')
    }

    # ═══════════════════════════════════════════════════════════════
    # PROFILE APP MODULES — skanuj RZECZYWISTE moduły załadowane przez proces
    # Wywoływane gdy app jest running → zapamiętuje dokładne pliki
    # ═══════════════════════════════════════════════════════════════
    [void] ProfileAppModules([string]$appName) {
        if ([string]::IsNullOrWhiteSpace($appName)) { return }
        try {
            $proc = Get-Process -Name $appName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $proc) { return }
            
            # Pobierz RZECZYWISTE załadowane moduły procesu
            $maxModules = 100  # default
            if ($this.HW -and $this.HW.CacheStrategy) { $maxModules = $this.HW.CacheStrategy.MaxModules }
            else {
                $totalGB3 = $this.TotalSystemRAM / 1024.0
                $maxModules = if ($totalGB3 -ge 32) { 150 } elseif ($totalGB3 -ge 16) { 100 } else { 30 }
            }
            $modules = $proc.Modules | Where-Object { 
                $_.FileName -and (Test-Path $_.FileName -ErrorAction SilentlyContinue)
            } | Select-Object -First $maxModules
            
            # CHILD PROCESS SCAN v2: wykryj procesy potomne DOWOLNEJ aplikacji
            # Batch WMI query zamiast per-process (10x szybszy)
            $childModules = [System.Collections.Generic.List[object]]::new()
            $childProcNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            $childProcInfos = [System.Collections.Generic.List[hashtable]]::new()  # v47.4: ExePath + Dir per child
            try {
                # Jedno zapytanie WMI — pobierz WSZYSTKIE procesy z ParentProcessId == nasz PID
                $parentPid = $proc.Id
                $wmiChildren = Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentPid" -ErrorAction SilentlyContinue
                $childPidSet = [System.Collections.Generic.HashSet[int]]::new()
                if ($wmiChildren) {
                    foreach ($wc in $wmiChildren) {
                        if ($wc.ProcessId -ne $parentPid) { $childPidSet.Add([int]$wc.ProcessId) | Out-Null }
                    }
                }
                # Dodaj znane plugin host names (nie muszą być dziećmi — mogą być siostrzane)
                $childPluginNames = @('vstbridge','vsthost','jbridge','audiogridder','wine','wineserver',
                    'pluginval','vst3scanner','vstscanner','bridgeserver','clap-bridge','clap-host',
                    'reaper_host','reaper_vst','bitwig-engine','bitwig-bridge','ableton-plugins',
                    'audiopluginhost','pluginhost','fx-chain','sforzando','xlnaudio')
                $allProcs = Get-Process -ErrorAction SilentlyContinue
                foreach ($cp in $allProcs) {
                    $isChild = $childPidSet.Contains($cp.Id)
                    if (-not $isChild) {
                        $cpName = $cp.ProcessName.ToLower()
                        foreach ($ph in $childPluginNames) { if ($cpName -like "*$ph*") { $isChild = $true; break } }
                    }
                    if ($isChild -and $cp.Id -ne $proc.Id) {
                        $childProcNames.Add($cp.ProcessName) | Out-Null
                        # v47.4: Zbierz ExePath/Dir per child (do persystentnego ChildApps)
                        try {
                            $cpPath = $cp.Path
                            if ($cpPath -and -not $this.IsJunkExePath($cpPath)) {
                                $childProcInfos.Add(@{
                                    Name    = $cp.ProcessName
                                    ExePath = $cpPath
                                    Dir     = [System.IO.Path]::GetDirectoryName($cpPath)
                                    PID     = $cp.Id
                                })
                            }
                        } catch {}
                        try {
                            $childMods = $cp.Modules | Where-Object { $_.FileName -and (Test-Path $_.FileName -ErrorAction SilentlyContinue) } | Select-Object -First 80
                            foreach ($cm in $childMods) { $childModules.Add($cm) }
                        } catch {}
                    }
                }
                if ($childModules.Count -gt 0) {
                    Write-RCLog "CHILD MODULES '$appName': found $($childModules.Count) modules from child/plugin processes"
                }
            } catch {}
            
            # Połącz moduły główne + potomne (bez duplikatów ścieżek)
            $allModules = [System.Collections.Generic.List[object]]::new()
            $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($m in $modules) { if ($seenPaths.Add($m.FileName)) { $allModules.Add($m) } }
            foreach ($m in $childModules) { if ($m.FileName -and $seenPaths.Add($m.FileName)) { $allModules.Add($m) } }
            $modules = $allModules
            
            if ($modules.Count -lt 2) { return }
            
            # Zbierz listę plików z rozmiarami
            $learnedFiles = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($mod in $modules) {
                try {
                    $size = (Get-Item $mod.FileName -ErrorAction Stop).Length
                    if ($size -gt 5KB -and $size -lt 200MB) {
                        $learnedFiles.Add(@{
                            Path = $mod.FileName
                            Size = $size
                            Module = $mod.ModuleName
                        })
                    }
                } catch { continue }
            }
            
            if ($learnedFiles.Count -lt 2) { return }

            # Wczesne wykrycie serwisów wtyczek — DAW z vstservice/asioservice/clapservice
            # potrzebuje większego limitu modułów (pluginy użytkownika = dziesiątki dodatkowych DLL)
            $pluginSvcNames = @('vstservice','asioservice','clapservice','araservice','juceaudio')
            $hasPlugSvc = $false
            foreach ($lf in $learnedFiles) {
                $fn = [System.IO.Path]::GetFileNameWithoutExtension($lf.Path).ToLower()
                if ($fn -in $pluginSvcNames) { $hasPlugSvc = $true; break }
            }
            if ($hasPlugSvc) {
                # DAW z plugin serwisem: podnieś limit tak jak HEAVY (+50%, max 250)
                # Inaczej pluginy ładowane po starcie (po 90-120s) zastępują systemowe DLL zamiast dołączyć
                $maxModules = [Math]::Min([int]($maxModules * 1.5), 250)
            }

            # ════════════════════════════════════════════════════════════
            # AI-GUIDED MODULE PRIORITY — Prophet + session context
            # HEAVY/Gaming: game assets > runtime/shader DLLs > inne moduły
            # LIGHT: rozmiar malejący; Turbo preferred → +50% limit modułów
            # ════════════════════════════════════════════════════════════
            $aiPropCategory  = "LEARNING"
            $aiPropPreferred = ""
            if ($this.ProphetAppsRef -and $this.ProphetAppsRef.ContainsKey($appName)) {
                $pd = $this.ProphetAppsRef[$appName]
                $aiPropCategory  = if ($pd.Category)      { [string]$pd.Category }      else { "LEARNING" }
                $aiPropPreferred = if ($pd.PreferredMode) { [string]$pd.PreferredMode } else { "" }
                # Turbo/HEAVY → więcej modułów w cache (+50%)
                if ($aiPropCategory -eq "HEAVY" -or $aiPropPreferred -eq "Turbo") {
                    $maxModules = [Math]::Min([int]($maxModules * 1.5), 250)
                }
            }
            $aiSessionCtx = $this.CurrentSession  # "Gaming"|"Work"|"Browsing"|"Mixed"
            $scoredModules = foreach ($lf in $learnedFiles) {
                $ms = 1.0
                $mext  = [System.IO.Path]::GetExtension($lf.Path).ToLower()
                $mname = [System.IO.Path]::GetFileName($lf.Path).ToLower()
                # Typ pliku: game assets > runtime/shader DLLs > zwykłe DLLs
                if ($mext  -in @('.pak','.pck','.bank','.ushaderbytecode','.shaderbundle','.oodle','.wem')) { $ms += 5.0 }
                elseif ($mname -match 'runtime|core|clr|jit|v8|electron|cef|qt5core|libcef')               { $ms += 3.5 }
                elseif ($mname -match 'd3d|vulkan|opengl|dxgi|nvapi|cuda|opencl|vk')                       { $ms += 3.5 }
                elseif ($mext  -eq '.dll')                                                                  { $ms += 1.0 }
                # Rozmiar: większy = bardziej krytyczny do zawarcia w cache
                $ms += [Math]::Log10([Math]::Max(1, $lf.Size / 1KB)) * 0.4
                # Gaming/Heavy bonus dla dużych plików (>10MB = shader pack / runtime)
                if (($aiPropCategory -eq "HEAVY" -or $aiSessionCtx -eq "Gaming") -and $lf.Size -gt 10MB) { $ms += 2.5 }
                @{ File = $lf; Score = $ms }
            }
            $learnedFiles = [System.Collections.Generic.List[hashtable]]::new()
            foreach ($sm in ($scoredModules | Sort-Object { $_.Score } -Descending | Select-Object -First $maxModules)) {
                $learnedFiles.Add($sm.File)
            }
            if ($aiPropCategory -ne "LEARNING") {
                Write-RCLog "AI SORT '$appName': cat=$aiPropCategory mode=$aiPropPreferred sess=$aiSessionCtx maxMod=$maxModules"
            }

            # v43.15: odrzuć procesy z junk ścieżką (VS Code extension binaries, temp instalatory)
            if ($this.IsJunkExePath($proc.Path)) {
                Write-RCLog "PROFILE SKIP '$appName': junk exePath '$($proc.Path)'"
                return
            }
            
            # Zapisz do AppPaths
            if (-not $this.AppPaths.ContainsKey($appName)) {
                $this.AppPaths[$appName] = @{ ExePath = $proc.Path; Dir = [System.IO.Path]::GetDirectoryName($proc.Path) }
            } else { $this.AppPaths[$appName]['ExePath'] = $proc.Path }

            # MERGE: zachowaj moduły z poprzednich sesji (pluginy, które nie są teraz załadowane)
            # Dzięki temu re-profil rozszerza wiedzę zamiast ją nadpisywać
            $prevLF = if ($this.AppPaths[$appName].ContainsKey('LearnedFiles') -and
                         $this.AppPaths[$appName].LearnedFiles -and
                         $this.AppPaths[$appName].LearnedFiles.Count -gt 0) { $this.AppPaths[$appName].LearnedFiles } else { $null }
            if ($prevLF) {
                $curPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                foreach ($f in $learnedFiles) { $curPaths.Add($f.Path) | Out-Null }
                $mergeCount = 0
                foreach ($elf in $prevLF) {
                    if (-not $curPaths.Contains($elf.Path) -and (Test-Path $elf.Path -ErrorAction SilentlyContinue)) {
                        $learnedFiles.Add($elf); $mergeCount++
                    }
                }
                if ($mergeCount -gt 0) { Write-RCLog "PROFILE MERGE '$appName': +$mergeCount modułów z poprzednich sesji zachowanych" }
            }

            $this.AppPaths[$appName].LearnedFiles = $learnedFiles
            $this.AppPaths[$appName].ProfiledAt = [datetime]::Now
            $this.AppPaths[$appName].ModuleCount = $learnedFiles.Count

            # CHILD PATTERN TRACKING — które child procs pojawiły się Z tą app w tej sesji
            # Np. Reaper+vstbridge w Gaming → przy następnym Gaming preloaduj vstbridge automatycznie
            if ($childProcNames -and $childProcNames.Count -gt 0) {
                $cpSession = $this.CurrentSession
                if (-not $this.AppPaths[$appName].ContainsKey('ChildPatterns')) {
                    $this.AppPaths[$appName].ChildPatterns = @{}
                }
                if (-not $this.AppPaths[$appName].ChildPatterns.ContainsKey($cpSession)) {
                    $this.AppPaths[$appName].ChildPatterns[$cpSession] = @{}
                }
                foreach ($cpN in $childProcNames) {
                    if (-not $this.AppPaths[$appName].ChildPatterns[$cpSession].ContainsKey($cpN)) {
                        $this.AppPaths[$appName].ChildPatterns[$cpSession][$cpN] = 0
                    }
                    $this.AppPaths[$appName].ChildPatterns[$cpSession][$cpN]++
                }
                Write-RCLog "CHILD PATTERN '$appName' [$cpSession]: $($childProcNames.Count) child procs śledzonych"

                # v47.4: CHILD APPS PERSIST — zapisz ExePath/Dir/LearnedFiles dla każdego dziecka
                # Dzięki temu przy WARMUP/MISS parent → automatycznie preloaduj znane dzieci
                if ($childProcInfos.Count -gt 0) {
                    if (-not $this.ChildApps.ContainsKey($appName)) { $this.ChildApps[$appName] = @{} }
                    foreach ($cpi in $childProcInfos) {
                        $cn = $cpi.Name
                        if (-not $this.ChildApps[$appName].ContainsKey($cn)) {
                            $this.ChildApps[$appName][$cn] = @{
                                ExePath = $cpi.ExePath; Dir = $cpi.Dir; LastSeen = [datetime]::Now
                                LearnedFiles = [System.Collections.Generic.List[hashtable]]::new()
                            }
                        } else {
                            $this.ChildApps[$appName][$cn].ExePath = $cpi.ExePath
                            $this.ChildApps[$appName][$cn].LastSeen = [datetime]::Now
                        }
                        # Zbierz moduły tego dziecka z już zebranych childModules
                        $cpid = $cpi.PID
                        try {
                            $childProc = Get-Process -Id $cpid -ErrorAction SilentlyContinue
                            if ($childProc) {
                                $cMods = $childProc.Modules | Where-Object { $_.FileName -and (Test-Path $_.FileName -EA SilentlyContinue) } | Select-Object -First 80
                                $clf = [System.Collections.Generic.List[hashtable]]::new()
                                foreach ($cm in $cMods) {
                                    try {
                                        $csz = (Get-Item $cm.FileName -EA Stop).Length
                                        if ($csz -gt 5KB -and $csz -lt 200MB) {
                                            $clf.Add(@{ Path = $cm.FileName; Size = $csz; Module = $cm.ModuleName })
                                        }
                                    } catch { continue }
                                }
                                if ($clf.Count -gt 2) {
                                    $this.ChildApps[$appName][$cn].LearnedFiles = $clf
                                }
                            }
                        } catch {}
                        # Ucz też AppPaths dla child (ułatwia standalone cache/preload)
                        if (-not $this.AppPaths.ContainsKey($cn) -and $cpi.ExePath) {
                            $this.AppPaths[$cn] = @{ ExePath = $cpi.ExePath; Dir = $cpi.Dir }
                        }
                    }
                    $childNames = @($childProcInfos | ForEach-Object { $_.Name }) -join ','
                    Write-RCLog "CHILD APPS '$appName': learned $($childProcInfos.Count) children [$childNames]"
                }
            }

            # Log success
            $totalSizeMB = 0; foreach ($f in $learnedFiles) { $totalSizeMB += $f.Size }
            $totalSizeMB = [Math]::Round($totalSizeMB / 1MB, 1)
            Write-RCLog "PROFILED '$appName': $($learnedFiles.Count) modułów ($($totalSizeMB)MB) cat=$aiPropCategory sess=$aiSessionCtx"
            $this.IsDirty = $true
            
            # DEEP PROFILE: skanuj katalog app dla asset files (shaders, pak, textures)
            # Zapamiętaj pełny profil — przy ponownym uruchomieniu załaduj WSZYSTKO
            try {
                $appDir = [System.IO.Path]::GetDirectoryName($proc.Path)
                # Game root detection: UE4/UE5 exe w Binaries/Win64
                $scanRoot = $appDir
                $testDir2 = $appDir
                for ($up2 = 0; $up2 -lt 4; $up2++) {
                    $parent2 = [System.IO.Path]::GetDirectoryName($testDir2)
                    if (-not $parent2 -or $parent2 -eq $testDir2) { break }
                    if ((Test-Path (Join-Path $parent2 "Content") -ErrorAction SilentlyContinue) -or
                        (Test-Path (Join-Path $parent2 "Engine") -ErrorAction SilentlyContinue) -or
                        (Get-ChildItem $parent2 -Filter "*.pak" -ErrorAction SilentlyContinue | Select-Object -First 1)) {
                        $scanRoot = $parent2
                        break
                    }
                    $testDir2 = $parent2
                }
                $assetExts = "*.pak","*.pck","*.bank","*.wem","*.ushaderbytecode","*.shaderbundle","*.upk","*.uasset","*.umap","*.cache","*.dat","*.bin","*.oodle"
                # Dynamiczny limit rozmiaru pliku — spójny z PreloadApp i BatchTick
                # 32GB RAM→MaxCache~16GB→maxFile=2GB | 16GB→1GB | 8GB→512MB
                $profileMaxAssetBytes = [Math]::Max(512MB, [long]($this.MaxCacheMB / 8) * 1MB)
                $assetFiles = Get-ChildItem -Path $scanRoot -Include $assetExts -Recurse -Depth 5 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 100KB -and $_.Length -lt $profileMaxAssetBytes } |
                    Sort-Object Length -Descending | Select-Object -First 40
                
                $assetCount = 0
                $assetSizeMB = 0
                foreach ($asset in $assetFiles) {
                    $already = $false
                    foreach ($lf in $learnedFiles) { if ($lf.Path -eq $asset.FullName) { $already = $true; break } }
                    if ($already) { continue }
                    $learnedFiles.Add(@{ Path = $asset.FullName; Size = $asset.Length; Module = "asset:$($asset.Name)" })
                    $assetCount++
                    $assetSizeMB += $asset.Length
                }
                if ($assetCount -gt 0) {
                    $this.AppPaths[$appName].LearnedFiles = $learnedFiles
                    $this.AppPaths[$appName].ModuleCount = $learnedFiles.Count
                    Write-RCLog "DEEP PROFILE '$appName': +$assetCount assets ($([Math]::Round($assetSizeMB/1MB,1))MB), total=$($learnedFiles.Count) files"
                }
            } catch {}
            
            # VST3 DIRECTORY SCAN: jeśli app ma vstservice/clapservice, przeskanuj standardowy
            # katalog VST3 pod kątem OSTATNIO UŻYWANYCH plików .vst3 — łapie pluginy in-process
            if ($hasPlugSvc) {
                try {
                    $vst3Dir = "C:\Program Files\Common Files\VST3"
                    if (Test-Path $vst3Dir) {
                        $recentThreshold = [datetime]::Now.AddMinutes(-10)
                        $vst3Files = Get-ChildItem $vst3Dir -Filter '*.vst3' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                            Where-Object { $_.Length -gt 100KB -and $_.Length -lt 200MB -and $_.LastAccessTime -gt $recentThreshold }
                        $vst3Added = 0
                        $curPaths2 = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
                        foreach ($f in $learnedFiles) { $curPaths2.Add($f.Path) | Out-Null }
                        foreach ($vf in $vst3Files) {
                            if (-not $curPaths2.Contains($vf.FullName)) {
                                $learnedFiles.Add(@{ Path = $vf.FullName; Size = $vf.Length; Module = $vf.Name })
                                $curPaths2.Add($vf.FullName) | Out-Null
                                $vst3Added++
                            }
                        }
                        if ($vst3Added -gt 0) {
                            Write-RCLog "VST3 SCAN '$appName': +$vst3Added pluginów z $vst3Dir (recently accessed)"
                        }
                    }
                } catch {}
            }

            # LATE PROFILE: jeśli app ma serwis pluginów (VST/CLAP/ASIO/ARA), zaplanuj
            # ponowny skan za 120s — wtedy pluginy załadowane przez użytkownika są już w pamięci.
            # $hasPlugSvc obliczone wcześniej (przed AI SORT) — nie deklarujemy ponownie.
            if ($hasPlugSvc) {
                # Sprawdź czy late profile był już wykonany w ciągu ostatnich 5 minut
                # (zapobiega nieskończonej pętli: każdy profil widzi vstservice → kolejkuje → odpala → itd.)
                $recentlyQueued = $false
                foreach ($pq in $this.PendingProfileQueue) {
                    if ($pq.AppName -eq $appName -and $pq.ContainsKey('IsLate')) { $recentlyQueued = $true; break }
                }
                if (-not $recentlyQueued) {
                    $lastLate = if ($this.AppPaths[$appName].ContainsKey('LateProfileAt')) { $this.AppPaths[$appName]['LateProfileAt'] } else { [datetime]::MinValue }
                    $cooldownOk = ([datetime]::Now - $lastLate).TotalMinutes -gt 5
                    if ($cooldownOk) {
                        $this.AppPaths[$appName]['LateProfileAt'] = [datetime]::Now
                        $detectedSvc = ($pluginSvcNames | Where-Object { $sn = $_; $learnedFiles | Where-Object { [System.IO.Path]::GetFileNameWithoutExtension($_.Path).ToLower() -eq $sn } } | Select-Object -First 1)
                        $this.PendingProfileQueue.Add(@{
                            AppName      = $appName
                            ProfileAfter = [datetime]::Now.AddSeconds(120)
                            IsLate       = $true
                        })
                        Write-RCLog "LATE PROFILE QUEUED '$appName': re-scan za 120s (plugin service: $detectedSvc, maxMod=$maxModules) — zaladuj wtyczki teraz"
                    }
                }
            }

            # Zapisz manifest na dysk od razu po profilowaniu (nie czekaj na LoadComplete)
            $this.SaveAppToDiskCache($appName)
        } catch {}
    }
    
    [void] SaveState([string]$configDir) {
        try {
            $path = Join-Path $configDir "RAMCache.json"
            
            # WALIDACJA: nie zapisuj pustych danych (chroni przed utratą przy crash/restart)
            if ($this.AppPaths.Count -eq 0 -and $this.AppClassification.Count -eq 0) {
                Write-RCLog "SAVE SKIP: empty state (Paths=0 Class=0) — protecting existing data"
                return
            }
            
            # MERGE PROTECTION: wczytaj istniejący plik i zachowaj/wzbogać dane
            # (Bootstrap skanuje tylko RUNNING apps — zamknięte giną bez tego)
            # Próbuje main → .bak (fallback jeśli main uszkodzony)
            $existingData = $null
            foreach ($mergeCandidate in @($path, "$path.bak")) {
                if (-not (Test-Path $mergeCandidate)) { continue }
                try {
                    $existingJson = [System.IO.File]::ReadAllText($mergeCandidate, [System.Text.Encoding]::UTF8)
                    if ($existingJson.Length -lt 10) { continue }
                    $existingData = $existingJson | ConvertFrom-Json
                    if ($existingData.AppPaths) { break }  # Valid data found
                    $existingData = $null
                } catch { $existingData = $null; continue }
            }
            if ($existingData -and $existingData.AppPaths) {
                $merged = 0
                $enriched = 0
                $existingData.AppPaths.PSObject.Properties | ForEach-Object {
                    $appName = $_.Name
                    $v = $_.Value
                    if (-not $this.AppPaths.ContainsKey($appName)) {
                        # Przywróć zamkniętą app z dysku (nie ma w pamięci)
                        $entry = @{ ExePath = $v.ExePath; Dir = $v.Dir }
                        if ($v.LF -and $v.LF.Count -gt 0) {
                            $lf = [System.Collections.Generic.List[hashtable]]::new()
                            foreach ($f in $v.LF) {
                                $lf.Add(@{ Path = $f.P; Size = [long]$f.S; Module = $f.M })
                            }
                            $entry.LearnedFiles = $lf
                            if ($v.PA) { $entry.ProfiledAt = try { [datetime]::Parse($v.PA, [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::Now } }
                            $entry.ModuleCount = $lf.Count
                        }
                        # Przywróć wzorce child procs per sesja
                        if ($v.CP) {
                            $cpMap = @{}
                            $v.CP.PSObject.Properties | ForEach-Object {
                                $sess = $_.Name; $cpMap[$sess] = @{}
                                $_.Value.PSObject.Properties | ForEach-Object { $cpMap[$sess][$_.Name] = [int]$_.Value }
                            }
                            $entry.ChildPatterns = $cpMap
                        }
                        $this.AppPaths[$appName] = $entry
                        $merged++
                    } else {
                        # ENRICH: app istnieje w pamięci, ale dysk może mieć bogatsze LearnedFiles
                        $memEntry = $this.AppPaths[$appName]
                        $memLF = if ($memEntry.ContainsKey('LearnedFiles') -and $memEntry.LearnedFiles) { $memEntry.LearnedFiles.Count } else { 0 }
                        $diskLF = if ($v.LF) { $v.LF.Count } else { 0 }
                        if ($diskLF -gt $memLF -and $diskLF -ge 3) {
                            # Dysk ma bogatsze dane — przywróć LearnedFiles z dysku
                            $lf = [System.Collections.Generic.List[hashtable]]::new()
                            foreach ($f in $v.LF) {
                                $lf.Add(@{ Path = $f.P; Size = [long]$f.S; Module = $f.M })
                            }
                            $this.AppPaths[$appName].LearnedFiles = $lf
                            if ($v.PA) { $this.AppPaths[$appName].ProfiledAt = try { [datetime]::Parse($v.PA, [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::Now } }
                            $this.AppPaths[$appName].ModuleCount = $lf.Count
                            $enriched++
                        }
                        # Przywróć ChildPatterns jeśli pamięć ich nie ma
                        if ($v.CP -and -not $this.AppPaths[$appName].ContainsKey('ChildPatterns')) {
                            $cpMap = @{}
                            $v.CP.PSObject.Properties | ForEach-Object {
                                $sess = $_.Name; $cpMap[$sess] = @{}
                                $_.Value.PSObject.Properties | ForEach-Object { $cpMap[$sess][$_.Name] = [int]$_.Value }
                            }
                            $this.AppPaths[$appName].ChildPatterns = $cpMap
                        }
                    }
                }
                # Merge NameMap
                if ($existingData.NameMap) {
                    $existingData.NameMap.PSObject.Properties | ForEach-Object {
                        if (-not $this.NameMap.ContainsKey($_.Name)) {
                            $this.NameMap[$_.Name] = [string]$_.Value
                            $merged++
                        }
                    }
                }
                # Merge AppClassification
                if ($existingData.AppClassification) {
                    $existingData.AppClassification.PSObject.Properties | ForEach-Object {
                        if (-not $this.AppClassification.ContainsKey($_.Name)) {
                            $this.AppClassification[$_.Name] = $_.Value
                            $merged++
                        }
                    }
                }
                # Merge NegativeScores
                if ($existingData.NegativeScores) {
                    $existingData.NegativeScores.PSObject.Properties | ForEach-Object {
                        if (-not $this.NegativeScores.ContainsKey($_.Name)) {
                            $ns = $_.Value
                            $this.NegativeScores[$_.Name] = @{
                                PreloadCount = [int]$ns.PreloadCount
                                HitCount = [int]$ns.HitCount
                                PenaltyUntil = try { [datetime]::Parse($ns.PenaltyUntil, [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::MinValue }
                            }
                            $merged++
                        }
                    }
                }
                # Merge cumulative stats (keep higher)
                if ($existingData.TotalHits -and [int]$existingData.TotalHits -gt $this.TotalHits) { $this.TotalHits = [int]$existingData.TotalHits }
                if ($existingData.TotalMisses -and [int]$existingData.TotalMisses -gt $this.TotalMisses) { $this.TotalMisses = [int]$existingData.TotalMisses }
                if ($existingData.TotalPreloads -and [int]$existingData.TotalPreloads -gt $this.TotalPreloads) { $this.TotalPreloads = [int]$existingData.TotalPreloads }
                # Merge ChildApps
                if ($existingData.ChildApps) {
                    $existingData.ChildApps.PSObject.Properties | ForEach-Object {
                        $parentName = $_.Name
                        if (-not $this.ChildApps.ContainsKey($parentName)) {
                            $this.ChildApps[$parentName] = @{}
                            $_.Value.PSObject.Properties | ForEach-Object {
                                $cn = $_.Name; $cv = $_.Value
                                $parsedLastSeen = [datetime]::Now
                                try { $parsedLastSeen = [datetime]::Parse($cv.LastSeen, [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
                                $childEntry = @{
                                    ExePath = $cv.ExePath; Dir = $cv.Dir
                                    LastSeen = $parsedLastSeen
                                    LearnedFiles = [System.Collections.Generic.List[hashtable]]::new()
                                }
                                if ($cv.LF -and $cv.LF.Count -gt 0) {
                                    foreach ($f in $cv.LF) { $childEntry.LearnedFiles.Add(@{ Path = $f.P; Size = [long]$f.S; Module = $f.M }) }
                                }
                                $this.ChildApps[$parentName][$cn] = $childEntry
                            }
                            $merged++
                        }
                    }
                }
                if ($merged -gt 0 -or $enriched -gt 0) { Write-RCLog "MERGE: Restored $merged entries, enriched $enriched apps from disk" }
            }
            
            # CLEANUP: usuń entries z pustym ExePath (np. system processes bez ścieżki)
            $toRemove = @($this.AppPaths.Keys | Where-Object { -not $this.AppPaths[$_].ExePath })
            foreach ($key in $toRemove) { $this.AppPaths.Remove($key) }
            
            # v43.15 CLEANUP: wyczyść stale/junk ExePath (plik nie istnieje lub ścieżka to śmieć)
            # Zostawiamy LearnedFiles — zostaną odkryte na nowo przy następnym uruchomieniu app
            $stalePaths = @($this.AppPaths.Keys | Where-Object {
                $ep = $this.AppPaths[$_].ExePath
                if ([string]::IsNullOrWhiteSpace($ep)) { return $false }
                # Junk: temp pliki (.tmp exe, instalatory Inno Setup, itp.)
                $isJunk = ($ep -match '\\(Temp|TEMP|tmp)\\' -or
                           $ep -match '\.tmp$' -or
                           $ep -match '\\is-[A-Z0-9]+\.tmp\\' -or
                           $ep -match '\\\.vscode\\extensions\\')
                if ($isJunk) { return $true }
                # Stale: ścieżka zapisana ale plik już nie istnieje
                return (-not (Test-Path $ep -ErrorAction SilentlyContinue))
            })
            foreach ($key in $stalePaths) {
                # Zachowaj LearnedFiles / statystyki, tylko wyczyść nieważną ścieżkę
                if ($this.AppPaths[$key].LearnedFiles -and $this.AppPaths[$key].LearnedFiles.Count -gt 0) {
                    $this.AppPaths[$key].ExePath = ""   # tryb "no-path" — Get-Process znajdzie nową ścieżkę
                    $this.AppPaths[$key].Dir = ""
                    Write-RCLog "STALE PATH cleared '$key': '$($this.AppPaths[$key].ExePath)' (LearnedFiles retained)"
                } else {
                    $this.AppPaths.Remove($key)
                    Write-RCLog "STALE PATH removed '$key' (no LearnedFiles)"
                }
            }
            
            # NegativeScores (safe serialization)
            $negScores = @{}
            foreach ($app in @($this.NegativeScores.Keys)) {
                try {
                    $ns = $this.NegativeScores[$app]
                    if ($ns -and $ns.PenaltyUntil) {
                        $negScores[$app] = @{
                            PreloadCount = [int]$ns.PreloadCount
                            HitCount = [int]$ns.HitCount
                            PenaltyUntil = ([datetime]$ns.PenaltyUntil).ToString("o")
                        }
                    }
                } catch { continue }
            }
            
            # AppPaths z LearnedFiles (safe serialization)
            $paths = @{}
            foreach ($app in @($this.AppPaths.Keys)) {
                try {
                    $entry = $this.AppPaths[$app]
                    if (-not $entry -or -not $entry.ExePath) { continue }
                    $pathEntry = @{ 
                        ExePath = [string]$entry.ExePath
                        Dir = [string]$entry.Dir 
                    }
                    # Learned files — serializuj bezpiecznie
                    if ($entry.ContainsKey('LearnedFiles') -and $entry.LearnedFiles -and $entry.LearnedFiles.Count -gt 0) {
                        $files = [System.Collections.Generic.List[hashtable]]::new()
                        $count = 0
                        foreach ($f in $entry.LearnedFiles) {
                            if ($count -ge $(if ($this.HW -and $this.HW.CacheStrategy) { $this.HW.CacheStrategy.MaxSavedFiles } else { 40 })) { break }
                            if ($f -and $f.Path) {
                                $files.Add(@{ P = [string]$f.Path; S = [long]$f.Size; M = [string]$f.Module })
                                $count++
                            }
                        }
                        if ($files.Count -gt 0) {
                            $pathEntry.LF = @($files)  # Force array
                        }
                        if ($entry.ContainsKey('ProfiledAt') -and $entry.ProfiledAt) {
                            $pathEntry.PA = ([datetime]$entry.ProfiledAt).ToString("o")
                        }
                    }
                    # Zapisz ChildPatterns — które child procs pojawiają się per sesja
                    if ($entry.ContainsKey('ChildPatterns') -and $entry.ChildPatterns -and $entry.ChildPatterns.Count -gt 0) {
                        $pathEntry.CP = $entry.ChildPatterns
                    }
                    $paths[$app] = $pathEntry
                } catch { continue }
            }
            
            # ChildApps (safe serialization) — parent→children mapping
            $childAppsData = @{}
            foreach ($parent in @($this.ChildApps.Keys)) {
                try {
                    $children = $this.ChildApps[$parent]
                    if (-not $children -or $children.Count -eq 0) { continue }
                    $childMap = @{}
                    foreach ($cn in @($children.Keys)) {
                        $ci = $children[$cn]
                        $childEntry = @{
                            ExePath = [string]$ci.ExePath
                            Dir = [string]$ci.Dir
                            LastSeen = ([datetime]$ci.LastSeen).ToString("o")
                        }
                        if ($ci.LearnedFiles -and $ci.LearnedFiles.Count -gt 0) {
                            $clf = [System.Collections.Generic.List[hashtable]]::new()
                            $cc = 0
                            foreach ($f in $ci.LearnedFiles) {
                                if ($cc -ge 60) { break }
                                if ($f -and $f.Path) {
                                    $clf.Add(@{ P = [string]$f.Path; S = [long]$f.Size; M = [string]$f.Module })
                                    $cc++
                                }
                            }
                            if ($clf.Count -gt 0) { $childEntry.LF = @($clf) }
                        }
                        $childMap[$cn] = $childEntry
                    }
                    if ($childMap.Count -gt 0) { $childAppsData[$parent] = $childMap }
                } catch { continue }
            }
            
            $data = @{
                V = 2
                AppClassification = $this.AppClassification
                NegativeScores = $negScores
                AppPaths = $paths
                NameMap = $this.NameMap
                AppStartupMs = $this.AppStartupMs
                ChildApps = $childAppsData
                Aggressiveness = [Math]::Round($this.Aggressiveness, 3)
                MaxCacheMB = [int]$this.MaxCacheMB
                TotalSystemRAM = [int]$this.TotalSystemRAM
                GuardBandMB = [int]$this.GuardBandMB
                GuardBandHeavyMB = [int]$this.GuardBandHeavyMB
                TotalHits = [int]$this.TotalHits
                TotalMisses = [int]$this.TotalMisses
                TotalPreloads = [int]$this.TotalPreloads
                TotalWastedPreloads = [int]$this.TotalWastedPreloads
                SavedAt = [datetime]::Now.ToString("o")
            }
            $json = $data | ConvertTo-Json -Depth 8 -Compress
            # ATOMIC WRITE: zapisz do .tmp, potem rename → plik nigdy nie jest uszkodzony
            $tmpPath = "$path.tmp"
            [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
            # Walidacja: sprawdź czy .tmp jest poprawny JSON
            $testRead = [System.IO.File]::ReadAllText($tmpPath, [System.Text.Encoding]::UTF8)
            $null = $testRead | ConvertFrom-Json  # throws if invalid
            # OK — safe overwrite: .bak ← current, main ← .tmp
            if (Test-Path $path) {
                try { Copy-Item $path "$path.bak" -Force -ErrorAction Stop } catch {}
            }
            Copy-Item $tmpPath $path -Force
            Remove-Item $tmpPath -Force -ErrorAction SilentlyContinue
            Write-RCLog "SAVED: $path ($([Math]::Round($json.Length/1KB,1))KB) Paths=$($paths.Count) Hits=$($this.TotalHits) Miss=$($this.TotalMisses) Aggr=$([Math]::Round($this.Aggressiveness,2))"
            
            # Batch save manifestów dla WSZYSTKICH znanych apps
            if ($this.DiskCacheDir) {
                $manifestCount = 0
                foreach ($app in @($this.AppPaths.Keys)) {
                    $manifestPath = Join-Path $this.DiskCacheDir "$app.json"
                    if (-not (Test-Path $manifestPath)) {
                        $this.SaveAppToDiskCache($app)
                        $manifestCount++
                    }
                }
                if ($manifestCount -gt 0) {
                    Write-RCLog "MANIFESTS: $manifestCount new manifests saved to $($this.DiskCacheDir)"
                }
            }
        } catch {
            Write-RCLog "SAVE ERROR: $($_.Exception.Message)"
        }
    }
    
    [void] LoadState([string]$configDir) {
        try {
            $path = Join-Path $configDir "RAMCache.json"
            $data = $null
            $loadedFrom = ""
            
            # Try main file → .bak → .tmp (in order of freshness)
            foreach ($candidate in @($path, "$path.bak", "$path.tmp")) {
                if (-not (Test-Path $candidate)) { continue }
                try {
                    $json = [System.IO.File]::ReadAllText($candidate, [System.Text.Encoding]::UTF8)
                    if (-not $json -or $json.Length -lt 10) { continue }
                    $parsed = $json | ConvertFrom-Json
                    # Walidacja: sprawdź czy ma AppPaths
                    $pathCount = 0
                    if ($parsed.AppPaths) { $parsed.AppPaths.PSObject.Properties | ForEach-Object { $pathCount++ } }
                    if ($pathCount -gt 0) {
                        $data = $parsed
                        $loadedFrom = $candidate
                        break
                    }
                } catch {
                    Write-RCLog "LOAD: Failed to parse $candidate — $($_.Exception.Message)"
                    continue
                }
            }
            
            if (-not $data) {
                Write-RCLog "LOAD: No valid RAMCache.json found (tried main, .bak, .tmp)"
                return
            }
            if ($loadedFrom -ne $path) {
                Write-RCLog "LOAD: Main file invalid, restored from $loadedFrom"
            }
            
            if ($data.AppClassification) {
                $data.AppClassification.PSObject.Properties | ForEach-Object {
                    $this.AppClassification[$_.Name] = $_.Value
                }
            }
            if ($data.NegativeScores) {
                $data.NegativeScores.PSObject.Properties | ForEach-Object {
                    $ns = $_.Value
                    $this.NegativeScores[$_.Name] = @{
                        PreloadCount = [int]$ns.PreloadCount
                        HitCount = [int]$ns.HitCount
                        PenaltyUntil = try { [datetime]::Parse($ns.PenaltyUntil, [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::MinValue }
                    }
                }
            }
            # Restore AppPaths Z LearnedFiles
            if ($data.AppPaths) {
                $data.AppPaths.PSObject.Properties | ForEach-Object {
                    $v = $_.Value
                    $entry = @{ ExePath = $v.ExePath; Dir = $v.Dir }
                    # Restore learned files
                    if ($v.LF -and $v.LF.Count -gt 0) {
                        $lf = [System.Collections.Generic.List[hashtable]]::new()
                        foreach ($f in $v.LF) {
                            $lf.Add(@{ Path = $f.P; Size = [long]$f.S; Module = $f.M })
                        }
                        $entry.LearnedFiles = $lf
                        if ($v.PA) { $entry.ProfiledAt = try { [datetime]::Parse($v.PA, [System.Globalization.CultureInfo]::InvariantCulture) } catch { [datetime]::Now } }
                        $entry.ModuleCount = $lf.Count
                    }
                    $this.AppPaths[$_.Name] = $entry
                }
            }
            if ($data.Aggressiveness) { $this.Aggressiveness = [Math]::Max($this.AggressivenessMin, [Math]::Min($this.AggressivenessMax, [double]$data.Aggressiveness)) }
            # Restore NameMap
            if ($data.NameMap) {
                $data.NameMap.PSObject.Properties | ForEach-Object {
                    $this.NameMap[$_.Name] = [string]$_.Value
                }
            }
            # MaxCacheMB NIE przywracaj z JSON — jest dynamicznie wyliczane w konstruktorze
            if ($data.TotalHits) { $this.TotalHits = [int]$data.TotalHits }
            if ($data.TotalMisses) { $this.TotalMisses = [int]$data.TotalMisses }
            if ($data.TotalPreloads) { $this.TotalPreloads = [int]$data.TotalPreloads }
            if ($data.TotalWastedPreloads) { $this.TotalWastedPreloads = [int]$data.TotalWastedPreloads }
            # #4 Restore AppStartupMs
            if ($data.AppStartupMs) {
                $data.AppStartupMs.PSObject.Properties | ForEach-Object {
                    if ($_.Value -gt 0 -and $_.Value -lt 120000) {
                        $this.AppStartupMs[$_.Name] = [int]$_.Value
                    }
                }
            }
            # Restore ChildApps — parent→children mapping
            if ($data.ChildApps) {
                $data.ChildApps.PSObject.Properties | ForEach-Object {
                    $parentName = $_.Name
                    if (-not $this.ChildApps.ContainsKey($parentName)) { $this.ChildApps[$parentName] = @{} }
                    $_.Value.PSObject.Properties | ForEach-Object {
                        $cn = $_.Name; $cv = $_.Value
                        if (-not $this.ChildApps[$parentName].ContainsKey($cn)) {
                            $parsedLS = [datetime]::Now
                            try { $parsedLS = [datetime]::Parse($cv.LastSeen, [System.Globalization.CultureInfo]::InvariantCulture) } catch {}
                            $childEntry = @{
                                ExePath = $cv.ExePath; Dir = $cv.Dir
                                LastSeen = $parsedLS
                                LearnedFiles = [System.Collections.Generic.List[hashtable]]::new()
                            }
                            if ($cv.LF -and $cv.LF.Count -gt 0) {
                                foreach ($f in $cv.LF) { $childEntry.LearnedFiles.Add(@{ Path = $f.P; Size = [long]$f.S; Module = $f.M }) }
                            }
                            $this.ChildApps[$parentName][$cn] = $childEntry
                        }
                    }
                }
                Write-RCLog "LoadState: ChildApps restored for $($this.ChildApps.Count) parents"
            }
        } catch {
            Write-RCLog "LOAD ERROR: $($_.Exception.Message)"
        }
        Write-RCLog "LoadState: Paths=$($this.AppPaths.Count) Class=$($this.AppClassification.Count) Aggr=$([Math]::Round($this.Aggressiveness,2)) MaxCache=$($this.MaxCacheMB)MB"
    }
    
    # ═══════════════════════════════════════════════════════════════
    # BOOTSTRAP SCAN — natychmiastowe skanowanie przy pierwszym uruchomieniu
    # Skanuje WSZYSTKIE running procesy, uczy się ścieżek + modułów,
    # klasyfikuje Heavy/Light, tworzy RAMCache.json od razu
    # ═══════════════════════════════════════════════════════════════
    [int] BootstrapScan([hashtable]$prophetApps) {
        $learned = 0
        try {
            # Pobierz wszystkie user procesy (nie systemowe, nie svchost)
            $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -and 
                $_.Id -gt 4 -and 
                $_.ProcessName -notmatch '^(svchost|csrss|lsass|services|smss|wininit|System|Idle|Registry|dwm|conhost|fontdrvhost|sihost|taskhostw|ctfmon|SearchHost|StartMenuExperienceHost|RuntimeBroker|TextInputHost|SecurityHealthSystray|explorer|ShellExperienceHost|pwsh|powershell|WindowsTerminal|WmiPrvSE|wmiprvse|ApplicationFrameHost|nvcontainer|NVDisplay\.Container|audiodg|CompPkgSrv|dllhost|ShellHost|igfxEM|dasHost|spoolsv|SearchIndexer|MidiSrv|IntelAudioService|CrossDeviceResume|TiWorker|msedgewebview2|GameManagerService3|OneApp\.IGCC\.WinService)$' -and
                $_.ProcessName -notmatch '\.(tmp|nks\.tmp)$' -and
                $_.Path -notmatch '\\(Temp|TEMP|tmp)\\' -and
                $_.Path -notmatch '\\\.vscode\\extensions\\' -and  # v43.15: skip VS Code extension binaries
                $_.WorkingSet64 -gt 30MB
            } | Sort-Object WorkingSet64 -Descending | Select-Object -First 20
            
            foreach ($proc in $procs) {
                $appName = $proc.ProcessName
                if ($this.AppPaths.ContainsKey($appName)) {
                    # App already known from LoadState — skip entirely
                    # (Bootstrap's shallow module scan would overwrite richer LearnedFiles data)
                    continue
                }
                
                try {
                    # 1. Zapisz ścieżkę
                    $this.AppPaths[$appName] = @{
                        ExePath = $proc.Path
                        Dir = [System.IO.Path]::GetDirectoryName($proc.Path)
                    }
                    
                    # 2. Profiluj moduły (rzeczywiste DLL w pamięci procesu)
                    $modules = $proc.Modules | Where-Object { 
                        $_.FileName -and (Test-Path $_.FileName -ErrorAction SilentlyContinue)
                    } | Select-Object -First $(if ($this.HW -and $this.HW.CacheStrategy) { $this.HW.CacheStrategy.MaxModules } elseif ($this.TotalSystemRAM -gt 32768) { 50 } elseif ($this.TotalSystemRAM -gt 16384) { 35 } else { 25 })
                    
                    if ($modules.Count -ge 2) {
                        $learnedFiles = [System.Collections.Generic.List[hashtable]]::new()
                        foreach ($mod in $modules) {
                            try {
                                $size = (Get-Item $mod.FileName -ErrorAction Stop).Length
                                if ($size -gt 5KB -and $size -lt 200MB) {
                                    $learnedFiles.Add(@{
                                        Path = $mod.FileName
                                        Size = $size
                                        Module = $mod.ModuleName
                                    })
                                }
                            } catch { continue }
                        }
                        if ($learnedFiles.Count -ge 2) {
                            $this.AppPaths[$appName].LearnedFiles = $learnedFiles
                            $this.AppPaths[$appName].ProfiledAt = [datetime]::Now
                            $this.AppPaths[$appName].ModuleCount = $learnedFiles.Count
                        }
                    }
                    
                    # 3. Klasyfikuj Heavy/Light
                    $class = "Light"
                    if ($proc.WorkingSet64 -gt 1500MB) { $class = "Heavy" }
                    elseif ($prophetApps -and $prophetApps.ContainsKey($appName)) {
                        $pa = $prophetApps[$appName]
                        if ($pa.IsHeavy -or ($pa.AvgCPU -gt 50 -and $pa.Samples -gt 20)) { $class = "Heavy" }
                    }
                    $this.AppClassification[$appName] = $class
                    
                    $learned++
                    Write-RCLog "  BOOTSTRAP NEW: $appName [$class] modules=$($this.AppPaths[$appName].ModuleCount) exe=$($proc.Path)"
                } catch { continue }
            }
        } catch {}
        Write-RCLog "BOOTSTRAP: Scanned $learned new apps. Paths=$($this.AppPaths.Count) Class=$($this.AppClassification.Count)"
        if ($learned -gt 0) { $this.IsDirty = $true }
        # Loguj tylko nowo znalezione procesy (nie cały AppPaths)
        return $learned
    }
    
    # ═══════════════════════════════════════════════════════════════
    # STARTUP PRELOAD — przy starcie ENGINE załaduj apps które Prophet
    # wie że są typowe dla tej godziny + mają high priority
    # ═══════════════════════════════════════════════════════════════
    [void] StartupPreload([hashtable]$prophetApps, [int[]]$hourlyActivity, [hashtable]$transitions) {
        if (-not $this.Enabled -or -not $prophetApps) { return }
        $currentHour = (Get-Date).Hour
        
        # Sprawdź czy ta godzina jest aktywna (Prophet wie)
        $hourActivity = 0
        if ($hourlyActivity -and $currentHour -ge 0 -and $currentHour -lt 24) {
            $hourActivity = $hourlyActivity[$currentHour]
        }
        if ($hourActivity -lt 3) { return }  # Za mało danych dla tej godziny
        
        # Zbierz kandydatów: Heavy apps z wysokim priorytetem które mamy ścieżkę
        $candidates = @{}
        foreach ($appName in $prophetApps.Keys) {
            $app = $prophetApps[$appName]
            # Tylko apps ze znaną ścieżką
            if (-not $this.AppPaths.ContainsKey($appName)) { continue }
            # Skip apps z negative penalty
            if ($this.IsNegativePenalty($appName)) { continue }
            
            $prio = 0
            if ($app.IsHeavy) { $prio += 30 }
            if ($app.Samples -and $app.Samples -gt 5) { $prio += [Math]::Min(25, [int]($app.Samples / 3)) }
            if ($app.AvgCPU -gt 40) { $prio += 15 }
            # Bonus za historyczne hity (z NegativeScores — ironic name ale trzyma hitCount)
            if ($this.NegativeScores.ContainsKey($appName)) {
                $prio += [Math]::Min(20, $this.NegativeScores[$appName].HitCount * 3)
            }
            # v43.15 LEARNED bonus — proporcjonalny do rozmiaru (większy profil = ważniejsza app)
            if ($this.AppPaths[$appName].ContainsKey('LearnedFiles') -and $this.AppPaths[$appName].LearnedFiles -and $this.AppPaths[$appName].LearnedFiles.Count -gt 0) {
                $lfSzMB = 0; foreach ($f in $this.AppPaths[$appName].LearnedFiles) { $lfSzMB += $f.Size }
                $lfSzMB = $lfSzMB / 1MB
                # 0-5MB → +2, 5-50MB → +8, 50-100MB → +15, >100MB → +20 (cap)
                $learnedBonus = [Math]::Min(20, [int]($lfSzMB / 5))
                $prio += [Math]::Max(2, $learnedBonus)
            }
            # Chain bonus
            if ($transitions) {
                foreach ($src in $transitions.Keys) {
                    if ($transitions[$src].ContainsKey($appName)) {
                        $prio += [Math]::Min(10, $transitions[$src][$appName].Count * 2)
                    }
                }
            }
            if ($prio -ge 10) { $candidates[$appName] = $prio }  # Niski próg — mamy 20GB RAM do zagospodarowania
        }
        
        if ($candidates.Count -eq 0) { return }
        
        # Preload top kandydatów — skaluj do HW Tier
        $maxStartup = 6  # default
        if ($this.HW -and $this.HW.CacheStrategy) {
            $maxStartup = $this.HW.CacheStrategy.MaxStartupApps
        } else {
            $totalGB = $this.TotalSystemRAM / 1024.0
            $maxStartup = if ($totalGB -ge 32) { 10 } elseif ($totalGB -ge 16) { 6 } else { 3 }
        }
        
        $sorted = $candidates.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $maxStartup
        Write-RCLog "STARTUP PRELOAD: $($sorted.Count) candidates (max=$maxStartup, hour=$currentHour, activity=$hourActivity)"
        foreach ($entry in $sorted) {
            $appName = $entry.Name
            # PRIORYTET: DiskCache (instant — pliki lokalne, sekwencyjne)
            if ($this.LoadAppFromDiskCache($appName)) { continue }
            # FALLBACK: PreloadApp z oryginalnych ścieżek (wolniejsze)
            $exePath = $this.AppPaths[$appName].ExePath
            $conf = [Math]::Min(1.0, $entry.Value / 60.0)
            $this.PreloadApp($appName, $exePath, $conf) | Out-Null
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # WARMUP ALL KNOWN — po starcie, ładuj WSZYSTKIE znane apps z LEARNED profilem
    # Wywołaj ASYNCHRONICZNIE (w tle) ~30s po starcie, żeby nie blokować UI
    # Filozofia: 20GB RAM i 500MB cache = marnowanie. Załaduj WSZYSTKO co znamy.
    # ═══════════════════════════════════════════════════════════════
    [int] WarmupAllKnown() {
        if (-not $this.Enabled) { return 0 }
        
        # Bezpieczeństwo: minimum 25% RAM musi zostać wolne
        $this.MeasureMemoryPressure() | Out-Null
        $freePercent = if ($this.TotalSystemRAM -gt 0) { $this.LastAvailableMB / $this.TotalSystemRAM } else { 0.5 }
        if ($freePercent -lt 0.30) { 
            Write-RCLog "WARMUP SKIP: not enough free RAM ($([int]($freePercent*100))%)"
            return 0 
        }
        
        $loaded = 0
        $skipped = 0
        $totalMB = 0.0
        
        # Zbierz WSZYSTKIE apps z LEARNED profilem (mają DLL do załadowania)
        foreach ($appName in @($this.AppPaths.Keys)) {
            # Skip już cached
            if ($this.CachedApps.ContainsKey($appName)) { continue }
            # Skip blacklisted
            if ($appName -eq "Desktop" -or $appName -match '^(pwsh|powershell|conhost|WindowsTerminal|ShellHost|explorer|dwm|WinStore\.App|ApplicationFrameHost|SystemSettings)$') { continue }
            # Skip negative penalty
            if ($this.IsNegativePenalty($appName)) { continue }
            # Tylko LEARNED (mają prawdziwy profil DLL)
            $entry = $this.AppPaths[$appName]
            if (-not $entry.ContainsKey('LearnedFiles') -or -not $entry.LearnedFiles -or $entry.LearnedFiles.Count -lt 3) { 
                # Brak LearnedFiles — spróbuj załadować z DiskCache manifest
                if ($this.LoadAppFromDiskCache($appName)) {
                    $loaded++
                    $appMB = 0; if ($this.CachedApps.ContainsKey($appName)) { $appMB = $this.CachedApps[$appName].SizeMB }
                    $totalMB += $appMB
                } else {
                    $skipped++
                }
                continue 
            }
            
            # PERFORMANCE FIX: Sprawdź RAM co 5 apps (nie co app — WMI jest wolne)
            if ($loaded % 5 -eq 0) {
                $this._LastWMICheck = [DateTime]::MinValue  # Force fresh WMI
                $this.MeasureMemoryPressure() | Out-Null
                $freeNow = if ($this.TotalSystemRAM -gt 0) { $this.LastAvailableMB / $this.TotalSystemRAM } else { 0.5 }
                if ($freeNow -lt 0.25) {
                    Write-RCLog "WARMUP STOP: RAM at $([int]($freeNow*100))% free after $loaded apps ($([int]$totalMB)MB)"
                    break
                }
            }
            
            # Cache full?
            if ($this.TotalCachedMB -ge $this.MaxCacheMB * 0.90) {
                Write-RCLog "WARMUP STOP: cache at 90% ($([int]$this.TotalCachedMB)/$($this.MaxCacheMB)MB) after $loaded apps"
                break
            }
            
            # PRIORYTET 1: Załaduj z DiskCache (C:\CPUManager\Cache\) — szybsze niż skanowanie DLL
            if ($this.LoadAppFromDiskCache($appName)) {
                $loaded++
                $appMB = 0; if ($this.CachedApps.ContainsKey($appName)) { $appMB = $this.CachedApps[$appName].SizeMB }
                $totalMB += $appMB
            } else {
                # FALLBACK: Preload z oryginalnych ścieżek
                $exePath = $entry.ExePath
                $conf = 0.7  # Medium confidence — ładuj exe + top DLL
                if ($this.PreloadApp($appName, $exePath, $conf)) {
                    $loaded++
                    $appMB = 0; if ($this.CachedApps.ContainsKey($appName)) { $appMB = $this.CachedApps[$appName].SizeMB }
                    $totalMB += $appMB
                }
            }
            
            # PERFORMANCE FIX: Yield CPU co app żeby nie blokować systemu podczas warmup
            [System.Threading.Thread]::Sleep(10)
        }
        
        Write-RCLog "WARMUP COMPLETE: $loaded apps loaded ($([int]$totalMB)MB), $skipped skipped (no profile), cache=$([int]$this.TotalCachedMB)/$($this.MaxCacheMB)MB"
        # v47.4: Po warmup — załaduj dzieci wszystkich załadowanych parentów
        $childrenLoaded = 0
        foreach ($parentApp in @($this.ChildApps.Keys)) {
            if ($this.CachedApps.ContainsKey($parentApp) -and $this.HasGuardBandSpace()) {
                $beforeCount = $this.TotalPreloads
                $this.PreloadChildApps($parentApp)
                $childrenLoaded += ($this.TotalPreloads - $beforeCount)
            }
        }
        if ($childrenLoaded -gt 0) {
            Write-RCLog "WARMUP CHILDREN: $childrenLoaded child apps loaded for cached parents"
        }
        return $loaded
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# NativeCopy — Win32 P/Invoke: FILE_FLAG_NO_BUFFERING + FILE_FLAG_WRITE_THROUGH
# Omija Windows Cache Manager całkowicie — dane idą: dysk → RAM → dysk
# Double-buffer producer-consumer: odczyt i zapis nakładają się w czasie
# Wymaganie: bufory i offsety muszą być wielokrotnością 4096 (Advanced Format)
# ═══════════════════════════════════════════════════════════════════════════
if (-not ([System.Management.Automation.PSTypeName]'NativeCopy').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Concurrent;

public static class NativeCopy {
    const uint GR  = 0x80000000u;   // GENERIC_READ
    const uint GW  = 0x40000000u;   // GENERIC_WRITE
    const uint OE  = 3u;            // OPEN_EXISTING
    const uint CA  = 2u;            // CREATE_ALWAYS
    const uint SR  = 0x00000001u;   // FILE_SHARE_READ
    const uint NB  = 0x20000000u;   // FILE_FLAG_NO_BUFFERING   — pomija OS read cache
    const uint WT  = 0x80000000u;   // FILE_FLAG_WRITE_THROUGH  — zapis prosto na nośnik
    const uint SS  = 0x08000000u;   // FILE_FLAG_SEQUENTIAL_SCAN — hint dla prefetcher
    const int  SEC = 4096;          // Advanced Format / NVMe sector size

    static readonly IntPtr INV = new IntPtr(-1);

    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="CreateFileW")]
    static extern IntPtr CF(string f, uint a, uint s, IntPtr sa, uint cr, uint fl, IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool ReadFile(IntPtr h, IntPtr b, uint n, out uint d, IntPtr o);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool WriteFile(IntPtr h, IntPtr b, uint n, out uint d, IntPtr o);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool GetFileSizeEx(IntPtr h, out long s);
    [DllImport("kernel32.dll")] static extern bool SetFilePointerEx(IntPtr h, long d, out long np, uint m);
    [DllImport("kernel32.dll")] static extern bool SetEndOfFile(IntPtr h);

    // Kopiuje jeden plik: NO_BUFFERING+WRITE_THROUGH + double-buffer
    // chunkMB: rozmiar bufora (zostanie wyrównany do 4096)
    // prog:    prog[0] = skopiowane bajty (aktualizowane na żywo przez wątek zapisu)
    // Zwraca "OK" lub opis błędu
    public static string Copy(string src, string dst, int chunkMB, long[] prog) {
        long chunk = Math.Max(SEC, (((long)chunkMB * 1024L * 1024L) / SEC) * SEC);

        // Otwórz źródło: NO_BUFFERING+SEQUENTIAL_SCAN (pomiń read-cache OS)
        IntPtr sH = CF(src, GR, SR, IntPtr.Zero, OE, NB|SS, IntPtr.Zero);
        if (sH == INV) return "ERR_SRC:" + Marshal.GetLastWin32Error();
        long fsz = 0; GetFileSizeEx(sH, out fsz);
        long aln  = (fsz / SEC) * SEC;   // wyrównany rozmiar do pełnych sektorów
        long tail = fsz - aln;           // ogon: ostatnie < 4096 bajtów

        // Otwórz cel: NO_BUFFERING+WRITE_THROUGH (zapis prosto na nośnik, bez cache OS)
        IntPtr dH = CF(dst, GW, 0, IntPtr.Zero, CA, NB|WT, IntPtr.Zero);
        if (dH == INV) { CloseHandle(sH); return "ERR_DST:" + Marshal.GetLastWin32Error(); }

        // Dwa wyrównane bufory do double-bufferingu
        IntPtr rA = Marshal.AllocHGlobal((int)chunk + SEC);
        IntPtr rB = Marshal.AllocHGlobal((int)chunk + SEC);
        IntPtr bA = new IntPtr(((rA.ToInt64() + SEC - 1) / SEC) * SEC);
        IntPtr bB = new IntPtr(((rB.ToInt64() + SEC - 1) / SEC) * SEC);
        IntPtr[] bufs = new IntPtr[] { bA, bB };
        string er = null;

        try {
            // readSem (count=2): writer zwalnia slot po każdym zakończonym zapisie
            //   → sygnalizuje: "ten bufor jest wolny, można nadpisać"
            // writeQ (cap=2): reader produkuje (ptr,size), writer konsumuje FIFO
            //   → zapewnia że reader jest max 2 chunki przed writerem
            var readSem = new SemaphoreSlim(2, 2);
            var writeQ  = new BlockingCollection<Tuple<IntPtr,int>>(2);

            // Wątek zapisu (consumer) — działa równolegle z odczytem
            var writerTask = Task.Run(() => {
                foreach (var item in writeQ.GetConsumingEnumerable()) {
                    if (item.Item2 <= 0) { readSem.Release(); break; } // sentinel
                    uint bw = 0;
                    if (!WriteFile(dH, item.Item1, (uint)item.Item2, out bw, IntPtr.Zero))
                        Interlocked.CompareExchange(ref er, "ERR_WRITE:" + Marshal.GetLastWin32Error(), null);
                    prog[0] += bw;
                    readSem.Release(); // bufor wolny do ponownego użycia
                }
            });

            // Pętla odczytu (producer) — odczyt bi%2 podczas gdy writer pisze (bi-1)%2
            int bi = 0; long rem = aln;
            while (rem > 0 && er == null) {
                readSem.Wait();                     // czekaj na wolny bufor
                IntPtr cur = bufs[bi & 1];
                long toRead = Math.Min(chunk, rem);
                uint br = 0;
                if (!ReadFile(sH, cur, (uint)toRead, out br, IntPtr.Zero) || br == 0) {
                    readSem.Release(); break;       // błąd lub EOF
                }
                writeQ.Add(Tuple.Create(cur, (int)br));
                rem -= br; bi++;
            }
            writeQ.Add(Tuple.Create(IntPtr.Zero, 0)); // sentinel: zakończ wątek zapisu
            writerTask.Wait();
        } finally {
            Marshal.FreeHGlobal(rA); Marshal.FreeHGlobal(rB);
            CloseHandle(sH); CloseHandle(dH);
        }

        if (er != null) return er;

        // Ogon: ostatnie (fsz%4096) bajtów — nie są wyrównane, używamy normalnego I/O
        if (tail > 0) {
            IntPtr s2 = CF(src, GR, SR, IntPtr.Zero, OE, SS, IntPtr.Zero);
            IntPtr d2 = CF(dst, GW, 0,  IntPtr.Zero, OE, WT, IntPtr.Zero);
            if (s2 != INV && d2 != INV) {
                long np = 0;
                SetFilePointerEx(s2, aln, out np, 0);  // przewiń src do pozycji ogona
                SetFilePointerEx(d2, 0,   out np, 2);  // przewiń dst na koniec (FILE_END=2)
                IntPtr tb = Marshal.AllocHGlobal((int)tail + 16);
                try {
                    uint tr = 0, tw = 0;
                    ReadFile(s2, tb, (uint)tail, out tr, IntPtr.Zero);
                    if (tr > 0) { WriteFile(d2, tb, tr, out tw, IntPtr.Zero); prog[0] += tw; }
                } finally { Marshal.FreeHGlobal(tb); }
            }
            if (s2 != INV) CloseHandle(s2);
            if (d2 != INV) CloseHandle(d2);
        }

        // Obetnij plik do dokładnego rozmiaru (NO_BUFFERING mógł dopełnić ostatni sektor zerami)
        IntPtr d3 = CF(dst, GW, 0, IntPtr.Zero, OE, 0u, IntPtr.Zero);
        if (d3 != INV) {
            long np = 0; SetFilePointerEx(d3, fsz, out np, 0); SetEndOfFile(d3); CloseHandle(d3);
        }
        return "OK";
    }
}
'@ -ErrorAction Stop
}
# Helper: wywołanie NativeCopy z poziomu klasy — type resolution odroczone do call-time
# (klasy PS resolwują [TypeName] w czasie parsowania, funkcje skryptowe — dopiero przy wywołaniu)
function _Invoke-NativeCopy {
    param([string]$Src, [string]$Dst, [int]$ChunkMB, [long[]]$Prog)
    return [NativeCopy]::Copy($Src, $Dst, $ChunkMB, $Prog)
}

# ═══════════════════════════════════════════════════════════════════════════
# FastFileCopy — inteligentne kopiowanie/przenoszenie plików
# Kontrolowane przez ENGINE, używa RAMCache jako bufor
# Strategie: SmallBatch (parallel), LargeStream (sequential), Mix (adaptive)
# ═══════════════════════════════════════════════════════════════════════════