# Applies the current system theme resources to a WPF window.
# Dynamically swaps out the Color and Brush resources based on dark/light mode.
# Also merges SharedStyles.xaml into the window so keyed styles are accessible.
function SetWindowThemeResources {
    param (
        [Parameter(Mandatory=$true)]
        [System.Windows.Window]$window,
        
        [Parameter(Mandatory=$true)]
        [bool]$usesDarkMode
    )

    # Merge SharedStyles.xaml into the window resource dictionary so that all
    # keyed styles (AppMatrixCardStyle, PresetChipStyle, AppCategoryExpanderStyle, etc.)
    # are accessible via $window.Resources['StyleKey'] from PowerShell code-behind.
    if ($script:SharedStylesSchema -and (Test-Path $script:SharedStylesSchema)) {
        # Only merge once — check if our sentinel key is already present
        $alreadyMerged = $false
        foreach ($dict in $window.Resources.MergedDictionaries) {
            if ($dict.Contains('AppMatrixCardStyle')) { $alreadyMerged = $true; break }
        }
        if (-not $alreadyMerged) {
            try {
                $sharedXaml = Get-Content -Path $script:SharedStylesSchema -Raw
                $sharedReader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($sharedXaml))
                $sharedDict = [System.Windows.Markup.XamlReader]::Load($sharedReader)
                $sharedReader.Close()
                $window.Resources.MergedDictionaries.Add($sharedDict)
            } catch {
                Write-Warning "SetWindowThemeResources: Failed to merge SharedStyles.xaml: $_"
            }
        }
    }

    $DarkPalette = @{
        BgColor='#181818'; FgColor='#E4E4E7'; CardBgColor='#222222'
        BorderColor='#333333'; ButtonBorderColor='#3a3a3a'
        CheckBoxBgColor='#222222'; CheckBoxBorderColor='#555555'; CheckBoxHoverColor='#2a2a2a'
        ComboBgColor='#262626'; ComboHoverColor='#303030'; ComboItemBgColor='#262626'
        ComboItemHoverColor='#333333'; ComboItemSelectedColor='#3a3a3a'
        AccentColor='#60CDFF'; SelectionAccentColor='#60CDFF'; OptionAccentColor='#10B981'; PresetAccentColor='#10B981'; HoverBorderColor='#4a4a4a'
        WarningColor='#F59E0B'
        ButtonDisabled='#2a2a2a'; ButtonTextDisabled='#71717A'
        SecondaryButtonBg='#27272A'; SecondaryButtonHover='#3F3F46'
        SecondaryButtonPressed='#52525B'; SecondaryButtonDisabled='#18181B'
        SecondaryButtonTextDisabled='#52525B'; InputFocusColor='#262626'
        ScrollBarThumbColor='#3F3F46'; ScrollBarThumbHoverColor='#52525B'
        TitlebarButtonHover='#27272A'; TitlebarButtonPressed='#3F3F46'
        AppIdColor='#A1A1AA'; SearchHighlightColor='#4A4A2A'
        SearchHighlightActiveColor='#8A7000'; TableHeaderColor='#222222'
        SidebarBgColor='#181818'; SidebarBorderColor='#27272A'; ContentBgColor='#0e0e0e'
        HeroTitleColor='#FFFFFF'; HeroSubtitleColor='#A1A1AA'; SidebarLabelColor='#A1A1AA'
        CloseHover='#E81123'; ClosePressed='#F1707A'
    }
    
    $LightPalette = @{
        BgColor='#FFFFFF'; FgColor='#27272A'; CardBgColor='#FFFFFF'
        BorderColor='#E4E4E7'; ButtonBorderColor='#D4D4D8'
        CheckBoxBgColor='#FFFFFF'; CheckBoxBorderColor='#A1A1AA'; CheckBoxHoverColor='#F4F4F5'
        ComboBgColor='#FFFFFF'; ComboHoverColor='#F4F4F5'; ComboItemBgColor='#FFFFFF'
        ComboItemHoverColor='#F4F4F5'; ComboItemSelectedColor='#E4E4E7'
        AccentColor='#005FB8'; SelectionAccentColor='#005FB8'; OptionAccentColor='#059669'; PresetAccentColor='#059669'; HoverBorderColor='#A1A1AA'
        WarningColor='#D97706'
        ButtonDisabled='#F4F4F5'; ButtonTextDisabled='#A1A1AA'
        SecondaryButtonBg='#F4F4F5'; SecondaryButtonHover='#E4E4E7'
        SecondaryButtonPressed='#D4D4D8'; SecondaryButtonDisabled='#FAFAFA'
        SecondaryButtonTextDisabled='#A1A1AA'; InputFocusColor='#FFFFFF'
        ScrollBarThumbColor='#D4D4D8'; ScrollBarThumbHoverColor='#A1A1AA'
        TitlebarButtonHover='#F4F4F5'; TitlebarButtonPressed='#E4E4E7'
        AppIdColor='#71717A'; SearchHighlightColor='#FFF4CE'
        SearchHighlightActiveColor='#FFD966'; TableHeaderColor='#FFFFFF'
        SidebarBgColor='#FFFFFF'; SidebarBorderColor='#E4E4E7'; ContentBgColor='#F4F4F5'
        HeroTitleColor='#09090B'; HeroSubtitleColor='#52525B'; SidebarLabelColor='#52525B'
        CloseHover='#E81123'; ClosePressed='#F1707A'
    }

    $palette = if ($usesDarkMode) { $DarkPalette } else { $LightPalette }
    
    foreach ($key in $palette.Keys) {
        $color = [System.Windows.Media.Color][System.Windows.Media.ColorConverter]::ConvertFromString($palette[$key])
        $newBrush = [System.Windows.Media.SolidColorBrush]::new($color)
        $newBrush.Freeze()
        $window.Resources[$key] = $newBrush
    }
}
