# ═══════════════════════════════════════════════════════════════════════════════
# MODULE: 06_Classes_AI_Advanced.ps1
# Advanced AI: MultiArmedBandit, GeneticOptimizer, DecisionExplainer, ThermalGuardian, ProcessAI, GPUAI, NetworkOptimizer, NetworkAI
# Lines 12999-15751 from CPUManager_v40.ps1 (original)
# ═══════════════════════════════════════════════════════════════════════════════
class MultiArmedBandit {
    [hashtable] $Arms          # Turbo, Balanced, Silent
    [hashtable] $Successes     # Alpha (successes)
    [hashtable] $Failures      # Beta (failures)
    [string] $LastArm
    [int] $TotalPulls
    [hashtable] $EngineWeights        # Wagi zaufania dla silnikow AI
    [hashtable] $EngineSuccessRate    # Success rate per engine per context
    [hashtable] $SpikeResponseTime    # Jak szybko engine reagowal na spike
    [System.Collections.Generic.List[hashtable]] $ContextHistory  # Historia kontekstow
    [bool] $PassiveAdvisorMode        # Tryb obserwacji (gdy Ensemble OFF)
    [hashtable] $AdvisoryLog          # Co bysmy wybrali w trybie passive
    [datetime] $LastSpikeTime
    [string] $LastBestEngine
    [int] $TurboFocusCounter          # Licznik priorytetow Turbo Focus
    MultiArmedBandit() {
        $this.Arms = @{ "Turbo" = 0.15; "Balanced" = 0.50; "Silent" = 0.35 }
        # - Turbo ma niski prior (duzo porazek), Balanced wysoki (duzo sukcesow)
        $this.Successes = @{ "Turbo" = 1.0; "Balanced" = 10.0; "Silent" = 5.0 }
        $this.Failures = @{ "Turbo" = 10.0; "Balanced" = 1.0; "Silent" = 2.0 }
        $this.LastArm = "Balanced"
        $this.TotalPulls = 0
        $this.EngineWeights = @{
            "Brain" = 0.25
            "QLearning" = 0.40
            "Patterns" = 0.15
            "Prophet" = 0.20
        }
        $this.EngineSuccessRate = @{
            "Brain" = @{ "Spike" = 0.5; "Linear" = 0.5; "Exponential" = 0.5; "Decel" = 0.5 }
            "QLearning" = @{ "Spike" = 0.5; "Linear" = 0.5; "Exponential" = 0.5; "Decel" = 0.5 }
            "Patterns" = @{ "Spike" = 0.5; "Linear" = 0.5; "Exponential" = 0.5; "Decel" = 0.5 }
            "Prophet" = @{ "Spike" = 0.5; "Linear" = 0.5; "Exponential" = 0.5; "Decel" = 0.5 }
        }
        $this.SpikeResponseTime = @{
            "Brain" = 999.0
            "QLearning" = 999.0
            "Patterns" = 999.0
            "Prophet" = 999.0
        }
        $this.ContextHistory = New-Object System.Collections.Generic.List[hashtable]
        $this.PassiveAdvisorMode = $false
        $this.AdvisoryLog = @{}
        $this.LastSpikeTime = [datetime]::MinValue
        $this.LastBestEngine = "QLearning"
        $this.TurboFocusCounter = 0
    }
    # #
    # #
    [hashtable] GetBestEngineCandidate([hashtable]$ramInfo, [hashtable]$availableEngines, [string]$currentThreshold) {
        $acceleration = if ($ramInfo -and $ramInfo.Acceleration) { $ramInfo.Acceleration } else { 0.0 }
        $trendType = if ($ramInfo -and $ramInfo.TrendType) { $ramInfo.TrendType } else { "NONE" }
        $delta = if ($ramInfo -and $ramInfo.Delta) { $ramInfo.Delta } else { 0.0 }
        $spike = if ($ramInfo -and $ramInfo.Spike) { $ramInfo.Spike } else { $false }
        # Spike Detection: >5.8% delta = CRITICAL SPIKE
        $isCriticalSpike = ($delta -gt 5.8)
        # Context scoring
        $scores = @{}
        foreach ($engine in $availableEngines.Keys) {
            if (-not $availableEngines[$engine]) { continue }  # Skip disabled engines
            $score = 0.0
            # Base weight
            $score += $this.EngineWeights[$engine] * 100
            #  RAM Intelligence Boost
            if ($acceleration -gt 2.0) {
                # Wysokie przyspieszenie -> preferuj Brain lub QLearning
                if ($engine -eq "Brain") { $score += 30 }
                if ($engine -eq "QLearning") { $score += 25 }
            }
            #  Trend Type Specialization
            switch ($trendType) {
                "LINEAR" {
                    # LINEAR -> lekki silnik wystarczy
                    if ($engine -eq "Patterns") { $score += 20 }
                    if ($engine -eq "QLearning") { $score += 15 }
                }
                "EXPONENTIAL" {
                    # EXPONENTIAL -> ciezki kaliber
                    if ($engine -eq "Brain") { $score += 35 }
                    if ($engine -eq "QLearning") { $score += 20 }
                }
                "DECEL" {
                    # DECEL -> konserwatywny
                    if ($engine -eq "Prophet") { $score += 20 }
                    if ($engine -eq "Patterns") { $score += 15 }
                }
            }
            #  CRITICAL SPIKE -> Turbo Focus Mode
            if ($isCriticalSpike) {
                # 100% zaufanie dla najszybszego respondenta
                $fastestResponseTime = 999.0
                $fastestEngine = $engine
                foreach ($e in $this.SpikeResponseTime.Keys) {
                    if ($availableEngines[$e] -and $this.SpikeResponseTime[$e] -lt $fastestResponseTime) {
                        $fastestResponseTime = $this.SpikeResponseTime[$e]
                        $fastestEngine = $e
                    }
                }
                if ($engine -eq $fastestEngine) {
                    $score = 1000  # Force selection
                    $this.TurboFocusCounter++
                } else {
                    $score = 0  # Suppress others
                }
            }
            #  Dynamic Threshold Adjustment
            # COOL threshold (4%) -> agresywny przy malym ruchu
            if ($currentThreshold -eq "COOL" -and $delta -gt 1.0) {
                if ($engine -eq "Brain" -or $engine -eq "QLearning") {
                    $score += 15
                }
            }
            #  Success Rate Context Boost
            if ($this.EngineSuccessRate.ContainsKey($engine)) {
                $contextKey = if ($spike) { "Spike" } else { $trendType }
                if ($this.EngineSuccessRate[$engine].ContainsKey($contextKey)) {
                    $successRate = $this.EngineSuccessRate[$engine][$contextKey]
                    $score += $successRate * 50  # 0.5 = +25, 1.0 = +50
                }
            }
            $scores[$engine] = $score
        }
        # Find best
        $bestEngine = "QLearning"  # fallback
        $bestScore = 0
        foreach ($engine in $scores.Keys) {
            if ($scores[$engine] -gt $bestScore) {
                $bestScore = $scores[$engine]
                $bestEngine = $engine
            }
        }
        $this.LastBestEngine = $bestEngine
        return @{
            BestEngine = $bestEngine
            Scores = $scores
            Confidence = [Math]::Min(100, [int]($bestScore / 10))
            TurboFocus = $isCriticalSpike
            Context = @{
                Acceleration = $acceleration
                TrendType = $trendType
                Delta = $delta
                Threshold = $currentThreshold
            }
        }
    }
    # #
    # #
    [void] UpdateEnginePerformance([string]$engine, [string]$context, [bool]$success, [double]$responseTime) {
        if (-not $this.EngineSuccessRate.ContainsKey($engine)) { return }
        # Update success rate (exponential moving average)
        $currentRate = $this.EngineSuccessRate[$engine][$context]
        $newRate = if ($success) { 
            $currentRate * 0.9 + 0.1 * 1.0  # Success
        } else {
            $currentRate * 0.9 + 0.1 * 0.0  # Failure
        }
        $this.EngineSuccessRate[$engine][$context] = $newRate
        # Update response time for spike detection
        if ($context -eq "Spike" -and $responseTime -lt $this.SpikeResponseTime[$engine]) {
            $this.SpikeResponseTime[$engine] = $responseTime
        }
        # Update engine weight (global trust)
        if ($success) {
            $this.EngineWeights[$engine] = [Math]::Min(1.0, $this.EngineWeights[$engine] + 0.01)
        } else {
            $this.EngineWeights[$engine] = [Math]::Max(0.05, $this.EngineWeights[$engine] - 0.005)
        }
        # Normalize weights
        $totalWeight = 0.0
        foreach ($e in $this.EngineWeights.Keys) { $totalWeight += $this.EngineWeights[$e] }
        if ($totalWeight -gt 0) {
            $engineKeys = @($this.EngineWeights.Keys)
            foreach ($e in $engineKeys) {
                $this.EngineWeights[$e] /= $totalWeight
            }
        }
    }
    # #
    # #
    [void] RecordAdvisoryDecision([hashtable]$ramInfo, [hashtable]$availableEngines, [string]$actualEngine, [bool]$success) {
        if (-not $this.PassiveAdvisorMode) { return }
        # Zapisz co bysmy wybrali
        $recommendation = $this.GetBestEngineCandidate($ramInfo, $availableEngines, "NORMAL")
        $advisoryEntry = @{
            Timestamp = [datetime]::Now
            Recommended = $recommendation.BestEngine
            Actual = $actualEngine
            Success = $success
            Context = $recommendation.Context
        }
        # Store in log
        $key = [datetime]::Now.ToString("yyyy-MM-dd-HH-mm-ss")
        $this.AdvisoryLog[$key] = $advisoryEntry
        # Keep only last 100 entries
        if ($this.AdvisoryLog.Count -gt 100) {
            $oldest = ($this.AdvisoryLog.Keys | Sort-Object)[0]
            $this.AdvisoryLog.Remove($oldest)
        }
        # Continue learning even in passive mode
        $context = if ($ramInfo.Spike) { "Spike" } else { $ramInfo.TrendType }
        $this.UpdateEnginePerformance($actualEngine, $context, $success, 0.5)
    }
    # #
    # Original methods (preserved)
    # #
    # Thompson Sampling - probkowanie z rozkladu Beta
    [string] SelectArm() {
        $samples = @{}
        foreach ($arm in $this.Arms.Keys) {
            # Symulacja rozkladu Beta przez przyblizenie
            $alpha = $this.Successes[$arm]
            $beta = $this.Failures[$arm]
            # Uzywamy sredniej + szum zamiast pelnego rozkladu Beta
            $mean = $alpha / ($alpha + $beta)
            $variance = ($alpha * $beta) / (($alpha + $beta) * ($alpha + $beta) * ($alpha + $beta + 1))
            $noise = (Get-Random -Minimum -100 -Maximum 100) / 100.0 * [Math]::Sqrt($variance) * 2
            $samples[$arm] = [Math]::Max(0, [Math]::Min(1, $mean + $noise))
        }
        # Wybierz arm z najwyzsza probka
        $bestArm = "Balanced"
        $bestSample = 0
        foreach ($arm in $samples.Keys) {
            if ($samples[$arm] -gt $bestSample) {
                $bestSample = $samples[$arm]
                $bestArm = $arm
            }
        }
        $this.LastArm = $bestArm
        $this.TotalPulls++
        return $bestArm
    }
    # Aktualizuj na podstawie nagrody (0-1)
    [void] Update([string]$arm, [bool]$success) {
        if (-not $this.Successes.ContainsKey($arm)) { return }
        if ($success) {
            $this.Successes[$arm] += 1.0
        } else {
            $this.Failures[$arm] += 1.0
        }
        # Decay stare obserwacje (zapominanie)
        if ($this.TotalPulls % 100 -eq 0) {
            $armKeys = @($this.Successes.Keys)
            foreach ($a in $armKeys) {
                $this.Successes[$a] = [Math]::Max(1, $this.Successes[$a] * 0.95)
                $this.Failures[$a] = [Math]::Max(1, $this.Failures[$a] * 0.95)
            }
        }
    }
    [double] GetArmProbability([string]$arm) {
        if (-not $this.Successes.ContainsKey($arm)) { return 0.33 }
        $alpha = $this.Successes[$arm]
        $beta = $this.Failures[$arm]
        return [Math]::Round($alpha / ($alpha + $beta), 3)
    }
    [string] GetStatus() {
        $t = $this.GetArmProbability("Turbo")
        $b = $this.GetArmProbability("Balanced")
        $s = $this.GetArmProbability("Silent")
        return "T:$([Math]::Round($t*100))% B:$([Math]::Round($b*100))% S:$([Math]::Round($s*100))%"
    }
    [string] GetEngineStatus() {
        $status = "Engines: "
        foreach ($engine in $this.EngineWeights.Keys) {
            $weight = [Math]::Round($this.EngineWeights[$engine] * 100)
            $status += "$engine=$weight% "
        }
        if ($this.PassiveAdvisorMode) {
            $status += "| PASSIVE ADVISOR"
        }
        if ($this.TurboFocusCounter -gt 0) {
            $status += "| TurboFocus=$($this.TurboFocusCounter)"
        }
        return $status.Trim()
    }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "Bandit.json"
            $data = @{
                Successes = $this.Successes
                Failures = $this.Failures
                TotalPulls = $this.TotalPulls
                EngineWeights = $this.EngineWeights
                EngineSuccessRate = $this.EngineSuccessRate
                SpikeResponseTime = $this.SpikeResponseTime
                TurboFocusCounter = $this.TurboFocusCounter
            }
            [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 8 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "Bandit.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.Successes) { 
                    $data.Successes.PSObject.Properties | ForEach-Object { $this.Successes[$_.Name] = [double]$_.Value }
                }
                if ($data.Failures) {
                    $data.Failures.PSObject.Properties | ForEach-Object { $this.Failures[$_.Name] = [double]$_.Value }
                }
                if ($data.TotalPulls) { $this.TotalPulls = $data.TotalPulls }
                if ($data.EngineWeights) {
                    $data.EngineWeights.PSObject.Properties | ForEach-Object {
                        $this.EngineWeights[$_.Name] = [double]$_.Value
                    }
                }
                if ($data.EngineSuccessRate) {
                    foreach ($engine in $data.EngineSuccessRate.PSObject.Properties) {
                        $engineName = $engine.Name  # v39 FIX
                        if (-not $this.EngineSuccessRate.ContainsKey($engineName)) {
                            $this.EngineSuccessRate[$engineName] = @{}
                        }
                        $engine.Value.PSObject.Properties | ForEach-Object {
                            $modeName = $_.Name  # v39 FIX
                            $this.EngineSuccessRate[$engineName][$modeName] = [double]$_.Value
                        }
                    }
                }
                if ($data.SpikeResponseTime) {
                    $data.SpikeResponseTime.PSObject.Properties | ForEach-Object {
                        $this.SpikeResponseTime[$_.Name] = [double]$_.Value
                    }
                }
                if ($data.TurboFocusCounter) { $this.TurboFocusCounter = $data.TurboFocusCounter }
            }
        } catch { }
    }
}
class GeneticOptimizer {
    [System.Collections.Generic.List[hashtable]] $Population
    [int] $PopulationSize
    [int] $Generation
    [double] $MutationRate
    [double] $BestFitness
    [double] $LastFitnessImprovement  # V37.8.5: Ostatnia poprawa fitness (do wyswietlania w Configurator)
    [hashtable] $BestGenome
    [hashtable] $CurrentGenome
    GeneticOptimizer() {
        $this.PopulationSize = 8
        $this.Generation = 0
        $this.MutationRate = 0.15
        $this.BestFitness = 0
        $this.LastFitnessImprovement = 0.0
        $this.Population = [System.Collections.Generic.List[hashtable]]::new()
        # Inicjalizuj populacje
        for ($i = 0; $i -lt $this.PopulationSize; $i++) {
            $this.Population.Add($this.CreateRandomGenome())
        }
        $this.BestGenome = $this.Population[0].Clone()
        $this.CurrentGenome = $this.Population[0].Clone()
    }
    [hashtable] CreateRandomGenome() {
        return @{
            TurboThreshold = Get-Random -Minimum 70 -Maximum 85
            BalancedThreshold = Get-Random -Minimum 30 -Maximum 55
            SilentAggression = [Math]::Round((Get-Random -Minimum 30 -Maximum 80) / 100.0, 2)
            ThermalWeight = [Math]::Round((Get-Random -Minimum 10 -Maximum 40) / 100.0, 2)
            ActivityWeight = [Math]::Round((Get-Random -Minimum 20 -Maximum 50) / 100.0, 2)
            PredictionWeight = [Math]::Round((Get-Random -Minimum 10 -Maximum 30) / 100.0, 2)
            BoostDuration = Get-Random -Minimum 3 -Maximum 10
            Fitness = 0.0
        }
    }
    [hashtable] Crossover([hashtable]$parent1, [hashtable]$parent2) {
        $child = @{}
        foreach ($key in $parent1.Keys) {
            if ($key -eq "Fitness") { $child[$key] = 0.0; continue }
            # 50/50 od kazdego rodzica
            if ((Get-Random -Maximum 2) -eq 0) {
                $child[$key] = $parent1[$key]
            } else {
                $child[$key] = $parent2[$key]
            }
        }
        return $child
    }
    [void] Mutate([hashtable]$genome) {
        if ((Get-Random -Minimum 0.0 -Maximum 1.0) -gt $this.MutationRate) { return }
        $keys = @("TurboThreshold", "BalancedThreshold", "SilentAggression", "ThermalWeight", "ActivityWeight")
        $key = $keys[(Get-Random -Maximum $keys.Count)]
        switch ($key) {
            "TurboThreshold" { $genome[$key] = [Math]::Max(50, [Math]::Min(85, $genome[$key] + (Get-Random -Minimum -10 -Maximum 10))) }
            "BalancedThreshold" { $genome[$key] = [Math]::Max(20, [Math]::Min(60, $genome[$key] + (Get-Random -Minimum -10 -Maximum 10))) }
            "SilentAggression" { $genome[$key] = [Math]::Max(0.2, [Math]::Min(0.9, $genome[$key] + (Get-Random -Minimum -20 -Maximum 20) / 100.0)) }
            "ThermalWeight" { $genome[$key] = [Math]::Max(0.05, [Math]::Min(0.5, $genome[$key] + (Get-Random -Minimum -10 -Maximum 10) / 100.0)) }
            "ActivityWeight" { $genome[$key] = [Math]::Max(0.1, [Math]::Min(0.6, $genome[$key] + (Get-Random -Minimum -10 -Maximum 10) / 100.0)) }
        }
    }
    [void] EvaluateFitness([int]$genomeIndex, [double]$performance, [double]$efficiency, [double]$thermal) {
        if ($genomeIndex -lt 0 -or $genomeIndex -ge $this.Population.Count) { return }
        # Fitness = weighted sum
        $fitness = ($performance * 0.4) + ($efficiency * 0.35) + ($thermal * 0.25)
        $this.Population[$genomeIndex].Fitness = $fitness
        if ($fitness -gt $this.BestFitness) {
            $this.LastFitnessImprovement = $fitness - $this.BestFitness  # v39: Zapisz poprawe
            $this.BestFitness = $fitness
            $this.BestGenome = $this.Population[$genomeIndex].Clone()
        } else {
            $this.LastFitnessImprovement = 0.0
        }
    }
    [void] Evolve() {
        # Sortuj po fitness (malejaco)
        $sorted = $this.Population | Sort-Object { $_.Fitness } -Descending
        # Elityzm: zachowaj top 2
        $newPop = [System.Collections.Generic.List[hashtable]]::new()
        $newPop.Add($sorted[0].Clone())
        $newPop.Add($sorted[1].Clone())
        # Reszta przez crossover + mutation
        while ($newPop.Count -lt $this.PopulationSize) {
            $p1 = $sorted[(Get-Random -Maximum ([Math]::Min(4, $sorted.Count)))]
            $p2 = $sorted[(Get-Random -Maximum ([Math]::Min(4, $sorted.Count)))]
            $child = $this.Crossover($p1, $p2)
            $this.Mutate($child)
            $newPop.Add($child)
        }
        $this.Population = $newPop
        $this.Generation++
        $this.CurrentGenome = $this.BestGenome.Clone()
    }
    [hashtable] GetCurrentParams() {
        return $this.CurrentGenome
    }
    [string] GetStatus() {
        return "Gen:$($this.Generation) Fit:$([Math]::Round($this.BestFitness * 100))%"
    }
    [void] SaveState([string]$dir) {
        try {
            $path = Join-Path $dir "Genetic.json"
            $data = @{
                Generation = $this.Generation
                BestFitness = $this.BestFitness
                BestGenome = $this.BestGenome
                MutationRate = $this.MutationRate
            }
            [System.IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 3 -Compress), [System.Text.Encoding]::UTF8)
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "Genetic.json"
            if (Test-Path $path) {
                $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
                if ($data.Generation) { $this.Generation = $data.Generation }
                if ($data.BestFitness) { $this.BestFitness = $data.BestFitness }
                if ($data.BestGenome) {
                    $this.BestGenome = @{}
                    $data.BestGenome.PSObject.Properties | ForEach-Object { $this.BestGenome[$_.Name] = $_.Value }
                    $this.CurrentGenome = $this.BestGenome.Clone()
                }
            }
        } catch { }
    }
}
#  ULTRA: DECISION EXPLAINER - Wyjasnia decyzje AI
class DecisionExplainer {
    [System.Collections.Generic.List[hashtable]] $RecentDecisions
    [int] $MaxHistory
    [hashtable] $LastMetrics
    [string] $LastMode
    [System.Collections.Generic.List[string]] $CurrentReasons
    DecisionExplainer() {
        $this.RecentDecisions = [System.Collections.Generic.List[hashtable]]::new()
        $this.MaxHistory = 50
        $this.LastMetrics = @{}
        $this.LastMode = ""
        $this.CurrentReasons = [System.Collections.Generic.List[string]]::new()
    }
    [void] Analyze([hashtable]$metrics, [string]$decision, [hashtable]$context) {
        $this.CurrentReasons.Clear()
        $cpu = if ($metrics.CPU) { $metrics.CPU } else { 0 }
        $temp = if ($metrics.Temp) { $metrics.Temp } else { 0 }
        $gpuLoad = if ($metrics.GPU -and $metrics.GPU.Load) { $metrics.GPU.Load } else { 0 }
        $gpuTemp = if ($metrics.GPU -and $metrics.GPU.Temp) { $metrics.GPU.Temp } else { 0 }
        $vrmTemp = if ($metrics.VRM -and $metrics.VRM.Temp) { $metrics.VRM.Temp } else { 0 }
        $ram = if ($metrics.RAMUsage) { $metrics.RAMUsage } else { 0 }
        $power = if ($metrics.CPUPower) { $metrics.CPUPower } else { 0 }
        $hour = (Get-Date).Hour
        # Analizuj powody decyzji
        switch ($decision) {
            "Silent" {
                if ($cpu -lt 20) { $this.CurrentReasons.Add("CPU niskie ($cpu%)") }
                if ($temp -lt 50) { $this.CurrentReasons.Add("Temp OK (${temp}C)") }
                if ($gpuLoad -lt 10) { $this.CurrentReasons.Add("GPU idle ($gpuLoad%)") }
                if ($hour -ge 22 -or $hour -lt 7) { $this.CurrentReasons.Add("Godziny nocne") }
                if ($context.Activity -eq "Idle") { $this.CurrentReasons.Add("Brak aktywnosci") }
                if ($context.Context -match "Light|Browse") { $this.CurrentReasons.Add("Lekka praca") }
            }
            "Balanced" {
                if ($cpu -ge 20 -and $cpu -lt 70) { $this.CurrentReasons.Add("Srednie CPU ($cpu%)") }
                if ($temp -ge 50 -and $temp -lt 75) { $this.CurrentReasons.Add("Srednia temp (${temp}C)") }
                if ($context.Context -match "Office|Browser") { $this.CurrentReasons.Add("Praca biurowa") }
                if ($gpuLoad -ge 10 -and $gpuLoad -lt 50) { $this.CurrentReasons.Add("GPU w uzyciu ($gpuLoad%)") }
            }
            "Turbo" {
                if ($cpu -ge 70) { $this.CurrentReasons.Add("Wysokie CPU ($cpu%)") }
                if ($gpuLoad -ge 50) { $this.CurrentReasons.Add("GPU obciazony ($gpuLoad%)") }
                if ($context.Context -match "Gaming|Heavy|Video") { $this.CurrentReasons.Add("Ciezka praca ($($context.Context))") }
                if ($context.Activity -match "Game|Render|Compile") { $this.CurrentReasons.Add("Aplikacja: $($context.Activity)") }
                if ($temp -lt 80) { $this.CurrentReasons.Add("Zapas termiczny (${temp}C < 80)") }
            }
        }
        # Ostrzezenia termiczne
        if ($temp -ge 85) { $this.CurrentReasons.Add("[WARN] UWAGA: CPU ${temp}C!") }
        if ($gpuTemp -ge 85) { $this.CurrentReasons.Add("[WARN] UWAGA: GPU ${gpuTemp}C!") }
        if ($vrmTemp -ge 90) { $this.CurrentReasons.Add("[WARN] UWAGA: VRM ${vrmTemp}C!") }
        # Zapisz decyzje
        if ($this.RecentDecisions.Count -ge $this.MaxHistory) {
            $this.RecentDecisions.RemoveAt(0)
        }
        $this.RecentDecisions.Add(@{
            Time = Get-Date
            Decision = $decision
            CPU = $cpu
            Temp = $temp
            GPU = $gpuLoad
            Reasons = [string[]]$this.CurrentReasons.ToArray()
        })
        $this.LastMetrics = $metrics
        $this.LastMode = $decision
    }
    [string] GetExplanation() {
        if ($this.CurrentReasons.Count -eq 0) {
            return "Brak danych"
        }
        return $this.CurrentReasons -join " | "
    }
    [string] GetShortExplanation() {
        if ($this.CurrentReasons.Count -eq 0) { return "" }
        $topReasons = @($this.CurrentReasons | Select-Object -First 2)
        return $topReasons -join ", "
    }
    [hashtable[]] GetHistory([int]$count) {
        $start = [Math]::Max(0, $this.RecentDecisions.Count - $count)
        return $this.RecentDecisions.GetRange($start, [Math]::Min($count, $this.RecentDecisions.Count)).ToArray()
    }
    [hashtable] GetStats() {
        $total = $this.RecentDecisions.Count
        if ($total -eq 0) { return @{ Silent = 0; Balanced = 0; Turbo = 0; Total = 0 } }
        $silent = ($this.RecentDecisions | Where-Object { $_.Decision -eq "Silent" }).Count
        $balanced = ($this.RecentDecisions | Where-Object { $_.Decision -eq "Balanced" }).Count
        $turbo = ($this.RecentDecisions | Where-Object { $_.Decision -eq "Turbo" }).Count
        return @{
            Silent = [Math]::Round(($silent / $total) * 100)
            Balanced = [Math]::Round(($balanced / $total) * 100)
            Turbo = [Math]::Round(($turbo / $total) * 100)
            Total = $total
        }
    }
    [string] GetStatus() {
        $stats = $this.GetStats()
        return "S:$($stats.Silent)% B:$($stats.Balanced)% T:$($stats.Turbo)%"
    }
    [void] SaveState([string]$dir) {
        try {
            $stats = $this.GetStats()
            # Zapisz statystyki i ostatnie 20 decyzji
            $recentToSave = @()
            $startIdx = [Math]::Max(0, $this.RecentDecisions.Count - 20)
            for ($i = $startIdx; $i -lt $this.RecentDecisions.Count; $i++) {
                $recentToSave += $this.RecentDecisions[$i]
            }
            $data = @{
                TotalDecisions = $this.RecentDecisions.Count
                Stats = $stats
                RecentDecisions = $recentToSave
                LastMode = $this.LastMode
            }
            $path = Join-Path $dir "DecisionExplainer.json"
            $data | ConvertTo-Json -Depth 5 | Set-Content $path -Encoding UTF8
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "DecisionExplainer.json"
            if (Test-Path $path) {
                $data = Get-Content $path -Raw | ConvertFrom-Json
                if ($data.RecentDecisions) {
                    foreach ($dec in $data.RecentDecisions) {
                        $this.RecentDecisions.Add(@{
                            Time = $dec.Time
                            Decision = $dec.Decision
                            Reasons = @($dec.Reasons)
                            CPU = $dec.CPU
                            GPU = $dec.GPU
                        })
                    }
                }
                if ($data.LastMode) { $this.LastMode = $data.LastMode }
            }
        } catch { }
    }
}
class ThermalGuardian {
    [double] $CPULimit
    [double] $GPULimit
    [double] $VRMLimit
    [bool] $ThrottleActive
    [string] $ThrottleReason
    [int] $ThrottleCount
    [datetime] $LastThrottle
    [System.Collections.Generic.List[double]] $TempHistory
    ThermalGuardian() {
        $this.CPULimit = 90      # CPU max temp
        $this.GPULimit = 85      # GPU max temp
        $this.VRMLimit = 95      # VRM max temp (mini PC often higher)
        $this.ThrottleActive = $false
        $this.ThrottleReason = ""
        $this.ThrottleCount = 0
        $this.LastThrottle = [datetime]::MinValue
        $this.TempHistory = [System.Collections.Generic.List[double]]::new()
    }
    [hashtable] Check([hashtable]$metrics) {
        $result = @{
            Throttle = $false
            Reason = ""
            Severity = 0  # 0=OK, 1=Warning, 2=Critical
            Recommendation = "Normal"
        }
        $cpuTemp = if ($metrics.Temp) { $metrics.Temp } else { 0 }
        $gpuTemp = if ($metrics.GPU -and $metrics.GPU.Temp) { $metrics.GPU.Temp } else { 0 }
        $vrmTemp = if ($metrics.VRM -and $metrics.VRM.Temp) { $metrics.VRM.Temp } else { 0 }
        # Track history
        if ($this.TempHistory.Count -ge 60) { $this.TempHistory.RemoveAt(0) }
        $this.TempHistory.Add($cpuTemp)
        # Check CPU
        if ($cpuTemp -ge $this.CPULimit) {
            $result.Throttle = $true
            $result.Reason = "CPU ${cpuTemp}C >= $($this.CPULimit)C"
            $result.Severity = 2
            $result.Recommendation = "ForceSilent"
        } elseif ($cpuTemp -ge ($this.CPULimit - 10)) {
            $result.Severity = 1
            $result.Reason = "CPU ${cpuTemp}C blisko limitu"
            $result.Recommendation = "AvoidTurbo"
        }
        # Check GPU
        if ($gpuTemp -ge $this.GPULimit) {
            $result.Throttle = $true
            $result.Reason += " | GPU ${gpuTemp}C >= $($this.GPULimit)C"
            $result.Severity = 2
            $result.Recommendation = "ForceSilent"
        } elseif ($gpuTemp -ge ($this.GPULimit - 10)) {
            if ($result.Severity -lt 1) { $result.Severity = 1 }
            $result.Reason += " | GPU ${gpuTemp}C blisko limitu"
            if ($result.Recommendation -eq "Normal") { $result.Recommendation = "AvoidTurbo" }
        }
        # Check VRM (critical for mini PC!)
        if ($vrmTemp -ge $this.VRMLimit) {
            $result.Throttle = $true
            $result.Reason += " | VRM ${vrmTemp}C >= $($this.VRMLimit)C!"
            $result.Severity = 2
            $result.Recommendation = "ForceSilent"
        } elseif ($vrmTemp -ge ($this.VRMLimit - 10)) {
            if ($result.Severity -lt 1) { $result.Severity = 1 }
            $result.Reason += " | VRM ${vrmTemp}C blisko limitu"
            if ($result.Recommendation -eq "Normal") { $result.Recommendation = "AvoidTurbo" }
        }
        # Update state
        if ($result.Throttle) {
            $this.ThrottleActive = $true
            $this.ThrottleReason = $result.Reason
            $this.ThrottleCount++
            $this.LastThrottle = Get-Date
        } else {
            $this.ThrottleActive = $false
            $this.ThrottleReason = ""
        }
        return $result
    }
    [double] GetTrend() {
        if ($this.TempHistory.Count -lt 10) { return 0 }
        $recent = $this.TempHistory | Select-Object -Last 10
        $old = $this.TempHistory | Select-Object -First 10
        return ($recent | Measure-Object -Average).Average - ($old | Measure-Object -Average).Average
    }
    [string] GetStatus() {
        $trend = $this.GetTrend()
        $trendStr = if ($trend -gt 1) { "?" } elseif ($trend -lt -1) { "?" } else { "->" }
        return "Throttle:$($this.ThrottleCount) Trend:$trendStr"
    }
    [void] SaveState([string]$dir) {
        try {
            $data = @{
                CPULimit = $this.CPULimit
                GPULimit = $this.GPULimit
                VRMLimit = $this.VRMLimit
                ThrottleCount = $this.ThrottleCount
                LastThrottle = $this.LastThrottle.ToString("o")
                # Zapisz ostatnie 30 temperatur do analizy trendu
                TempHistory = @($this.TempHistory | Select-Object -Last 30)
            }
            $path = Join-Path $dir "ThermalGuardian.json"
            $data | ConvertTo-Json -Depth 3 | Set-Content $path -Encoding UTF8
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "ThermalGuardian.json"
            if (Test-Path $path) {
                $data = Get-Content $path -Raw | ConvertFrom-Json
                if ($data.CPULimit) { $this.CPULimit = $data.CPULimit }
                if ($data.GPULimit) { $this.GPULimit = $data.GPULimit }
                if ($data.VRMLimit) { $this.VRMLimit = $data.VRMLimit }
                if ($data.ThrottleCount) { $this.ThrottleCount = $data.ThrottleCount }
                if ($data.LastThrottle) { 
                    try { $this.LastThrottle = [datetime]::Parse($data.LastThrottle, [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
                }
                if ($data.TempHistory) {
                    foreach ($t in $data.TempHistory) {
                        $this.TempHistory.Add([double]$t)
                    }
                }
            }
        } catch { }
    }
    [void] AdjustLimits([double]$cpuLimit, [double]$gpuLimit, [double]$vrmLimit) {
        # Pozwala dostosowac limity na podstawie doswiadczenia
        if ($cpuLimit -gt 70 -and $cpuLimit -lt 100) { $this.CPULimit = $cpuLimit }
        if ($gpuLimit -gt 60 -and $gpuLimit -lt 95) { $this.GPULimit = $gpuLimit }
        if ($vrmLimit -gt 80 -and $vrmLimit -lt 110) { $this.VRMLimit = $vrmLimit }
    }
}
# V40: PROCESSAI - Inteligentna optymalizacja procesów systemowych
class ProcessAI {
    [hashtable] $ProcessProfiles       # procName -> {AvgCPU, AvgRAM, Priority, CanThrottle, Sessions}
    [hashtable] $ThrottleHistory       # procName -> {ThrottleCount, RestoreCount, LastThrottle}
    [hashtable] $SafeToThrottle        # Procesy, które można bezpiecznie throttlować
    [hashtable] $HighPriorityApps      # Procesy wymagające wysokiego priorytetu
    [hashtable] $SystemProcesses       # Procesy systemowe - NIGDY nie throttle
    [int] $TotalLearnings = 0
    [int] $TotalThrottles = 0
    [datetime] $LastLearnTime
    
    ProcessAI() {
        $this.ProcessProfiles = @{}
        $this.ThrottleHistory = @{}
        $this.SafeToThrottle = @{}
        $this.HighPriorityApps = @{}
        $this.SystemProcesses = @{}
        $this.LastLearnTime = [DateTime]::Now
        
        # - V40: Procesy systemowe Windows - OCHRONA (nigdy nie throttle)
        $this.SystemProcesses = @{
            # Core Windows System
            "system" = $true
            "idle" = $true
            "registry" = $true
            "smss" = $true
            "csrss" = $true
            "wininit" = $true
            "services" = $true
            "lsass" = $true
            "winlogon" = $true
            # Windows Subsystem — BEZ TEGO = białe ikony, znikające UI
            "svchost" = $true
            "runtimebroker" = $true
            "dwm" = $true                      # Desktop Window Manager
            "explorer" = $true                 # File Explorer
            "shellexperiencehost" = $true      # Start Menu
            "searchhost" = $true
            "startmenuexperiencehost" = $true
            "applicationframehost" = $true     # UWP frames
            "textinputhost" = $true            # Keyboard/IME
            "shellhost" = $true                # Quick Settings
            "sihost" = $true                   # Shell Infrastructure Host
            "taskhostw" = $true                # Task Host Window
            "dllhost" = $true                  # COM Surrogate
            "fontdrvhost" = $true              # Font Driver Host
            "conhost" = $true                  # Console Host
            # Security & Updates
            "msmpeng" = $true                  # Windows Defender
            "securityhealthservice" = $true
            "trustedinstaller" = $true
            "wuauclt" = $true
            "usoclient" = $true
            # Audio & Drivers
            "audiodg" = $true
            "ctfmon" = $true
            # Network
            "dns" = $true
            "bits" = $true
            # Self-protection
            "cpumanager" = $true
            "powershell" = $true
            "pwsh" = $true
        }
        
        # Wbudowana wiedza - procesy, które ZAWSZE można throttlować
        $this.SafeToThrottle = @{
            "chrome" = @{ Confidence = 0.8; Reason = "Browser background" }
            "firefox" = @{ Confidence = 0.8; Reason = "Browser background" }
            "msedge" = @{ Confidence = 0.8; Reason = "Browser background" }
            "discord" = @{ Confidence = 0.7; Reason = "Chat app" }
            "spotify" = @{ Confidence = 0.9; Reason = "Music streaming" }
            "teams" = @{ Confidence = 0.6; Reason = "Communication" }
            "onedrive" = @{ Confidence = 0.9; Reason = "Cloud sync" }
            "dropbox" = @{ Confidence = 0.9; Reason = "Cloud sync" }
            "steamwebhelper" = @{ Confidence = 0.8; Reason = "Steam helper" }
        }
        
        # Procesy wymagające wysokiego priorytetu
        $this.HighPriorityApps = @{
            "valorant" = "Gaming"
            "csgo" = "Gaming"
            "cs2" = "Gaming"
            "dota2" = "Gaming"
            "obs64" = "Streaming"
            "obs" = "Streaming"
            "davinci resolve" = "Rendering"
            "premiere" = "Rendering"
            "blender" = "Rendering"
        }
    }
    
    # Główna metoda uczenia - analizuje procesy i ich zachowanie
    [void] Learn([string]$currentApp, [double]$cpu, [double]$ram) {
        if ([string]::IsNullOrWhiteSpace($currentApp)) { return }
        
        $appLower = $currentApp.ToLower()
        
        # Aktualizuj profil procesu
        if (-not $this.ProcessProfiles.ContainsKey($appLower)) {
            $this.ProcessProfiles[$appLower] = @{
                AvgCPU = $cpu
                MaxCPU = $cpu
                AvgRAM = $ram
                MaxRAM = $ram
                Priority = "Normal"
                CanThrottle = $null  # null = nie wiemy jeszcze
                Sessions = 1
                LastSeen = [DateTime]::Now
                Category = "Unknown"
            }
        } else {
            $profile = $this.ProcessProfiles[$appLower]
            $sessions = $profile.Sessions + 1
            $alpha = 1.0 / [Math]::Min(50, $sessions)
            
            # Średnie kroczące
            $profile.AvgCPU = ($profile.AvgCPU * (1 - $alpha)) + ($cpu * $alpha)
            $profile.AvgRAM = ($profile.AvgRAM * (1 - $alpha)) + ($ram * $alpha)
            
            # Maksima
            if ($cpu -gt $profile.MaxCPU) { $profile.MaxCPU = $cpu }
            if ($ram -gt $profile.MaxRAM) { $profile.MaxRAM = $ram }
            
            $profile.Sessions = $sessions
            $profile.LastSeen = [DateTime]::Now
            
            # Klasyfikacja po zebraniu danych
            if ($sessions -gt 10) {
                $profile.Category = $this.ClassifyProcess($profile)
                $profile.CanThrottle = $this.CanSafelyThrottle($profile)
                
                # Ustal priorytet
                if ($profile.CanThrottle) {
                    $profile.Priority = "BelowNormal"
                } elseif ($profile.Category -eq "Gaming" -or $profile.Category -eq "Rendering") {
                    $profile.Priority = "AboveNormal"
                } else {
                    $profile.Priority = "Normal"
                }
            }
        }
        
        $this.TotalLearnings++
        $this.LastLearnTime = [DateTime]::Now
        try {
            $entry = @{ Timestamp = (Get-Date).ToString('o'); Source='ProcessAI'; Event='Learn'; Process=$appLower; AvgCPU=[double]$cpu; AvgRAM=[double]$ram; Sessions=$this.ProcessProfiles[$appLower].Sessions }
            Append-AILearningEntry $entry
        } catch {}
    }
    
    # Klasyfikacja procesu na podstawie użycia zasobów
    [string] ClassifyProcess([hashtable]$profile) {
        $avgCPU = $profile.AvgCPU
        $maxCPU = $profile.MaxCPU
        $avgRAM = $profile.AvgRAM
        
        # Wysokie CPU i RAM = Rendering/Gaming
        if ($avgCPU -gt 50 -and $avgRAM -gt 2000) {
            return "Rendering"
        }
        # Wysokie CPU, niskie RAM = Gaming
        elseif ($avgCPU -gt 40 -and $avgRAM -lt 2000) {
            return "Gaming"
        }
        # Niskie CPU, wysokie RAM = Browser/Communication
        elseif ($avgCPU -lt 20 -and $avgRAM -gt 500) {
            return "Browser"
        }
        # Średnie użycie = Work
        elseif ($avgCPU -gt 10 -and $avgCPU -lt 40) {
            return "Work"
        }
        # Niskie użycie = Background
        else {
            return "Background"
        }
    }
    
    # Czy można bezpiecznie throttlować proces?
    [bool] CanSafelyThrottle([hashtable]$profile) {
        # Background procesy można throttlować
        if ($profile.Category -eq "Background") { return $true }
        
        # Browser można throttlować gdy nie jest w foreground
        if ($profile.Category -eq "Browser" -and $profile.AvgCPU -lt 30) { return $true }
        
        # Gaming/Rendering NIGDY nie throttluj
        if ($profile.Category -eq "Gaming" -or $profile.Category -eq "Rendering") { return $false }
        
        # Średnie CPU można throttlować jeśli nie w foreground
        if ($profile.AvgCPU -lt 40) { return $true }
        
        return $false
    }
    
    # Rekomendacje dla ProBalance
    [hashtable] GetThrottleRecommendations([string]$currentForeground) {
        $recommendations = @{
            SafeToThrottle = @()
            HighPriority = @()
            SystemProtected = @()
            Confidence = 0.0
        }
        
        $foregroundLower = if ($currentForeground) { $currentForeground.ToLower() } else { "" }
        
        # Procesy bezpieczne do throttlowania
        foreach ($proc in $this.ProcessProfiles.Keys) {
            $profile = $this.ProcessProfiles[$proc]
            
            # - V40: OCHRONA SYSTEM PROCESSES - NIGDY NIE THROTTLE!
            if ($this.SystemProcesses.ContainsKey($proc)) {
                $recommendations.SystemProtected += $proc
                continue
            }
            
            # Nie throttluj aktywnej aplikacji
            if ($proc -eq $foregroundLower) { continue }
            
            # Sprawdź czy można throttlować
            if ($profile.CanThrottle -eq $true -or $this.SafeToThrottle.ContainsKey($proc)) {
                $recommendations.SafeToThrottle += $proc
            }
        }
        
        # Procesy wysokiego priorytetu
        foreach ($proc in $this.HighPriorityApps.Keys) {
            if ($foregroundLower -eq $proc.ToLower()) {
                $recommendations.HighPriority += $proc
            }
        }
        
        # Confidence based on learned data
        $learnedCount = ($this.ProcessProfiles.Values | Where-Object { $_.Sessions -gt 10 }).Count
        $recommendations.Confidence = [Math]::Min(0.9, $learnedCount / 20.0)
        
        return $recommendations
    }
    
    [string] GetStatus() {
        $learned = ($this.ProcessProfiles.Values | Where-Object { $_.Sessions -gt 10 }).Count
        $total = $this.ProcessProfiles.Count
        return "Learned:$learned/$total Throttles:$($this.TotalThrottles)"
    }
    
    [void] SaveState([string]$dir) {
        try {
            $state = @{
                ProcessProfiles = @{}
                ThrottleHistory = @{}
                TotalLearnings = $this.TotalLearnings
                TotalThrottles = $this.TotalThrottles
                LastSaved = (Get-Date).ToString("o")
            }
            
            foreach ($key in $this.ProcessProfiles.Keys) {
                $state.ProcessProfiles[$key] = $this.ProcessProfiles[$key]
            }
            foreach ($key in $this.ThrottleHistory.Keys) {
                $state.ThrottleHistory[$key] = $this.ThrottleHistory[$key]
            }
            
            $path = Join-Path $dir "ProcessAI.json"
            $json = $state | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch {
            try { "$((Get-Date).ToString('o')) - ProcessAI.SaveState ERROR: $_" | Out-File -FilePath 'C:\CPUManager\ErrorLog.txt' -Append -Encoding utf8 } catch { }
        }
    }
    
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "ProcessAI.json"
            if (Test-Path $path) {
                $state = Get-Content $path -Raw | ConvertFrom-Json
                
                if ($state.ProcessProfiles) {
                    $state.ProcessProfiles.PSObject.Properties | ForEach-Object {
                        $this.ProcessProfiles[$_.Name] = @{
                            AvgCPU = $_.Value.AvgCPU
                            MaxCPU = $_.Value.MaxCPU
                            AvgRAM = $_.Value.AvgRAM
                            MaxRAM = $_.Value.MaxRAM
                            Priority = $_.Value.Priority
                            CanThrottle = $_.Value.CanThrottle
                            Sessions = $_.Value.Sessions
                            Category = $_.Value.Category
                        }
                    }
                }
                
                if ($state.TotalLearnings) { $this.TotalLearnings = $state.TotalLearnings }
                if ($state.TotalThrottles) { $this.TotalThrottles = $state.TotalThrottles }
            }
        } catch { }
    }
}
# V40.2: GPUAI - Inteligentne zarządzanie GPU (iGPU/dGPU switching + power control)
# Obsługuje: Intel iGPU, AMD APU (Vega/RDNA), NVIDIA dGPU, AMD dGPU (RX), konfiguracje hybrid
# V40.4: DODANO Q-LEARNING dla decyzji GPU (nie tylko EMA!)
class GPUAI {
    [bool] $HasiGPU = $false
    [bool] $HasdGPU = $false
    [string] $iGPUName = ""
    [string] $dGPUName = ""
    [string] $dGPUVendor = ""  # NVIDIA/AMD
    [string] $iGPUVendor = ""  # Intel/AMD (APU)
    [string] $CurrentMode = "Auto"  # Auto/iGPU-Only/dGPU-Only
    [int] $TotalSwitches = 0
    [int] $TotalLearnings = 0
    [datetime] $LastSwitch
    [datetime] $LastLearning
    [hashtable] $AppGPUProfiles = @{}  # app -> GPU profile z uczeniem
    [hashtable] $GPULoadHistory = @{}  # Ostatnie pomiary dla uczenia
    [string] $SystemType = "Unknown"   # SingleGPU/Hybrid/DedicatedOnly/IntegratedOnly
    
    # === Q-LEARNING dla GPU ===
    [hashtable] $QTable = @{}           # State -> { Turbo, Balanced, Silent } Q-values
    [double] $LearningRate = 0.15       # Alpha - szybkość uczenia
    [double] $DiscountFactor = 0.9      # Gamma - waga przyszłych nagród
    [double] $ExplorationRate = 0.10    # Epsilon - eksploracja vs eksploatacja
    [string] $LastState = ""
    [string] $LastAction = ""
    [double] $LastReward = 0.0
    [double] $CumulativeReward = 0.0
    [int] $TotalQUpdates = 0
    
    GPUAI([bool]$hasiGPU, [bool]$hasdGPU, [string]$iGPUName, [string]$dGPUName, [string]$dGPUVendor) {
        $this.HasiGPU = $hasiGPU
        $this.HasdGPU = $hasdGPU
        $this.iGPUName = $iGPUName
        $this.dGPUName = $dGPUName
        $this.dGPUVendor = $dGPUVendor
        $this.LastSwitch = [DateTime]::Now
        $this.LastLearning = [DateTime]::Now
        $this.AppGPUProfiles = @{}
        $this.GPULoadHistory = @{}
        
        # === Q-LEARNING INIT ===
        $this.QTable = @{}
        $this.LastState = ""
        $this.LastAction = ""
        $this.LastReward = 0.0
        $this.CumulativeReward = 0.0
        $this.TotalQUpdates = 0
        
        # Wykryj typ iGPU vendor
        if ($iGPUName -match "Intel") { $this.iGPUVendor = "Intel" }
        elseif ($iGPUName -match "AMD|Radeon|Vega") { $this.iGPUVendor = "AMD" }
        
        # Określ typ systemu
        if ($hasiGPU -and $hasdGPU) { $this.SystemType = "Hybrid" }
        elseif ($hasdGPU -and -not $hasiGPU) { $this.SystemType = "DedicatedOnly" }
        elseif ($hasiGPU -and -not $hasdGPU) { $this.SystemType = "IntegratedOnly" }
        else { $this.SystemType = "Unknown" }
        
        # V40 FIX: Usunieto LoadState z konstruktora - wywoływany jest później w Main()
        # $this.LoadState($Script:ConfigDir) - powodowało podwójne ładowanie
    }
    
    # === Q-LEARNING METHODS ===
    
    # Dyskretyzacja stanu GPU dla Q-Learning
    [string] DiscretizeGPUState([double]$gpuLoad, [string]$activeGPU, [double]$cpuLoad, [double]$temp, [string]$appCategory) {
        # GPU Load bins: 0-20=L, 20-50=M, 50-80=H, 80+=X
        $gpuBin = if ($gpuLoad -lt 20) { "L" } elseif ($gpuLoad -lt 50) { "M" } elseif ($gpuLoad -lt 80) { "H" } else { "X" }
        # Active GPU: i=iGPU, d=dGPU, a=Auto
        $gpuType = switch ($activeGPU) { "iGPU" { "i" } "dGPU" { "d" } default { "a" } }
        # CPU Load bins: 0-30=L, 30-60=M, 60+=H
        $cpuBin = if ($cpuLoad -lt 30) { "L" } elseif ($cpuLoad -lt 60) { "M" } else { "H" }
        # Temp bins: <60=C, 60-80=W, 80+=H
        $tempBin = if ($temp -lt 60) { "C" } elseif ($temp -lt 80) { "W" } else { "H" }
        # App category: X=Extreme, G=Gaming/Heavy, R=Rendering, W=Work, I=Idle/Light
        $catBin = switch ($appCategory) { "Extreme" { "X" } "Heavy" { "G" } "Gaming" { "G" } "Rendering" { "R" } "Idle" { "I" } "Light" { "I" } default { "W" } }
        
        return "G$gpuBin-$gpuType-C$cpuBin-T$tempBin-$catBin"
    }
    
    # Inicjalizuj stan w QTable jeśli nie istnieje
    [void] InitQState([string]$state) {
        if (-not $this.QTable.ContainsKey($state)) {
            $this.QTable[$state] = @{ "Turbo" = 0.0; "Balanced" = 0.0; "Silent" = 0.0 }
        }
    }
    
    # Wybierz akcję na podstawie Q-Table (epsilon-greedy)
    [string] SelectQAction([string]$state) {
        $this.InitQState($state)
        
        # Eksploracja - losowa akcja
        if ((Get-Random -Minimum 0.0 -Maximum 1.0) -lt $this.ExplorationRate) {
            return @("Turbo", "Balanced", "Silent")[(Get-Random -Maximum 3)]
        }
        
        # Eksploatacja - najlepsza akcja z Q-Table
        # ZMIANA: Przy równych Q-values preferuj niższy tryb (efektywność energetyczna)
        $q = $this.QTable[$state]
        $best = "Silent"
        $bestV = $q["Silent"]
        if ($q["Balanced"] -gt $bestV) { $best = "Balanced"; $bestV = $q["Balanced"] }
        if ($q["Turbo"] -gt $bestV) { $best = "Turbo" }
        return $best
    }
    
    # Oblicz reward dla GPU (iGPU/dGPU aware)
    [double] CalcGPUReward([string]$action, [double]$gpuLoad, [string]$activeGPU, [double]$cpuLoad, [double]$temp, [bool]$isHeavyApp) {
        $reward = 0.0
        
        # === HIGH GPU LOAD (>60%) - bazuj na AKTUALNYM load, nie profilu ===
        if ($gpuLoad -gt 60) {
            switch ($action) {
                "Turbo" { 
                    $reward += 3.0
                    if ($activeGPU -eq "dGPU") { $reward += 1.5 }
                }
                "Balanced" { $reward += 0.5 }
                "Silent" { $reward -= 3.0 }
            }
        }
        # === LOW GPU LOAD (<20%) - preferuj Silent ===
        elseif ($gpuLoad -lt 20 -and $cpuLoad -lt 30) {
            switch ($action) {
                "Silent" { 
                    $reward += 3.0
                    if ($activeGPU -eq "iGPU") { $reward += 1.5 }
                }
                "Balanced" { $reward += 1.5 }
                "Turbo" { $reward -= 2.0 }
            }
        }
        # === MEDIUM GPU LOAD (20-60%) ===
        else {
            switch ($action) {
                "Balanced" { $reward += 2.0 }
                "Turbo" { if ($gpuLoad -gt 40) { $reward += 1.0 } else { $reward -= 0.5 } }
                "Silent" { if ($gpuLoad -lt 30) { $reward += 1.0 } else { $reward -= 1.0 } }
            }
        }
        
        # === THERMAL PENALTY ===
        if ($temp -gt 85) {
            switch ($action) {
                "Turbo" { $reward -= 2.0 }
                "Silent" { $reward += 1.0 }
            }
        } elseif ($temp -lt 55) {
            if ($action -eq "Turbo" -and $gpuLoad -gt 30) { $reward += 0.5 }
        }
        
        # === HYBRID SYSTEM BONUS ===
        if ($this.SystemType -eq "Hybrid") {
            if ($activeGPU -eq "dGPU" -and $gpuLoad -gt 50 -and $action -eq "Turbo") {
                $reward += 1.0
            }
            if ($activeGPU -eq "iGPU" -and $gpuLoad -lt 25 -and $action -eq "Silent") {
                $reward += 1.0
            }
        }
        
        return $reward
    }
    
    # Aktualizuj Q-Table (Bellman equation)
    [void] UpdateQ([string]$state, [string]$action, [double]$reward, [string]$nextState) {
        $this.InitQState($state)
        $this.InitQState($nextState)
        
        # Q(s,a) = Q(s,a) + α * (reward + γ * max(Q(s',a')) - Q(s,a))
        $currentQ = $this.QTable[$state][$action]
        $maxNextQ = [Math]::Max([Math]::Max($this.QTable[$nextState]["Turbo"], $this.QTable[$nextState]["Balanced"]), $this.QTable[$nextState]["Silent"])
        
        $newQ = $currentQ + $this.LearningRate * ($reward + $this.DiscountFactor * $maxNextQ - $currentQ)
        $this.QTable[$state][$action] = $newQ
        
        $this.TotalQUpdates++
        $this.CumulativeReward += $reward
        $this.LastReward = $reward
        
        # Decay exploration rate (z czasem mniej eksploracji)
        $this.ExplorationRate = [Math]::Max(0.02, $this.ExplorationRate * 0.9995)
        
        $this.LastState = $state
        $this.LastAction = $action
    }
    
    # Rekomendacja GPU na podstawie trybu AI
    [hashtable] GetGPURecommendation([string]$mode, [string]$currentApp, [double]$cpuLoad) {
        $recommendation = @{
            PreferredGPU = "Auto"
            Reason = ""
            PowerLimit = 100
            ShouldSwitch = $false
            GPUType = $this.SystemType
        }
        
        # System z jednym GPU - brak wyboru, ale nadal ucz się zachowań
        if ($this.SystemType -eq "DedicatedOnly") {
            $recommendation.PreferredGPU = "dGPU"
            $recommendation.Reason = "Single GPU: $($this.dGPUName)"
            # Dostosuj PowerLimit na podstawie trybu
            $recommendation.PowerLimit = switch ($mode) {
                "Silent" { 70 }
                "Turbo" { 100 }
                default { 85 }
            }
            return $recommendation
        }
        if ($this.SystemType -eq "IntegratedOnly") {
            $recommendation.PreferredGPU = "iGPU"
            $recommendation.Reason = "Single GPU: $($this.iGPUName)"
            $recommendation.PowerLimit = 100  # iGPU zawsze na max
            return $recommendation
        }
        
        # HYBRID: Sprawdź najpierw nauczone preferencje aplikacji
        $appLower = if ($currentApp) { $currentApp.ToLower() } else { "" }
        if ($appLower -and $this.AppGPUProfiles.ContainsKey($appLower)) {
            $appPref = $this.AppGPUProfiles[$appLower]
            # Użyj nauczonych preferencji jeśli mamy wystarczająco danych
            if ($appPref.Sessions -ge 3 -and $appPref.PreferredGPU -ne "Auto") {
                $recommendation.PreferredGPU = $appPref.PreferredGPU
                $recommendation.Reason = "AI Learned: $currentApp -> $($appPref.PreferredGPU) (avg:$([Math]::Round($appPref.AvgGPULoad))% max:$([Math]::Round($appPref.MaxGPULoad))%)"
                $recommendation.PowerLimit = if ($appPref.PreferredGPU -eq "dGPU") { 100 } else { 80 }
                return $recommendation
            }
        }
        
        # Domyślna logika na podstawie trybu AI
        switch ($mode) {
            "Silent" {
                $recommendation.PreferredGPU = "iGPU"
                $recommendation.PowerLimit = 60
                $recommendation.Reason = "Silent: prefer iGPU (battery/quiet)"
                $recommendation.ShouldSwitch = ($this.CurrentMode -ne "iGPU-Only")
            }
            "Turbo" {
                $recommendation.PreferredGPU = "dGPU"
                $recommendation.PowerLimit = 100
                $recommendation.Reason = "Turbo: force dGPU (max performance)"
                $recommendation.ShouldSwitch = ($this.CurrentMode -ne "dGPU-Only")
            }
            default {
                $recommendation.PreferredGPU = "Auto"
                $recommendation.PowerLimit = 80
                $recommendation.Reason = "Balanced: Windows Hybrid Graphics"
                $recommendation.ShouldSwitch = ($this.CurrentMode -ne "Auto")
            }
        }
        
        return $recommendation
    }
    
    # V40.2: Rozszerzone uczenie się GPU - działa dla WSZYSTKICH konfiguracji
    [void] Learn([string]$app, [double]$gpuLoad, [string]$activeGPU, [double]$cpuLoad, [double]$temp) {
        if ([string]::IsNullOrWhiteSpace($app)) { return }
        if ($gpuLoad -lt 1) { return }  # Ignoruj zerowe obciążenie
        
        $appLower = $app.ToLower()
        $now = [DateTime]::Now
        
        # Inicjalizuj profil jeśli nowy
        if (-not $this.AppGPUProfiles.ContainsKey($appLower)) {
            $this.AppGPUProfiles[$appLower] = @{
                PreferredGPU = "Auto"
                AvgGPULoad = $gpuLoad
                MaxGPULoad = $gpuLoad
                MinGPULoad = $gpuLoad
                AvgCPULoad = $cpuLoad
                AvgTemp = $temp
                Sessions = 1
                Samples = 1
                LastSeen = $now
                FirstSeen = $now
                ActiveGPUHistory = @{ "dGPU" = 0; "iGPU" = 0; "Auto" = 0; "Unknown" = 0 }
                GPULoadBuckets = @{ "Low" = 0; "Medium" = 0; "High" = 0; "Extreme" = 0 }
                NeedsHighPerf = $false
                IsLightApp = $false
            }
        }
        
        $profile = $this.AppGPUProfiles[$appLower]
        
        # Aktualizuj statystyki
        $alpha = 0.15  # Współczynnik uczenia
        $profile.AvgGPULoad = ($profile.AvgGPULoad * (1 - $alpha)) + ($gpuLoad * $alpha)
        $profile.MaxGPULoad = [Math]::Max($profile.MaxGPULoad, $gpuLoad)
        $profile.MinGPULoad = [Math]::Min($profile.MinGPULoad, $gpuLoad)
        $profile.AvgCPULoad = ($profile.AvgCPULoad * (1 - $alpha)) + ($cpuLoad * $alpha)
        $profile.AvgTemp = ($profile.AvgTemp * (1 - $alpha)) + ($temp * $alpha)
        $profile.Samples++
        $profile.LastSeen = $now
        
        # Śledź który GPU był aktywny
        if ($profile.ActiveGPUHistory.ContainsKey($activeGPU)) {
            $profile.ActiveGPUHistory[$activeGPU]++
        }
        
        # Kategoryzuj obciążenie GPU
        if ($gpuLoad -lt 20) { $profile.GPULoadBuckets["Low"]++ }
        elseif ($gpuLoad -lt 50) { $profile.GPULoadBuckets["Medium"]++ }
        elseif ($gpuLoad -lt 80) { $profile.GPULoadBuckets["High"]++ }
        else { $profile.GPULoadBuckets["Extreme"]++ }
        
        # Nowa sesja jeśli minęło >5 min od ostatniego widzenia
        if (($now - $profile.LastSeen).TotalMinutes -gt 5) {
            $profile.Sessions++
        }
        
        # UCZENIE: Klasyfikuj aplikację po zebraniu wystarczającej ilości danych
        if ($profile.Samples -ge 10) {
            $totalBuckets = $profile.GPULoadBuckets["Low"] + $profile.GPULoadBuckets["Medium"] + $profile.GPULoadBuckets["High"] + $profile.GPULoadBuckets["Extreme"]
            
            if ($totalBuckets -gt 0) {
                $highPercent = (($profile.GPULoadBuckets["High"] + $profile.GPULoadBuckets["Extreme"]) / $totalBuckets) * 100
                $lowPercent = ($profile.GPULoadBuckets["Low"] / $totalBuckets) * 100
                
                # Aplikacja potrzebuje wysokiej wydajności GPU
                if ($highPercent -gt 40 -or $profile.MaxGPULoad -gt 70 -or $profile.AvgGPULoad -gt 45) {
                    $profile.NeedsHighPerf = $true
                    $profile.IsLightApp = $false
                    # Dla systemu Hybrid: preferuj dGPU
                    if ($this.SystemType -eq "Hybrid") {
                        $profile.PreferredGPU = "dGPU"
                    }
                }
                # Lekka aplikacja - wystarczy iGPU
                elseif ($lowPercent -gt 70 -and $profile.AvgGPULoad -lt 15 -and $profile.MaxGPULoad -lt 30) {
                    $profile.IsLightApp = $true
                    $profile.NeedsHighPerf = $false
                    # Dla systemu Hybrid: preferuj iGPU
                    if ($this.SystemType -eq "Hybrid") {
                        $profile.PreferredGPU = "iGPU"
                    }
                }
                # Średnie użycie - Auto
                else {
                    $profile.PreferredGPU = "Auto"
                }
            }
        }
        
        # === V40.4: Q-LEARNING UPDATE ===
        # Kategoria: GPU+CPU combined (nie tylko GPU sam)
        $appCategory = "Light"
        if ($gpuLoad -gt 85) {
            $appCategory = "Extreme"  # GPU maxed out → potrzebuje max power budget
        } elseif ($gpuLoad -gt 60) {
            $appCategory = if ($cpuLoad -gt 40) { "Heavy" } else { "Rendering" }
        } elseif ($gpuLoad -gt 30) {
            $appCategory = "Work"
        } elseif ($cpuLoad -gt 60) {
            $appCategory = "Heavy"  # CPU-heavy, GPU idle (kompilacja/encoding)
        } elseif ($gpuLoad -lt 10 -and $cpuLoad -lt 15) {
            $appCategory = "Idle"
        }
        
        # Dyskretyzuj obecny stan
        $currentState = $this.DiscretizeGPUState($gpuLoad, $activeGPU, $cpuLoad, $temp, $appCategory)
        
        # Jeśli mamy poprzedni stan - aktualizuj Q-Table
        if ($this.LastState -and $this.LastAction) {
            $isHeavyApp = ($gpuLoad -gt 60)  # Bazuj tylko na AKTUALNYM GPU load
            $reward = $this.CalcGPUReward($this.LastAction, $gpuLoad, $activeGPU, $cpuLoad, $temp, $isHeavyApp)
            $this.UpdateQ($this.LastState, $this.LastAction, $reward, $currentState)
        }
        
        # Wybierz akcję dla obecnego stanu (do następnej iteracji)
        $this.LastAction = $this.SelectQAction($currentState)
        $this.LastState = $currentState
        
        $this.TotalLearnings++
        $this.LastLearning = $now
    }
    
    # Kompatybilność wsteczna - stara sygnatura
    [void] Learn([string]$app, [double]$gpuLoad, [string]$activeGPU) {
        $this.Learn($app, $gpuLoad, $activeGPU, 0, 50)
    }
    
    # V40.4: Pobierz rekomendowany tryb AI na podstawie Q-LEARNING + nauczonych danych GPU
    [string] GetRecommendedMode([string]$app, [double]$currentGPULoad) {
        if ([string]::IsNullOrWhiteSpace($app)) { return "Balanced" }
        
        # Określ kategorię na podstawie AKTUALNEGO GPU load
        $appCategory = if ($currentGPULoad -gt 60) { "Heavy" } elseif ($currentGPULoad -lt 20) { "Light" } else { "Work" }
        
        # Dyskretyzuj AKTUALNY stan (nie używaj starego LastState!)
        # Użyj uproszczonej wersji stanu bo nie mamy wszystkich parametrów
        $gpuBin = if ($currentGPULoad -lt 20) { "L" } elseif ($currentGPULoad -lt 50) { "M" } elseif ($currentGPULoad -lt 80) { "H" } else { "X" }
        $catBin = switch ($appCategory) { "Heavy" { "G" } "Light" { "I" } default { "W" } }
        
        # Szukaj pasującego stanu w Q-Table (z dowolnym GPU type i temp)
        $matchingStates = $this.QTable.Keys | Where-Object { $_ -match "^G$gpuBin-.*-$catBin$" }
        
        if ($matchingStates) {
            # Znajdź stan z najlepszymi Q-values
            $bestAction = "Silent"
            $bestQ = -999.0
            
            foreach ($state in $matchingStates) {
                $qValues = $this.QTable[$state]
                $maxQ = [Math]::Max([Math]::Max($qValues["Turbo"], $qValues["Balanced"]), $qValues["Silent"])
                
                if ($maxQ -gt $bestQ -and [Math]::Abs($maxQ) -gt 0.5) {
                    $bestQ = $maxQ
                    # Wybierz akcję z najwyższym Q dla tego stanu
                    if ($qValues["Silent"] -ge $qValues["Balanced"] -and $qValues["Silent"] -ge $qValues["Turbo"]) {
                        $bestAction = "Silent"
                    } elseif ($qValues["Balanced"] -ge $qValues["Turbo"]) {
                        $bestAction = "Balanced"
                    } else {
                        $bestAction = "Turbo"
                    }
                }
            }
            
            if ($bestQ -gt -999.0) {
                return $bestAction
            }
        }
        
        # === FALLBACK: Decyzja na podstawie AKTUALNEGO GPU load ===
        if ($currentGPULoad -gt 60) {
            return "Turbo"
        }
        if ($currentGPULoad -lt 20) {
            return "Silent"
        }
        return "Balanced"
    }
    
    [string] GetStatus() {
        $appsLearned = $this.AppGPUProfiles.Count
        $highPerfApps = ($this.AppGPUProfiles.Values | Where-Object { $_.NeedsHighPerf -eq $true }).Count
        $lightApps = ($this.AppGPUProfiles.Values | Where-Object { $_.IsLightApp -eq $true }).Count
        $qStates = $this.QTable.Count
        return "Type:$($this.SystemType) Apps:$appsLearned (Heavy:$highPerfApps Light:$lightApps) Q:$qStates Learns:$($this.TotalLearnings)"
    }
    
    [hashtable] GetLearningStats() {
        return @{
            SystemType = $this.SystemType
            HasiGPU = $this.HasiGPU
            HasdGPU = $this.HasdGPU
            iGPUName = $this.iGPUName
            iGPUVendor = $this.iGPUVendor
            dGPUName = $this.dGPUName
            dGPUVendor = $this.dGPUVendor
            TotalAppsLearned = $this.AppGPUProfiles.Count
            TotalLearnings = $this.TotalLearnings
            TotalQUpdates = $this.TotalQUpdates
            QTableStates = $this.QTable.Count
            LastReward = $this.LastReward
            CumulativeReward = $this.CumulativeReward
            ExplorationRate = $this.ExplorationRate
            HighPerfApps = ($this.AppGPUProfiles.Values | Where-Object { $_.NeedsHighPerf -eq $true }).Count
            LightApps = ($this.AppGPUProfiles.Values | Where-Object { $_.IsLightApp -eq $true }).Count
            LastLearning = $this.LastLearning
        }
    }
    
    [void] SaveState([string]$dir) {
        try {
            $state = @{
                AppGPUProfiles = $this.AppGPUProfiles
                TotalSwitches = $this.TotalSwitches
                TotalLearnings = $this.TotalLearnings
                CurrentMode = $this.CurrentMode
                SystemType = $this.SystemType
                # Hardware detection info - for CONFIGURATOR display
                HasiGPU = $this.HasiGPU
                HasdGPU = $this.HasdGPU
                iGPUName = $this.iGPUName
                iGPUVendor = $this.iGPUVendor
                dGPUName = $this.dGPUName
                dGPUVendor = $this.dGPUVendor
                PrimaryGPU = if ($this.HasdGPU) { "dGPU" } elseif ($this.HasiGPU) { "iGPU" } else { "None" }
                LastSaved = (Get-Date).ToString("o")
                LastLearning = $this.LastLearning.ToString("o")
                # V40.4: Q-Learning data
                QTable = $this.QTable
                TotalQUpdates = $this.TotalQUpdates
                CumulativeReward = $this.CumulativeReward
                LastReward = $this.LastReward
                ExplorationRate = $this.ExplorationRate
                LastState = $this.LastState
                LastAction = $this.LastAction
            }
            
            $path = Join-Path $dir "GPUAI.json"
            $json = $state | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch { }
    }
    
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "GPUAI.json"
            if (Test-Path $path) {
                $state = Get-Content $path -Raw | ConvertFrom-Json
                
                if ($state.AppGPUProfiles) {
                    foreach ($app in $state.AppGPUProfiles.PSObject.Properties) {
                        $v = $app.Value
                        $this.AppGPUProfiles[$app.Name] = @{
                            PreferredGPU = if ($v.PreferredGPU) { $v.PreferredGPU } else { "Auto" }
                            AvgGPULoad = if ($v.AvgGPULoad) { $v.AvgGPULoad } else { 0 }
                            MaxGPULoad = if ($v.MaxGPULoad) { $v.MaxGPULoad } else { 0 }
                            MinGPULoad = if ($v.MinGPULoad) { $v.MinGPULoad } else { 0 }
                            AvgCPULoad = if ($v.AvgCPULoad) { $v.AvgCPULoad } else { 0 }
                            AvgTemp = if ($v.AvgTemp) { $v.AvgTemp } else { 50 }
                            Sessions = if ($v.Sessions) { $v.Sessions } else { 1 }
                            Samples = if ($v.Samples) { $v.Samples } else { 1 }
                            LastSeen = if ($v.LastSeen) { $v.LastSeen } else { [DateTime]::Now }
                            FirstSeen = if ($v.FirstSeen) { $v.FirstSeen } else { [DateTime]::Now }
                            ActiveGPUHistory = if ($v.ActiveGPUHistory) { 
                                @{ 
                                    "dGPU" = if ($v.ActiveGPUHistory.dGPU) { $v.ActiveGPUHistory.dGPU } else { 0 }
                                    "iGPU" = if ($v.ActiveGPUHistory.iGPU) { $v.ActiveGPUHistory.iGPU } else { 0 }
                                    "Auto" = if ($v.ActiveGPUHistory.Auto) { $v.ActiveGPUHistory.Auto } else { 0 }
                                    "Unknown" = if ($v.ActiveGPUHistory.Unknown) { $v.ActiveGPUHistory.Unknown } else { 0 }
                                }
                            } else { @{ "dGPU" = 0; "iGPU" = 0; "Auto" = 0; "Unknown" = 0 } }
                            GPULoadBuckets = if ($v.GPULoadBuckets) {
                                @{
                                    "Low" = if ($v.GPULoadBuckets.Low) { $v.GPULoadBuckets.Low } else { 0 }
                                    "Medium" = if ($v.GPULoadBuckets.Medium) { $v.GPULoadBuckets.Medium } else { 0 }
                                    "High" = if ($v.GPULoadBuckets.High) { $v.GPULoadBuckets.High } else { 0 }
                                    "Extreme" = if ($v.GPULoadBuckets.Extreme) { $v.GPULoadBuckets.Extreme } else { 0 }
                                }
                            } else { @{ "Low" = 0; "Medium" = 0; "High" = 0; "Extreme" = 0 } }
                            NeedsHighPerf = if ($null -ne $v.NeedsHighPerf) { $v.NeedsHighPerf } else { $false }
                            IsLightApp = if ($null -ne $v.IsLightApp) { $v.IsLightApp } else { $false }
                        }
                    }
                }
                
                if ($state.TotalSwitches) { $this.TotalSwitches = $state.TotalSwitches }
                if ($state.TotalLearnings) { $this.TotalLearnings = $state.TotalLearnings }
                if ($state.CurrentMode) { $this.CurrentMode = $state.CurrentMode }
                
                # V40.3: Załaduj info o GPU (z poprzedniej sesji)
                if ($state.SystemType) { $this.SystemType = $state.SystemType }
                if ($null -ne $state.HasiGPU) { $this.HasiGPU = $state.HasiGPU }
                if ($null -ne $state.HasdGPU) { $this.HasdGPU = $state.HasdGPU }
                if ($state.iGPUName) { $this.iGPUName = $state.iGPUName }
                if ($state.iGPUVendor) { $this.iGPUVendor = $state.iGPUVendor }
                if ($state.dGPUName) { $this.dGPUName = $state.dGPUName }
                if ($state.dGPUVendor) { $this.dGPUVendor = $state.dGPUVendor }
                if ($state.LastLearning) { 
                    try { $this.LastLearning = [DateTime]::Parse($state.LastLearning) } catch { }
                }
                
                # V40.4: Załaduj Q-Learning data
                if ($state.QTable) {
                    $this.QTable = @{}
                    foreach ($s in $state.QTable.PSObject.Properties) {
                        $this.QTable[$s.Name] = @{
                            "Turbo" = if ($s.Value.Turbo) { [double]$s.Value.Turbo } else { 0.0 }
                            "Balanced" = if ($s.Value.Balanced) { [double]$s.Value.Balanced } else { 0.0 }
                            "Silent" = if ($s.Value.Silent) { [double]$s.Value.Silent } else { 0.0 }
                        }
                    }
                }
                if ($state.TotalQUpdates) { $this.TotalQUpdates = [int]$state.TotalQUpdates }
                if ($state.CumulativeReward) { $this.CumulativeReward = [double]$state.CumulativeReward }
                if ($state.LastReward) { $this.LastReward = [double]$state.LastReward }
                if ($state.ExplorationRate) { $this.ExplorationRate = [double]$state.ExplorationRate }
                if ($state.LastState) { $this.LastState = $state.LastState }
                if ($state.LastAction) { $this.LastAction = $state.LastAction }
            }
        } catch { }
    }
}
class NetworkOptimizer {
    [bool] $Initialized = $false
    [bool] $OptimizationsApplied = $false
    [string] $ConfigDir
    [string] $BackupFile
    [hashtable] $OriginalSettings
    [string] $CurrentMode = "Normal"  # Normal, Gaming, Browsing, Download
    [datetime] $LastModeChange
    [int] $TotalOptimizations = 0
    # Progi wykrywania
    [double] $HighDownloadThreshold = 5MB  # 5 MB/s = duzy download
    [double] $GamingPingThreshold = 50     # ms - jesli ping > 50 to optymalizuj
    # Status
    [bool] $DNSOptimized = $false
    [bool] $NagleDisabled = $false
    [bool] $TCPOptimized = $false
    [bool] $ThrottlingDisabled = $false
    NetworkOptimizer([string]$configDir) {
        $this.ConfigDir = $configDir
        $this.BackupFile = Join-Path $configDir "NetworkBackup.json"
        $this.OriginalSettings = @{}
        $this.LastModeChange = [DateTime]::Now
    }
    # #
    # JEDNORAZOWA INICJALIZACJA - Zapisuje backup i stosuje optymalizacje
    # #
    [void] Initialize() {
        if ($this.Initialized) { return }
        try {
            # Sprawdz czy backup istnieje (= juz optymalizowane)
            if (Test-Path $this.BackupFile) {
                $this.LoadBackup()
                $this.OptimizationsApplied = $true
                $this.Initialized = $true
                return
            }
            # Pierwsze uruchomienie - zapisz backup i zastosuj optymalizacje
            $this.BackupCurrentSettings()
            $this.ApplyOptimizations()
            $this.Initialized = $true
            $this.OptimizationsApplied = $true
            $this.TotalOptimizations++
        } catch {
            # Blad - nie stosuj optymalizacji
            $this.Initialized = $true
            $this.OptimizationsApplied = $false
        }
    }
    # #
    # BACKUP ORYGINALNYCH USTAWIEN
    # #
    [void] BackupCurrentSettings() {
        $backup = @{
            Timestamp = (Get-Date).ToString("o")
            DNS = @{}
            Registry = @{}
        }
        # Backup DNS dla kazdego aktywnego adaptera
        try {
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            foreach ($adapter in $adapters) {
                try {
                    $dns = Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
                    if ($dns) {
                        $backup.DNS[$adapter.Name] = @{
                            InterfaceIndex = $adapter.ifIndex
                            OriginalDNS = $dns.ServerAddresses
                        }
                    }
                } catch { }
            }
        } catch { }
        # Backup ustawien rejestru
        try {
            # Network Throttling Index
            $throttlePath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            if (Test-Path $throttlePath) {
                $val = Get-ItemProperty -Path $throttlePath -Name "NetworkThrottlingIndex" -ErrorAction SilentlyContinue
                if ($val) { $backup.Registry["NetworkThrottlingIndex"] = $val.NetworkThrottlingIndex }
            }
            # Nagle Algorithm (sprawdz wszystkie interfejsy)
            $tcpipPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
            if (Test-Path $tcpipPath) {
                $backup.Registry["NagleInterfaces"] = @{}
                Get-ChildItem $tcpipPath | ForEach-Object {
                    $ifPath = $_.PSPath
                    $tcpNoDelay = Get-ItemProperty -Path $ifPath -Name "TcpNoDelay" -ErrorAction SilentlyContinue
                    $tcpAck = Get-ItemProperty -Path $ifPath -Name "TcpAckFrequency" -ErrorAction SilentlyContinue
                    $backup.Registry["NagleInterfaces"][$_.PSChildName] = @{
                        TcpNoDelay = if ($tcpNoDelay) { $tcpNoDelay.TcpNoDelay } else { $null }
                        TcpAckFrequency = if ($tcpAck) { $tcpAck.TcpAckFrequency } else { $null }
                    }
                }
            }
        } catch { }
        $this.OriginalSettings = $backup
        # Zapisz do pliku
        try {
            $backup | ConvertTo-Json -Depth 5 | Set-Content $this.BackupFile -Encoding UTF8 -Force
        } catch { }
    }
    [void] LoadBackup() {
        try {
            if (Test-Path $this.BackupFile) {
                $this.OriginalSettings = Get-Content $this.BackupFile -Raw | ConvertFrom-Json -AsHashtable
            }
        } catch { }
    }
    # #
    # STOSOWANIE OPTYMALIZACJI
    # #
    [void] ApplyOptimizations() {
        # Podstawowe optymalizacje (kontrolowane przez $Script zmienne)
        if ($Script:NetworkOptimizeDNS) {
            # 1. DNS - Cloudflare (najszybszy publiczny DNS)
            $this.OptimizeDNS()
        }
        if ($Script:NetworkDisableNagle) {
            # 2. Wylacz Nagle Algorithm (nizszy ping)
            $this.DisableNagle()
        }
        if ($Script:NetworkOptimizeTCP) {
            # 3. TCP ACK Frequency = 1 (szybsze ACK)
            $this.OptimizeTCPAck()
            # 4. Wylacz Network Throttling (pelna przepustowosc)
            $this.DisableThrottling()
        }
        
        # ULTRA optymalizacje (kontrolowane przez $Script zmienne)
        if ($Script:NetworkMaximizeTCPBuffers) {
            # 5. ULTRA: Maksymalne bufory TCP/IP
            $this.MaximizeTCPBuffers()
        }
        if ($Script:NetworkEnableWindowScaling) {
            # 6. ULTRA: Optymalizuj TCP Window Scaling
            $this.OptimizeTCPWindowScaling()
        }
        if ($Script:NetworkEnableRSS) {
            # 7. ULTRA: RSS (Receive Side Scaling) dla multi-core
            $this.EnableRSS()
        }
        if ($Script:NetworkEnableLSO) {
            # 8. ULTRA: Large Send Offload (LSO) dla duzych transferow
            $this.EnableLSO()
        }
        if ($Script:NetworkDisableChimney) {
            # 9. ULTRA: Wylacz TCP Chimney Offload (problematyczny)
            $this.DisableTCPChimney()
        }
    }
    [void] OptimizeDNS() {
        try {
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            foreach ($adapter in $adapters) {
                try {
                    # Cloudflare Primary + Secondary
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @("1.1.1.1", "1.0.0.1") -ErrorAction SilentlyContinue
                } catch { }
            }
            $this.DNSOptimized = $true
            # Flush DNS cache
            try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
        } catch { }
    }
    [void] DisableNagle() {
        try {
            $tcpipPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
            if (Test-Path $tcpipPath) {
                Get-ChildItem $tcpipPath | ForEach-Object {
                    try {
                        # TcpNoDelay = 1 wylacza Nagle Algorithm
                        Set-ItemProperty -Path $_.PSPath -Name "TcpNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    } catch { }
                }
            }
            $this.NagleDisabled = $true
        } catch { }
    }
    [void] OptimizeTCPAck() {
        try {
            $tcpipPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
            if (Test-Path $tcpipPath) {
                Get-ChildItem $tcpipPath | ForEach-Object {
                    try {
                        # TcpAckFrequency = 1 = natychmiastowe ACK (zamiast czekania na 2 pakiety)
                        Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                    } catch { }
                }
            }
            $this.TCPOptimized = $true
        } catch { }
    }
    [void] DisableThrottling() {
        try {
            $throttlePath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            if (Test-Path $throttlePath) {
                # NetworkThrottlingIndex = ffffffff (hex) = wylaczony throttling
                Set-ItemProperty -Path $throttlePath -Name "NetworkThrottlingIndex" -Value 0xffffffff -Type DWord -Force -ErrorAction SilentlyContinue
            }
            $this.ThrottlingDisabled = $true
        } catch { }
    }
    # ULTRA: Maksymalne bufory TCP/IP dla przepustowości
    [void] MaximizeTCPBuffers() {
        try {
            $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            if (Test-Path $tcpParams) {
                # TcpWindowSize = 65535 (64KB) - maksymalny rozmiar okna TCP bez scaling
                Set-ItemProperty -Path $tcpParams -Name "TcpWindowSize" -Value 65535 -Type DWord -Force -ErrorAction SilentlyContinue
                # Tcp1323Opts = 3 (enable window scaling + timestamps)
                Set-ItemProperty -Path $tcpParams -Name "Tcp1323Opts" -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
                # DefaultTTL = 64 (standardowy TTL dla Internetu)
                Set-ItemProperty -Path $tcpParams -Name "DefaultTTL" -Value 64 -Type DWord -Force -ErrorAction SilentlyContinue
                # EnablePMTUDiscovery = 1 (wykrywaj MTU dla unikniecia fragmentacji)
                Set-ItemProperty -Path $tcpParams -Name "EnablePMTUDiscovery" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    # ULTRA: TCP Window Scaling dla wysokich przepustowości
    [void] OptimizeTCPWindowScaling() {
        try {
            $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            if (Test-Path $tcpParams) {
                # TcpWindowSize = 0 (auto-tuning - Windows 10/11 domyślnie dobre)
                # GlobalMaxTcpWindowSize = 16777216 (16MB - dla gigabitowych połączeń)
                Set-ItemProperty -Path $tcpParams -Name "GlobalMaxTcpWindowSize" -Value 16777216 -Type DWord -Force -ErrorAction SilentlyContinue
                # Tcp1323Opts = 3 (włącz window scaling + timestamps dla wysokich przepustowości)
                Set-ItemProperty -Path $tcpParams -Name "Tcp1323Opts" -Value 3 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    # ULTRA: RSS (Receive Side Scaling) dla multi-core CPU
    [void] EnableRSS() {
        try {
            # Włącz RSS dla wszystkich adapterów sieciowych
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            foreach ($adapter in $adapters) {
                try {
                    # Włącz RSS (Receive Side Scaling)
                    Set-NetAdapterRss -Name $adapter.Name -Enabled $true -ErrorAction SilentlyContinue
                    # Ustaw liczbę procesorów dla RSS (max dostępne)
                    Set-NetAdapterRss -Name $adapter.Name -BaseProcessorNumber 0 -MaxProcessors ([Environment]::ProcessorCount) -ErrorAction SilentlyContinue
                } catch { }
            }
        } catch { }
    }
    # ULTRA: LSO (Large Send Offload) dla dużych transferów
    [void] EnableLSO() {
        try {
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            foreach ($adapter in $adapters) {
                try {
                    # Włącz Large Send Offload v2 (IPv4)
                    Set-NetAdapterLso -Name $adapter.Name -IPv4Enabled $true -ErrorAction SilentlyContinue
                    # Włącz Large Send Offload v2 (IPv6)
                    Set-NetAdapterLso -Name $adapter.Name -IPv6Enabled $true -ErrorAction SilentlyContinue
                } catch { }
            }
        } catch { }
    }
    # ULTRA: Wyłącz TCP Chimney (może powodować problemy)
    [void] DisableTCPChimney() {
        try {
            # Wyłącz TCP Chimney Offload (często powoduje problemy z połączeniami)
            netsh int tcp set global chimney=disabled *> $null
            # Wyłącz TCP Offloading (dla stabilności)
            $adapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
            foreach ($adapter in $adapters) {
                try {
                    # Wyłącz TCP Offloading
                    Disable-NetAdapterChecksumOffload -Name $adapter.Name -ErrorAction SilentlyContinue
                } catch { }
            }
        } catch { }
    }
    # #
    # DYNAMICZNA OPTYMALIZACJA - wywolywana co iteracje
    # #
    [string] Update([string]$context, [double]$downloadSpeed, [double]$uploadSpeed, [bool]$isGaming) {
        if (-not $this.Initialized) { 
            $this.Initialize() 
        }
        $newMode = "Normal"
        # Wykryj tryb na podstawie kontekstu
        if ($isGaming -or $context -eq "Gaming") {
            $newMode = "Gaming"
        } elseif ($context -eq "Browser" -or $context -eq "Browsing") {
            $newMode = "Browsing"
        } elseif ($downloadSpeed -gt $this.HighDownloadThreshold) {
            $newMode = "Download"
        }
        # Zmien tryb jesli inny
        if ($newMode -ne $this.CurrentMode) {
            $this.SetMode($newMode)
        }
        return $this.CurrentMode
    }
    [void] SetMode([string]$mode) {
        $oldMode = $this.CurrentMode
        $this.CurrentMode = $mode
        $this.LastModeChange = [DateTime]::Now
        switch ($mode) {
            "Gaming" {
                # Maksymalna optymalizacja dla niskiego pingu
                $this.SetProcessPriority("High")
                $this.EnableQoSForGaming()
                # V40: Dodatkowa optymalizacja TCP dla Gaming
                $this.OptimizeForLowLatency()
            }
            "Browsing" {
                # Priorytet dla DNS i HTTP
                $this.SetProcessPriority("AboveNormal")
            }
            "Download" {
                # Maksymalna przepustowosc
                $this.SetProcessPriority("Normal")
                # V40: Optymalizacja dla wysokiej przepustowości
                $this.OptimizeForHighThroughput()
            }
            default {
                # Normal - standardowe ustawienia
                $this.SetProcessPriority("Normal")
            }
        }
        if ($oldMode -ne $mode) {
            $this.TotalOptimizations++
        }
    }
    # V40: Optymalizacja dla niskiego opóźnienia (Gaming)
    [void] OptimizeForLowLatency() {
        try {
            # Priorytet dla małych pakietów (gaming packets są małe)
            $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            if (Test-Path $tcpParams) {
                # DisableLargeMtu = 0 (pozwól na path MTU discovery)
                Set-ItemProperty -Path $tcpParams -Name "DisableLargeMtu" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
    # V40: Optymalizacja dla wysokiej przepustowości (Download)
    [void] OptimizeForHighThroughput() {
        try {
            # Zwiększ bufory dla dużych transferów
            $tcpParams = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters"
            if (Test-Path $tcpParams) {
                # TcpWindowSize = 65535 (maksymalny rozmiar dla nie-scaling)
                # Już ustawione w MaximizeTCPBuffers, ale potwierdzamy
            }
        } catch { }
    }
    [void] SetProcessPriority([string]$priority) {
        # Ustaw priorytet dla procesow sieciowych (przegladarki, gry)
        try {
            $netProcesses = @("chrome", "firefox", "msedge", "opera", "brave")
            $priorityClass = switch ($priority) {
                "High" { [System.Diagnostics.ProcessPriorityClass]::High }
                "AboveNormal" { [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
                default { [System.Diagnostics.ProcessPriorityClass]::Normal }
            }
            foreach ($procName in $netProcesses) {
                try {
                    $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
                    foreach ($p in $procs) {
                        try { $p.PriorityClass = $priorityClass } catch { }
                    }
                } catch { }
            }
        } catch { }
    }
    [void] EnableQoSForGaming() {
        # Dodatkowe optymalizacje dla gier
        # Flush DNS cache dla swiezych lookupow
        try { Clear-DnsClientCache -ErrorAction SilentlyContinue } catch { }
    }
    # #
    # PRZYWRACANIE ORYGINALNYCH USTAWIEN
    # #
    [void] RestoreOriginalSettings() {
        if (-not $this.OriginalSettings -or $this.OriginalSettings.Count -eq 0) {
            $this.LoadBackup()
        }
        if (-not $this.OriginalSettings) { return }
        try {
            # Przywroc DNS
            if ($this.OriginalSettings.DNS) {
                foreach ($adapterName in $this.OriginalSettings.DNS.Keys) {
                    try {
                        $info = $this.OriginalSettings.DNS[$adapterName]
                        if ($info.OriginalDNS -and $info.InterfaceIndex) {
                            Set-DnsClientServerAddress -InterfaceIndex $info.InterfaceIndex -ServerAddresses $info.OriginalDNS -ErrorAction SilentlyContinue
                        }
                    } catch { }
                }
            }
            # Przywroc rejestr
            if ($this.OriginalSettings.Registry) {
                # Network Throttling
                if ($null -ne $this.OriginalSettings.Registry.NetworkThrottlingIndex) {
                    $throttlePath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
                    Set-ItemProperty -Path $throttlePath -Name "NetworkThrottlingIndex" -Value $this.OriginalSettings.Registry.NetworkThrottlingIndex -Type DWord -Force -ErrorAction SilentlyContinue
                }
                # Nagle interfaces
                if ($this.OriginalSettings.Registry.NagleInterfaces) {
                    $tcpipPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
                    foreach ($ifName in $this.OriginalSettings.Registry.NagleInterfaces.Keys) {
                        try {
                            $ifPath = Join-Path $tcpipPath $ifName
                            $settings = $this.OriginalSettings.Registry.NagleInterfaces[$ifName]
                            if ($null -ne $settings.TcpNoDelay) {
                                Set-ItemProperty -Path $ifPath -Name "TcpNoDelay" -Value $settings.TcpNoDelay -Type DWord -Force -ErrorAction SilentlyContinue
                            }
                            if ($null -ne $settings.TcpAckFrequency) {
                                Set-ItemProperty -Path $ifPath -Name "TcpAckFrequency" -Value $settings.TcpAckFrequency -Type DWord -Force -ErrorAction SilentlyContinue
                            }
                        } catch { }
                    }
                }
            }
            $this.OptimizationsApplied = $false
        } catch { }
    }
    [void] Restore() {
        $this.RestoreOriginalSettings()
    }
    [void] RestoreDNS() {
        if (-not $this.OriginalSettings -or $this.OriginalSettings.Count -eq 0) {
            $this.LoadBackup()
        }
        if (-not $this.OriginalSettings) { return }
        try {
            if ($this.OriginalSettings.DNS) {
                foreach ($adapterName in $this.OriginalSettings.DNS.Keys) {
                    try {
                        $info = $this.OriginalSettings.DNS[$adapterName]
                        if ($info.OriginalDNS -and $info.InterfaceIndex) {
                            Set-DnsClientServerAddress -InterfaceIndex $info.InterfaceIndex -ServerAddresses $info.OriginalDNS -ErrorAction SilentlyContinue
                        }
                    } catch { }
                }
            }
            $this.DNSOptimized = $false
        } catch { }
    }
    # #
    # STATUS I ZAPIS
    # #
    [string] GetStatus() {
        $dns = if ($this.DNSOptimized) { "?" } else { "?" }
        $nagle = if ($this.NagleDisabled) { "?" } else { "?" }
        $tcp = if ($this.TCPOptimized) { "?" } else { "?" }
        $throttle = if ($this.ThrottlingDisabled) { "?" } else { "?" }
        return "Mode:$($this.CurrentMode) DNS:$dns Nagle:$nagle TCP:$tcp Throttle:$throttle"
    }
    [hashtable] GetDetailedStatus() {
        return @{
            Initialized = $this.Initialized
            OptimizationsApplied = $this.OptimizationsApplied
            CurrentMode = $this.CurrentMode
            DNSOptimized = $this.DNSOptimized
            NagleDisabled = $this.NagleDisabled
            TCPOptimized = $this.TCPOptimized
            ThrottlingDisabled = $this.ThrottlingDisabled
            TotalOptimizations = $this.TotalOptimizations
            LastModeChange = $this.LastModeChange
        }
    }
    [void] SaveState([string]$dir) {
        try {
            $state = @{
                CurrentMode = $this.CurrentMode
                TotalOptimizations = $this.TotalOptimizations
                DNSOptimized = $this.DNSOptimized
                NagleDisabled = $this.NagleDisabled
                TCPOptimized = $this.TCPOptimized
                ThrottlingDisabled = $this.ThrottlingDisabled
                LastSaved = (Get-Date).ToString("o")
            }
            $path = Join-Path $dir "NetworkOptimizer.json"
            $state | ConvertTo-Json -Depth 3 | Set-Content $path -Encoding UTF8 -Force
        } catch { }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "NetworkOptimizer.json"
            if (Test-Path $path) {
                $state = Get-Content $path -Raw | ConvertFrom-Json
                if ($state.TotalOptimizations) { $this.TotalOptimizations = $state.TotalOptimizations }
                if ($state.DNSOptimized) { $this.DNSOptimized = $state.DNSOptimized }
                if ($state.NagleDisabled) { $this.NagleDisabled = $state.NagleDisabled }
                if ($state.TCPOptimized) { $this.TCPOptimized = $state.TCPOptimized }
                if ($state.ThrottlingDisabled) { $this.ThrottlingDisabled = $state.ThrottlingDisabled }
            }
        } catch { }
    }
}
#  NETWORK AI - Uczenie sie wzorcow sieciowych
class NetworkAI {
    # Wzorce aplikacji sieciowych
    [hashtable] $AppNetworkProfiles      # app -> {Type, AvgDownload, AvgUpload, NeedsLowPing, Sessions}
    [hashtable] $HourlyNetworkPatterns   # hour -> {AvgDownload, AvgUpload, DominantType, Samples}
    [hashtable] $DayNetworkPatterns      # dayOfWeek -> {PeakHours, DominantType, Samples}
    # Q-Learning dla sieci
    [hashtable] $NetworkQTable           # state -> {action -> qValue}
    [double] $NetworkLearningRate = 0.15
    [double] $NetworkDiscountFactor = 0.9
    [double] $NetworkExploration = 0.2
    # Metryki skutecznosci
    [int] $TotalPredictions = 0
    [int] $CorrectPredictions = 0
    [int] $TotalOptimizations = 0
    [double] $AvgPingImprovement = 0
    [double] $AvgSpeedImprovement = 0
    # Historia do uczenia
    [System.Collections.Generic.List[hashtable]] $RecentNetworkSamples
    [int] $MaxSamples = 100
    # Ostatnie wartosci
    [string] $LastApp = ""
    [string] $LastPredictedMode = "Normal"
    [double] $LastDownloadSpeed = 0
    [double] $LastUploadSpeed = 0
    [double] $LastPing = 0
    [datetime] $LastUpdate
    # Kategorie aplikacji sieciowych (poczatkowa wiedza)
    [hashtable] $KnownNetworkApps
    NetworkAI() {
        $this.AppNetworkProfiles = @{}
        $this.HourlyNetworkPatterns = @{}
        $this.DayNetworkPatterns = @{}
        $this.NetworkQTable = @{}
        $this.RecentNetworkSamples = [System.Collections.Generic.List[hashtable]]::new()
        $this.LastUpdate = [DateTime]::Now
        # Inicjalizacja wzorcow godzinowych (0-23)
        for ($h = 0; $h -lt 24; $h++) {
            $this.HourlyNetworkPatterns[$h] = @{
                AvgDownload = 0.0
                AvgUpload = 0.0
                DominantType = "Normal"
                GamingProbability = 0.0
                DownloadProbability = 0.0
                Samples = 0
            }
        }
        # Inicjalizacja wzorcow dni tygodnia (0=Niedziela, 6=Sobota)
        for ($d = 0; $d -lt 7; $d++) {
            $this.DayNetworkPatterns[$d] = @{
                PeakDownloadHours = @()
                PeakGamingHours = @()
                DominantType = "Normal"
                Samples = 0
            }
        }
        # Wbudowana wiedza o aplikacjach sieciowych
        $this.KnownNetworkApps = @{
            #  Gry online - potrzebuja niskiego pingu
            "valorant" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "csgo" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "cs2" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "dota2" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "leagueclient" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "league of legends" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "fortnite" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "apex" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "r5apex" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "overwatch" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "cod" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "warzone" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "pubg" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "rocketleague" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "minecraft" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "Normal" }
            "gta5" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "gtav" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "battlefield" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "rainbow six" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "r6" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "wow" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "Normal" }
            "worldofwarcraft" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "Normal" }
            "ffxiv" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "Normal" }
            "destiny2" = @{ Type = "Gaming"; NeedsLowPing = $true; Priority = "High" }
            "steam" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Normal" }
            "steamwebhelper" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Normal" }
            "epicgameslauncher" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Normal" }
            "origin" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Normal" }
            "battle.net" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Normal" }
            # - Streaming - potrzebuje przepustowosci
            "spotify" = @{ Type = "Streaming"; NeedsLowPing = $false; Priority = "Normal" }
            "netflix" = @{ Type = "Streaming"; NeedsLowPing = $false; Priority = "Normal" }
            "vlc" = @{ Type = "Streaming"; NeedsLowPing = $false; Priority = "Normal" }
            "obs64" = @{ Type = "Streaming"; NeedsLowPing = $false; Priority = "High" }
            "obs" = @{ Type = "Streaming"; NeedsLowPing = $false; Priority = "High" }
            "streamlabs" = @{ Type = "Streaming"; NeedsLowPing = $false; Priority = "High" }
            "twitch" = @{ Type = "Streaming"; NeedsLowPing = $false; Priority = "Normal" }
            # - Przegladarki - kategoryzowane dynamicznie po aktualnym ruchu sieciowym
            "chrome" = @{ Type = "Normal"; NeedsLowPing = $false; Priority = "Normal" }
            "firefox" = @{ Type = "Normal"; NeedsLowPing = $false; Priority = "Normal" }
            "msedge" = @{ Type = "Normal"; NeedsLowPing = $false; Priority = "Normal" }
            "opera" = @{ Type = "Normal"; NeedsLowPing = $false; Priority = "Normal" }
            "brave" = @{ Type = "Normal"; NeedsLowPing = $false; Priority = "Normal" }
            # - Komunikatory - potrzebuja niskiego pingu dla glosu
            "discord" = @{ Type = "VoIP"; NeedsLowPing = $true; Priority = "High" }
            "teams" = @{ Type = "VoIP"; NeedsLowPing = $true; Priority = "High" }
            "zoom" = @{ Type = "VoIP"; NeedsLowPing = $true; Priority = "High" }
            "skype" = @{ Type = "VoIP"; NeedsLowPing = $true; Priority = "High" }
            "slack" = @{ Type = "VoIP"; NeedsLowPing = $true; Priority = "Normal" }
            "telegram" = @{ Type = "Messaging"; NeedsLowPing = $false; Priority = "Normal" }
            "whatsapp" = @{ Type = "Messaging"; NeedsLowPing = $false; Priority = "Normal" }
            # - Download managers
            "qbittorrent" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Low" }
            "utorrent" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Low" }
            "bittorrent" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Low" }
            "jdownloader" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Normal" }
            "idm" = @{ Type = "Download"; NeedsLowPing = $false; Priority = "Normal" }
        }
    }
    # #
    # GLOWNA METODA UPDATE - wywolywana co iteracje
    # #
    [hashtable] Update([string]$currentApp, [double]$downloadSpeed, [double]$uploadSpeed, [string]$currentContext, [bool]$isGaming) {
        $now = [DateTime]::Now
        $hour = $now.Hour
        $dayOfWeek = [int]$now.DayOfWeek
        $appLower = if ($currentApp) { $currentApp.ToLower() } else { "" }
        # Okresl typ aktywnosci sieciowej
        $networkType = $this.DetermineNetworkType($appLower, $downloadSpeed, $uploadSpeed, $isGaming)
        # Zaktualizuj wzorce aplikacji
        if (-not [string]::IsNullOrWhiteSpace($appLower)) {
            $this.UpdateAppProfile($appLower, $networkType, $downloadSpeed, $uploadSpeed)
        }
        # Zaktualizuj wzorce czasowe
        $this.UpdateTimePatterns($hour, $dayOfWeek, $networkType, $downloadSpeed, $uploadSpeed)
        # Q-Learning update
        $this.UpdateQLearning($networkType, $downloadSpeed, $uploadSpeed)
        # Zapisz sample do historii
        $this.RecordSample($appLower, $networkType, $downloadSpeed, $uploadSpeed, $hour, $dayOfWeek)
        # Przewiduj optymalny tryb sieci
        $predictedMode = $this.PredictOptimalMode($appLower, $hour, $dayOfWeek, $downloadSpeed, $isGaming)
        # Sprawdz skutecznosc poprzedniej predykcji
        if ($this.LastPredictedMode -ne "Normal" -and $this.LastApp -eq $appLower) {
            $this.EvaluatePrediction($predictedMode, $networkType)
        }
        $this.LastApp = $appLower
        $this.LastPredictedMode = $predictedMode
        $this.LastDownloadSpeed = $downloadSpeed
        $this.LastUploadSpeed = $uploadSpeed
        $this.LastUpdate = $now
        return @{
            PredictedMode = $predictedMode
            NetworkType = $networkType
            NeedsLowPing = ($networkType -eq "Gaming" -or $networkType -eq "VoIP")
            NeedsHighBandwidth = ($networkType -eq "Download" -or $networkType -eq "Streaming")
            Confidence = $this.GetPredictionConfidence($appLower, $hour)
            AppCategory = $this.GetAppCategory($appLower)
        }
    }
    # #
    # OKRESLANIE TYPU AKTYWNOSCI SIECIOWEJ
    # #
    [string] DetermineNetworkType([string]$app, [double]$download, [double]$upload, [bool]$isGaming) {
        # 1. Sprawdz wbudowana wiedze - TYLKO exact match
        if ($this.KnownNetworkApps.ContainsKey($app)) {
            return $this.KnownNetworkApps[$app].Type
        }
        # 2. Wnioskuj z kontekstu (PRZED learned profiles - świeże dane mają priorytet)
        if ($isGaming) { return "Gaming" }
        # 3. Wnioskuj z AKTUALNEJ prędkości (ważniejsze niż historyczne Type)
        $downloadMB = $download / 1MB
        $uploadMB = $upload / 1MB
        if ($downloadMB -gt 5) { return "Download" }
        if ($uploadMB -gt 2) { return "Streaming" }
        if ($downloadMB -gt 1 -or $uploadMB -gt 0.5) { return "Active" }
        # 4. Sprawdz AppCategoryPreferences (user/system kategorie)
        if ($Script:AppCategoryPreferences -and $Script:AppCategoryPreferences.Count -gt 0) {
            foreach ($key in $Script:AppCategoryPreferences.Keys) {
                $keyLower = $key.ToLower() -replace '\.exe$', ''
                if ($keyLower -eq $app) {
                    $pref = $Script:AppCategoryPreferences[$key]
                    if ($pref.Bias -ge 0.8) { return "Gaming" }
                    break
                }
            }
        }
        # 5. Sprawdz nauczone profile - ale TYLKO jeśli Type nie jest "Browser"/"Normal"
        # (nie pozwól na utknięcie w złej kategorii)
        if ($this.AppNetworkProfiles.ContainsKey($app)) {
            $profile = $this.AppNetworkProfiles[$app]
            if ($profile.Sessions -gt 5 -and $profile.Type -notin @("Browser", "Normal", "Unknown")) {
                return $profile.Type
            }
        }
        return "Normal"
    }
    # #
    # AKTUALIZACJA PROFILU APLIKACJI
    # #
    [void] UpdateAppProfile([string]$app, [string]$networkType, [double]$download, [double]$upload) {
        if ([string]::IsNullOrWhiteSpace($app)) { return }
        if (-not $this.AppNetworkProfiles.ContainsKey($app)) {
            $this.AppNetworkProfiles[$app] = @{
                Type = $networkType
                AvgDownload = $download
                AvgUpload = $upload
                MaxDownload = $download
                MaxUpload = $upload
                NeedsLowPing = ($networkType -eq "Gaming" -or $networkType -eq "VoIP")
                Sessions = 1
                LastSeen = [DateTime]::Now
            }
        } else {
            $profile = $this.AppNetworkProfiles[$app]
            $sessions = $profile.Sessions + 1
            # Srednia kroczaca
            $alpha = 1.0 / [Math]::Min(50, $sessions)
            $profile.AvgDownload = ($profile.AvgDownload * (1 - $alpha)) + ($download * $alpha)
            $profile.AvgUpload = ($profile.AvgUpload * (1 - $alpha)) + ($upload * $alpha)
            # Maksima
            if ($download -gt $profile.MaxDownload) { $profile.MaxDownload = $download }
            if ($upload -gt $profile.MaxUpload) { $profile.MaxUpload = $upload }
            # Aktualizuj typ na podstawie aktualnej aktywności
            # Nie pozwól na utknięcie w "Browser"/"Normal" gdy app robi coś innego
            if ($sessions -gt 3) {
                if ($networkType -ne "Normal" -and $networkType -ne "Browser") {
                    $profile.Type = $networkType
                    $profile.NeedsLowPing = ($networkType -eq "Gaming" -or $networkType -eq "VoIP")
                } elseif ($sessions -gt 20 -and $profile.Type -eq "Browser") {
                    # Jeśli "Browser" ale realne zachowanie to Normal — zaktualizuj
                    $profile.Type = $networkType
                }
            }
            $profile.Sessions = $sessions
            $profile.LastSeen = [DateTime]::Now
        }
    }
    # #
    # AKTUALIZACJA WZORCOW CZASOWYCH
    # #
    [void] UpdateTimePatterns([int]$hour, [int]$dayOfWeek, [string]$networkType, [double]$download, [double]$upload) {
        # Wzorce godzinowe
        $hourPattern = $this.HourlyNetworkPatterns[$hour]
        $samples = $hourPattern.Samples + 1
        $alpha = 1.0 / [Math]::Min(100, $samples)
        $hourPattern.AvgDownload = ($hourPattern.AvgDownload * (1 - $alpha)) + ($download * $alpha)
        $hourPattern.AvgUpload = ($hourPattern.AvgUpload * (1 - $alpha)) + ($upload * $alpha)
        # Aktualizuj prawdopodobienstwa
        if ($networkType -eq "Gaming") {
            $hourPattern.GamingProbability = ($hourPattern.GamingProbability * 0.95) + 0.05
        } else {
            $hourPattern.GamingProbability = $hourPattern.GamingProbability * 0.99
        }
        if ($networkType -eq "Download") {
            $hourPattern.DownloadProbability = ($hourPattern.DownloadProbability * 0.95) + 0.05
        } else {
            $hourPattern.DownloadProbability = $hourPattern.DownloadProbability * 0.99
        }
        if ($samples -gt 20) {
            if ($hourPattern.GamingProbability -gt 0.3) {
                $hourPattern.DominantType = "Gaming"
            } elseif ($hourPattern.DownloadProbability -gt 0.3) {
                $hourPattern.DominantType = "Download"
            } elseif ($hourPattern.AvgDownload -gt 1MB) {
                $hourPattern.DominantType = "Active"
            } else {
                $hourPattern.DominantType = "Normal"
            }
        }
        $hourPattern.Samples = $samples
        # Wzorce dnia tygodnia
        $dayPattern = $this.DayNetworkPatterns[$dayOfWeek]
        $dayPattern.Samples++
        # Sledz godziny szczytowe
        if ($download -gt 5MB -and $hour -notin $dayPattern.PeakDownloadHours) {
            $dayPattern.PeakDownloadHours += $hour
            $dayPattern.PeakDownloadHours = @($dayPattern.PeakDownloadHours | Select-Object -Unique | Sort-Object)
        }
        if ($networkType -eq "Gaming" -and $hour -notin $dayPattern.PeakGamingHours) {
            $dayPattern.PeakGamingHours += $hour
            $dayPattern.PeakGamingHours = @($dayPattern.PeakGamingHours | Select-Object -Unique | Sort-Object)
        }
    }
    # #
    # Q-LEARNING DLA OPTYMALIZACJI SIECI
    # #
    [void] UpdateQLearning([string]$networkType, [double]$download, [double]$upload) {
        # Stan: kombinacja typu i predkosci
        $downloadLevel = if ($download -gt 5MB) { "High" } elseif ($download -gt 1MB) { "Med" } else { "Low" }
        $state = "$networkType-$downloadLevel"
        # Akcje mozliwe
        $actions = @("Normal", "Gaming", "Download", "Streaming")
        # Inicjalizuj Q-wartosci jesli nowe
        if (-not $this.NetworkQTable.ContainsKey($state)) {
            $this.NetworkQTable[$state] = @{}
            foreach ($a in $actions) {
                $this.NetworkQTable[$state][$a] = 0.0
            }
        }
        # Oblicz nagrode na podstawie dopasowania
        $reward = 0.0
        $bestAction = $networkType
        if ($bestAction -eq "Active") { $bestAction = "Normal" }
        if ($bestAction -notin $actions) { $bestAction = "Normal" }
        # Nagroda za poprawne dopasowanie
        $currentAction = $this.LastPredictedMode
        if ($currentAction -eq $bestAction) {
            $reward = 1.0
        } elseif ($networkType -eq "Gaming" -and $currentAction -eq "Gaming") {
            $reward = 1.0  # Bonus za wykrycie gamingu
        } elseif ($networkType -eq "Download" -and $currentAction -eq "Download") {
            $reward = 0.8
        } else {
            $reward = -0.2
        }
        # Q-Learning update
        if ($this.NetworkQTable.ContainsKey($state) -and $this.NetworkQTable[$state].ContainsKey($currentAction)) {
            $oldQ = $this.NetworkQTable[$state][$currentAction]
            $maxNextQ = ($this.NetworkQTable[$state].Values | Measure-Object -Maximum).Maximum
            if (-not $maxNextQ) { $maxNextQ = 0 }
            $newQ = $oldQ + $this.NetworkLearningRate * ($reward + $this.NetworkDiscountFactor * $maxNextQ - $oldQ)
            $this.NetworkQTable[$state][$currentAction] = $newQ
        }
    }
    # #
    # PREDYKCJA OPTYMALNEGO TRYBU
    # #
    [string] PredictOptimalMode([string]$app, [int]$hour, [int]$dayOfWeek, [double]$currentDownload, [bool]$isGaming) {
        $this.TotalPredictions++
        # 1. Priorytet: wbudowana wiedza o aplikacji
        if ($this.KnownNetworkApps.ContainsKey($app)) {
            $knownType = $this.KnownNetworkApps[$app].Type
            if ($knownType -eq "Gaming" -or $knownType -eq "VoIP") {
                return "Gaming"
            } elseif ($knownType -eq "Download" -or $knownType -eq "Streaming") {
                return "Download"
            }
        }
        # 2. Nauczone profile aplikacji
        if ($this.AppNetworkProfiles.ContainsKey($app)) {
            $profile = $this.AppNetworkProfiles[$app]
            if ($profile.Sessions -gt 10 -and $profile.NeedsLowPing) {
                return "Gaming"
            } elseif ($profile.Sessions -gt 10 -and $profile.MaxDownload -gt 5MB) {
                return "Download"
            }
        }
        # 3. Kontekst gamingowy
        if ($isGaming) {
            return "Gaming"
        }
        # 4. Wzorce czasowe
        $hourPattern = $this.HourlyNetworkPatterns[$hour]
        if ($hourPattern.Samples -gt 30) {
            if ($hourPattern.GamingProbability -gt 0.4) {
                return "Gaming"
            } elseif ($hourPattern.DownloadProbability -gt 0.4) {
                return "Download"
            }
        }
        # 5. Aktualna predkosc
        if ($currentDownload -gt 5MB) {
            return "Download"
        }
        # 6. Q-Learning decision
        $downloadLevel = if ($currentDownload -gt 5MB) { "High" } elseif ($currentDownload -gt 1MB) { "Med" } else { "Low" }
        $state = "Normal-$downloadLevel"
        if ($this.NetworkQTable.ContainsKey($state)) {
            $qValues = $this.NetworkQTable[$state]
            $bestAction = "Normal"
            $bestQ = -999
            foreach ($action in $qValues.Keys) {
                if ($qValues[$action] -gt $bestQ) {
                    $bestQ = $qValues[$action]
                    $bestAction = $action
                }
            }
            if ($bestQ -gt 0.5) {
                return $bestAction
            }
        }
        return "Normal"
    }
    # #
    # POMOCNICZE
    # #
    [void] RecordSample([string]$app, [string]$type, [double]$download, [double]$upload, [int]$hour, [int]$day) {
        $sample = @{
            App = $app
            Type = $type
            Download = $download
            Upload = $upload
            Hour = $hour
            DayOfWeek = $day
            Timestamp = [DateTime]::Now
        }
        $this.RecentNetworkSamples.Add($sample)
        while ($this.RecentNetworkSamples.Count -gt $this.MaxSamples) {
            $this.RecentNetworkSamples.RemoveAt(0)
        }
    }
    [void] EvaluatePrediction([string]$predicted, [string]$actual) {
        if ($predicted -eq $actual -or 
            ($predicted -eq "Gaming" -and $actual -eq "VoIP") -or
            ($predicted -eq "Download" -and $actual -eq "Streaming")) {
            $this.CorrectPredictions++
        }
    }
    [double] GetPredictionConfidence([string]$app, [int]$hour) {
        $confidence = 0.5
        # Bonus za znana aplikacje
        if ($this.KnownNetworkApps.ContainsKey($app)) {
            $confidence += 0.3
        } elseif ($this.AppNetworkProfiles.ContainsKey($app)) {
            $sessions = $this.AppNetworkProfiles[$app].Sessions
            $confidence += [Math]::Min(0.25, $sessions / 100.0)
        }
        # Bonus za wzorce czasowe
        $hourPattern = $this.HourlyNetworkPatterns[$hour]
        if ($hourPattern.Samples -gt 50) {
            $confidence += 0.15
        }
        return [Math]::Min(0.95, $confidence)
    }
    [string] GetAppCategory([string]$app) {
        if ($this.KnownNetworkApps.ContainsKey($app)) {
            return $this.KnownNetworkApps[$app].Type
        }
        if ($this.AppNetworkProfiles.ContainsKey($app)) {
            return $this.AppNetworkProfiles[$app].Type
        }
        return "Unknown"
    }
    # #
    # TRAIN - Glowna metoda uczenia sie wzorcow z historii (wywolywana periodycznie)
    # #
    [void] Train() {
        # Ucz sie wzorcow z ostatnich sampli (co 60s)
        if ($this.RecentNetworkSamples.Count -lt 10) { return }
        
        # 1. Analiza wzorcow aplikacji - ktorе aplikacje wymagaja niskiego pingu
        $this.LearnAppPatterns()
        
        # 2. Analiza wzorcow czasowych - kiedy uzytkownik gra/pobiera/streamuje
        $this.LearnTimePatterns()
        
        # 3. Optymalizacja Q-Table - ucz sie optymalnych akcji dla stanow
        $this.OptimizeQTable()
        
        # 4. Cleanup starych sampli
        while ($this.RecentNetworkSamples.Count -gt $this.MaxSamples) {
            $this.RecentNetworkSamples.RemoveAt(0)
        }
    }
    [void] LearnAppPatterns() {
        # Ucz sie, ktore aplikacje potrzebuja optymalizacji sieci
        foreach ($app in $this.AppNetworkProfiles.Keys) {
            $profile = $this.AppNetworkProfiles[$app]
            
            # Jesli aplikacja ma duzo sesji, klasyfikuj ja
            if ($profile.Sessions -gt 10) {
                $avgDownloadMB = $profile.AvgDownload / 1MB
                $avgUploadMB = $profile.AvgUpload / 1MB
                
                # Heurystyki klasyfikacji
                if ($avgDownloadMB -gt 5 -and $avgUploadMB -lt 1) {
                    # Duzy download, maly upload = Download/Streaming
                    $profile.Type = if ($avgDownloadMB -gt 10) { "Download" } else { "Streaming" }
                    $profile.NeedsLowPing = $false
                }
                elseif ($avgUploadMB -gt 2) {
                    # Duzy upload = prawdopodobnie streaming wideo
                    $profile.Type = "Streaming"
                    $profile.NeedsLowPing = $false
                }
                elseif ($avgDownloadMB -lt 1 -and $avgUploadMB -lt 0.5) {
                    # Maly ruch = Gaming/VoIP/Browser
                    # Sprawdz czy to znana gra/VoIP
                    if ($this.KnownNetworkApps.ContainsKey($app)) {
                        $profile.Type = $this.KnownNetworkApps[$app].Type
                        $profile.NeedsLowPing = $this.KnownNetworkApps[$app].NeedsLowPing
                    }
                    else {
                        $profile.Type = "Browser"
                        $profile.NeedsLowPing = $false
                    }
                }
            }
        }
    }
    [void] LearnTimePatterns() {
        # Ucz sie, kiedy uzytkownik typowo gra, pobiera, streamuje
        $now = [DateTime]::Now
        
        # Analiza ostatnich sampli (ostatnie 5 minut)
        $recentSamples = $this.RecentNetworkSamples | Where-Object { 
            ($now - $_.Timestamp).TotalMinutes -lt 5 
        }
        
        if ($recentSamples.Count -lt 5) { return }
        
        # Statystyki aktywnosci
        $gamingSamples = @($recentSamples | Where-Object { $_.Type -eq "Gaming" -or $_.Type -eq "VoIP" })
        $downloadSamples = @($recentSamples | Where-Object { $_.Type -eq "Download" -or $_.Type -eq "Streaming" })
        
        $hour = $now.Hour
        $hourPattern = $this.HourlyNetworkPatterns[$hour]
        
        # Aktualizuj prawdopodobienstwa na podstawie aktywnosci
        if ($gamingSamples.Count -gt ($recentSamples.Count * 0.5)) {
            # Ponad polowa sampli to gaming - zwieksz prawdopodobienstwo
            $hourPattern.GamingProbability = [Math]::Min(0.9, $hourPattern.GamingProbability + 0.1)
        }
        if ($downloadSamples.Count -gt ($recentSamples.Count * 0.5)) {
            # Ponad polowa sampli to download - zwieksz prawdopodobienstwo
            $hourPattern.DownloadProbability = [Math]::Min(0.9, $hourPattern.DownloadProbability + 0.1)
        }
    }
    [void] OptimizeQTable() {
        # Regularyzacja Q-Table - zmniejsz wartosci, ktore nie sa uzywane
        $decay = 0.99
        
        foreach ($state in $this.NetworkQTable.Keys) {
            foreach ($action in $this.NetworkQTable[$state].Keys) {
                # Decay niewykorzystanych akcji
                $this.NetworkQTable[$state][$action] *= $decay
            }
        }
        
        # Ogranicz rozmiar Q-Table (jesli za duza)
        if ($this.NetworkQTable.Count -gt 100) {
            # Usun stany z najnizszymi wartosciami
            $sortedStates = $this.NetworkQTable.Keys | Sort-Object {
                ($this.NetworkQTable[$_].Values | Measure-Object -Maximum).Maximum
            }
            
            # Usun 20% najslabszych stanow
            $toRemove = [Math]::Floor($sortedStates.Count * 0.2)
            for ($i = 0; $i -lt $toRemove; $i++) {
                $this.NetworkQTable.Remove($sortedStates[$i])
            }
        }
    }
    [string] GetStatus() {
        $accuracy = if ($this.TotalPredictions -gt 0) { 
            [Math]::Round(($this.CorrectPredictions / $this.TotalPredictions) * 100, 1) 
        } else { 0 }
        $apps = $this.AppNetworkProfiles.Count
        return "Apps:$apps Acc:$accuracy% Pred:$($this.TotalPredictions)"
    }
    [hashtable] GetDetailedStatus() {
        return @{
            LearnedApps = $this.AppNetworkProfiles.Count
            TotalPredictions = $this.TotalPredictions
            CorrectPredictions = $this.CorrectPredictions
            Accuracy = if ($this.TotalPredictions -gt 0) { 
                [Math]::Round(($this.CorrectPredictions / $this.TotalPredictions) * 100, 1) 
            } else { 0 }
            QTableStates = $this.NetworkQTable.Count
            LastPredictedMode = $this.LastPredictedMode
        }
    }
    # #
    # ZAPIS I ODCZYT STANU
    # #
    [void] SaveState([string]$dir) {
        try {
            $state = @{
                AppNetworkProfiles = @{}
                HourlyNetworkPatterns = @{}
                DayNetworkPatterns = @{}
                NetworkQTable = @{}
                TotalPredictions = $this.TotalPredictions
                CorrectPredictions = $this.CorrectPredictions
                TotalOptimizations = $this.TotalOptimizations
                LastSaved = (Get-Date).ToString("o")
            }
            # Konwertuj hashtable na format serializowalny
            foreach ($key in $this.AppNetworkProfiles.Keys) {
                $state.AppNetworkProfiles[$key] = $this.AppNetworkProfiles[$key]
            }
            foreach ($key in $this.HourlyNetworkPatterns.Keys) {
                $state.HourlyNetworkPatterns[$key.ToString()] = $this.HourlyNetworkPatterns[$key]
            }
            foreach ($key in $this.DayNetworkPatterns.Keys) {
                $state.DayNetworkPatterns[$key.ToString()] = $this.DayNetworkPatterns[$key]
            }
            foreach ($key in $this.NetworkQTable.Keys) {
                $state.NetworkQTable[$key] = $this.NetworkQTable[$key]
            }
            $path = Join-Path $dir "NetworkAI.json"
            $json = $state | ConvertTo-Json -Depth 6
            [System.IO.File]::WriteAllText($path, $json, [System.Text.Encoding]::UTF8)
        } catch {
            try { "$((Get-Date).ToString('o')) - NetworkAI.SaveState ERROR: $_" | Out-File -FilePath 'C:\CPUManager\ErrorLog.txt' -Append -Encoding utf8 } catch { }
        }
    }
    [void] LoadState([string]$dir) {
        try {
            $path = Join-Path $dir "NetworkAI.json"
            if (Test-Path $path) {
                $state = Get-Content $path -Raw | ConvertFrom-Json
                # Odtworz profile aplikacji
                if ($state.AppNetworkProfiles) {
                    $state.AppNetworkProfiles.PSObject.Properties | ForEach-Object {
                        $loadedType = if ($_.Value.Type) { $_.Value.Type } else { "Normal" }
                        # FIX: "Browser" nie jest poprawną kategorią sieciową
                        # Przeglądarki to narzędzia - ich aktywność sieciowa to Download/Streaming/Active/Normal
                        # Reklasyfikuj "Browser" → "Normal" żeby DetermineNetworkType mógł ponownie ocenić
                        if ($loadedType -eq "Browser") { $loadedType = "Normal" }
                        $this.AppNetworkProfiles[$_.Name] = @{
                            Type = $loadedType
                            AvgDownload = $_.Value.AvgDownload
                            AvgUpload = $_.Value.AvgUpload
                            MaxDownload = $_.Value.MaxDownload
                            MaxUpload = $_.Value.MaxUpload
                            NeedsLowPing = $_.Value.NeedsLowPing
                            Sessions = $_.Value.Sessions
                        }
                    }
                }
                # Odtworz wzorce godzinowe
                if ($state.HourlyNetworkPatterns) {
                    for ($h = 0; $h -lt 24; $h++) {
                        $key = $h.ToString()
                        if ($state.HourlyNetworkPatterns.$key) {
                            $this.HourlyNetworkPatterns[$h] = @{
                                AvgDownload = $state.HourlyNetworkPatterns.$key.AvgDownload
                                AvgUpload = $state.HourlyNetworkPatterns.$key.AvgUpload
                                DominantType = $state.HourlyNetworkPatterns.$key.DominantType
                                GamingProbability = $state.HourlyNetworkPatterns.$key.GamingProbability
                                DownloadProbability = $state.HourlyNetworkPatterns.$key.DownloadProbability
                                Samples = $state.HourlyNetworkPatterns.$key.Samples
                            }
                        }
                    }
                }
                # Odtworz Q-Table
                if ($state.NetworkQTable) {
                    $state.NetworkQTable.PSObject.Properties | ForEach-Object {
                        $stateName = $_.Name  # v39 FIX
                        $this.NetworkQTable[$stateName] = @{}
                        $_.Value.PSObject.Properties | ForEach-Object {
                            $actionName = $_.Name  # v39 FIX
                            $this.NetworkQTable[$stateName][$actionName] = [double]$_.Value
                        }
                    }
                }
                if ($state.TotalPredictions) { $this.TotalPredictions = $state.TotalPredictions }
                if ($state.CorrectPredictions) { $this.CorrectPredictions = $state.CorrectPredictions }
                if ($state.TotalOptimizations) { $this.TotalOptimizations = $state.TotalOptimizations }
            }
        } catch { }
    }
}
# ═══════════════════════════════════════════════════════════════════════════════
# DISK WRITE CACHE - PrimoCache-like Write-Back Cache
# Zamiast 27 plików JSON zapisywanych na dysk NARAZ co 5 min,
# cache trzyma dane w RAM i flushuje 1-2 pliki na tick (co ~2s).
# Efekt: rozłożenie I/O w czasie, mniej spike'ów dyskowych, szybsze SaveState.
# ═══════════════════════════════════════════════════════════════════════════════