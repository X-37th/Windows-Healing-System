# Restores previously saved settings from JSON and applies them to the UI controls.
function ApplySettingsToUiControls {
    param (
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$window,
        
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$settingsJson,
        
        [Parameter(Mandatory=$true)]
        [hashtable]$uiControlMappings
    )

    if (-not $settingsJson -or -not $settingsJson.Settings -or -not $uiControlMappings) {
        return
    }

    # Index settings for fast lookup
    $settingsIndex = @{}
    foreach ($setting in $settingsJson.Settings) {
        # Treat true, 1, 'True' as $true
        $val = $setting.Value
        $isTrue = ($val -eq $true -or $val -eq 1 -or $val -eq 'True')
        $settingsIndex[$setting.Name] = $isTrue
    }

    foreach ($controlName in $uiControlMappings.Keys) {
        $control = $window.FindName($controlName)
        if (-not $control) { continue }

        $mapping = $uiControlMappings[$controlName]

        if ($mapping.Type -eq 'feature') {
            if ($control -is [System.Windows.Controls.Primitives.ToggleButton]) {
                if ($settingsIndex.ContainsKey($mapping.FeatureId)) {
                    $control.IsChecked = $settingsIndex[$mapping.FeatureId]
                } else {
                    $control.IsChecked = $false
                }
            }
        }
        elseif ($mapping.Type -eq 'group') {
            if ($control -is [System.Windows.Controls.Primitives.Selector]) {
                $selectedIndex = 0
                $i = 1
                
                foreach ($val in $mapping.Values) {
                    $allFeaturesMatch = $true
                    
                    if (-not $val.FeatureIds -or $val.FeatureIds.Count -eq 0) {
                        $allFeaturesMatch = $false
                    } else {
                        foreach ($fid in $val.FeatureIds) {
                            if (-not $settingsIndex.ContainsKey($fid) -or $settingsIndex[$fid] -ne $true) {
                                $allFeaturesMatch = $false
                                break
                            }
                        }
                    }
                    
                    if ($allFeaturesMatch) {
                        $selectedIndex = $i
                        break
                    }
                    $i++
                }
                
                $control.SelectedIndex = $selectedIndex
            }
        }
    }
}
