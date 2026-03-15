# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 08_Functions_Power_UI.ps1
# FastFileCopy, DesktopWidget, WebDashboard, power management, Save/Load-State, Render-UI
# Lines 19292-20437 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
class FastFileCopy {
    # ── Config ──
    [int] $SmallFileThreshold          # Granica mały/duży plik (bytes)
    [int] $ParallelThreads             # Ile wątków dla małych plików
    [int] $LargeBufferSize             # Bufor dla dużych plików
    [int] $RAMBufferMaxMB              # Max RAM na buforowanie małych plików
    [bool] $VerifyAfterCopy            # Sprawdź hash po kopiowaniu
    [bool] $PreserveTimestamps         # Zachowaj daty
    
    # ── State ──
    [long] $TotalBytes
    [long] $CopiedBytes
    [int] $TotalFiles
    [int] $CopiedFiles
    [int] $FailedFiles
    [double] $SpeedMBps
    [string] $CurrentFile
    [string] $Strategy                 # "SmallBatch" | "LargeStream" | "Mixed"
    [bool] $IsCancelled
    [System.Diagnostics.Stopwatch] $Timer
    [System.Collections.Generic.List[string]] $Errors
    
    # ── Drive info cache ──
    [hashtable] $DriveTypes            # "C:" → "SSD" | "HDD" | "Network"
    [long] $LargeChunkBytes            # Dynamiczny rozmiar chunka dla dużych plików (RAM-based)
    
    FastFileCopy() {
        $this.SmallFileThreshold = 1MB
        $this.LargeBufferSize = 4MB
        $this.LargeChunkBytes = 128MB
        $this.RAMBufferMaxMB = 512
        $this.VerifyAfterCopy = $false
        $this.PreserveTimestamps = $true
        $this.IsCancelled = $false
        $this.Timer = [System.Diagnostics.Stopwatch]::new()
        $this.Errors = [System.Collections.Generic.List[string]]::new()
        $this.DriveTypes = @{}
        
        # Skaluj wątki wg total RAM (CPU bound)
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $totalGB = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
            if     ($totalGB -ge 32) { $this.ParallelThreads = 16 }
            elseif ($totalGB -ge 16) { $this.ParallelThreads = 12 }
            else                     { $this.ParallelThreads = 8  }
        } catch { $this.ParallelThreads = 8 }
        
        # RAMBufferMaxMB i LargeChunkBytes → bazują na WOLNYM RAM (nie total)
        $this.RecalcRAMBudget()
        $this.DetectDriveTypes()
    }
    
    # ═══ DYNAMICZNY BUDŻET RAM — wywołuj przed każdym Copy ═══
    [int] GetFreeRAMMB() {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            return [int]($os.FreePhysicalMemory / 1KB)   # FreePhysicalMemory jest w KB
        } catch { return 512 }
    }
    
    [void] RecalcRAMBudget() {
        $freeMB = $this.GetFreeRAMMB()
        # Użyj max 50% wolnego RAM, min 256MB, max 8192MB
        $budgetMB = [Math]::Max(256, [Math]::Min(8192, [int]($freeMB * 0.50)))
        $this.RAMBufferMaxMB = $budgetMB
        
        # Chunk dla dużych plików: do 25% wolnego RAM per plik (min 64MB, max 2048MB)
        $chunkMB = [Math]::Max(64, [Math]::Min(2048, [int]($freeMB * 0.25)))
        $this.LargeChunkBytes = [long]$chunkMB * 1MB
        
        # LargeBufferSize (stream fallback) skaluj też
        $this.LargeBufferSize = if ($freeMB -ge 4096) { 32MB }
                                elseif ($freeMB -ge 2048) { 16MB }
                                elseif ($freeMB -ge 1024) { 8MB  }
                                else { 4MB }
    }
    
    # ═══ WYKRYWANIE TYPU DYSKU ═══
    [void] DetectDriveTypes() {
        try {
            $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue
            $partitions = Get-CimInstance Win32_DiskDriveToDiskPartition -ErrorAction SilentlyContinue
            $logicals = Get-CimInstance Win32_LogicalDiskToPartition -ErrorAction SilentlyContinue
            
            foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
                if (-not $drive.IsReady) { continue }
                $letter = $drive.Name.Substring(0, 2)  # "C:"
                if ($drive.DriveType -eq [System.IO.DriveType]::Network) {
                    $this.DriveTypes[$letter] = "Network"
                } else {
                    # Domyślnie SSD, spróbuj wykryć HDD
                    $this.DriveTypes[$letter] = "SSD"
                    try {
                        $mediaType = Get-PhysicalDisk | Where-Object { $_.DeviceID -eq "0" } | Select-Object -First 1 -ExpandProperty MediaType
                        if ($mediaType -eq "HDD") { $this.DriveTypes[$letter] = "HDD" }
                    } catch {}
                }
            }
        } catch {}
    }
    
    [string] GetDriveType([string]$path) {
        try {
            $root = [System.IO.Path]::GetPathRoot($path)
            $letter = $root.Substring(0, 2)
            if ($this.DriveTypes.ContainsKey($letter)) { return $this.DriveTypes[$letter] }
            if ($path.StartsWith("\\")) { return "Network" }
        } catch {}
        return "SSD"
    }
    
    # ═══ ANALIZA ŹRÓDŁA — dobór strategii ═══
    [hashtable] AnalyzeSource([string]$sourcePath) {
        $result = @{
            TotalFiles = 0; TotalBytes = [long]0
            SmallFiles = 0; SmallBytes = [long]0
            LargeFiles = 0; LargeBytes = [long]0
            Files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        }
        
        try {
            $items = if (Test-Path $sourcePath -PathType Container) {
                [System.IO.DirectoryInfo]::new($sourcePath).EnumerateFiles("*", [System.IO.SearchOption]::AllDirectories)
            } else {
                @([System.IO.FileInfo]::new($sourcePath))
            }
            
            foreach ($fi in $items) {
                $result.TotalFiles++
                $result.TotalBytes += $fi.Length
                $result.Files.Add($fi)
                if ($fi.Length -le $this.SmallFileThreshold) {
                    $result.SmallFiles++
                    $result.SmallBytes += $fi.Length
                } else {
                    $result.LargeFiles++
                    $result.LargeBytes += $fi.Length
                }
            }
        } catch {
            $this.Errors.Add("Analiza: $_")
        }
        
        return $result
    }
    
    [string] SelectStrategy([hashtable]$analysis, [string]$srcDrive, [string]$dstDrive) {
        $smallRatio = if ($analysis.TotalFiles -gt 0) { $analysis.SmallFiles / $analysis.TotalFiles } else { 0 }
        
        # >80% małych plików → SmallBatch (parallel)
        if ($smallRatio -gt 0.8) { return "SmallBatch" }
        # >80% dużych plików → LargeStream (sequential, duży bufor)
        if ($smallRatio -lt 0.2) { return "LargeStream" }
        # Mix
        return "Mixed"
    }
    
    # ═══ GŁÓWNA METODA — KOPIUJ ═══
    [hashtable] Copy([string]$source, [string]$destination, [bool]$move) {
        $this.Reset()
        $this.Timer.Start()
        
        $analysis = $this.AnalyzeSource($source)
        if ($analysis.TotalFiles -eq 0) {
            return @{ Success = $false; Error = "Brak plików do kopiowania" }
        }
        
        $this.TotalFiles = $analysis.TotalFiles
        $this.TotalBytes = $analysis.TotalBytes
        
        # Odśwież budżet RAM tuż przed kopią (wolny RAM mógł się zmienić)
        $this.RecalcRAMBudget()
        
        $srcDrive = $this.GetDriveType($source)
        $dstDrive = $this.GetDriveType($destination)
        $this.Strategy = $this.SelectStrategy($analysis, $srcDrive, $dstDrive)
        
        $srcRoot = if (Test-Path $source -PathType Container) { $source } else { [System.IO.Path]::GetDirectoryName($source) }
        
        # Sortuj: małe najpierw (szybkie parallel), duże potem (sequential)
        $smallFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $largeFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
        foreach ($f in $analysis.Files) {
            if ($f.Length -le $this.SmallFileThreshold) { $smallFiles.Add($f) }
            else { $largeFiles.Add($f) }
        }
        
        # ═══ FAZA 1: Małe pliki — PARALLEL z RAM buffer ═══
        if ($smallFiles.Count -gt 0) {
            $this.CopySmallFilesParallel($smallFiles, $srcRoot, $destination, $move)
        }
        
        # ═══ FAZA 2: Duże pliki — SEQUENTIAL z dużym buforem ═══
        if ($largeFiles.Count -gt 0 -and -not $this.IsCancelled) {
            $this.CopyLargeFilesStream($largeFiles, $srcRoot, $destination, $move)
        }
        
        $this.Timer.Stop()
        $elapsed = $this.Timer.Elapsed
        $avgSpeed = if ($elapsed.TotalSeconds -gt 0) { [Math]::Round(($this.CopiedBytes / 1MB) / $elapsed.TotalSeconds, 1) } else { 0 }
        
        return @{
            Success = ($this.FailedFiles -eq 0)
            TotalFiles = $this.TotalFiles
            CopiedFiles = $this.CopiedFiles
            FailedFiles = $this.FailedFiles
            TotalMB = [Math]::Round($this.TotalBytes / 1MB, 1)
            CopiedMB = [Math]::Round($this.CopiedBytes / 1MB, 1)
            Elapsed = $elapsed.ToString("mm\:ss\.f")
            AvgSpeedMBps = $avgSpeed
            Strategy = $this.Strategy
            Errors = $this.Errors
        }
    }
    
    # ═══ MAŁE PLIKI — PARALLEL (RunspacePool) ═══
    [void] CopySmallFilesParallel([System.Collections.Generic.List[System.IO.FileInfo]]$files, [string]$srcRoot, [string]$dst, [bool]$move) {
        $pool = [System.Management.Automation.Runspaces.RunspacePool]::CreateRunspacePool(1, $this.ParallelThreads)
        $pool.Open()
        
        $jobs = [System.Collections.Generic.List[hashtable]]::new()
        $batchBytes = [long]0
        
        # Grupuj w batche po RAMBufferMaxMB
        $batch = [System.Collections.Generic.List[hashtable]]::new()
        
        foreach ($fi in $files) {
            if ($this.IsCancelled) { break }
            
            $relativePath = $fi.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
            $dstPath = [System.IO.Path]::Combine($dst, $relativePath)
            
            $batch.Add(@{ Src = $fi.FullName; Dst = $dstPath; Size = $fi.Length; Move = $move; Timestamps = $this.PreserveTimestamps })
            $batchBytes += $fi.Length
            
            # Flush batch gdy pełny lub ostatni plik
            if ($batchBytes -ge ($this.RAMBufferMaxMB * 1MB) -or $fi -eq $files[$files.Count - 1]) {
                foreach ($item in $batch) {
                    $ps = [System.Management.Automation.PowerShell]::Create()
                    $ps.RunspacePool = $pool
                    [void]$ps.AddScript({
                        param($src, $dst, $move, $ts)
                        try {
                            $dstDir = [System.IO.Path]::GetDirectoryName($dst)
                            if (-not [System.IO.Directory]::Exists($dstDir)) {
                                [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null
                            }
                            # RAM buffer: czytaj do pamięci, zapisz na raz
                            $data = [System.IO.File]::ReadAllBytes($src)
                            [System.IO.File]::WriteAllBytes($dst, $data)
                            if ($ts) {
                                $srcInfo = [System.IO.FileInfo]::new($src)
                                [System.IO.File]::SetCreationTime($dst, $srcInfo.CreationTime)
                                [System.IO.File]::SetLastWriteTime($dst, $srcInfo.LastWriteTime)
                            }
                            if ($move) { [System.IO.File]::Delete($src) }
                            return @{ OK = $true; Size = $data.Length }
                        } catch {
                            return @{ OK = $false; Error = $_.Exception.Message; Src = $src }
                        }
                    }).AddArgument($item.Src).AddArgument($item.Dst).AddArgument($item.Move).AddArgument($item.Timestamps)
                    
                    $handle = $ps.BeginInvoke()
                    $jobs.Add(@{ PS = $ps; Handle = $handle; Size = $item.Size })
                }
                
                # Czekaj na batch
                foreach ($job in $jobs) {
                    try {
                        $result = $job.PS.EndInvoke($job.Handle)
                        if ($result -and $result[0].OK) {
                            $this.CopiedFiles++
                            $this.CopiedBytes += $job.Size
                        } else {
                            $this.FailedFiles++
                            if ($result -and $result[0].Error) { $this.Errors.Add($result[0].Error) }
                        }
                    } catch {
                        $this.FailedFiles++
                        $this.Errors.Add("Parallel: $_")
                    }
                    $job.PS.Dispose()
                }
                $jobs.Clear()
                $batch.Clear()
                $batchBytes = 0
                
                # Update speed
                $elapsed = $this.Timer.Elapsed.TotalSeconds
                if ($elapsed -gt 0) { $this.SpeedMBps = [Math]::Round(($this.CopiedBytes / 1MB) / $elapsed, 1) }
            }
        }
        
        $pool.Close()
        $pool.Dispose()
    }
    
    # ═══ DUŻE PLIKI — NativeCopy (FILE_FLAG_NO_BUFFERING + double-buffer) ═══
    # Lokalny dysk: używa Win32 NO_BUFFERING+WRITE_THROUGH — omija cache OS całkowicie
    # Sieć/błąd: fallback do managed FileStream z WriteThrough
    [void] CopyLargeFilesStream([System.Collections.Generic.List[System.IO.FileInfo]]$files, [string]$srcRoot, [string]$dst, [bool]$move) {
        
        foreach ($fi in $files) {
            if ($this.IsCancelled) { break }
            
            $relativePath = $fi.FullName.Substring($srcRoot.Length).TrimStart('\', '/')
            $dstPath = [System.IO.Path]::Combine($dst, $relativePath)
            $this.CurrentFile = $fi.Name
            
            try {
                $dstDir = [System.IO.Path]::GetDirectoryName($dstPath)
                if (-not [System.IO.Directory]::Exists($dstDir)) {
                    [System.IO.Directory]::CreateDirectory($dstDir) | Out-Null
                }
                
                # Sprawdź czy lokalne dyski — NativeCopy nie działa na sieciowych udziałach
                $srcIsLocal = -not $fi.FullName.StartsWith('\\')
                $dstIsLocal = -not $dstPath.StartsWith('\\')
                $nativeAvail = ([System.Management.Automation.PSTypeName]'NativeCopy').Type -ne $null
                
                if ($srcIsLocal -and $dstIsLocal -and $nativeAvail) {
                    # ─── ŚCIEŻKA NATYWNA: NO_BUFFERING+WRITE_THROUGH+double-buffer ───
                    # Omija Windows Cache Manager całkowicie — dane: dysk→RAM→dysk
                    # Chunk = 25% wolnego RAM (RecalcRAMBudget ustawia LargeChunkBytes)
                    $chunkMB = [int]($this.LargeChunkBytes / 1MB)
                    if ($chunkMB -lt 16) { $chunkMB = 16 }    # min 16MB per chunk
                    if ($chunkMB -gt 2048) { $chunkMB = 2048 } # max 2GB per chunk
                    
                    $progress = [long[]]@(0)
                    $result = _Invoke-NativeCopy $fi.FullName $dstPath $chunkMB $progress
                    
                    if ($result -eq 'OK') {
                        $this.CopiedBytes += $fi.Length
                        $this.CopiedFiles++
                    } else {
                        # Fallback do managed I/O jeśli native się wysypie
                        $this.Errors.Add("NativeCopy fallback '$($fi.Name)': $result")
                        $this._CopyFileManaged($fi, $dstPath)
                    }
                } else {
                    # ─── ŚCIEŻKA MANAGED: sieć lub NativeCopy niedostępne ───
                    $this._CopyFileManaged($fi, $dstPath)
                }
                
                if ($this.PreserveTimestamps) {
                    [System.IO.File]::SetCreationTime($dstPath, $fi.CreationTime)
                    [System.IO.File]::SetLastWriteTime($dstPath, $fi.LastWriteTime)
                }
                
                if ($move -and -not $this.IsCancelled) { [System.IO.File]::Delete($fi.FullName) }
                
                # Aktualizuj prędkość
                $elapsed = $this.Timer.Elapsed.TotalSeconds
                if ($elapsed -gt 0) { $this.SpeedMBps = [Math]::Round(($this.CopiedBytes / 1MB) / $elapsed, 1) }
                
            } catch {
                $this.FailedFiles++
                $this.Errors.Add("Stream '$($fi.Name)': $_")
            }
        }
    }
    
    # Managed fallback: FileStream z WriteThrough (tylko gdy NativeCopy niedostępne lub błąd)
    hidden [void] _CopyFileManaged([System.IO.FileInfo]$fi, [string]$dstPath) {
        $chunkBuf = [byte[]]::new($this.LargeChunkBytes)
        $srcStream = [System.IO.FileStream]::new(
            $fi.FullName,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read,
            [int][Math]::Min($this.LargeBufferSize, [int]::MaxValue),
            [System.IO.FileOptions]::SequentialScan)
        $dstStream = [System.IO.FileStream]::new(
            $dstPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            [int][Math]::Min($this.LargeBufferSize, [int]::MaxValue),
            [System.IO.FileOptions]::WriteThrough)
        try {
            $totalInChunk = 0
            do {
                $n = $srcStream.Read($chunkBuf, $totalInChunk, [int]($this.LargeChunkBytes - $totalInChunk))
                $totalInChunk += $n
                if ($n -le 0 -or $totalInChunk -ge $this.LargeChunkBytes) {
                    if ($totalInChunk -gt 0) {
                        $dstStream.Write($chunkBuf, 0, $totalInChunk)
                        $this.CopiedBytes += $totalInChunk
                        $totalInChunk = 0
                    }
                }
            } while ($n -gt 0 -and -not $this.IsCancelled)
        } finally {
            $dstStream.Flush(); $dstStream.Dispose(); $srcStream.Dispose()
            $chunkBuf = $null
        }
        $this.CopiedFiles++
    }
    
    # ═══ PROGRESS INFO ═══
    [hashtable] GetProgress() {
        $elapsed = $this.Timer.Elapsed.TotalSeconds
        $percent = if ($this.TotalBytes -gt 0) { [Math]::Round(($this.CopiedBytes / $this.TotalBytes) * 100, 1) } else { 0 }
        $eta = 0
        if ($this.SpeedMBps -gt 0 -and $this.TotalBytes -gt $this.CopiedBytes) {
            $remainMB = ($this.TotalBytes - $this.CopiedBytes) / 1MB
            $eta = [int]($remainMB / $this.SpeedMBps)
        }
        return @{
            Percent = $percent
            CopiedMB = [Math]::Round($this.CopiedBytes / 1MB, 1)
            TotalMB = [Math]::Round($this.TotalBytes / 1MB, 1)
            Files = "$($this.CopiedFiles)/$($this.TotalFiles)"
            SpeedMBps = $this.SpeedMBps
            ETA = $eta
            CurrentFile = $this.CurrentFile
            Strategy = $this.Strategy
            Failed = $this.FailedFiles
        }
    }
    
    [void] Cancel() { $this.IsCancelled = $true }
    
    [void] Reset() {
        $this.TotalBytes = 0; $this.CopiedBytes = 0
        $this.TotalFiles = 0; $this.CopiedFiles = 0; $this.FailedFiles = 0
        $this.SpeedMBps = 0; $this.CurrentFile = ""
        $this.IsCancelled = $false
        $this.Errors.Clear()
        $this.Timer.Reset()
    }
}

# ═══ HELPER: Invoke-FastCopy — wrapper do wywołania z ENGINE/CLI ═══
function Invoke-FastCopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Move,
        [switch]$Verify,
        [switch]$NoProgress
    )
    
    $fc = [FastFileCopy]::new()
    if ($Verify) { $fc.VerifyAfterCopy = $true }
    
    $analysis = $fc.AnalyzeSource($Source)
    $strategy = $fc.SelectStrategy($analysis, $fc.GetDriveType($Source), $fc.GetDriveType($Destination))
    $totalMB   = [Math]::Round($analysis.TotalBytes / 1MB, 1)
    $chunkMB   = [Math]::Round($fc.LargeChunkBytes / 1MB, 0)
    $budgetMB  = $fc.RAMBufferMaxMB
    $freeMB    = $fc.GetFreeRAMMB()
    
    Write-Host "═══ FastCopy (RAM-Cache) ═══" -ForegroundColor Cyan
    Write-Host "  Source:   $Source" -ForegroundColor White
    Write-Host "  Dest:     $Destination" -ForegroundColor White
    Write-Host "  Files:    $($analysis.TotalFiles) ($totalMB MB) [$($analysis.SmallFiles) small + $($analysis.LargeFiles) large]" -ForegroundColor White
    Write-Host "  Strategy: $strategy | Threads: $($fc.ParallelThreads)" -ForegroundColor Yellow
    Write-Host "  RAM:      wolne=${freeMB}MB  budzet=${budgetMB}MB  chunk-duze=${chunkMB}MB  stream-buf=$([Math]::Round($fc.LargeBufferSize/1MB,0))MB" -ForegroundColor Cyan
    Write-Host ""
    
    $result = $fc.Copy($Source, $Destination, $Move.IsPresent)
    
    # Wynik
    Write-Host ""
    if ($result.Success) {
        Write-Host "✓ DONE: $($result.CopiedFiles) files ($($result.CopiedMB) MB) in $($result.Elapsed) @ $($result.AvgSpeedMBps) MB/s [$($result.Strategy)]" -ForegroundColor Green
    } else {
        Write-Host "✗ ERRORS: $($result.FailedFiles) failed, $($result.CopiedFiles) OK" -ForegroundColor Red
        foreach ($err in $result.Errors) { Write-Host "  - $err" -ForegroundColor Red }
    }
    
    return $result
}

class DesktopWidget {
    [string] $DataFile
    [bool] $Running
    DesktopWidget() {
        $this.DataFile = "C:\CPUManager\WidgetData.json"
        $this.Running = $false
    }
    [void] UpdateData([hashtable]$metrics) {
        # Sprawdz tryb storage
        if ($Script:UseRAMStorage -and $Script:SharedRAM) {
            # Tryb RAM - zapisz do RAMManager
            try {
                $Script:SharedRAM.Write("WidgetData", $metrics)
            } catch {
                try { "$((Get-Date).ToString('o')) - DesktopWidget.UpdateData [RAM] ERROR: $_" | Out-File -FilePath 'C:\CPUManager\ErrorLog.txt' -Append -Encoding utf8 } catch { }
            }
        } else {
            # Tryb JSON - zapisz do pliku
            try {
                $json = $metrics | ConvertTo-Json -Depth 10 -Compress
                $fs = New-Object System.IO.FileStream($this.DataFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                $writer = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8)
                $writer.Write($json)
                $writer.Flush()
                $writer.Dispose()
                $fs.Dispose()
            } catch {
                try { "$((Get-Date).ToString('o')) - DesktopWidget.UpdateData [JSON] ERROR: $_" | Out-File -FilePath 'C:\CPUManager\ErrorLog.txt' -Append -Encoding utf8 } catch { }
            }
        }
    }
    [void] Start() {
        $this.Running = $true
        # Mozna dodac logike uruchamiania procesu widgetu, jesli nie dziala
    }
    [void] Stop() {
        $this.Running = $false
        # Mozna dodac logike zamykania procesu widgetu
    }
    [void] Toggle() {
        if ($this.Running) {
            $this.Stop()
        } else {
            $this.Start()
        }
    }
    [bool] IsRunning() {
        return $this.Running
    }
}
class WebDashboard {
    [object] $Runspace
    [object] $PowerShell
    [int] $Port
    [bool] $Running
    [string] $DataFile
    WebDashboard([int]$port) {
        $this.Port = $port
        $this.Running = $false
        $this.DataFile = "C:\CPUManager\DashboardData.json"
    }
    [void] Start() {
        try {
            $serverPort = $this.Port
            $dataFilePath = $this.DataFile
            # Create runspace for background HTTP server
            $this.Runspace = [runspacefactory]::CreateRunspace()
            $this.Runspace.Open()
            $this.PowerShell = New-TrackedPowerShell 'WebDashboard'
            $this.PowerShell.Runspace = $this.Runspace
            $this.PowerShell.AddScript({
                param($Port, $DataFile)
                $listener = New-Object System.Net.HttpListener
                $listener.Prefixes.Add("http://localhost:$Port/")
                try {
                    $listener.Start()
                    while ($listener.IsListening) {
                        try {
                            $context = $listener.GetContext()
                            $response = $context.Response
                            # Read data from file
                            $d = @{ CPU=0; Temp=50; Mode="Balanced"; Activity="Idle"; Context="Idle"; Iteration=0; CPUHistory=@(0); TempHistory=@(50); Brain="0w"; QLearning=""; Bandit=""; Genetic=""; Ensemble=""; Energy=""; RAM=0; DiskIO=0; NetDL=0; NetUL=0; CpuMHz=0; AI="ON"; CPUType="Unknown"; CPUName="Unknown" }
                            if (Test-Path $DataFile) {
                                try {
                                    $json = [System.IO.File]::ReadAllText($DataFile)
                                    $loaded = $json | ConvertFrom-Json
                                    $d.CPU = $loaded.CPU
                                    $d.Temp = $loaded.Temp
                                    $d.Mode = $loaded.Mode
                                    $d.Activity = $loaded.Activity
                                    $d.Context = $loaded.Context
                                    $d.Iteration = $loaded.Iteration
                                    $d.CPUHistory = @($loaded.CPUHistory)
                                    $d.TempHistory = @($loaded.TempHistory)
                                    $d.Brain = $loaded.Brain
                                    $d.QLearning = $loaded.QLearning
                                    $d.Bandit = $loaded.Bandit
                                    $d.Genetic = $loaded.Genetic
                                    $d.Ensemble = $loaded.Ensemble
                                    $d.Energy = $loaded.Energy
                                    if ($loaded.RAM) { $d.RAM = $loaded.RAM }
                                    if ($loaded.DiskIO) { $d.DiskIO = $loaded.DiskIO }
                                    if ($loaded.NetDL) { $d.NetDL = $loaded.NetDL }
                                    if ($loaded.NetUL) { $d.NetUL = $loaded.NetUL }
                                    if ($loaded.CpuMHz) { $d.CpuMHz = $loaded.CpuMHz }
                                    if ($loaded.AI) { $d.AI = $loaded.AI }
                                    if ($loaded.CPUType) { $d.CPUType = $loaded.CPUType } else { $d.CPUType = "Unknown" }
                                    if ($loaded.CPUName) { $d.CPUName = $loaded.CPUName } else { $d.CPUName = "Unknown" }
                                } catch { }
                            }
                            $cpuJson = "[$($d.CPUHistory -join ',')]"
                            $tempJson = "[$($d.TempHistory -join ',')]"
                            $modeClass = $d.Mode.ToLower()
                            $cpuGHz = if ($d.CpuMHz -gt 0) { "{0:N2}" -f ($d.CpuMHz/1000) } else { "-.--" }
                            $netDLFmt = if ($d.NetDL -ge 1048576) { "{0:N1} MB/s" -f ($d.NetDL/1048576) } elseif ($d.NetDL -ge 1024) { "{0:N0} KB/s" -f ($d.NetDL/1024) } else { "{0:N0} B/s" -f $d.NetDL }
                            $netULFmt = if ($d.NetUL -ge 1048576) { "{0:N1} MB/s" -f ($d.NetUL/1048576) } elseif ($d.NetUL -ge 1024) { "{0:N0} KB/s" -f ($d.NetUL/1024) } else { "{0:N0} B/s" -f $d.NetUL }
                            $html = @"
<!DOCTYPE html><html><head><title>CPU Manager AI</title><meta charset="UTF-8"><meta http-equiv="refresh" content="2">
<script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
<style>*{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:linear-gradient(135deg,#1a1a2e,#16213e);color:#fff;min-height:100vh;padding:20px}.header{text-align:center;padding:20px;background:rgba(255,255,255,0.1);border-radius:15px;margin-bottom:20px}.header h1{color:#00d9ff;font-size:2em}.status{color:#0f0;font-size:1.2em;margin-top:10px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:20px}.card{background:rgba(255,255,255,0.05);border-radius:15px;padding:20px;border:1px solid rgba(255,255,255,0.1)}.card h2{color:#00d9ff;margin-bottom:15px}.metric{display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid rgba(255,255,255,0.1)}.metric:last-child{border-bottom:none}.label{color:#aaa}.value{font-weight:bold}.turbo{color:#ff6b6b}.balanced{color:#ffd93d}.silent{color:#6bcb77}.chart-container{height:200px;margin-top:15px}.ai-status{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin-top:10px}.ai-item{background:rgba(0,217,255,0.1);padding:10px;border-radius:8px;text-align:center}.ai-item .name{font-size:0.8em;color:#aaa}.ai-item .val{font-size:1.1em;font-weight:bold;color:#00d9ff}.hw-grid{display:grid;grid-template-columns:repeat(2,1fr);gap:15px;margin-top:10px}.hw-item{background:rgba(255,255,255,0.05);padding:12px;border-radius:10px;text-align:center}.hw-item .hw-val{font-size:1.4em;font-weight:bold;color:#00d9ff}.hw-item .hw-lbl{font-size:0.8em;color:#888;margin-top:4px}</style></head>
<body><div class="header"><h1> CPU Manager AI</h1><div class="status">AI: $($d.AI) | Mode: <span class="$modeClass">$($d.Mode)</span> | CPU: $($d.CPUType) | Iteration: $($d.Iteration)</div></div>
<div class="grid">
<div class="card"><h2>- Processor</h2><div class="metric"><span class="label">Model</span><span class="value" style="font-size:0.9em">$($d.CPUName)</span></div><div class="metric"><span class="label">Type</span><span class="value">$($d.CPUType)</span></div><div class="metric"><span class="label">Current Speed</span><span class="value">$cpuGHz GHz</span></div></div>
<div class="card"><h2> System Metrics</h2>
<div class="hw-grid">
<div class="hw-item"><div class="hw-val">$($d.CPU)%</div><div class="hw-lbl">CPU Usage</div></div>
<div class="hw-item"><div class="hw-val">$($d.Temp)°C</div><div class="hw-lbl">Temperature</div></div>
<div class="hw-item"><div class="hw-val">$cpuGHz GHz</div><div class="hw-lbl">CPU Speed</div></div>
<div class="hw-item"><div class="hw-val">$($d.RAM)%</div><div class="hw-lbl">RAM Usage</div></div>
<div class="hw-item"><div class="hw-val">$($d.DiskIO) MB/s</div><div class="hw-lbl">Disk I/O</div></div>
<div class="hw-item"><div class="hw-val $modeClass">$($d.Mode)</div><div class="hw-lbl">Power Mode</div></div>
</div>
<div class="metric" style="margin-top:15px"><span class="label">Activity</span><span class="value">$($d.Activity)</span></div>
<div class="metric"><span class="label">Context</span><span class="value">$($d.Context)</span></div>
<div class="metric"><span class="label">Network DL</span><span class="value">$netDLFmt</span></div>
<div class="metric"><span class="label">Network UL</span><span class="value">$netULFmt</span></div>
</div>
<div class="card"><h2> AI Learning & Status</h2><div class="metric"><span class="label"> Mode Switches</span><span class="value">$($d.ModeSwitches)</span></div><div class="metric"><span class="label">- Active Apps</span><span class="value">$($d.AppsDetected)</span></div><div class="metric"><span class="label"> Runtime</span><span class="value">$($d.Runtime) min</span></div><h3 style="color:#00d9ff;margin:15px 0 10px 0;font-size:0.9em">AI Components:</h3><div class="ai-status">
<div class="ai-item"><div class="name">Brain</div><div class="val">$($d.Brain)</div></div>
<div class="ai-item"><div class="name">Q-Learning</div><div class="val">$($d.QLearning)</div></div>
<div class="ai-item"><div class="name">Bandit</div><div class="val">$($d.Bandit)</div></div>
<div class="ai-item"><div class="name">Genetic</div><div class="val">$($d.Genetic)</div></div>
<div class="ai-item"><div class="name">Ensemble</div><div class="val">$($d.Ensemble)</div></div>
<div class="ai-item"><div class="name">Energy</div><div class="val">$($d.Energy)</div></div></div></div>
<div class="card"><h2> CPU History (last 60)</h2><div class="chart-container"><canvas id="cpuChart"></canvas></div></div>
<div class="card"><h2>- Temp History</h2><div class="chart-container"><canvas id="tempChart"></canvas></div></div></div>
<script>const cpuData=$cpuJson;const tempData=$tempJson;const labels=Array.from({length:Math.max(cpuData.length,1)},(_,i)=>i);
new Chart(document.getElementById('cpuChart'),{type:'line',data:{labels:labels,datasets:[{data:cpuData,borderColor:'#00d9ff',backgroundColor:'rgba(0,217,255,0.1)',fill:true,tension:0.3,pointRadius:0}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{y:{min:0,max:100,grid:{color:'rgba(255,255,255,0.1)'}},x:{display:false}}}});
new Chart(document.getElementById('tempChart'),{type:'line',data:{labels:labels,datasets:[{data:tempData,borderColor:'#ff6b6b',backgroundColor:'rgba(255,107,107,0.1)',fill:true,tension:0.3,pointRadius:0}]},options:{responsive:true,maintainAspectRatio:false,plugins:{legend:{display:false}},scales:{y:{min:30,max:100,grid:{color:'rgba(255,255,255,0.1)'}},x:{display:false}}}});</script></body></html>
"@
                            $buffer = [System.Text.Encoding]::UTF8.GetBytes($html)
                            $response.ContentType = "text/html; charset=utf-8"
                            $response.ContentLength64 = $buffer.Length
                            $response.OutputStream.Write($buffer, 0, $buffer.Length)
                            $response.OutputStream.Close()
                        } catch { Start-Sleep -Milliseconds 50 }
                    }
                } catch { } finally {
                    try { $listener.Stop(); $listener.Close() } catch { }
                }
            }).AddArgument($serverPort).AddArgument($dataFilePath)
            $this.PowerShell.BeginInvoke() | Out-Null
            $null = $this.PowerShell
            $this.Running = $true
        } catch {
            $this.Running = $false
        }
    }
    [void] UpdateData([hashtable]$data) {
        try {
            $json = $data | ConvertTo-Json -Depth 10 -Compress
            $tmp = "$($this.DataFile).tmp"
            [System.IO.File]::WriteAllText($tmp, $json, [System.Text.Encoding]::UTF8)
            try { Move-Item -Path $tmp -Destination $this.DataFile -Force -ErrorAction Stop } catch { Copy-Item -Path $tmp -Destination $this.DataFile -Force; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        } catch { 
            try { "$((Get-Date).ToString('o')) - DesktopWidget.UpdateData ERROR: $_" | Out-File -FilePath $Script:ErrorLogPath -Append -Encoding utf8 } catch { }
        }
    }
    [void] Stop() {
        try {
            $this.Running = $false
            if ($this.PowerShell) { $this.PowerShell.Stop(); $this.PowerShell.Dispose() }
            if ($this.Runspace) { $this.Runspace.Close(); $this.Runspace.Dispose() }
        } catch { }
    }
}
function Register-CPUManagerTask {
    param(
        [string]$ScriptPath = $MyInvocation.MyCommand.Path,
        [switch]$Remove
    )
    $taskName = "CPUManagerAI_AutoStart"
    if ($Remove) {
        try {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Host " Task removed: $taskName" -ForegroundColor Green
            return $true
        } catch {
            Write-Host "- Failed to remove task: $_" -ForegroundColor Red
            return $false
        }
    }
    try {
        # Usun istniejace zadanie
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        # Utworz nowe zadanie
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn
        $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        Write-Host " Auto-start registered: $taskName" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "- Failed to register task: $_" -ForegroundColor Red
        return $false
    }
}
function Test-CPUManagerTaskExists {
    try {
        $task = Get-ScheduledTask -TaskName "CPUManagerAI_AutoStart" -ErrorAction SilentlyContinue
        return ($task -ne $null)
    } catch {
        return $false
    }
}
# POWER CONTROL - Dynamic scaling
$Script:LastPowerMode = ""
$Script:LastPowerMax = -1
$Script:PowerPlanGUID = $null
# PRZYWRACANIE DOMYSLNYCH PLANOW ZASILANIA WINDOWS
function Restore-DefaultPowerPlans {
    <#
    .SYNOPSIS
    Przywraca domyslne plany zasilania Windows przy zamykaniu programu.
    Resetuje Min/Max CPU do domyslnych wartosci i ustawia plan Balanced.
    #>
    try {
        Write-Host "   Przywracanie domyslnych ustawien zasilania..." -ForegroundColor Yellow
        # Domyslne GUIDy planow Windows
        $balancedGUID = "381b4222-f694-41f0-9685-ff5bb260df2e"
        $powerSaverGUID = "a1841308-3541-4fab-bc81-f71556f20b4a"
        $highPerfGUID = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
        # Subgroup i settings dla CPU
        $cpuSubgroup = "54533251-82be-4824-96c1-47b60b740d00"
        $minCpuSetting = "893dee8e-2bef-41e0-89c6-b55d0929964c"
        $maxCpuSetting = "bc5038f7-23e0-4960-96da-33abaf5935ec"
        # Domyslne wartosci Windows
        $defaultMin = 5    # 5% minimum
        $defaultMax = 100  # 100% maximum
        # Przywroc domyslne wartosci dla planu Balanced
        $null = powercfg /setacvalueindex $balancedGUID $cpuSubgroup $minCpuSetting $defaultMin 2>$null
        $null = powercfg /setacvalueindex $balancedGUID $cpuSubgroup $maxCpuSetting $defaultMax 2>$null
        $null = powercfg /setdcvalueindex $balancedGUID $cpuSubgroup $minCpuSetting $defaultMin 2>$null
        $null = powercfg /setdcvalueindex $balancedGUID $cpuSubgroup $maxCpuSetting $defaultMax 2>$null
        # Przywroc domyslne wartosci dla planu Power Saver (jesli istnieje)
        $null = powercfg /setacvalueindex $powerSaverGUID $cpuSubgroup $minCpuSetting 5 2>$null
        $null = powercfg /setacvalueindex $powerSaverGUID $cpuSubgroup $maxCpuSetting 100 2>$null
        $null = powercfg /setdcvalueindex $powerSaverGUID $cpuSubgroup $minCpuSetting 5 2>$null
        $null = powercfg /setdcvalueindex $powerSaverGUID $cpuSubgroup $maxCpuSetting 100 2>$null
        # Przywroc domyslne wartosci dla planu High Performance (jesli istnieje)
        $null = powercfg /setacvalueindex $highPerfGUID $cpuSubgroup $minCpuSetting 100 2>$null
        $null = powercfg /setacvalueindex $highPerfGUID $cpuSubgroup $maxCpuSetting 100 2>$null
        $null = powercfg /setdcvalueindex $highPerfGUID $cpuSubgroup $minCpuSetting 100 2>$null
        $null = powercfg /setdcvalueindex $highPerfGUID $cpuSubgroup $maxCpuSetting 100 2>$null
        # Aktywuj plan Balanced
        $null = powercfg /setactive $balancedGUID 2>$null
        # Jesli byl uzyty inny plan (np. utworzony przez skrypt), tez go zresetuj
        if ($Script:PowerPlanGUID -and $Script:PowerPlanGUID -ne $balancedGUID) {
            $null = powercfg /setacvalueindex $Script:PowerPlanGUID $cpuSubgroup $minCpuSetting $defaultMin 2>$null
            $null = powercfg /setacvalueindex $Script:PowerPlanGUID $cpuSubgroup $maxCpuSetting $defaultMax 2>$null
            $null = powercfg /setdcvalueindex $Script:PowerPlanGUID $cpuSubgroup $minCpuSetting $defaultMin 2>$null
            $null = powercfg /setdcvalueindex $Script:PowerPlanGUID $cpuSubgroup $maxCpuSetting $defaultMax 2>$null
        }
        Write-Host "   Plan zasilania 'Balanced' przywrocony (CPU: 5-100%)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "  [WARN] Nie udalo sie przywrocic planow zasilania: $_" -ForegroundColor Red
        return $false
    }
}
function Set-PowerMode {
    param(
        [string]$Mode,
        [int]$CurrentCPU = 50,
        [switch]$HardLock
    )
    if ([string]::IsNullOrWhiteSpace($Mode)) { return }
    # ═══ AMD: RyzenADJ (bezpośredni TDP) ═══
    if ($Script:RyzenAdjAvailable -and $Script:CPUType -eq "AMD") {
        Set-RyzenAdjMode $Mode | Out-Null
        # AMD nadal potrzebuje powercfg jako backup (affinity zarządzane przez RyzenAdj)
        $powerStates = Get-PowerStates
        $state = $powerStates[$Mode]
        if ($state -and ($Script:LastPowerMode -ne $Mode -or $Script:LastPowerMax -ne $state.Max)) {
            try {
                if (-not $Script:PowerPlanGUID) {
                    $output = powercfg /getactivescheme 2>$null
                    if ($output -match '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') {
                        $Script:PowerPlanGUID = $matches[1]
                    }
                }
                if ($Script:PowerPlanGUID) {
                    $guid = $Script:PowerPlanGUID
                    $subgroup = "54533251-82be-4824-96c1-47b60b740d00"
                    powercfg /setacvalueindex $guid $subgroup "893dee8e-2bef-41e0-89c6-b55d0929964c" $state.Min 2>$null
                    powercfg /setacvalueindex $guid $subgroup "bc5038f7-23e0-4960-96da-33abaf5935ec" $state.Max 2>$null
                    powercfg /setdcvalueindex $guid $subgroup "893dee8e-2bef-41e0-89c6-b55d0929964c" $state.Min 2>$null
                    powercfg /setdcvalueindex $guid $subgroup "bc5038f7-23e0-4960-96da-33abaf5935ec" $state.Max 2>$null
                    powercfg /setactive $guid 2>$null
                }
            } catch {}
        }
    }
    # ═══ INTEL: Własny mechanizm ENGINE (IntelPowerManager) ═══
    elseif ($Script:CPUType -eq "Intel" -and $Script:IntelPM -and $Script:IntelPM.Available) {
        Set-IntelPowerMode -PM $Script:IntelPM -Mode $Mode
    }
    # ═══ FALLBACK: nieznany CPU — powercfg jako ostatnia deska ═══
    elseif ($Script:CPUType -ne "AMD") {
        $powerStates = Get-PowerStates
        $state = $powerStates[$Mode]
        if ($state -and ($Script:LastPowerMode -ne $Mode -or $Script:LastPowerMax -ne $state.Max)) {
            try {
                if (-not $Script:PowerPlanGUID) {
                    $output = powercfg /getactivescheme 2>$null
                    if ($output -match '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') {
                        $Script:PowerPlanGUID = $matches[1]
                    }
                }
                if ($Script:PowerPlanGUID) {
                    $guid = $Script:PowerPlanGUID
                    $subgroup = "54533251-82be-4824-96c1-47b60b740d00"
                    powercfg /setacvalueindex $guid $subgroup "893dee8e-2bef-41e0-89c6-b55d0929964c" $state.Min 2>$null
                    powercfg /setacvalueindex $guid $subgroup "bc5038f7-23e0-4960-96da-33abaf5935ec" $state.Max 2>$null
                    powercfg /setdcvalueindex $guid $subgroup "893dee8e-2bef-41e0-89c6-b55d0929964c" $state.Min 2>$null
                    powercfg /setdcvalueindex $guid $subgroup "bc5038f7-23e0-4960-96da-33abaf5935ec" $state.Max 2>$null
                    powercfg /setactive $guid 2>$null
                }
            } catch {}
        }
    }
    # ═══ Tracking ═══
    if ($Script:LastPowerMode -ne $Mode) {
        if ($Global:DebugMode) {
            $method = if ($Script:CPUType -eq "AMD") { "RyzenAdj" } 
                      elseif ($Script:CPUType -eq "Intel" -and $Script:IntelPM) { "IntelPM" } 
                      else { "powercfg" }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] MODE: $($Script:LastPowerMode) -> $Mode [$method] CPU:$CurrentCPU%" -ForegroundColor Gray
        }
        $Global:LastLoggedMode = $Mode
        $Global:ModeChangeCount++
        $Script:LastPowerMode = $Mode
        $Script:LastPowerMax = 0
    }
}
# FILE OPERATIONS - FIXED z obsluga bledow
function Save-State {
    param(
        [NeuralBrain]$Brain, 
        [ProphetMemory]$Prophet
    )
    if ($null -eq $Brain -or $null -eq $Prophet) { return $false }
    $success = $true
    # Powod: Dane Brain moga istniec z poprzedniej sesji - nie tracimy ich
    try {
        $brainData = @{
            Weights = $Brain.Weights
            AggressionBias = $Brain.AggressionBias
            ReactivityBias = $Brain.ReactivityBias
            LastLearned = $Brain.LastLearned
            LastLearnTime = $Brain.LastLearnTime    # v39 FIX: Dodano brakujace pole
            TotalDecisions = $Brain.TotalDecisions
            RAMWeight = $Brain.RAMWeight            # v39 FIX: Dodano brakujace pole
        }
        $json = $brainData | ConvertTo-Json -Depth 3 -Compress
        [System.IO.File]::WriteAllText($Script:BrainPath, $json, [System.Text.Encoding]::UTF8)
    } catch { $success = $false }
    try {
        $prophetData = @{
            Apps = @{}
            LastActiveApp = $Prophet.LastActiveApp
            TotalSessions = $Prophet.TotalSessions
            HourlyActivity = $Prophet.HourlyActivity
            MinSamplesForConfidence = $Prophet.MinSamplesForConfidence
        }
        $cacheLimit = if ($Script:ProphetCacheLimit -gt 0) { $Script:ProphetCacheLimit } else { 50 }
        $appList = $Prophet.Apps.Keys | ForEach-Object {
            @{ Name = $_; LastSeen = $Prophet.Apps[$_].LastSeen; Launches = $Prophet.Apps[$_].Launches }
        }
        # Sort by LastSeen (newest first), then by Launches
        $sortedApps = $appList | Sort-Object { $_.LastSeen } -Descending | Select-Object -First $cacheLimit
        $keepApps = @{}
        foreach ($a in $sortedApps) { $keepApps[$a.Name] = $true }
        foreach ($appName in $Prophet.Apps.Keys) {
            if (-not $keepApps.ContainsKey($appName)) { continue }
            $app = $Prophet.Apps[$appName]
            $prophetData.Apps[$appName] = @{
                Name = $app.Name
                ProcessName = $app.ProcessName
                Launches = $app.Launches
                AvgCPU = $app.AvgCPU
                AvgIO = $app.AvgIO
                MaxCPU = $app.MaxCPU
                MaxIO = $app.MaxIO
                Category = $app.Category
                LastSeen = $app.LastSeen
                HourHits = $app.HourHits
                PrevApps = $app.PrevApps
                IsHeavy = $app.IsHeavy
                Samples = if ($app.ContainsKey('Samples')) { $app.Samples } else { 0 }
                SessionRuntime = if ($app.ContainsKey('SessionRuntime')) { $app.SessionRuntime } else { 0.0 }
            }
        }
        $json = $prophetData | ConvertTo-Json -Depth 5 -Compress
        [System.IO.File]::WriteAllText($Script:ProphetPath, $json, [System.Text.Encoding]::UTF8)
    } catch { $success = $false }
    return [bool]$success
}
function Load-State {
    $brain = [NeuralBrain]::new()
    $prophet = [ProphetMemory]::new()
    $gpuBound = [GPUBoundDetector]::new()  # v42.1: GPU-Bound Detector
    # Powod: Dane Brain moga istniec z poprzedniej sesji - zachowujemy je
    if (Test-Path $Script:BrainPath) {
        try {
            $json = [System.IO.File]::ReadAllText($Script:BrainPath, [System.Text.Encoding]::UTF8)
            $data = $json | ConvertFrom-Json
            if ($data.Weights) {
                $data.Weights.PSObject.Properties | ForEach-Object {
                    $brain.Weights[$_.Name] = [double]$_.Value
                }
            }
            if ($null -ne $data.AggressionBias) { $brain.AggressionBias = [double]$data.AggressionBias }
            if ($null -ne $data.ReactivityBias) { $brain.ReactivityBias = [double]$data.ReactivityBias }
            if ($data.LastLearned) { $brain.LastLearned = $data.LastLearned }
            if ($data.LastLearnTime) { $brain.LastLearnTime = $data.LastLearnTime }  # v39 FIX: Dodano
            if ($null -ne $data.TotalDecisions) { $brain.TotalDecisions = [int]$data.TotalDecisions }
            if ($null -ne $data.RAMWeight) { $brain.RAMWeight = [double]$data.RAMWeight }  # v39 FIX: Dodano
        } catch { }
    }
    if (Test-Path $Script:ProphetPath) {
        try {
            $json = [System.IO.File]::ReadAllText($Script:ProphetPath, [System.Text.Encoding]::UTF8)
            $data = $json | ConvertFrom-Json
            if ($data.Apps) {
                $loadedCount = 0
                $data.Apps.PSObject.Properties | ForEach-Object {
                    $appName = $_.Name  # v39 FIX: Zachowaj nazwe PRZED wewnetrzna petla
                    $appData = $_.Value
                    $app = @{
                        Name = $appData.Name
                        ProcessName = $appData.ProcessName
                        Launches = [int]$appData.Launches
                        AvgCPU = [double]$appData.AvgCPU
                        AvgIO = [double]$appData.AvgIO
                        MaxCPU = [double]$appData.MaxCPU
                        MaxIO = [double]$appData.MaxIO
                        Category = $appData.Category
                        LastSeen = $appData.LastSeen
                        HourHits = if ($appData.HourHits) { [int[]]$appData.HourHits } else { [int[]]::new(24) }
                        PrevApps = @{}
                        IsHeavy = [bool]$appData.IsHeavy
                        Samples = if ($appData.Samples) { [int]$appData.Samples } else { 0 }
                        SessionRuntime = if ($appData.SessionRuntime) { [double]$appData.SessionRuntime } else { 0.0 }
                    }
                    if ($appData.PrevApps) {
                        $appData.PrevApps.PSObject.Properties | ForEach-Object {
                            $prevName = $_.Name  # v39 FIX: Osobna zmienna dla wewnetrznej petli
                            $app.PrevApps[$prevName] = [int]$_.Value
                        }
                    }
                    $prophet.Apps[$appName] = $app  # v39 FIX: Uzywaj zachowanej nazwy
                    $loadedCount++
                }
                Write-Host "  Prophet: Loaded $loadedCount apps from ProphetMemory.json" -ForegroundColor Green
            } else {
                Write-Host "  Prophet: Apps section empty or missing in ProphetMemory.json" -ForegroundColor Yellow
            }
            if ($data.LastActiveApp) { $prophet.LastActiveApp = $data.LastActiveApp }
            if ($null -ne $data.TotalSessions) { $prophet.TotalSessions = [int]$data.TotalSessions }
            if ($data.HourlyActivity) { $prophet.HourlyActivity = [int[]]$data.HourlyActivity }
            if ($data.MinSamplesForConfidence) { $prophet.MinSamplesForConfidence = [int]$data.MinSamplesForConfidence }
        } catch {
            Write-Host "  Prophet: Load error - $_" -ForegroundColor Red
        }
    } else {
        Write-Host "  Prophet: ProphetMemory.json not found (new installation)" -ForegroundColor Yellow
    }
    return @{ Brain = $brain; Prophet = $prophet; GPUBound = $gpuBound }
}
# UI RENDERING
function Draw-ProgressBar {
    param([int]$Value, [int]$MaxValue = 100, [int]$Width = 20)
    $Value = [Math]::Max(0, [Math]::Min($MaxValue, $Value))
    $filled = [Math]::Min($Width, [Math]::Round(($Value / $MaxValue) * $Width))
    $empty = $Width - $filled
    $fillChar = [char]0x2588  # Full block
    $emptyChar = [char]0x2591  # Light shade
    return ($fillChar.ToString() * $filled + $emptyChar.ToString() * $empty)
}
function Render-UI {
    param(
        $Metrics, $State, $AIDecision, $Watcher, $Brain, $Prophet,
        $TempSource, $PredictedLoad, $AnomalyAlert, $PriorityCount = 0,
        $SelfTunerStatus = "", $ChainPrediction = "", $TurboThreshold = 75, $BalancedThreshold = 30,
        $ActivityStatus = "Unknown", $ContextStatus = "Idle", $ThermalStatus = "", 
        $UserPatternStatus = "", $TimerStatus = "2Hz",
        $GPUInfo = $null, $VRMTemp = 0, $CPUPower = 0, $ExplainerReason = ""
    )
    # FIX: Instead of Clear-Host use SetCursorPosition - eliminates flickering
    try { [Console]::SetCursorPosition(0, 0) } catch { Clear-Host }
    # Get console width for padding line endings
    $consoleWidth = try { [Console]::WindowWidth - 1 } catch { 120 }
    $lines = [System.Collections.Generic.List[string]]::new()
    $aiStatus = if ($Global:AI_Active) { "- AI ON" } else { "- MANUAL" }
    $debugStatus = if ($Global:DebugMode) { " [DEBUG]" } else { "" }
    $lines.Add(" [STATUS AI] $aiStatus$debugStatus | Sessions: $($Prophet.TotalSessions) | Time: $((Get-Date).ToString('HH:mm'))")
    $lines.Add("")
    $icon = switch($State) { "Turbo" { "^^" } "Balanced" { "==" } "Silent" { ".." } default { "??" } }
    $powerInfo = if ($Script:LastPowerMax -gt 0) { " [Max:$($Script:LastPowerMax)%]" } else { "" }
    $lines.Add(" [POWER STATE] $icon $State$powerInfo - $($AIDecision.Reason)")
    $lines.Add("")
    # - RyzenADJ TDP Info
    if ($Script:RyzenAdjAvailable -and $Script:CurrentTDP.STAPM -gt 0) {
        $lines.Add(" [TDP] STAPM=$($Script:CurrentTDP.STAPM)W Fast=$($Script:CurrentTDP.Fast)W Slow=$($Script:CurrentTDP.Slow)W Tctl=$($Script:CurrentTDP.Tctl)C")
    }
    # === CPU / GPU / SENSORS (single-line) ===
    $cpuPowerStr = if ($CPUPower -gt 0) { " ${CPUPower}W" } else { "" }
    $sensorsParts = @()
    if ($null -eq $Metrics.CPU) {
        $sensorsParts += ("CPU: N/A$cpuPowerStr (no data)")
    } else {
        $sensorsParts += ("CPU: $($Metrics.CPU)%$cpuPowerStr")
    }
    if ($GPUInfo -and $GPUInfo.Load -gt 0) {
        $gpuTempStr = if ($GPUInfo.Temp -gt 0) { " ${GPUInfo.Temp}°C" } else { "" }
        $gpuPowerStr = if ($GPUInfo.Power -gt 0) { " ${GPUInfo.Power}W" } else { "" }
        $sensorsParts += ("GPU: $($GPUInfo.Load)%$gpuTempStr$gpuPowerStr")
    } elseif ($GPUInfo -and $GPUInfo.Temp -gt 0) {
        $sensorsParts += ("GPU: iGPU $($GPUInfo.Temp)°C")
    }
    $trendIcon = if ($AIDecision.Trend -gt 3) { '^^' }
                 elseif ($AIDecision.Trend -gt 0) { '^' }
                 elseif ($AIDecision.Trend -lt -3) { 'vv' }
                 elseif ($AIDecision.Trend -lt 0) { 'v' }
                 else { '->' }
    $tempDisplay = if ($Metrics.Temp -gt 0) { "$($Metrics.Temp)°C" } else { "N/A" }
    $tempSourceShort = switch ($TempSource) {
        "LibreHardwareMonitor" { "LHM" }
        "OpenHardwareMonitor" { "OHM" }
        "WMI-ACPI" { "ACPI" }
        default { "UNK" }
    }
    $vrmStr = if ($VRMTemp -gt 0) { " VRM: ${VRMTemp}°C" } else { "" }
    $sensorsParts += ("I/O: $($Metrics.IO) MB/s")
    $sensorsParts += ("Temp: $tempDisplay [$tempSourceShort]$vrmStr")
    $sensorsParts += ("Trend: $trendIcon")
    $lines.Add(" [SENSORS] " + ($sensorsParts -join ' | '))
    $lines.Add("")
    if ($Global:AI_Active) {
        $pressureBar = Draw-ProgressBar -Value ([Math]::Min(100, $AIDecision.Score))
        $lines.Add(" [AI ENGINE]")
        $lines.Add("   Pressure: [$pressureBar] $($AIDecision.Score)")
        # FIX: Total Decisions = sum from ALL AI engines (not just Neural Brain)
        $totalDecisions = $qLearning.TotalUpdates + $bandit.TotalPulls + $genetic.Generation + 
                          $selfTuner.DecisionHistory.Count + $chainPredictor.TotalPredictions + 
                          $Prophet.GetAppCount() + $Brain.TotalDecisions
        # Bias: If Neural Brain active, show its bias, otherwise "N/A"
        $biasDisplay = if ($Brain.TotalDecisions -gt 0) { 
            [Math]::Round($Brain.AggressionBias, 2) 
        } else { 
            "N/A" 
        }
        $lines.Add("   Bias: $biasDisplay | Decisions: $totalDecisions")
        $lines.Add("")
    }
    $lines.Add(" [ADVANCED AI]")
    $lines.Add("   - Ensemble: $($ensemble.TotalVotes) |  Neural Brain: $($Brain.GetCount())")
    $lines.Add("")
    $lines.Add(" [CORE AI]")
    $qStates = if ($qLearning.QTable) { $qLearning.QTable.Count } else { 0 }
    $qExplore = [Math]::Round($qLearning.ExplorationRate * 100)
    $banditStatus = $bandit.GetStatus()
    $energyEff = [Math]::Round($energyTracker.CurrentEfficiency * 100)
    $selfTuneGood = $selfTuner.GoodDecisions
    $selfTuneTotal = $selfTuner.TotalEvaluations
    $chainCorrect = $chainPredictor.CorrectPredictions
    $chainTotal = $chainPredictor.TotalPredictions
    $lines.Add("   Prophet: $($Prophet.GetAppCount()) apps | QLearning: $qStates states Exp:$qExplore% | Bandit: $banditStatus | Genetic: Gen$($genetic.Generation) | Energy: Eff:$energyEff% | SelfTuner: $selfTuneGood/$selfTuneTotal good | Chain: $chainCorrect/$chainTotal correct")
    $lines.Add("   - Bandit Meta: $($bandit.GetEngineStatus())")  #  v39: RAM-Driven Meta-Selector
    $predBar = Draw-ProgressBar -Value ([Math]::Min(100, $PredictedLoad)) -Width 10
    $anomalyStatus = if ([string]::IsNullOrWhiteSpace($AnomalyAlert)) { "- OK" } else { "[WARN] $AnomalyAlert" }
    $lines.Add("    Load Pred: [$predBar] $([Math]::Round($PredictedLoad))% | - Anomaly: $anomalyStatus")
    # Self-Tuner info
    $lines.Add("   - Self-Tune: T>$([Math]::Round($TurboThreshold)) B>$([Math]::Round($BalancedThreshold))")
    # Chain Predictor info
    $chainDisplay = if ([string]::IsNullOrWhiteSpace($ChainPrediction)) { "Learning..." } else { $ChainPrediction }
    $lines.Add("   - Next App: $chainDisplay")
    # Context & Thermal
    $lines.Add("    Context: $ContextStatus | - $ThermalStatus")
    # Activity & Timer
    $activityIcon = if ($ActivityStatus -eq "Active") { "[*]" } else { "[ ]" }
    $lines.Add("   $activityIcon User: $ActivityStatus |  Rate: $TimerStatus |  Patterns: $UserPatternStatus")
    # Explainer Reason
    if (-not [string]::IsNullOrWhiteSpace($ExplainerReason)) {
        $lines.Add("    Why: $ExplainerReason")
    }
    $lines.Add("")
    $lines.Add(" [LEARNED]")
    $lines.Add("    Learned applications are listed here.")
    if ($Watcher.IsBoosting) {
        $lines.Add("    BOOSTING: $($Watcher.BoostDisplayName) [$($Watcher.GetBoostRemainingSeconds())s]")
        $lines.Add("      Peak: CPU=$([Math]::Round($Watcher.PeakCPU))% IO=$([Math]::Round($Watcher.PeakIO))")
    } elseif (![string]::IsNullOrWhiteSpace($Brain.LastLearned)) {
        $lines.Add("   - Last learned: $($Brain.LastLearned) @ $($Brain.LastLearnTime)")
    } else {
        $lines.Add("    Waiting for new applications...")
    }
    $lines.Add("")
    $lines.Add(" [ACTIVITY]")
    for ($i = 0; $i -lt 4; $i++) {
        $entry = if ($i -lt $Script:ActivityLog.Count) { $Script:ActivityLog[$i] } else { "" }
        if ($entry.Length -gt 72) { $entry = $entry.Substring(0, 69) + "..." }
        $lines.Add("   $entry")
    }
    $lines.Add("")
    if ($Global:DebugMode) {
        $lines.Add(" [DEBUG LOG]")
        for ($i = 0; $i -lt 5; $i++) {
            $entry = if ($i -lt $Script:DebugLog.Count) { $Script:DebugLog[$i] } else { "" }
            if ($entry.Length -gt 72) { $entry = $entry.Substring(0, 69) + "..." }
            $lines.Add("   $entry")
        }
        $lines.Add("")
    }
    $lines.Add(" [CONTROLS]")
    $lines.Add("   [1] Turbo  [2] Balanced  [3] Silent  [0] AUTO  [5] AI Toggle  [Q/Esc] Quit")
    $lines.Add("   [S] Save  [I] Info  [L] Logs  [R] Reset Brain  [D] Debug  [H] Widget")
    $lines.Add("   [W] Web  [G] Genetic  [B] Bandit  [9] AutoStart  [P] Predict  [A] Anomaly")
    $lines.Add("   [T] Temp  [C] Chain  [E] Efficiency  [X] GPU/Thermal  [F12] Database")
    $lines.Add("")
    $lines.Add(" [HINT] Press key for action. [X] shows GPU & Thermal status.")
    foreach ($line in $lines) { Write-Host $line.PadRight($consoleWidth) }
}
function Show-Database {
    param([ProphetMemory]$Prophet)
    Clear-Host
    Write-Host ""
    Write-Host "  #" -ForegroundColor Magenta
    Write-Host "  -                     APPLICATION DATABASE                               ?" -ForegroundColor Magenta
    Write-Host "  #" -ForegroundColor Magenta
    Write-Host ""
    if ($Prophet.Apps.Count -eq 0) {
        Write-Host "     Database is empty." -ForegroundColor DarkGray
    } else {
        Write-Host ("     " + "NAME".PadRight(32) + "| RUNS | AVG% | MAX% | CLASS") -ForegroundColor Yellow
        Write-Host "     --------------------------------+------+------+------+-------" -ForegroundColor DarkGray
        $Prophet.Apps.Values | Sort-Object { $_.Launches } -Descending | Select-Object -First 20 | ForEach-Object {
            $cat = $_.Category -replace "^LEARNING_", "[L] "
            $line = "     " + $_.Name.PadRight(32) + "| " + $_.Launches.ToString().PadLeft(4) + " | " + ([Math]::Round($_.AvgCPU,0)).ToString().PadLeft(4) + " | " + $_.MaxCPU.ToString().PadLeft(4) + " | " + $cat
            Write-Host $line -ForegroundColor Gray
        }
    }
    Write-Host ""
    Write-Host "  Press any key to return..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# MAIN EXECUTION - FIXED z garbage collection i cleanup