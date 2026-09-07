# Shows the CLI menu options and prompts the user to select one. Loops until a valid option is selected.
function ShowCLIMenuOptions {
    Do {
        $ModeSelectionMessage = "Select an option"

        PrintHeader 'Main Menu'

        Write-Host "  1  Default mode" -ForegroundColor Cyan
        Write-Host "     Apply the recommended Windows cleanup and privacy settings."
        Write-Host ""
        Write-Host "  2  App removal mode" -ForegroundColor Cyan
        Write-Host "     Select and remove apps without applying other tweaks."

        if (Test-Path $script:SavedSettingsFilePath) {
            Write-Host ""
            Write-Host "  3  Last used settings" -ForegroundColor Cyan
            Write-Host "     Apply the previous saved selection."
            $ModeSelectionMessage = "Select an option (1/2/3)"
        }
        else {
            $ModeSelectionMessage = "Select an option (1/2)"
        }

        Write-Host ""
        $Mode = Read-Host $ModeSelectionMessage

        if (($Mode -eq '3') -and -not (Test-Path $script:SavedSettingsFilePath)) {
            $Mode = $null
        }

        if ($Mode -ne '1' -and $Mode -ne '2' -and $Mode -ne '3') {
            Write-Host "Please enter a valid option." -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
        }
    }
    while ($Mode -ne '1' -and $Mode -ne '2' -and $Mode -ne '3')

    return $Mode
}
