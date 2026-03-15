# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 03_Classes_Foundation.ps1
# Core classes: PerformanceMonitor, RAMManager, StorageModeManager, ReactiveThermalGuard, RyzenAdjVerifier
# Lines 788-1877 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
class PerformanceMonitor {
    [System.Collections.Generic.List[double]] $FrameTimes
    [int] $MaxSamples
    [double] $LastFPS
    [double] $AvgFrameTime
    [double] $FrameTimeVariance
    [bool] $StutteringDetected
    [int] $StutterCount
    [datetime] $LastStutter
    PerformanceMonitor() {
        $this.FrameTimes = [System.Collections.Generic.List[double]]::new()
        $this.MaxSamples = 60  # Last 60 frames
        $this.LastFPS = 0
        $this.AvgFrameTime = 0
        $this.FrameTimeVariance = 0
        $this.StutteringDetected = $false
        $this.StutterCount = 0
        $this.LastStutter = [datetime]::MinValue
    }
    [void] RecordFrame([double]$frameTimeMs) {
        $this.FrameTimes.Add($frameTimeMs)
        if ($this.FrameTimes.Count -gt $this.MaxSamples) {
            $this.FrameTimes.RemoveAt(0)
        }
        if ($this.FrameTimes.Count -ge 10) {
            $this.AnalyzePerformance()
        }
    }
    [void] AnalyzePerformance() {
        # Oblicz srednia
        $sum = 0.0
        foreach ($ft in $this.FrameTimes) { $sum += $ft }
        $this.AvgFrameTime = $sum / $this.FrameTimes.Count
        $this.LastFPS = if ($this.AvgFrameTime -gt 0) { 1000.0 / $this.AvgFrameTime } else { 0 }
        # Oblicz wariancje (wykrycie stutteringu)
        $variance = 0.0
        foreach ($ft in $this.FrameTimes) {
            $diff = $ft - $this.AvgFrameTime
            $variance += $diff * $diff
        }
        $this.FrameTimeVariance = [Math]::Sqrt($variance / $this.FrameTimes.Count)
        # Detekcja stutteringu: variance > 30% sredniej
        # LUB pojedyncza frame time > 2x sredniej
        $stutterThreshold = $this.AvgFrameTime * 0.3
        $this.StutteringDetected = $false
        if ($this.FrameTimeVariance -gt $stutterThreshold) {
            $this.StutteringDetected = $true
        }
        # Sprawdz ostatnie 10 frame times
        $recentFrames = $this.FrameTimes.GetRange([Math]::Max(0, $this.FrameTimes.Count - 10), [Math]::Min(10, $this.FrameTimes.Count))
        foreach ($ft in $recentFrames) {
            if ($ft -gt ($this.AvgFrameTime * 2.0)) {
                $this.StutteringDetected = $true
                break
            }
        }
        if ($this.StutteringDetected) {
            $this.StutterCount++
            $this.LastStutter = [datetime]::Now
        }
    }
    [hashtable] GetMetrics() {
        return @{
            FPS = [Math]::Round($this.LastFPS, 1)
            AvgFrameTime = [Math]::Round($this.AvgFrameTime, 2)
            Variance = [Math]::Round($this.FrameTimeVariance, 2)
            Stuttering = $this.StutteringDetected
            StutterCount = $this.StutterCount
        }
    }
    [bool] HasRecentStutter() {
        # Stutter w ostatnich 5 sekundach
        return (([datetime]::Now - $this.LastStutter).TotalSeconds -lt 5)
    }
}
$Script:PerfMonitor = [PerformanceMonitor]::new()
# STARTUP BOOST TRACKING (global Turbo for first launch)
function Start-StartupBoost {
    param([System.Diagnostics.Process]$Process)
    if (-not $Script:StartupBoostEnabled -or -not $Process) { return }
    try {
        if ($Process.HasExited) { return }
    } catch { return }
    
    # v43.10 FIX: Sprawdź HardLock PRZED włączeniem StartupBoost
    $processName = $Process.ProcessName
    if ($Script:AppCategoryPreferences) {
        $appLower = $processName.ToLower() -replace '\.exe$', ''
        
        # DEBUG: Log wszystkie klucze
        if ($Global:DebugMode -and $Script:AppCategoryPreferences.Count -gt 0) {
            $allKeys = $Script:AppCategoryPreferences.Keys -join ", "
            Add-Log " [DEBUG] StartupBoost checking HardLock for: $processName against: $allKeys" -Debug
        }
        
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
                    # ZAWSZE LOG gdy blokujemy
                    Add-Log " STARTUP BOOST BLOCKED: $processName (HardLock for '$key' - Bias=$($pref.Bias))"
                    return  # Pomiń StartupBoost dla aplikacji z HardLock
                }
            }
        }
    }
    
    $processId = $Process.Id
    if ($Script:ActivityBoostApps.ContainsKey($processId)) { return }
    $entry = [pscustomobject]@{
        Pid = $processId
        ProcessName = $Process.ProcessName
        Started = Get-Date
        LastCPUTime = $Process.TotalProcessorTime.TotalSeconds
        LastCheck = Get-Date
        IdleCount = 0           # Ile razy z rzędu CPU < próg
        BoostActive = $true
        PeakCPU = 0.0
    }
    $Script:ActivityBoostApps[$processId] = $entry
    Add-Log "[ACTIVITY BOOST] Started: $($Process.ProcessName) (PID:$processId)"
}
function Update-StartupBoostState {
    if (-not $Script:ActivityBoostApps -or $Script:ActivityBoostApps.Count -eq 0) {
        $Script:ActiveStartupBoost = $null
        return $null
    }
    $now = Get-Date
    $active = $null
    $idleThreshold = if ($null -ne $Script:ActivityIdleThreshold) { $Script:ActivityIdleThreshold } else { 5 }
    $maxIdleChecks = 3          # Ile razy idle = koniec boost
    $maxBoostTime = if ($null -ne $Script:ActivityMaxBoostTime) { $Script:ActivityMaxBoostTime } else { 30 }
    foreach ($procId in @($Script:ActivityBoostApps.Keys)) {
        $entry = $Script:ActivityBoostApps[$procId]
        # Safety: Max boost time
        $elapsed = ($now - $entry.Started).TotalSeconds
        if ($elapsed -gt $maxBoostTime) {
            Add-Log "[ACTIVITY BOOST] Timeout: $($entry.ProcessName) after ${maxBoostTime}s"
            $Script:ActivityBoostApps.Remove($procId)
            continue
        }
        # Sprawdź czy proces jeszcze żyje
        try {
            $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if (-not $proc -or $proc.HasExited) {
                $Script:ActivityBoostApps.Remove($procId)
                continue
            }
            # Oblicz CPU% tej aplikacji
            $currentCPUTime = $proc.TotalProcessorTime.TotalSeconds
            $timeDelta = ($now - $entry.LastCheck).TotalSeconds
            if ($timeDelta -gt 0.5) {  # Min 0.5s między pomiarami
                $cpuDelta = $currentCPUTime - $entry.LastCPUTime
                $appCPU = [Math]::Min(100, ($cpuDelta / $timeDelta) * 100)
                # Update entry
                $entry.LastCPUTime = $currentCPUTime
                $entry.LastCheck = $now
                if ($appCPU -gt $entry.PeakCPU) { $entry.PeakCPU = $appCPU }
                # Sprawdź czy aktywna (using configurable threshold)
                if ($appCPU -lt $idleThreshold) {
                    $entry.IdleCount++
                    if ($entry.IdleCount -ge $maxIdleChecks) {
                        # Aplikacja idle - koniec boost
                        Add-Log "[ACTIVITY BOOST] End: $($entry.ProcessName) idle (peak:$([Math]::Round($entry.PeakCPU))%)"
                        $entry.BoostActive = $false
                        $Script:ActivityBoostApps.Remove($procId)
                        continue
                    }
                } else {
                    # Aktywna - reset idle counter
                    $entry.IdleCount = 0
                }
            }
            # Jeśli boost aktywny, dodaj do aktywnych
            if ($entry.BoostActive) {
                if (-not $active -or $entry.Started -gt $active.Started) {
                    $active = $entry
                }
            }
        } catch {
            $Script:ActivityBoostApps.Remove($procId)
        }
    }
    $Script:ActiveStartupBoost = $active
    return $Script:ActiveStartupBoost
}
if (-not $Script:ActivityBoostApps) { $Script:ActivityBoostApps = @{} }
# Funkcje narzedziowe do refaktoryzacji powtarzajacych sie fragmentow
function Ensure-FileExists {
    param([string]$Path)
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }
}
function Ensure-DirectoryExists {
    param([string]$Path)
    
    # Sprawdź czy ścieżka to Junction/SymLink (przekierowanie na RAM dysk)
    $isJunction = $false
    $targetPath = $Path
    
    try {
        $item = Get-Item -Path $Path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkType -eq 'Junction') {
            $isJunction = $true
            $targetPath = $item.Target
            Write-Host "  [INIT] Wykryto Junction: $Path -> $targetPath" -ForegroundColor Cyan
        }
    } catch {
        # Ścieżka nie istnieje lub nie jest Junction - sprawdzimy dalej
    }
    
    # Jeśli to Junction, upewnij się że folder docelowy istnieje
    if ($isJunction -and $targetPath) {
        if (-not (Test-Path $targetPath)) {
            try {
                Write-Host "  [INIT] Tworzę folder docelowy na RAM dysku: $targetPath" -ForegroundColor Yellow
                New-Item -ItemType Directory -Path $targetPath -Force -ErrorAction Stop | Out-Null
                Start-Sleep -Milliseconds 200
                
                if (Test-Path $targetPath) {
                    Write-Host "  [INIT] Folder na RAM dysku utworzony: $targetPath" -ForegroundColor Green
                } else {
                    Write-Host "  [INIT] BŁĄD: Nie można utworzyć folderu na RAM dysku!" -ForegroundColor Red
                }
            } catch {
                Write-Host "  [INIT] BŁĄD tworzenia folderu na RAM dysku: $_" -ForegroundColor Red
            }
        }
    }
    
    # Standardowe sprawdzenie i tworzenie folderu
    if (-not (Test-Path $Path)) {
        try {
            Write-Host "  [INIT] Tworzę folder: $Path" -ForegroundColor Cyan
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
            
            # Retry dla RAM dysków - czekaj aż system zarejestruje folder
            $retries = 0
            while ((-not (Test-Path $Path)) -and ($retries -lt 5)) {
                Start-Sleep -Milliseconds 200
                $retries++
            }
            
            if (Test-Path $Path) {
                Write-Host "  [INIT] Folder utworzony: $Path" -ForegroundColor Green
            } else {
                Write-Host "  [INIT] Ostrzeżenie: Folder może nie być dostępny: $Path" -ForegroundColor Yellow
            }
        } catch {
            Write-Host "  [INIT] Błąd tworzenia folderu $Path - $_" -ForegroundColor Red
        }
    }
}
function Find-FirstExistingPath {
    param([string[]]$Paths)
    foreach ($p in $Paths) { if ($p -and (Test-Path $p)) { return $p } }
    return $null
}
function Remove-ExistingFiles {
    param([string[]]$Files)
    foreach ($f in $Files) { if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
}
# Backwards-compatible wrapper: some code calls Remove-FilesIfExist (older name)
if (-not (Get-Command -Name Remove-FilesIfExist -ErrorAction SilentlyContinue)) {
    function Remove-FilesIfExist {
        param([string[]]$Files)
        foreach ($f in $Files) { if ($f -and (Test-Path $f)) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
    }
}
# Lightweight fallback for Write-Log during early startup (will be superseded by real implementation later)
if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param(
            [string]$Message,
            [string]$Type = "INFO"
        )
        try {
            $Timestamp = Get-Date -Format "HH:mm:ss.fff"
            $LogEntry = "[$Timestamp] [$Type] $Message"
            Write-Host $LogEntry -ForegroundColor Gray
            if ($Type -match "ERROR|CRITICAL|FATAL|WARN") {
                try { Add-Content -Path 'C:\CPUManager\ErrorLog.txt' -Value $LogEntry -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
            }
        } catch {}
    }
}
$ErrorLogPath = "C:\CPUManager\ErrorLog.txt"
Ensure-FileExists $ErrorLogPath
# RAMMANAGER v2.0 + STORAGE MANAGER + THERMAL GUARD
# RAMManager v2.0 - TRUE SHARED MEMORY (Memory-Mapped Files)
# NOWOSC: Uzywa Memory-Mapped Files zamiast lokalnego hashtable
# RESULT: ENGINE i CONSOLE faktycznie wspoldziela dane w pamieci RAM
Add-Type -AssemblyName System.Core
class RAMManager {
    [System.IO.MemoryMappedFiles.MemoryMappedFile]$MMF
    [System.IO.MemoryMappedFiles.MemoryMappedViewAccessor]$Accessor
    [System.Threading.Mutex]$Mutex
    [string]$MutexName
    [string]$MMFName
    [int]$TimeoutMs
    [int]$MaxSize
    [string]$ErrorLogPath
    [string]$CachedJson
    [object]$CachedLock  # v39 FIX: Lock dla CachedJson
    [System.Collections.Concurrent.ConcurrentQueue[string]]$WriteQueue
    [int]$MaxQueue
    [int]$QueueDrops
    [int]$BackgroundWrites
    [int]$BackgroundRetries
    [bool]$UseLockFree
    [System.Threading.CancellationTokenSource]$WriterCTS
    [bool]$IsInitialized  # v39 FIX: Flaga inicjalizacji
    static [int]$HEADER_ACTIVE_OFFSET = 0      # Int32 - aktywny slot (0 lub 1)
    static [int]$HEADER_SIZE = 4               # Rozmiar naglowka globalnego
    static [int]$SLOT_VER_OFFSET = 0           # Int64 - wersja w slocie
    static [int]$SLOT_LEN_OFFSET = 8           # Int32 - dlugosc danych w slocie
    static [int]$SLOT_DATA_OFFSET = 12         # Poczatek danych w slocie
    static [int]$MIN_MMF_SIZE = 4096           # Minimalny rozmiar MMF
    RAMManager([string]$name) {
        $this.MutexName = "Global\CPUManager_RAM_$name"
        $this.MMFName = "Global\CPUManager_MMF_$name"
        $this.TimeoutMs = 200
        $this.MaxSize = 2097152
        $this.ErrorLogPath = "C:\CPUManager\ErrorLog.txt"
        $this.CachedJson = "{}"
        $this.CachedLock = New-Object Object
        $this.IsInitialized = $false
        if ($this.MaxSize -lt [RAMManager]::MIN_MMF_SIZE) {
            $this.LogError("MMF size too small: $($this.MaxSize), minimum: $([RAMManager]::MIN_MMF_SIZE)")
            throw "MMF size too small"
        }
        try { 
            $this.Mutex = [System.Threading.Mutex]::OpenExisting($this.MutexName) 
        } catch { 
            try {
                $this.Mutex = [System.Threading.Mutex]::new($false, $this.MutexName) 
            } catch {
                $this.LogError("Mutex create failed: $_")
                throw
            }
        }
        try {
            $this.MMF = [System.IO.MemoryMappedFiles.MemoryMappedFile]::OpenExisting($this.MMFName)
        } catch {
            try {
                $this.MMF = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateNew($this.MMFName, $this.MaxSize, [System.IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite)
            } catch {
                $this.LogError("MMF create failed: $_")
                if ($this.Mutex) { try { $this.Mutex.Dispose() } catch {} }
                throw
            }
        }
        try {
            $this.Accessor = $this.MMF.CreateViewAccessor(0, $this.MaxSize)
        } catch {
            $this.LogError("Accessor create failed: $_")
            if ($this.MMF) { try { $this.MMF.Dispose() } catch {} }
            if ($this.Mutex) { try { $this.Mutex.Dispose() } catch {} }
            throw
        }
        # Initialize queue/telemetry
        $this.WriteQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $this.MaxQueue = 1000
        $this.QueueDrops = 0
        $this.BackgroundWrites = 0
        $this.BackgroundRetries = 0
        $this.UseLockFree = $true
        $this.WriterCTS = [System.Threading.CancellationTokenSource]::new()
        try {
            $slotSize = $this.GetSlotSize()
            if ($slotSize -lt [RAMManager]::SLOT_DATA_OFFSET + 10) {
                $this.LogError("Slot size too small: $slotSize")
            } else {
                $empty = [System.Text.Encoding]::UTF8.GetBytes("{}")
                if ($empty.Length -le ($slotSize - [RAMManager]::SLOT_DATA_OFFSET)) {
                    # Inicjalizuj slot 0
                    $base0 = [RAMManager]::HEADER_SIZE + (0 * $slotSize)
                    $ver0 = [Int64]([DateTime]::UtcNow.Ticks)
                    $this.Accessor.Write($base0 + [RAMManager]::SLOT_VER_OFFSET, [Int64]$ver0)
                    $this.Accessor.Write($base0 + [RAMManager]::SLOT_LEN_OFFSET, [int]$empty.Length)
                    $this.Accessor.WriteArray($base0 + [RAMManager]::SLOT_DATA_OFFSET, $empty, 0, $empty.Length)
                    # Inicjalizuj slot 1
                    $base1 = [RAMManager]::HEADER_SIZE + (1 * $slotSize)
                    $ver1 = [Int64]([DateTime]::UtcNow.Ticks)
                    $this.Accessor.Write($base1 + [RAMManager]::SLOT_VER_OFFSET, [Int64]$ver1)
                    $this.Accessor.Write($base1 + [RAMManager]::SLOT_LEN_OFFSET, [int]$empty.Length)
                    $this.Accessor.WriteArray($base1 + [RAMManager]::SLOT_DATA_OFFSET, $empty, 0, $empty.Length)
                    # Ustaw aktywny slot na 0
                    $this.Accessor.Write([RAMManager]::HEADER_ACTIVE_OFFSET, [int]0)
                    $this.SetCachedJson("{}")
                    $this.IsInitialized = $true
                }
            }
        } catch {
            $this.LogError("Slot init failed: $_")
        }
        # Start background writer
        $self = $this
        $cts = $this.WriterCTS
        [System.Threading.Tasks.Task]::Run([Action]{
            while (-not $cts.IsCancellationRequested) {
                $itemRef = [ref]$null
                if ($self.WriteQueue.TryDequeue([ref]$itemRef)) {
                    $jsonItem = $itemRef.Value
                    $written = $false
                    $retries = 0
                    while (-not $written -and $retries -lt 10) {
                        try {
                            if ($self.UseLockFree) {
                                $active = $self.Accessor.ReadInt32([RAMManager]::HEADER_ACTIVE_OFFSET)
                                if ($active -ne 0 -and $active -ne 1) { $active = 0 }
                                $slotSize = $self.GetSlotSize()
                                $slot = 1 - $active
                                $base = [RAMManager]::HEADER_SIZE + ($slot * $slotSize)
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonItem)
                                $maxDataSize = $slotSize - [RAMManager]::SLOT_DATA_OFFSET
                                if ($bytes.Length -gt $maxDataSize) {
                                    $self.LogError("Background writer: data too large ($($bytes.Length) > $maxDataSize) - dropped")
                                    $written = $true; break
                                }
                                $ver = [Int64]([DateTime]::UtcNow.Ticks)
                                $self.Accessor.Write($base + [RAMManager]::SLOT_VER_OFFSET, [Int64]$ver)
                                $self.Accessor.Write($base + [RAMManager]::SLOT_LEN_OFFSET, [int]$bytes.Length)
                                $self.Accessor.WriteArray($base + [RAMManager]::SLOT_DATA_OFFSET, $bytes, 0, $bytes.Length)
                                # publish
                                $self.Accessor.Write([RAMManager]::HEADER_ACTIVE_OFFSET, [int]$slot)
                                $self.SetCachedJson($jsonItem)
                                $self.BackgroundWrites++
                                $written = $true
                            } else {
                                if ($self.Mutex.WaitOne(500)) {
                                    try {
                                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($jsonItem)
                                        if ($bytes.Length -le ($self.MaxSize - 12)) {
                                            $ver = [Int64]([DateTime]::UtcNow.Ticks)
                                            $self.Accessor.Write(0, [Int64]$ver)
                                            $self.Accessor.Write(8, [int]$bytes.Length)
                                            $self.Accessor.WriteArray(12, $bytes, 0, $bytes.Length)
                                            $self.SetCachedJson($jsonItem)
                                            $self.BackgroundWrites++
                                            $written = $true
                                        } else {
                                            $self.LogError("Background writer (mutex): data too large - dropped")
                                            $written = $true
                                        }
                                    } finally { $self.Mutex.ReleaseMutex() }
                                } else { $retries++; $self.BackgroundRetries++; Start-Sleep -Milliseconds (50 * $retries) }
                            }
                        } catch { $self.LogError("Background writer exception: $_"); $retries++; $self.BackgroundRetries++; Start-Sleep -Milliseconds (200 * $retries) }
                    }
                } else { Start-Sleep -Milliseconds 50 }
            }
        }) | Out-Null
    }
    [int]GetSlotSize() {
        return [Math]::Floor(($this.MaxSize - [RAMManager]::HEADER_SIZE) / 2)
    }
    [void]SetCachedJson([string]$json) {
        [System.Threading.Monitor]::Enter($this.CachedLock)
        try { $this.CachedJson = $json }
        finally { [System.Threading.Monitor]::Exit($this.CachedLock) }
    }
    [string]GetCachedJson() {
        [System.Threading.Monitor]::Enter($this.CachedLock)
        try { return $this.CachedJson }
        finally { [System.Threading.Monitor]::Exit($this.CachedLock) }
    }
    [void]WriteRaw([string]$json) {
        try {
            if ($this.WriteQueue.Count -ge $this.MaxQueue) { $this.QueueDrops++; $this.LogError("WriteRaw: queue full, drop event"); return }
            $this.WriteQueue.Enqueue($json)
        } catch { $this.LogError("WriteRaw enqueue ERROR: $_") }
    }
    [string]ReadRaw() {
        try {
            if ($this.UseLockFree) {
                $slotSize = $this.GetSlotSize()
                $maxDataSize = $slotSize - [RAMManager]::SLOT_DATA_OFFSET
                for ($retry = 0; $retry -lt 5; $retry++) {
                    $active = $this.Accessor.ReadInt32([RAMManager]::HEADER_ACTIVE_OFFSET)
                    if ($active -ne 0 -and $active -ne 1) { 
                        Start-Sleep -Milliseconds 5
                        continue 
                    }
                    $base = [RAMManager]::HEADER_SIZE + ($active * $slotSize)
                    $ver1 = $this.Accessor.ReadInt64($base + [RAMManager]::SLOT_VER_OFFSET)
                    $length = $this.Accessor.ReadInt32($base + [RAMManager]::SLOT_LEN_OFFSET)
                    if ($length -le 0 -or $length -gt $maxDataSize) { 
                        Start-Sleep -Milliseconds 5
                        continue 
                    }
                    $bytes = New-Object byte[] $length
                    $this.Accessor.ReadArray($base + [RAMManager]::SLOT_DATA_OFFSET, $bytes, 0, $length)
                    $ver2 = $this.Accessor.ReadInt64($base + [RAMManager]::SLOT_VER_OFFSET)
                    if ($ver1 -ne $ver2) { 
                        # Writer collision - retry
                        Start-Sleep -Milliseconds 5
                        continue 
                    }
                    $result = [System.Text.Encoding]::UTF8.GetString($bytes)
                    $this.SetCachedJson($result)
                    return $result
                }
                # Po wszystkich retry - zwroc cached
                return $this.GetCachedJson()
            } else {
                if ($this.Mutex.WaitOne(50)) {
                    try {
                        $length = $this.Accessor.ReadInt32(8)
                        if ($length -le 0 -or $length -gt ($this.MaxSize - 12)) { return $this.GetCachedJson() }
                        $bytes = New-Object byte[] $length
                        $this.Accessor.ReadArray(12, $bytes, 0, $length)
                        $result = [System.Text.Encoding]::UTF8.GetString($bytes)
                        $this.SetCachedJson($result)
                        return $result
                    } finally { $this.Mutex.ReleaseMutex() }
                } else { return $this.GetCachedJson() }
            }
        } catch { $this.LogError("ReadRaw ERROR: $_"); return $this.GetCachedJson() }
    }
    [void]Write([string]$key, $value) {
        try {
            $json = $this.ReadRaw()
            $data = $null
            try { $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            if (-not $data) { $data = @{} }
            elseif ($data -is [System.Array]) { $data = @{ Items = $data } }
            if ($data -is [PSCustomObject]) { $data | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force } else { $data[$key] = $value }
            $newJson = $data | ConvertTo-Json -Depth 20 -Compress
            $jsonSize = [System.Text.Encoding]::UTF8.GetByteCount($newJson)
            if ($jsonSize -gt 1048576) {
                $this.LogError("Write($key) WARNING: JSON size $jsonSize bytes exceeds 1MB limit - data may be dropped")
            }
            $this.WriteRaw($newJson)
        } catch { $this.LogError("Write($key) ERROR: $_") }
    }
    [object]Read([string]$key) {
        try { 
            $json = $this.ReadRaw()
            $data = $null
            try { $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            if (-not $data) { return $null }
            if ($data -is [System.Array]) { return $null }
            if ($data -is [PSCustomObject]) { return $data.PSObject.Properties[$key].Value } 
            else { return $data[$key] }
        } catch { $this.LogError("Read($key) ERROR: $_"); return $null }
    }
    [bool]Exists([string]$key) {
        try { 
            $json = $this.ReadRaw()
            $data = $null
            try { $data = $json | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
            if (-not $data) { return $false }
            if ($data -is [System.Array]) { return $false }
            if ($data -is [PSCustomObject]) { return $null -ne $data.PSObject.Properties[$key] } 
            else { return $data.ContainsKey($key) }
        } catch { $this.LogError("Exists($key) ERROR: $_"); return $false }
    }
    [void]Clear() {
        $this.WriteRaw("{}")
        $this.SetCachedJson("{}")
    }
    [bool]BackupToJSON([string]$filePath) {
        try { 
            $json = $this.ReadRaw()
            $tmpPath = "$filePath.tmp"
            $json | Set-Content $tmpPath -Encoding UTF8 -Force
            Move-Item $tmpPath $filePath -Force
            return $true 
        } catch { $this.LogError("BackupToJSON ERROR: $_"); return $false }
    }
    [bool]RestoreFromJSON([string]$filePath) {
        try { 
            if (-not (Test-Path $filePath)) { return $false }
            $json = Get-Content $filePath -Raw -Encoding UTF8
            try { $null = $json | ConvertFrom-Json -ErrorAction Stop } 
            catch { $this.LogError("RestoreFromJSON: Invalid JSON in $filePath"); return $false }
            $this.WriteRaw($json)
            return $true 
        } catch { $this.LogError("RestoreFromJSON ERROR: $_"); return $false }
    }
    [void]LogError([string]$message) {
        try { $logEntry = "$(Get-Date -Format 'HH:mm:ss') - RAMManager: $message"; Add-Content -Path $this.ErrorLogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
    }
    [void]LogDebug([string]$message) {
    }
    [hashtable]GetTelemetry() {
        return @{ QueueSize = $this.WriteQueue.Count; QueueDrops = $this.QueueDrops; BackgroundWrites = $this.BackgroundWrites; BackgroundRetries = $this.BackgroundRetries; IsInitialized = $this.IsInitialized }
    }
    [void]Dispose() {
        if ($this.WriterCTS) { 
            try { 
                $this.WriterCTS.Cancel()
                Start-Sleep -Milliseconds 200
                $this.WriterCTS.Dispose()
            } catch {} 
        }
        try { if ($this.Accessor) { $this.Accessor.Dispose() } } catch {}
        try { if ($this.MMF) { $this.MMF.Dispose() } } catch {}
        try { if ($this.Mutex) { $this.Mutex.Dispose() } } catch {}
    }
}
# STORAGE MODE MANAGER - Zarzadza trybami JSON/RAM/BOTH + Auto-Backup
class StorageModeManager {
    [RAMManager]$RAM
    [string]$JSONPath
    [string]$ConfigPath
    [bool]$UseJSON
    [bool]$UseRAM
    [DateTime]$LastBackup
    [int]$BackupIntervalSeconds
    [string]$ErrorLogPath
    StorageModeManager([string]$jsonPath, [string]$configPath) {
        $this.JSONPath = $jsonPath
        $this.ConfigPath = $configPath
        $this.ErrorLogPath = "C:\CPUManager\ErrorLog.txt"
        $this.LastBackup = [DateTime]::MinValue
        # Wczytaj tryb z config
        $this.LoadMode()
        # Inicjalizuj RAMManager jesli potrzebny
        if ($this.UseRAM) {
            $this.RAM = [RAMManager]::new("MainEngine")
        }
        # Ustaw interval backupu zaleznie od trybu
        $this.UpdateBackupInterval()
    }
    [void]LoadMode() {
        if (Test-Path $this.ConfigPath) {
            try {
                $config = Get-Content $this.ConfigPath -Raw | ConvertFrom-Json
                # v40.2 FIX: Obsłuż oba formaty - UseJSON/UseRAM i Mode
                if ($null -ne $config.UseJSON -and $null -ne $config.UseRAM) {
                    $this.UseJSON = [bool]$config.UseJSON
                    $this.UseRAM = [bool]$config.UseRAM
                } elseif ($config.Mode) {
                    # Fallback: parsuj z Mode string
                    $this.UseJSON = ($config.Mode -eq "JSON" -or $config.Mode -eq "BOTH")
                    $this.UseRAM = ($config.Mode -eq "RAM" -or $config.Mode -eq "BOTH")
                } else {
                    $this.UseJSON = $true
                    $this.UseRAM = $false
                }
                return
            }
            catch {
                $this.LogError("LoadMode ERROR: $_")
            }
        }
        # Default: JSON only (safe)
        $this.UseJSON = $true
        $this.UseRAM = $false
    }
    [void]SaveMode() {
        try {
            @{
                UseJSON = $this.UseJSON
                UseRAM = $this.UseRAM
            } | ConvertTo-Json | Set-Content $this.ConfigPath -Force
        }
        catch {
            $this.LogError("SaveMode ERROR: $_")
        }
    }
    [void]SetMode([string]$mode) {
        $oldUseRAM = $this.UseRAM
        $oldUseJSON = $this.UseJSON
        switch ($mode.ToUpper()) {
            "JSON" {
                $this.UseJSON = $true
                $this.UseRAM = $false
            }
            "RAM" {
                $this.UseJSON = $false
                $this.UseRAM = $true
            }
            "BOTH" {
                $this.UseJSON = $true
                $this.UseRAM = $true
            }
        }
        # Sync danych przed zmiana trybu
        $this.SyncStorage($oldUseRAM, $oldUseJSON)
        # Inicjalizuj RAM jesli trzeba
        if ($this.UseRAM -and -not $this.RAM) {
            $this.RAM = [RAMManager]::new("MainEngine")
        }
        $this.UpdateBackupInterval()
        $this.SaveMode()
        $this.LogError("Storage mode changed to: $mode")
    }
    [void]UpdateBackupInterval() {
        if ($this.UseRAM -and $this.UseJSON) {
            # BOTH: backup co 1 minute
            $this.BackupIntervalSeconds = 60
        }
        elseif ($this.UseRAM -and -not $this.UseJSON) {
            # RAM only: backup co 5 minut (safety)
            $this.BackupIntervalSeconds = 300
        }
        else {
            # JSON only: nie potrzeba backupu
            $this.BackupIntervalSeconds = 0
        }
    }
    # KLUCZOWA FUNKCJA: Sync danych miedzy RAM a JSON przy zmianie trybu
    [void]SyncStorage([bool]$oldUseRAM, [bool]$oldUseJSON) {
        try {
            # Przechodzimy Z RAM -> cokolwiek innego = zrzuc RAM do JSON
            if ($oldUseRAM -and -not $this.UseRAM) {
                if ($this.RAM) {
                    $this.LogError("SyncStorage: Dumping RAM -> JSON (mode change)")
                    $this.RAM.BackupToJSON($this.JSONPath)
                }
            }
            # Przechodzimy Z JSON -> RAM = wczytaj JSON do RAM
            if (-not $oldUseRAM -and $this.UseRAM) {
                if ($this.RAM) {
                    $this.LogError("SyncStorage: Loading JSON -> RAM (mode change)")
                    $this.RAM.RestoreFromJSON($this.JSONPath)
                }
            }
            # BOTH -> BOTH = sync obu kierunkow (preferuj RAM jako nowsze)
            if ($oldUseRAM -and $this.UseRAM -and $oldUseJSON -and $this.UseJSON) {
                if ($this.RAM) {
                    $this.RAM.BackupToJSON($this.JSONPath)
                }
            }
        }
        catch {
            $this.LogError("SyncStorage ERROR: $_")
        }
    }
    # Zapis danych (auto-routing zaleznie od trybu)
    [void]WriteData([hashtable]$data) {
        try {
            # RAM
            if ($this.UseRAM -and $this.RAM) {
                $this.RAM.Write("WidgetData", $data)
            }
            # JSON
            if ($this.UseJSON) {
                $json = $data | ConvertTo-Json -Depth 10 -Compress
                # Atomic write
                $tmpPath = "$($this.JSONPath).tmp"
                $json | Set-Content $tmpPath -Encoding UTF8 -Force
                Move-Item $tmpPath $this.JSONPath -Force
            }
        }
        catch {
            $this.LogError("WriteData ERROR: $_")
        }
    }
    # Odczyt danych (auto-routing)
    [object]ReadData() {
        try {
            # RAM ma priorytet (szybszy)
            if ($this.UseRAM -and $this.RAM) {
                $data = $this.RAM.Read("WidgetData")
                if ($data) {
                    return $data
                }
            }
            # Fallback: JSON
            if ($this.UseJSON -and (Test-Path $this.JSONPath)) {
                $json = Get-Content $this.JSONPath -Raw -Encoding UTF8
                return $json | ConvertFrom-Json
            }
        }
        catch {
            $this.LogError("ReadData ERROR: $_")
        }
        return $null
    }
    # Auto-Backup (wywoluj w glownej petli)
    [void]AutoBackup() {
        if ($this.BackupIntervalSeconds -eq 0) {
            return  # Backup wylaczony
        }
        $elapsed = ([DateTime]::Now - $this.LastBackup).TotalSeconds
        if ($elapsed -ge $this.BackupIntervalSeconds) {
            if ($this.RAM) {
                $this.LogError("AutoBackup: RAM -> JSON")
                $this.RAM.BackupToJSON($this.JSONPath)
                $this.LastBackup = [DateTime]::Now
            }
        }
    }
    # Force sync (z GUI)
    [void]ForceSyncNow() {
        if ($this.RAM) {
            $this.LogError("ForceSyncNow: RAM -> JSON")
            $this.RAM.BackupToJSON($this.JSONPath)
            $this.LastBackup = [DateTime]::Now
        }
    }
    [void]LogError([string]$message) {
        try {
            $logEntry = "$(Get-Date -Format 'HH:mm:ss') - StorageModeManager: $message"
            Add-Content -Path $this.ErrorLogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch { }
    }
    [void]Dispose() {
        if ($this.RAM) {
            # Final backup przed zamknieciem
            $this.RAM.BackupToJSON($this.JSONPath)
            $this.RAM.Dispose()
        }
    }
}
# REACTIVE THERMAL GUARD - Natychmiastowa reakcja na przegrzanie
class ReactiveThermalGuard {
    [int]$EmergencyTemp         # Temp ktora wymusza Silent (default 95°C)
    [int]$CriticalTemp          # Temp ktora wymusza shutdown CPU (default 100°C)
    [int]$RecoveryTemp          # Temp ponizej ktorej mozna wrocic do AI (default 85°C)
    [bool]$EmergencyActive      # Czy jestesmy w trybie emergency
    [DateTime]$EmergencyStart   # Kiedy rozpoczal sie emergency
    [int]$EmergencyCount        # Ile razy emergency zostal wywolany
    [string]$ForcedMode         # Jaki tryb zostal wymusony
    [string]$LastMode           # Ostatni tryb przed emergency
    [string]$ErrorLogPath
    ReactiveThermalGuard() {
        $this.EmergencyTemp = 95
        $this.CriticalTemp = 100
        $this.RecoveryTemp = 85
        $this.EmergencyActive = $false
        $this.EmergencyStart = [DateTime]::MinValue
        $this.EmergencyCount = 0
        $this.ForcedMode = ""
        $this.LastMode = ""
        $this.ErrorLogPath = "C:\CPUManager\ErrorLog.txt"
    }
    # Glowna funkcja sprawdzajaca - wywoluj w kazdej iteracji
    [hashtable]Check([int]$currentTemp, [string]$currentMode) {
        $result = @{
            Action = "NONE"           # NONE / FORCE_SILENT / FORCE_SHUTDOWN / RECOVER
            NewMode = $currentMode    # Jaki tryb ustawic
            Message = ""
            IsEmergency = $this.EmergencyActive
        }
        # CRITICAL: Shutdown CPU (100°C+)
        if ($currentTemp -ge $this.CriticalTemp) {
            $result.Action = "FORCE_SHUTDOWN"
            $result.NewMode = "Silent"
            $result.Message = " CRITICAL THERMAL SHUTDOWN: ${currentTemp}°C >= $($this.CriticalTemp)°C - EMERGENCY SILENT + TDP MINIMUM"
            if (-not $this.EmergencyActive) {
                $this.EmergencyActive = $true
                $this.EmergencyStart = [DateTime]::Now
                $this.LastMode = $currentMode
                $this.EmergencyCount++
            }
            $this.ForcedMode = "Silent"
            $this.LogError($result.Message)
            return $result
        }
        # EMERGENCY: Force Silent (95°C+)
        if ($currentTemp -ge $this.EmergencyTemp) {
            $result.Action = "FORCE_SILENT"
            $result.NewMode = "Silent"
            $result.Message = " THERMAL EMERGENCY: ${currentTemp}°C >= $($this.EmergencyTemp)°C - FORCING SILENT MODE"
            if (-not $this.EmergencyActive) {
                $this.EmergencyActive = $true
                $this.EmergencyStart = [DateTime]::Now
                $this.LastMode = $currentMode
                $this.EmergencyCount++
            }
            $this.ForcedMode = "Silent"
            $this.LogError($result.Message)
            return $result
        }
        # RECOVERY: Temperatura spadla ponizej recovery threshold
        if ($this.EmergencyActive -and $currentTemp -le $this.RecoveryTemp) {
            $duration = ([DateTime]::Now - $this.EmergencyStart).TotalSeconds
            $result.Action = "RECOVER"
            $result.NewMode = $this.LastMode  # Wroc do trybu sprzed emergency
            $result.Message = " THERMAL RECOVERY: ${currentTemp}°C <= $($this.RecoveryTemp)°C - Restoring mode: $($this.LastMode) (emergency lasted ${duration}s)"
            $this.EmergencyActive = $false
            $this.ForcedMode = ""
            $this.LogError($result.Message)
            return $result
        }
        # NORMAL: Temperatura OK
        if ($this.EmergencyActive) {
            # Dalej w emergency (temp miedzy recovery a emergency)
            $result.Action = "MAINTAIN_SILENT"
            $result.NewMode = "Silent"
            $result.Message = "[WARN] THERMAL COOLDOWN: ${currentTemp}°C (waiting for <=$($this.RecoveryTemp)°C to recover)"
            $result.IsEmergency = $true
        }
        return $result
    }
    [string]GetStatus() {
        if ($this.EmergencyActive) {
            $duration = [int]([DateTime]::Now - $this.EmergencyStart).TotalSeconds
            return " EMERGENCY (${duration}s) - Events: $($this.EmergencyCount)"
        }
        return " Normal - Events: $($this.EmergencyCount)"
    }
    [void]Reset() {
        $this.EmergencyActive = $false
        $this.EmergencyCount = 0
        $this.ForcedMode = ""
        $this.LastMode = ""
    }
    [void]LogError([string]$message) {
        try {
            $logEntry = "$(Get-Date -Format 'HH:mm:ss') - ThermalGuard: $message"
            Add-Content -Path $this.ErrorLogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch { }
    }
}
# RYZENADJ VERIFIER - Weryfikacja czy TDP faktycznie sie zaaplikowal
class RyzenAdjVerifier {
    [string]$RyzenAdjPath
    [bool]$Available
    [int]$LastSTAPM
    [int]$LastFast
    [int]$LastSlow
    [int]$LastTctl
    [int]$VerificationAttempts
    [int]$VerificationFailures
    [DateTime]$LastVerification
    [string]$ErrorLogPath
    RyzenAdjVerifier([string]$ryzenAdjPath) {
        $this.RyzenAdjPath = $ryzenAdjPath
        $this.Available = Test-Path $this.RyzenAdjPath
        $this.LastSTAPM = 0
        $this.LastFast = 0
        $this.LastSlow = 0
        $this.LastTctl = 0
        $this.VerificationAttempts = 0
        $this.VerificationFailures = 0
        $this.LastVerification = [DateTime]::MinValue
        $this.ErrorLogPath = "C:\CPUManager\ErrorLog.txt"
    }
    # Ustaw TDP z weryfikacja
    [hashtable]SetTDP([int]$stapm, [int]$fast, [int]$slow, [int]$tctl) {
        $result = @{
            Success = $false
            Applied = $false
            Verified = $false
            Message = ""
            ActualSTAPM = 0
            ActualFast = 0
            ActualSlow = 0
            ActualTctl = 0
        }
        if (-not $this.Available) {
            $result.Message = "RyzenADJ not available at: $($this.RyzenAdjPath)"
            $this.LogError($result.Message)
            return $result
        }
        try {
            # Buduj argumenty
            $args = @(
                "--stapm-limit=$stapm",
                "--fast-limit=$fast",
                "--slow-limit=$slow",
                "--tctl-temp=$tctl"
            )
            # Wykonaj RyzenADJ
            $process = Start-Process -FilePath $this.RyzenAdjPath `
                                    -ArgumentList $args `
                                    -NoNewWindow `
                                    -Wait `
                                    -PassThru `
                                    -RedirectStandardOutput "C:\CPUManager\ryzenadj_output.txt" `
                                    -RedirectStandardError "C:\CPUManager\ryzenadj_error.txt"
            if ($process.ExitCode -eq 0) {
                $result.Applied = $true
                $result.Message = " RyzenADJ executed: STAPM=$stapm Fast=$fast Slow=$slow Tctl=$tctl"
                $this.LogError($result.Message)
                # Poczekaj chwile na zastosowanie
                Start-Sleep -Milliseconds 500
                # WERYFIKACJA: Odczytaj faktyczne wartosci
                $verified = $this.VerifyTDP($stapm, $fast, $slow, $tctl)
                if ($verified.Success) {
                    $result.Success = $true
                    $result.Verified = $true
                    $result.ActualSTAPM = $verified.ActualSTAPM
                    $result.ActualFast = $verified.ActualFast
                    $result.ActualSlow = $verified.ActualSlow
                    $result.ActualTctl = $verified.ActualTctl
                    $result.Message += " |  VERIFIED"
                }
                else {
                    $result.Verified = $false
                    $result.Message += " | [WARN] VERIFICATION FAILED: $($verified.Message)"
                    $this.VerificationFailures++
                }
                # Zapisz wartosci
                $this.LastSTAPM = $stapm
                $this.LastFast = $fast
                $this.LastSlow = $slow
                $this.LastTctl = $tctl
                $this.LastVerification = [DateTime]::Now
                $this.VerificationAttempts++
            }
            else {
                $result.Message = "- RyzenADJ failed with exit code: $($process.ExitCode)"
                $this.LogError($result.Message)
                $this.VerificationFailures++
            }
        }
        catch {
            $result.Message = "- RyzenADJ exception: $_"
            $this.LogError($result.Message)
            $this.VerificationFailures++
        }
        return $result
    }
    # Weryfikuj faktyczne wartosci TDP (odczyt z -i)
    [hashtable]VerifyTDP([int]$expectedSTAPM, [int]$expectedFast, [int]$expectedSlow, [int]$expectedTctl) {
        $result = @{
            Success = $false
            Message = ""
            ActualSTAPM = 0
            ActualFast = 0
            ActualSlow = 0
            ActualTctl = 0
        }
        try {
            # Wywolaj RyzenADJ -i (info mode)
            $infoOutput = & $this.RyzenAdjPath -i 2>&1
            if (-not $infoOutput) {
                $result.Message = "No output from RyzenADJ -i"
                return $result
            }
            # Parsuj output (przyklad: "STAPM LIMIT                | 25000")
            foreach ($line in $infoOutput) {
                if ($line -match "STAPM LIMIT.*\|\s*(\d+)") {
                    $result.ActualSTAPM = [int]([int]$matches[1] / 1000)  # mW -> W
                }
                if ($line -match "FAST LIMIT.*\|\s*(\d+)") {
                    $result.ActualFast = [int]([int]$matches[1] / 1000)
                }
                if ($line -match "SLOW LIMIT.*\|\s*(\d+)") {
                    $result.ActualSlow = [int]([int]$matches[1] / 1000)
                }
                if ($line -match "TCTL TEMP.*\|\s*(\d+)") {
                    $result.ActualTctl = [int]$matches[1]
                }
            }
            # Sprawdz zgodnosc (tolerancja +/-1W / +/-2°C)
            $stapmOK = [Math]::Abs($result.ActualSTAPM - $expectedSTAPM) -le 1
            $fastOK = [Math]::Abs($result.ActualFast - $expectedFast) -le 1
            $slowOK = [Math]::Abs($result.ActualSlow - $expectedSlow) -le 1
            $tctlOK = [Math]::Abs($result.ActualTctl - $expectedTctl) -le 2
            if ($stapmOK -and $fastOK -and $slowOK -and $tctlOK) {
                $result.Success = $true
                $result.Message = "Values match (tolerance +/-1W/+/-2°C)"
            }
            else {
                $result.Success = $false
                $mismatch = @()
                if (-not $stapmOK) { $mismatch += "STAPM: expected $expectedSTAPM, got $($result.ActualSTAPM)" }
                if (-not $fastOK) { $mismatch += "Fast: expected $expectedFast, got $($result.ActualFast)" }
                if (-not $slowOK) { $mismatch += "Slow: expected $expectedSlow, got $($result.ActualSlow)" }
                if (-not $tctlOK) { $mismatch += "Tctl: expected $expectedTctl, got $($result.ActualTctl)" }
                $result.Message = "Mismatch: " + ($mismatch -join ", ")
            }
        }
        catch {
            $result.Message = "Verification exception: $_"
        }
        return $result
    }
    [string]GetStatus() {
        $successRate = if ($this.VerificationAttempts -gt 0) {
            [int](($this.VerificationAttempts - $this.VerificationFailures) / $this.VerificationAttempts * 100)
        } else { 0 }
        return "Attempts: $($this.VerificationAttempts) | Failures: $($this.VerificationFailures) | Success: $successRate%"
    }
    [void]LogError([string]$message) {
        try {
            $logEntry = "$(Get-Date -Format 'HH:mm:ss') - RyzenAdjVerifier: $message"
            Add-Content -Path $this.ErrorLogPath -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        }
        catch { }
    }
}