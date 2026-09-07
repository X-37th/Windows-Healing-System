# Scripts/AI/Invoke-OllamaChat.ps1
# Windows Healing System - Recency-Biased Rolling Memory Engine

. "$PSScriptRoot/Get-RagContext.ps1"

$script:RAG_CONFIDENCE_THRESHOLD = 0.58

# Persistent anchor for the current conversational topic. Updated only when the
# user asks a genuine, self-contained new-topic question; used to resolve
# ambiguous follow-ups so a chain of vague questions ("what about that?" ->
# "and the registry path for it?") doesn't collapse into a self-reference.
$script:WHS_LastTopicAnchor = $null

# ==============================================================================
# NON-BLOCKING ASYNC HTTP DISPATCHER
# ==============================================================================
Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue

function Invoke-OllamaHttpAsync {
    param(
        [string]$Uri,
        [string]$PayloadJson,
        [int]$TimeoutSec = 180
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    $content = New-Object System.Net.Http.StringContent($PayloadJson, [System.Text.Encoding]::UTF8, "application/json")
    $postTask = $client.PostAsync($Uri, $content)

    # Pump WPF Dispatcher with [void] to prevent pipeline null leaks
    while (-not $postTask.IsCompleted) {
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        [System.Threading.Thread]::Sleep(25)
    }

    if ($postTask.IsFaulted) {
        $errMsg = if ($postTask.Exception.InnerException) { $postTask.Exception.InnerException.Message } else { $postTask.Exception.Message }
        $content.Dispose()
        $client.Dispose()
        $handler.Dispose()
        throw $errMsg
    }

    $response = $postTask.Result
    $readTask = $response.Content.ReadAsStringAsync()
    while (-not $readTask.IsCompleted) {
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{}
        )
        [System.Threading.Thread]::Sleep(10)
    }

    $rawBody = $readTask.Result

    $content.Dispose()
    $response.Dispose()
    $client.Dispose()
    $handler.Dispose()

    if (-not $response.IsSuccessStatusCode) {
        throw "Ollama returned HTTP $([int]$response.StatusCode): $rawBody"
    }

    return [string]$rawBody
}

function Get-OllamaModelsDetailed {
    param([string]$Endpoint = "http://localhost:11434")
    try {
        $res = Invoke-RestMethod -Uri "$Endpoint/api/tags" -Method Get -TimeoutSec 5 -ErrorAction Stop
        
        $chatModels = @($res.models | Where-Object { $_.name -notmatch "embed|ocr" } | ForEach-Object {
            $sizeMb = [Math]::Round($_.size / 1MB, 1)
            $isOptimal = $sizeMb -le 2500

            $tag = if ($isOptimal) { "[Optimal - Fast]" } else { "[Heavy - Exceeds VRAM]" }
            $display = "$($_.name) ($sizeMb MB) $tag"

            [PSCustomObject]@{
                Name        = $_.name
                DisplayName = $display
                SizeMB      = $sizeMb
                Bytes       = [int64]$_.size
                IsOptimal   = $isOptimal
            }
        } | Sort-Object Bytes)

        return $chatModels
    }
    catch {
        return @()
    }
}

function Get-QueryIntentCategory {
    param([string]$Query)
    $q = $Query.ToLower().Trim()

    if ($q -match '\b(what is this (software|tool|app|program)|what can you do|who are you|explain whs|tell me about yourself|what are your capabilities|features of whs|how do you work)\b') {
        return "META"
    }

    if ($q -match '\b(windows|laptop|pc|battery|sleep|standby|cpu|gpu|ram|disk|edge|onedrive|telemetry|gaming|fps|driver|registry|service)\b') {
        return "TECHNICAL"
    }

    $triviaPatterns = @(
        "\bcapital of\b", "\bwho is\b", "\bwho was\b", "\bpresident of\b", "\bweather in\b",
        "\brecipe for\b", "\bhow to bake\b", "\bhow to cook\b", "\blyrics of\b", "\bmeaning of life\b",
        "\btranslate to\b", "\bwrite a poem\b", "\btell me a joke\b", "\bpopulation of\b", "\bcurrency of\b"
    )
    foreach ($pat in $triviaPatterns) {
        if ($q -match $pat) { return "TRIVIA" }
    }

    return "TECHNICAL"
}

# ==============================================================================
# COREFERENCE CONTEXTUALIZER (ONLY ATTACHES WHEN PRONOUNS LACK NOUN SUBJECT)
# ==============================================================================
function Resolve-SearchQueryContext {
    param(
        [string]$CurrentQuery,
        [System.Collections.Generic.List[PSCustomObject]]$RecentTurns
    )

    $newTopicKeywords = '\b(gaming|fps|telemetry|edge|onedrive|disk|storage|debloat|update|ram|cpu|gpu|sound|audio|wifi|driver)\b'
    $followUpPattern  = '\b(it|that|this|these|those|them|the tweak|the fix|the issue|the problem|how do i fix|how to do it|is it safe|what about|tell me more|how to disable|enable it|apply it|registry path)\b'

    $isNewTopic = $CurrentQuery -match $newTopicKeywords

    if ($isNewTopic) {
        # Self-contained new-topic query -> becomes the new anchor for future follow-ups
        $script:WHS_LastTopicAnchor = $CurrentQuery
        return $CurrentQuery
    }

    $words = $CurrentQuery.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
    $isAmbiguous = ($CurrentQuery -match $followUpPattern -or $words.Length -le 4)

    if (-not $isAmbiguous) {
        # Also a self-contained query -> update the anchor
        $script:WHS_LastTopicAnchor = $CurrentQuery
        return $CurrentQuery
    }

    # Ambiguous follow-up: resolve against the persisted topic anchor (not just
    # the raw previous message) so a chain of vague follow-ups keeps pointing
    # back at the real topic instead of drifting after one hop.
    if ($script:WHS_LastTopicAnchor) {
        return "$CurrentQuery (Referencing topic: $($script:WHS_LastTopicAnchor))"
    }

    if ($RecentTurns -and $RecentTurns.Count -gt 0) {
        $recentUserMsg = @($RecentTurns | Where-Object { $_.role -eq "user" })[-1]
        if ($recentUserMsg) {
            return "$CurrentQuery (Referencing: $($recentUserMsg.content))"
        }
    }

    return $CurrentQuery
}

function Invoke-WHSAssistantQuery {
    param(
        [string]$UserQuery,
        [string]$Model = "gemma3:1b",
        [string]$EmbeddingModel = "nomic-embed-text:v1.5",
        [string]$Endpoint = "http://localhost:11434",
        [System.Collections.Generic.List[PSCustomObject]]$RecentTurns = $null,
        [System.Collections.Generic.List[string]]$SummaryBullets = $null
    )

    $cleanQuery = $UserQuery.Trim().Trim('"').Trim("'")
    $intent = Get-QueryIntentCategory -Query $cleanQuery

    # Fast-Path Trivia Intercept (0 ms)
    if ($intent -eq "TRIVIA") {
        return @{
            Success        = $true
            Reply          = "I am here only to help you with fixing and improving your machine!`n`nI specialize in Windows 11 performance tuning, Modern Standby battery fixes, debloating, and system security. How can I help with your PC today?"
            Docs           = @()
            Actions        = @()
            RetrievalMs    = 0
            GenerationMs   = 0
            TopScore       = 0.0
        }
    }

    # Contextualize search query with recency bias
    $retrievalQuery = Resolve-SearchQueryContext -CurrentQuery $cleanQuery -RecentTurns $RecentTurns

    # 1. Retrieve Knowledge Base Chunks
    $docs = @()
    $swRet = [System.Diagnostics.Stopwatch]::StartNew()
    if ($intent -eq "TECHNICAL") {
        $docs = Search-KnowledgeContext -Query $retrievalQuery -TopK 4 -Model $EmbeddingModel -Endpoint $Endpoint
    }
    $swRet.Stop()

    $topScore = 0.0
    if ($docs -and $docs.Count -gt 0) {
        $topScore = [double]$docs[0].SearchScore
    }

    $usableDocs = @()
    $contextText = ""
    if ($docs.Count -gt 0 -and $topScore -ge $script:RAG_CONFIDENCE_THRESHOLD) {
        $usableDocs = $docs
        $contextText = "<verified_documentation>`n"
        foreach ($d in $docs) {
            $contextText += "[Feature: $($d.title)]`nSummary: $($d.summary)`nTechnical Details: $($d.technical_details)`nSwitch Parameter: $($d.whs_parameter)`nSafety Level: $($d.safety_level)`n---`n"
        }
        $contextText += "</verified_documentation>`n"
    }

    # =========================================================================
    # SYSTEM PROMPT WITH STRICT RECENCY DIRECTIVE
    # =========================================================================
    $systemPrompt = @"
<agent_role>
You are the AI Assistant for Windows Healing System (WHS) — an articulate, frank, and expert Windows 11 system optimization engineer.
</agent_role>

<core_manifesto>
Windows Healing System (WHS) is an open-source Windows 11 optimization, debloating, and system repair suite.
Capabilities:
- Sleep & Power: Fixes Modern Standby (S0) battery drain and bag overheating by disabling sleep network connectivity.
- Privacy & Telemetry: Disables background telemetry, diagnostic tracking, and consumer data collection.
- System Debloating: Safely uninstalls preinstalled bloatware (Microsoft Edge, OneDrive, Cortana).
- Gaming Optimization: Activates the Ultimate Performance power plan, configures Game Mode, and reduces background latency.
- Component Healing: Restores Windows integrity using native DISM, SFC, and registry diagnostics.
</core_manifesto>

<operating_principles>
1. Recency Priority: The user's latest query is your highest priority. Build on recent context when asked follow-ups (e.g. "how do I do that?"), but if the user shifts to a new topic, focus entirely on the new topic.
2. Identity & Software Questions: When asked who you are or what this software is, explain your features clearly, thoroughly, and helpfully using the Core Manifesto.
3. Frankness Over Sycophancy: Never be a "yes-man". If an action is risky or marked Caution (such as force-removing Edge or OneDrive), be candid about the trade-offs: explain app dependencies, update reinstallation, and potential instability.
4. Grounded Technical Advice: Synthesize the verified documentation context whenever provided. Never invent imaginary registry paths.
5. Retrieved Document Relevance Check: The <verified_documentation> block may occasionally not match what the user is actually asking about (e.g. a follow-up question referencing a different tweak than what was retrieved). If the documentation does not clearly relate to the user's specific question or the recent conversation topic, do NOT force-fit an answer from it. Say so plainly and rely on the conversation history instead, or ask the user to clarify which feature/registry key they mean.
</operating_principles>
"@

    # Inject compacted summary of older turns (Older data summarized, oldest forgotten)
    if ($SummaryBullets -and $SummaryBullets.Count -gt 0) {
        $summaryText = ($SummaryBullets | ForEach-Object { "- $_" }) -join "`n"
        $systemPrompt += "`n`n<session_memory_summary>`nBrief background from earlier in this session:`n$summaryText`n</session_memory_summary>"
    }

    # =========================================================================
    # CONSTRUCT MESSAGES: SYSTEM + VERBATIM RECENCY (LAST 4 MESSAGES) + CURRENT
    # =========================================================================
    $messages = [System.Collections.Generic.List[hashtable]]::new()
    $messages.Add(@{ role = "system"; content = $systemPrompt })

    # Inject strictly the most recent turns (Max 8 messages = 4 full exchanges)
    if ($RecentTurns -and $RecentTurns.Count -gt 0) {
        $windowSize = 8
        $startIdx = [Math]::Max(0, $RecentTurns.Count - $windowSize)
        for ($i = $startIdx; $i -lt $RecentTurns.Count; $i++) {
            $messages.Add(@{
                role    = $RecentTurns[$i].role
                content = $RecentTurns[$i].content
            })
        }
    }

    # Current user turn - include the resolved-context note (if this was an
    # ambiguous follow-up) so the model can see what topic it was resolved
    # against, rather than only the raw ambiguous query plus retrieved docs.
    $resolvedNote = if ($retrievalQuery -ne $cleanQuery) {
        "`n(This is a follow-up question. Resolved context: $retrievalQuery)"
    } else {
        ""
    }

    $currentTurnContent = if ([string]::IsNullOrWhiteSpace($contextText)) {
        "$cleanQuery$resolvedNote"
    } else {
        "$contextText`nUser Input: $cleanQuery$resolvedNote"
    }
    $messages.Add(@{ role = "user"; content = $currentTurnContent })

    # 10k Token Output Capacity + 16k Context Window
    $payload = @{
        model      = $Model
        messages   = $messages
        stream     = $false
        keep_alive = -1
        options    = @{
            num_predict = 10240
            num_ctx     = 16384
            temperature = 0.35
            top_k       = 40
            top_p       = 0.9
        }
    } | ConvertTo-Json -Depth 6 -Compress

    $swLlm = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $rawJson = Invoke-OllamaHttpAsync -Uri "$Endpoint/api/chat" -PayloadJson $payload -TimeoutSec 180
        $swLlm.Stop()

        $res = ConvertFrom-Json -InputObject $rawJson
        $actions = @($usableDocs | Where-Object { -not [string]::IsNullOrWhiteSpace($_.whs_parameter) } | ForEach-Object { $_.whs_parameter })

        return @{
            Success        = $true
            Reply          = $res.message.content
            Docs           = $usableDocs
            Actions        = $actions
            RetrievalMs    = $swRet.ElapsedMilliseconds
            GenerationMs   = $swLlm.ElapsedMilliseconds
            TopScore       = $topScore
            ContextQuery   = $retrievalQuery
        }
    }
    catch {
        $swLlm.Stop()
        return @{
            Success        = $false
            Reply          = "Local AI engine communication error: $_"
            Docs           = $usableDocs
            Actions        = @()
            RetrievalMs    = $swRet.ElapsedMilliseconds
            GenerationMs   = $swLlm.ElapsedMilliseconds
            TopScore       = $topScore
            ContextQuery   = $retrievalQuery
        }
    }
}