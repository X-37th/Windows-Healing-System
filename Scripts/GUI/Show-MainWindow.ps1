function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms | Out-Null

    # Helper to constrain the maximized window to the monitor working area (respects taskbar).
    # Required for WindowStyle=None windows — without this the window extends behind the taskbar.
    if (-not ([System.Management.Automation.PSTypeName]'Windows Healing System.MaximizedWindowHelper').Type) {
        Add-Type -Namespace WindowsHealingSystem -Name MaximizedWindowHelper `
            -ReferencedAssemblies 'PresentationFramework','System.Windows.Forms','System.Drawing' `
            -MemberDefinition @'
            [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
            private struct MINMAXINFO {
                public POINT ptReserved, ptMaxSize, ptMaxPosition, ptMinTrackSize, ptMaxTrackSize;
            }
            [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
            private struct POINT { public int x, y; }

            [System.Runtime.InteropServices.DllImport("user32.dll")]
            private static extern System.IntPtr MonitorFromWindow(System.IntPtr hwnd, uint dwFlags);

            [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Auto)]
            private static extern bool GetMonitorInfo(System.IntPtr hMonitor, ref MONITORINFO lpmi);

            [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
            private struct RECT {
                public int Left, Top, Right, Bottom;
            }

            [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
            private struct MONITORINFO {
                public int cbSize;
                public RECT rcMonitor;
                public RECT rcWork;
                public uint dwFlags;
            }

            public static System.IntPtr WmGetMinMaxInfoHook(
                System.IntPtr hwnd, int msg, System.IntPtr wParam, System.IntPtr lParam, ref bool handled) {
                if (msg == 0x0024) { // WM_GETMINMAXINFO
                    var mmi = (MINMAXINFO)System.Runtime.InteropServices.Marshal.PtrToStructure(
                        lParam, typeof(MINMAXINFO));

                    const uint MONITOR_DEFAULTTONEAREST = 0x00000002;
                    var monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
                    var monitorInfo = new MONITORINFO();
                    monitorInfo.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(MONITORINFO));

                    if (monitor != System.IntPtr.Zero && GetMonitorInfo(monitor, ref monitorInfo)) {
                        mmi.ptMaxPosition.x = monitorInfo.rcWork.Left - monitorInfo.rcMonitor.Left;
                        mmi.ptMaxPosition.y = monitorInfo.rcWork.Top - monitorInfo.rcMonitor.Top;
                        mmi.ptMaxSize.x     = monitorInfo.rcWork.Right - monitorInfo.rcWork.Left;
                        mmi.ptMaxSize.y     = monitorInfo.rcWork.Bottom - monitorInfo.rcWork.Top;
                    }
                    else {
                        var screen = System.Windows.Forms.Screen.FromHandle(hwnd);
                        var wa = screen.WorkingArea;
                        var bounds = screen.Bounds;
                        mmi.ptMaxPosition.x = wa.Left - bounds.Left;
                        mmi.ptMaxPosition.y = wa.Top - bounds.Top;
                        mmi.ptMaxSize.x     = wa.Width;
                        mmi.ptMaxSize.y     = wa.Height;
                    }

                    System.Runtime.InteropServices.Marshal.StructureToPtr(mmi, lParam, true);
                }
                return System.IntPtr.Zero;
            }
'@
    }

    # Get current Windows build version
    $WinVersion = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' CurrentBuild

    $script:IsDarkMode = GetSystemUsesDarkMode

    # Load XAML from file
    $xaml = Get-Content -Path $script:MainWindowSchema -Raw
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    try {
        $window = [System.Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        $reader.Close()
    }

    SetWindowThemeResources -window $window -usesDarkMode $script:IsDarkMode

    # Get named elements
    $mainBorder = $window.FindName('MainBorder')
    $titleBarBackground = $window.FindName('TitleBarBackground')
    $closeBtn = $window.FindName('CloseBtn')
    $themeToggleBtn = $window.FindName('ThemeToggleBtn')
    $themeToggleIcon = $window.FindName('ThemeToggleIcon')
    $menuDocumentation = $window.FindName('MenuDocumentation')
    $importConfigBtn = $window.FindName('ImportConfigBtn')
    $exportConfigBtn = $window.FindName('ExportConfigBtn')

    $windowStateNormal = [System.Windows.WindowState]::Normal
    $windowStateMaximized = [System.Windows.WindowState]::Maximized
    $normalWindowShadow = $mainBorder.Effect
    $initialNormalMaxWidth = 1400.0

    $convertScreenPointToDip = {
        param(
            [double]$x,
            [double]$y
        )

        $source = [System.Windows.PresentationSource]::FromVisual($window)
        if ($null -eq $source -or $null -eq $source.CompositionTarget) {
            return [System.Windows.Point]::new($x, $y)
        }

        return $source.CompositionTarget.TransformFromDevice.Transform([System.Windows.Point]::new($x, $y))
    }

    $convertScreenPixelsToDip = {
        param(
            [double]$width,
            [double]$height
        )

        $topLeft = & $convertScreenPointToDip 0 0
        $bottomRight = & $convertScreenPointToDip $width $height
        return [System.Windows.Size]::new($bottomRight.X - $topLeft.X, $bottomRight.Y - $topLeft.Y)
    }

    $getWindowScreen = {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        if ($hwnd -eq [IntPtr]::Zero) {
            return $null
        }

        return [System.Windows.Forms.Screen]::FromHandle($hwnd)
    }

    $updateWindowChrome = {
        $chrome = [System.Windows.Shell.WindowChrome]::GetWindowChrome($window)
        if ($window.WindowState -eq $windowStateMaximized) {
            $mainBorder.Margin = [System.Windows.Thickness]::new(0)
            $mainBorder.BorderThickness = [System.Windows.Thickness]::new(0)
            $mainBorder.CornerRadius = [System.Windows.CornerRadius]::new(0)
            $mainBorder.Effect = $null
            $titleBarBackground.CornerRadius = [System.Windows.CornerRadius]::new(0)
            # Zero out resize borders when maximized so the entire title bar row is draggable
            if ($chrome) { $chrome.ResizeBorderThickness = [System.Windows.Thickness]::new(0) }
        }
        else {
            $mainBorder.Margin = [System.Windows.Thickness]::new(0)
            $mainBorder.BorderThickness = [System.Windows.Thickness]::new(1)
            $mainBorder.CornerRadius = [System.Windows.CornerRadius]::new(8)
            $mainBorder.Effect = $normalWindowShadow
            $titleBarBackground.CornerRadius = [System.Windows.CornerRadius]::new(8, 8, 0, 0)
            if ($chrome) { $chrome.ResizeBorderThickness = [System.Windows.Thickness]::new(5) }
        }
    }

    $applyInitialWindowSize = {
        if ($window.WindowState -ne $windowStateNormal) {
            return
        }

        $screen = & $getWindowScreen
        if ($null -eq $screen) {
            return
        }

        $workingAreaTopLeftDip = & $convertScreenPointToDip $screen.WorkingArea.Left $screen.WorkingArea.Top
        $workingAreaDip = & $convertScreenPixelsToDip $screen.WorkingArea.Width $screen.WorkingArea.Height
        $window.Width = [Math]::Min($initialNormalMaxWidth, $workingAreaDip.Width)
        $window.Left = $workingAreaTopLeftDip.X + (($workingAreaDip.Width - $window.Width) / 2)
    }

    $window.Add_SourceInitialized({
        & $applyInitialWindowSize
        & $updateWindowChrome

        # Register WM_GETMINMAXINFO hook so maximizing respects the working area (taskbar)
        $hwndHelper = New-Object System.Windows.Interop.WindowInteropHelper($window)
        $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($hwndHelper.Handle)
        $hookMethod = [WindowsHealingSystem.MaximizedWindowHelper].GetMethod('WmGetMinMaxInfoHook')
        $hook = [System.Delegate]::CreateDelegate([System.Windows.Interop.HwndSourceHook], $hookMethod)
        $hwndSource.AddHook($hook)
    })

    $contentGrid = $window.FindName('ContentGrid')
    # Option B: gutter only applies above 1800px — normal/maximized windows get full width
    $maxContentWidth = 1800.0

    $updateContentMargin = {
        $w = $window.ActualWidth
        if ($w -gt $maxContentWidth) {
            $gutter = [Math]::Floor(($w - $maxContentWidth) / 2)
            $contentGrid.Margin = [System.Windows.Thickness]::new($gutter, 0, $gutter, 0)
        } else {
            if ($contentGrid.Margin.Left -ne 0) {
                $contentGrid.Margin = [System.Windows.Thickness]::new(0)
            }
        }
    }

    # SizeChanged: only update content margin — chrome recalc removed (causes layout thrash on every pixel)
    $window.Add_SizeChanged({
        if ($window.ActualWidth -gt $maxContentWidth -or $contentGrid.Margin.Left -gt 0) {
            & $updateContentMargin
        }
    })

    # StateChanged: update chrome AND margin — fires only on Normal<->Maximized transitions
    $window.Add_StateChanged({
        & $updateWindowChrome
        & $updateContentMargin
    })

    $window.Add_LocationChanged({
        # Nudge the popup offset to force WPF to recalculate its screen position
        if ($script:BubblePopup -and $script:BubblePopup.IsOpen) {
            $script:BubblePopup.HorizontalOffset += 1
            $script:BubblePopup.HorizontalOffset -= 1
        }
    })
    
    $closeBtn.Add_Click({
        $window.Close()
    })

    # ── Theme Switcher ──────────────────────────────────────────────────────
    # Palettes stored at script scope so the Add_Click handler can reach them
    # (WPF event handlers run outside the enclosing function's scope in PS5.1)
    $script:DarkPalette = @{
        BgColor='#202020'; FgColor='#FFFFFF'; CardBgColor='#2b2b2b'
        BorderColor='#404040'; ButtonBorderColor='#404040'
        CheckBoxBgColor='#272727'; CheckBoxBorderColor='#808080'; CheckBoxHoverColor='#343434'
        ComboBgColor='#373737'; ComboHoverColor='#434343'; ComboItemBgColor='#2c2c2c'
        ComboItemHoverColor='#383838'; ComboItemSelectedColor='#343434'
        AccentColor='#FFD700'; ButtonDisabled='#434343'; ButtonTextDisabled='#989898'
        SecondaryButtonBg='#393939'; SecondaryButtonHover='#2a2a2a'
        SecondaryButtonPressed='#1e1e1e'; SecondaryButtonDisabled='#3b3b3b'
        SecondaryButtonTextDisabled='#787878'; InputFocusColor='#1f1f1f'
        ScrollBarThumbColor='#3d3d3d'; ScrollBarThumbHoverColor='#4b4b4b'
        TitlebarButtonHover='#2d2d2d'; TitlebarButtonPressed='#292929'
        AppIdColor='#afafaf'; SearchHighlightColor='#4A4A2A'
        SearchHighlightActiveColor='#8A7000'; TableHeaderColor='#333333'
        SidebarBgColor='#1e1e1e'; SidebarBorderColor='#2a2a2a'; ContentBgColor='#141414'
        HeroTitleColor='#E5E7EB'; HeroSubtitleColor='#9CA3AF'; SidebarLabelColor='#9CA3AF'
    }
    $script:LightPalette = @{
        BgColor='#e5e5e5'; FgColor='#000000'; CardBgColor='#ffffff'
        BorderColor='#1E1E1E'; ButtonBorderColor='#1E1E1E'
        CheckBoxBgColor='#ffffff'; CheckBoxBorderColor='#1E1E1E'; CheckBoxHoverColor='#ececec'
        ComboBgColor='#ffffff'; ComboHoverColor='#f0f0f0'; ComboItemBgColor='#ffffff'
        ComboItemHoverColor='#e0e0e0'; ComboItemSelectedColor='#d1d5db'
        AccentColor='#ffae00'; ButtonDisabled='#bfbfbf'; ButtonTextDisabled='#ffffff'
        SecondaryButtonBg='#fbfbfb'; SecondaryButtonHover='#f0f0f0'
        SecondaryButtonPressed='#e0e0e0'; SecondaryButtonDisabled='#f7f7f7'
        SecondaryButtonTextDisabled='#b7b7b7'; InputFocusColor='#ffffff'
        ScrollBarThumbColor='#b9b9b9'; ScrollBarThumbHoverColor='#8b8b8b'
        TitlebarButtonHover='#e1e1e1'; TitlebarButtonPressed='#e6e6e6'
        AppIdColor='#444444'; SearchHighlightColor='#FFF4CE'
        SearchHighlightActiveColor='#FFD966'; TableHeaderColor='#ffffff'
        SidebarBgColor='#ffffff'; SidebarBorderColor='#1E1E1E'; ContentBgColor='#f9fafb'
        HeroTitleColor='#111827'; HeroSubtitleColor='#4b5563'; SidebarLabelColor='#4b5563'
    }

    if ($themeToggleBtn) {
        $themeToggleBtn.Add_Click({
            $toDark   = -not $script:IsDarkMode
            $palette  = if ($toDark) { $script:DarkPalette } else { $script:LightPalette }
            try {
                foreach ($key in $palette.Keys) {
                    # REPLACE the resource entry rather than mutating the existing brush.
                    # Mutation silently fails if WPF froze the brush (common when brushes are
                    # used inside ControlTemplates or Storyboards). Replacing the dictionary
                    # entry always fires the DynamicResource change-notification pipeline,
                    # so every {DynamicResource X} binding in the visual tree re-evaluates.
                    $newBrush = [System.Windows.Media.SolidColorBrush]::new(
                        [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
                    )
                    $script:GuiWindow.Resources[$key] = $newBrush
                }
                $script:IsDarkMode = $toDark
                $icon = $script:GuiWindow.FindName('ThemeToggleIcon')
                if ($icon) {
                    $icon.Text    = if ($toDark) { [char]0xF08C } else { [char]0xE706 }
                    $icon.ToolTip = if ($toDark) { 'Switch to light mode' } else { 'Switch to dark mode' }
                }
            } catch {
                Write-Warning "Theme switch failed: $_"
            }
        })
    }


    # Ensure closing the main window stops all execution
    $window.Add_Closing({
        $script:CancelRequested = $true
    })

    # Integrated App Selection UI
    $onlyInstalledAppsBox = $window.FindName('OnlyInstalledAppsBox')
    $loadingAppsIndicator = $window.FindName('LoadingAppsIndicator')
    $appSelectionStatus = $window.FindName('AppSelectionStatus')

    $presetDefaultApps = $window.FindName('PresetDefaultApps')
    $presetLastUsed = $window.FindName('PresetLastUsed')
    $jsonPresetsPanel = $window.FindName('JsonPresetsPanel')
    $appCategoryContainer = $window.FindName('AppCategoryContainer')
    $clearAppSelectionBtn = $window.FindName('ClearAppSelectionBtn')
    $presetDefaultTweaksBtn = $window.FindName('PresetDefaultTweaksBtn')
    $presetLastUsedTweaksBtn = $window.FindName('PresetLastUsedTweaksBtn')
    $presetPrivacyTweaksBtn = $window.FindName('PresetPrivacyTweaksBtn')
    $presetAITweaksBtn = $window.FindName('PresetAITweaksBtn')

    function AttachTriStateClickBehavior {
        param([System.Windows.Controls.CheckBox]$checkBox)

        if (-not $checkBox -or -not $checkBox.IsThreeState) { return }

        if (-not $checkBox.PSObject.Properties['WasIndeterminateBeforeClick']) {
            Add-Member -InputObject $checkBox -MemberType NoteProperty -Name 'WasIndeterminateBeforeClick' -Value $false
        }

        $checkBox.Add_PreviewMouseLeftButtonDown({
            $this.WasIndeterminateBeforeClick = ($this.IsChecked -eq [System.Nullable[bool]]$null)
        })
    }

    function NormalizeCheckboxState {
        param([System.Windows.Controls.CheckBox]$checkBox)

        if ($checkBox.PSObject.Properties['WasIndeterminateBeforeClick'] -and $checkBox.WasIndeterminateBeforeClick) {
            # WPF toggles null -> false before Click handlers fire; restore desired mixed -> checked behavior.
            $checkBox.WasIndeterminateBeforeClick = $false
            $checkBox.IsChecked = $true
            return $true
        }

        return ($checkBox.IsChecked -eq $true)
    }

    function SetTriStatePresetCheckBoxState {
        param(
            [System.Windows.Controls.CheckBox]$CheckBox,
            [int]$Total,
            [int]$Selected
        )

        if (-not $CheckBox) { return }

        if ($Total -eq 0) {
            $CheckBox.IsEnabled = $false
            $CheckBox.IsChecked = $false
            return
        }

        $CheckBox.IsEnabled = $true
        if ($Selected -eq 0) {
            $CheckBox.IsChecked = $false
        }
        elseif ($Selected -eq $Total) {
            $CheckBox.IsChecked = $true
        }
        else {
            $CheckBox.IsChecked = [System.Nullable[bool]]$null
        }
    }


    # Load JSON-defined presets and build dynamic preset checkboxes
    $script:JsonPresetCheckboxes = @()
    foreach ($preset in (LoadAppPresetsFromJson)) {
        $checkbox = New-Object System.Windows.Controls.CheckBox
        $checkbox.Content = $preset.Name
        $checkbox.IsThreeState = $true
        $checkbox.Style = $window.Resources['PresetChipStyle']
        $checkbox.ToolTip = "Select $($preset.Name)"
        $checkbox.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, $preset.Name)
        AttachTriStateClickBehavior -checkBox $checkbox
        Add-Member -InputObject $checkbox -MemberType NoteProperty -Name 'PresetAppIds' -Value $preset.AppIds
        $jsonPresetsPanel.Children.Add($checkbox) | Out-Null
        $script:JsonPresetCheckboxes += $checkbox

        $checkbox.Add_Click({
            if ($script:UpdatingPresets) { return }
            $presetIds = $this.PresetAppIds
            $check = NormalizeCheckboxState -checkBox $this
            ApplyPresetToApps -MatchFilter { param($c) (@($c.AppIds) | Where-Object { $presetIds -contains $_ }).Count -gt 0 }.GetNewClosure() -Check $check
        })
    }
    
    # Track the last selected checkbox for shift-click range selection
    $script:MainWindowLastSelectedCheckbox = $null
    
    # Guard flag: true while a load is in progress; prevents concurrent loads
    $script:IsLoadingApps = $false
    # Flag set when Default Mode is clicked before apps have finished loading
    $script:PendingDefaultMode = $false
    # Holds apps data preloaded before ShowDialog() so the first load skips the background job
    $script:PreloadedAppData = $null

    # Prevent app import until the apps list has finished initial population.
    if ($importConfigBtn) {
        $importConfigBtn.IsEnabled = $false
    }
    
    # Set script-level variable for GUI window reference
    $script:GuiWindow = $window

    # Guard flag to prevent preset handlers from firing when we update their state programmatically
    $script:UpdatingPresets = $false
    $script:UpdatingTweakPresets = $false



    # Running counter — updated incrementally instead of scanning all children on every click
    $script:SelectedAppCount = 0

    function UpdateAppSelectionStatus {
        $appSelectionStatus.Text = "$script:SelectedAppCount app(s) selected for removal"
    }

    # Applies a preset by checking/unchecking apps that match the given filter
    # When -Exclusive is set, all apps are unchecked first so only matching apps end up selected
    function ApplyPresetToApps {
        param ( 
            [scriptblock]$MatchFilter,
            [bool]$Check,
            [switch]$Exclusive
        )
        # Reset counter before bulk apply; Add_Checked/Unchecked events will still fire
        # but we recalculate the true count in one pass at the end to guarantee accuracy
        $newCount = 0
        foreach ($child in $script:AllAppCheckboxes) {
            if ($Exclusive) {
                $child.IsChecked = (& $MatchFilter $child)
            } elseif (& $MatchFilter $child) {
                $child.IsChecked = $Check
            }
            if ($child.IsChecked) { $newCount++ }
        }
        $script:SelectedAppCount = $newCount
        UpdateAppSelectionStatus
        UpdatePresetStates
    }

    # Update preset checkboxes to reflect checked/indeterminate/unchecked state
    function UpdatePresetStates {
        $script:UpdatingPresets = $true
        try {
            # Helper: count matching and checked apps, set checkbox state
            function SetPresetState($checkbox, [scriptblock]$MatchFilter) {
                $total = 0; $checked = 0
                foreach ($child in $script:AllAppCheckboxes) {
                    if (& $MatchFilter $child) {
                        $total++
                        if ($child.IsChecked) { $checked++ }
                    }
                }
                SetTriStatePresetCheckBoxState -CheckBox $checkbox -Total $total -Selected $checked
            }

            SetPresetState $presetDefaultApps { param($c) $c.SelectedByDefault -eq $true }
            foreach ($jsonCb in $script:JsonPresetCheckboxes) {
                $localIds = $jsonCb.PresetAppIds
                SetPresetState $jsonCb { param($c) (@($c.AppIds) | Where-Object { $localIds -contains $_ }).Count -gt 0 }.GetNewClosure()
            }

            # Last used preset: only update if it's visible (has saved apps)
            if ($presetLastUsed.Visibility -ne 'Collapsed' -and $script:SavedAppIds) {
                SetPresetState $presetLastUsed { param($c) (@($c.AppIds) | Where-Object { $script:SavedAppIds -contains $_ }).Count -gt 0 }
            }
        }
        finally {
            $script:UpdatingPresets = $false
        }
    }

    # Dynamically builds Tweaks UI from Features.json
    function BuildDynamicTweaks {
        $featuresJson = LoadJsonFile -filePath $script:FeaturesFilePath -expectedVersion "1.0"

        if (-not $featuresJson) {
            Show-MessageBox -Message "Unable to load Features.json file!" -Title "Error" -Button 'OK' -Icon 'Error' | Out-Null
            Exit
        }

        # Column containers (2-column matrix layout)
        $col0 = $window.FindName('Column0Panel')
        $col1 = $window.FindName('Column1Panel')
        $columns = @($col0, $col1) | Where-Object { $_ -ne $null }

        # Clear columns for fully dynamic panel creation
        foreach ($col in $columns) {
            if ($col) { $col.Children.Clear() }
        }

        $script:UiControlMappings = @{}
        $script:CategoryCardMap = @{}

        function CreateLabeledCombo($parent, $labelText, $comboName, $items) {
            # If only 2 items (No Change + one option), use a checkbox instead
            if ($items.Count -eq 2) {
                $checkbox = New-Object System.Windows.Controls.CheckBox
                $checkbox.Content = $labelText
                $checkbox.Name = $comboName
                $checkbox.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, $labelText)
                $checkbox.IsChecked = $false
                $checkbox.Style = $window.Resources["FeatureCheckboxStyle"]
                $parent.Children.Add($checkbox) | Out-Null
                
                try {
                    [System.Windows.NameScope]::SetNameScope($checkbox, [System.Windows.NameScope]::GetNameScope($window))
                    $window.RegisterName($comboName, $checkbox)
                } catch {}
                
                return $checkbox
            }
            
            # Segmented Control Container
            $container = New-Object System.Windows.Controls.Border
            $container.Style = $window.Resources['SegmentedGroupContainerStyle']
            $container.Tag = 'MultiOptionContainer'
            
            $innerPanel = New-Object System.Windows.Controls.DockPanel
            $innerPanel.LastChildFill = $false
            $container.Child = $innerPanel
            
            $lbl = New-Object System.Windows.Controls.TextBlock
            $lbl.Text = $labelText
            $lbl.Style = $window.Resources['LabelStyle']
            $lbl.Margin = '0,0,16,0'
            $lbl.VerticalAlignment = 'Center'
            [System.Windows.Controls.DockPanel]::SetDock($lbl, 'Left')
            $innerPanel.Children.Add($lbl) | Out-Null
            
            # Hidden combo box to maintain state compatibility
            $combo = New-Object System.Windows.Controls.ComboBox
            $combo.Name = $comboName
            $combo.Visibility = 'Collapsed'
            foreach ($item in $items) { 
                $comboItem = New-Object System.Windows.Controls.ComboBoxItem
                $comboItem.Content = $item
                $combo.Items.Add($comboItem) | Out-Null 
            }
            $combo.SelectedIndex = 0
            $innerPanel.Children.Add($combo) | Out-Null
            
            try {
                [System.Windows.NameScope]::SetNameScope($combo, [System.Windows.NameScope]::GetNameScope($window))
                $window.RegisterName($comboName, $combo)
            } catch {}
            
            # Visible Segmented Control
            $segmentContainer = New-Object System.Windows.Controls.WrapPanel
            $segmentContainer.Orientation = 'Horizontal'
            $segmentContainer.HorizontalAlignment = 'Right'
            [System.Windows.Controls.DockPanel]::SetDock($segmentContainer, 'Right')
            
            for ($i = 0; $i -lt $items.Count; $i++) {
                $btn = New-Object System.Windows.Controls.RadioButton
                $btn.Content = $items[$i]
                $btn.GroupName = $comboName
                $btn.Style = $window.Resources["SelectionChipStyle"]
                $btn.Margin = '0,0,4,4'
                $btn.Tag = $i
                if ($i -eq 0) { $btn.IsChecked = $true }
                
                # Bi-directional sync: clicking RadioButton updates ComboBox
                $btn.Add_Checked({
                    param($sender, $e)
                    $hiddenCombo = $window.FindName($sender.GroupName)
                    if ($hiddenCombo) { $hiddenCombo.SelectedIndex = $sender.Tag }
                })
                
                $segmentContainer.Children.Add($btn) | Out-Null
            }
            
            # Sync: if ComboBox is updated programmatically, update RadioButtons
            $combo.Add_SelectionChanged({
                param($sender, $e)
                foreach ($child in $segmentContainer.Children) {
                    if ($child.Tag -eq $sender.SelectedIndex) {
                        $child.IsChecked = $true
                        break
                    }
                }
            })
            
            $innerPanel.Children.Add($segmentContainer) | Out-Null
            $parent.Children.Add($container) | Out-Null
            
            return $combo
        }

        function GetOrCreateCategoryCard($categoryObj) {
            $categoryName = $categoryObj.Name
            $categoryIcon = $categoryObj.Icon

            if ($script:CategoryCardMap.ContainsKey($categoryName)) { return $script:CategoryCardMap[$categoryName] }

            $border = New-Object System.Windows.Controls.Border
            $border.Style = $window.Resources['CategoryCardBorderStyle']
            $border.Tag = 'DynamicCategory'

            $panel = New-Object System.Windows.Controls.StackPanel
            $safe = ($categoryName -replace '[^a-zA-Z0-9_]','_')
            $panel.Name = "Category_{0}_Panel" -f $safe

            $headerRow = New-Object System.Windows.Controls.StackPanel
            $headerRow.Orientation = 'Horizontal'

            # Add category icon
            $icon = New-Object System.Windows.Controls.TextBlock
            if ($categoryIcon -match '&#x([0-9A-Fa-f]+);') {
                $hexValue = [Convert]::ToInt32($matches[1], 16)
                $icon.Text = [char]$hexValue
            }
            $icon.Style = $window.Resources['CategoryHeaderIcon']
            $headerRow.Children.Add($icon) | Out-Null

            $header = New-Object System.Windows.Controls.TextBlock
            $header.Text = $categoryName
            $header.Style = $window.Resources['CategoryHeaderTextBlock']
            $headerRow.Children.Add($header) | Out-Null

            $panel.Children.Add($headerRow) | Out-Null
            $border.Child = $panel
            
            # Start everything in Column0 (List mode by default)
            $col0.Children.Add($border) | Out-Null

            $script:CategoryCardMap[$categoryName] = $panel
            return $panel
        }

        # Determine categories present (from lists and features)
        $categoriesPresent = @{}
        if ($featuresJson.UiGroups) {
            foreach ($g in $featuresJson.UiGroups) { if ($g.Category) { $categoriesPresent[$g.Category] = $true } }
        }
        foreach ($f in $featuresJson.Features) { if ($f.Category) { $categoriesPresent[$f.Category] = $true } }

        # Create cards in the order defined in Features.json Categories (if present)
        $orderedCategories = @()
        if ($featuresJson.Categories) {
            foreach ($c in $featuresJson.Categories) {
                $categoryName = if ($c -is [string]) { $c } else { $c.Name }
                if ($categoriesPresent.ContainsKey($categoryName)) {
                    # Store the full category object (or create one with default icon for string categories)
                    $categoryObj = if ($c -is [string]) { @{Name = $c; Icon = '&#xE712;'} } else { $c }
                    $orderedCategories += $categoryObj
                }
            }
        } else {
            # For backward compatibility, create category objects from keys
            foreach ($catName in $categoriesPresent.Keys) {
                $orderedCategories += @{Name = $catName; Icon = '&#xE712;'}
            }
        }

        foreach ($categoryObj in $orderedCategories) {
            $categoryName = $categoryObj.Name
            
            # Create/get card for this category
            $panel = GetOrCreateCategoryCard -categoryObj $categoryObj
            if (-not $panel) { continue }

            # Collect groups and features for this category, then sort by priority
            $categoryItems = @()

            # Add any groups for this category
            if ($featuresJson.UiGroups) {
                $groupIndex = 0
                foreach ($group in $featuresJson.UiGroups) {
                    if ($group.Category -ne $categoryName) { $groupIndex++; continue }
                    $categoryItems += [PSCustomObject]@{
                        Type = 'group'
                        Data = $group
                        Priority = if ($null -ne $group.Priority) { $group.Priority } else { [int]::MaxValue }
                        OriginalIndex = $groupIndex
                    }
                    $groupIndex++
                }
            }

            # Add individual features for this category
            $featureIndex = 0
            foreach ($feature in $featuresJson.Features) {
                if ($feature.Category -ne $categoryName) { $featureIndex++; continue }
                
                # Check version and feature compatibility using Features.json
                if (($feature.MinVersion -and $WinVersion -lt $feature.MinVersion) -or ($feature.MaxVersion -and $WinVersion -gt $feature.MaxVersion) -or ($feature.FeatureId -eq 'DisableModernStandbyNetworking' -and (-not $script:ModernStandbySupported))) {
                    $featureIndex++; continue
                }

                # Skip if feature part of a group
                $inGroup = $false
                if ($featuresJson.UiGroups) {
                    foreach ($g in $featuresJson.UiGroups) { foreach ($val in $g.Values) { if ($val.FeatureIds -contains $feature.FeatureId) { $inGroup = $true; break } }; if ($inGroup) { break } }
                }
                if ($inGroup) { $featureIndex++; continue }

                $categoryItems += [PSCustomObject]@{
                    Type = 'feature'
                    Data = $feature
                    Priority = if ($null -ne $feature.Priority) { $feature.Priority } else { [int]::MaxValue }
                    OriginalIndex = $featureIndex
                }
                $featureIndex++
            }

            # Sort by priority first, then by original index for items with same/no priority
            $sortedItems = $categoryItems | Sort-Object -Property Priority, OriginalIndex

            # Separate items into standard toggles (feature with 2 items) and multi-option groups
            $featureItems = $sortedItems | Where-Object { $_.Type -eq 'feature' }
            $groupItems   = $sortedItems | Where-Object { $_.Type -eq 'group'   }

            # Render standard toggles first
            foreach ($item in $featureItems) {
                $feature = $item.Data
                $opt = 'Apply'
                if ($feature.FeatureId -match '^Disable') { $opt = 'Disable' } elseif ($feature.FeatureId -match '^Enable') { $opt = 'Enable' }
                $items = @('No Change', $opt)
                $comboName = ("Feature_{0}_Combo" -f $feature.FeatureId) -replace '[^a-zA-Z0-9_]',''
                $combo = CreateLabeledCombo -parent $panel -labelText ($feature.Action + ' ' + $feature.Label) -comboName $comboName -items $items
                if ($feature.ToolTip) {
                    $tipBlock = New-Object System.Windows.Controls.TextBlock
                    $tipBlock.Text = $feature.ToolTip
                    $tipBlock.TextWrapping = 'Wrap'
                    $tipBlock.MaxWidth = 420
                    $combo.ToolTip = $tipBlock
                }
                $script:UiControlMappings[$comboName] = @{ Type='feature'; FeatureId = $feature.FeatureId; Action = $feature.Action; Label = $feature.Label; Category = $categoryName }
            }

            # If multi-option groups exist, add a visual subsection divider then render them
            if ($groupItems.Count -gt 0) {
                # Thin separator line
                $sep = New-Object System.Windows.Controls.Separator
                $sep.SetResourceReference([System.Windows.Controls.Separator]::BackgroundProperty, 'BorderColor')
                $sep.Height = 1
                $sep.Margin = '0,10,0,0'
                $panel.Children.Add($sep) | Out-Null

                # "SELECTION OPTIONS" micro-header
                $hdr = New-Object System.Windows.Controls.TextBlock
                $hdr.Text = 'SELECTION OPTIONS'
                $hdr.Style = $window.Resources['MultiOptionSectionHeaderStyle']
                $panel.Children.Add($hdr) | Out-Null

                foreach ($item in $groupItems) {
                    $group = $item.Data
                    $items = @('No Change') + ($group.Values | ForEach-Object { $_.Label })
                    $comboName = 'Group_{0}Combo' -f $group.GroupId
                    $combo = CreateLabeledCombo -parent $panel -labelText $group.Label -comboName $comboName -items $items
                    if ($group.ToolTip) {
                        $tipBlock = New-Object System.Windows.Controls.TextBlock
                        $tipBlock.Text = $group.ToolTip
                        $tipBlock.TextWrapping = 'Wrap'
                        $tipBlock.MaxWidth = 420
                        $combo.ToolTip = $tipBlock
                    }
                    $script:UiControlMappings[$comboName] = @{ Type='group'; Values = $group.Values; Label = $group.Label; Category = $categoryName }
                }
            }
        }

        # Build a feature-label lookup so GenerateOverview can resolve feature IDs without reloading JSON
        $script:FeatureLabelLookup = @{}
        foreach ($f in $featuresJson.Features) {
            $script:FeatureLabelLookup[$f.FeatureId] = $f.Action + ' ' + $f.Label
        }
    }

    # Helper function to load apps and populate the app list panel
    function script:LoadAppsWithList($listOfApps) {
        $script:MainWindowLastSelectedCheckbox = $null

        $loaderScriptPath = $script:LoadAppsDetailsScriptPath
        $appsFilePath  = $script:AppsListFilePath
        $onlyInstalled = [bool]$onlyInstalledAppsBox.IsChecked

        # Use preloaded data if available; otherwise load in background job
        if (-not $onlyInstalled -and $script:PreloadedAppData) {
            $rawAppData = $script:PreloadedAppData
            $script:PreloadedAppData = $null
        } else {
            # Load apps details in a background job to keep the UI responsive
            $rawAppData = Invoke-NonBlocking -ScriptBlock {
                param($loaderScript, $appsListFilePath, $installedList, $onlyInstalled)
                $script:AppsListFilePath = $appsListFilePath
                . $loaderScript
                LoadAppsDetailsFromJson -OnlyInstalled:$onlyInstalled -InstalledList $installedList -InitialCheckedFromJson:$false
            } -ArgumentList $loaderScriptPath, $appsFilePath, $listOfApps, $onlyInstalled
        }

        $appsToAdd = @($rawAppData | Where-Object { $_ -and ($_.AppId -or $_.FriendlyName) } | Sort-Object -Property FriendlyName)

        $loadingAppsIndicator.Visibility = 'Collapsed'

        if ($appsToAdd.Count -eq 0) {
            $window.FindName('DeploymentApplyBtn').IsEnabled = $true
            if ($importConfigBtn) {
                $importConfigBtn.IsEnabled = $true
            }
            return
        }

        $brushSafe    = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#4CAF50')
        $brushUnsafe  = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#F44336')
        $brushDefault = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#FFC107')
        $brushSafe.Freeze(); $brushUnsafe.Freeze(); $brushDefault.Freeze()

        # Initialize flat list for easy search/filter later
        $script:AllAppCheckboxes = @()

        function Get-AppCategory {
            param($AppId, $FriendlyName)
            $id = if ($AppId) { [string]$AppId.ToLower() } else { "" }
            $name = if ($FriendlyName) { [string]$FriendlyName.ToLower() } else { "" }

            if ($id -match 'xbox' -or $name -match 'xbox' -or $id -match 'gaming') { return 'Xbox Apps' }
            if ($id -match '^ad2f1837\.' -or $id -match '^e046963f\.' -or $id -match 'lenovo' -or $id -match 'dell' -or $id -match 'hp') { return 'OEM / Manufacturer Apps' }
            if ($id -match 'king\.com' -or $name -match 'game' -or $id -match 'asphalt' -or $name -match 'casino' -or $name -match 'empire' -or $id -match 'hidden') { return 'Gaming Apps' }
            if ($id -match 'spotify' -or $id -match 'disney' -or $id -match 'netflix' -or $id -match 'hulu' -or $name -match 'plex' -or $id -match 'video' -or $id -match 'audio' -or $name -match 'player' -or $id -match 'music' -or $id -match 'media') { return 'Media Apps' }
            if ($name -match 'paint' -or $name -match 'draw' -or $id -match 'photo' -or $id -match 'clipchamp' -or $id -match 'sketch' -or $id -match 'picsart' -or $id -match '3dbuilder') { return 'Creative Apps' }
            if ($id -match 'print' -or $id -match 'scan' -or $id -match 'calculator' -or $id -match 'clock' -or $id -match 'weather' -or $id -match 'map' -or $id -match 'camera' -or $id -match 'alarm' -or $id -match 'soundrecorder') { return 'Utility Apps' }
            if ($id -match '^microsoft\.' -or $id -match 'microsoftcorporation' -or $name -match 'microsoft') { return 'Microsoft Apps' }
            
            return 'Other Apps'
        }

        # Group apps by category
        $groupedApps = @{}
        foreach ($app in $appsToAdd) {
            $cat = Get-AppCategory -AppId $app.AppId -FriendlyName $app.FriendlyName
            if (-not $groupedApps.ContainsKey($cat)) { $groupedApps[$cat] = @() }
            $groupedApps[$cat] += $app
        }

        $batchSize = 20
        $processedCount = 0

        # Create Category Expanders and Grids
        # Order the categories logically
        $categoryOrder = @('Microsoft Apps', 'Xbox Apps', 'OEM / Manufacturer Apps', 'Gaming Apps', 'Media Apps', 'Creative Apps', 'Utility Apps', 'Other Apps')
        
        foreach ($cat in $categoryOrder) {
            if (-not $groupedApps.ContainsKey($cat)) { continue }
            
            $expander = New-Object System.Windows.Controls.Expander
            $expander.Header = $cat
            $expander.IsExpanded = $true
            $expander.Style = $window.Resources['AppCategoryExpanderStyle']
            
            $wrapPanel = New-Object System.Windows.Controls.WrapPanel
            $wrapPanel.Orientation = 'Horizontal'
            
            foreach ($app in $groupedApps[$cat]) {
                $checkbox = New-Object System.Windows.Controls.CheckBox
                $automationName = if ($app.FriendlyName) { $app.FriendlyName } elseif ($app.AppIdDisplay) { $app.AppIdDisplay } else { $null }
                if ($automationName) { $checkbox.SetValue([System.Windows.Automation.AutomationProperties]::NameProperty, $automationName) }
                $checkbox.Tag       = $app.AppIdDisplay
                $checkbox.IsChecked = $app.IsChecked
                $checkbox.Style     = $window.Resources['AppMatrixCardStyle']

                # Build vertical card content inside the CheckBox
                $cardStack = New-Object System.Windows.Controls.StackPanel
                $cardStack.Margin = [System.Windows.Thickness]::new(0,0,0,0)

                $titleStack = New-Object System.Windows.Controls.StackPanel
                $titleStack.Orientation = 'Horizontal'
                $titleStack.Margin = [System.Windows.Thickness]::new(0,0,0,4)

                $dot = New-Object System.Windows.Shapes.Ellipse
                $dot.Style = $window.Resources['AppRecommendationDotStyle']
                $dot.Fill  = switch ($app.Recommendation) { 'safe' { $brushSafe } 'unsafe' { $brushUnsafe } default { $brushDefault } }
                $dot.ToolTip = switch ($app.Recommendation) {
                    'safe'   { '[Recommended] Safe to remove for most users' }
                    'unsafe' { '[Not Recommended] Only remove if you know what you are doing' }
                    default  { "[Optional] Remove if you don't need this app" }
                }
                $dot.Margin = [System.Windows.Thickness]::new(0,1,6,0)

                $tbName = New-Object System.Windows.Controls.TextBlock
                $tbName.Text  = $app.FriendlyName
                $tbName.Style = $window.Resources['AppNameTextStyle']
                $tbName.TextWrapping = 'Wrap'
                $tbName.MaxWidth = 180
                
                $titleStack.Children.Add($dot) | Out-Null
                $titleStack.Children.Add($tbName) | Out-Null
                
                $tbDesc = New-Object System.Windows.Controls.TextBlock
                $tbDesc.Text    = $app.Description
                $tbDesc.Style   = $window.Resources['AppDescTextStyle']
                $tbDesc.ToolTip = $app.Description
                $tbDesc.TextWrapping = 'Wrap'
                $tbDesc.MaxHeight = 35
                $tbDesc.TextTrimming = 'CharacterEllipsis'
                
                $cardStack.Children.Add($titleStack) | Out-Null
                $cardStack.Children.Add($tbDesc) | Out-Null
                
                $checkbox.Content = $cardStack

                Add-Member -InputObject $checkbox -MemberType NoteProperty -Name 'AppName'          -Value $app.FriendlyName
                Add-Member -InputObject $checkbox -MemberType NoteProperty -Name 'AppDescription'   -Value $app.Description
                Add-Member -InputObject $checkbox -MemberType NoteProperty -Name 'SelectedByDefault' -Value $app.SelectedByDefault
                Add-Member -InputObject $checkbox -MemberType NoteProperty -Name 'AppIds' -Value @($app.AppId)
                Add-Member -InputObject $checkbox -MemberType NoteProperty -Name 'AppIdDisplay' -Value $app.AppIdDisplay

                # Cache lowercase search strings once at creation
                Add-Member -InputObject $checkbox -MemberType NoteProperty -Name 'SearchKey' -Value ("$($app.FriendlyName) $($app.Description) $($app.AppIdDisplay)".ToLower())

                $checkbox.Add_Checked({ 
                    $script:SelectedAppCount++
                    UpdateAppSelectionStatus 
                })
                $checkbox.Add_Unchecked({ 
                    $script:SelectedAppCount--
                    UpdateAppSelectionStatus 
                })
                
                # NOTE: UpdatePresetStates is intentionally NOT called here per-click.
                # It runs after bulk loads (LoadAppsWithList) and preset Apply operations.
                # Calling it on every individual checkbox click caused O(n*presets) freezes.
                
                AttachShiftClickBehavior -checkbox $checkbox -appsPanel $wrapPanel `
                    -lastSelectedCheckboxRef ([ref]$script:MainWindowLastSelectedCheckbox) `
                    -updateStatusCallback { UpdateAppSelectionStatus }

                $wrapPanel.Children.Add($checkbox) | Out-Null
                $script:AllAppCheckboxes += $checkbox

                $processedCount++
                if ($processedCount % $batchSize -eq 0) { DoEvents }
            }
            
            $expander.Content = $wrapPanel
            $appCategoryContainer.Children.Add($expander) | Out-Null
        }

        # If Default Mode was clicked while apps were still loading, apply defaults now
        if ($script:PendingDefaultMode) {
            $script:PendingDefaultMode = $false
            ApplyPresetToApps -MatchFilter { param($c) $c.SelectedByDefault -eq $true } -Exclusive
        }
        
        # Sync running counter with final loaded state
        $script:SelectedAppCount = 0
        foreach ($checkbox in $script:AllAppCheckboxes) {
            if ($checkbox.IsChecked) { $script:SelectedAppCount++ }
        }
        UpdateAppSelectionStatus
        
        # After apps have loaded, update the preset chips to reflect reality
        UpdatePresetStates

        # Re-enable Apply button now that the full, correctly-checked app list is ready
        $window.FindName('DeploymentApplyBtn').IsEnabled = $true
        if ($importConfigBtn) {
            $importConfigBtn.IsEnabled = $true
        }
    }

    # Loads apps into the UI
    function LoadAppsIntoMainUI {
        # Prevent concurrent loads
        if ($script:IsLoadingApps) { return }
        $script:IsLoadingApps = $true

        if ($importConfigBtn) {
            $importConfigBtn.IsEnabled = $false
        }

        # Show loading indicator and clear existing apps
        $loadingAppsIndicator.Visibility = 'Visible'
        $appCategoryContainer.Children.Clear()

        # Disable Apply button while apps are loading so it can't be clicked with a partial list
        $window.FindName('DeploymentApplyBtn').IsEnabled = $false

        # Force a render so the loading indicator is visible, then schedule the
        # actual loading at Background priority so this call returns immediately.
        # This is critical when called from Add_Loaded: the window must finish
        # its initialization before we start a nested message pump via DoEvents.
        $window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [action]{})
        $window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
            try {
                $listOfApps = ""

                if ($onlyInstalledAppsBox.IsChecked -and ($script:WingetInstalled -eq $true)) {
                    $listOfApps = GetInstalledAppsViaWinget -TimeOut 10 -NonBlocking

                    if ($null -eq $listOfApps) {
                        Show-MessageBox -Message 'Unable to load list of installed apps via WinGet.' -Title 'Error' -Button 'OK' -Icon 'Error' | Out-Null
                        $onlyInstalledAppsBox.IsChecked = $false
                    }
                }

                LoadAppsWithList $listOfApps
            }
            finally {
                $script:IsLoadingApps = $false
                # Ensure the WHS execution trigger is re-enabled once background loading completes
                $window.Dispatcher.Invoke([action]{
                    $window.FindName('DeploymentApplyBtn').IsEnabled = $true
                    if ($importConfigBtn) { $importConfigBtn.IsEnabled = $true }
                })
            }
        }) | Out-Null
    }

    # Event handlers for app selection
    $onlyInstalledAppsBox.Add_Checked({
        LoadAppsIntoMainUI
    })

    $onlyInstalledAppsBox.Add_Unchecked({
        LoadAppsIntoMainUI
    })

    # Preset chips are always visible — update their state whenever the Apps view is shown
    # (previously done lazily inside Popup.Opened; now done on nav)
    # (navAppsBtn.Add_Checked wires this below in navigation section)

    foreach ($presetCheckBox in @(
        $presetDefaultApps,
        $presetLastUsed,
        $presetDefaultTweaksBtn,
        $presetLastUsedTweaksBtn,
        $presetPrivacyTweaksBtn,
        $presetAITweaksBtn
    )) {
        AttachTriStateClickBehavior -checkBox $presetCheckBox
    }

    # Preset: Default selection
    $presetDefaultApps.Add_Click({
        if ($script:UpdatingPresets) { return }
        $check = NormalizeCheckboxState -checkBox $this
        ApplyPresetToApps -MatchFilter { param($c) $c.SelectedByDefault -eq $true } -Check $check
    })

    # Clear selection button + reset all preset checkboxes
    $clearAppSelectionBtn.Add_Click({
        ApplyPresetToApps -MatchFilter { param($c) $true } -Check $false
    })


    # Helper function to scroll to an item if it's not visible, centering it in the viewport
    function ScrollToItemIfNotVisible {
        param (
            [System.Windows.Controls.ScrollViewer]$scrollViewer,
            [System.Windows.UIElement]$item,
            [System.Windows.UIElement]$container
        )
        
        if (-not $scrollViewer -or -not $item -or -not $container) { return }
        
        try {
            $itemPosition = $item.TransformToAncestor($container).Transform([System.Windows.Point]::new(0, 0)).Y
            $viewportHeight = $scrollViewer.ViewportHeight
            $itemHeight = $item.ActualHeight
            $currentOffset = $scrollViewer.VerticalOffset
            
            # Check if the item is currently visible in the viewport
            $itemTop = $itemPosition - $currentOffset
            $itemBottom = $itemTop + $itemHeight
            
            $isVisible = ($itemTop -ge 0) -and ($itemBottom -le $viewportHeight)
            
            # Only scroll if the item is not visible
            if (-not $isVisible) {
                # Center the item in the viewport
                $targetOffset = $itemPosition - ($viewportHeight / 2) + ($itemHeight / 2)
                $scrollViewer.ScrollToVerticalOffset([Math]::Max(0, $targetOffset))
            }
        }
        catch {
            # Fallback to simple bring into view
            $item.BringIntoView()
        }
    }
    
    # Helper function to find the parent ScrollViewer of an element
    function FindParentScrollViewer {
        param ([System.Windows.UIElement]$element)
        
        $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($element)
        while ($null -ne $parent) {
            if ($parent -is [System.Windows.Controls.ScrollViewer]) {
                return $parent
            }
            $parent = [System.Windows.Media.VisualTreeHelper]::GetParent($parent)
        }
        return $null
    }

    # App Search Box functionality
    $appSearchBox = $window.FindName('AppSearchBox')
    $appSearchPlaceholder = $window.FindName('AppSearchPlaceholder')
    
    # Track current search matches and active index for Enter-key navigation
    $script:AppSearchMatches = @()
    $script:AppSearchMatchIndex = -1
    
    $appSearchBox.Add_TextChanged({
        $searchText = $appSearchBox.Text.ToLower().Trim()
        
        # Show/hide placeholder
        $appSearchPlaceholder.Visibility = if ([string]::IsNullOrWhiteSpace($appSearchBox.Text)) { 'Visible' } else { 'Collapsed' }
        
        $script:AppSearchMatches = @()
        $script:AppSearchMatchIndex = -1
        
        if ([string]::IsNullOrWhiteSpace($searchText)) {
            # Restore all expanders visibility — no per-card resets needed
            foreach ($expander in $appCategoryContainer.Children) {
                if ($expander -is [System.Windows.Controls.Expander]) {
                    $expander.Visibility = 'Visible'
                }
            }
            return
        }
        
        # Cache the two highlight brushes (resolved once per search event)
        $highlightBrush      = $window.Resources["SearchHighlightColor"]
        $activeHighlightBrush = $window.Resources["SearchHighlightActiveColor"]
        
        # Build a fast map: expander → has any match (avoid VisualTree walks per card)
        $expanderHasMatch = @{}
        
        # Pre-compute the expander for each category WrapPanel once
        # using the logical tree: AppCategoryContainer > Expander > WrapPanel > CheckBox
        $checkboxToExpander = @{}
        foreach ($expander in $appCategoryContainer.Children) {
            if ($expander -is [System.Windows.Controls.Expander] -and
                $expander.Content -is [System.Windows.Controls.Panel]) {
                foreach ($cb in $expander.Content.Children) {
                    if ($cb -is [System.Windows.Controls.CheckBox]) {
                        $checkboxToExpander[$cb] = $expander
                    }
                }
            }
        }
        
        foreach ($child in $script:AllAppCheckboxes) {
            if ($child.SearchKey.Contains($searchText)) {
                $script:AppSearchMatches += $child
                $exp = $checkboxToExpander[$child]
                if ($exp) { $expanderHasMatch[$exp] = $true }
            }
        }
        
        # Show/hide Expanders based on match presence
        foreach ($expander in $appCategoryContainer.Children) {
            if ($expander -is [System.Windows.Controls.Expander]) {
                $expander.Visibility = if ($expanderHasMatch[$expander]) { 'Visible' } else { 'Collapsed' }
            }
        }
        
        # Scroll to and visually mark the first match
        if ($script:AppSearchMatches.Count -gt 0) {
            $script:AppSearchMatchIndex = 0
            $scrollViewer = FindParentScrollViewer -element $appCategoryContainer
            if ($scrollViewer) {
                ScrollToItemIfNotVisible -scrollViewer $scrollViewer -item $script:AppSearchMatches[0] -container $appCategoryContainer
            }
        }
    })
    
    $appSearchBox.Add_KeyDown({
        param($sourceControl, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Enter -and $script:AppSearchMatches.Count -gt 0) {
            # Reset background of current active match
            $script:AppSearchMatches[$script:AppSearchMatchIndex].Background = $window.Resources["SearchHighlightColor"]
            # Advance to next match (wrapping)
            $script:AppSearchMatchIndex = ($script:AppSearchMatchIndex + 1) % $script:AppSearchMatches.Count
            # Highlight new active match
            $script:AppSearchMatches[$script:AppSearchMatchIndex].Background = $window.Resources["SearchHighlightActiveColor"]
            $scrollViewer = FindParentScrollViewer -element $appCategoryContainer
            if ($scrollViewer) {
                ScrollToItemIfNotVisible -scrollViewer $scrollViewer -item $script:AppSearchMatches[$script:AppSearchMatchIndex] -container $appCategoryContainer
            }
            $e.Handled = $true
        }
    })

    # Tweak Search Box functionality
    $tweakSearchBox = $window.FindName('TweakSearchBox')
    $tweakSearchPlaceholder = $window.FindName('TweakSearchPlaceholder')
    $tweakSearchBorder = $window.FindName('TweakSearchBorder')
    $tweaksScrollViewer = $window.FindName('TweaksScrollViewer')
    $tweaksGrid = $window.FindName('TweaksGrid')
    $col0 = $window.FindName('Column0Panel')
    $col1 = $window.FindName('Column1Panel')
    $col2 = $window.FindName('Column2Panel')
    
    # Monitor scrollbar visibility and adjust searchbar margin
    $tweaksScrollViewer.Add_ScrollChanged({
        if ($tweaksScrollViewer.ScrollableHeight -gt 0) {
            # The 17px accounts for the scrollbar width + some padding
            $tweakSearchBorder.Margin = [System.Windows.Thickness]::new(0, 0, 17, 0)
        } else {
            $tweakSearchBorder.Margin = [System.Windows.Thickness]::new(0)
        }
    })
    
    # Helper function to clear all tweak highlights
    function ClearTweakHighlights {
        $columns = @($col0, $col1, $col2) | Where-Object { $_ -ne $null }
        foreach ($column in $columns) {
            foreach ($card in $column.Children) {
                if ($card -is [System.Windows.Controls.Border] -and $card.Child -is [System.Windows.Controls.StackPanel]) {
                    foreach ($control in $card.Child.Children) {
                        if ($control -is [System.Windows.Controls.CheckBox] -or 
                            ($control -is [System.Windows.Controls.Border] -and $control.Name -like '*_LabelBorder')) {
                            $control.Background = [System.Windows.Media.Brushes]::Transparent
                        }
                    }
                }
            }
        }
    }
    
    # Helper function to check if a ComboBox contains matching items
    function ComboBoxContainsMatch {
        param ([System.Windows.Controls.ComboBox]$comboBox, [string]$searchText)
        
        foreach ($item in $comboBox.Items) {
            $itemText = if ($item -is [System.Windows.Controls.ComboBoxItem]) { $item.Content.ToString().ToLower() } else { $item.ToString().ToLower() }
            if ($itemText.Contains($searchText)) { return $true }
        }
        return $false
    }
    
    $tweakSearchBox.Add_TextChanged({
        $searchText = $tweakSearchBox.Text.ToLower().Trim()
        
        # Show/hide placeholder
        $tweakSearchPlaceholder.Visibility = if ([string]::IsNullOrWhiteSpace($tweakSearchBox.Text)) { 'Visible' } else { 'Collapsed' }
        
        # Clear all highlights
        ClearTweakHighlights
        
        if ([string]::IsNullOrWhiteSpace($searchText)) { return }
        
        # Find and highlight all matching tweaks
        $firstMatch = $null
        $highlightBrush = $window.Resources["SearchHighlightColor"]
        $columns = @($col0, $col1, $col2) | Where-Object { $_ -ne $null }
        
        foreach ($column in $columns) {
            foreach ($card in $column.Children) {
                if ($card -is [System.Windows.Controls.Border] -and $card.Child -is [System.Windows.Controls.StackPanel]) {
                    $controlsList = @($card.Child.Children)
                    for ($i = 0; $i -lt $controlsList.Count; $i++) {
                        $control = $controlsList[$i]
                        $matchFound = $false
                        $controlToHighlight = $null
                        
                        if ($control -is [System.Windows.Controls.CheckBox]) {
                            if ($control.Content.ToString().ToLower().Contains($searchText)) {
                                $matchFound = $true
                                $controlToHighlight = $control
                            }
                        }
                        elseif ($control -is [System.Windows.Controls.Border] -and $control.Name -like '*_LabelBorder') {
                            $labelText = if ($control.Child) { $control.Child.Text.ToLower() } else { "" }
                            $comboBox = if ($i + 1 -lt $controlsList.Count -and $controlsList[$i + 1] -is [System.Windows.Controls.ComboBox]) { $controlsList[$i + 1] } else { $null }
                            
                            # Check label text or combo box items
                            if ($labelText.Contains($searchText) -or ($comboBox -and (ComboBoxContainsMatch -comboBox $comboBox -searchText $searchText))) {
                                $matchFound = $true
                                $controlToHighlight = $control
                            }
                        }
                        
                        if ($matchFound -and $controlToHighlight) {
                            $controlToHighlight.Background = $highlightBrush
                            if ($null -eq $firstMatch) { $firstMatch = $controlToHighlight }
                        }
                    }
                }
            }
        }
        
        # Scroll to first match if not visible
        if ($firstMatch -and $tweaksScrollViewer) {
            ScrollToItemIfNotVisible -scrollViewer $tweaksScrollViewer -item $firstMatch -container $tweaksGrid
        }
    })

    # Add Ctrl+F keyboard shortcut to focus search box on current tab
    $window.Add_PreviewKeyDown({
        param($sourceControl, $e)
        
        # Check if Ctrl+F was pressed
        if ($e.Key -eq [System.Windows.Input.Key]::F -and 
            ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control)) {
            
            # Focus AppSearchBox if on App Removal view
            if ($navAppsBtn.IsChecked -eq $true -and $appSearchBox) {
                $appSearchBox.Focus()
                $appSearchBox.SelectAll()
                $e.Handled = $true
            }
            # Focus TweakSearchBox if on Tweaks view
            elseif ($navTweaksBtn.IsChecked -eq $true -and $tweakSearchBox) {
                $tweakSearchBox.Focus()
                $tweakSearchBox.SelectAll()
                $e.Handled = $true
            }
        }
    })

    # Wizard Navigation
    # ── Execution Settings UI references ──────────────────────────────────────
    $userSelectionDescription   = $window.FindName('UserSelectionDescription')
    $otherUserPanel             = $window.FindName('OtherUserPanel')
    $otherUsernameTextBox       = $window.FindName('OtherUsernameTextBox')
    $usernameTextBoxPlaceholder = $window.FindName('UsernameTextBoxPlaceholder')
    $usernameValidationMessage  = $window.FindName('UsernameValidationMessage')
    $appRemovalScopeDescription = $window.FindName('AppRemovalScopeDescription')
    $appRemovalScopeSection     = $window.FindName('AppRemovalScopeSection')
    $inlineOverviewPanel        = $window.FindName('InlineOverviewPanel')

    # ── Chip RadioButton wiring for UserSelection ──────────────────────────────
    $userSelectionChip0  = $window.FindName('UserSelectionChip0')
    $userSelectionChip1    = $window.FindName('UserSelectionChip1')
    $userSelectionChip2  = $window.FindName('UserSelectionChip2')


    # Adapter object: exposes .SelectedIndex (get/set) so Show-ConfigWindow.ps1 keeps working unchanged
    $userSelectionCombo = [PSCustomObject]@{ _chips = @($userSelectionChip0, $userSelectionChip1, $userSelectionChip2) }
    $userSelectionCombo | Add-Member -MemberType ScriptProperty -Name SelectedIndex -Value {
        for ($i = 0; $i -lt $this._chips.Count; $i++) {
            if ($this._chips[$i].IsChecked) { return $i }
        }
        return -1
    } -SecondValue {
        param($val)
        for ($i = 0; $i -lt $this._chips.Count; $i++) {
            $this._chips[$i].IsChecked = ($i -eq $val)
        }
    }
    $userSelectionCombo | Add-Member -MemberType ScriptProperty -Name IsEnabled -Value {
        $this._chips[0].IsEnabled
    } -SecondValue {
        param($v)
        for ($i = 0; $i -lt $this._chips.Count; $i++) {
            $this._chips[$i].IsEnabled = [bool]$v
        }
    }

    function ApplyUserSelectionChange {
        $idx = $userSelectionCombo.SelectedIndex
        $userSelectionDescription.Text = switch ($idx) {
            0 { "Changes will be applied to the currently logged-in user profile." }
            1 { "Changes will be applied to a different user profile on this system." }
            2 { "Changes will be applied to the default user template, affecting all new users created after this point. Useful for Sysprep deployment." }
            default { "" }
        }
        $otherUserPanel.Visibility = if ($idx -eq 1) { 'Visible' } else { 'Collapsed' }
        $usernameValidationMessage.Text = ""

        if ($idx -eq 0) {
            $appRemovalScopeChip1.Visibility = 'Visible'
            $appRemovalScopeChip2.Visibility  = 'Collapsed'
            $appRemovalScopeCombo.IsEnabled    = $true
            if ($appRemovalScopeCombo.SelectedIndex -eq 2) { $appRemovalScopeCombo.SelectedIndex = 0 }
        }
        elseif ($idx -eq 1) {
            $appRemovalScopeChip1.Visibility = 'Collapsed'
            $appRemovalScopeChip2.Visibility  = 'Visible'
            $appRemovalScopeCombo.IsEnabled    = $true
            if ($appRemovalScopeCombo.SelectedIndex -eq 1) { $appRemovalScopeCombo.SelectedIndex = 0 }
        }
        elseif ($idx -eq 2) {
            $appRemovalScopeChip1.Visibility = 'Collapsed'
            $appRemovalScopeChip2.Visibility  = 'Collapsed'
            $appRemovalScopeCombo.IsEnabled    = $false
            $appRemovalScopeCombo.SelectedIndex = 0
        }
    }

    foreach ($chip in @($userSelectionChip0, $userSelectionChip1, $userSelectionChip2)) {
        $chip.Add_Checked({ ApplyUserSelectionChange })
        # CLICK-TO-UNCHECK
        $chip.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            if ($s.IsChecked) {
                $s.IsChecked = $false
                ApplyUserSelectionChange
                $e.Handled = $true
            }
        })
    }

    # ── Chip RadioButton wiring for AppRemovalScope ────────────────────────────
    $appRemovalScopeChip0 = $window.FindName('AppRemovalScopeChip0')
    $appRemovalScopeChip1 = $window.FindName('AppRemovalScopeChip1')
    $appRemovalScopeChip2 = $window.FindName('AppRemovalScopeChip2')

    # Adapter object: exposes .SelectedIndex and .SelectedItem.Content for backend compat
    $appRemovalScopeCombo = [PSCustomObject]@{ _chips = @($appRemovalScopeChip0, $appRemovalScopeChip1, $appRemovalScopeChip2) }
    $appRemovalScopeCombo | Add-Member -MemberType ScriptProperty -Name SelectedIndex -Value {
        for ($i = 0; $i -lt $this._chips.Count; $i++) {
            if ($this._chips[$i].IsChecked) { return $i }
        }
        return -1
    } -SecondValue {
        param($val)
        for ($i = 0; $i -lt $this._chips.Count; $i++) {
            $this._chips[$i].IsChecked = ($i -eq $val)
        }
    }
    $appRemovalScopeCombo | Add-Member -MemberType ScriptProperty -Name IsEnabled -Value {
        $this._chips[0].IsEnabled
    } -SecondValue {
        param($v)
        for ($i = 0; $i -lt $this._chips.Count; $i++) {
            $this._chips[$i].IsEnabled = [bool]$v
        }
    }

    function ApplyAppRemovalScopeChange {
        $idx = $appRemovalScopeCombo.SelectedIndex
        $appRemovalScopeDescription.Text = switch ($idx) {
            0 { "Apps will be removed for all users and from the Windows image to prevent reinstallation for new users." }
            1 { "Apps will be removed for the currently logged-in user profile." }
            2 { "Apps will be removed for the targeted user profile." }
            default { "" }
        }
    }

    foreach ($chip in @($appRemovalScopeChip0, $appRemovalScopeChip1, $appRemovalScopeChip2)) {
        $chip.Add_Checked({ ApplyAppRemovalScopeChange })
        $chip.Add_PreviewMouseLeftButtonDown({
            param($s, $e)
            if ($s.IsChecked) {
                $s.IsChecked = $false
                ApplyAppRemovalScopeChange
                $e.Handled = $true
            }
        })
    }

    # Click-to-toggle logic is now handled in the adapter loops above

    # --- Navigation Bindings ---
    $navHomeBtn    = $window.FindName('NavHomeBtn')
    $navAppsBtn    = $window.FindName('NavAppsBtn')
    $navTweaksBtn  = $window.FindName('NavTweaksBtn')
    $navExecuteBtn = $window.FindName('NavExecuteBtn')

    # Content Views
    $homeView = $window.FindName('HomeView')
    $appsView = $window.FindName('AppsView')
    $tweaksView = $window.FindName('TweaksView')
    $executeView = $window.FindName('DeployView')

    # Routing Function
    $allViews = @($homeView, $appsView, $tweaksView, $executeView)
    function Switch-View ($targetView) {
        foreach ($view in $allViews) {
            if ($view) { $view.Visibility = 'Collapsed' }
        }
        if ($targetView) { $targetView.Visibility = 'Visible' }
    }

    # Attach Events to RadioButtons
    $navHomeBtn.Add_Checked({ Switch-View $homeView })
    $navAppsBtn.Add_Checked({ 
        Switch-View $appsView 
        # Lazy load the app profile to prevent blocking the initial WHS execution flow
        if ($appCategoryContainer.Children.Count -eq 0 -and -not $script:IsLoadingApps) {
            LoadAppsIntoMainUI
        }
        # Update preset chip states (was done lazily in Popup.Opened; now done on nav)
        UpdatePresetStates
    })
    $navTweaksBtn.Add_Checked({
        Switch-View $tweaksView
        # Update tweak preset chip states
        UpdateTweakPresetStates
    })
    
    # --- Routing Logic ---
    $navExecuteBtn.Add_Checked({ 
        Switch-View $executeView 
        UpdateInlineOverview # Ensures the manifest side-panel is current
    })

    # (UserSelection and AppRemovalScope change handlers are wired above via Add_Checked on chips)

    $otherUsernameTextBox.Add_TextChanged({
        # Show/hide placeholder
        if ([string]::IsNullOrWhiteSpace($otherUsernameTextBox.Text)) {
            $usernameTextBoxPlaceholder.Visibility = 'Visible'
        } else {
            $usernameTextBoxPlaceholder.Visibility = 'Collapsed'
        }
        
        ValidateOtherUsername
    })

    function ValidateOtherUsername {
        # Only validate if "Other User" is selected
        if ($userSelectionCombo.SelectedIndex -ne 1) {
            return $true
        }

        $username = $otherUsernameTextBox.Text.Trim()

        $errorBrush   = $window.Resources['ValidationErrorColor']
        $successBrush = $window.Resources['ValidationSuccessColor']

        if ($username.Length -eq 0) {
            $usernameValidationMessage.Text = "Please enter a username"
            $usernameValidationMessage.Foreground = $errorBrush
            return $false
        }
        
        if ($username -eq $env:USERNAME) {
            $usernameValidationMessage.Text = "Cannot enter your own username, use 'Current User' option instead"
            $usernameValidationMessage.Foreground = $errorBrush
            return $false
        }
        
        $userExists = CheckIfUserExists -Username $username

        if ($userExists) {
            if (TestIfUserIsLoggedIn -Username $username) {
                $usernameValidationMessage.Text = "User '$username' is currently logged in. Please sign out that user first."
                $usernameValidationMessage.Foreground = $errorBrush
                return $false
            }

            $usernameValidationMessage.Text = "User found: $username"
            $usernameValidationMessage.Foreground = $successBrush
            return $true
        }

        $usernameValidationMessage.Text = "User not found, please enter a valid username"
        $usernameValidationMessage.Foreground = $errorBrush
        return $false
    }

    function GenerateOverview {
        $changesList = @()
        
        # Collect selected apps
        $selectedAppsCount = 0
        if ($script:AllAppCheckboxes) {
            foreach ($checkbox in $script:AllAppCheckboxes) {
                if ($checkbox.IsChecked) {
                    $selectedAppsCount++
                }
            }
        }
        if ($selectedAppsCount -gt 0) {
            $changesList += "Remove $selectedAppsCount application(s)"
        }
        
        # Update app removal scope section based on whether apps are selected
        if ($selectedAppsCount -gt 0) {
            # Enable app removal scope selection (unless locked by sysprep mode)
            if ($userSelectionCombo.SelectedIndex -ne 2) {
                $appRemovalScopeCombo.IsEnabled = $true
            }
            ApplyAppRemovalScopeChange
        }
        else {
            # Set description when no apps selected
            $appRemovalScopeDescription.Text = "No apps selected for removal."
        }
        
        # Collect all ComboBox/CheckBox selections from dynamically created controls
        if ($script:UiControlMappings) {
            foreach ($mappingKey in $script:UiControlMappings.Keys) {
                $control = $window.FindName($mappingKey)
                $isSelected = $false
                
                # Check if it's a checkbox or combobox
                if ($control -is [System.Windows.Controls.CheckBox]) {
                    $isSelected = $control.IsChecked -eq $true
                }
                elseif ($control -is [System.Windows.Controls.ComboBox]) {
                    $isSelected = $control.SelectedIndex -gt 0
                }
                
                if ($control -and $isSelected) {
                    $mapping = $script:UiControlMappings[$mappingKey]
                    if ($mapping.Type -eq 'group') {
                        # For combobox: SelectedIndex 0 = No Change, so subtract 1 to index into Values
                        $selectedValue = $mapping.Values[$control.SelectedIndex - 1]
                        foreach ($fid in $selectedValue.FeatureIds) {
                            $label = $script:FeatureLabelLookup[$fid]
                            if ($label) { $changesList += $label }
                        }
                    }
                    elseif ($mapping.Type -eq 'feature') {
                        $label = $script:FeatureLabelLookup[$mapping.FeatureId]
                        if (-not $label) { $label = $mapping.Action + ' ' + $mapping.Label }
                        $changesList += $label
                    }
                }
            }
        }
        
        return $changesList
    }

    function UpdateInlineOverview {
        $changesList = GenerateOverview

        # Clear previous list
        $inlineOverviewPanel.Children.Clear()

        if ($changesList.Count -eq 0) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "No changes selected."
            $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "FgColor")
            $tb.Opacity = 0.5
            $tb.FontStyle = [System.Windows.FontStyles]::Italic
            $tb.FontSize = 13
            $tb.Margin = "0,2,0,2"
            $inlineOverviewPanel.Children.Add($tb) | Out-Null
            return
        }

        # Populate with actual changes
        foreach ($change in $changesList) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.Text = "$([char]0x2022) $change"
            $tb.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, "FgColor")
            $tb.Opacity = 0.8
            $tb.FontSize = 13
            $tb.Margin = "0,3,0,3"
            $tb.TextWrapping = "Wrap"
            $inlineOverviewPanel.Children.Add($tb) | Out-Null
        }
    }

    # --- Hero Cards (Home Page) ---
    $homeStartBtn = $window.FindName('HomeStartBtn')
    $homeStartAction = {
        $navAppsBtn.IsChecked = $true
    }
    if ($homeStartBtn) { $homeStartBtn.Add_Click($homeStartAction) }

    $homeDefaultModeBtn = $window.FindName('HomeDefaultModeBtn')
    $homeDefaultAction = {
        $defaultsJson = LoadJsonFile -filePath $script:DefaultSettingsFilePath -expectedVersion "1.0"
        if ($defaultsJson) {
            ApplySettingsToUiControls -window $window -settingsJson $defaultsJson -uiControlMappings $script:UiControlMappings
        }
        if ($script:IsLoadingApps) {
            $script:PendingDefaultMode = $true
        } else {
            ApplyPresetToApps -MatchFilter { param($c) $c.SelectedByDefault -eq $true } -Exclusive
        }
        $navExecuteBtn.IsChecked = $true
    }
    if ($homeDefaultModeBtn) { $homeDefaultModeBtn.Add_Click($homeDefaultAction) }

    # Helper to find elements if the standard FindName fails
    function Get-WpfElement {
        param($Name)
        $element = $window.FindName($Name)
        if ($null -eq $element) {
            # Fallback: Manual logical tree search
            $window.InternalChildren | ForEach-Object { if ($_.Name -eq $Name) { $element = $_ } }
        }
        return $element
    }

    function Update-TweaksViewMode {
        $col0 = $window.FindName('Column0Panel')
        $col1 = $window.FindName('Column1Panel')
        $col1Def = $window.FindName('TweaksCol1Def')
        
        $listBtn = $window.FindName('ViewModeListBtn')
        if (-not $listBtn) { return }
        $isListMode = ($listBtn.IsChecked -eq $true)
        
        if ($isListMode) {
            $col1Def.Width = [System.Windows.GridLength]::new(0)
            
            $childrenToMove = @()
            foreach ($child in $col1.Children) { $childrenToMove += $child }
            foreach ($child in $childrenToMove) {
                $col1.Children.Remove($child)
                $col0.Children.Add($child) | Out-Null
            }
        } else {
            $col1Def.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
            
            $allChildren = @()
            foreach ($child in $col0.Children) { $allChildren += $child }
            foreach ($child in $col1.Children) { $allChildren += $child }
            
            $col0.Children.Clear()
            $col1.Children.Clear()
            
            foreach ($child in $allChildren) {
                $categoryName = ''
                if ($child -is [System.Windows.Controls.Border]) {
                    $innerPanel = $child.Child
                    if ($innerPanel) {
                        $categoryName = $innerPanel.Name -replace '^Category_','' -replace '_Panel$',''
                    }
                }
                
                if ($categoryName -match 'Multi_tasking|Other') {
                    $col0.Children.Add($child) | Out-Null
                } else {
                    $target = if ($col0.Children.Count -le $col1.Children.Count) { $col0 } else { $col1 }
                    $target.Children.Add($child) | Out-Null
                }
            }
        }

        # Update responsive layout for multi-option chips
        $allCards = @()
        foreach ($child in $col0.Children) { $allCards += $child }
        foreach ($child in $col1.Children) { $allCards += $child }

        foreach ($card in $allCards) {
            if ($card -is [System.Windows.Controls.Border] -and $card.Child) {
                $panel = $card.Child
                foreach ($child in $panel.Children) {
                    if ($child -is [System.Windows.Controls.Border] -and $child.Tag -eq 'MultiOptionContainer') {
                        $dp = $child.Child
                        # dp.Children[0] is the TextBlock Label, dp.Children[2] is the WrapPanel holding the chips
                        if ($isListMode) {
                            [System.Windows.Controls.DockPanel]::SetDock($dp.Children[0], 'Left')
                            $dp.Children[0].Margin = '0,0,16,0'
                            $dp.Children[2].HorizontalAlignment = 'Right'
                            [System.Windows.Controls.DockPanel]::SetDock($dp.Children[2], 'Right')
                        } else {
                            [System.Windows.Controls.DockPanel]::SetDock($dp.Children[0], 'Top')
                            $dp.Children[0].Margin = '0,0,0,8'
                            $dp.Children[2].HorizontalAlignment = 'Left'
                            [System.Windows.Controls.DockPanel]::SetDock($dp.Children[2], 'Bottom')
                        }
                    }
                }
            }
        }
    }

    $viewModeListBtn = $window.FindName('ViewModeListBtn')
    $viewModeMatrixBtn = $window.FindName('ViewModeMatrixBtn')
    if ($viewModeListBtn) { $viewModeListBtn.Add_Checked({ Update-TweaksViewMode }) }
    if ($viewModeMatrixBtn) { $viewModeMatrixBtn.Add_Checked({ Update-TweaksViewMode }) }

    # Bind the buttons
    $importConfigBtn  = Get-WpfElement -Name "ImportConfigBtn"
    $exportConfigBtn  = Get-WpfElement -Name "ExportConfigBtn"
    $menuDocsBtn      = Get-WpfElement -Name "MenuDocumentation"

    # Logic for Import Profile
    if ($null -ne $importConfigBtn) {
        # Ensure it's enabled and visible to the mouse
        $importConfigBtn.IsHitTestVisible = $true
        
        $importConfigBtn.Add_Click({
            Write-Host "[WHS] Import Clicked" -ForegroundColor Green
            
            # Launch the existing Import-Configuration logic
            Import-Configuration `
                -Owner $window `
                -UsesDarkMode $true `
                -AppsPanel $appsPanel `
                -UiControlMappings $script:UiControlMappings `
                -UserSelectionCombo $userSelectionCombo `
                -OtherUsernameTextBox $otherUsernameTextBox `
                -OnAppsImported { UpdateAppSelectionStatus; UpdatePresetStates } `
                -OnImportCompleted {
                    $navExecuteBtn.IsChecked = $true
                    UpdateInlineOverview
                }
        })
    }

    # Logic for GitHub Link
    if ($null -ne $menuDocsBtn) {
        $menuDocsBtn.Add_Click({
            Start-Process "https://github.com"
        })
    }

    # --- Logic: Export Profile ---
    if ($null -ne $exportConfigBtn) {
        $exportConfigBtn.Add_Click({
            Export-Configuration -Owner $window -UsesDarkMode $true -AppsPanel $appCategoryContainer -UiControlMappings $script:UiControlMappings -UserSelectionCombo $userSelectionCombo -OtherUsernameTextBox $otherUsernameTextBox
        })
    }

    # Handle Apply Changes button - validates and immediately starts applying changes
    $deploymentApplyBtn = $window.FindName('DeploymentApplyBtn')
    $deploymentApplyBtn.Add_Click({
        if (-not (ValidateOtherUsername)) {
            $validationMessage = if ($usernameValidationMessage) {
                $usernameValidationMessage.Text
            }
            else {
                "Please enter a valid username."
            }
            Show-MessageBox -Message $validationMessage -Title "Invalid Username" -Button 'OK' -Icon 'Warning' | Out-Null
            return
        }

        Hide-Bubble -Immediate

        # App Removal - collect selected apps from integrated UI
        $selectedApps = @()
        if ($script:AllAppCheckboxes) {
            foreach ($checkbox in $script:AllAppCheckboxes) {
                if ($checkbox.IsChecked) {
                    $selectedApps += @($checkbox.AppIds)
                }
            }
        }
        $selectedApps = @($selectedApps | Where-Object { $_ } | Select-Object -Unique)
        
        if ($selectedApps.Count -gt 0) {
            # Check if Microsoft Store is selected
            if ($selectedApps -contains "Microsoft.WindowsStore") {
                $result = Show-MessageBox -Message 'Are you sure you wish to uninstall the Microsoft Store? This app cannot easily be reinstalled.' -Title 'Are you sure?' -Button 'YesNo' -Icon 'Warning'

                if ($result -eq 'No') {
                    return
                }
            }
            
            AddParameter 'RemoveApps'
            AddParameter 'Apps' ($selectedApps -join ',')
            
            # Add app removal target parameter based on selection
            $selectedScopeItem = $appRemovalScopeCombo.SelectedItem
            if ($selectedScopeItem) {
                switch ($selectedScopeItem.Content) {
                    "All users" { 
                        AddParameter 'AppRemovalTarget' 'AllUsers'
                    }
                    "Current user only" { 
                        AddParameter 'AppRemovalTarget' 'CurrentUser'
                    }
                    "Target user only" { 
                        # Use the target username from Other User panel
                        AddParameter 'AppRemovalTarget' ($otherUsernameTextBox.Text.Trim())
                    }
                }
            }
        }

        # Apply dynamic tweaks selections
        if ($script:UiControlMappings) {
            foreach ($mappingKey in $script:UiControlMappings.Keys) {
                $control = $window.FindName($mappingKey)
                $isSelected = $false
                $selectedIndex = 0
                
                # Check if it's a checkbox or combobox
                if ($control -is [System.Windows.Controls.CheckBox]) {
                    $isSelected = $control.IsChecked -eq $true
                    $selectedIndex = if ($isSelected) { 1 } else { 0 }
                }
                elseif ($control -is [System.Windows.Controls.ComboBox]) {
                    $isSelected = $control.SelectedIndex -gt 0
                    $selectedIndex = $control.SelectedIndex
                }
                
                if ($control -and $isSelected) {
                    $mapping = $script:UiControlMappings[$mappingKey]
                    if ($mapping.Type -eq 'group') {
                        if ($selectedIndex -gt 0 -and $selectedIndex -le $mapping.Values.Count) {
                            $selectedValue = $mapping.Values[$selectedIndex - 1]
                            foreach ($fid in $selectedValue.FeatureIds) { 
                                AddParameter $fid
                            }
                        }
                    }
                    elseif ($mapping.Type -eq 'feature') {
                        AddParameter $mapping.FeatureId
                    }
                }
            }
        }

        $controlParamsCount = 0
        foreach ($Param in $script:ControlParams) {
            if ($script:Params.ContainsKey($Param)) {
                $controlParamsCount++
            }
        }

        # Check if any changes were selected
        $totalChanges = $script:Params.Count - $controlParamsCount

        # Apps parameter does not count as a change itself
        if ($script:Params.ContainsKey('Apps')) {
            $totalChanges = $totalChanges - 1
        }

        if ($totalChanges -eq 0) {
            Show-MessageBox -Message 'No changes have been selected, please select at least one option to proceed.' -Title 'No Changes Selected' -Button 'OK' -Icon 'Information'
            return
        }

        # Check RestorePointCheckBox
        $restorePointCheckBox = $window.FindName('RestorePointCheckBox')
        if ($restorePointCheckBox -and $restorePointCheckBox.IsChecked) {
            AddParameter 'CreateRestorePoint'
        }
        
        # Store selected user mode
        switch ($userSelectionCombo.SelectedIndex) {
            0 { 
                Write-Host "Selected user mode: current user ($(GetUserName))"
            }
            1 { 
                Write-Host "Selected user mode: $($otherUsernameTextBox.Text.Trim())"
                AddParameter User ($otherUsernameTextBox.Text.Trim()) 
            }
            2 {
                Write-Host "Selected user mode: default user profile (Sysprep)"
                AddParameter Sysprep
            }
        }

        SaveSettings

        # Check if user wants to restart explorer
        $restartExplorerCheckBox = $window.FindName('RestartExplorerCheckBox')
        $shouldRestartExplorer = $restartExplorerCheckBox -and $restartExplorerCheckBox.IsChecked

        # Show the apply changes window
        Show-ApplyModal -Owner $window -RestartExplorer $shouldRestartExplorer

        # Close the main window after the apply dialog closes
        $window.Close()
    })

    # Initialize UI elements on window load
    $window.Add_Loaded({
        BuildDynamicTweaks
        RefreshTweakPresetSources -defaultSettingsJson $defaultsJson -lastUsedSettingsJson $lastUsedSettingsJson
        RegisterTweakPresetControlStateHandlers
        UpdateTweakPresetStates

        # Update Current User chip label with actual username
        if ($userSelectionChip0) {
            $userSelectionChip0.Content = "Current User ($(GetUserName))"
        }

        # Disable Restart Explorer option if NoRestartExplorer parameter is set
        $restartExplorerCheckBox = $window.FindName('RestartExplorerCheckBox')
        if ($restartExplorerCheckBox -and $script:Params.ContainsKey("NoRestartExplorer")) {
            $restartExplorerCheckBox.IsChecked = $false
            $restartExplorerCheckBox.IsEnabled = $false
        }

        # Force Apply Changes To setting if Sysprep or User parameters are set
        if ($script:Params.ContainsKey("Sysprep")) {
            $userSelectionCombo.SelectedIndex = 2
            $userSelectionCombo.IsEnabled = $false
        }
        elseif ($script:Params.ContainsKey("User")) {
            $userSelectionCombo.SelectedIndex = 1
            $userSelectionCombo.IsEnabled = $false
            $otherUsernameTextBox.Text = $script:Params.Item("User")
            $otherUsernameTextBox.IsEnabled = $false
        }
    })

    function BuildTweakPresetControlMap {
        param($settingsJson)

        $presetMap = @{}
        if (-not $settingsJson -or -not $settingsJson.Settings -or -not $script:UiControlMappings) {
            return $presetMap
        }

        # FeatureId -> control metadata, similar to ApplySettingsToUiControls lookup.
        $featureIdIndex = @{}
        foreach ($controlName in $script:UiControlMappings.Keys) {
            $control = $window.FindName($controlName)
            if (-not $control -or $control.Visibility -ne 'Visible') { continue }

            $mapping = $script:UiControlMappings[$controlName]
            if ($mapping.Type -eq 'group') {
                $i = 1
                foreach ($val in $mapping.Values) {
                    foreach ($fid in $val.FeatureIds) {
                        $featureIdIndex[$fid] = @{ ControlName = $controlName; Control = $control; MappingType = 'group'; Index = $i }
                    }
                    $i++
                }
            }
            elseif ($mapping.Type -eq 'feature') {
                $featureIdIndex[$mapping.FeatureId] = @{ ControlName = $controlName; Control = $control; MappingType = 'feature' }
            }
        }

        foreach ($setting in $settingsJson.Settings) {
            if ($setting.Value -ne $true) { continue }
            if ($setting.Name -eq 'CreateRestorePoint') { continue }

            $entry = $featureIdIndex[$setting.Name]
            if (-not $entry) { continue }
            if ($presetMap.ContainsKey($entry.ControlName)) { continue }

            $controlType = if ($entry.Control -is [System.Windows.Controls.CheckBox]) { 'CheckBox' } else { 'ComboBox' }
            $desiredValue = switch ($entry.MappingType) {
                'group'   { $entry.Index }
                default   { if ($controlType -eq 'CheckBox') { $true } else { 1 } }
            }

            $presetMap[$entry.ControlName] = @{ Control = $entry.Control; ControlType = $controlType; DesiredValue = $desiredValue }
        }

        return $presetMap
    }

    function BuildCategoryTweakPresetMap {
        param([string]$Category)

        $presetMap = @{}
        if (-not $script:UiControlMappings) { return $presetMap }

        foreach ($controlName in $script:UiControlMappings.Keys) {
            $mapping = $script:UiControlMappings[$controlName]
            if ($mapping.Category -ne $Category) { continue }

            $control = $window.FindName($controlName)
            if (-not $control -or $control.Visibility -ne 'Visible') { continue }

            $controlType = if ($control -is [System.Windows.Controls.CheckBox]) { 'CheckBox' } else { 'ComboBox' }
            $desiredValue = if ($controlType -eq 'CheckBox') { $true } else { 1 }
            $presetMap[$controlName] = @{ Control = $control; ControlType = $controlType; DesiredValue = $desiredValue }
        }

        return $presetMap
    }

    function GetSavedAppIdsFromSettingsJson {
        param($settingsJson)

        if (-not $settingsJson -or -not $settingsJson.Settings) {
            return $null
        }

        $appsValue = $null
        foreach ($setting in $settingsJson.Settings) {
            if ($setting.Name -eq 'Apps' -and $setting.Value) {
                $appsValue = $setting.Value
                break
            }
        }

        if (-not $appsValue) {
            return $null
        }

        $savedAppIds = @()
        if ($appsValue -is [string]) {
            $savedAppIds = $appsValue.Split(',')
        }
        elseif ($appsValue -is [array]) {
            $savedAppIds = $appsValue
        }

        $savedAppIds = $savedAppIds | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        if ($savedAppIds.Count -eq 0) {
            return $null
        }

        return $savedAppIds
    }

    function ApplyTweakPresetMap {
        param(
            [hashtable]$PresetMap,
            [bool]$Check
        )

        if (-not $PresetMap) {
            $PresetMap = @{}
        }

        $wasUpdatingTweakPresets = [bool]$script:UpdatingTweakPresets
        $script:UpdatingTweakPresets = $true
        try {
            foreach ($target in $PresetMap.Values) {
                $control = $target.Control
                if (-not $control) { continue }

                if ($target.ControlType -eq 'CheckBox') {
                    $control.IsChecked = $Check
                }
                elseif ($target.ControlType -eq 'ComboBox') {
                    $desiredIndex = [int]$target.DesiredValue
                    if ($Check) {
                        $control.SelectedIndex = $desiredIndex
                    }
                    elseif ($control.SelectedIndex -eq $desiredIndex) {
                        $control.SelectedIndex = 0
                    }
                }
            }
        }
        finally {
            $script:UpdatingTweakPresets = $wasUpdatingTweakPresets
        }

        if (-not $wasUpdatingTweakPresets) {
            UpdateTweakPresetStates
        }
    }

    function SetTweakPresetState {
        param(
            [System.Windows.Controls.CheckBox]$PresetCheckBox,
            [hashtable]$PresetMap
        )

        if (-not $PresetCheckBox) { return }
        if (-not $PresetMap) {
            $PresetMap = @{}
        }

        $total = $PresetMap.Count
        $selected = 0

        foreach ($target in $PresetMap.Values) {
            $control = $target.Control
            if (-not $control) { continue }

            if ($target.ControlType -eq 'CheckBox' -and $control.IsChecked -eq $true) {
                $selected++
            }
            elseif ($target.ControlType -eq 'ComboBox' -and $control.SelectedIndex -eq [int]$target.DesiredValue) {
                $selected++
            }
        }

        SetTriStatePresetCheckBoxState -CheckBox $PresetCheckBox -Total $total -Selected $selected
    }

    function UpdateTweakPresetStates {
        $script:UpdatingTweakPresets = $true
        try {
            SetTweakPresetState -PresetCheckBox $presetDefaultTweaksBtn -PresetMap $script:DefaultTweakPresetMap
            if ($presetLastUsedTweaksBtn -and $presetLastUsedTweaksBtn.Visibility -ne 'Collapsed') {
                SetTweakPresetState -PresetCheckBox $presetLastUsedTweaksBtn -PresetMap $script:LastUsedTweakPresetMap
            }
            SetTweakPresetState -PresetCheckBox $presetPrivacyTweaksBtn -PresetMap $script:PrivacyTweakPresetMap
            SetTweakPresetState -PresetCheckBox $presetAITweaksBtn -PresetMap $script:AITweakPresetMap
        }
        finally {
            $script:UpdatingTweakPresets = $false
        }
    }

    function RegisterTweakPresetControlStateHandlers {
        if (-not $script:UiControlMappings) { return }

        foreach ($controlName in $script:UiControlMappings.Keys) {
            $control = $window.FindName($controlName)
            if (-not $control) { continue }

            if ($control -is [System.Windows.Controls.CheckBox]) {
                # $control.Add_Checked({ if (-not $script:UpdatingTweakPresets) { UpdateTweakPresetStates } })
                # $control.Add_Unchecked({ if (-not $script:UpdatingTweakPresets) { UpdateTweakPresetStates } })
            }
            elseif ($control -is [System.Windows.Controls.ComboBox]) {
                # $control.Add_SelectionChanged({ if (-not $script:UpdatingTweakPresets) { UpdateTweakPresetStates } })
            }
        }
    }

    function RefreshTweakPresetSources {
        param(
            $defaultSettingsJson,
            $lastUsedSettingsJson
        )

        $script:DefaultTweakPresetMap = BuildTweakPresetControlMap -settingsJson $defaultSettingsJson
        $script:LastUsedTweakPresetMap = BuildTweakPresetControlMap -settingsJson $lastUsedSettingsJson
        $script:PrivacyTweakPresetMap = BuildCategoryTweakPresetMap -Category 'Privacy & Suggested Content'
        $script:AITweakPresetMap = BuildCategoryTweakPresetMap -Category 'AI'

        if ($presetLastUsedTweaksBtn) {
            $presetLastUsedTweaksBtn.Visibility = if ($script:LastUsedTweakPresetMap.Count -gt 0) { 'Visible' } else { 'Collapsed' }
        }
    }

    $lastUsedSettingsJson = LoadJsonFile -filePath $script:SavedSettingsFilePath -expectedVersion "1.0" -optionalFile

    $defaultsJson = LoadJsonFile -filePath $script:DefaultSettingsFilePath -expectedVersion "1.0"
    $script:DefaultTweakPresetMap = @{}
    $script:LastUsedTweakPresetMap = @{}
    $script:PrivacyTweakPresetMap = @{}
    $script:AITweakPresetMap = @{}
    $script:SavedAppIds = GetSavedAppIdsFromSettingsJson -settingsJson $lastUsedSettingsJson

    if ($presetDefaultTweaksBtn) {
        $presetDefaultTweaksBtn.Add_Click({
            if ($script:UpdatingTweakPresets) { return }
            $check = NormalizeCheckboxState -checkBox $this
            ApplyTweakPresetMap -PresetMap $script:DefaultTweakPresetMap -Check $check
        })
    }

    if ($presetLastUsedTweaksBtn) {
        $presetLastUsedTweaksBtn.Add_Click({
            if ($script:UpdatingTweakPresets) { return }
            $check = NormalizeCheckboxState -checkBox $this
            ApplyTweakPresetMap -PresetMap $script:LastUsedTweakPresetMap -Check $check
        })
    }

    if ($presetPrivacyTweaksBtn) {
        $presetPrivacyTweaksBtn.Add_Click({
            if ($script:UpdatingTweakPresets) { return }
            $check = NormalizeCheckboxState -checkBox $this
            ApplyTweakPresetMap -PresetMap $script:PrivacyTweakPresetMap -Check $check
        })
    }

    if ($presetAITweaksBtn) {
        $presetAITweaksBtn.Add_Click({
            if ($script:UpdatingTweakPresets) { return }
            $check = NormalizeCheckboxState -checkBox $this
            ApplyTweakPresetMap -PresetMap $script:AITweakPresetMap -Check $check
        })
    }

    # Hide Last used tweak preset by default; it is shown after dynamic controls are built and mappings are resolved.
    if ($presetLastUsedTweaksBtn) {
        $presetLastUsedTweaksBtn.Visibility = 'Collapsed'
    }

    # Preset: Last used selection (wired to PresetLastUsed checkbox)
    if ($script:SavedAppIds) {
        $presetLastUsed.Add_Click({
            if ($script:UpdatingPresets) { return }
            $check = NormalizeCheckboxState -checkBox $this
            ApplyPresetToApps -MatchFilter { param($c) (@($c.AppIds) | Where-Object { $script:SavedAppIds -contains $_ }).Count -gt 0 } -Check $check
        })
    }
    else {
        $script:SavedAppIds = $null
        $presetLastUsed.Visibility = 'Collapsed'
    }

    # Clear All Tweaks button
    $clearAllTweaksBtn = $window.FindName('ClearAllTweaksBtn')
    $clearAllTweaksBtn.Add_Click({
        # Reset all ComboBoxes to index 0 (No Change) and uncheck all CheckBoxes
        if ($script:UiControlMappings) {
            foreach ($comboName in $script:UiControlMappings.Keys) {
                $control = $window.FindName($comboName)
                if ($control -is [System.Windows.Controls.CheckBox]) {
                    $control.IsChecked = $false
                }
                elseif ($control -is [System.Windows.Controls.ComboBox]) {
                    $control.SelectedIndex = 0
                }
            }
        }
        UpdateTweakPresetStates
    })

    # Preload app data to speed up loading when user navigates to App Removal tab
    try {
        $script:PreloadedAppData = LoadAppsDetailsFromJson -OnlyInstalled:$false -InstalledList '' -InitialCheckedFromJson:$false
    }
    catch {
        Write-Warning "Failed to preload apps list: $_"
    }
    finally {
        # Preload complete (success or failure) — safe to enable Import Profile now.
        # Without this, ImportConfigBtn stays disabled until the user visits App Removal,
        # because IsEnabled is set to $false at startup (line ~352) as a load-order guard.
        if ($importConfigBtn) { $importConfigBtn.IsEnabled = $true }
    }

    # Show the window
    $frame = [System.Windows.Threading.DispatcherFrame]::new()
    $window.Add_Closed({
        $frame.Continue = $false
    })

    $window.Show() | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    return $null
}
