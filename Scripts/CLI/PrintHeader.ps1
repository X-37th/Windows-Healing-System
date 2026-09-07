# Prints the header for the script
function PrintHeader {
    param (
        [string]$title
    )

    $scope = if ($script:Params.ContainsKey("Sysprep")) {
        "Default user profile (Sysprep)"
    }
    elseif ($script:Params.ContainsKey("User")) {
        "Target user: $($script:Params.Item("User"))"
    }
    else {
        "Current user: $(GetUserName)"
    }

    Clear-Host
    Write-Host "+----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "| Windows Healing System                                  |" -ForegroundColor Cyan
    Write-Host "+----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host (" Section : {0}" -f $title) -ForegroundColor White
    Write-Host (" Scope   : {0}" -f $scope) -ForegroundColor DarkGray
    Write-Host "+----------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
}
