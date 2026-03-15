# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 04_Config_Functions.ps1
# Config functions, RyzenAdj functions, Intel power, AI engine control, data sources
# Lines 1878-5547 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
# STORAGE MODE CONFIG - RAM vs JSON
$Script:StorageModeConfigPath = "C:\CPUManager\StorageMode.json"
function Get-StorageMode {
    try {
        if (Test-Path $Script:StorageModeConfigPath) {
            $config = Get-Content $Script:StorageModeConfigPath -Raw | ConvertFrom-Json
            if ($config.Mode) {
                # New format: "JSON" / "RAM" / "BOTH"
                return $config.Mode
            } elseif ($null -ne $config.UseRAM) {
                if ($config.UseJSON -and $config.UseRAM) {
                    return "BOTH"  #  FIX: bylo tylko "RAM"
                } elseif ($config.UseRAM) {
                    return "RAM"
                } else {
                    return "JSON"
                }
            }
        }
    } catch { }
    return "JSON"  # Default: JSON mode
}
function Set-StorageMode {
    param([string]$Mode)  # "JSON" / "RAM" / "BOTH"
    try {
        # v40.2 FIX: Zapisuj ZARÓWNO Mode jak i UseJSON/UseRAM (kompatybilność z StorageModeManager.LoadMode)
        $useJSON = ($Mode -eq "JSON" -or $Mode -eq "BOTH")
        $useRAM = ($Mode -eq "RAM" -or $Mode -eq "BOTH")
        @{ Mode = $Mode; UseJSON = $useJSON; UseRAM = $useRAM } | ConvertTo-Json | Set-Content $Script:StorageModeConfigPath -Force
        $Script:StorageMode = $Mode
        # Reinicjalizuj RAMManager jesli RAM lub BOTH
        if (($Mode -eq "RAM" -or $Mode -eq "BOTH") -and -not $Script:SharedRAM) {
            $Script:SharedRAM = [RAMManager]::new("MainEngine")
        }
        return $true
    } catch {
        return $false
    }
}
# #
# #
$Script:StorageManager = [StorageModeManager]::new(
    "C:\CPUManager\WidgetData.json",
    "C:\CPUManager\StorageMode.json"
)
Write-Host " Storage: JSON=$($Script:StorageManager.UseJSON) RAM=$($Script:StorageManager.UseRAM)" -ForegroundColor Green
$Script:ThermalGuard = [ReactiveThermalGuard]::new()
$Script:ThermalGuard.EmergencyTemp = 82   # v40.3: Obniżone z 95 — wentylatory nie szaleją
$Script:ThermalGuard.CriticalTemp = 90    # v40.3: Obniżone z 100 — chroni CPU ZANIM się przegrzeje
$Script:ThermalGuard.RecoveryTemp = 72    # v40.3: Obniżone z 85 — czekaj na spokojne chłodzenie
Write-Host " ThermalGuard: Emergency=82°C Critical=90°C Recovery=72°C" -ForegroundColor Green
$Script:RyzenVerifier = $null
$Script:ThermalEmergencyActive = $false
$Script:LastVerifiedTDP = $null
if ($Script:RyzenAdjAvailable -and $Script:RyzenAdjPath) {
    $Script:RyzenVerifier = [RyzenAdjVerifier]::new($Script:RyzenAdjPath)
    if ($Script:RyzenVerifier.Available) {
        Write-Host " RyzenVerifier: Enabled" -ForegroundColor Green
    }
}
# RyzenADJ async cache + lock
if (-not $Script:RyzenAdjLock) { $Script:RyzenAdjLock = New-Object System.Object }
if (-not $Script:RyzenAdjCache) { $Script:RyzenAdjCache = @{ Info = $null; InfoTime = $null; LastApplyResult = $null; LastApplyTime = $null; LastJob = $null } }
if (-not $Script:RyzenInfoPollMs) { $Script:RyzenInfoPollMs = 10000 }
if (-not $Script:LastRyzenInfoPollTime) { $Script:LastRyzenInfoPollTime = [DateTime]::MinValue }
# Inicjalizacja
$Script:StorageMode = Get-StorageMode
$Script:SharedRAM = $null
$Script:UseRAMStorage = $false  # v39.4 FIX: Initialize UseRAMStorage flag
if ($Script:StorageMode -eq "RAM" -or $Script:StorageMode -eq "BOTH") {
    $Script:SharedRAM = [RAMManager]::new("MainEngine")
    $Script:UseRAMStorage = $true  # v39.4 FIX: Enable RAM storage
    $backupInfo = if ($Script:StorageMode -eq "RAM") { "backup every 5 min" } else { "backup every 1 min" }
    Write-Host "  [RAM] Storage mode: $($Script:StorageMode) ($backupInfo)" -ForegroundColor Cyan
} else {
    Write-Host "  [JSON] Storage mode: JSON (AI auto-save every 5 min)" -ForegroundColor Cyan
}
if (-not $Script:WarmCacheTimestamps) { $Script:WarmCacheTimestamps = @{} }
if (-not $Script:WarmCacheCooldownSec) { $Script:WarmCacheCooldownSec = 300 }

function SafeWarm {
    param([string]$appName)
    if ([string]::IsNullOrWhiteSpace($appName)) { return }
    try {
        $now = Get-Date
        if (-not $Script:WarmCacheTimestamps.ContainsKey($appName) -or ((Get-Date) - $Script:WarmCacheTimestamps[$appName]).TotalSeconds -gt $Script:WarmCacheCooldownSec) {
            try { [void]$performanceBooster.WarmDiskCache($appName) } catch {}
            $Script:WarmCacheTimestamps[$appName] = $now
        }
    } catch { }
}
# ROTACJA LOGOW - limituj rozmiar do 5MB
function Rotate-ErrorLog {
    try {
        if (Test-Path $script:ErrorLogPath) {
            $logSize = (Get-Item $script:ErrorLogPath).Length / 1MB
            if ($logSize -gt 5) {
                $backupPath = $script:ErrorLogPath + ".old"
                Remove-ExistingFiles @($backupPath)
                Move-Item $script:ErrorLogPath $backupPath -Force
                Ensure-FileExists $script:ErrorLogPath
                "[$(Get-Date -f 'yyyy-MM-dd HH:mm:ss')] ErrorLog rotated - backup: $backupPath" | Out-File -FilePath $script:ErrorLogPath -Encoding utf8
            }
        }
    } catch { }
}
# Wykonaj rotacje na starcie
Rotate-ErrorLog
$global:ErrorActionPreference = "Continue"
# Inicjalizacja sciezki logow
$Script:LogDir = "C:\CPUManager"
$null = Ensure-DirectoryExists $Script:LogDir
$Global:LogFile = Join-Path $Script:LogDir "CPUManager_$(Get-Date -Format 'yyyy-MM-dd').log"
try { $Host.UI.RawUI.WindowTitle = "CPU Manager AI ULTRA" } catch { }
# Domyslne katalogi konfiguracyjne (upewnij sie ze istnieja przed operacjami sygnalowymi)
if (-not $Script:ConfigDir) { $Script:ConfigDir = "C:\CPUManager" }
$null = Ensure-DirectoryExists $Script:ConfigDir
# Cache folder na dysku — persistent preload data between reboots
$Script:CacheDir = Join-Path $Script:ConfigDir "Cache"
$null = Ensure-DirectoryExists $Script:CacheDir
# --- Ustawienie sciezki do pliku TDPConfig.json oraz funkcji ladowania ---
$Script:TDPConfigPath = Join-Path $Script:ConfigDir 'TDPConfig.json'
function Load-TDPConfig {
    param([string]$Path)
    if (-not $Path) { return $false }
    if (-not (Test-Path $Path)) { return $false }
    try {
        $json = Get-Content $Path -Raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $Script:TDPProfiles) {
            $Script:TDPProfiles = @{}
        }
        foreach ($mode in @('Silent','Balanced','Turbo','Extreme')) {
            $node = $null
            try { $node = $json.$mode } catch { $node = $null }
            if ($null -ne $node) {
                # Ensure existing profile exists to fall back to
                if (-not $Script:TDPProfiles[$mode]) { $Script:TDPProfiles[$mode] = @{ STAPM = 0; Fast = 0; Slow = 0; Tctl = 85 } }
                $cur = $Script:TDPProfiles[$mode]
                $Script:TDPProfiles[$mode] = @{ 
                    STAPM = if ($node.STAPM -ne $null) { [int]$node.STAPM } else { $cur.STAPM }
                    Fast   = if ($node.Fast -ne $null)  { [int]$node.Fast }  else { $cur.Fast }
                    Slow   = if ($node.Slow -ne $null)  { [int]$node.Slow }  else { $cur.Slow }
                    Tctl   = if ($node.Tctl -ne $null)  { [int]$node.Tctl }  else { $cur.Tctl }
                }
            }
        }
        foreach ($mode in @('Silent','Balanced','Turbo','Extreme')) {
            if ($Script:TDPProfiles[$mode]) {
                $validation = Validate-TDP -TDPProfile $Script:TDPProfiles[$mode] -Mode $mode
                $Script:TDPProfiles[$mode] = $validation.Profile
                if (-not $validation.Safe) {
                    Write-Log " TDP Safety: $mode profile exceeded HARD LIMITS - values were capped" "TDP-SAFETY"
                }
            }
        }
        # Synchronizuj Performance z Extreme (fallback to Turbo if Extreme missing)
        if ($Script:TDPProfiles['Extreme']) {
            try { $Script:TDPProfiles['Performance'] = $Script:TDPProfiles['Extreme'].Clone() } catch { $Script:TDPProfiles['Performance'] = $Script:TDPProfiles['Extreme'] }
        } elseif ($Script:TDPProfiles['Turbo']) {
            $Script:TDPProfiles['Performance'] = $Script:TDPProfiles['Turbo']
        }
        if ($json.Turbo -and $json.Turbo.STAPM) { $Script:TurboSTAPM = [int]$json.Turbo.STAPM }
        # Loguj zaladowane wartosci dla diagnostyki
        foreach ($m in @('Silent','Balanced','Turbo','Extreme')) {
            try { $p = $Script:TDPProfiles[$m]; if ($p) { Write-Log "TDP profile loaded: $m STAPM=$($p.STAPM)W Fast=$($p.Fast)W Slow=$($p.Slow)W Tctl=$($p.Tctl)C" "TDP" } } catch {}
        }
        Write-Log "Zaladowano TDPConfig.json z Konfiguratora" "TDP"
        return $true
    } catch {
        Write-Log "Blad ladowania TDPConfig.json: $_" "WARN"
        return $false
    }
}
# Wczytaj od razu przy starcie (jesli istnieje)
try { Load-TDPConfig -Path $Script:TDPConfigPath | Out-Null } catch {}
# ═══════════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════════
$Script:AppCategoriesPath = Join-Path $Script:ConfigDir 'AppCategories.json'
$Script:AppCategoryPreferences = @{}
function Load-AppCategories {
    <#
    .SYNOPSIS
    Wczytuje AppCategories.json z CONFIGURATOR
    Zawiera preferencje użytkownika dotyczące kategoryzacji aplikacji
    #>
    param([string]$Path)
    if (-not $Path) { $Path = $Script:AppCategoriesPath }
    if (-not (Test-Path $Path)) { return $false }
    try {
        $json = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json
        # Wczytaj UserPreferences
        if ($json.UserPreferences) {
            $Script:AppCategoryPreferences = @{}
            foreach ($prop in $json.UserPreferences.PSObject.Properties) {
                $appName = $prop.Name
                $pref = $prop.Value
                
                $Script:AppCategoryPreferences[$appName] = @{
                    Bias = if ($pref.Bias -ne $null) { [double]$pref.Bias } else { 0.5 }
                    Confidence = if ($pref.Confidence -ne $null) { [double]$pref.Confidence } else { 0.7 }
                    Samples = if ($pref.Samples -ne $null) { [int]$pref.Samples } else { 1 }
                    LastUsed = if ($pref.LastUsed) { $pref.LastUsed } else { "" }
                    HardLock = if ($pref.HardLock -ne $null) { [bool]$pref.HardLock } else { $false }
                }
            }
            Write-Log "AppCategories loaded: $($Script:AppCategoryPreferences.Count) apps with preferences" "CONFIG"
            
            # v43.10b: DEBUG - log wszystkie aplikacje z HardLock
            $hardLockApps = @()
            foreach ($key in $Script:AppCategoryPreferences.Keys) {
                if ($Script:AppCategoryPreferences[$key].HardLock) {
                    $bias = $Script:AppCategoryPreferences[$key].Bias
                    $mode = if ($bias -le 0.2) { "Silent" } elseif ($bias -ge 0.8) { "Turbo" } else { "Balanced" }
                    $hardLockApps += "$key=$mode"
                }
            }
            if ($hardLockApps.Count -gt 0) {
                Write-Log " AppCategories HardLock apps: $($hardLockApps -join ', ')" "CONFIG"
            }
        }
        return $true
    } catch {
        Write-Log "Error loading AppCategories: $_" "WARN"
        return $false
    }
}
# Wczytaj AppCategories przy starcie
try { 
    $loaded = Load-AppCategories
    if ($loaded) {
        Write-DebugLog "AppCategories.json loaded successfully at startup" "CONFIG" "INFO"
    } else {
        Write-DebugLog "AppCategories.json NOT FOUND at startup - file: $Script:AppCategoriesPath" "CONFIG" "WARN"
    }
} catch {
    Write-DebugLog "AppCategories.json FAILED to load: $_" "CONFIG" "ERROR"
}
# Timer do odświeżania AppCategories.json (co 10s)
$global:LastAppCategoriesWrite = $null
if (Test-Path $Script:AppCategoriesPath) { $global:LastAppCategoriesWrite = (Get-Item $Script:AppCategoriesPath).LastWriteTime }
$global:AppCategoriesRefreshTimer = [System.Timers.Timer]::new(10000)
$global:AppCategoriesRefreshTimer.AutoReset = $true
$global:AppCategoriesRefreshTimer.Add_Elapsed({
    try {
        if (Test-Path $Script:AppCategoriesPath) {
            $now = (Get-Item $Script:AppCategoriesPath).LastWriteTime
            if ($global:LastAppCategoriesWrite -eq $null -or $now -ne $global:LastAppCategoriesWrite) {
                $global:LastAppCategoriesWrite = $now
                Load-AppCategories | Out-Null
                Write-Log "AppCategories.json changed - reloaded preferences" "CONFIG"
            }
        }
    } catch { Write-Log "Error refreshing AppCategories: $_" "WARN" }
})
$global:AppCategoriesRefreshTimer.Start()
# Funkcja pomocnicza - pobiera bias dla aplikacji z preferencji użytkownika
function Get-AppCategoryBias {
    <#
    .SYNOPSIS
    Zwraca bias (preferencję mocy) dla aplikacji z AppCategories.json
    Bias > 0.5 = więcej mocy, Bias < 0.5 = mniej mocy
    #>
    param([string]$AppName)
    if (-not $AppName) { return 0.5 }
    $appLower = $AppName.ToLower() -replace '\.exe$', ''
    # Sprawdź czy mamy preferencje dla tej aplikacji
    if ($Script:AppCategoryPreferences -and $Script:AppCategoryPreferences.Count -gt 0) {
        foreach ($key in $Script:AppCategoryPreferences.Keys) {
            $keyLower = $key.ToLower() -replace '\.exe$', ''
            if ($keyLower -eq $appLower -or $appLower -like "*$keyLower*" -or $keyLower -like "*$appLower*") {
                $pref = $Script:AppCategoryPreferences[$key]
                if ($pref.HardLock) {
                    # HardLock = użytkownik wymusił kategorię - używaj tego!
                    return $pref.Bias
                }
                # Zwykła preferencja - używaj z confidence
                return $pref.Bias
            }
        }
    }
    # Brak preferencji - zwróć neutralny bias
    return 0.5
}
#  PERFORMANCE FIX: Usunieto dedykowany timer TDPConfig.json
#  TDPConfig jest teraz monitorowany TYLKO przez reload.signal (wydajniejsze)
#  Eliminuje podwojne sprawdzanie i zmniejsza obciazenie I/O

# USTAWIENIE KODOWANIA KONSOLI NA UTF-8 (dla emoji/ikon)
try {
    # Ustaw strone kodowa na UTF-8
    chcp 65001 | Out-Null
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }
# Funkcja odbudowy cache ikon Windows
function Rebuild-IconCache {
    try {
        Write-Log "Rozpoczynam odbudowę cache ikon Windows..." "INFO"
        $explorer = Get-Process explorer -ErrorAction SilentlyContinue
        if ($explorer) {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
        $userProfile = [Environment]::GetFolderPath("UserProfile")
        $iconCacheFiles = @("IconCache.db", "IconCache_*.db", "ThumbCache_*.db")
        foreach ($pattern in $iconCacheFiles) {
            Get-ChildItem -Path "$userProfile\AppData\Local" -Filter $pattern -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 1
        Start-Process explorer.exe
        Write-Log "Odbudowa cache ikon zakończona." "INFO"
    } catch {
        Write-Log "Błąd podczas odbudowy cache ikon: $_" "ERROR"
    }
}
# CLEANUP SIGNAL FILES ON STARTUP - CRITICAL!
# Usun stare pliki sygnalowe ktore mogly zostac po poprzedniej sesji
$signalDir = $Script:ConfigDir
$signalFiles = @(
    "$signalDir\shutdown.signal",
    "$signalDir\reload.signal",
    "$signalDir\WidgetCommand.txt",
    "$signalDir\Widget.pid"
)
Remove-FilesIfExist $signalFiles
# Odbuduj cache ikon Windows na starcie
Rebuild-IconCache
# Reset WidgetData.json to default values on startup
# NOTE: Avoid unconditional overwrite -- only create defaults when file is missing or empty.
$widgetDataPath = Join-Path $signalDir 'WidgetData.json'
try {
    if (-not (Test-Path $widgetDataPath) -or ((Get-Item $widgetDataPath).Length -eq 0)) {
        $defaultWidget = @{
            CPU = 0
            Temp = 0
            Mode = "BALANCED"
            AI = $false
            Context = "Init"
            Activity = "Starting"
            App = "CPUManager"
            Iteration = 0
        }
        $defaultWidget | ConvertTo-Json -Depth 6 | Set-Content $widgetDataPath -Force -ErrorAction SilentlyContinue
        Write-Log "WidgetData.json: utworzono domyslny plik (brak lub pusty)" "INFO"
    } else {
        Write-Log "WidgetData.json: istnieje -- pomijam nadpisanie." "INFO"
    }
} catch { Write-Log "WidgetData.json: blad przy tworzeniu domyslnego pliku: $_" "ERROR" }
# AUTO-KOPIOWANIE SKRYPTU DO C:\CPUManager\ (jesli uruchamiany z innego miejsca)
try {
    $targetDir = "C:\CPUManager"
    $targetScript = Join-Path $targetDir "CPUManager_v40.ps1"
    $currentScript = $MyInvocation.MyCommand.Path
    # Upewnij sie ze folder istnieje
    Ensure-DirectoryExists $targetDir
    # Jesli skrypt jest uruchamiany spoza C:\CPUManager - skopiuj go
    if ($currentScript -and (Test-Path $currentScript)) {
        $currentDir = Split-Path -Parent $currentScript
        if ($currentDir -ne $targetDir) {
            # Skopiuj skrypt do C:\CPUManager
            Copy-Item -Path $currentScript -Destination $targetScript -Force
            Write-Host "  [OK] Skrypt skopiowany do $targetDir" -ForegroundColor Green
        }
    }
    # Utworz tez Start_CPUManager.bat jesli nie istnieje
    $batFile = Join-Path $targetDir "Start_CPUManager.bat"
    if (-not (Test-Path $batFile)) {
        $batContent = @"
@echo off
title CPU Manager AI ULTRA
cd /d "$targetDir"
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$targetScript"
pause
"@
        [System.IO.File]::WriteAllText($batFile, $batContent)
    }
} catch { }
# TWORZENIE SKROTU NA PULPICIE (przy pierwszym uruchomieniu)
try {
    $desktopPath = [Environment]::GetFolderPath("Desktop")
    $shortcutPath = Join-Path $desktopPath "CPU Manager AI.lnk"
    # Sprawdz czy skrot juz istnieje
    if (-not (Test-Path $shortcutPath)) {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($shortcutPath)
        # Sprawdz czy istnieje EXE w roznych lokalizacjach
        $exePaths = @(
            "C:\CPUManager\CPUManagerAI.exe",
            (Join-Path $PSScriptRoot "CPUManagerAI.exe"),
            (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "CPUManagerAI.exe")
        )
        $foundExe = Find-FirstExistingPath $exePaths
        if ($foundExe) {
            # Mamy EXE - uzyj go
            $Shortcut.TargetPath = $foundExe
            $Shortcut.WorkingDirectory = Split-Path -Parent $foundExe
        } else {
            # Brak EXE - uzyj skryptu PS1
            $ps1Paths = @(
                "C:\CPUManager\CPUManager_v40.ps1",
                $MyInvocation.MyCommand.Path
            )
            $foundPs1 = Find-FirstExistingPath $ps1Paths
            if ($foundPs1) {
                $Shortcut.TargetPath = "powershell.exe"
                $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$foundPs1`""
                $Shortcut.WorkingDirectory = Split-Path -Parent $foundPs1
            }
        }
        $Shortcut.Description = "CPU Manager AI ULTRA"
        $Shortcut.Save()
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($WshShell) | Out-Null
    }
} catch { }
# AUTOMATYCZNE USTAWIENIE ROZMIARU OKNA
try {
    # Wymagane wymiary: ustawione zgodnie z preferencjami użytkownika
    $targetWidth = 161
    $targetHeight = 41
    # Pobierz maksymalny rozmiar okna
    $maxSize = $Host.UI.RawUI.MaxPhysicalWindowSize
    # Ogranicz do maksymalnego rozmiaru
    $newWidth = [Math]::Min($targetWidth, $maxSize.Width)
    $newHeight = [Math]::Min($targetHeight, $maxSize.Height)
    # Ustaw bufor (musi byc >= rozmiar okna)
    $bufferSize = $Host.UI.RawUI.BufferSize
    $desiredBufHeight = 9000
    if ($bufferSize.Width -lt $newWidth) {
        $bufferSize.Width = $newWidth + 10
    }
    if ($bufferSize.Height -lt $desiredBufHeight) {
        $bufferSize.Height = [int]$desiredBufHeight  # Duzy bufor dla scrollowania
    }
    $Host.UI.RawUI.BufferSize = $bufferSize
    # Ustaw rozmiar okna
    $windowSize = New-Object System.Management.Automation.Host.Size($newWidth, $newHeight)
    $Host.UI.RawUI.WindowSize = $windowSize
    # Ustaw pozycje okna (lewa gorna czesc ekranu)
    $Host.UI.RawUI.WindowPosition = New-Object System.Management.Automation.Host.Coordinates(0, 0)
} catch {
    # Fallback: uzyj mode con (dziala w CMD i starszych PowerShell)
    try {
        $null = cmd /c "mode con: cols=100 lines=45" 2>$null
    } catch { }
}
function Write-Log {
    param(
        [string]$Message,
        [string]$Type = "INFO"
    )
    # Throttling ustawienia (domyslnie: INFO co 10s)
    if (-not $Script:LogMinIntervalSec) { $Script:LogMinIntervalSec = 60 }
    if (-not $Script:LastLogTime) { $Script:LastLogTime = [DateTime]::MinValue }
    $Timestamp = Get-Date -Format "HH:mm:ss.fff"
    $LogEntry = "[$Timestamp] [$Type] $Message"
    # Kolor konsoli
    $Color = switch ($Type) {
        "BOOST"    { "Yellow" }
        "TURBO"    { "Red" }
        "BALANCED" { "Green" }
        "SILENT"   { "Cyan" }
        "ERROR"    { "DarkRed" }
        "INFO"     { "Gray" }
        default    { "White" }
    }
    # Typy, ktore zawsze logujemy
                               # Set-RyzenAdjMode "Silent" (bledne wywolanie)
    $alwaysLog = @('ERROR','WARN','WARNING','TURBO','BOOST','SUCCESS')
    $now = Get-Date
    $shouldLog = $false
    if ($alwaysLog -contains $Type.ToUpper()) {
        $shouldLog = $true
    } else {
        $elapsed = ($now - $Script:LastLogTime).TotalSeconds
                               # Set-RyzenAdjMode "Balanced" (bledne wywolanie)
        if ($elapsed -ge $Script:LogMinIntervalSec) { $shouldLog = $true }
    }
    if ($shouldLog) {
        Write-Host $LogEntry -ForegroundColor $Color
        try {
            Add-Content -Path $Global:LogFile -Value $LogEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
        # Also forward important messages to the Activity window (if Add-Log is available)
        try {
            if (Get-Command -Name Add-Log -ErrorAction SilentlyContinue) {
                if ($Type.ToUpper() -ne 'DEBUG') {
                        # Prefer concise TDP/activity entries when possible
                        $forward = $null
                        try {
                            if ($Type.ToUpper() -eq 'TDP' -or $Message -match 'RyzenADJ cmd') {
                                if ($Message -match '--stapm-limit=(\d+)') {
                                    $st = [int]($Matches[1]) / 1000
                                    $forward = "TDP - ${st}W"
                                } elseif ($Message -match 'TDP:\s*(\w+)\s*(\d+)') {
                                    $forward = "$($Matches[1]) - $($Matches[2])W"
                                } else {
                                    # Generic short TDP tag
                                    $forward = "TDP: action"
                                }
                            } elseif ($Message -match 'TDP:\s*(\w+)\s*(\d+)') {
                                $forward = "$($Matches[1]) - $($Matches[2])W"
                            }
                        } catch {}
                        if (-not $forward) {
                            # Sanitize multiline or very long messages before forwarding to Activity
                            $forward = $Message -replace "[\r\n]+", ' | '
                            $forward = $forward -replace '\s{2,}', ' '
                            if ($forward.Length -gt 140) { $forward = $forward.Substring(0,137) + '...' }
                        }
                        Add-Log $forward
                }
            }
        } catch {}
        $Script:LastLogTime = $now
    }
}
Write-Log "#" "INFO"
Write-Log "-           CPUManager AI v40 - SESJA STARTUJE                      		      ?" "INFO"
Write-Log "#" "INFO"
Write-Log "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" "INFO"
Write-Log "Log: $Global:LogFile" "INFO"
                               # Set-RyzenAdjMode "Turbo" (bledne wywolanie)
$Global:LastLoggedMode = ""
$Global:BoostCount = 0
$Global:ModeChangeCount = 0
$Global:LastStatsTime = Get-Date
# WIN32 API - Already defined at the top of the script (lines 396-447)
# Global variables for new features
$Global:WebDashboardPort = 8080
# TRAY ICON - Szybkie menu (bez Runspace)
$Script:TrayBaseDir = "C:\CPUManager"
$Script:TrayCommandFile = "$Script:TrayBaseDir\WidgetCommand.txt"
$Script:TrayAIEnginesFile = "$Script:TrayBaseDir\AIEngines.json"
$Script:TrayCPUConfigFile = "$Script:TrayBaseDir\CPUConfig.json"
# Zapisz PID
$pidFile = Join-Path $Script:TrayBaseDir 'CPUManager.pid'
# Funkcje tray
function Start-BackgroundWrite {
    param(
        [string]$Path,
        [string]$Content,
        [string]$Encoding = 'UTF8'
    )
    try {
        $ps = New-TrackedPowerShell 'Start-BackgroundWrite'
        $null = $ps.AddScript({ param($p, $c, $enc)
            $tmp = "$p.tmp"
            $bytes = [System.Text.Encoding]::GetEncoding($enc).GetBytes($c)
            [System.IO.File]::WriteAllBytes($tmp, $bytes)
            try { Move-Item -Path $tmp -Destination $p -Force } catch { Copy-Item -Path $tmp -Destination $p -Force; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }).AddArgument($Path).AddArgument($Content).AddArgument($Encoding)
        $null = $ps.BeginInvoke()
    } catch { try { $Content | Set-Content $Path -Encoding $Encoding -Force } catch {} }
}
# Diagnostic helper: create PowerShell instance and log call stack to file
function New-TrackedPowerShell {
    param([string]$Tag = "unknown")
    try {
        $ps = [powershell]::Create()
        try {
            $preferredDirs = @(
                "C:\CPUManager",
                (Join-Path $env:LOCALAPPDATA 'CPUManager'),
                (Join-Path $env:TEMP 'CPUManager')
            )
            $logDir = $null
            foreach ($d in $preferredDirs) {
                try {
                    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null }
                    $logDir = $d
                    break
                } catch {}
            }
            if (-not $logDir) { $logDir = Join-Path $env:TEMP 'CPUManager'; New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            $logFile = Join-Path $logDir 'ps_create_traces.log'
            try {
                $stack = (Get-PSCallStack -ErrorAction Stop | Out-String).Trim()
            } catch {
                $stack = [Environment]::StackTrace
            }
            $entry = "$(Get-Date -Format o) | Tag=$Tag`n$stack`n---`n"
            Add-Content -Path $logFile -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
        return $ps
    } catch {
        return [powershell]::Create()
    }
}
function Send-TrayCommand { 
    param([string]$Cmd)
    $path = if ($Script:TrayCommandFile) { $Script:TrayCommandFile } else { Join-Path $Script:ConfigDir 'WidgetCommand.txt' }
    try {
        Start-BackgroundWrite $path $Cmd 'UTF8'
    } catch { try { $Cmd | Set-Content $path -Force -ErrorAction SilentlyContinue } catch { } }
}
# After defining helper, write PID atomically in background
try { Start-BackgroundWrite $pidFile $PID 'UTF8' } catch { try { $PID | Out-File -FilePath $pidFile -Encoding UTF8 -Force } catch {} }
# Bezpieczne zadanie zamkniecia aplikacji (ustawia flage zamiast rzucac wyjatek)
function Request-Shutdown {
    param([string]$Reason = "Requested")
    try {
        if (-not $Script:ShutdownRequested) {
            $Script:ShutdownRequested = $true
            Add-Log "Shutdown requested: $Reason" "INFO"
            # Zapisz sygnal takze do pliku, zeby inne skrypty / widgety wiedzialy (format: { Timestamp, Reason })
            try { $sig = @{ Timestamp = (Get-Date).ToString("o"); Reason = $Reason } | ConvertTo-Json -Depth 2; Start-BackgroundWrite $Script:ShutdownSignalPath $sig 'UTF8' } catch {}
        }
    } catch {}
}
function Load-TrayAIEngines {
    if (Test-Path $Script:TrayAIEnginesFile) {
        try { return Get-Content $Script:TrayAIEnginesFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch {}
    }
    return @{ QLearning=$true; Ensemble=$false; Prophet=$true; NeuralBrain=$false; AnomalyDetector=$true; SelfTuner=$true; ChainPredictor=$true; LoadPredictor=$true }
}
function Save-TrayAIEngines {
    param($Engines)
    try {
        if ($Engines -is [hashtable]) { $json = $Engines | ConvertTo-Json } else { $ht = @{}; $Engines.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value }; $json = $ht | ConvertTo-Json }
        Start-BackgroundWrite $Script:TrayAIEnginesFile $json 'UTF8'
    } catch {}
}
function Set-TrayCPUType {
    param([string]$Type)
    $ct = @{CPUType=$Type} | ConvertTo-Json
    Start-BackgroundWrite $Script:TrayCPUConfigFile $ct 'UTF8'
    Send-TrayCommand "CPU_$Type"
}
function Stop-AllProcesses {
    $Script:MainTray.Visible = $false
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and ($_.CommandLine -match 'MiniWidget_v40.ps1|CPUManager_Configurator_v40.ps1|CPUManager_v40.ps1|CPUManagerAI') }
        foreach ($p in $procs) {
            try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {}
        }
    } catch {
        try { Get-Process powershell,pwsh,powershell_ise -ErrorAction SilentlyContinue | Stop-Process -Force } catch {}
    }
}
# Wykryj CPU (wstepnie - dokladne wykrycie pozniej w Detect-CPUType)
$Script:TrayCPUType = "Unknown"
if (Test-Path $Script:TrayCPUConfigFile) {
    try { $cfg = Get-Content $Script:TrayCPUConfigFile -Raw | ConvertFrom-Json; if ($cfg.CPUType) { $Script:TrayCPUType = $cfg.CPUType } } catch {}
}
# Jesli nie ma zapisanego, sprobuj wykryc
if ($Script:TrayCPUType -eq "Unknown") {
    try {
        $cpuName = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1).Name
        if ($cpuName -match "AMD|Ryzen") { $Script:TrayCPUType = "AMD" }
        elseif ($cpuName -match "Intel|Core") { $Script:TrayCPUType = "Intel" }
        else { $Script:TrayCPUType = "AMD" }  # Fallback
    } catch { $Script:TrayCPUType = "AMD" }
}
# === TRAY ICON ===
$Script:MainTray = New-Object System.Windows.Forms.NotifyIcon
$Script:MainTray.Text = "CPU Manager AI v40"
$Script:MainTray.Visible = $true
# Ikona "C" zielona
$bmpTray = New-Object System.Drawing.Bitmap(16, 16)
$gTray = [System.Drawing.Graphics]::FromImage($bmpTray)
$gTray.SmoothingMode = 'AntiAlias'
$gTray.Clear([System.Drawing.Color]::FromArgb(50, 180, 80))
$fontTray = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
$gTray.DrawString("C", $fontTray, [System.Drawing.Brushes]::White, 1, -1)
$fontTray.Dispose(); $gTray.Dispose()
$Script:MainTray.Icon = [System.Drawing.Icon]::FromHandle($bmpTray.GetHicon())
# Tray icon initialized
# === MENU TRAY ===
$Script:TrayMenu = New-Object System.Windows.Forms.ContextMenuStrip
# Status
$trayStatus = New-Object System.Windows.Forms.ToolStripMenuItem
$trayStatus.Text = "CPU Manager AI v40"
$trayStatus.Enabled = $false
$Script:TrayMenu.Items.Add($trayStatus)
$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# === TRYBY PRACY ===
$trayModes = New-Object System.Windows.Forms.ToolStripMenuItem
$trayModes.Text = "Tryb pracy"
$traySilent = New-Object System.Windows.Forms.ToolStripMenuItem
$traySilent.Text = "Silent (cichy)"
$traySilent.Add_Click({ Send-TrayCommand "SILENT" })
$trayModes.DropDownItems.Add($traySilent)
$trayBalanced = New-Object System.Windows.Forms.ToolStripMenuItem
$trayBalanced.Text = "Balanced (zrownowazony)"
$trayBalanced.Add_Click({ Send-TrayCommand "BALANCED" })
$trayModes.DropDownItems.Add($trayBalanced)
$trayTurbo = New-Object System.Windows.Forms.ToolStripMenuItem
$trayTurbo.Text = "Turbo (wydajnosc)"
$trayTurbo.Add_Click({ Send-TrayCommand "TURBO" })
$trayModes.DropDownItems.Add($trayTurbo)
$trayModes.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$trayAI = New-Object System.Windows.Forms.ToolStripMenuItem
$trayAI.Text = "Toggle AI"
$trayAI.Add_Click({ Send-TrayCommand "AI" })
$trayModes.DropDownItems.Add($trayAI)
$Script:TrayMenu.Items.Add($trayModes)
$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# === PROFILE ===
$trayProfiles = New-Object System.Windows.Forms.ToolStripMenuItem
$trayProfiles.Text = "Profile"
$trayGaming = New-Object System.Windows.Forms.ToolStripMenuItem
$trayGaming.Text = "GAMING (Turbo + Fast AI)"
$trayGaming.Add_Click({ Send-TrayCommand "PROFILE_GAMING" })
$trayProfiles.DropDownItems.Add($trayGaming)
$trayWork = New-Object System.Windows.Forms.ToolStripMenuItem
$trayWork.Text = "WORK (Balanced + All AI)"
$trayWork.Add_Click({ Send-TrayCommand "PROFILE_WORK" })
$trayProfiles.DropDownItems.Add($trayWork)
$trayMovie = New-Object System.Windows.Forms.ToolStripMenuItem
$trayMovie.Text = "MOVIE (Silent + Min AI)"
$trayMovie.Add_Click({ Send-TrayCommand "PROFILE_MOVIE" })
$trayProfiles.DropDownItems.Add($trayMovie)
$Script:TrayMenu.Items.Add($trayProfiles)
$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# === PROCESOR ===
$trayProc = New-Object System.Windows.Forms.ToolStripMenuItem
$trayProc.Text = "Procesor [$Script:TrayCPUType]"
$trayAMD = New-Object System.Windows.Forms.ToolStripMenuItem
$trayAMD.Text = "AMD Ryzen"
$trayAMD.Checked = ($Script:TrayCPUType -eq "AMD")
$trayAMD.Add_Click({ Set-TrayCPUType "AMD"; $trayAMD.Checked = $true; $trayIntel.Checked = $false; $trayProc.Text = "Procesor [AMD]" })
$trayProc.DropDownItems.Add($trayAMD)
$trayIntel = New-Object System.Windows.Forms.ToolStripMenuItem
$trayIntel.Text = "Intel Core"
$trayIntel.Checked = ($Script:TrayCPUType -eq "Intel")
$trayIntel.Add_Click({ Set-TrayCPUType "Intel"; $trayIntel.Checked = $true; $trayAMD.Checked = $false; $trayProc.Text = "Procesor [Intel]" })
$trayProc.DropDownItems.Add($trayIntel)
$Script:TrayMenu.Items.Add($trayProc)
$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# === SILNIKI AI ===
$trayEngines = New-Object System.Windows.Forms.ToolStripMenuItem
$trayEngines.Text = "Silniki AI"
$trayEnableAll = New-Object System.Windows.Forms.ToolStripMenuItem
$trayEnableAll.Text = "Wlacz CORE"
$trayEnableAll.Add_Click({
    $all = @{ QLearning=$true; Ensemble=$false; Prophet=$true; NeuralBrain=$false; AnomalyDetector=$true; SelfTuner=$true; ChainPredictor=$true; LoadPredictor=$true }
    Save-TrayAIEngines $all | Out-Null
    $Script:TrayEngineItems['QLearning'].Checked = $true
    $Script:TrayEngineItems['Ensemble'].Checked = $false
    $Script:TrayEngineItems['Prophet'].Checked = $true
    $Script:TrayEngineItems['NeuralBrain'].Checked = $false
    $Script:TrayEngineItems['AnomalyDetector'].Checked = $true
    $Script:TrayEngineItems['SelfTuner'].Checked = $true
    $Script:TrayEngineItems['ChainPredictor'].Checked = $true
    $Script:TrayEngineItems['LoadPredictor'].Checked = $true
})
$trayEngines.DropDownItems.Add($trayEnableAll)
$trayDisableAll = New-Object System.Windows.Forms.ToolStripMenuItem
$trayDisableAll.Text = "Wylacz WSZYSTKIE"
$trayDisableAll.Add_Click({
    $all = @{ QLearning=$false; Ensemble=$false; Prophet=$false; NeuralBrain=$false; AnomalyDetector=$false; SelfTuner=$false; ChainPredictor=$false; LoadPredictor=$false }
    Save-TrayAIEngines $all | Out-Null
    foreach ($k in $Script:TrayEngineItems.Keys) { $Script:TrayEngineItems[$k].Checked = $false }
})
$trayEngines.DropDownItems.Add($trayDisableAll)
$trayEngines.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$Script:TrayEngineItems = @{}
$trayEngineList = @(
    @{Key="QLearning"; Name="QLearning - uczenie"},
    @{Key="Ensemble"; Name="Ensemble - glosowanie"},
    @{Key="Prophet"; Name="Prophet - wzorce"},
    @{Key="NeuralBrain"; Name="NeuralBrain - siec"},
    @{Key="AnomalyDetector"; Name="AnomalyDetector - anomalie"},
    @{Key="SelfTuner"; Name="SelfTuner - optymalizacja"},
    @{Key="ChainPredictor"; Name="ChainPredictor - sekwencje"},
    @{Key="LoadPredictor"; Name="LoadPredictor - obciazenie"}
)
$trayCurrentEngines = Load-TrayAIEngines
foreach ($eng in $trayEngineList) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem
    $mi.Text = $eng.Name
    $mi.CheckOnClick = $true
    $mi.Checked = if ($trayCurrentEngines.($eng.Key) -eq $true) { $true } else { $false }
    $mi.Tag = $eng.Key
    $mi.Add_CheckedChanged({
        param($eventSender, $e)
        $engs = Load-TrayAIEngines
        $key = $eventSender.Tag
        $ht = @{}
        if ($engs -is [PSCustomObject]) { $engs.PSObject.Properties | ForEach-Object { $ht[$_.Name] = $_.Value } }
        else { $ht = $engs }
        $ht[$key] = $eventSender.Checked
        Save-TrayAIEngines $ht | Out-Null
    })
    $Script:TrayEngineItems[$eng.Key] = $mi
    $trayEngines.DropDownItems.Add($mi)
}
$Script:TrayMenu.Items.Add($trayEngines)
$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# === URUCHOM KOMPONENTY ===
$trayComponents = New-Object System.Windows.Forms.ToolStripMenuItem
$trayComponents.Text = "Components"
$trayWidget = New-Object System.Windows.Forms.ToolStripMenuItem
$trayWidget.Text = "Desktop Widget"
    $trayWidget.Add_Click({ Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",(Join-Path $Script:ConfigDir 'Widget_v40.ps1') -WindowStyle Hidden | Out-Null })
$trayComponents.DropDownItems.Add($trayWidget)
$trayMiniWidget = New-Object System.Windows.Forms.ToolStripMenuItem
$trayMiniWidget.Text = "Mini Widget"
    $trayMiniWidget.Add_Click({ Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",(Join-Path $Script:ConfigDir 'MiniWidget_v40.ps1') -WindowStyle Hidden | Out-Null })
$trayComponents.DropDownItems.Add($trayMiniWidget)
$trayConfig = New-Object System.Windows.Forms.ToolStripMenuItem
$trayConfig.Text = "Configurator"
    $trayConfig.Add_Click({ Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",(Join-Path $Script:ConfigDir 'CPUManager_Configurator_v40.ps1') -WindowStyle Hidden | Out-Null })
$trayComponents.DropDownItems.Add($trayConfig)
$trayComponents.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$trayStartAll = New-Object System.Windows.Forms.ToolStripMenuItem
$trayStartAll.Text = "Start ALL"
$trayStartAll.Add_Click({
    Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",(Join-Path $Script:ConfigDir 'Widget_v40.ps1') -WindowStyle Hidden | Out-Null
    Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",(Join-Path $Script:ConfigDir 'MiniWidget_v40.ps1') -WindowStyle Hidden | Out-Null
    Start-Process pwsh.exe -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",(Join-Path $Script:ConfigDir 'CPUManager_Configurator_v40.ps1') -WindowStyle Hidden | Out-Null
})
$trayComponents.DropDownItems.Add($trayStartAll)
$Script:TrayMenu.Items.Add($trayComponents)
# === INSTRUKCJA ===
$trayHelp = New-Object System.Windows.Forms.ToolStripMenuItem
$trayHelp.Text = "Instrukcja"
$trayHelp.Add_Click({ if (Test-Path "$Script:TrayBaseDir\INSTRUKCJA.txt") { Start-Process notepad.exe -ArgumentList "$Script:TrayBaseDir\INSTRUKCJA.txt" | Out-Null } })
$Script:TrayMenu.Items.Add($trayHelp)
$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# === ZAMKNIJ CPUMANAGER ===
$trayClose = New-Object System.Windows.Forms.ToolStripMenuItem
$trayClose.Text = "Zamknij CPUManager"
$trayClose.Add_Click({ Send-TrayCommand "EXIT"; $Script:MainTray.Visible = $false })
$Script:TrayMenu.Items.Add($trayClose)
$Script:TrayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
# === KILL ALL ===
$trayKillAll = New-Object System.Windows.Forms.ToolStripMenuItem
$trayKillAll.Text = "KILL ALL"
$trayKillAll.BackColor = [System.Drawing.Color]::FromArgb(120, 30, 30)
$trayKillAll.ForeColor = [System.Drawing.Color]::Red
$trayKillAll.Add_Click({ Stop-AllProcesses })
$Script:TrayMenu.Items.Add($trayKillAll)
$Script:MainTray.ContextMenuStrip = $Script:TrayMenu
# KONFIGURACJA
$Script:ConfigDir     = "C:\CPUManager"
$Script:BrainPath     = Join-Path $Script:ConfigDir "BrainState.json"
$Script:ProphetPath   = Join-Path $Script:ConfigDir "ProphetMemory.json"
$Script:AnomalyPath   = Join-Path $Script:ConfigDir "AnomalyProfiles.json"
$Script:PredictorPath = Join-Path $Script:ConfigDir "LoadPatterns.json"
$Script:SettingsPath  = Join-Path $Script:ConfigDir "ProgramSettings.json"
$Script:AILearningPath = Join-Path $Script:ConfigDir "AILearningState.json"
$Script:ManualBoostDataPath = Join-Path $Script:ConfigDir "ManualBoostData.json"
# === READ MANUAL BOOST DATA (user learned preferences) ===
function Read-ManualBoostData {
    if (-not (Test-Path $Script:ManualBoostDataPath)) { return $null }
    try {
        $json = [System.IO.File]::ReadAllText($Script:ManualBoostDataPath, [System.Text.Encoding]::UTF8)
        return $json | ConvertFrom-Json
    } catch { return $null }
}
# === GET LEARNED PREFERENCE FOR APP ===
function Get-LearnedPreferenceForApp {
    param([string]$AppName)
    if ([string]::IsNullOrWhiteSpace($AppName)) { return $null }
    $boostData = Read-ManualBoostData
    if (-not $boostData -or -not $boostData.Apps) { return $null }
    $appKey = $AppName.ToLower()
    $appData = $null
    if ($boostData.Apps -is [PSCustomObject]) {
        $prop = $boostData.Apps.PSObject.Properties | Where-Object { $_.Name -eq $appKey } | Select-Object -First 1
        if ($prop) { $appData = $prop.Value }
    } elseif ($boostData.Apps -is [hashtable] -and $boostData.Apps.ContainsKey($appKey)) {
        $appData = $boostData.Apps[$appKey]
    }
    if ($appData -and $appData.LearnedPreference -and $appData.ManualInterventions -ge 1) {
        return @{
            Mode = $appData.LearnedPreference
            Interventions = $appData.ManualInterventions
            LastSeen = $appData.LastSeen
        }
    }
    return $null
}
# #
# #
function Test-IsSystemProcess {
    param([string]$ProcessName)
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return $true }
    # Sprawdz glowna blackliste
    if ($Script:BlacklistSet -and $Script:BlacklistSet.Contains($ProcessName)) { return $true }
    # Sprawdz wzorce nazw procesow systemowych
    $systemPatterns = @(
        "^svc",           # svchost, svcs...
        "^wmi",           # WMI procesy
        "^dllhost",       # COM+ host
        "^rundll",        # rundll32
        "^msiexec",       # Instalator
        "^setup",         # Instalatory
        "^update",        # Updater procesy
        "Helper$",        # Procesy pomocnicze
        "Service$",       # Serwisy
        "Worker$",        # Workery
        "Agent$",         # Agenty
        "Broker$",        # Brokery
        "Host$"           # Hosty
    )
    foreach ($pattern in $systemPatterns) {
        if ($ProcessName -match $pattern) { return $true }
    }
    return $false
}
# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Save-JsonAtomic - Bezpieczny zapis JSON (atomic write pattern)
# ═══════════════════════════════════════════════════════════════════════════════
function Save-JsonAtomic {
    <#
    .SYNOPSIS
    Zapisuje dane JSON w sposób atomowy (najpierw .tmp, potem Move-Item)
    Zapobiega błędom "File is being used" gdy GUI czyta plik w tym samym momencie
    .PARAMETER Path
    Docelowa ścieżka pliku JSON
    .PARAMETER Data
    Dane do zapisania (hashtable/object)
    .PARAMETER Depth
    Głębokość konwersji JSON (domyślnie 5)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        $Data,
        [int]$Depth = 5
    )
    try {
        # 1. Konwertuj do JSON
        $json = $Data | ConvertTo-Json -Depth $Depth -Compress
        # 2. Zapisz do pliku tymczasowego
        $tmpPath = "$Path.tmp"
        [System.IO.File]::WriteAllText($tmpPath, $json, [System.Text.Encoding]::UTF8)
        # 3. Atomowe przeniesienie (nadpisuje docelowy plik)
        Move-Item -Path $tmpPath -Destination $Path -Force
        return $true
    } catch {
        Write-Log "Save-JsonAtomic failed for $Path : $_" "ERROR"
        return $false
    }
}
# #
# #
function Show-BoostNotification {
    param(
        [string]$AppName,
        [int]$CPUUsage,
        [string]$RecommendedMode
    )
    if (-not $Script:UserApprovedBoosts.Contains($AppName)) {
        $Script:UserApprovedBoosts.Add($AppName) | Out-Null
        Add-Log " AI learned: $AppName -> $RecommendedMode (CPU: $CPUUsage%)"
    }
    return $true
}
function Get-DefaultConfigTemplate {
    return @{
        ForceMode = ""
        PowerModes = @{
            Silent   = @{ Min = 50;  Max = 85  }
            Balanced = @{ Min = 70;  Max = 99  }
            Turbo    = @{ Min = 85;  Max = 100 }
            Extreme  = @{ Min = 100; Max = 100 }
        }
        PowerModesIntel = @{
            Silent   = @{ Min = 50;  Max = 85  }
            Balanced = @{ Min = 85;  Max = 99  }
            Turbo    = @{ Min = 99;  Max = 100 }
            Extreme  = @{ Min = 100; Max = 100 }
        }
        BoostSettings = @{
            BoostDuration = $Script:BoostDuration
            BoostCooldown = $Script:BoostCooldown
            AppLaunchSensitivity = @{
                CPUDelta = $Script:AppLaunchCPUDelta
                CPUThreshold = $Script:AppLaunchCPUThreshold
            }
            AutoBoostEnabled = $Script:AutoBoostEnabled
            AutoBoostSampleMs = $Script:AutoBoostSampleMs
            EnableBoostForAllAppsOnStart = $Script:StartupBoostEnabled
            StartupBoostDurationSeconds = $Script:StartupBoostDurationSeconds
        }
        AdaptiveTimer = @{
            DefaultInterval = $Script:DefaultTimerInterval
            MinInterval = $Script:MinTimerInterval
            MaxInterval = $Script:MaxTimerInterval
            GamingInterval = $Script:GamingTimerInterval
        }
        AIThresholds = @{
            ForceSilentCPU = $Script:ForceSilentCPU
            ForceSilentCPUInactive = $Script:ForceSilentCPUInactive
            TurboThreshold = $Script:TurboThreshold
            BalancedThreshold = $Script:BalancedThreshold
            ModeHoldTime = $Script:ModeHoldTime
        }
        IOSettings = @{
            ReadThreshold = $Script:IOReadThreshold
            WriteThreshold = $Script:IOWriteThreshold
            Sensitivity = $Script:IOSensitivity
            CheckInterval = $Script:IOCheckInterval
            TurboThreshold = $Script:IOTurboThreshold
            OverrideForceMode = $Script:IOOverrideForceMode
            ExtremeGraceSeconds = $Script:IOExtremeGraceSeconds
        }
        DatabaseSettings = @{
            ProphetAutosaveSeconds = $Script:ProphetAutosaveSeconds
        }
        # ═══════════════════════════════════════════════════════════════════════════════
        # V40 FIX: Dodano brakujące sekcje Network, Privacy, Performance, Services
        # Synchronizacja z CONFIGURATOR DefaultConfig
        # ═══════════════════════════════════════════════════════════════════════════════
        Network = @{
            Enabled = $Script:NetworkOptimizerEnabled
            DisableNagle = $Script:NetworkDisableNagle
            OptimizeTCP = $Script:NetworkOptimizeTCP
            OptimizeDNS = $Script:NetworkOptimizeDNS
            MaximizeTCPBuffers = $Script:NetworkMaximizeTCPBuffers
            EnableWindowScaling = $Script:NetworkEnableWindowScaling
            EnableRSS = $Script:NetworkEnableRSS
            EnableLSO = $Script:NetworkEnableLSO
            DisableChimney = $Script:NetworkDisableChimney
        }
        Privacy = @{
            Enabled = $Script:PrivacyShieldEnabled
            BlockTelemetry = $Script:PrivacyBlockTelemetry
            DisableCortana = $Script:PrivacyDisableCortana
            DisableLocation = $Script:PrivacyDisableLocation
            DisableAds = $Script:PrivacyDisableAds
            DisableTimeline = $Script:PrivacyDisableTimeline
        }
        Performance = @{
            OptimizeMemory = $Script:PerfOptimizeMemory
            OptimizeFileSystem = $Script:PerfOptimizeFileSystem
            OptimizeVisualEffects = $Script:PerfOptimizeVisualEffects
            OptimizeStartup = $Script:PerfOptimizeStartup
            OptimizeNetwork = $Script:PerfOptimizeNetwork
        }
        Services = @{
            DisableFax = $Script:SvcDisableFax
            DisableRemoteAccess = $Script:SvcDisableRemoteAccess
            DisableTablet = $Script:SvcDisableTablet
            DisableSearch = $Script:SvcDisableSearch
        }
    }
}
function Initialize-ConfigJson {
    if (Test-Path $Script:ConfigJsonPath) { return $true }
    try {
        # CRITICAL FIX: Sprawdź czy ConfigDir to Junction (przekierowanie na RAM dysk)
        $targetPath = $Script:ConfigDir
        try {
            $item = Get-Item -Path $Script:ConfigDir -Force -ErrorAction SilentlyContinue
            if ($item -and $item.LinkType -eq 'Junction') {
                $targetPath = $item.Target
                Write-Host "  [CONFIG] Wykryto przekierowanie: $Script:ConfigDir -> $targetPath" -ForegroundColor Cyan
                
                # Upewnij się że folder docelowy istnieje na RAM dysku
                if (-not (Test-Path $targetPath)) {
                    Write-Host "  [CONFIG] Tworzę folder na RAM dysku: $targetPath" -ForegroundColor Yellow
                    New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
                    Start-Sleep -Milliseconds 200
                }
            }
        } catch {
            # Ignoruj błąd sprawdzania Junction
        }
        
        # Upewnij się że folder istnieje (dla RAM dysków)
        if (-not (Test-Path $Script:ConfigDir)) {
            Write-Host "  [CONFIG] Tworzę folder: $Script:ConfigDir" -ForegroundColor Yellow
            New-Item -Path $Script:ConfigDir -ItemType Directory -Force | Out-Null
            Start-Sleep -Milliseconds 100
        }
        
        # Sprawdź czy folder jest dostępny (ważne dla RAM dysków)
        if (-not (Test-Path $Script:ConfigDir)) {
            Write-Host "  [CONFIG] BŁĄD: Folder $Script:ConfigDir nie jest dostępny!" -ForegroundColor Red
            Write-Host "  [CONFIG] Sprawdź czy RAM dysk jest zamontowany i czy przekierowanie działa" -ForegroundColor Yellow
            return $false
        }
        
        $template = Get-DefaultConfigTemplate
        if (-not $template) { return $false }
        $json = $template | ConvertTo-Json -Depth 8
        
        # Retry mechanizm dla RAM dysków
        $retries = 0
        $success = $false
        while ((-not $success) -and ($retries -lt 3)) {
            try {
                Set-Content -Path $Script:ConfigJsonPath -Value $json -Encoding UTF8 -Force -ErrorAction Stop
                $success = $true
                Write-Host "  [CONFIG] Utworzono domyslny config.json" -ForegroundColor Green
            } catch {
                $retries++
                Write-Host "  [CONFIG] Próba $retries/3 zapisu config.json: $_" -ForegroundColor Yellow
                if ($retries -lt 3) {
                    Start-Sleep -Milliseconds 300
                }
            }
        }
        
        if (-not $success) {
            Write-Host "  [CONFIG] BŁĄD: Nie można zapisać config.json po 3 próbach!" -ForegroundColor Red
            Write-Host "  [CONFIG] Docelowa ścieżka: $Script:ConfigJsonPath" -ForegroundColor Yellow
            return $false
        }
        
        $Script:LastConfigModified = (Get-Date)
        return $true
    } catch {
        Write-Host "  [CONFIG] Blad tworzenia config.json: $_" -ForegroundColor Red
        return $false
    }
}
# HOT-RELOAD CONFIG - Ladowanie config.json na biezaco
$Script:ConfigJsonPath = Join-Path $Script:ConfigDir "config.json"
$Script:ReloadSignalPath = Join-Path $Script:ConfigDir "reload.signal"
$Script:ShutdownSignalPath = Join-Path $Script:ConfigDir "shutdown.signal"
$Script:LastConfigModified = [DateTime]::MinValue
$Script:LastReloadSignalTime = [DateTime]::Now  # FIX v40.2: Uzyj Now zamiast MinValue zeby po restarcie nie przetwarzac starych sygnalow
$Script:ConfigCheckInterval = 5  # Sprawdzaj co 5 sekund
$Script:LastConfigCheck = [DateTime]::Now
# AI ENGINES CONFIG - Wlaczone/wylaczone silniki AI
$Script:AIEnginesPath = Join-Path $Script:ConfigDir "AIEngines.json"
$Script:LastAIEnginesCheck = [DateTime]::Now
$Script:AIEnginesCheckInterval = 10  #  PERFORMANCE: Zmieniono z 3s na 10s (wystarczajaco czesto)
$Script:DefaultAIEngines = @{
    # CORE - zawsze ON (zalecane)
    QLearning = $true
    Prophet = $true
    AnomalyDetector = $true
    SelfTuner = $true
    # ADVANCED - opcjonalne
    ChainPredictor = $true
    LoadPredictor = $true
    Bandit = $true           # v42.6: Dodano
    Genetic = $true          # v42.6: Dodano
    Energy = $true           # v42.6: Dodano
    # HEAVY - domyslnie OFF (wysokie zuzycie CPU)
    Ensemble = $false
    NeuralBrain = $false
}
$Script:AIEngines = $Script:DefaultAIEngines.Clone()
function Load-AIEnginesConfig {
    <#
    .SYNOPSIS
    Laduje konfiguracje silnikow AI z pliku
    #>
    if (Test-Path $Script:AIEnginesPath) {
        try {
            $json = Get-Content $Script:AIEnginesPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $Script:AIEngines = @{
                QLearning = if ($null -ne $json.QLearning) { $json.QLearning } else { $true }
                Ensemble = if ($null -ne $json.Ensemble) { $json.Ensemble } else { $false }
                Prophet = if ($null -ne $json.Prophet) { $json.Prophet } else { $true }
                NeuralBrain = if ($null -ne $json.NeuralBrain) { $json.NeuralBrain } else { $false }
                AnomalyDetector = if ($null -ne $json.AnomalyDetector) { $json.AnomalyDetector } else { $true }
                SelfTuner = if ($null -ne $json.SelfTuner) { $json.SelfTuner } else { $true }
                ChainPredictor = if ($null -ne $json.ChainPredictor) { $json.ChainPredictor } else { $true }
                LoadPredictor = if ($null -ne $json.LoadPredictor) { $json.LoadPredictor } else { $true }
                Bandit = if ($null -ne $json.Bandit) { $json.Bandit } else { $true }           # v42.6
                Genetic = if ($null -ne $json.Genetic) { $json.Genetic } else { $true }       # v42.6
                Energy = if ($null -ne $json.Energy) { $json.Energy } else { $true }          # v42.6
            }
            $Script:CurrentAIEngines = $Script:AIEngines
            return $true
        } catch {
            return $false
        }
    } else {
        # Utworz domyslny plik
        Ensure-FileExists $Script:AIEnginesPath
        try {
            $Script:DefaultAIEngines | ConvertTo-Json | Set-Content $Script:AIEnginesPath -Force
        } catch {}
        return $false
    }
}
function Acquire-FileLock {
    param([string]$FilePath, [int]$TimeoutMs = 2000)
    $lockPath = "$FilePath.lock"
    $start = Get-Date
    while (Test-Path $lockPath) {
        Start-Sleep -Milliseconds 20
        if (((Get-Date) - $start).TotalMilliseconds -gt $TimeoutMs) {
            throw "Timeout waiting for file lock: $FilePath"
        }
    }
    New-Item -ItemType File -Path $lockPath -Force | Out-Null
}
function Release-FileLock {
    param([string]$FilePath)
    $lockPath = "$FilePath.lock"
    if (Test-Path $lockPath) { Remove-Item $lockPath -Force }
}
function Save-AIEnginesConfig {
    try {
        Acquire-FileLock $Script:AIEnginesPath
        $Script:AIEngines | ConvertTo-Json | Set-Content $Script:AIEnginesPath -Force
        Release-FileLock $Script:AIEnginesPath
        return $true
    } catch {
        try { Release-FileLock $Script:AIEnginesPath } catch {}
        return $false
    }
}
function Test-AIEngine {
    <#
    .SYNOPSIS
    Sprawdza czy dany silnik AI jest wlaczony
    #>
    param([string]$EngineName)
    if ($Script:AIEngines.ContainsKey($EngineName)) {
        return $Script:AIEngines[$EngineName]
    }
    return $true  # Domyslnie wlaczony jesli nie znaleziono
}
# Zaladuj przy starcie
Load-AIEnginesConfig | Out-Null
# Alias dla kompatybilnosci z nowa logika decyzyjna
$Script:CurrentAIEngines = $Script:AIEngines
$Script:RyzenAdjPath = "C:\ryzenadj-win64\ryzenadj.exe"
$Script:RyzenAdjAvailable = $false
$Script:LastTDPMode = ""
$Script:CurrentTDP = @{ STAPM = 0; Fast = 0; Slow = 0; Tctl = 0 }
# Profile TDP dla roznych trybow (w Watach) - domyslne wartosci
$Script:TDPProfiles = @{
    Silent = @{ STAPM = 12; Fast = 28; Slow = 15; Tctl = 75 }
    Balanced = @{ STAPM = 15; Fast = 28; Slow = 22; Tctl = 80 }
    Turbo = @{ STAPM = 25; Fast = 35; Slow = 30; Tctl = 88 }
    Extreme = @{ STAPM = 28; Fast = 40; Slow = 35; Tctl = 92 }
    Boost = @{ STAPM = 30; Fast = 40; Slow = 32; Tctl = 85 }
    Performance = @{ STAPM = 35; Fast = 45; Slow = 38; Tctl = 90 }
}
# Inicjalizacja i test RyzenADJ
function Initialize-RyzenAdj {
    # Sprawdz rozne lokalizacje
    $paths = @(
        "C:\ryzenadj-win64\ryzenadj.exe",
        "C:\CPUManager\ryzenadj\ryzenadj.exe",
        "$env:ProgramFiles\ryzenadj\ryzenadj.exe",
        "$env:USERPROFILE\ryzenadj\ryzenadj.exe"
    )
    $found = Find-FirstExistingPath $paths
    if ($found) {
        try {
            $result = & $found --info 2>&1
            if ($result -match "STAPM|PPT|Tctl") {
                $Script:RyzenAdjPath = $found
                $Script:RyzenAdjAvailable = $true
                Write-Log "RyzenADJ znaleziony: $found" "SUCCESS"
                return $true
            }
        } catch { }
    }
    Write-Log "RyzenADJ niedostepny - uzywam tylko powercfg" "WARN"
    $Script:RyzenAdjAvailable = $false
    return $false
}
# Pobierz aktualne wartosci TDP
function Get-RyzenAdjInfo {
    if (-not $Script:RyzenAdjAvailable) { return $null }
    try {
        $output = & $Script:RyzenAdjPath --info 2>&1
        $info = @{ STAPM = 0; Fast = 0; Slow = 0; Tctl = 0; TctlValue = 0 }
        foreach ($line in $output) {
            if ($line -match "STAPM LIMIT\s*\|\s*(\d+)") { $info.STAPM = [int]$Matches[1] / 1000 }
            if ($line -match "PPT LIMIT FAST\s*\|\s*(\d+)") { $info.Fast = [int]$Matches[1] / 1000 }
            if ($line -match "PPT LIMIT SLOW\s*\|\s*(\d+)") { $info.Slow = [int]$Matches[1] / 1000 }
            if ($line -match "THM LIMIT\s*\|\s*(\d+)") { $info.Tctl = [int]$Matches[1] }
            if ($line -match "THM VALUE\s*\|\s*(\d+\.?\d*)") { $info.TctlValue = [double]$Matches[1] }
        }
        return $info
    } catch { return $null }
}
# Start async refresh of RyzenAdj info (non-blocking)
function Start-RyzenAdjInfoRefresh {
    if (-not $Script:RyzenAdjAvailable) { return $false }
    try {
        $state = @{ }
        $cb = [System.Threading.WaitCallback]::new({ param($st)
            try {
                $info = Get-RyzenAdjInfo
                if ($info) {
                    if ([System.Threading.Monitor]::TryEnter($Script:RyzenAdjLock, 500)) {
                        try { $Script:RyzenAdjCache.Info = $info; $Script:RyzenAdjCache.InfoTime = Get-Date } finally { [System.Threading.Monitor]::Exit($Script:RyzenAdjLock) }
                    }
                }
            } catch { }
        })
        [System.Threading.ThreadPool]::QueueUserWorkItem($cb, $state) | Out-Null
        return $true
    } catch { return $false }
}
# Start async apply of RyzenAdj TDP (non-blocking). Stores last result in $Script:RyzenAdjCache.LastApplyResult
function Start-RyzenAdjSetTDP {
    param([int]$STAPM, [int]$Fast, [int]$Slow, [int]$Tctl = 85)
    if (-not $Script:RyzenAdjAvailable) { return $false }
    try {
        $jobId = [guid]::NewGuid().ToString()
        $state = @{ STAPM = $STAPM; Fast = $Fast; Slow = $Slow; Tctl = $Tctl; JobId = $jobId }
        $cb = [System.Threading.WaitCallback]::new({ param($st)
            try {
                $s = $st.STAPM; $f = $st.Fast; $sl = $st.Slow; $t = $st.Tctl; $jid = $st.JobId
                $res = Set-RyzenAdjTDP -STAPM $s -Fast $f -Slow $sl -Tctl $t
                if ([System.Threading.Monitor]::TryEnter($Script:RyzenAdjLock, 1000)) {
                    try {
                        $Script:RyzenAdjCache.LastApplyResult = $res
                        $Script:RyzenAdjCache.LastApplyTime = Get-Date
                        $Script:RyzenAdjCache.LastJob = $jid
                    } finally { [System.Threading.Monitor]::Exit($Script:RyzenAdjLock) }
                }
                try { Add-Log "RyzenAdj async applied: $($res) (job=$jid)" } catch { }
            } catch {
                try { Add-Log "RyzenAdj async exception: $_" } catch { }
            }
        })
        [System.Threading.ThreadPool]::QueueUserWorkItem($cb, $state) | Out-Null
        return @{ Started = $true; JobId = $jobId }
    } catch { return @{ Started = $false; Error = $_ } }
}
# Return cached RyzenAdj info (if any)
function Get-RyzenAdjCachedInfo {
    if ([System.Threading.Monitor]::TryEnter($Script:RyzenAdjLock, 200)) {
        try { return $Script:RyzenAdjCache.Info } finally { [System.Threading.Monitor]::Exit($Script:RyzenAdjLock) }
    }
    return $null
}
# Ustaw TDP przez RyzenADJ
function Set-RyzenAdjTDP {
    param([int]$STAPM, [int]$Fast, [int]$Slow, [int]$Tctl = 85)
    if (-not $Script:RyzenAdjAvailable) { return $false }
    try {
        $myArgs = @(
            "--stapm-limit=$($STAPM * 1000)",
            "--fast-limit=$($Fast * 1000)",
            "--slow-limit=$($Slow * 1000)",
            "--tctl-temp=$Tctl"
        )
        $output = & $Script:RyzenAdjPath $myArgs 2>&1
        $exit = $LASTEXITCODE
        $cmdLine = "$($Script:RyzenAdjPath) $($myArgs -join ' ')"
        Write-Log "RyzenADJ cmd: $cmdLine" "TDP"
        if ($output) { Write-Log "RyzenADJ output: $([string]::Join('`n', $output))" "TDP" }
        Write-Log "RyzenADJ exit code: $exit" "TDP"
        if ($exit -eq 0) {
            $Script:CurrentTDP = @{ STAPM = $STAPM; Fast = $Fast; Slow = $Slow; Tctl = $Tctl }
            return $true
        } else {
            return $false
        }
    } catch {
        Write-Log "RyzenADJ exception: $_" "ERROR"
        return $false
    }
}
# Zastosuj profil TDP na podstawie trybu
function Set-RyzenAdjMode {
    param([string]$Mode)
    if (-not $Script:RyzenAdjAvailable) { return $false }
    if ($Script:LastTDPMode -eq $Mode) { return $true }
    $myProfile = $Script:TDPProfiles[$Mode]
    if (-not $myProfile) {
           # Fallback do Balanced
           # Uzyj domyslnego profilu Balanced
        $myProfile = $Script:TDPProfiles["Balanced"]
    }
    $res = Start-RyzenAdjSetTDP -STAPM $myProfile.STAPM -Fast $myProfile.Fast -Slow $myProfile.Slow -Tctl $myProfile.Tctl
    if ($res -and $res.Started) {
        $Script:LastTDPMode = $Mode
        Write-Log "RyzenADJ: Scheduled $Mode (STAPM=$($myProfile.STAPM)W Fast=$($myProfile.Fast)W Tctl=$($myProfile.Tctl)C)" "TDP"
        Add-Log "TDP: scheduled $Mode $($myProfile.STAPM)W"
        return $true
    }
    return $false
}
# AI Learning - zapisuje efektywnosc profili TDP
$Script:TDPLearningPath = "C:\CPUManager\TDPLearning.json"
$Script:TDPLearning = @{}
function Update-TDPLearning {
    param([string]$Mode, [double]$CPU, [double]$Temp, [double]$Score)
    if (-not $Script:RyzenAdjAvailable) { return }
    if (-not $Script:TDPLearning[$Mode]) {
        $Script:TDPLearning[$Mode] = @{ Samples = 0; AvgCPU = 0; AvgTemp = 0; AvgScore = 0; TotalTime = 0 }
    }
    $s = $Script:TDPLearning[$Mode]
    $s.Samples++
    $s.TotalTime++
    $s.AvgCPU = (($s.AvgCPU * ($s.Samples - 1)) + $CPU) / $s.Samples
    $s.AvgTemp = (($s.AvgTemp * ($s.Samples - 1)) + $Temp) / $s.Samples
    $s.AvgScore = (($s.AvgScore * ($s.Samples - 1)) + $Score) / $s.Samples
    # Zapisz co 100 probek
    if ($s.Samples % 100 -eq 0) {
        try { $Script:TDPLearning | ConvertTo-Json -Depth 3 | Set-Content $Script:TDPLearningPath -Force } catch {}
    }
}
# Ladowanie wczesniej nauczonych danych TDP
function Load-TDPLearning {
    if (Test-Path $Script:TDPLearningPath) {
        try {
            $json = Get-Content $Script:TDPLearningPath -Raw | ConvertFrom-Json
            $json.PSObject.Properties | ForEach-Object {
                $Script:TDPLearning[$_.Name] = @{
                    Samples = $_.Value.Samples
                    AvgCPU = $_.Value.AvgCPU
                    AvgTemp = $_.Value.AvgTemp
                    AvgScore = $_.Value.AvgScore
                    TotalTime = $_.Value.TotalTime
                }
            }
            Write-Log "Zaladowano dane TDP Learning ($($Script:TDPLearning.Count) profili)" "INFO"
        } catch {}
    }
}
# Inteligentny wybor profilu TDP na podstawie AI learning
function Get-OptimalTDPProfile {
    param([double]$CPU, [double]$Temp, [string]$Context, [bool]$IsGaming = $false)
    # Bezpieczenstwo termiczne - zawsze priorytet
    if ($Temp -gt 88) { return "Silent" }
    if ($Temp -gt 82) { return "Balanced" }
    # Gaming - maksymalna wydajnosc
    if ($IsGaming -or $Context -eq "Gaming") {
        if ($Temp -lt 75) { return "Extreme" }
        return "Turbo"
    }
    # Audio/DAW context: minimum Balanced — Silent = buffer underruns = dropouty audio
    if ($Context -eq "Audio") { return "Balanced" }
    # Heavy work
    if ($Context -eq "Heavy" -or $CPU -gt $Script:TurboThreshold) {
        if ($Temp -lt 78) { return "Turbo" }
        return "Balanced"
    }
    # Normalne uzycie - FAWORYZUJ SILENT przy niskim CPU
    if ($CPU -lt $Script:ForceSilentCPU) { return "Silent" }
    # ZMIANA: Rozszerzony zakres dla Silent (bylo < BalancedThreshold -> Balanced)
    if ($CPU -lt ($Script:BalancedThreshold - 10)) { return "Silent" }  # CPU < 28% -> Silent
    if ($CPU -lt $Script:BalancedThreshold) { return "Balanced" }        # CPU 28-38% -> Balanced
    return "Turbo"
}
# WYKRYWANIE PROCESORA AMD/INTEL
$Script:CPUType = "Unknown"
$Script:CPUName = "Unknown"
$Script:CPUConfigPath = Join-Path $Script:ConfigDir "CPUConfig.json"
function Detect-CPUType {
    try {
        $cpu = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $Script:CPUName = $cpu.Name
        if ($cpu.Name -match "AMD|Ryzen|EPYC|Athlon|Threadripper") {
            $Script:CPUType = "AMD"
        } elseif ($cpu.Name -match "Intel|Core|Xeon|Pentium|Celeron") {
            $Script:CPUType = "Intel"
        } else {
            $Script:CPUType = "Unknown"
        }
    } catch {
        $Script:CPUType = "Unknown"
    }
    # Sprawdz zapisana konfiguracje (reczny wybor nadpisuje auto)
    if (Test-Path $Script:CPUConfigPath) {
        try {
            $cfg = Get-Content $Script:CPUConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($cfg.CPUType) { $Script:CPUType = $cfg.CPUType }
        } catch {}
    }
    return $Script:CPUType
}
function Set-CPUTypeManual {
    param([string]$Type)
    $Script:CPUType = $Type
    try {
        @{ CPUType = $Type; CPUName = $Script:CPUName } | ConvertTo-Json | Set-Content $Script:CPUConfigPath -Force
    } catch {}
}
# Wykryj przy starcie
Detect-CPUType | Out-Null
# ═══════════════════════════════════════════════════════════════════════════════
# INTEL POWER MANAGER — własny mechanizm ENGINE (odpowiednik RyzenAdj dla Intel)
# Function-based (nie class) bo wymaga [Win32] z Add-Type
# Kontroluje: Affinity rdzeni, EcoQoS/Priority, Frequency cap (MHz)
# ═══════════════════════════════════════════════════════════════════════════════
function New-IntelPowerManager {
    $pm = @{
        Available = $false; CurrentMode = "Balanced"; LastMode = ""
        TotalCores = 0; PhysicalCores = 0; PerformanceCores = 0; EfficiencyCores = 0
        HasHybridArch = $false; MaxFreqMHz = 0; BaseFreqMHz = 0
        FullAffinityMask = 0L; SilentAffinityMask = 0L; BalancedAffinityMask = 0L
        ThrottledProcesses = @{}; ModeStats = @{ Silent=0; Balanced=0; Turbo=0; Extreme=0 }
        PowerPlanGUID = $null
    }
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $pm.TotalCores = [Environment]::ProcessorCount
        $pm.PhysicalCores = [int]$cpu.NumberOfCores
        $pm.MaxFreqMHz = [int]$cpu.MaxClockSpeed
        $cpuName = $cpu.Name
        if ($cpuName -match "12th|13th|14th|Core Ultra|i[3579]-1[2-5]") {
            $pm.HasHybridArch = $true
            $pm.PerformanceCores = [Math]::Max(2, [int]($pm.PhysicalCores * 0.4))
            $pm.EfficiencyCores = $pm.PhysicalCores - $pm.PerformanceCores
        } else { $pm.PerformanceCores = $pm.PhysicalCores }
        $pm.BaseFreqMHz = [int]($pm.MaxFreqMHz * 0.5)
        $pm.FullAffinityMask = (1L -shl $pm.TotalCores) - 1
        $silentCores = [Math]::Max(2, [int]($pm.TotalCores / 2))
        $pm.SilentAffinityMask = (1L -shl $silentCores) - 1
        $balancedCores = [Math]::Max(4, [int]($pm.TotalCores * 0.75))
        $pm.BalancedAffinityMask = (1L -shl $balancedCores) - 1
        # Cache power plan GUID
        $output = powercfg /getactivescheme 2>$null
        if ($output -match '([a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12})') {
            $pm.PowerPlanGUID = $matches[1]
        }
        $pm.Available = $true
        Write-Host "  [IntelPM] Initialized: $($pm.PhysicalCores)C/$($pm.TotalCores)T Max=$($pm.MaxFreqMHz)MHz Hybrid=$($pm.HasHybridArch)" -ForegroundColor Cyan
    } catch { $pm.Available = $false }
    return $pm
}

function Set-IntelPowerMode {
    param([hashtable]$PM, [string]$Mode)
    if (-not $PM -or -not $PM.Available) { return }
    # FIX v40.3: Skip jeśli ten sam mode ORAZ nie minęło 3s (zapobiega spam powercfg → CPU spike)
    if ($Mode -eq $PM.LastMode) { return }
    $now = [DateTime]::UtcNow
    if ($PM._LastModeChange -and ($now - $PM._LastModeChange).TotalSeconds -lt 3.0) { return }
    $PM._LastModeChange = $now
    # Pobierz Min/Max z IntelStates (konfigurowalnych przez Configurator)
    $states = $Script:IntelStates
    $state = $states[$Mode]
    if (-not $state) { $state = @{ Min = 50; Max = 100 } }
    $minPct = $state.Min
    $maxPct = $state.Max
    switch ($Mode) {
        "Silent" {
            Set-IntelBackgroundAffinity $PM $PM.SilentAffinityMask
            Set-IntelBackgroundPriority $PM $true
            Set-IntelFrequencyCap $PM $minPct $maxPct
        }
        "Balanced" {
            Restore-IntelAffinities $PM
            Set-IntelBackgroundPriority $PM $false
            Set-IntelFrequencyCap $PM $minPct $maxPct
        }
        "Turbo" {
            Restore-IntelAffinities $PM
            Set-IntelBackgroundPriority $PM $true
            Set-IntelForegroundBoost $PM
            Set-IntelFrequencyCap $PM $minPct $maxPct
        }
        "Extreme" {
            Restore-IntelAffinities $PM
            Set-IntelBackgroundPriority $PM $false
            Set-IntelForegroundBoost $PM
            Set-IntelFrequencyCap $PM $minPct $maxPct
        }
    }
    $PM.LastMode = $Mode; $PM.CurrentMode = $Mode; $PM.ModeStats[$Mode]++
}

function Set-IntelBackgroundAffinity {
    param([hashtable]$PM, [long]$mask)
    try {
        # AUDIO SAFE MODE: DAW/VST wymaga pełnego dostępu do CPU — zmiana affinity = dropout
        if ($Script:CurrentAppContext -eq "Audio") { return }
        # PERFORMANCE FIX v40.3: Throttle — max raz na 5 sekund
        $now = [DateTime]::UtcNow
        if ($PM._LastBgAffinityCheck -and ($now - $PM._LastBgAffinityCheck).TotalSeconds -lt 5.0) { return }
        $PM._LastBgAffinityCheck = $now
        
        $fgHwnd = [Win32]::GetForegroundWindow()
        $fgPid = 0
        if ($fgHwnd -ne [IntPtr]::Zero) { [Win32]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid) | Out-Null }
        $protected = @("System","Idle","svchost","csrss","smss","lsass","services","wininit","dwm","explorer","powershell","CPUManager","ShellExperienceHost","ApplicationFrameHost","TextInputHost","ShellHost","sihost","taskhostw","RuntimeBroker","dllhost","ctfmon","audiodg",
            "kontakt","kontakt7","kontakt6","vstbridge","vstbridge64","jbridge","jbridge64","audiogridder",
            "cubase","cubase13","reaper","reaper64","fl64","flstudio","bitwig","ableton","studioone","nuendo","protools")
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Id -ne $fgPid -and $_.Id -gt 4 -and $_.WorkingSet64 -gt 20MB -and $protected -notcontains $_.ProcessName
        } | Sort-Object WorkingSet64 -Descending | Select-Object -First 15
        foreach ($p in $procs) {
            try {
                if (-not $PM.ThrottledProcesses.ContainsKey($p.Id)) {
                    $PM.ThrottledProcesses[$p.Id] = @{ Name=$p.ProcessName; OrigAffinity=$p.ProcessorAffinity.ToInt64() }
                }
                $p.ProcessorAffinity = [IntPtr]$mask
            } catch {} finally { try { $p.Dispose() } catch {} }
        }
    } catch {}
}

function Restore-IntelAffinities {
    param([hashtable]$PM)
    foreach ($procId in @($PM.ThrottledProcesses.Keys)) {
        try {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($p) {
                $orig = $PM.ThrottledProcesses[$procId].OrigAffinity
                if ($orig -gt 0) { $p.ProcessorAffinity = [IntPtr]$orig }
                $p.Dispose()
            }
        } catch {}
    }
    $PM.ThrottledProcesses.Clear()
}

function Set-IntelBackgroundPriority {
    param([hashtable]$PM, [bool]$throttle)
    try {
        # AUDIO SAFE MODE: Nie obniżaj priorytetów procesów gdy DAW/VST aktywne — powoduje buffer underruns
        if ($throttle -and $Script:CurrentAppContext -eq "Audio") { return }
        # PERFORMANCE FIX v40.3: Throttle — max raz na 5 sekund (Get-Process = 50-200ms + CPU spike)
        $now = [DateTime]::UtcNow
        if ($PM._LastBgPriorityCheck -and ($now - $PM._LastBgPriorityCheck).TotalSeconds -lt 5.0) { return }
        $PM._LastBgPriorityCheck = $now
        
        $fgHwnd = [Win32]::GetForegroundWindow()
        $fgPid = 0
        if ($fgHwnd -ne [IntPtr]::Zero) { [Win32]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid) | Out-Null }
        # Shell/system + audio/DAW procesy NIGDY nie throttle — bez tego = dropout, zamrożony UI
        $shellProtected = @("System","Idle","svchost","csrss","smss","lsass","services","wininit","dwm","explorer","powershell","pwsh","CPUManager","ShellExperienceHost","ApplicationFrameHost","TextInputHost","ShellHost","sihost","taskhostw","RuntimeBroker","dllhost","ctfmon","audiodg","conhost","fontdrvhost","SearchHost","StartMenuExperienceHost","winlogon","SecurityHealthService","MsMpEng",
            "kontakt","kontakt7","kontakt6","vstbridge","vstbridge64","jbridge","jbridge64","audiogridder",
            "cubase","cubase13","reaper","reaper64","fl64","flstudio","bitwig","ableton","studioone","nuendo","protools")
        $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Id -ne $fgPid -and $_.Id -gt 4 -and $_.WorkingSet64 -gt 30MB -and $shellProtected -notcontains $_.ProcessName
        } | Select-Object -First 20
        foreach ($p in $procs) {
            try {
                $p.PriorityClass = if ($throttle) { [System.Diagnostics.ProcessPriorityClass]::BelowNormal } 
                                   else { [System.Diagnostics.ProcessPriorityClass]::Normal }
            } catch {} finally { try { $p.Dispose() } catch {} }
        }
    } catch {}
}

function Set-IntelForegroundBoost {
    param([hashtable]$PM)
    try {
        $fgHwnd = [Win32]::GetForegroundWindow()
        if ($fgHwnd -eq [IntPtr]::Zero) { return }
        $fgPid = 0; [Win32]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid) | Out-Null
        if ($fgPid -gt 0) {
            $p = Get-Process -Id $fgPid -ErrorAction SilentlyContinue
            if ($p) {
                $p.ProcessorAffinity = [IntPtr]$PM.FullAffinityMask
                $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
                $p.Dispose()
            }
        }
    } catch {}
}

function Set-IntelFrequencyCap {
    param([hashtable]$PM, [int]$minPercent, [int]$maxPercent = 100)
    try {
        $guid = $PM.PowerPlanGUID
        if (-not $guid) { return }
        $sub = "54533251-82be-4824-96c1-47b60b740d00"
        # Max Processor Frequency (MHz cap) — z IntelStates
        $freqGuid = "75b0ae3f-bce0-45a7-8c89-c9611c25e100"
        $freqCap = if ($maxPercent -ge 100) { 0 } else { [int]($PM.MaxFreqMHz * $maxPercent / 100) }
        powercfg /setacvalueindex $guid $sub $freqGuid $freqCap 2>$null
        powercfg /setdcvalueindex $guid $sub $freqGuid $freqCap 2>$null
        # EPP — hint dla Intel Speed Shift (skalowany z Max%)
        $epp = if ($maxPercent -ge 100) { 0 } elseif ($maxPercent -ge 85) { 64 } elseif ($maxPercent -ge 50) { 128 } else { 200 }
        powercfg /setacvalueindex $guid $sub "36687f9e-e3a5-4dbf-b1dc-15eb381c6863" $epp 2>$null
        powercfg /setdcvalueindex $guid $sub "36687f9e-e3a5-4dbf-b1dc-15eb381c6863" $epp 2>$null
        # Boost mode — z Max%
        $boost = if ($maxPercent -ge 100) { 2 } elseif ($maxPercent -ge 85) { 1 } else { 0 }
        powercfg /setacvalueindex $guid $sub "be337238-0d82-4146-a960-4f3749d470c7" $boost 2>$null
        powercfg /setdcvalueindex $guid $sub "be337238-0d82-4146-a960-4f3749d470c7" $boost 2>$null
        # Min/Max CPU state — BEZPOŚREDNIO z IntelStates (Configurator)
        powercfg /setacvalueindex $guid $sub "893dee8e-2bef-41e0-89c6-b55d0929964c" $minPercent 2>$null
        powercfg /setacvalueindex $guid $sub "bc5038f7-23e0-4960-96da-33abaf5935ec" $maxPercent 2>$null
        powercfg /setdcvalueindex $guid $sub "893dee8e-2bef-41e0-89c6-b55d0929964c" $minPercent 2>$null
        powercfg /setdcvalueindex $guid $sub "bc5038f7-23e0-4960-96da-33abaf5935ec" $maxPercent 2>$null
        powercfg /setactive $guid 2>$null
    } catch {}
}

function Reset-IntelPowerManager {
    param([hashtable]$PM)
    if (-not $PM -or -not $PM.Available) { return }
    Restore-IntelAffinities $PM
    Set-IntelBackgroundPriority $PM $false
    Set-IntelFrequencyCap $PM 100 100
}

$Script:IntelPM = $null
if ($Script:CPUType -eq "Intel") {
    try {
        $Script:IntelPM = New-IntelPowerManager
        if ($Script:IntelPM.Available) {
            Write-Host "  Intel Power Manager: ACTIVE ($($Script:IntelPM.PhysicalCores)C/$($Script:IntelPM.TotalCores)T, Hybrid=$($Script:IntelPM.HasHybridArch))" -ForegroundColor Green
        }
    } catch {
        Write-Host "  Intel Power Manager: FAILED ($($_.Exception.Message))" -ForegroundColor Yellow
        $Script:IntelPM = $null
    }
}
# - V40: Wykryj GPU (iGPU/dGPU)
Detect-GPU | Out-Null

# DEBUG: Log GPU detection results
if ($Script:DebugLogEnabled) {
    if ($Script:HasiGPU -and $Script:HasdGPU) {
        Write-DebugLog "GPU DETECTION: Hybrid Graphics detected - iGPU: $($Script:iGPUName) | dGPU: $($Script:dGPUName) ($($Script:dGPUVendor))" "INFO"
    } elseif ($Script:HasdGPU) {
        Write-DebugLog "GPU DETECTION: Dedicated GPU only - $($Script:dGPUName) ($($Script:dGPUVendor))" "INFO"
    } elseif ($Script:HasiGPU) {
        Write-DebugLog "GPU DETECTION: Integrated GPU only - $($Script:iGPUName)" "INFO"
    } else {
        Write-DebugLog "GPU DETECTION: No GPU detected or detection failed" "INFO"
    }
}

# Synchronizuj TrayCPUType z wykrytym CPUType
$Script:TrayCPUType = $Script:CPUType
if ($Script:CPUType -eq "AMD") {
    Write-Host "  [CPU] Wykryto AMD: $($Script:CPUName)" -ForegroundColor Green
    Initialize-RyzenAdj | Out-Null
    Load-TDPLearning | Out-Null
    Load-TDPConfig -Path $Script:TDPConfigPath | Out-Null
    if ($Script:RyzenAdjAvailable) {
        Start-RyzenAdjInfoRefresh | Out-Null
        $info = Get-RyzenAdjCachedInfo
        if ($info) {
            Write-Log "RyzenADJ: STAPM=$($info.STAPM)W Fast=$($info.Fast)W Slow=$($info.Slow)W Tctl=$($info.Tctl)C" "INFO"
        }
    }
} elseif ($Script:CPUType -eq "Intel") {
    Write-Host "  [CPU] Wykryto Intel: $($Script:CPUName)" -ForegroundColor Cyan
    Write-Host "  [CPU] Intel Speed Shift + EPP enabled" -ForegroundColor Cyan
    Write-Log "Intel CPU detected: $($Script:CPUName) - using Speed Shift + EPP" "INFO"
} else {
    Write-Host "  [CPU] Nieznany CPU: $($Script:CPUName) - uzywam ustawien AMD" -ForegroundColor Yellow
    $Script:CPUType = "AMD"  # Fallback do AMD
}
function Load-ExternalConfig {
    <#
    .SYNOPSIS
    Laduje config.json i aktualizuje ustawienia na biezaco
    #>
    param([switch]$Silent)
    if (-not (Test-Path $Script:ConfigJsonPath)) {
        if (-not (Initialize-ConfigJson)) {
            if (-not $Silent) { Write-Host "  [CONFIG] Brak config.json - uzywam domyslnych" -ForegroundColor Yellow }
            return $false
        }
    }
    try {
        $configJson = Get-Content $Script:ConfigJsonPath -Raw -ErrorAction Stop | ConvertFrom-Json
        # ForceMode - wymusza tryb z konfiguratora (TYLKO prawidlowe wartosci!)
        $validModes = @("Silent", "Silent Lock", "Balanced Lock", "Balanced", "Turbo", "Extreme")
        if ($configJson.PSObject.Properties.Name -contains "ForceMode" -and $configJson.ForceMode -and $validModes -contains $configJson.ForceMode) {
            $Script:ForceModeFromConfig = $configJson.ForceMode
            if ($configJson.ForceMode -eq "Silent Lock") {
                $Script:SilentLockMode = $true
                $Script:BalancedLockMode = $false
                $Script:SilentModeActive = $false
                $Global:AI_Active = $false
            } elseif ($configJson.ForceMode -eq "Balanced Lock") {
                $Script:BalancedLockMode = $true
                $Script:SilentLockMode = $false
                $Script:SilentModeActive = $false
                $Global:AI_Active = $false
            } elseif ($configJson.ForceMode -eq "Silent") {
                $Script:SilentModeActive = $true
                $Script:SilentLockMode = $false
                $Script:BalancedLockMode = $false
            } else {
                $Script:SilentModeActive = $false
                $Script:SilentLockMode = $false
                $Script:BalancedLockMode = $false
            }
        } else {
            $Script:ForceModeFromConfig = ""
            $Script:BalancedLockMode = $false
        }
        # v43.14: AUTO-MIGRACJA starych config.json
        # Jeśli brak PowerModes → stary format → dodaj defaults i zapisz
        if (-not $configJson.PowerModes) {
            Add-Log "CONFIG MIGRATION: Old config.json detected - adding PowerModes defaults"
            $configJson | Add-Member -NotePropertyName "PowerModes" -NotePropertyValue @{
                Silent = @{ Min = 50; Max = 85 }; Balanced = @{ Min = 70; Max = 99 }
                Turbo = @{ Min = 85; Max = 100 }; Extreme = @{ Min = 100; Max = 100 }
            } -Force
            $configJson | Add-Member -NotePropertyName "PowerModesIntel" -NotePropertyValue @{
                Silent = @{ Min = 50; Max = 85 }; Balanced = @{ Min = 85; Max = 99 }
                Turbo = @{ Min = 99; Max = 100 }; Extreme = @{ Min = 100; Max = 100 }
            } -Force
            if (-not $configJson.PSObject.Properties.Name.Contains("AIThresholds")) {
                $configJson | Add-Member -NotePropertyName "AIThresholds" -NotePropertyValue @{
                    TurboThreshold = 72; BalancedThreshold = 35
                    ForceSilentCPU = 15; ForceSilentCPUInactive = 20
                } -Force
            }
            if (-not $configJson.PSObject.Properties.Name.Contains("CPUAgressiveness")) {
                $configJson | Add-Member -NotePropertyName "CPUAgressiveness" -NotePropertyValue 50 -Force
                $configJson | Add-Member -NotePropertyName "MemoryAgressiveness" -NotePropertyValue 30 -Force
                $configJson | Add-Member -NotePropertyName "IOPriority" -NotePropertyValue 3 -Force
            }
            if (-not $configJson.PSObject.Properties.Name.Contains("BoostSettings")) {
                $configJson | Add-Member -NotePropertyName "BoostSettings" -NotePropertyValue @{
                    BoostDuration = 8; BoostCooldown = 30; AppLaunchSensitivity = "Medium"
                } -Force
            }
            # Zapisz migrowany config
            try {
                $configJson | ConvertTo-Json -Depth 5 | Set-Content $Script:ConfigJsonPath -Encoding UTF8 -Force
                Add-Log "CONFIG MIGRATION: Saved migrated config.json with PowerModes"
            } catch { Add-Log "CONFIG MIGRATION: Failed to save - $($_.Exception.Message)" }
        }
        # PowerModes -> RyzenStates (AMD) - SYNC v39: rozdzielone AMD/Intel
        if ($configJson.PowerModes) {
            if ($configJson.PowerModes.Silent) {
                $Script:RyzenStates.Silent.Min = [int]$configJson.PowerModes.Silent.Min
                $Script:RyzenStates.Silent.Max = [int]$configJson.PowerModes.Silent.Max
            }
            if ($configJson.PowerModes.Balanced) {
                $Script:RyzenStates.Balanced.Min = [int]$configJson.PowerModes.Balanced.Min
                $Script:RyzenStates.Balanced.Max = [int]$configJson.PowerModes.Balanced.Max
            }
            if ($configJson.PowerModes.Turbo) {
                $Script:RyzenStates.Turbo.Min = [int]$configJson.PowerModes.Turbo.Min
                $Script:RyzenStates.Turbo.Max = [int]$configJson.PowerModes.Turbo.Max
            }
            if ($configJson.PowerModes.Extreme) {
                $Script:RyzenStates.Extreme.Min = [int]$configJson.PowerModes.Extreme.Min
                $Script:RyzenStates.Extreme.Max = [int]$configJson.PowerModes.Extreme.Max
            }
        }
        #  SYNC v39: PowerModesIntel -> IntelStates (osobne wartosci dla Intel)
        if ($configJson.PowerModesIntel) {
            # Uzyj osobnych wartosci Intel jesli sa zdefiniowane
            if ($configJson.PowerModesIntel.Silent) {
                $Script:IntelStates.Silent.Min = [int]$configJson.PowerModesIntel.Silent.Min
                $Script:IntelStates.Silent.Max = [int]$configJson.PowerModesIntel.Silent.Max
            }
            if ($configJson.PowerModesIntel.Balanced) {
                $Script:IntelStates.Balanced.Min = [int]$configJson.PowerModesIntel.Balanced.Min
                $Script:IntelStates.Balanced.Max = [int]$configJson.PowerModesIntel.Balanced.Max
            }
            if ($configJson.PowerModesIntel.Turbo) {
                $Script:IntelStates.Turbo.Min = [int]$configJson.PowerModesIntel.Turbo.Min
                $Script:IntelStates.Turbo.Max = [int]$configJson.PowerModesIntel.Turbo.Max
            }
            if ($configJson.PowerModesIntel.Extreme) {
                $Script:IntelStates.Extreme.Min = [int]$configJson.PowerModesIntel.Extreme.Min
                $Script:IntelStates.Extreme.Max = [int]$configJson.PowerModesIntel.Extreme.Max
            }
            Write-Log "CONFIG LOADED: PowerModesIntel applied (separate Intel values)" "CONFIG"
        } elseif ($configJson.PowerModes) {
            # Backward compatibility: jesli nie ma PowerModesIntel, uzyj PowerModes dla Intel
            if ($configJson.PowerModes.Silent) {
                $Script:IntelStates.Silent.Min = [int]$configJson.PowerModes.Silent.Min
                $Script:IntelStates.Silent.Max = [int]$configJson.PowerModes.Silent.Max
            }
            if ($configJson.PowerModes.Balanced) {
                $Script:IntelStates.Balanced.Min = [int]$configJson.PowerModes.Balanced.Min
                $Script:IntelStates.Balanced.Max = [int]$configJson.PowerModes.Balanced.Max
            }
            if ($configJson.PowerModes.Turbo) {
                $Script:IntelStates.Turbo.Min = [int]$configJson.PowerModes.Turbo.Min
                $Script:IntelStates.Turbo.Max = [int]$configJson.PowerModes.Turbo.Max
            }
            if ($configJson.PowerModes.Extreme) {
                $Script:IntelStates.Extreme.Min = [int]$configJson.PowerModes.Extreme.Min
                $Script:IntelStates.Extreme.Max = [int]$configJson.PowerModes.Extreme.Max
            }
        }
        # Diagnostics: log what was applied
        if ($configJson.PowerModes -or $configJson.PowerModesIntel) {
            try {
                $rs = $Script:RyzenStates
                $is = $Script:IntelStates
                Write-Log "CONFIG LOADED: AMD Silent=$($rs.Silent.Min)-$($rs.Silent.Max) Balanced=$($rs.Balanced.Min)-$($rs.Balanced.Max) Turbo=$($rs.Turbo.Min)-$($rs.Turbo.Max)" "CONFIG"
                Write-Log "CONFIG LOADED: Intel Silent=$($is.Silent.Min)-$($is.Silent.Max) Balanced=$($is.Balanced.Min)-$($is.Balanced.Max) Turbo=$($is.Turbo.Min)-$($is.Turbo.Max)" "CONFIG"
            } catch { }
        }
        # BoostSettings
        if ($configJson.BoostSettings) {
            if ($null -ne $configJson.BoostSettings.BoostDuration) {
                $Script:BoostDuration = [int]$configJson.BoostSettings.BoostDuration
            }
            #  NEW: BoostCooldown - czas miedzy Boostami tej samej aplikacji
            if ($null -ne $configJson.BoostSettings.BoostCooldown) {
                $Script:BoostCooldown = [int]$configJson.BoostSettings.BoostCooldown
            }
            if ($configJson.BoostSettings.AppLaunchSensitivity) {
                if ($null -ne $configJson.BoostSettings.AppLaunchSensitivity.CPUDelta) {
                    $Script:AppLaunchCPUDelta = [int]$configJson.BoostSettings.AppLaunchSensitivity.CPUDelta
                }
                if ($null -ne $configJson.BoostSettings.AppLaunchSensitivity.CPUThreshold) {
                    $Script:AppLaunchCPUThreshold = [int]$configJson.BoostSettings.AppLaunchSensitivity.CPUThreshold
                }
            }
            # AutoBoost settings (optional)
            if ($null -ne $configJson.BoostSettings.AutoBoostEnabled) {
                $Script:AutoBoostEnabled = [bool]$configJson.BoostSettings.AutoBoostEnabled
            }
            if ($null -ne $configJson.BoostSettings.AutoBoostSampleMs) {
                $Script:AutoBoostSampleMs = [int]$configJson.BoostSettings.AutoBoostSampleMs
            }
            if ($null -ne $configJson.BoostSettings.EnableBoostForAllAppsOnStart) {
                $Script:StartupBoostEnabled = [bool]$configJson.BoostSettings.EnableBoostForAllAppsOnStart
            }
            if ($null -ne $configJson.BoostSettings.ForceBoostOnNewApps) {
                $Script:ForceBoostOnNewApps = [bool]$configJson.BoostSettings.ForceBoostOnNewApps
            }
            if ($null -ne $configJson.BoostSettings.StartupBoostDurationSeconds) {
                $Script:StartupBoostDurationSeconds = [int]$configJson.BoostSettings.StartupBoostDurationSeconds
            }
            if ($null -ne $configJson.BoostSettings.ActivityBasedBoost) {
                $Script:ActivityBasedBoostEnabled = [bool]$configJson.BoostSettings.ActivityBasedBoost
            }
            if ($null -ne $configJson.BoostSettings.ActivityIdleThreshold) {
                $Script:ActivityIdleThreshold = [int]$configJson.BoostSettings.ActivityIdleThreshold
            }
            if ($null -ne $configJson.BoostSettings.ActivityMaxBoostTime) {
                $Script:ActivityMaxBoostTime = [int]$configJson.BoostSettings.ActivityMaxBoostTime
            }
        }
        # AdaptiveTimer
        if ($configJson.AdaptiveTimer) {
            if ($null -ne $configJson.AdaptiveTimer.DefaultInterval) {
                $Script:DefaultTimerInterval = [int]$configJson.AdaptiveTimer.DefaultInterval
            }
            if ($null -ne $configJson.AdaptiveTimer.MinInterval) {
                $Script:MinTimerInterval = [int]$configJson.AdaptiveTimer.MinInterval
            }
            if ($null -ne $configJson.AdaptiveTimer.MaxInterval) {
                $Script:MaxTimerInterval = [int]$configJson.AdaptiveTimer.MaxInterval
            }
            if ($null -ne $configJson.AdaptiveTimer.GamingInterval) {
                $Script:GamingTimerInterval = [int]$configJson.AdaptiveTimer.GamingInterval
            }
        }
        # AIThresholds
        if ($configJson.AIThresholds) {
            if ($null -ne $configJson.AIThresholds.ForceSilentCPU) {
                $Script:ForceSilentCPU = [int]$configJson.AIThresholds.ForceSilentCPU
            }
            if ($null -ne $configJson.AIThresholds.ForceSilentCPUInactive) {
                $Script:ForceSilentCPUInactive = [int]$configJson.AIThresholds.ForceSilentCPUInactive
            }
            if ($null -ne $configJson.AIThresholds.TurboThreshold) {
                $Script:TurboThreshold = [int]$configJson.AIThresholds.TurboThreshold
            }
            if ($null -ne $configJson.AIThresholds.BalancedThreshold) {
                $Script:BalancedThreshold = [int]$configJson.AIThresholds.BalancedThreshold
            }
            if ($null -ne $configJson.AIThresholds.ModeHoldTime) {
                $Script:ModeHoldTime = [Math]::Max(2, [Math]::Min(30, [int]$configJson.AIThresholds.ModeHoldTime))
            }
        }
        # IOSettings - Ustawienia czulosci I/O (NOWE!)
        if ($configJson.IOSettings) {
            if ($null -ne $configJson.IOSettings.ReadThreshold) {
                $Script:IOReadThreshold = [int]$configJson.IOSettings.ReadThreshold
            }
            if ($null -ne $configJson.IOSettings.WriteThreshold) {
                $Script:IOWriteThreshold = [int]$configJson.IOSettings.WriteThreshold
            }
            if ($null -ne $configJson.IOSettings.Sensitivity) {
                $Script:IOSensitivity = [int]$configJson.IOSettings.Sensitivity
            }
            if ($null -ne $configJson.IOSettings.CheckInterval) {
                $Script:IOCheckInterval = [int]$configJson.IOSettings.CheckInterval
            }
            if ($null -ne $configJson.IOSettings.TurboThreshold) {
                $Script:IOTurboThreshold = [int]$configJson.IOSettings.TurboThreshold
            }
            if ($null -ne $configJson.IOSettings.OverrideForceMode) {
                $Script:IOOverrideForceMode = [bool]$configJson.IOSettings.OverrideForceMode
            }
            if ($configJson.IOSettings.PSObject.Properties.Name -contains "ExtremeGraceSeconds" -and $null -ne $configJson.IOSettings.ExtremeGraceSeconds) {
                $Script:IOExtremeGraceSeconds = [int]$configJson.IOSettings.ExtremeGraceSeconds
            }
        }
        # Database / Prophet autosave settings
        if ($configJson.DatabaseSettings) {
            if ($null -ne $configJson.DatabaseSettings.ProphetAutosaveSeconds) {
                $Script:ProphetAutosaveSeconds = [int]$configJson.DatabaseSettings.ProphetAutosaveSeconds
            }
        }
        # OptimizationSettings - V38 advanced optimization
        if ($configJson.OptimizationSettings) {
            if ($null -ne $configJson.OptimizationSettings.PreloadEnabled) {
                $Script:PreloadEnabled = [bool]$configJson.OptimizationSettings.PreloadEnabled
            }
            if ($null -ne $configJson.OptimizationSettings.CacheSize) {
                $Script:CacheSize = [int]$configJson.OptimizationSettings.CacheSize
            }
            if ($null -ne $configJson.OptimizationSettings.PreBoostDuration) {
                $Script:PreBoostDuration = [int]$configJson.OptimizationSettings.PreBoostDuration
            }
            if ($null -ne $configJson.OptimizationSettings.PredictiveBoostEnabled) {
                $Script:PredictiveBoostEnabled = [bool]$configJson.OptimizationSettings.PredictiveBoostEnabled
            }
        }
        if ($null -ne $configJson.SmartPreload) {
            $Script:SmartPreload = [bool]$configJson.SmartPreload
        }
        if ($null -ne $configJson.MemoryCompression) {
            $Script:MemoryCompression = [bool]$configJson.MemoryCompression
        }
        if ($null -ne $configJson.PowerBoost) {
            $Script:PowerBoost = [bool]$configJson.PowerBoost
        }
        if ($null -ne $configJson.PredictiveIO) {
            $Script:PredictiveIO = [bool]$configJson.PredictiveIO
        }
        if ($null -ne $configJson.CPUAgressiveness) {
            $Script:CPUAgressiveness = [int]$configJson.CPUAgressiveness
        }
        if ($null -ne $configJson.ThermalLimit) {
            $Script:ThermalLimit = [int]$configJson.ThermalLimit
        }
        if ($null -ne $configJson.MemoryAgressiveness) {
            $Script:MemoryAgressiveness = [int]$configJson.MemoryAgressiveness
        }
        if ($null -ne $configJson.IOPriority) {
            $Script:IOPriority = [int]$configJson.IOPriority
        }
        if ($configJson.LearningSettings) {
            if ($null -ne $configJson.LearningSettings.BiasInfluence) {
                $Script:BiasInfluence = [Math]::Max(0, [Math]::Min(40, [int]$configJson.LearningSettings.BiasInfluence))
            }
            if ($null -ne $configJson.LearningSettings.ConfidenceThreshold) {
                $Script:ConfidenceThreshold = [Math]::Max(50, [Math]::Min(95, [int]$configJson.LearningSettings.ConfidenceThreshold))
            }
            if ($configJson.LearningSettings.LearningMode) {
                $Script:LearningMode = $configJson.LearningSettings.LearningMode
            }
        }
        # ═══════════════════════════════════════════════════════════════════════════════
        # ═══════════════════════════════════════════════════════════════════════════════
        if ($configJson.Network) {
            if ($null -ne $configJson.Network.Enabled) {
                $Script:NetworkOptimizerEnabled = [bool]$configJson.Network.Enabled
            }
            if ($null -ne $configJson.Network.DisableNagle) {
                $Script:NetworkDisableNagle = [bool]$configJson.Network.DisableNagle
            }
            if ($null -ne $configJson.Network.OptimizeTCP) {
                $Script:NetworkOptimizeTCP = [bool]$configJson.Network.OptimizeTCP
            }
            if ($null -ne $configJson.Network.OptimizeDNS) {
                $Script:NetworkOptimizeDNS = [bool]$configJson.Network.OptimizeDNS
            }
            # ULTRA Network Settings
            if ($null -ne $configJson.Network.MaximizeTCPBuffers) {
                $Script:NetworkMaximizeTCPBuffers = [bool]$configJson.Network.MaximizeTCPBuffers
            }
            if ($null -ne $configJson.Network.EnableWindowScaling) {
                $Script:NetworkEnableWindowScaling = [bool]$configJson.Network.EnableWindowScaling
            }
            if ($null -ne $configJson.Network.EnableRSS) {
                $Script:NetworkEnableRSS = [bool]$configJson.Network.EnableRSS
            }
            if ($null -ne $configJson.Network.EnableLSO) {
                $Script:NetworkEnableLSO = [bool]$configJson.Network.EnableLSO
            }
            if ($null -ne $configJson.Network.DisableChimney) {
                $Script:NetworkDisableChimney = [bool]$configJson.Network.DisableChimney
            }
        }
        # ═══════════════════════════════════════════════════════════════════════════════
        # ═══════════════════════════════════════════════════════════════════════════════
        if ($configJson.Privacy) {
            if ($null -ne $configJson.Privacy.Enabled) {
                $Script:PrivacyShieldEnabled = [bool]$configJson.Privacy.Enabled
            }
            if ($null -ne $configJson.Privacy.BlockTelemetry) {
                $Script:PrivacyBlockTelemetry = [bool]$configJson.Privacy.BlockTelemetry
            }
            if ($null -ne $configJson.Privacy.DisableCortana) {
                $Script:PrivacyDisableCortana = [bool]$configJson.Privacy.DisableCortana
            }
            if ($null -ne $configJson.Privacy.DisableLocation) {
                $Script:PrivacyDisableLocation = [bool]$configJson.Privacy.DisableLocation
            }
            if ($null -ne $configJson.Privacy.DisableAds) {
                $Script:PrivacyDisableAds = [bool]$configJson.Privacy.DisableAds
            }
            if ($null -ne $configJson.Privacy.DisableTimeline) {
                $Script:PrivacyDisableTimeline = [bool]$configJson.Privacy.DisableTimeline
            }
        }
        # ═══════════════════════════════════════════════════════════════════════════════
        # ═══════════════════════════════════════════════════════════════════════════════
        if ($configJson.Performance) {
            if ($null -ne $configJson.Performance.OptimizeMemory) {
                $Script:PerfOptimizeMemory = [bool]$configJson.Performance.OptimizeMemory
            }
            if ($null -ne $configJson.Performance.OptimizeFileSystem) {
                $Script:PerfOptimizeFileSystem = [bool]$configJson.Performance.OptimizeFileSystem
            }
            if ($null -ne $configJson.Performance.OptimizeVisualEffects) {
                $Script:PerfOptimizeVisualEffects = [bool]$configJson.Performance.OptimizeVisualEffects
            }
            if ($null -ne $configJson.Performance.OptimizeStartup) {
                $Script:PerfOptimizeStartup = [bool]$configJson.Performance.OptimizeStartup
            }
            if ($null -ne $configJson.Performance.OptimizeNetwork) {
                $Script:PerfOptimizeNetwork = [bool]$configJson.Performance.OptimizeNetwork
            }
        }
        # ═══════════════════════════════════════════════════════════════════════════════
        # ═══════════════════════════════════════════════════════════════════════════════
        if ($configJson.Services) {
            if ($null -ne $configJson.Services.DisableFax) {
                $Script:SvcDisableFax = [bool]$configJson.Services.DisableFax
            }
            if ($null -ne $configJson.Services.DisableRemoteAccess) {
                $Script:SvcDisableRemoteAccess = [bool]$configJson.Services.DisableRemoteAccess
            }
            if ($null -ne $configJson.Services.DisableTablet) {
                $Script:SvcDisableTablet = [bool]$configJson.Services.DisableTablet
            }
            if ($null -ne $configJson.Services.DisableSearch) {
                $Script:SvcDisableSearch = [bool]$configJson.Services.DisableSearch
            }
        }
        # Zapisz timestamp
        $Script:LastConfigModified = (Get-Item $Script:ConfigJsonPath).LastWriteTime
        if (-not $Silent) {
            Write-Host "  [CONFIG] Zaladowano config.json" -ForegroundColor Green
            if ($Script:ForceModeFromConfig) {
                Write-Host "    ForceMode: $($Script:ForceModeFromConfig)" -ForegroundColor Cyan
            } else {
                Write-Host "    ForceMode: AI (automatyczny)" -ForegroundColor Gray
            }
            Write-Host "    Silent: $($Script:RyzenStates.Silent.Min)-$($Script:RyzenStates.Silent.Max)%" -ForegroundColor Gray
            Write-Host "    Balanced: $($Script:RyzenStates.Balanced.Min)-$($Script:RyzenStates.Balanced.Max)%" -ForegroundColor Gray
            Write-Host "    Turbo: $($Script:RyzenStates.Turbo.Min)-$($Script:RyzenStates.Turbo.Max)%" -ForegroundColor Gray
            Write-Host "    BoostDuration: $($Script:BoostDuration)ms" -ForegroundColor Gray
            Write-Host "    I/O: Read=$($Script:IOReadThreshold)MB/s Write=$($Script:IOWriteThreshold)MB/s Sens=$($Script:IOSensitivity) Turbo=$($Script:IOTurboThreshold)MB/s Override=$($Script:IOOverrideForceMode) Grace=$($Script:IOExtremeGraceSeconds)s" -ForegroundColor Gray
            Write-Host "    Optimization: Preload=$($Script:PreloadEnabled) Cache=$($Script:CacheSize) PreBoost=$($Script:PreBoostDuration)ms Predictive=$($Script:PredictiveBoostEnabled)" -ForegroundColor Gray
            Write-Host "    Advanced: SmartPreload=$($Script:SmartPreload) MemCompress=$($Script:MemoryCompression) PowerBoost=$($Script:PowerBoost) PredIO=$($Script:PredictiveIO)" -ForegroundColor Gray
            Write-Host "    Aggression: CPU=$($Script:CPUAgressiveness) Memory=$($Script:MemoryAgressiveness) IOPriority=$($Script:IOPriority)" -ForegroundColor Gray
            Write-Host "    Database: autosave=$($Script:ProphetAutosaveSeconds)s" -ForegroundColor Gray
            Write-Host "    Network: Enabled=$($Script:NetworkOptimizerEnabled) Nagle=$($Script:NetworkDisableNagle) TCP=$($Script:NetworkOptimizeTCP) DNS=$($Script:NetworkOptimizeDNS)" -ForegroundColor Gray
            Write-Host "    Network ULTRA: Buffers=$($Script:NetworkMaximizeTCPBuffers) Scaling=$($Script:NetworkEnableWindowScaling) RSS=$($Script:NetworkEnableRSS) LSO=$($Script:NetworkEnableLSO) Chimney=$($Script:NetworkDisableChimney)" -ForegroundColor Cyan
            Write-Host "    Privacy: Enabled=$($Script:PrivacyShieldEnabled) Telemetry=$($Script:PrivacyBlockTelemetry) Cortana=$($Script:PrivacyDisableCortana) Location=$($Script:PrivacyDisableLocation)" -ForegroundColor Gray
            Write-Host "    Performance: Memory=$($Script:PerfOptimizeMemory) FS=$($Script:PerfOptimizeFileSystem) Visual=$($Script:PerfOptimizeVisualEffects) Startup=$($Script:PerfOptimizeStartup)" -ForegroundColor Gray
            Write-Host "    Services: Fax=$($Script:SvcDisableFax) Remote=$($Script:SvcDisableRemoteAccess) Tablet=$($Script:SvcDisableTablet) Search=$($Script:SvcDisableSearch)" -ForegroundColor Gray
        }
        return $true
    } catch {
        if (-not $Silent) { Write-Host "  [CONFIG] Blad ladowania config.json: $_" -ForegroundColor Red }
        return $false
    }
}
# ═══════════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════════
function Apply-ConfiguratorSettings {
    <#
    .SYNOPSIS
    Stosuje ustawienia Network/Privacy/Performance/Services z config.json do Windows
    Wywoływane przy starcie ENGINE i przy hot-reload config.json
    #>
    param([switch]$Force)
    # Nie stosuj wielokrotnie w tej samej sesji (chyba że Force)
    if ($Script:ConfiguratorSettingsApplied -and -not $Force) {
        return
    }
    Write-Host "`n  [v40] Stosowanie ustawień z CONFIGURATOR..." -ForegroundColor Cyan
    # ═══════════════════════════════════════════════════════════════════════════
    # PRIVACY - Stosuj ustawienia prywatności
    # ═══════════════════════════════════════════════════════════════════════════
    if ($Script:PrivacyShieldEnabled) {
        Write-Host "  [PRIVACY] Privacy Shield ENABLED" -ForegroundColor Green
        if ($Script:PrivacyBlockTelemetry) {
            try {
                # Wyłącz DiagTrack
                $diagJob = Start-Job -ScriptBlock {
                    Stop-Service "DiagTrack" -Force -ErrorAction SilentlyContinue
                    Set-Service "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue
                    Stop-Service "dmwappushservice" -Force -ErrorAction SilentlyContinue
                    Set-Service "dmwappushservice" -StartupType Disabled -ErrorAction SilentlyContinue
                }
                $null = Wait-Job $diagJob -Timeout 5
                Remove-Job $diagJob -Force -ErrorAction SilentlyContinue
                # Registry
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Write-Host "    ✓ Telemetria wyłączona" -ForegroundColor Green
            } catch { Write-Host "    ✗ Błąd telemetrii: $_" -ForegroundColor Red }
        }
        if ($Script:PrivacyDisableCortana) {
            try {
                New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Write-Host "    ✓ Cortana wyłączona" -ForegroundColor Green
            } catch { Write-Host "    ✗ Błąd Cortany: $_" -ForegroundColor Red }
        }
        if ($Script:PrivacyDisableLocation) {
            try {
                Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny" -ErrorAction SilentlyContinue
                Write-Host "    ✓ Lokalizacja wyłączona" -ForegroundColor Green
            } catch { Write-Host "    ✗ Błąd lokalizacji: $_" -ForegroundColor Red }
        }
        if ($Script:PrivacyDisableAds) {
            try {
                Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Write-Host "    ✓ Reklamy wyłączone" -ForegroundColor Green
            } catch { Write-Host "    ✗ Błąd reklam: $_" -ForegroundColor Red }
        }
        if ($Script:PrivacyDisableTimeline) {
            try {
                New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Force -ErrorAction SilentlyContinue | Out-Null
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Write-Host "    ✓ Oś czasu wyłączona" -ForegroundColor Green
            } catch { Write-Host "    ✗ Błąd osi czasu: $_" -ForegroundColor Red }
        }
    } else {
        Write-Host "  [PRIVACY] Privacy Shield DISABLED" -ForegroundColor Yellow
    }
    # ═══════════════════════════════════════════════════════════════════════════
    # PERFORMANCE - Stosuj ustawienia wydajności
    # ═══════════════════════════════════════════════════════════════════════════
    Write-Host "  [PERFORMANCE] Stosowanie optymalizacji wydajności..." -ForegroundColor Cyan
    if ($Script:PerfOptimizeMemory) {
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "LargeSystemCache" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "DisablePagingExecutive" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "    ✓ Pamięć zoptymalizowana" -ForegroundColor Green
        } catch { Write-Host "    ✗ Błąd pamięci: $_" -ForegroundColor Red }
    }
    if ($Script:PerfOptimizeFileSystem) {
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem" -Name "NtfsDisableLastAccessUpdate" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "    ✓ System plików zoptymalizowany" -ForegroundColor Green
        } catch { Write-Host "    ✗ Błąd systemu plików: $_" -ForegroundColor Red }
    }
    if ($Script:PerfOptimizeVisualEffects) {
        try {
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "    ✓ Efekty wizualne zoptymalizowane" -ForegroundColor Green
        } catch { Write-Host "    ✗ Błąd efektów: $_" -ForegroundColor Red }
    }
    if ($Script:PerfOptimizeStartup) {
        try {
            New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize" -Name "StartupDelayInMSec" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "    ✓ Startup zoptymalizowany" -ForegroundColor Green
        } catch { Write-Host "    ✗ Błąd startup: $_" -ForegroundColor Red }
    }
    # ═══════════════════════════════════════════════════════════════════════════
    # SERVICES - Stosuj ustawienia usług
    # ═══════════════════════════════════════════════════════════════════════════
    Write-Host "  [SERVICES] Stosowanie ustawień usług..." -ForegroundColor Cyan
    if ($Script:SvcDisableFax) {
        try {
            $faxJob = Start-Job { Stop-Service "Fax" -Force -EA SilentlyContinue; Set-Service "Fax" -StartupType Disabled -EA SilentlyContinue }
            $null = Wait-Job $faxJob -Timeout 3; Remove-Job $faxJob -Force -EA SilentlyContinue
            Write-Host "    ✓ Usługa faksów wyłączona" -ForegroundColor Green
        } catch { }
    }
    if ($Script:SvcDisableRemoteAccess) {
        try {
            $remoteJob = Start-Job { Stop-Service "RemoteRegistry" -Force -EA SilentlyContinue; Set-Service "RemoteRegistry" -StartupType Disabled -EA SilentlyContinue }
            $null = Wait-Job $remoteJob -Timeout 3; Remove-Job $remoteJob -Force -EA SilentlyContinue
            Write-Host "    ✓ Dostęp zdalny wyłączony" -ForegroundColor Green
        } catch { }
    }
    if ($Script:SvcDisableTablet) {
        try {
            $tabletJob = Start-Job { Stop-Service "TabletInputService" -Force -EA SilentlyContinue; Set-Service "TabletInputService" -StartupType Disabled -EA SilentlyContinue }
            $null = Wait-Job $tabletJob -Timeout 3; Remove-Job $tabletJob -Force -EA SilentlyContinue
            Write-Host "    ✓ Usługi tabletu wyłączone" -ForegroundColor Green
        } catch { }
    }
    if ($Script:SvcDisableSearch) {
        try {
            $searchJob = Start-Job { Stop-Service "WSearch" -Force -EA SilentlyContinue; Set-Service "WSearch" -StartupType Disabled -EA SilentlyContinue }
            $null = Wait-Job $searchJob -Timeout 5; Remove-Job $searchJob -Force -EA SilentlyContinue
            Write-Host "    ⚠ Windows Search wyłączony (wyszukiwanie nie będzie działać!)" -ForegroundColor Yellow
        } catch { }
    }
    $Script:ConfiguratorSettingsApplied = $true
    Write-Host "  [v40] Ustawienia CONFIGURATOR zastosowane!`n" -ForegroundColor Green
}

function Check-ConfigReload {
    <#
    .SYNOPSIS
     UNIFIED CONFIG RELOAD - Konsoliduje sprawdzanie reload.signal i timestamp-based config monitoring
    .DESCRIPTION
    Funkcja sprawdza:
    1. reload.signal (natychmiastowy reload z walidacja timestamp)
    2. Timestamp config.json (fallback, co 5s)
    3. AIEngines.json (co 10s w glownej petli)
    #>
    param([switch]$Silent)
    
    # === 0. NAJWYŻSZY PRIORYTET: Sprawdź ReloadCategories.signal (z zakładki App Categorization) ===
    $categoriesSignalPath = "C:\CPUManager\ReloadCategories.signal"
    if (Test-Path $categoriesSignalPath) {
        try {
            $signalContent = Get-Content $categoriesSignalPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if (-not $Silent) {
                Write-Host "`n  [CATEGORIES.SIGNAL] Otrzymano sygnal przeladowania kategorii aplikacji" -ForegroundColor Magenta
            }
            
            # Przeladuj AppCategories
            $result = Load-AppCategories
            if ($result -and -not $Silent) {
                Write-Host "  [RELOAD] AppCategories.json przeladowany - $($Script:AppCategoryPreferences.Count) apps" -ForegroundColor Green
                
                # Log aplikacje z HardLock
                $hardLockApps = @()
                foreach ($key in $Script:AppCategoryPreferences.Keys) {
                    if ($Script:AppCategoryPreferences[$key].HardLock) {
                        $bias = $Script:AppCategoryPreferences[$key].Bias
                        $mode = if ($bias -le 0.2) { "Silent" } elseif ($bias -ge 0.8) { "Turbo" } else { "Balanced" }
                        $hardLockApps += "$key=$mode"
                    }
                }
                if ($hardLockApps.Count -gt 0) {
                    Write-Host "  [HARDLOCK] Apps: $($hardLockApps -join ', ')" -ForegroundColor Yellow
                }
            }
            
            # Usun plik sygnalu po przetworzeniu
            Remove-Item $categoriesSignalPath -Force -ErrorAction SilentlyContinue
            
            Add-Log "RELOAD: AppCategories from Configurator signal"
        } catch {
            Write-ErrorLog -Component "RELOAD" -ErrorMessage "Failed to process categories signal" -Details $_.Exception.Message
        }
    }
    
    # === 1. PRIORYTET: Sprawdz reload.signal (najszybsza sciezka) ===
    # FIX v40.2: Usuwanie reload.signal po przetworzeniu (zapobiega stale signal po restarcie ENGINE)
    if (Test-Path $Script:ReloadSignalPath) {
        try {
            $signalInfo = Get-Item $Script:ReloadSignalPath -ErrorAction Stop
            $signalTime = $signalInfo.LastWriteTime
            
            # Sprawdz czy to nowy sygnal (nowszy niz ostatnio przetworzony)
            if ($signalTime -gt $Script:LastReloadSignalTime) {
                $Script:LastReloadSignalTime = $signalTime
                
                # Odczytaj zawartosc sygnalu
                try {
                    $signalContent = Get-Content $Script:ReloadSignalPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    $signalFile = if ($signalContent.File) { $signalContent.File } else { "Config" }
                    
                    if (-not $Silent) {
                        Write-Host "`n  [RELOAD.SIGNAL] Otrzymano sygnal od CONFIGURATOR: $signalFile" -ForegroundColor Magenta
                    }
                    
                    # Reaguj na typ sygnalu
                    switch ($signalFile) {
                        "Config" {
                            Load-ExternalConfig -Silent:$Silent | Out-Null
                            # FIX v40.1: Zastosuj ustawienia Privacy/Services/Performance po reload
                            $Script:ConfiguratorSettingsApplied = $false  # Reset flagi
                            Apply-ConfiguratorSettings -Force
                            $Script:LastPowerMode = ""
                            # FIX v40.3: Reset IntelPM.LastMode żeby nowe PowerModesIntel się zastosowały
                            if ($Script:IntelPM) { $Script:IntelPM.LastMode = "" }
                        }
                        "AIEngines" {
                            Load-AIEnginesConfig | Out-Null
                            if (-not $Silent) {
                                Write-Host "  [RELOAD] AIEngines.json przeladowany" -ForegroundColor Green
                            }
                        }
                        "TDPConfig" {
                            # TDP jest ladowany przez Load-ExternalConfig
                            Load-ExternalConfig -Silent:$Silent | Out-Null
                            if (-not $Silent) {
                                Write-Host "  [RELOAD] TDPConfig przeladowany" -ForegroundColor Green
                            }
                        }
                        "NetworkDefaults" {
                            Load-ExternalConfig -Silent:$Silent | Out-Null
                            # Zastosuj Network optymalizacje
                            if ($Script:NetworkOptimizerEnabled -and $Script:NetworkOptimizerInstance) {
                                $Script:NetworkOptimizerInstance.ApplyOptimizations()
                                if (-not $Silent) {
                                    Write-Host "  [RELOAD] Network optimizations re-applied" -ForegroundColor Green
                                }
                            }
                        }
                        default {
                            Load-ExternalConfig -Silent:$Silent | Out-Null
                        }
                    }
                    
                    if ($Script:ProcessWatcherInstance -and $Script:BoostCooldown -gt 0) {
                        $Script:ProcessWatcherInstance.BoostCooldownSeconds = [Math]::Max(5, [int]$Script:BoostCooldown)
                    }
                    
                    # FIX v40.2: Usun reload.signal po przetworzeniu
                    Remove-Item $Script:ReloadSignalPath -Force -ErrorAction SilentlyContinue
                    
                    return $true
                } catch {
                    # Nie udalo sie odczytac JSON - zaladuj config jako fallback
                    Load-ExternalConfig -Silent:$Silent | Out-Null
                    Remove-Item $Script:ReloadSignalPath -Force -ErrorAction SilentlyContinue
                    return $true
                }
            }
        } catch {
            # Blad odczytu pliku sygnalu - ignoruj
        }
    }
    
    # === 2. FALLBACK: Timestamp-based monitoring dla config.json ===
    $now = [DateTime]::Now
    if (($now - $Script:LastConfigCheck).TotalSeconds -ge $Script:ConfigCheckInterval) {
        $Script:LastConfigCheck = $now
        if (Test-Path $Script:ConfigJsonPath) {
            try {
                $currentModified = (Get-Item $Script:ConfigJsonPath).LastWriteTime
                if ($currentModified -gt $Script:LastConfigModified) {
                    if (-not $Silent) {
                        Write-Host "`n  [AUTO-RELOAD] Config.json zmieniony - przeladowuje..." -ForegroundColor Cyan
                    }
                    Load-ExternalConfig -Silent:$Silent | Out-Null
                    # FIX v40.1: Zastosuj ustawienia Privacy/Services/Performance po timestamp reload
                    $Script:ConfiguratorSettingsApplied = $false  # Reset flagi
                    Apply-ConfiguratorSettings -Force
                    if ($Script:ProcessWatcherInstance -and $Script:BoostCooldown -gt 0) {
                        $Script:ProcessWatcherInstance.BoostCooldownSeconds = [Math]::Max(5, [int]$Script:BoostCooldown)
                    }
                    $Script:LastPowerMode = ""
                    # FIX v40.3: Reset IntelPM.LastMode żeby nowe PowerModesIntel się zastosowały
                    if ($Script:IntelPM) { $Script:IntelPM.LastMode = "" }
                    return $true
                }
            } catch {
                # Ignoruj bledy odczytu (plik moze byc w trakcie zapisu)
            }
        }
    }
    
    return $false
}

# Domyslne wartosci dla parametrow (przed zaladowaniem config.json)
$Script:ForceModeFromConfig = ""
$Script:AppLaunchCPUDelta = 12
$Script:AppLaunchCPUThreshold = 22
$Script:DefaultTimerInterval = 1000
$Script:MinTimerInterval = 400
$Script:MaxTimerInterval = 2500
$Script:GamingTimerInterval = 500
$Script:ForceSilentCPU = 30   # v40.3: Podwyższone z 20 — CPU <30% = ZAWSZE Silent (mniej przełączania, ciszej)
$Script:ForceSilentCPUInactive = 25
$Script:TurboThreshold = 72
$Script:BalancedThreshold = 38
$Script:ModeHoldTime = 6     # Sekund minimalnego czasu w trybie przed zmiana (debounce, konfigurowalne)
$Script:BoostCooldown = 20  #  NEW: Domyslny cooldown miedzy Boostami (sekundy)
# === I/O SENSITIVITY SETTINGS (z config.json) ===
$Script:IOReadThreshold = 80      # MB/s - prog odczytu wyzwalajacy reakcje
$Script:IOWriteThreshold = 50     # MB/s - prog zapisu wyzwalajacy reakcje  
$Script:IOSensitivity = 4         # 1-10 skala czulosci (1=niska, 10=bardzo wysoka)
$Script:IOCheckInterval = 1200    # ms - interwal sprawdzania aktywnosci I/O
$Script:IOTurboThreshold = 150    # MB/s - prog I/O dla wymuszenia Turbo
$Script:IOOverrideForceMode = $false  # Czy I/O moze nadpisac ForceMode
$Script:LastIOCheck = [DateTime]::Now
$Script:IOBoostActive = $false
$Script:IOBoostStartTime = [DateTime]::MinValue
$Script:LastIOThresholdEvent = [DateTime]::MinValue   # Sledzi ostatni wysoki ruch I/O
$Script:IOExtremeGraceSeconds = 8                     # Sekundy ciszy wymagane przed wymuszeniem Extreme
# === OPTIMIZATION SETTINGS (z config.json) ===
$Script:PreloadEnabled = $true              # Preload enabled
$Script:CacheSize = 50                      # App cache size
$Script:ProphetCacheLimit = 50              # V38: Prophet max apps (same as CacheSize default)
$Script:PreBoostDuration = 15000            # Pre-boost duration (ms)
$Script:PredictiveBoostEnabled = $true      # Predictive boost
$Script:SmartPreload = $true                # Smart preload
$Script:MemoryCompression = $false          # Memory compression
$Script:PowerBoost = $false                 # Power boost mode
$Script:PredictiveIO = $true                # Predykcyjne I/O
$Script:CPUAgressiveness = 50               # CPU aggressiveness (0-100)
$Script:MemoryAgressiveness = 30            # Memory aggressiveness (0-100)
$Script:IOPriority = 3                      # IO priority (1-5)
$Script:BiasInfluence = 25                  # User bias influence (0-40)
$Script:ConfidenceThreshold = 70            # AI confidence threshold (50-95)
$Script:LearningMode = "AUTO"               # Learning mode: AUTO, MANUAL, HYBRID
# ═══════════════════════════════════════════════════════════════════════════════
# Te ustawienia są czytane z config.json (wysyłane przez CONFIGURATOR)
# ═══════════════════════════════════════════════════════════════════════════════
# Network Settings (domyślnie WŁĄCZONE - ENGINE potrzebuje tego dla NetworkOptimizer)
$Script:NetworkOptimizerEnabled = $true     # Główny przełącznik Network Optimizer
$Script:NetworkDisableNagle = $true         # Wyłącz Nagle Algorithm (niższy ping)
$Script:NetworkOptimizeTCP = $true          # Optymalizuj TCP/ACK
$Script:NetworkOptimizeDNS = $true          # Ustaw Cloudflare DNS
# ULTRA Network Settings (domyślnie WŁĄCZONE - maksymalna przepustowość)
$Script:NetworkMaximizeTCPBuffers = $true   # Maksymalne bufory TCP/IP
$Script:NetworkEnableWindowScaling = $true  # TCP Window Scaling dla gigabit
$Script:NetworkEnableRSS = $true            # RSS (Receive Side Scaling) multi-core
$Script:NetworkEnableLSO = $true            # LSO (Large Send Offload) dla dużych transferów
$Script:NetworkDisableChimney = $true       # Wyłącz TCP Chimney (problematyczny)
# Privacy Settings (domyślnie WYŁĄCZONE - tylko CONFIGURATOR włącza)
$Script:PrivacyShieldEnabled = $false       # Główny przełącznik Privacy Shield
$Script:PrivacyBlockTelemetry = $false      # Blokuj telemetrię Microsoft
$Script:PrivacyDisableCortana = $false      # Wyłącz Cortanę
$Script:PrivacyDisableLocation = $false     # Wyłącz lokalizację
$Script:PrivacyDisableAds = $false          # Wyłącz reklamy
$Script:PrivacyDisableTimeline = $false     # Wyłącz oś czasu
# Performance Settings (domyślnie WYŁĄCZONE - tylko CONFIGURATOR włącza)
$Script:PerfOptimizeMemory = $false         # Optymalizuj pamięć
$Script:PerfOptimizeFileSystem = $false     # Optymalizuj system plików
$Script:PerfOptimizeVisualEffects = $false  # Optymalizuj efekty (opcjonalne)
$Script:PerfOptimizeStartup = $false        # Optymalizuj startup
$Script:PerfOptimizeNetwork = $false        # Optymalizuj sieć
# Services Settings (domyślnie WYŁĄCZONE - tylko CONFIGURATOR włącza)
$Script:SvcDisableFax = $false              # Wyłącz usługę faksów
$Script:SvcDisableRemoteAccess = $false     # Wyłącz zdalny dostęp
$Script:SvcDisableTablet = $false           # Wyłącz usługi tabletu
$Script:SvcDisableSearch = $false           # Wyłącz Windows Search (OSTROŻNIE!)
# Flaga czy ustawienia zostały już zastosowane w tej sesji
$Script:ConfiguratorSettingsApplied = $false
# Domyslne wartosci
$Global:AI_Active     = $true
$Global:DebugMode     = $false
$Script:SavedManualMode = "Balanced"
# #
# #
$Global:EcoMode = $false                              # Tryb eco (agresywniejszy Silent)
# Progi EcoMode (bardziej agresywne przelaczanie na Silent)
$Script:EcoMode_SilentCPUThreshold = 25               # Silent gdy CPU < 25% (normalnie 15%)
$Script:EcoMode_SilentRAMThreshold = 75               # Silent gdy RAM < 75% (normalnie 60%)
$Script:EcoMode_BalancedCPUThreshold = 50             # Balanced gdy CPU < 50% (normalnie 35%)
$Script:EcoMode_TurboDelay = 3                        # Sekundy opoznienia przed Turbo (normalnie 0)
$Script:EcoMode_FastSilentReturn = $true              # Szybki powrot do Silent po spadku CPU
# Progi normalne (dla porownania)
$Script:Normal_SilentCPUThreshold = 15
$Script:Normal_SilentRAMThreshold = 60
$Script:Normal_BalancedCPUThreshold = 35
# #
# #
$Script:SilentModeActive = $false
$Script:SilentLockMode = $false
$Script:LastBoostNotification = [DateTime]::MinValue
$Script:BoostNotificationCooldown = 30
$Script:PendingBoostApp = ""
$Script:UserApprovedBoosts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$Script:UserForcedMode = ""
$Script:UserForcedTime = [DateTime]::MinValue
$Script:LastHighActivityTime = [DateTime]::Now
$Script:AutoRestoreAIDelaySeconds = 45
$Script:QuietCPUThreshold = 18
$Script:StartTime = [DateTime]::Now
# Wczytaj zapisane ustawienia jesli istnieja
try {
    if (Test-Path $Script:SettingsPath) {
        $savedSettings = Get-Content $Script:SettingsPath -Raw | ConvertFrom-Json
        if ($null -ne $savedSettings.AI_Active) { $Global:AI_Active = $savedSettings.AI_Active }
        if ($null -ne $savedSettings.DebugMode) { $Global:DebugMode = $savedSettings.DebugMode }
        if ($null -ne $savedSettings.EcoMode) { $Global:EcoMode = $savedSettings.EcoMode }
        if ($savedSettings.ManualMode) { $Script:SavedManualMode = $savedSettings.ManualMode }
        Write-Host "  [OK] Ustawienia wczytane z poprzedniej sesji" -ForegroundColor Green
    }
} catch { }
# #
# #
function Get-SilentCPUThreshold {
    if ($Global:EcoMode) { return $Script:EcoMode_SilentCPUThreshold }
    return $Script:Normal_SilentCPUThreshold
}
function Get-SilentRAMThreshold {
    if ($Global:EcoMode) { return $Script:EcoMode_SilentRAMThreshold }
    return $Script:Normal_SilentRAMThreshold
}
function Get-BalancedCPUThreshold {
    if ($Global:EcoMode) { return $Script:EcoMode_BalancedCPUThreshold }
    return $Script:Normal_BalancedCPUThreshold
}
function Should-DelaySwitchToTurbo {
    # W EcoMode opozniamy przelaczanie na Turbo o kilka sekund
    # (zapobiega krotkim spike'om CPU powodujacym niepotrzebny Turbo)
    if (-not $Global:EcoMode) { return $false }
    if (-not $Script:LastTurboRequest) { 
        $Script:LastTurboRequest = [DateTime]::Now
        return $true 
    }
    $elapsed = ([DateTime]::Now - $Script:LastTurboRequest).TotalSeconds
    if ($elapsed -ge $Script:EcoMode_TurboDelay) {
        return $false  # OK, mozna przelaczyc
    }
    return $true  # Jeszcze czekaj
}
function Reset-TurboDelay {
    $Script:LastTurboRequest = $null
}
# LISTA IGNOROWANYCH PROCESOW DLA AI
# AI ignoruje te procesy systemowe, pomocnicze i malo wazne
$Script:BlacklistSet = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        # #
        # KRYTYCZNE PROCESY SYSTEMOWE WINDOWS
        # #
        "System", "Idle", "Registry", "smss", "csrss", "wininit", "services",
        "lsass", "lsaiso", "winlogon", "fontdrvhost", "Memory Compression",
        "spoolsv", "svchost", "WerFault", "WerFaultSecure", "wermgr",
        "dwm", "conhost", "dllhost", "sihost", "taskhostw", "audiodg",
        "WmiPrvSE", "WmiApSrv", "msdtc", "vds", "vmms", "vmwp",
        # #
        # PROCESY POWLOKI I EKSPLORATORA WINDOWS
        # #
        "explorer", "SearchApp", "SearchHost", "SearchIndexer", "SearchProtocolHost",
        "SearchFilterHost", "RuntimeBroker", "Taskmgr", "ctfmon", "CTFMON",
        "StartMenuExperienceHost", "ShellExperienceHost", "TextInputHost",
        "ApplicationFrameHost", "SystemSettings", "LockApp", "Widgets",
        "WidgetService", "smartscreen", "SecurityHealthSystray", "UserOOBEBroker",
        "SettingSyncHost", "PhoneExperienceHost", "YourPhone", "YourPhoneServer",
        # #
        # WINDOWS DEFENDER / BEZPIECZENSTWO
        # #
        "MsMpEng", "NisSrv", "SecurityHealthService", "SgrmBroker",
        "MpCmdRun", "MpDefenderCoreService", "MsSense", "SenseCncProxy",
        "SenseIR", "SenseNdr", "wscsvc",
        # #
        # TERMINALE I POWERSHELL (nie chcemy boostowac samych siebie)
        # #
        "powershell", "pwsh", "powershell_ise", "WindowsTerminal", "cmd",
        "OpenConsole", "wt", "mintty", "ConEmu", "ConEmu64", "ConEmuC",
        "ConEmuC64", "Cmder", "Hyper", "Terminus", "Alacritty",
        # #
        # MICROSOFT EDGE I PROCESY POMOCNICZE
        # #
        "msedge", "msedgewebview2", "MicrosoftEdge", "MicrosoftEdgeUpdate",
        "edge", "msedge_pwa_launcher", "MicrosoftEdgeCP", "browser_broker",
        # #
        # PROCESY POMOCNICZE PRZEGLADAREK I APLIKACJI
        # #
        "identity_helper", "elevation_service", "notification_helper",
        "crashpad_handler", "nacl64", "pwahelper", "setup", "update",
        "updater", "installer", "uninstaller", "helper", "broker",
        "renderer", "gpu-process", "utility", "crashreporter",
        "plugin-container", "ServiceWorker", "WebView", "CefSharp.BrowserSubprocess",
        "QtWebEngineProcess", "nacl_helper", "zygote",
        # #
        # WINDOWS UWP / MODERN APP HELPERS
        # #
        "SearchUI", "CompPkgSrv", "backgroundTaskHost", "BackgroundTransferHost",
        "AppHostRegistrationVerifier", "dasHost", "CompatTelRunner", "DeviceCensus",
        "musNotification", "musNotificationUx", "MusNotifyIcon", "UsoClient",
        # #
        # XBOX / GAME BAR (tlo dla gier, nie same gry)
        # #
        "GameBar", "GameBarFTServer", "GameBarPresenceWriter", "GameInputSvc",
        "XboxIdp", "XblAuthManager", "XboxGipSvc", "gamingservices", "gamingservicesnet",
        "BcastDVRUserService", "GamingServices", "XboxNetApiSvc",
        # #
        # NVIDIA / AMD / INTEL PROCESY TLA (sterowniki, telemetria)
        # #
        "NVDisplay.Container", "nvcontainer", "NVIDIA Web Helper", "NvTelemetryContainer",
        "NvBackend", "NvNode", "nvidia-smi", "nvsphelper64", "NvOAWrapperCache",
        "RadeonSoftware", "AMDRSServ", "aaborc", "atieclxx", "atiesrxx",
        "cncmd", "AMDRyzenMasterDriverV21", "AMDRyzenMasterService",
        "igfxCUIService", "igfxEM", "igfxHK", "igfxTray", "IntelCpHDCPSvc",
        "IntelCpHeciSvc", "esif_uf", "OfficeClickToRun",
        # #
        # AUDIO / KOMUNIKACJA (uslugi tla)
        # #
        "AudioSrv", "Audiosrv", "RtkAudUService64", "RtkUService64",
        "RtkBtManServ", "cAVS Audio Service", "DolbyDAX2API", "DolbyDAXAPI",
        "NahimicService", "NahimicSvc64", "nhAsusStrixSvc", "SteelSeriesGG",
        "SteelSeriesEngine", "RazerCentralService", "Razer Synapse Service",
        # #
        # SIEC / LACZNOSC (uslugi tla)
        # #
        "NcsiClient", "netprofm", "WlanSvc", "Wlansvc", "WwanSvc", "vnetlib64",
        "PnkBstrA", "PnkBstrB", "EasyAntiCheat", "BEService", "BattleEye",
        "vmnetdhcp", "vmnat", "vmware-authd", "vpnkit",
        # #
        # WINDOWS UPDATE / TELEMETRIA
        # #
        "TiWorker", "TrustedInstaller", "wuauclt", "wuauserv", "WaaSMedicAgent",
        "SIHClient", "DiagTrack", "diagsvc", "CompatTelRunner",
        "DiagnosticsHub.StandardCollector.Service", "PerfWatson2", "vscmon",
        # #
        # NARZEDZIA SYSTEMOWE / MONITORING
        # #
        "perfmon", "resmon", "mmc", "eventvwr", "compmgmt", "devmgmt", "diskmgmt",
        "dfrgui", "cleanmgr", "msconfig", "msinfo32", "dxdiag", "winver",
        "SystemInformer", "ProcessHacker", "procexp", "procexp64",
        "Procmon", "Procmon64", "autoruns", "autoruns64", "tcpview", "tcpview64",
        # #
        # USLUGI CHMUROWE (OneDrive, Dropbox, Google itp.)
        # #
        "OneDrive", "OneDriveStandaloneUpdater", "FileCoAuth", "FileSyncHelper",
        "Dropbox", "DropboxUpdate", "GoogleDriveFS", "googledrivesync",
        "iCloudServices", "iCloudDrive", "iCloudPhotos", "AppleMobileDeviceService",
        # #
        # INNE PROCESY TLA I SERWISY
        # #
        "msiexec", "TiWorker", "wusa", "SystemSettingsBroker",
        "CredentialUIBroker", "WindowsInternal.ComposableShell.Experiences.TextInput.InputApp",
        "WMIC", "wbem", "winmgmt", "scrcons", "unsecapp",
        "sppsvc", "SppExtComObj", "SgrmBroker", "sgrmbroker",
        "AggregatorHost", "MoUsoCoreWorker", "SpeechRuntime", "Cortana",
        "PresentationFontCache", "fontcache", "lsm", "DcomLaunch",
        "PlugPlay", "Dhcp", "Dnscache", "NlaSvc", "nsi", "Tcpip", "AFD",
        "CryptSvc", "KeyIso", "SamSs", "VaultSvc", "gpsvc", "Schedule",
        "SENS", "Themes", "UxSms", "WinHttpAutoProxySvc",
        # #
        # HYPER-V / WIRTUALIZACJA
        # #
        "vmcompute", "vmwp", "vmmem", "Vmmem", "vmconnect", "vmms",
        "VBoxSVC", "VBoxSDS", "VirtualBox", "VirtualBoxVM",
        # #
        # POPULARNE APLIKACJE TLA (launchers, tray icons)
        # #
        "steamwebhelper", "Steam Client WebHelper", "GameOverlayUI",
        "SteamService", "steam_monitor", "steamwebhelper",
        "EpicGamesLauncher", "EpicWebHelper", "UnrealCEFSubProcess",
        "Origin", "OriginWebHelperService", "OriginClientService",
        "GalaxyClient Helper", "GOG Galaxy Notifications Renderer",
        "UbisoftGameLauncher", "upc", "UplayWebCore",
        "Ubisoft Game Launcher", "BattleNetHelper", "Battle.net Helper",
        # #
        # DISCORD / KOMUNIKATORY (procesy pomocnicze)
        # #
        "Discord PTB", "DiscordPTB", "Discord Canary", "DiscordCanary",
        "Slack Helper", "slack helper", "Teams", "ms-teams", "msteams",
        "Zoom", "CptHost", "ZoomOutlookIMPlugin", "ZoomWebviewHost",
        # #
        # INNE POMOCNICZE
        # #
        "ShareX", "Lightshot", "Greenshot", "ScreenClippingHost", "SnippingTool",
        "SystemInformer", "HWiNFO64", "CPUZ", "GPU-Z", "HWMonitor", "CoreTemp",
        "MSIAfterburner", "RTSS", "RivaTuner", "RivaTunerStatisticsServer",
        "FanControl", "SpeedFan", "Open Hardware Monitor",
        "Everything", "WizTree", "TreeSize", "bleachbit", "CCleaner", "CCleaner64"
    ), [System.StringComparer]::OrdinalIgnoreCase
)
# === STANY MOCY DLA PROCESOROW ===
$Script:RyzenStates = @{
    Silent   = @{ Min=50;   Max=85  }   # AMD: Cichy tryb (responsywny, wentylator cicho)
    Balanced = @{ Min=70;   Max=99  }   # AMD: Praca biurowa, kodowanie (stabilne Balanced)
    Turbo    = @{ Min=85;   Max=100 }   # AMD: Gaming, kompilacja (agresywny Turbo)
    Extreme  = @{ Min=100;  Max=100 }   # AMD: Benchmark, rendering (pelna moc)
}
$Script:IntelStates = @{
    Silent   = @{ Min=50;   Max=50  }   # Intel: Cichy tryb — 50%=1.3GHz bazowa, NIE pozwalaj na skoki wyżej
    Balanced = @{ Min=50;   Max=99  }   # Intel: Praca biurowa — od bazy do prawie max, Windows sam reguluje
    Turbo    = @{ Min=99;   Max=100 }   # Intel: Gaming, kompilacja (pelna moc)
    Extreme  = @{ Min=100;  Max=100 }   # Intel: Benchmark, rendering (max staly)
}
# ================== AI ENGINES CONTROL (Ensemble/NeuralBrain) =====================
# Sciezki do plikow danych silnikow
$Script:EnsembleDataPath = Join-Path $Script:ConfigDir "EnsembleWeights.json"
$Script:NeuralBrainDataPath = Join-Path $Script:ConfigDir "BrainState.json"
$Script:TransferCachePath = Join-Path $Script:ConfigDir "TransferCache.json"
$Script:AIEnginesConfigPath = Join-Path $Script:ConfigDir "AIEngines.json"
# Tworzenie plikow danych silnikow przy pierwszym uruchomieniu
if (-not (Test-Path $Script:EnsembleDataPath)) {
    '{}' | Set-Content $Script:EnsembleDataPath -Encoding UTF8 -Force
}
if (-not (Test-Path $Script:NeuralBrainDataPath)) {
    '{}' | Set-Content $Script:NeuralBrainDataPath -Encoding UTF8 -Force
}
if (-not (Test-Path $Script:TransferCachePath)) {
    @{ 
        Timestamp = (Get-Date).ToString("o")
        ModePreferences = @{}
        ModeEffectiveness = @{}
        ContextPatterns = @()
        AppPatterns = @()
    } | ConvertTo-Json | Set-Content $Script:TransferCachePath -Encoding UTF8 -Force
}
# Helpery do sprawdzania stanu (dynamicznie na podstawie $Script:AIEngines)
function Is-EnsembleEnabled { return $Script:AIEngines.Ensemble -eq $true }
function Is-NeuralBrainEnabled { return $Script:AIEngines.NeuralBrain -eq $true }
function Is-ProphetEnabled { return $Script:AIEngines.Prophet -eq $true }
# v42.6: Dodano brakujące helpery - CONFIGURATOR może teraz kontrolować wszystkie silniki
function Is-QLearningEnabled { return $Script:AIEngines.QLearning -eq $true }
function Is-SelfTunerEnabled { return $Script:AIEngines.SelfTuner -eq $true }
function Is-ChainEnabled { return $Script:AIEngines.ChainPredictor -eq $true }
function Is-LoadPredictorEnabled { return $Script:AIEngines.LoadPredictor -eq $true }
function Is-AnomalyEnabled { return $Script:AIEngines.AnomalyDetector -eq $true }
function Is-BanditEnabled { return $Script:AIEngines.Bandit -eq $true }
function Is-GeneticEnabled { return $Script:AIEngines.Genetic -eq $true }
function Is-EnergyEnabled { return $Script:AIEngines.Energy -eq $true }
# ================== BLOKOWANIE LOGIKI SILNIKOW =====================
# Przyklad uzycia w logice silnikow:
# if (Is-EnsembleEnabled) { ... } else { # nie uruchamiaj }
# if (Is-NeuralBrainEnabled) { ... } else { # nie uruchamiaj }
# Przyklad: blokada inicjalizacji i zapisu
# ...
# if (Is-EnsembleEnabled) {
#     # uruchom logike Ensemble
#     # zapisuj do $Script:EnsembleDataPath
# } else {
#     # NIE uruchamiaj, NIE nadpisuj pliku
# }
# if (Is-NeuralBrainEnabled) {
#     # uruchom logike NeuralBrain
#     # zapisuj do $Script:NeuralBrainDataPath
# } else {
#     # NIE uruchamiaj, NIE nadpisuj pliku
# }
# W dowolnym miejscu, gdzie jest logika tych silnikow, nalezy dodac powyzsze warunki.
# Funkcja wyboru stanow w zaleznosci od CPU
function Get-PowerStates {
    if ($Script:CPUType -eq "Intel") {
        return $Script:IntelStates
    } else {
        return $Script:RyzenStates
    }
}
# BOOST TURBO Tracking
$Script:BoostActive = $false
$Script:BoostStartTime = 0
$Script:BoostDuration = 10000
$Script:LastCPU = 0
$Script:LastProcessCount = 0
$Script:AutoBoostEnabled = $true
$Script:AutoBoostSampleMs = 350
$Script:ProphetAutosaveSeconds = 20
$Script:ForceBoostOnNewApps = $true
$Script:StartupBoostEnabled = $true
$Script:StartupBoostDurationSeconds = 3   # Legacy - now using Activity-Based
$Script:ActivityBoostApps = @{}           # v40: Activity-Based Boost tracking
$Script:ActiveStartupBoost = $null
$Script:ProcessWatcherInstance = $null
$Script:ActivityBasedBoostEnabled = $true  # Enable Activity-Based Boost
$Script:ActivityIdleThreshold = 5          # CPU% below which app is idle
$Script:ActivityMaxBoostTime = 30          # Max boost time in seconds (safety)
# Zastepuje stary AppNameMap - dziala dla KAZDEJ aplikacji automatycznie
# Cache dla nazw procesow (zeby nie odpytywac za kazdym razem)
$Script:ProcessNameCache = @{}
$Script:ProcessNameCacheExpiry = @{}
$Script:CacheExpiryMinutes = 5
function Get-ProcessDisplayName {
    <#
    .SYNOPSIS
    Pobiera przyjazna nazwe procesu z metadanych Windows (FileDescription, ProductName, WindowTitle)
    Automatycznie dziala dla kazdej aplikacji bez recznego mapowania.
    #>
    param(
        [string]$ProcessName,
        [System.Diagnostics.Process]$Process = $null
    )
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return "Desktop" }
    # Sprawdz cache
    $now = Get-Date
    if ($Script:ProcessNameCache.ContainsKey($ProcessName)) {
        $expiry = $Script:ProcessNameCacheExpiry[$ProcessName]
        if ($now -lt $expiry) {
            return $Script:ProcessNameCache[$ProcessName]
        }
    }
    $displayName = $ProcessName
    try {
        # Pobierz proces jesli nie podano
        if ($null -eq $Process) {
            $Process = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($Process) {
            # Metoda 1: FileVersionInfo.FileDescription (najlepsza!)
            try {
                $fileInfo = $Process.MainModule.FileVersionInfo
                if ($fileInfo) {
                    # Priorytet: FileDescription > ProductName > InternalName
                    if (![string]::IsNullOrWhiteSpace($fileInfo.FileDescription) -and $fileInfo.FileDescription.Length -gt 1) {
                        $displayName = $fileInfo.FileDescription.Trim()
                    }
                    elseif (![string]::IsNullOrWhiteSpace($fileInfo.ProductName) -and $fileInfo.ProductName.Length -gt 1) {
                        $displayName = $fileInfo.ProductName.Trim()
                    }
                }
            } catch { }
            # Metoda 2: MainWindowTitle (jesli FileDescription nie zadzialalo)
            if ($displayName -eq $ProcessName -or $displayName.Length -lt 2) {
                try {
                    $Process.Refresh()
                    $title = $Process.MainWindowTitle
                    if (![string]::IsNullOrWhiteSpace($title) -and $title.Length -gt 1) {
                        # Wyczysc tytul z suffiksow przegladarek/systemowych
                        $title = $title -replace '\s*[----]\s*(Microsoft Edge|Google Chrome|Mozilla Firefox|Brave|Opera|Safari|Visual Studio Code|Notepad\+\+).*$', ''
                        $title = $title -replace '\s*[----]\s*Personal.*$', ''
                        $title = $title -replace '\s*[----]\s*(Work|Praca).*$', ''
                        $title = $title.Trim()
                        # Wez tylko pierwsza czesc tytulu (przed " - ")
                        if ($title -match '^(.+?)\s*[----]') {
                            $title = $matches[1].Trim()
                        }
                        if ($title.Length -gt 1 -and $title.Length -lt 60) {
                            $displayName = $title
                        }
                    }
                } catch { }
            }
        }
    } catch { }
    # Fallback: Capitalize ProcessName
    if ($displayName -eq $ProcessName -or [string]::IsNullOrWhiteSpace($displayName)) {
        if ($ProcessName.Length -gt 1) {
            $displayName = $ProcessName.Substring(0,1).ToUpper() + $ProcessName.Substring(1)
        } else {
            $displayName = $ProcessName.ToUpper()
        }
    }
    # Ogranicz dlugosc
    if ($displayName.Length -gt 40) {
        $displayName = $displayName.Substring(0, 37) + "..."
    }
    # Zapisz do cache
    $Script:ProcessNameCache[$ProcessName] = $displayName
    $Script:ProcessNameCacheExpiry[$ProcessName] = $now.AddMinutes($Script:CacheExpiryMinutes)
    return $displayName
}
# Alias dla kompatybilnosci wstecznej
function Get-FriendlyAppName {
    param([string]$ProcessName)
    return Get-ProcessDisplayName -ProcessName $ProcessName
}
# Funkcja do pobierania tytulu aktywnego okna przez Win32 API
function Get-ForegroundWindowTitle {
    try {
        $hwnd = [Win32]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return "" }
        $length = [Win32]::GetWindowTextLength($hwnd)
        if ($length -le 0) { return "" }
        $sb = New-Object System.Text.StringBuilder($length + 1)
        [Win32]::GetWindowText($hwnd, $sb, $sb.Capacity) | Out-Null
        $title = $sb.ToString()
        # Wyczysc tytul z suffiksow przegladarek/systemowych
        $title = $title -replace '\s*[----]\s*(Microsoft Edge|Google Chrome|Mozilla Firefox|Brave|Opera|Safari).*$', ''
        $title = $title -replace '\s*[----]\s*Personal.*$', ''
        $title = $title -replace '\s*[----]\s*(Work|Praca).*$', ''
        return $title.Trim()
    } catch { return "" }
}
    Ensure-DirectoryExists $Script:ConfigDir
# LOGS
$Script:ActivityLog = [System.Collections.Generic.List[string]]::new()
$Script:DebugLog = [System.Collections.Generic.List[string]]::new()
$Script:DecisionHistory = [System.Collections.Generic.List[hashtable]]::new()
$Script:DecisionHistoryMaxSize = 30  # 30 sekund historii (zoptymalizowane dla RAM storage)
$Script:RAMIntelligenceHistory = [System.Collections.Generic.List[hashtable]]::new()
$Script:RAMIntelligenceMaxSize = 30  # 30 sekund historii (zoptymalizowane dla RAM storage)
$Script:ProBalanceHistory = [System.Collections.Generic.List[hashtable]]::new()
$Script:ProBalanceHistoryMaxSize = 60
function Add-Log {
    param(
        [string]$Entry, 
        [switch]$Debug
    )
    if ([string]::IsNullOrWhiteSpace($Entry)) { return }
    $time = (Get-Date).ToString("HH:mm:ss")
    $text = "[$time] $Entry"
    if ($Debug) {
        $Script:DebugLog.Insert(0, $text)
        while ($Script:DebugLog.Count -gt 15) { $Script:DebugLog.RemoveAt(15) }
    } else {
        $Script:ActivityLog.Insert(0, $text)
        while ($Script:ActivityLog.Count -gt 5) { $Script:ActivityLog.RemoveAt(5) }
    }
}
# FAST METRICS - Automatyczna detekcja zrodel danych (LHM/OHM/System)
# --- Globalna zmienna przechowujaca wykryte zrodla danych ---
$Script:DataSourcesInfo = @{
    DetectionDone = $false
    ActiveSource = "Unknown"  # LHM, OHM, SystemOnly
    # Dostepnosc zrodel
    LHMAvailable = $false
    OHMAvailable = $false
    ACPIThermalAvailable = $false
    PerfCountersAvailable = $false
    DetectedSensors = @()
    # Dostepne metryki per zrodlo
    AvailableMetrics = @{
        CPUTemp = $false
        CPUTempSource = "N/A"
        CPULoad = $false
        CPULoadSource = "N/A"
        CPUClock = $false
        CPUClockSource = "N/A"
        CPUPower = $false
        CPUPowerSource = "N/A"
        PerCoreTemp = $false
        PerCoreTempSource = "N/A"
        PerCoreLoad = $false
        PerCoreLoadSource = "N/A"
        GPUTemp = $false
        GPUTempSource = "N/A"
        GPULoad = $false
        GPULoadSource = "N/A"
        GPUPower = $false
        GPUPowerSource = "N/A"
        GPUVRAM = $false
        GPUVRAMSource = "N/A"
        VRMTemp = $false
        VRMTempSource = "N/A"
        RAMUsage = $false
        RAMUsageSource = "N/A"
        DiskIO = $false
        DiskIOSource = "N/A"
        # v43.14: Fan monitoring & control
        FanRPM = $false
        FanRPMSource = "N/A"
        FanControl = $false
        FanControlSource = "N/A"
    }
}
# --- Funkcja wykrywania dostepnych zrodel danych ---
function Detect-DataSources {
    Write-Host "\nDetekcja zrodel danych systemowych..." -ForegroundColor Cyan
    $info = $Script:DataSourcesInfo
    $info.DetectedSensors = @()
    # === TEST 1: LibreHardwareMonitor ===
    Write-Host "Sprawdzanie LibreHardwareMonitor..." -ForegroundColor Yellow -NoNewline
    try {
        $lhmProcess = Get-Process -Name 'LibreHardwareMonitor' -ErrorAction SilentlyContinue
        try { $lhmTest = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop | Select-Object -First 1 } catch { $lhmTest = $null }
        if ($lhmTest) {
            $info.LHMAvailable = $true
            Write-Host "Dostepny (WMI)" -ForegroundColor Green
        } elseif ($lhmProcess) {
            $info.LHMAvailable = $true
            Write-Host "Proces LibreHardwareMonitor uruchomiony (brak WMI)" -ForegroundColor Green
        } else {
            Write-Host "Niedostepny" -ForegroundColor Red
        }
    } catch {
        Write-Host "Niedostepny" -ForegroundColor Red
    }
    # === TEST 2: OpenHardwareMonitor ===
    Write-Host "Sprawdzanie OpenHardwareMonitor..." -ForegroundColor Yellow -NoNewline
    try {
        $ohmProcess = Get-Process -Name 'OpenHardwareMonitor' -ErrorAction SilentlyContinue
        try { $ohmTest = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop | Select-Object -First 1 } catch { $ohmTest = $null }
        if ($ohmTest) {
            $info.OHMAvailable = $true
            Write-Host "Dostepny (WMI)" -ForegroundColor Green
        } elseif ($ohmProcess) {
            $info.OHMAvailable = $true
            Write-Host "Proces OpenHardwareMonitor uruchomiony (brak WMI)" -ForegroundColor Green
        } else {
            Write-Host "Niedostepny" -ForegroundColor Red
        }
    } catch {
        Write-Host "Niedostepny" -ForegroundColor Red
    }
    # === TEST 3: ACPI Thermal Zone ===
    Write-Host "Sprawdzanie ACPI ThermalZone..." -ForegroundColor Yellow -NoNewline
    try {
        $acpiTest = Get-CimInstance -Namespace "root\wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop | Select-Object -First 1
        if ($acpiTest -and $acpiTest.CurrentTemperature -gt 0) {
            $info.ACPIThermalAvailable = $true
            $tempK = $acpiTest.CurrentTemperature / 10
            $tempC = [Math]::Round($tempK - 273.15, 1)
            Write-Host "Dostepny ($tempC°C)" -ForegroundColor Green
        } else {
            Write-Host "Brak danych" -ForegroundColor Red
        }
    } catch {
        Write-Host "Niedostepny" -ForegroundColor Red
    }
    # === TEST 4: Performance Counters ===
    Write-Host "Sprawdzanie Performance Counters..." -ForegroundColor Yellow -NoNewline
    try {
        $perfTest = [System.Diagnostics.PerformanceCounter]::new("Processor", "% Processor Time", "_Total")
        $null = $perfTest.NextValue()
        Start-Sleep -Milliseconds 100
        $val = $perfTest.NextValue()
        $perfTest.Dispose()
        if ($val -ge 0) {
            $info.PerfCountersAvailable = $true
            Write-Host "Dostepny" -ForegroundColor Green
        } else {
            Write-Host "Brak danych" -ForegroundColor Red
        }
    } catch {
        Write-Host "Niedostepny" -ForegroundColor Red
    }
    Write-Host ""
    # === OKRESLENIE AKTYWNEGO ZRODLA ===
    if ($info.LHMAvailable) {
        $info.ActiveSource = "LHM"
        if ($info.OHMAvailable) {
            Write-Host "  - Uwaga: Oba (LHM + OHM) dostepne - wybrano LHM (nowszy, wiecej sensorow)" -ForegroundColor Cyan
        }
    } elseif ($info.OHMAvailable) {
        $info.ActiveSource = "OHM"
    } else {
        $info.ActiveSource = "SystemOnly"
    }
    # === SKANOWANIE DOSTEPNYCH METRYK ===
    Write-Host "   Skanowanie dostepnych metryk..." -ForegroundColor Cyan
    Write-Host ""
    Detect-AvailableMetrics | Out-Null
    # === PODSUMOWANIE ===
    Write-Host ""
    Write-Host "Podsumowanie detekcji:" -ForegroundColor White
    $sourceColor = switch($info.ActiveSource) {
        "LHM" { "Green" }
        "OHM" { "Yellow" }
        "SystemOnly" { "Red" }
        default { "Gray" }
    }
    $sourceDesc = switch($info.ActiveSource) {
        "LHM" { "LibreHardwareMonitor (pelne dane)" }
        "OHM" { "OpenHardwareMonitor (pelne dane)" }
        "SystemOnly" { "Tylko system Windows (ograniczone)" }
        default { "Nieznane" }
    }
    Write-Host ("Aktywne zrodlo: {0}" -f $sourceDesc) -ForegroundColor $sourceColor
    # Tabela dostepnych metryk
    $metrics = $info.AvailableMetrics
    $metricsList = @(
        @{ Name = "Temperatura CPU"; Key = "CPUTemp"; SourceKey = "CPUTempSource" },
        @{ Name = "Obciazenie CPU"; Key = "CPULoad"; SourceKey = "CPULoadSource" },
        @{ Name = "Zegar CPU"; Key = "CPUClock"; SourceKey = "CPUClockSource" },
        @{ Name = "Moc CPU"; Key = "CPUPower"; SourceKey = "CPUPowerSource" },
        @{ Name = "Temp. per-Core"; Key = "PerCoreTemp"; SourceKey = "PerCoreTempSource" },
        @{ Name = "Load per-Core"; Key = "PerCoreLoad"; SourceKey = "PerCoreLoadSource" },
        @{ Name = "Temperatura GPU"; Key = "GPUTemp"; SourceKey = "GPUTempSource" },
        @{ Name = "Obciazenie GPU"; Key = "GPULoad"; SourceKey = "GPULoadSource" },
        @{ Name = "Moc GPU"; Key = "GPUPower"; SourceKey = "GPUPowerSource" },
        @{ Name = "VRAM GPU"; Key = "GPUVRAM"; SourceKey = "GPUVRAMSource" },
        @{ Name = "Temperatura VRM"; Key = "VRMTemp"; SourceKey = "VRMTempSource" },
        @{ Name = "Uzycie RAM"; Key = "RAMUsage"; SourceKey = "RAMUsageSource" },
        @{ Name = "Disk I/O"; Key = "DiskIO"; SourceKey = "DiskIOSource" }
    )
    foreach ($m in $metricsList) {
        $available = $metrics[$m.Key]
        $source = $metrics[$m.SourceKey]
        $status = if ($available) { "OK" } else { "BRAK" }
        Write-Host ("{0}: {1} (zrodlo: {2})" -f $m.Name, $status, $source)
    }
    Write-Host ""
    $info.DetectionDone = $true
    Populate-DetectedSensors
    return $info
}
function Populate-DetectedSensors {
    $info = $Script:DataSourcesInfo
    $info.DetectedSensors = @()
    # Collect from LHM if available
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            foreach ($sensor in $sensors) {
                # Filter out uninteresting sensors
                if ($sensor.Value -eq 0 -and $sensor.SensorType -ne "Control") { continue }
                # Add to detected sensors as PSCustomObject (better JSON serialization)
                $info.DetectedSensors += [PSCustomObject]@{
                    Type = $sensor.SensorType
                    Name = $sensor.Name
                    Path = $sensor.Identifier
                    Source = 'LHM'
                    Value = $sensor.Value
                }
            }
            Write-Host "  [DetectedSensors] Collected $($info.DetectedSensors.Count) sensors from LHM" -ForegroundColor Cyan
        } catch {
            Write-Host "  [DetectedSensors] Failed to collect from LHM: $_" -ForegroundColor Yellow
        }
    }
    # Collect from OHM if LHM not available
    if (-not $info.LHMAvailable -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            foreach ($sensor in $sensors) {
                # Filter out uninteresting sensors
                if ($sensor.Value -eq 0 -and $sensor.SensorType -ne "Control") { continue }
                # Add to detected sensors as PSCustomObject
                $info.DetectedSensors += [PSCustomObject]@{
                    Type = $sensor.SensorType
                    Name = $sensor.Name
                    Path = $sensor.Identifier
                    Source = 'OHM'
                    Value = $sensor.Value
                }
            }
            Write-Host "  [DetectedSensors] Collected $($info.DetectedSensors.Count) sensors from OHM" -ForegroundColor Cyan
        } catch {
            Write-Host "  [DetectedSensors] Failed to collect from OHM: $_" -ForegroundColor Yellow
        }
    }
    # Add ACPI if available
    if ($info.ACPIThermalAvailable) {
        $info.DetectedSensors += [PSCustomObject]@{
            Type = 'Temperature'
            Name = 'ACPI ThermalZone'
            Path = 'root\wmi\MSAcpi_ThermalZoneTemperature'
            Source = 'ACPI'
            Value = 0
        }
    }
}
# --- Funkcja skanowania dostepnych metryk ---
function Detect-AvailableMetrics {
    $info = $Script:DataSourcesInfo
    $metrics = $info.AvailableMetrics
    # ========== CPU TEMPERATURE ==========
    $providersOrder = @('LHM','OHM')
    foreach ($p in $providersOrder) {
        if ($p -eq 'OHM' -and $info.OHMAvailable -and -not $metrics.CPUTemp) {
            try {
                $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
                $cpuTemp = $sensors | Where-Object {
                    $_.SensorType -eq 'Temperature' -and ($_.Identifier -match '/cpu' -or $_.Name -match 'CPU|Core|Package')
                } | Select-Object -First 1
                if ($cpuTemp -and $cpuTemp.Value -gt 0) {
                    $metrics.CPUTemp = $true
                    $metrics.CPUTempSource = 'OHM'
                    $info.DetectedSensors += @{ Type='CPUTemp'; Name=$cpuTemp.Name; Path=$cpuTemp.Identifier; Source='OHM' }
                    break
                }
            } catch { }
        }
        if ($p -eq 'LHM' -and $info.LHMAvailable -and -not $metrics.CPUTemp) {
            try {
                $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
                $cpuTemp = $sensors | Where-Object {
                    $_.SensorType -eq 'Temperature' -and ($_.Identifier -match '/cpu' -or $_.Name -match 'CPU|Core|Package|Tctl|Tdie')
                } | Select-Object -First 1
                if ($cpuTemp -and $cpuTemp.Value -gt 0) {
                    $metrics.CPUTemp = $true
                    $metrics.CPUTempSource = 'LHM'
                    $info.DetectedSensors += @{ Type='CPUTemp'; Name=$cpuTemp.Name; Path=$cpuTemp.Identifier; Source='LHM' }
                    break
                }
            } catch { }
        }
    }
    if (-not $metrics.CPUTemp -and $info.ACPIThermalAvailable) {
        $metrics.CPUTemp = $true
        $metrics.CPUTempSource = 'ACPI'
        $info.DetectedSensors += @{ Type='CPUTemp'; Name='ACPI ThermalZone'; Path='root\wmi'; Source='ACPI' }
    }
    # ========== CPU LOAD ==========
    $providersOrder = if ($info.ActiveSource -eq 'OHM') { @('OHM','LHM','PerfCounter') } else { @('LHM','OHM','PerfCounter') }
    foreach ($p in $providersOrder) {
        if ($p -eq 'LHM' -and $info.LHMAvailable -and -not $metrics.CPULoad) {
            try {
                $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
                $cpuLoad = $sensors | Where-Object { $_.SensorType -eq 'Load' -and $_.Name -eq 'CPU Total' } | Select-Object -First 1
                if ($cpuLoad) { $metrics.CPULoad = $true; $metrics.CPULoadSource = 'LHM'; break }
            } catch { }
        }
        if ($p -eq 'OHM' -and $info.OHMAvailable -and -not $metrics.CPULoad) {
            try {
                $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
                $cpuLoad = $sensors | Where-Object { $_.SensorType -eq 'Load' -and $_.Name -eq 'CPU Total' } | Select-Object -First 1
                if ($cpuLoad) { $metrics.CPULoad = $true; $metrics.CPULoadSource = 'OHM'; break }
            } catch { }
        }
        if ($p -eq 'PerfCounter' -and $info.PerfCountersAvailable -and -not $metrics.CPULoad) {
            $metrics.CPULoad = $true
            $metrics.CPULoadSource = 'PerfCounter'
            break
        }
    }
    # ========== CPU CLOCK ==========
    $providersOrder = if ($info.ActiveSource -eq 'OHM') { @('OHM','LHM','WMI','Registry') } else { @('LHM','OHM','WMI','Registry') }
    foreach ($p in $providersOrder) {
        if ($p -eq 'LHM' -and $info.LHMAvailable -and -not $metrics.CPUClock) {
            try {
                $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
                $cpuClock = $sensors | Where-Object { $_.SensorType -eq 'Clock' -and $_.Identifier -match '/cpu' -and $_.Name -match 'Core' -and $_.Value -gt 100 } | Select-Object -First 1
                if ($cpuClock) { $metrics.CPUClock = $true; $metrics.CPUClockSource = 'LHM'; break }
            } catch { }
        }
        if ($p -eq 'OHM' -and $info.OHMAvailable -and -not $metrics.CPUClock) {
            try {
                $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
                $cpuClock = $sensors | Where-Object { $_.SensorType -eq 'Clock' -and $_.Identifier -match '/cpu' -and $_.Name -match 'Core' -and $_.Value -gt 100 } | Select-Object -First 1
                if ($cpuClock) { $metrics.CPUClock = $true; $metrics.CPUClockSource = 'OHM'; break }
            } catch { }
        }
        if ($p -eq 'WMI' -and -not $metrics.CPUClock) {
            try {
                $perfData = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
                if ($perfData -and $perfData.PercentProcessorPerformance -gt 0) { $metrics.CPUClock = $true; $metrics.CPUClockSource = 'WMI'; break }
            } catch { }
        }
        if ($p -eq 'Registry' -and -not $metrics.CPUClock) {
            try {
                $regMHz = (Get-ItemProperty -Path "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -Name "~MHz" -ErrorAction Stop)."~MHz"
                if ($regMHz -gt 100) { $metrics.CPUClock = $true; $metrics.CPUClockSource = 'Registry'; break }
            } catch { }
        }
    }
    # Fallback: WMI PercentProcessorPerformance + MaxClock
    if (-not $metrics.CPUClock) {
        try {
            $perfData = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop
            if ($perfData -and $perfData.PercentProcessorPerformance -gt 0) {
                $metrics.CPUClock = $true
                $metrics.CPUClockSource = "WMI"
            }
        } catch { }
    }
    # Fallback: Registry
    if (-not $metrics.CPUClock) {
        try {
            $regMHz = (Get-ItemProperty -Path "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -Name "~MHz" -ErrorAction Stop)."~MHz"
            if ($regMHz -gt 100) {
                $metrics.CPUClock = $true
                $metrics.CPUClockSource = "Registry"
            }
        } catch { }
    }
    # ========== CPU POWER ==========
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $cpuPower = $sensors | Where-Object { 
                $_.SensorType -eq "Power" -and $_.Identifier -match "/cpu" -and $_.Name -match "Package|Core"
            } | Select-Object -First 1
            if ($cpuPower -and $cpuPower.Value -gt 0) {
                $metrics.CPUPower = $true
                $metrics.CPUPowerSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.CPUPower -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $cpuPower = $sensors | Where-Object { 
                $_.SensorType -eq "Power" -and $_.Identifier -match "/cpu" -and $_.Name -match "Package|Core"
            } | Select-Object -First 1
            if ($cpuPower -and $cpuPower.Value -gt 0) {
                $metrics.CPUPower = $true
                $metrics.CPUPowerSource = "OHM"
            }
        } catch { }
    }
    # CPU Power nie ma fallbacku systemowego
    # ========== PER-CORE TEMPS ==========
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $coreTemps = $sensors | Where-Object { 
                $_.SensorType -eq "Temperature" -and $_.Identifier -match "/cpu" -and $_.Name -match "Core #\d+"
            }
            if ($coreTemps -and $coreTemps.Count -gt 0) {
                $metrics.PerCoreTemp = $true
                $metrics.PerCoreTempSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.PerCoreTemp -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $coreTemps = $sensors | Where-Object { 
                $_.SensorType -eq "Temperature" -and $_.Identifier -match "/cpu" -and $_.Name -match "Core #\d+"
            }
            if ($coreTemps -and $coreTemps.Count -gt 0) {
                $metrics.PerCoreTemp = $true
                $metrics.PerCoreTempSource = "OHM"
            }
        } catch { }
    }
    # ========== PER-CORE LOAD ==========
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $coreLoads = $sensors | Where-Object { 
                $_.SensorType -eq "Load" -and $_.Identifier -match "/cpu" -and $_.Name -match "CPU Core #\d+"
            }
            if ($coreLoads -and $coreLoads.Count -gt 0) {
                $metrics.PerCoreLoad = $true
                $metrics.PerCoreLoadSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.PerCoreLoad -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $coreLoads = $sensors | Where-Object { 
                $_.SensorType -eq "Load" -and $_.Identifier -match "/cpu" -and $_.Name -match "CPU Core #\d+"
            }
            if ($coreLoads -and $coreLoads.Count -gt 0) {
                $metrics.PerCoreLoad = $true
                $metrics.PerCoreLoadSource = "OHM"
            }
        } catch { }
    }
    # ========== GPU TEMPERATURE ==========
    # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $gpuTemp = $sensors | Where-Object { 
                $_.SensorType -eq "Temperature" -and 
                ($_.Identifier -match "gpu" -or ($_.Identifier -match "/amdcpu" -and $_.Name -match "GPU|Graphics"))
            } | Select-Object -First 1
            if ($gpuTemp -and $gpuTemp.Value -gt 0) {
                $metrics.GPUTemp = $true
                $metrics.GPUTempSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.GPUTemp -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $gpuTemp = $sensors | Where-Object { $_.SensorType -eq "Temperature" -and $_.Identifier -match "gpu" } | Select-Object -First 1
            if ($gpuTemp -and $gpuTemp.Value -gt 0) {
                $metrics.GPUTemp = $true
                $metrics.GPUTempSource = "OHM"
            }
        } catch { }
    }
    # ========== GPU LOAD ==========
    # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
    # FIX v40.1b: Preferuj GPU Core nad GPU Frame Buffer
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $gpuLoad = $sensors | Where-Object { 
                $_.SensorType -eq "Load" -and 
                (($_.Identifier -match "gpu" -and $_.Name -match "Core|GPU") -or ($_.Identifier -match "/amdcpu" -and $_.Name -match "GPU"))
            } | Sort-Object { if ($_.Name -eq "GPU Core") { 0 } else { 1 } } | Select-Object -First 1
            if ($gpuLoad) {
                $metrics.GPULoad = $true
                $metrics.GPULoadSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.GPULoad -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $gpuLoad = $sensors | Where-Object { $_.SensorType -eq "Load" -and $_.Identifier -match "gpu" -and $_.Name -match "Core|GPU" } | Sort-Object { if ($_.Name -eq "GPU Core") { 0 } else { 1 } } | Select-Object -First 1
            if ($gpuLoad) {
                $metrics.GPULoad = $true
                $metrics.GPULoadSource = "OHM"
            }
        } catch { }
    }
    # ========== GPU POWER ==========
    # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $gpuPower = $sensors | Where-Object { $_.SensorType -eq "Power" -and $_.Identifier -match "gpu" } | Select-Object -First 1
            if ($gpuPower -and $gpuPower.Value -gt 0) {
                $metrics.GPUPower = $true
                $metrics.GPUPowerSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.GPUPower -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $gpuPower = $sensors | Where-Object { $_.SensorType -eq "Power" -and $_.Identifier -match "gpu" } | Select-Object -First 1
            if ($gpuPower -and $gpuPower.Value -gt 0) {
                $metrics.GPUPower = $true
                $metrics.GPUPowerSource = "OHM"
            }
        } catch { }
    }
    # ========== GPU VRAM ==========
    # FIX v40.1: Zmieniono /gpu na gpu - /gpu nie matchuje /nvidiagpu
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $gpuVRAM = $sensors | Where-Object { $_.SensorType -eq "SmallData" -and $_.Identifier -match "gpu" -and $_.Name -match "Memory Used" } | Select-Object -First 1
            if ($gpuVRAM) {
                $metrics.GPUVRAM = $true
                $metrics.GPUVRAMSource = "LHM"
            }
        } catch { }
    }
    # ========== VRM TEMPERATURE ==========
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $vrmTemp = $sensors | Where-Object { 
                $_.SensorType -eq "Temperature" -and 
                ($_.Name -match "VRM|Motherboard|System|Chipset|PCH" -or $_.Identifier -match "/lpc/")
            } | Select-Object -First 1
            if ($vrmTemp -and $vrmTemp.Value -gt 0) {
                $metrics.VRMTemp = $true
                $metrics.VRMTempSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.VRMTemp -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $vrmTemp = $sensors | Where-Object { 
                $_.SensorType -eq "Temperature" -and 
                ($_.Name -match "VRM|Motherboard|System|Chipset" -or $_.Identifier -match "/lpc/")
            } | Select-Object -First 1
            if ($vrmTemp -and $vrmTemp.Value -gt 0) {
                $metrics.VRMTemp = $true
                $metrics.VRMTempSource = "OHM"
            }
        } catch { }
    }
    # ========== RAM USAGE ==========
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $ramLoad = $sensors | Where-Object { $_.SensorType -eq "Load" -and $_.Name -match "Memory" } | Select-Object -First 1
            if ($ramLoad) {
                $metrics.RAMUsage = $true
                $metrics.RAMUsageSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.RAMUsage) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            if ($os -and $os.TotalVisibleMemorySize -gt 0) {
                $metrics.RAMUsage = $true
                $metrics.RAMUsageSource = "WMI"
            }
        } catch { }
    }
    # ========== DISK I/O ==========
    if ($info.PerfCountersAvailable) {
        try {
            $diskCounter = [System.Diagnostics.PerformanceCounter]::new("PhysicalDisk", "Disk Bytes/sec", "_Total")
            $null = $diskCounter.NextValue()
            $diskCounter.Dispose()
            $metrics.DiskIO = $true
            $metrics.DiskIOSource = "PerfCounter"
        } catch { }
    }
    if (-not $metrics.DiskIO) {
        try {
            $diskPerf = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction Stop
            if ($diskPerf) {
                $metrics.DiskIO = $true
                $metrics.DiskIOSource = "WMI"
            }
        } catch { }
    }
    # ========== FAN MONITORING & CONTROL (v43.14) ==========
    if ($info.LHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $fanSensor = $sensors | Where-Object { $_.SensorType -eq "Fan" } | Select-Object -First 1
            if ($fanSensor -and $fanSensor.Value -gt 0) {
                $metrics.FanRPM = $true
                $metrics.FanRPMSource = "LHM"
            }
            $fanControl = $sensors | Where-Object { $_.SensorType -eq "Control" } | Select-Object -First 1
            if ($fanControl) {
                $metrics.FanControl = $true
                $metrics.FanControlSource = "LHM"
            }
        } catch { }
    }
    if (-not $metrics.FanRPM -and $info.OHMAvailable) {
        try {
            $sensors = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
            $fanSensor = $sensors | Where-Object { $_.SensorType -eq "Fan" } | Select-Object -First 1
            if ($fanSensor -and $fanSensor.Value -gt 0) {
                $metrics.FanRPM = $true
                $metrics.FanRPMSource = "OHM"
            }
            $fanControl = $sensors | Where-Object { $_.SensorType -eq "Control" } | Select-Object -First 1
            if ($fanControl) {
                $metrics.FanControl = $true
                $metrics.FanControlSource = "OHM"
            }
        } catch { }
    }
}
# --- Cached Cim/WMI helpers to reduce syscall frequency ---
function Get-LHMSensorsCached {
    param([int]$ttl = 800)  # Cache 800ms - swiezy dla CPU mgmt, bez zbednych CIM queries
    if (-not $Script:DataSourcesInfo.LHMAvailable) { return $null }
    if (-not $Script:LHMSensorsCacheTime) { $Script:LHMSensorsCacheTime = [DateTime]::MinValue }
    try {
        if ($Script:LHMSensorsCache -and (([DateTime]::Now - $Script:LHMSensorsCacheTime).TotalMilliseconds -lt $ttl)) { return $Script:LHMSensorsCache }
    } catch { }
    try {
        $s = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Sensor -ErrorAction Stop
        $Script:LHMSensorsCache = $s
        $Script:LHMSensorsCacheTime = [DateTime]::Now
        return $s
    } catch { return $Script:LHMSensorsCache }
}
function Get-LHMHardwareCached {
    param([int]$ttl = 30000)  #  v39.20: 30 sekund
    if (-not $Script:DataSourcesInfo.LHMAvailable) { return $null }
    if (-not $Script:LHMHardwareCacheTime) { $Script:LHMHardwareCacheTime = [DateTime]::MinValue }
    try {
        if ($Script:LHMHardwareCache -and (([DateTime]::Now - $Script:LHMHardwareCacheTime).TotalMilliseconds -lt $ttl)) { return $Script:LHMHardwareCache }
    } catch { }
    try { $s = Get-CimInstance -Namespace "root\LibreHardwareMonitor" -ClassName Hardware -ErrorAction SilentlyContinue; $Script:LHMHardwareCache = $s; $Script:LHMHardwareCacheTime = [DateTime]::Now; return $s } catch { return $Script:LHMHardwareCache }
}
function Get-OHMSensorsCached {
    param([int]$ttl = 800)  # Cache 800ms - swiezy dla CPU mgmt, bez zbednych CIM queries
    if (-not $Script:DataSourcesInfo.OHMAvailable) { return $null }
    if (-not $Script:OHMSensorsCacheTime) { $Script:OHMSensorsCacheTime = [DateTime]::MinValue }
    try {
        if ($Script:OHMSensorsCache -and (([DateTime]::Now - $Script:OHMSensorsCacheTime).TotalMilliseconds -lt $ttl)) { return $Script:OHMSensorsCache }
    } catch { }
    try {
        $s = Get-CimInstance -Namespace "root\OpenHardwareMonitor" -ClassName Sensor -ErrorAction Stop
        $Script:OHMSensorsCache = $s
        $Script:OHMSensorsCacheTime = [DateTime]::Now
        return $s
    } catch { return $Script:OHMSensorsCache }
}
function Get-ACPIThermalCached {
    param([int]$ttl = 30000)  #  v39.20: 30 sekund
    if (-not $Script:ACPIThermalCacheTime) { $Script:ACPIThermalCacheTime = [DateTime]::MinValue }
    try {
        if ($Script:ACPIThermalCache -and (([DateTime]::Now - $Script:ACPIThermalCacheTime).TotalMilliseconds -lt $ttl)) { return $Script:ACPIThermalCache }
    } catch { }
    try { $s = Get-CimInstance -Namespace "root\wmi" -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction SilentlyContinue | Select-Object -First 1; $Script:ACPIThermalCache = $s; $Script:ACPIThermalCacheTime = [DateTime]::Now; return $s } catch { return $Script:ACPIThermalCache }
}
# Cached WMI helpers for OS / Disk / CPU
function Get-OSCached {
    param([int]$ttl = 30000)  #  v39.21 FIX: 30s (bylo 10s) - eliminacja busy cursor co 10s
    if (-not $Script:OSCacheTime) { $Script:OSCacheTime = [DateTime]::MinValue }
    try { if ($Script:OSCache -and (([DateTime]::Now - $Script:OSCacheTime).TotalMilliseconds -lt $ttl)) { return $Script:OSCache } } catch { }
    try { $o = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue | Select-Object -First 1; $Script:OSCache = $o; $Script:OSCacheTime = [DateTime]::Now; return $o } catch { return $Script:OSCache }
}
function Get-DiskPerfCached {
    param([int]$ttl = 30000)  #  v39.21 FIX: 30s (bylo 5s) - eliminacja busy cursor co 5s
    if (-not $Script:DiskPerfCacheTime) { $Script:DiskPerfCacheTime = [DateTime]::MinValue }
    try { if ($Script:DiskPerfCache -and (([DateTime]::Now - $Script:DiskPerfCacheTime).TotalMilliseconds -lt $ttl)) { return $Script:DiskPerfCache } } catch { }
    try { $d = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'" -ErrorAction SilentlyContinue; $Script:DiskPerfCache = $d; $Script:DiskPerfCacheTime = [DateTime]::Now; return $d } catch { return $Script:DiskPerfCache }
}
function Get-CPUInfoCached {
    param([int]$ttl = 30000)  #  v39.21 FIX: 30s (bylo 10s) - eliminacja busy cursor co 10s
    if (-not $Script:CPUInfoCacheTime) { $Script:CPUInfoCacheTime = [DateTime]::MinValue }
    try { if ($Script:CPUInfoCache -and (([DateTime]::Now - $Script:CPUInfoCacheTime).TotalMilliseconds -lt $ttl)) { return $Script:CPUInfoCache } } catch { }
    try { $c = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1; $Script:CPUInfoCache = $c; $Script:CPUInfoCacheTime = [DateTime]::Now; return $c } catch { return $Script:CPUInfoCache }
}
function Get-ProcessorPerfCached {
    param([int]$ttl = 30000)
    if (-not $Script:ProcessorPerfCacheTime) { $Script:ProcessorPerfCacheTime = [DateTime]::MinValue }
    try { 
        if ($Script:ProcessorPerfCache -and (([DateTime]::Now - $Script:ProcessorPerfCacheTime).TotalMilliseconds -lt $ttl)) { 
            return $Script:ProcessorPerfCache 
        } 
    } catch { }
    try { 
        $p = Get-CimInstance -ClassName Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction SilentlyContinue
        $Script:ProcessorPerfCache = $p
        $Script:ProcessorPerfCacheTime = [DateTime]::Now
        return $p 
    } catch { 
        return $Script:ProcessorPerfCache 
    }
}
# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Get-DiskCounterCached (przeniesione z wnętrza klasy FastMetrics)
# ═══════════════════════════════════════════════════════════════════════════════
function Get-DiskCounterCached {
    <#
    .SYNOPSIS
    v39.3: Cache disk counter (fallback) - używane przez FastMetrics
    #>
    param([int]$ttl = 5000)
    if (-not $Script:DiskCounterCacheTime) { $Script:DiskCounterCacheTime = [DateTime]::MinValue }
    try { 
        if ($Script:DiskCounterCache -and (([DateTime]::Now - $Script:DiskCounterCacheTime).TotalMilliseconds -lt $ttl)) { 
            return $Script:DiskCounterCache 
        } 
    } catch { }
    try {
        $c = Get-Counter '\PhysicalDisk(_Total)\Disk Bytes/sec' -ErrorAction SilentlyContinue
        $Script:DiskCounterCache = $c
        $Script:DiskCounterCacheTime = [DateTime]::Now
        return $c
    } catch {
        return $Script:DiskCounterCache
    }
}