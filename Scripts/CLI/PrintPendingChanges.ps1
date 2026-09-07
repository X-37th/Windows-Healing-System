# Prints all pending changes that will be made by the script
function PrintPendingChanges {
    Write-Host "Windows Healing System is ready to apply these changes:" -ForegroundColor Cyan

    if ($script:Params['CreateRestorePoint']) {
        Write-Host "  - $($script:Features['CreateRestorePoint'].Label)"
    }
    foreach ($parameterName in $script:Params.Keys) {
        if ($script:ControlParams -contains $parameterName) {
            continue
        }

        # Print parameter description
        switch ($parameterName) {
            'Apps' {
                continue
            }
            'CreateRestorePoint' {
                continue
            }
            'RemoveApps' {
                $appsList = GenerateAppsList

                if ($appsList.Count -eq 0) {
                    Write-Host "No valid apps were selected for removal" -ForegroundColor Yellow
                    Write-Output ""
                    continue
                }

                Write-Host "  - Remove $($appsList.Count) apps:"
                Write-Host $appsList -ForegroundColor DarkGray
                continue
            }
            'RemoveAppsCustom' {
                $appsList = LoadAppsFromFile $script:CustomAppsListFilePath

                if ($appsList.Count -eq 0) {
                    Write-Host "No valid apps were selected for removal" -ForegroundColor Yellow
                    Write-Output ""
                    continue
                }

                Write-Host "  - Remove $($appsList.Count) apps:"
                Write-Host $appsList -ForegroundColor DarkGray
                continue
            }
            default {
                if ($script:Features -and $script:Features.ContainsKey($parameterName)) {
                    $action = $script:Features[$parameterName].Action
                    $message = $script:Features[$parameterName].Label
                    Write-Host "  - $action $message"
                }
                else {
                    # Fallback: show the parameter name if no feature description is available
                    Write-Host "  - $parameterName"
                }
                continue
            }
        }
    }

    Write-Output ""
    Write-Output ""
    Write-Host "Press Enter to apply these changes, or press CTRL+C to cancel." -ForegroundColor Yellow
    Read-Host | Out-Null
}
