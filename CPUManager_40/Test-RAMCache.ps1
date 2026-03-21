# ═══════════════════════════════════════════════════════════════════════════════
# Test-RAMCache.ps1  — Diagnostyka systemu preloadingu AppRAMCache
# Uruchom AS ADMIN gdy CPUManager działa (lub po nim) dla pełnych wyników.
# ═══════════════════════════════════════════════════════════════════════════════
# Co sprawdza:
#   [1] RAMCache.json — czy ENGINE uczył się aplikacji (AppPaths, LearnedFiles)
#   [2] Disk manifesty — czy pliki DLL/asset są zaplanowane do preloadu
#   [3] RAMCache-Debug.log — ostatnie zdarzenia PRELOAD / HIT / MISS / RETOUCH
#   [4] Standby List — czy kernel file cache ma pliki w RAM (GetSystemInfo)
#   [5] ProphetMemory.json — czy AI zna kategorie HEAVY/MEDIUM/LIGHT
#   [6] Podsumowanie: hit-rate, wasted preloads, aggressiveness
#
# Po uruchomieniu gry/aplikacji po raz DRUGI powinnaś widzieć:
#   LAUNCH RACE START   — ENGINE wykrył nowy PID
#   MANIFEST QUEUE      — pliki z dyskowego cache kolejkowane
#   LAUNCH RACE WIN     — wszystkie pliki załadowane przed init aplikacji
#   HIT                 — IsAppCached() potwierdza trafienie
# ═══════════════════════════════════════════════════════════════════════════════

#Requires -Version 5.1

param (
    [string] $ConfigDir  = "C:\CPUManager",
    [string] $CacheDir   = "C:\CPUManager\Cache",
    [string] $LogPath    = "C:\Temp\RAMCache-Debug.log",
    [string] $WatchApp   = "",     # Filtruj log do konkretnej aplikacji (np. "SomApp")
    [int]    $LogLines   = 60      # Ile ostatnich linii logu wyświetlić
)

$hr = "═" * 72

function Write-Header([string]$title) {
    Write-Host "`n$hr" -ForegroundColor DarkCyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host $hr -ForegroundColor DarkCyan
}

function Write-OK([string]$msg)   { Write-Host "  [OK]   $msg" -ForegroundColor Green }
function Write-WARN([string]$msg) { Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Write-FAIL([string]$msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Write-INFO([string]$msg) { Write-Host "  [INFO] $msg" -ForegroundColor Gray }

# ─── [1] RAMCache.json ────────────────────────────────────────────────────────
Write-Header "1  RAMCache.json — wiedza o aplikacjach"

$ramCachePath = Join-Path $ConfigDir "RAMCache.json"
if (-not (Test-Path $ramCachePath)) {
    Write-FAIL "Brak pliku $ramCachePath — ENGINE jeszcze nie zapisał danych (uruchom CPUManager)."
} else {
    try {
        $rc = [System.IO.File]::ReadAllText($ramCachePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $pathCount  = 0; if ($rc.AppPaths) { $rc.AppPaths.PSObject.Properties | ForEach-Object { $pathCount++ } }
        $classCount = 0; if ($rc.AppClassification) { $rc.AppClassification.PSObject.Properties | ForEach-Object { $classCount++ } }

        Write-OK "Plik istnieje, wersja V=$($rc.V), zapisano $($rc.SavedAt)"
        Write-INFO "AppPaths (znane aplikacje): $pathCount"
        Write-INFO "AppClassification (Heavy/Light): $classCount"

        $hits   = if ($rc.TotalHits)   { [int]$rc.TotalHits }   else { 0 }
        $misses = if ($rc.TotalMisses) { [int]$rc.TotalMisses } else { 0 }
        $total  = $hits + $misses
        $hitPct = if ($total -gt 0) { [Math]::Round($hits / $total * 100, 1) } else { 0 }
        Write-INFO "Hit-rate: $hits/$total ($hitPct%) | Aggressiveness: $($rc.Aggressiveness) | MaxCache: $($rc.MaxCacheMB) MB"

        # Wyświetl aplikacje z LearnedFiles
        if ($rc.AppPaths) {
            $appsWithLF = $rc.AppPaths.PSObject.Properties | Where-Object { $_.Value.LF -and $_.Value.LF.Count -gt 0 }
            $noExe      = $rc.AppPaths.PSObject.Properties | Where-Object { -not $_.Value.ExePath -and $_.Value.LF -and $_.Value.LF.Count -gt 0 }
            Write-INFO ""
            Write-INFO "── Aplikacje ze zbudowanym profilem modułów (LearnedFiles) ──"
            foreach ($ap in ($appsWithLF | Sort-Object { $_.Value.LF.Count } -Descending | Select-Object -First 20)) {
                $lfc = $ap.Value.LF.Count
                $exe = if ($ap.Value.ExePath) { [System.IO.Path]::GetFileName($ap.Value.ExePath) } else { "(brak exe — plik zmieniony?)" }
                $pa  = if ($ap.Value.PA) { $ap.Value.PA.Substring(0,16) } else { "?" }
                $cls = if ($rc.AppClassification -and $rc.AppClassification.($ap.Name)) { $rc.AppClassification.($ap.Name) } else { "?" }
                $tag = if (-not $ap.Value.ExePath) { " ← STALE EXE (LearnedFiles zachowane ✓)" } else { "" }
                Write-Host ("    {0,-22} [{1,-7}] {2,4} moduły  exe={3}  profilowano={4}{5}" -f $ap.Name, $cls, $lfc, $exe, $pa, $tag) -ForegroundColor White
            }
            if ($noExe.Count -gt 0) {
                Write-WARN "$($noExe.Count) aplikacji ma puste ExePath ale zachowane LearnedFiles (po poprawce Bug#3 — OK)."
            }
        }

    } catch { Write-FAIL "Błąd parsowania RAMCache.json: $($_.Exception.Message)" }
}

# ─── [2] Disk manifesty ───────────────────────────────────────────────────────
Write-Header "2  Disk cache manifesty — C:\CPUManager\Cache\"

if (-not (Test-Path $CacheDir)) {
    Write-WARN "Katalog $CacheDir nie istnieje — ENGINE nie zapisał jeszcze żadnych manifestów."
} else {
    $manifests = Get-ChildItem $CacheDir -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($manifests.Count -eq 0) {
        Write-WARN "Brak manifestów — ENGINE nie zakończył jeszcze żadnego preloadu."
    } else {
        Write-OK "$($manifests.Count) manifestów (plik = lista DLL/asset do preloadu przy następnym uruchomieniu)"
        Write-INFO ""
        Write-INFO "── Najnowsze manifesty ──"
        foreach ($m in ($manifests | Select-Object -First 15)) {
            try {
                $j = [System.IO.File]::ReadAllText($m.FullName) | ConvertFrom-Json
                $fc = if ($j.Files) { $j.Files.Count } else { 0 }
                $sz = if ($j.SizeMB) { "$($j.SizeMB) MB" } else { "?" }
                $ag = $m.LastWriteTime.ToString("MM-dd HH:mm")
                Write-Host ("    {0,-26} {1,4} plików  {2,8}  zapisano={3}" -f $m.BaseName, $fc, $sz, $ag) -ForegroundColor White
            } catch {
                Write-Host "    $($m.BaseName) — błąd parsowania" -ForegroundColor Red
            }
        }
        $totalMB = 0
        foreach ($m in $manifests) {
            try { $j = [System.IO.File]::ReadAllText($m.FullName) | ConvertFrom-Json; if ($j.SizeMB) { $totalMB += [double]$j.SizeMB } } catch {}
        }
        Write-INFO ""
        Write-INFO "Łączny rozmiar zaplanowany do RAM cache: $([Math]::Round($totalMB, 0)) MB"

        # Weryfikacja czy pliki istnieją na dysku
        $missingFiles = 0; $totalChecked = 0
        foreach ($m in ($manifests | Select-Object -First 10)) {
            try {
                $j = [System.IO.File]::ReadAllText($m.FullName) | ConvertFrom-Json
                foreach ($f in $j.Files) {
                    $totalChecked++
                    if (-not (Test-Path $f.Path -ErrorAction SilentlyContinue)) { $missingFiles++ }
                }
            } catch {}
        }
        if ($totalChecked -gt 0) {
            $okPct = [Math]::Round(($totalChecked - $missingFiles) / $totalChecked * 100, 1)
            if ($okPct -ge 90) { Write-OK "Weryfikacja ścieżek: $okPct% plików istnieje na dysku ($missingFiles/$totalChecked brakuje)" }
            elseif ($okPct -ge 70) { Write-WARN "Weryfikacja ścieżek: $okPct% plików istnieje ($missingFiles/$totalChecked brakuje — może po aktualizacji gry)" }
            else { Write-FAIL "Weryfikacja ścieżek: tylko $okPct% plików istnieje — duże zmiany w instalacjach!" }
        }
    }
}

# ─── [3] RAMCache-Debug.log ───────────────────────────────────────────────────
Write-Header "3  RAMCache-Debug.log — ostatnie zdarzenia ENGINE"

if (-not (Test-Path $LogPath)) {
    Write-WARN "Brak $LogPath — uruchom CPUManager aby ENGINE tworzył logi."
} else {
    $logSize = [Math]::Round((Get-Item $LogPath).Length / 1KB, 1)
    Write-INFO "Plik: $LogPath ($logSize KB)"

    $allLines = Get-Content $LogPath -Tail ([Math]::Max($LogLines * 5, 500)) -ErrorAction SilentlyContinue
    if ($WatchApp) {
        $allLines = $allLines | Where-Object { $_ -match [regex]::Escape($WatchApp) }
        Write-INFO "Filtr: '$WatchApp'"
    }
    $lines = $allLines | Select-Object -Last $LogLines

    Write-INFO ""
    $colorMap = @{
        'LAUNCH RACE START'  = 'Cyan'
        'LAUNCH RACE WIN'    = 'Green'
        'LAUNCH RACE END'    = 'DarkYellow'
        'MANIFEST QUEUE'     = 'Cyan'
        'PRELOAD '           = 'Cyan'
        'PRELOAD SKIP'       = 'DarkGray'
        'HIT '               = 'Green'
        'MISS '              = 'Yellow'
        'EVICT'              = 'DarkYellow'
        'RETOUCH'            = 'DarkGreen'
        'BOOTSTRAP'          = 'Magenta'
        'PROFILE '           = 'Blue'
        'SAVED'              = 'DarkGreen'
        'SAVE ERROR'         = 'Red'
        'LOAD ERROR'         = 'Red'
        'CHILD'              = 'DarkCyan'
    }
    foreach ($line in $lines) {
        $color = 'DarkGray'
        foreach ($kv in $colorMap.GetEnumerator()) {
            if ($line -match [regex]::Escape($kv.Key)) { $color = $kv.Value; break }
        }
        Write-Host "    $line" -ForegroundColor $color
    }

    # Statystyki z logu
    Write-INFO ""
    Write-INFO "── Statystyki z logu (wszystkie linie) ──"
    $allLog = Get-Content $LogPath -ErrorAction SilentlyContinue
    $cLaunch  = ($allLog | Where-Object { $_ -match 'LAUNCH RACE START' }).Count
    $cWin     = ($allLog | Where-Object { $_ -match 'LAUNCH RACE WIN' }).Count
    $cPreload = ($allLog | Where-Object { $_ -match '^.*PRELOAD ''' }).Count
    $cSkip    = ($allLog | Where-Object { $_ -match 'PRELOAD SKIP' }).Count
    $cHit     = ($allLog | Where-Object { $_ -match "\bHIT '" }).Count
    $cMiss    = ($allLog | Where-Object { $_ -match "\bMISS '" }).Count
    $cEvict   = ($allLog | Where-Object { $_ -match '^.*EVICT ' }).Count
    $cRetouch = ($allLog | Where-Object { $_ -match 'RETOUCH' }).Count
    $cManifest= ($allLog | Where-Object { $_ -match 'MANIFEST QUEUE' }).Count

    $logHitPct  = if (($cHit + $cMiss) -gt 0) { [Math]::Round($cHit / ($cHit + $cMiss) * 100, 1) } else { 0 }
    $raceWinPct = if ($cLaunch -gt 0) { [Math]::Round($cWin / $cLaunch * 100, 1) } else { 0 }

    Write-Host ("    Launch Race starts={0,4}  wins={1,4}  ({2}% wygranych)" -f $cLaunch, $cWin, $raceWinPct) -ForegroundColor White
    Write-Host ("    PRELOAD={0,4}  SKIP={1,4}  MANIFEST_QUEUE={2,4}" -f $cPreload, $cSkip, $cManifest) -ForegroundColor White
    Write-Host ("    HIT={0,4}  MISS={1,4}  hit-rate={2}%  EVICT={3}  RETOUCH={4}" -f $cHit, $cMiss, $logHitPct, $cEvict, $cRetouch) -ForegroundColor White

    if ($raceWinPct -ge 80) { Write-OK "Launch Race win-rate $raceWinPct% — doskonały preload (app ładuje z RAM)." }
    elseif ($raceWinPct -ge 50) { Write-WARN "Launch Race win-rate $raceWinPct% — preload częściowy (appów z dużymi assetami: normalne przy 1. uruchomieniu)." }
    elseif ($cLaunch -eq 0) { Write-WARN "Brak Launch Race — aplikacje nie były uruchamiane podczas sesji ENGINE lub CPUManager właśnie wystartował." }
    else { Write-FAIL "Launch Race win-rate $raceWinPct% — ENGINE przegrywa wyścig. Sprawdź czy dysk jest szybki i czy guard band RAM pozwala na preload." }
}

# ─── [4] Kernel file cache — Standby list ─────────────────────────────────────
Write-Header "4  Pamięć systemowa — Standby List vs Available"

try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $totalMB  = [Math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
    $freeMB   = [Math]::Round($os.FreePhysicalMemory / 1KB, 0)
    $usedMB   = $totalMB - $freeMB
    $freePct  = [Math]::Round($freeMB / $totalMB * 100, 1)

    Write-INFO "RAM total:     $totalMB MB"
    Write-INFO "RAM używany:   $usedMB MB"
    Write-INFO "RAM wolny:     $freeMB MB ($freePct%)"

    # Standby List przez Performance Counter
    try {
        $standbyMB = [Math]::Round((Get-Counter '\Memory\Standby Cache Normal Priority Bytes' -ErrorAction Stop).CounterSamples[0].CookedValue / 1MB, 0)
        $standbyAllMB = 0
        foreach ($c in @('\Memory\Standby Cache Reserve Bytes', '\Memory\Standby Cache Normal Priority Bytes', '\Memory\Standby Cache Core Bytes')) {
            try { $standbyAllMB += [Math]::Round((Get-Counter $c -ErrorAction SilentlyContinue).CounterSamples[0].CookedValue / 1MB, 0) } catch {}
        }
        Write-INFO "Standby (normal prio): $standbyMB MB   Standby (all tiers): $standbyAllMB MB"
        Write-INFO ""
        Write-INFO "Standby = kernel page cache (file data, DLL, shaery). Im więcej = więcej plików w RAM."
        if ($standbyAllMB -gt 2048) { Write-OK "Duża Standby List ($standbyAllMB MB) — system aktywnie korzysta z file cache. Preload pracuje." }
        elseif ($standbyAllMB -gt 512) { Write-WARN "Standby List $standbyAllMB MB — umiarkowana. Normalne po krótkim czasie pracy ENGINE." }
        else { Write-WARN "Standby List $standbyAllMB MB — mała. CPUManager mógł dopiero wystartować lub system ma mało wolnego RAM." }
    } catch {
        Write-INFO "Performance Counter niedostępny (brak uprawnień?). Sprawdź Task Manager → Performance → Memory → Standby."
    }

    if ($freePct -lt 15) {
        Write-FAIL "Wolny RAM $freePct% — poniżej guard band. ENGINE wstrzymuje preload. Zamknij niepotrzebne aplikacje."
    } elseif ($freePct -lt 25) {
        Write-WARN "Wolny RAM $freePct% — blisko progu eviction (25%). Preload będzie ostrożniejszy."
    } else {
        Write-OK "Wolny RAM $freePct% — engine ma miejsce na preload."
    }
} catch { Write-FAIL "Błąd odczytu WMI Win32_OperatingSystem: $($_.Exception.Message)" }

# ─── [5] ProphetMemory.json ───────────────────────────────────────────────────
Write-Header "5  ProphetMemory.json — AI wiedza o kategoriach aplikacji"

$prophetPath = Join-Path $ConfigDir "ProphetMemory.json"
if (-not (Test-Path $prophetPath)) {
    Write-WARN "Brak $prophetPath — Prophet nie zapisał jeszcze wiedzy."
} else {
    try {
        $pm = [System.IO.File]::ReadAllText($prophetPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $appCount = 0; if ($pm.Apps) { $pm.Apps.PSObject.Properties | ForEach-Object { $appCount++ } }
        Write-OK "ProphetMemory istnieje, $appCount aplikacji w pamięci."
        if ($pm.Apps) {
            $heavy = ($pm.Apps.PSObject.Properties | Where-Object { $_.Value.Category -match 'HEAVY' }).Count
            $medium = ($pm.Apps.PSObject.Properties | Where-Object { $_.Value.Category -match 'MEDIUM' }).Count
            $light = ($pm.Apps.PSObject.Properties | Where-Object { $_.Value.Category -match 'LIGHT' -and $_.Value.Category -notmatch 'LEARNING' }).Count
            $learning = ($pm.Apps.PSObject.Properties | Where-Object { $_.Value.Category -match 'LEARNING' }).Count
            Write-INFO "Kategorie: HEAVY=$heavy  MEDIUM=$medium  LIGHT=$light  LEARNING=$learning"
            Write-INFO ""
            Write-INFO "── Aplikacje ze sfinalizowaną kategorią (nie LEARNING) ──"
            foreach ($a in ($pm.Apps.PSObject.Properties | Where-Object { $_.Value.Category -notmatch 'LEARNING' } | Sort-Object { [double]$_.Value.Samples } -Descending | Select-Object -First 15)) {
                $v = $a.Value
                $samples = if ($v.Samples) { [int]$v.Samples } else { 0 }
                $avgCPU  = if ($v.AvgCPU)  { [Math]::Round([double]$v.AvgCPU, 1) } else { 0 }
                $mode    = if ($v.PreferredMode) { $v.PreferredMode } else { "?" }
                Write-Host ("    {0,-24} [{1,-6}]  cpu={2,5}%  samples={3,5}  preferMode={4}" -f $a.Name, $v.Category, $avgCPU, $samples, $mode) -ForegroundColor White
            }
            if ($learning -gt 0) {
                Write-WARN "$learning aplikacji wciąż w LEARNING (potrzeba 30+ próbek — graj dłużej)."
            }
        }
    } catch { Write-FAIL "Błąd parsowania ProphetMemory.json: $($_.Exception.Message)" }
}

# ─── [6] Podsumowanie i instrukcja interpretacji ──────────────────────────────
Write-Header "6  Jak czytać te wyniki — interpretacja poprawnego działania"

Write-Host @"

  CO POWINNAŚ WIDZIEĆ PO POPRAWNYM DZIAŁANIU (po 2-3 sesjach gry):
  ─────────────────────────────────────────────────────────────────
  [1] RAMCache.json      — gra ma LearnedFiles (dziesiątki modułów DLL)
  [2] Disk manifesty     — plik <gra>.json istnieje w C:\CPUManager\Cache\
                           files=X (DLL+shadery), SizeMB=Y
  [3] Log — Launch Race  — przy KAŻDYM uruchomieniu gry:
                             LAUNCH RACE START 'gra' — preemptive preload...
                             MANIFEST QUEUE 'gra': X files (~Y MB) → BatchQueue
                             LAUNCH RACE WIN 'gra' — all files loaded (startup~Zms)
             HIT          — IsAppCached() zwraca TRUE = trafienie w cache
  [4] Standby List        — duża (GB) = file cache aktywny
  [5] ProphetMemory       — gra ma kategorię HEAVY, PreferredMode=Turbo

  CO OZNACZA ŻE PRELOAD NIE DZIAŁA (placebo):
  ────────────────────────────────────────────
  × Launch Race END zamiast WIN = ENGINE nie zdążył załadować DLL przed startem
  × Brak HIT = plik nie był w RAMCache gdy gra pytała OS
  × Mała Standby List (<200MB) = kernel wyczyścił cache
  × EVICT często = brak RAM (zbyt małe GuardBand lub RAM za mały)
  × RETOUCH zbyt rzadko lub brak = strony mogły wylądować na cold standby

  WAŻNA UWAGA o testowaniu:
  ─────────────────────────
  NIE czyść pliku stronicowania (page file) między testami!
  NIE używaj RAMMap/EmptyWorkingSet do "oczyszczenia" RAM przed testem
  (to właśnie wyczyściłoby standby list, czyli efekt preloadu).
  Benchmark: uruchom grę i zmierz czas do menu PIERWSZY raz vs DRUGI raz.
  Różnica (szczególnie dla HDD/SATA SSD) to realny zysk preloadu.

"@ -ForegroundColor Gray

Write-Host $hr -ForegroundColor DarkCyan
Write-Host "  Koniec diagnostyki. Logi ENGINE: $LogPath" -ForegroundColor Cyan
Write-Host $hr -ForegroundColor DarkCyan
