# Detects whether the current Windows system theme is set to dark mode.
# Reads the AppsUseLightTheme registry key — returns $true if dark mode is active,
# $false if light mode is active or if the key cannot be read.
function GetSystemUsesDarkMode {
    try {
        $themeKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $value = Get-ItemPropertyValue -Path $themeKey -Name 'AppsUseLightTheme' -ErrorAction Stop
        # AppsUseLightTheme = 0 means dark mode is ON
        return ($value -eq 0)
    }
    catch {
        # Default to dark mode if registry read fails (modern Windows default)
        return $true
    }
}
