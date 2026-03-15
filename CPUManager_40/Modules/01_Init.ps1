# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 01_Init.ps1
# TDP safety limits, console sizing, process priority
# Lines 1-150 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
# ═══════════════════════════════════════════════════════════════════════════════
# CPUManager ENGINE v43.9 - AI KNOWLEDGE TRANSFER (FIXED)
# © 2026 Michał | v43.9: 2026-02-02
# ═══════════════════════════════════════════════════════════════════════════════
# v43.9 CRITICAL FIX (Claude Opus 4.5):
#   - NAPRAWIONO funkcję Show-Database (brakowało ciała ForEach-Object + zamknięć)
#   - NAPRAWIONO nadmiarowy } w bloku AIEngines config check (linia ~14487)
#   - Plik przechodzi walidację składni PowerShell
# ═══════════════════════════════════════════════════════════════════════════════
# v43.8 AI KNOWLEDGE TRANSFER (AICoordinator):
#   - WYKORZYSTUJE istniejący AICoordinator zamiast nowych funkcji
#   - Dodano metody do AICoordinator:
#     * IntegrateProphetData() - profile aplikacji do transferData
#     * IntegrateGPUBoundData() - scenariusze GPU-bound do transferData
#     * IntegrateBanditData() - Thompson Sampling stats do transferData
#     * IntegrateGeneticData() - ewolucyjne progi do transferData
#     * ApplyEnrichedToEnsemble() - aplikuj rozszerzony transferData do Ensemble
#     * TransferBackFromEnsemble() - oddaj wiedzę z Ensemble do Q-Learning/Prophet
#     * TransferBackFromBrain() - oddaj wiedzę z Brain do Q-Learning
#   - Ensemble ON: pobiera wiedzę z QLearning+Prophet+GPUBound+Bandit+Genetic
#   - Ensemble OFF: oddaje wiedzę do Q-Learning i Prophet
#   - Brain ON: pobiera wiedzę z QLearning+Prophet (używa istn. ApplyToNeuralBrain)
#   - Brain OFF: oddaje AggressionBias boost do Q-Learning
#   - Blend 70/30 zachowany (jak w oryginalnym AICoordinator)
#   - Logowanie przez AICoordinator.LogActivity()
# ═══════════════════════════════════════════════════════════════════════════════
# v43.3 CRITICAL FIX:
#   - $neuralBrainEnabledUser i $ensembleEnabledUser przeniesite PRZED hashtable
#   - Poprzednia wersja miała te zmienne WEWNĄTRZ @{} co crashowało ENGINE!
#   - Teraz widgetData zapisuje się poprawnie do WidgetData.json
#   - Komunikacja ENGINE <-> CONFIGURATOR przywrócona
# ═══════════════════════════════════════════════════════════════════════════════
# V42.5: TIMER-BASED HYSTERESIS - FIX PING-PONG!
# 
# PROBLEM v42.4:
# - Entry: CPU<45%, Exit: CPU>45% (instant)
# - Silent Hill: CPU skacze 40-55% → Mode ping-pong co 5 sekund! ❌
# - Wentylator: 2500 RPM ↔ 4000 RPM → IRYTUJĄCE! ❌
# - Rezultat: Balanced ↔ Turbo ↔ Balanced → brak stabilności!
# 
# ROZWIĄZANIE v42.5:
# ✅ Entry: CPU < 50% (wyższy próg, łatwiejsze wejście)
# ✅ Exit: CPU > 50% przez 3+ sekund (timer-based!)
# ✅ CPU spike 52% na 1s → ignoruj (timer nie upłynął)
# ✅ CPU 52% przez 5s → exit GPU-bound (confirmed)
# ✅ Rezultat: Mode STABILNY mimo CPU fluktuacji!
#
# PRZYKŁAD DZIAŁANIA:
# Silent Hill - CPU 30-55% zmienne:
# [t=0s]  CPU=45%, GPU=95% → GPU-BOUND entry ✅
# [t=2s]  CPU=52%, GPU=95% → EXIT pending 0/3s (stay GPU-bound) ✅
# [t=3s]  CPU=48%, GPU=95% → EXIT cancelled (stay GPU-bound) ✅
# [t=5s]  CPU=54%, GPU=95% → EXIT pending 0/3s (stay GPU-bound) ✅
# [t=8s]  CPU=56%, GPU=95% → EXIT pending 3/3s → TURBO ✅
# Rezultat: Mode stabilny przez 8 sekund! (było: ping-pong co 2s)
#
# V42.4: GPU-BOUND DETECTION - Podstawowe działanie
# 1. GPUBoundDetector - wykrywa scenariusze Low CPU + High GPU
# 2. Integracja W HIGH (priorytet 3)
# 3. Kompatybilność: AMD/Intel CPU + iGPU/dGPU
# 4. Intelligent reduction: 5-10-15W based on CPU usage
# 
# EFEKT GPU-BOUND:
# - CPU 30%, GPU 90% → ENGINE obniża CPU TDP (35W→25W)
# - Chłodniejszy system (-10-15°C CPU, -4-7°C GPU)
# - GPU boost wyżej (+50-100MHz) dzięki lepszym warunkom termalnym
# - Więcej FPS (+2-5%) przy MNIEJSZYM zużyciu energii
# - Kompatybilne z APU (AMD shared power budget) i dGPU (Nvidia/AMD)
#
# V42.1: FIX PROPHET LEARNING - Ciągłe uczenie aplikacji
# 1. Prophet.UpdateRunning() - aktualizacja danych co ~10s podczas pracy aplikacji
# 2. Mechanizm confidence (30 próbek) - finalizacja kategorii dopiero po wystarczających danych
# 3. V42 logic fix - Prophet SUGERUJE tryb, nie wymusza (rzeczywiste CPU ma priorytet)
# ═══════════════════════════════════════════════════════════════════════════════
# V42.5: HIERARCHIA DECYZJI (GPU-BOUND + TIMER HYSTERESIS):
# 1. THERMAL >90°C → Silent      5. HOLD SILENT (hysteresis)
# 2. LOADING (I/O>80) → Turbo    6. PROPHET (zna app)
# 3. HIGH >70% → Turbo           7. LOW <20% → Silent
#    ├─ GPU-BOUND check W HIGH ⭐
#    ├─ Entry: CPU<50% + GPU>75% (instant)
#    └─ Exit: CPU>50% przez 3s (timer!) → STABILNY!
# 4. HOLD TURBO (hysteresis)     8. DEFAULT → Balanced
# ═══════════════════════════════════════════════════════════════════════════════
#       --> Przeniesiono jako funkcję globalną przed definicję klasy
#       --> Dodano brakujący try { przed wywołaniem Main
#       --> Zapobiega "File is being used" gdy GUI czyta plik podczas zapisu ENGINE
#       --> TODO: Zastąpić wszystkie [File]::WriteAllText w metodach SaveState klas AI
# #
# #
#   1. USUNIETO podwojne wczytywanie Prophet/Brain (Load-State + LoadState metody)
#   2. NAPRAWIONO bug $_.Name w Load-State (zagniezdzone petle ForEach-Object)
#   3. NAPRAWIONO ten sam bug w ProphetMemory.LoadState
#   4. USUNIETO podwojne RecordLaunch (z brain.Train + glowna petla)
#   5. DODANO brakujace pola do Save-State (LastLearnTime, RAMWeight)
#   6. USUNIETO warunki Is-NeuralBrainEnabled przy Save-State (6 miejsc)
#   7. USUNIETO warunek Is-NeuralBrainEnabled z Load-State dla Brain
#   8. USUNIETO podwojne zapisywanie w auto-save (3x->1x)
#   9. NAPRAWIONO bug $_.Name w QLearningAgent.LoadState
#  10. NAPRAWIONO ten sam bug w LoadPredictor.LoadPatterns (HourlyData, AppLaunchPatterns)
#  11. NAPRAWIONO ten sam bug w NetworkAI.LoadState (NetworkQTable)
#  12. NAPRAWIONO ten sam bug w AICoordinator.LoadState (EngineSuccessRate)
# #
#   JEDNORAZOWO przy pierwszym uruchomieniu:
#   DYNAMICZNIE podczas dzialania:
#  NEW: NetworkAI - uczenie sie wzorcow sieciowych (PELNA INTEGRACJA Z AI!)
#   CO ROBI:
#   WBUDOWANA WIEDZA:
#   ZAPISUJE DO: NetworkAI.json (profile aplikacji, wzorce czasowe, Q-Table)
#   EFEKT: AI wyprzedza optymalizacje - wie ze o 20:00 grasz w Valorant
# -  FIX KRYTYCZNY: JSON mode backupInterval byl 999999 (praktycznie NIGDY!)
#   Rozwiazanie: Zmieniono z 999999 na 150 iteracji (~5 minut)
# - - FIX: ErrorLog.txt spam - usunieto logi DEBUG zapisywane co sekunde
#   Powod: Blokowal zapis gdy silnik wylaczony, powodujac utrate danych
#   Powod: Podwojna ochrona (auto-save + SaveState) blokowala zapis
#   Powod: Pliki tworzone dopiero przy zamknieciu, nie przy starcie
# #
# TDP SAFETY LIMITS - KRYTYCZNE BEZPIECZNIKI
# #
$Script:TDP_HARD_LIMITS = @{ # (console sizing and priority moved below to avoid duplicate try blocks)
    MaxSTAPM = 28      # Absolutny maksymalny STAPM (W) - dopasowano do profilu Extreme
    MaxFast = 40       # Absolutny maksymalny Fast Boost (W)
    MaxSlow = 35       # Absolutny maksymalny Slow Boost (W)
    MaxTctl = 92       # Absolutna maksymalna temperatura (°C)
    MinSTAPM = 10      # Minimalny STAPM (zabezpieczenie przed 0)
    MinTctl = 50       # Minimalna temperatura (zabezpieczenie)
    AutoAdjustTctl = $true  # Jesli $true -> automatycznie dopasowuje Tctl do zakresu [MinTctl, MaxTctl]; jesli $false -> tylko ostrzega przy MinTctl
}
try {
    $raw = $Host.UI.RawUI
    $desiredWidth = 157
    $desiredWinHeight = 41
    $desiredBufHeight = 9000

    $buf = $raw.BufferSize
    if ($buf.Width -ne $desiredWidth -or $buf.Height -lt $desiredBufHeight) {
        $buf.Width = $desiredWidth
        $buf.Height = [int]$desiredBufHeight
        $raw.BufferSize = $buf
    }

    $win = $raw.WindowSize
    if ($win.Width -ne $desiredWidth -or $win.Height -ne $desiredWinHeight) {
        $win.Width = $desiredWidth
        $win.Height = $desiredWinHeight
        $raw.WindowSize = $win
    }

    $proc = Get-Process -Id $PID -ErrorAction Stop
    if ($proc.PriorityClass -ne 'BelowNormal') { $proc.PriorityClass = 'BelowNormal' }
} catch {}