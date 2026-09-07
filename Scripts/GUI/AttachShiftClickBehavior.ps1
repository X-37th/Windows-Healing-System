# Provides Windows-like Shift+Click multi-selection for app checkboxes.
# Works with the flat $script:AllAppCheckboxes array so range selection
# spans across category Expanders seamlessly.
function AttachShiftClickBehavior {
    param (
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.CheckBox]$checkbox,
        
        # $appsPanel is accepted for API compatibility but not used internally.
        # Range selection is performed against $script:AllAppCheckboxes instead.
        [Parameter(Mandatory=$false)]
        [System.Windows.Controls.Panel]$appsPanel,
        
        [Parameter(Mandatory=$true)]
        [ref]$lastSelectedCheckboxRef,
        
        [Parameter(Mandatory=$false)]
        [scriptblock]$updateStatusCallback
    )
    
    $checkbox.Add_Click({
        param($sender, $e)
        
        $isShiftDown = [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::LeftShift) -or 
                       [System.Windows.Input.Keyboard]::IsKeyDown([System.Windows.Input.Key]::RightShift)
                       
        if ($isShiftDown -and $null -ne $lastSelectedCheckboxRef.Value -and $lastSelectedCheckboxRef.Value -ne $sender) {
            # Use the flat $script:AllAppCheckboxes array — works across all category Expanders
            $allBoxes = $script:AllAppCheckboxes
            
            if ($allBoxes -and $allBoxes.Count -gt 0) {
                $startIdx = [System.Array]::IndexOf($allBoxes, $lastSelectedCheckboxRef.Value)
                $endIdx   = [System.Array]::IndexOf($allBoxes, $sender)
                
                if ($startIdx -ne -1 -and $endIdx -ne -1) {
                    $min      = [Math]::Min($startIdx, $endIdx)
                    $max      = [Math]::Max($startIdx, $endIdx)
                    $newState = $sender.IsChecked
                    
                    for ($i = $min; $i -le $max; $i++) {
                        $box = $allBoxes[$i]
                        if ($box -ne $sender -and $box.IsChecked -ne $newState) {
                            $box.IsChecked = $newState
                        }
                    }
                    
                    if ($updateStatusCallback) {
                        & $updateStatusCallback
                    }
                }
            }
        }
        
        $lastSelectedCheckboxRef.Value = $sender
    }.GetNewClosure())
}
