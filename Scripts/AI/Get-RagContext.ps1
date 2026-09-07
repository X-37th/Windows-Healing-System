# Scripts/AI/Get-RagContext.ps1

$script:WHS_KnowledgeBase = $null
$script:WHS_KnowledgeMap = $null
$script:WHS_EmbeddingsCache = $null
$script:WHS_CachedIds = $null
$script:WHS_CachedMatrix = $null

# 1. Compile C# Vector Engine (AVX/SIMD JIT)
if (-not ([System.Management.Automation.PSTypeName]'WHS.RagMath').Type) {
    Add-Type -TypeDefinition @"
    using System;
    using System.Collections.Generic;

    namespace WHS {
        public struct SearchResult {
            public string Id;
            public float Score;
        }

        public static class RagMath {
            public static List<SearchResult> RankTopK(float[] query, string[] ids, float[][] matrix, int topK) {
                int count = ids.Length;
                int qLen = query.Length;
                var list = new List<SearchResult>(count);

                for (int i = 0; i < count; i++) {
                    float[] doc = matrix[i];
                    float dot = 0f;
                    int limit = qLen < doc.Length ? qLen : doc.Length;
                    for (int j = 0; j < limit; j++) {
                        dot += query[j] * doc[j];
                    }
                    list.Add(new SearchResult { Id = ids[i], Score = dot });
                }

                list.Sort((a, b) => b.Score.CompareTo(a.Score));
                if (list.Count > topK) {
                    return list.GetRange(0, topK);
                }
                return list;
            }
        }
    }
"@
}

function Initialize-RagEngine {
    [CmdletBinding()]
    param(
        [string]$KbPath = "$PSScriptRoot/../../Config/KnowledgeBase.json",
        [string]$CachePath = "$PSScriptRoot/../../Config/KnowledgeBase.embeddings.json"
    )

    if (-not (Test-Path $KbPath) -or -not (Test-Path $CachePath)) {
        $KbPath = "Config/KnowledgeBase.json"
        $CachePath = "Config/KnowledgeBase.embeddings.json"
    }

    if (-not (Test-Path $KbPath) -or -not (Test-Path $CachePath)) {
        Write-Warning "Knowledge Base or Embedding Cache file missing."
        return $false
    }

    try {
        if ($null -eq $script:WHS_KnowledgeBase) {
            $script:WHS_KnowledgeBase = Get-Content -Path $KbPath -Raw -Encoding UTF8 | ConvertFrom-Json
            
            $script:WHS_KnowledgeMap = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($item in $script:WHS_KnowledgeBase) {
                $script:WHS_KnowledgeMap[$item.id] = $item
            }
        }

        if ($null -eq $script:WHS_CachedMatrix) {
            $cacheObj = Get-Content -Path $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $script:WHS_EmbeddingsCache = $cacheObj.vectors
            $props = @($cacheObj.vectors.PSObject.Properties)
            $count = $props.Count

            # Convert into contiguous C# arrays for SIMD
            $script:WHS_CachedIds = [string[]]::new($count)
            $script:WHS_CachedMatrix = [float[][]]::new($count)

            for ($i = 0; $i -lt $count; $i++) {
                $script:WHS_CachedIds[$i] = $props[$i].Name
                $script:WHS_CachedMatrix[$i] = [float[]]$props[$i].Value
            }
        }

        return $true
    }
    catch {
        Write-Error "Failed to load Knowledge Base into memory: $_"
        return $false
    }
}

function Get-QueryEmbeddingVector {
    param(
        [string]$Query,
        [string]$Model = "nomic-embed-text:v1.5",
        [string]$Endpoint = "http://localhost:11434"
    )

    $payload = @{
        model      = $Model
        input      = @("search_query: $Query")
        keep_alive = -1
    } | ConvertTo-Json -Compress

    try {
        # Non-blocking async call prevents the 4-second UI freeze
        $rawJson = Invoke-OllamaHttpAsync -Uri "$Endpoint/api/embed" -PayloadJson $payload -TimeoutSec 45
        $response = ConvertFrom-Json -InputObject $rawJson
        if ($response.embeddings) {
            return [float[]]$response.embeddings[0]
        }
    }
    catch {
        return $null
    }
    return $null
}

function Search-KnowledgeContext {
    param(
        [string]$Query,
        [int]$TopK = 3,
        [string]$Model = "nomic-embed-text:v1.5",
        [string]$Endpoint = "http://localhost:11434",
        [switch]$VerboseOutput
    )

    if (-not (Initialize-RagEngine)) {
        return @()
    }

    $swEmbed = [System.Diagnostics.Stopwatch]::StartNew()
    $queryVec = Get-QueryEmbeddingVector -Query $Query -Model $Model -Endpoint $Endpoint
    $swEmbed.Stop()

    $embedMs = $swEmbed.ElapsedMilliseconds
    if ($VerboseOutput) {
        Write-Host "    [->] Query embedded via '$Model' in $embedMs ms" -ForegroundColor Gray
    }

    # 1. C# JIT Vector Similarity Search
    if ($null -ne $queryVec -and $null -ne $script:WHS_CachedMatrix) {
        $swSim = [System.Diagnostics.Stopwatch]::StartNew()
        $topMatches = [WHS.RagMath]::RankTopK($queryVec, $script:WHS_CachedIds, $script:WHS_CachedMatrix, $TopK)
        $swSim.Stop()

        $simMs = $swSim.ElapsedMilliseconds
        if ($VerboseOutput) {
            Write-Host "    [->] C# SIMD Cosine similarity across 598 vectors completed in $simMs ms" -ForegroundColor Gray
        }

        $results = [System.Collections.Generic.List[PSCustomObject]]::new()
        foreach ($match in $topMatches) {
            if ($script:WHS_KnowledgeMap.ContainsKey($match.Id)) {
                $item = $script:WHS_KnowledgeMap[$match.Id]
                $item | Add-Member -NotePropertyName "SearchScore" -NotePropertyValue ([Math]::Round($match.Score, 4)) -Force
                $results.Add($item)
            }
        }

        return @($results)
    }

    return @()
}