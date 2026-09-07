# Scripts/AI/Show-AiChatStandalone.ps1
# Windows Healing System - Conversational AI Assistant Runner
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

. "$PSScriptRoot/Get-RagContext.ps1"
. "$PSScriptRoot/Invoke-OllamaChat.ps1"

# Pure ASCII Vector Icons
$script:ICON_SEND = "M 12 3 L 4 11 L 5.4 12.4 L 11 6.8 L 11 21 L 13 21 L 13 6.8 L 18.6 12.4 L 20 11 Z"
$script:ICON_BUSY = "M 6 6 H 18 V 18 H 6 Z"

# 1. Resolve XAML Path
$xamlCandidates = @(
    (Join-Path $PSScriptRoot "../../Schemas/AiChatTab.xaml"),
    (Join-Path $PSScriptRoot "Schemas/AiChatTab.xaml"),
    "Schemas/AiChatTab.xaml"
)
$xamlPath = $null
foreach ($path in $xamlCandidates) {
    if (Test-Path $path) { $xamlPath = $path; break }
}
if (-not $xamlPath) { Write-Error "AiChatTab.xaml not found."; exit 1 }

[xml]$xamlContent = Get-Content -Path $xamlPath -Raw -Encoding UTF8
$gridNode = [System.Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xamlContent))

function Find-WpfControl {
    param([string]$Name)
    $ctl = $gridNode.FindName($Name)
    if ($null -eq $ctl) { $ctl = [System.Windows.LogicalTreeHelper]::FindLogicalNode($gridNode, $Name) }
    return $ctl
}

# Bind Controls
$AiStatusLight         = Find-WpfControl "AiStatusLight"
$AiStatusText          = Find-WpfControl "AiStatusText"
$AiModelComboBox       = Find-WpfControl "AiModelComboBox"
$AiBtnClear            = Find-WpfControl "AiBtnClear"
$AiChatScrollViewer    = Find-WpfControl "AiChatScrollViewer"
$AiChatPanel           = Find-WpfControl "AiChatPanel"
$AiWelcomeHero         = Find-WpfControl "AiWelcomeHero"
$InputContainerBorder  = Find-WpfControl "InputContainerBorder"
$AiChatInput           = Find-WpfControl "AiChatInput"
$AiChatPlaceholder     = Find-WpfControl "AiChatPlaceholder"
$AiBtnSend             = Find-WpfControl "AiBtnSend"
$ChipGaming            = Find-WpfControl "ChipGaming"
$ChipStandby           = Find-WpfControl "ChipStandby"
$ChipTelemetry         = Find-WpfControl "ChipTelemetry"
$ChipEdge              = Find-WpfControl "ChipEdge"

# Window Host
$window = New-Object System.Windows.Window
$window.Title = "Windows Healing System - AI Assistant"
$window.Width = 1040
$window.Height = 780
$window.MinWidth = 740
$window.MinHeight = 540
$window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
$window.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#121212")
$window.Content = $gridNode

function Sync-UI {
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke(
        [System.Windows.Threading.DispatcherPriority]::Render,
        [Action]{}
    )
}

# Responsive Column Controller (Capped at 960px, shrinks cleanly to fit any display)
$AdjustLayoutWidth = {
    $usable = $window.ActualWidth - 64
    $targetWidth = [Math]::Min([Math]::Max($usable, 500), 960)

    if ($AiChatPanel) { $AiChatPanel.Width = $targetWidth }
    if ($InputContainerBorder) { $InputContainerBorder.Width = $targetWidth }
    if ($AiWelcomeHero) { $AiWelcomeHero.Width = $targetWidth }
}

$window.Add_SizeChanged({ & $AdjustLayoutWidth })

# Placeholder visibility handler
$AiChatInput.Add_TextChanged({
    if ([string]::IsNullOrEmpty($AiChatInput.Text)) {
        $AiChatPlaceholder.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $AiChatPlaceholder.Visibility = [System.Windows.Visibility]::Collapsed
    }
})

# 2. Populate Models & Mark Thresholds
$script:ModelMap = @{}
$models = Get-OllamaModelsDetailed

if ($models.Count -gt 0) {
    foreach ($m in $models) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = $m.DisplayName
        if (-not $m.IsOptimal) {
            $item.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#606060")
        }
        $AiModelComboBox.Items.Add($item) | Out-Null
        $script:ModelMap[$m.DisplayName] = $m.Name
    }
    $AiModelComboBox.SelectedIndex = 0
    $AiStatusText.Text = "Engine Active (" + $models[0].Name + ")"
} else {
    $AiStatusLight.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#555555")
    $AiStatusText.Text = "Ollama Offline"
    $AiBtnSend.IsEnabled = $false
}

# ==============================================================================
# CONVERSATION MEMORY: RECENCY BUFFER + FIFO SUMMARY QUEUE
# ==============================================================================
$script:RecentTurns = [System.Collections.Generic.List[PSCustomObject]]::new()
$script:SummaryBullets = [System.Collections.Generic.List[string]]::new()
$script:IsProcessing = $false

# Extracts the core takeaway of an assistant reply for lightweight memory storage
function Extract-CoreSummary {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    $lines = $Text -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    # Pick first 2 informative lines or up to 200 characters
    $summary = ($lines | Select-Object -First 2) -join " "
    if ($summary.Length -gt 220) { $summary = $summary.Substring(0, 220) + "..." }

    # Preserve code-formatted technical values (registry paths, keys, params) so
    # they survive even after this exchange is compressed into long-term memory.
    $codeSpans = [System.Text.RegularExpressions.Regex]::Matches($Text, '`([^`]+)`') |
        ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique -First 5
    if ($codeSpans) {
        $summary += " [Key values: " + ($codeSpans -join ", ") + "]"
    }
    return $summary
}

# 3. Dynamic Message Renderers
function Render-UserMessage {
    param([string]$Text)
    if ($AiWelcomeHero) { $AiWelcomeHero.Visibility = [System.Windows.Visibility]::Collapsed }

    $bubble = New-Object System.Windows.Controls.Border
    $bubble.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#232323")
    $bubble.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2E2E2E")
    $bubble.BorderThickness = [System.Windows.Thickness]::new(1)
    $bubble.CornerRadius = [System.Windows.CornerRadius]::new(14, 14, 4, 14)
    $bubble.Padding = [System.Windows.Thickness]::new(18, 12, 18, 12)
    $bubble.Margin = [System.Windows.Thickness]::new(140, 10, 0, 10)
    $bubble.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
    $bubble.MaxWidth = 660

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.Foreground = [System.Windows.Media.Brushes]::White
    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tb.FontSize = 13.5
    $tb.LineHeight = 20

    $bubble.Child = $tb
    $AiChatPanel.Children.Add($bubble) | Out-Null
    $AiChatScrollViewer.ScrollToBottom()
    Sync-UI
}

function Render-AssistantMessageCard {
    $card = New-Object System.Windows.Controls.Border
    $card.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#181818")
    $card.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#262626")
    $card.BorderThickness = [System.Windows.Thickness]::new(1)
    $card.CornerRadius = [System.Windows.CornerRadius]::new(14, 14, 14, 4)
    $card.Padding = [System.Windows.Thickness]::new(24, 20, 24, 22)
    $card.Margin = [System.Windows.Thickness]::new(0, 10, 0, 16)
    $card.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Stretch

    $rootStack = New-Object System.Windows.Controls.StackPanel

    # Reasoning Tray with 20px Buffer
    $expanderBorder = New-Object System.Windows.Controls.Border
    $expanderBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#131313")
    $expanderBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#242424")
    $expanderBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $expanderBorder.CornerRadius = [System.Windows.CornerRadius]::new(10)
    $expanderBorder.Padding = [System.Windows.Thickness]::new(16, 12, 16, 12)
    $expanderBorder.Margin = [System.Windows.Thickness]::new(0, 0, 0, 20)

    $expanderStack = New-Object System.Windows.Controls.StackPanel

    # Header Row
    $headerGrid = New-Object System.Windows.Controls.Grid
    $headerGrid.Height = 28
    $headerGrid.Cursor = [System.Windows.Input.Cursors]::Hand

    $hCol0 = New-Object System.Windows.Controls.ColumnDefinition; $hCol0.Width = [System.Windows.GridLength]::Auto
    $hCol1 = New-Object System.Windows.Controls.ColumnDefinition; $hCol1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $hCol2 = New-Object System.Windows.Controls.ColumnDefinition; $hCol2.Width = [System.Windows.GridLength]::Auto

    $headerGrid.ColumnDefinitions.Add($hCol0)
    $headerGrid.ColumnDefinitions.Add($hCol1)
    $headerGrid.ColumnDefinitions.Add($hCol2)

    # Arrow Glyph
    $arrowGlyph = New-Object System.Windows.Controls.TextBlock
    $arrowGlyph.Text = "v"
    $arrowGlyph.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#707070")
    $arrowGlyph.FontSize = 10
    $arrowGlyph.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $arrowGlyph.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    [System.Windows.Controls.Grid]::SetColumn($arrowGlyph, 0)
    $headerGrid.Children.Add($arrowGlyph) | Out-Null

    # Header Title
    $headerTitle = New-Object System.Windows.Controls.TextBlock
    $headerTitle.Text = "Thought Process & Grounded Sources"
    $headerTitle.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CCCCCC")
    $headerTitle.FontSize = 12
    $headerTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
    $headerTitle.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($headerTitle, 1)
    $headerGrid.Children.Add($headerTitle) | Out-Null

    # Status Pill Badge
    $statsBadgeBorder = New-Object System.Windows.Controls.Border
    $statsBadgeBorder.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#202020")
    $statsBadgeBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#2A2A2A")
    $statsBadgeBorder.BorderThickness = [System.Windows.Thickness]::new(1)
    $statsBadgeBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $statsBadgeBorder.Padding = [System.Windows.Thickness]::new(10, 4, 10, 4)
    $statsBadgeBorder.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($statsBadgeBorder, 2)

    $statsBadge = New-Object System.Windows.Controls.TextBlock
    $statsBadge.Text = "Reasoning..."
    $statsBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#999999")
    $statsBadge.FontSize = 11
    $statsBadge.FontWeight = [System.Windows.FontWeights]::Medium
    $statsBadge.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $statsBadgeBorder.Child = $statsBadge
    $headerGrid.Children.Add($statsBadgeBorder) | Out-Null

    $expanderStack.Children.Add($headerGrid) | Out-Null

    # Divider Line
    $divider = New-Object System.Windows.Controls.Border
    $divider.Height = 1
    $divider.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#202020")
    $divider.Margin = [System.Windows.Thickness]::new(0, 10, 0, 10)
    $expanderStack.Children.Add($divider) | Out-Null

    # Step List Container
    $detailsContainer = New-Object System.Windows.Controls.StackPanel
    $detailsContainer.Margin = [System.Windows.Thickness]::new(4, 0, 0, 2)
    $detailsContainer.Visibility = [System.Windows.Visibility]::Visible

    $expanderStack.Children.Add($detailsContainer) | Out-Null
    $expanderBorder.Child = $expanderStack

    # Safe Toggle Handler using $sender.Tag
    $headerGrid.Tag = @{
        Container = $detailsContainer
        Divider   = $divider
        Arrow     = $arrowGlyph
    }

    $headerGrid.Add_MouseDown({
        param($sender, $e)
        try {
            $tag = $sender.Tag
            if ($null -ne $tag -and $null -ne $tag.Container) {
                if ($tag.Container.Visibility -eq [System.Windows.Visibility]::Visible) {
                    $tag.Container.Visibility = [System.Windows.Visibility]::Collapsed
                    $tag.Divider.Visibility = [System.Windows.Visibility]::Collapsed
                    $tag.Arrow.Text = ">"
                } else {
                    $tag.Container.Visibility = [System.Windows.Visibility]::Visible
                    $tag.Divider.Visibility = [System.Windows.Visibility]::Visible
                    $tag.Arrow.Text = "v"
                }
                Sync-UI
            }
        } catch { }
    })

    # Dedicated Progress Indicator Placeholder
    $loadingContainer = New-Object System.Windows.Controls.StackPanel
    $loadingContainer.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $loadingContainer.Margin = [System.Windows.Thickness]::new(4, 8, 0, 16)
    $loadingContainer.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $pulseDot = New-Object System.Windows.Controls.Border
    $pulseDot.Width = 8
    $pulseDot.Height = 8
    $pulseDot.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $pulseDot.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#8CD97E")
    $pulseDot.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $pulseDot.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $anim = New-Object System.Windows.Media.Animation.DoubleAnimation
    $anim.From = 0.2
    $anim.To = 1.0
    $anim.Duration = [System.Windows.Duration]::new([System.TimeSpan]::FromMilliseconds(700))
    $anim.AutoReverse = $true
    $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $pulseDot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $anim)

    $loadingText = New-Object System.Windows.Controls.TextBlock
    $loadingText.Text = "Thinking & synthesizing answer..."
    $loadingText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
    $loadingText.FontSize = 12
    $loadingText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $loadingContainer.Children.Add($pulseDot) | Out-Null
    $loadingContainer.Children.Add($loadingText) | Out-Null

    # Final Answer Content Panel
    $contentPanel = New-Object System.Windows.Controls.StackPanel
    $contentPanel.Visibility = [System.Windows.Visibility]::Collapsed

    $rootStack.Children.Add($expanderBorder) | Out-Null
    $rootStack.Children.Add($loadingContainer) | Out-Null
    $rootStack.Children.Add($contentPanel) | Out-Null

    $card.Child = $rootStack
    $AiChatPanel.Children.Add($card) | Out-Null
    $AiChatScrollViewer.ScrollToBottom()
    Sync-UI

    return @{
        Card             = $card
        StatsBadge       = $statsBadge
        ArrowGlyph       = $arrowGlyph
        DetailsContainer = $detailsContainer
        LoadingContainer = $loadingContainer
        ContentPanel     = $contentPanel
    }
}

function Add-ProcessTelemetryRow {
    param($Container, [string]$StepNumber, [string]$Text, [string]$Color = "#AAAAAA")

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $row.Margin = [System.Windows.Thickness]::new(0, 5, 0, 5)

    $numPill = New-Object System.Windows.Controls.Border
    $numPill.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#202020")
    $numPill.CornerRadius = [System.Windows.CornerRadius]::new(4)
    $numPill.Padding = [System.Windows.Thickness]::new(6, 1, 6, 1)
    $numPill.Margin = [System.Windows.Thickness]::new(0, 0, 10, 0)
    $numPill.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $numTb = New-Object System.Windows.Controls.TextBlock
    $numTb.Text = $StepNumber
    $numTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
    $numTb.FontSize = 10.5
    $numTb.FontWeight = [System.Windows.FontWeights]::SemiBold
    $numPill.Child = $numTb
    $row.Children.Add($numPill) | Out-Null

    $tTb = New-Object System.Windows.Controls.TextBlock
    $tTb.Text = $Text
    $tTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($Color)
    $tTb.FontSize = 11.5
    $tTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tTb.LineHeight = 16
    $tTb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

    $row.Children.Add($tTb) | Out-Null

    $Container.Children.Add($row) | Out-Null
    $AiChatScrollViewer.ScrollToBottom()
    Sync-UI
}

function Add-TelemetrySourceRow {
    param($Container, [string]$SourceId, [string]$Title, [string]$Score, [string]$Safety)

    $box = New-Object System.Windows.Controls.Border
    $box.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#181818")
    $box.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#242424")
    $box.BorderThickness = [System.Windows.Thickness]::new(1)
    $box.CornerRadius = [System.Windows.CornerRadius]::new(6)
    $box.Padding = [System.Windows.Thickness]::new(10, 6, 10, 6)
    $box.Margin = [System.Windows.Thickness]::new(26, 3, 0, 3)

    $grid = New-Object System.Windows.Controls.Grid
    $col0 = New-Object System.Windows.Controls.ColumnDefinition; $col0.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = [System.Windows.GridLength]::Auto
    $grid.ColumnDefinitions.Add($col0)
    $grid.ColumnDefinitions.Add($col1)

    $titleTb = New-Object System.Windows.Controls.TextBlock
    $titleTb.Text = "[$SourceId] $Title"
    $titleTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#CCCCCC")
    $titleTb.FontSize = 11
    [System.Windows.Controls.Grid]::SetColumn($titleTb, 0)
    $grid.Children.Add($titleTb) | Out-Null

    $metaTb = New-Object System.Windows.Controls.TextBlock
    $metaTb.Text = "$Score | $Safety"
    $metaTb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#777777")
    $metaTb.FontSize = 10.5
    [System.Windows.Controls.Grid]::SetColumn($metaTb, 1)
    $grid.Children.Add($metaTb) | Out-Null

    $box.Child = $grid
    $Container.Children.Add($box) | Out-Null
    $AiChatScrollViewer.ScrollToBottom()
    Sync-UI
}

function Create-FormattedTextBlock {
    param([string]$Text)

    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $tb.FontSize = 13.5
    $tb.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#D5D5D5")
    $tb.LineHeight = 22

    $pattern = '(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)'
    $tokens = [System.Text.RegularExpressions.Regex]::Split($Text, $pattern)

    foreach ($t in $tokens) {
        if ([string]::IsNullOrEmpty($t)) { continue }

        if ($t.StartsWith('**') -and $t.EndsWith('**') -and $t.Length -gt 4) {
            $run = New-Object System.Windows.Documents.Run($t.Substring(2, $t.Length - 4))
            $run.FontWeight = [System.Windows.FontWeights]::Bold
            $run.Foreground = [System.Windows.Media.Brushes]::White
            $tb.Inlines.Add($run)
        }
        elseif ($t.StartsWith('`') -and $t.EndsWith('`') -and $t.Length -gt 2) {
            $run = New-Object System.Windows.Documents.Run(" " + $t.Substring(1, $t.Length - 2) + " ")
            $run.FontFamily = New-Object System.Windows.Media.FontFamily("Consolas")
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#8CD97E")
            $tb.Inlines.Add($run)
        }
        elseif ($t.StartsWith('*') -and $t.EndsWith('*') -and $t.Length -gt 2) {
            $run = New-Object System.Windows.Documents.Run($t.Substring(1, $t.Length - 2))
            $run.FontStyle = [System.Windows.FontStyles]::Italic
            $run.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#E0E0E0")
            $tb.Inlines.Add($run)
        }
        else {
            $tb.Inlines.Add((New-Object System.Windows.Documents.Run($t)))
        }
    }
    return $tb
}

function Render-ConversationalMarkdown {
    param($ContentPanel, [string]$RawText)

    $ContentPanel.Children.Clear()
    if ([string]::IsNullOrWhiteSpace($RawText)) { return }

    $clean = $RawText -replace "\r\n", "`n"
    $lines = $clean -split "`n"

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i].Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        # Section Header Check
        $isHeader = $false
        $headerTitle = ""
        $trailingText = ""

        if ($line -match '^#{1,3}\s+(.+)') {
            $isHeader = $true
            $headerTitle = $matches[1] -replace '\*+', ''
        }
        elseif ($line -match '^\*\*(.+?):\*\*\s*(.*)') {
            $isHeader = $true
            $headerTitle = $matches[1] + ":"
            $trailingText = $matches[2]
        }
        elseif ($line -match '^(Cause|Recommended Fix|Technical Details|Diagnosis|Solution|Steps|Summary|Immediate Recommendations):\s*(.*)') {
            $isHeader = $true
            $headerTitle = $matches[1] + ":"
            $trailingText = $matches[2]
        }

        if ($isHeader) {
            $secBlock = New-Object System.Windows.Controls.StackPanel
            $secBlock.Margin = [System.Windows.Thickness]::new(0, 14, 0, 6)

            $hText = New-Object System.Windows.Controls.TextBlock
            $hText.Text = $headerTitle
            $hText.FontSize = 14
            $hText.FontWeight = [System.Windows.FontWeights]::Bold
            $hText.Foreground = [System.Windows.Media.Brushes]::White
            $hText.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $secBlock.Children.Add($hText) | Out-Null

            if (-not [string]::IsNullOrWhiteSpace($trailingText)) {
                $pText = Create-FormattedTextBlock -Text $trailingText
                $secBlock.Children.Add($pText) | Out-Null
            }

            $ContentPanel.Children.Add($secBlock) | Out-Null
            continue
        }

        # Bullet List Check
        if ($line -match '^[\*\-\u2022]\s+(.+)') {
            $itemContent = $matches[1]

            $listGrid = New-Object System.Windows.Controls.Grid
            $listGrid.Margin = [System.Windows.Thickness]::new(6, 4, 0, 4)

            $c0 = New-Object System.Windows.Controls.ColumnDefinition; $c0.Width = [System.Windows.GridLength]::Auto
            $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
            $listGrid.ColumnDefinitions.Add($c0)
            $listGrid.ColumnDefinitions.Add($c1)

            $bullet = New-Object System.Windows.Controls.Border
            $bullet.Width = 5
            $bullet.Height = 5
            $bullet.CornerRadius = [System.Windows.CornerRadius]::new(2.5)
            $bullet.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
            $bullet.Margin = [System.Windows.Thickness]::new(0, 8, 12, 0)
            $bullet.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
            [System.Windows.Controls.Grid]::SetColumn($bullet, 0)
            $listGrid.Children.Add($bullet) | Out-Null

            $bText = Create-FormattedTextBlock -Text $itemContent
            [System.Windows.Controls.Grid]::SetColumn($bText, 1)
            $listGrid.Children.Add($bText) | Out-Null

            $ContentPanel.Children.Add($listGrid) | Out-Null
            continue
        }

        # Standard Paragraph
        $paraText = Create-FormattedTextBlock -Text $line
        $paraText.Margin = [System.Windows.Thickness]::new(0, 2, 0, 10)
        $ContentPanel.Children.Add($paraText) | Out-Null
    }

    $ContentPanel.Visibility = [System.Windows.Visibility]::Visible
}

# ==============================================================================
# 4. ATOMIC EXECUTION PIPELINE WITH FIFO SUMMARY & RECENCY BUFFER
# ==============================================================================
$ExecuteQuery = {
    param([string]$QueryText)

    if ($script:IsProcessing) { return }
    if ([string]::IsNullOrWhiteSpace($QueryText)) { return }

    $script:IsProcessing = $true

    $AiBtnSend.IsEnabled = $false
    $AiChatInput.IsEnabled = $false

    $btnTemplate = $AiBtnSend.Template
    $sendPath = $btnTemplate.FindName("SendIconPath", $AiBtnSend)
    if ($sendPath) {
        $sendPath.Data = [System.Windows.Media.Geometry]::Parse($script:ICON_BUSY)
    }

    try {
        Render-UserMessage -Text $QueryText
        $AiChatInput.Text = ""

        # Resolve selected model
        $selectedItem = $AiModelComboBox.SelectedItem
        $selectedDisplay = if ($selectedItem -is [System.Windows.Controls.ComboBoxItem]) { $selectedItem.Content.ToString() } else { $selectedItem.ToString() }
        $actualModel = if ($script:ModelMap.ContainsKey($selectedDisplay)) { $script:ModelMap[$selectedDisplay] } else { "gemma3:1b" }

        # Render Assistant Card
        $ui = Render-AssistantMessageCard
        $swTotal = [System.Diagnostics.Stopwatch]::StartNew()

        # Step 1: Model Lock
        Add-ProcessTelemetryRow -Container $ui.DetailsContainer -StepNumber "01" -Text "Target Model: $actualModel" -Color "#FFFFFF"

        # Step 2: Knowledge Base Load
        $null = Initialize-RagEngine
        $docCount = if ($script:WHS_KnowledgeBase) { $script:WHS_KnowledgeBase.Count } else { 598 }
        Add-ProcessTelemetryRow -Container $ui.DetailsContainer -StepNumber "02" -Text "Knowledge Base: $docCount chunks active in memory" -Color "#999999"

        # Step 3: Retrieval & Memory Query Contextualization
        Add-ProcessTelemetryRow -Container $ui.DetailsContainer -StepNumber "03" -Text "Resolving conversational recency & embeddings..." -Color "#AAAAAA"

        # Pass both the Verbatim Recency Window and FIFO Summary Bullets into Engine
        $res = Invoke-WHSAssistantQuery -UserQuery $QueryText -Model $actualModel -RecentTurns $script:RecentTurns -SummaryBullets $script:SummaryBullets
        $swTotal.Stop()

        # Update Step 3
        if ($ui.DetailsContainer.Children.Count -gt 2) {
            $ui.DetailsContainer.Children.RemoveAt($ui.DetailsContainer.Children.Count - 1)
        }

        if ($res.Docs -and $res.Docs.Count -gt 0) {
            Add-ProcessTelemetryRow -Container $ui.DetailsContainer -StepNumber "03" -Text "Synthesized $($res.Docs.Count) grounded sources in $($res.RetrievalMs) ms:" -Color "#CCCCCC"
            foreach ($d in $res.Docs) {
                $scoreText = if ($d.SearchScore) { "Score: " + $d.SearchScore } else { "" }
                Add-TelemetrySourceRow -Container $ui.DetailsContainer -SourceId $d.id -Title $d.title -Score $scoreText -Safety $d.safety_level
            }
        } else {
            Add-ProcessTelemetryRow -Container $ui.DetailsContainer -StepNumber "03" -Text "Conversational dialogue / meta inquiry processed in $($res.RetrievalMs) ms" -Color "#888888"
        }

        # Step 4: Generation Complete
        Add-ProcessTelemetryRow -Container $ui.DetailsContainer -StepNumber "04" -Text "Synthesis complete in $($res.GenerationMs) ms" -Color "#FFFFFF"

        # Update Header Badge
        $sourceCount = if ($res.Docs) { $res.Docs.Count } else { 0 }
        $ui.StatsBadge.Text = "$sourceCount sources | $($swTotal.ElapsedMilliseconds) ms"
        $ui.StatsBadge.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#8CD97E")

        # Hide analyzing loading container
        $ui.LoadingContainer.Visibility = [System.Windows.Visibility]::Collapsed

        # Render Content with Sections & Bullets
        Render-ConversationalMarkdown -ContentPanel $ui.ContentPanel -RawText $res.Reply

        # =====================================================================
        # ROLLING BUFFER: FIFO FORGETTING OF OLD DATA, STRICT RETENTION OF LATEST
        # =====================================================================
        if ($res.Success -and -not [string]::IsNullOrWhiteSpace($res.Reply)) {
            # 1. Add latest exchange verbatim to recent turns
            $script:RecentTurns.Add([PSCustomObject]@{ role = "user"; content = $QueryText })

            # Store the FULL assistant reply (lightly capped) in the active recency
            # window so follow-up questions retain exact technical details such as
            # registry paths, value names, and parameters. Only get compressed down
            # to a short line once evicted into the long-term FIFO summary below.
            $fullReplyForMemory = $res.Reply
            if ($fullReplyForMemory.Length -gt 1500) {
                $fullReplyForMemory = $fullReplyForMemory.Substring(0, 1500) + "..."
            }
            $script:RecentTurns.Add([PSCustomObject]@{ role = "assistant"; content = $fullReplyForMemory })

            # 2. When recent turns exceed 8 messages (4 exchanges), evict oldest turn to summary
            if ($script:RecentTurns.Count -gt 8) {
                $evictedUser = $script:RecentTurns[0].content
                $evictedAsstFull = $script:RecentTurns[1].content
                $script:RecentTurns.RemoveAt(0)
                $script:RecentTurns.RemoveAt(0)

                # Condense the evicted assistant reply down to a short line only now,
                # at the point it leaves the active window (not when it was stored),
                # so it still carries a summary of what advice was actually given.
                $evictedAsst = Extract-CoreSummary -Text $evictedAsstFull

                # Condense evicted exchange into a single 1-line memory bullet
                $condensedBullet = "User inquired about '$evictedUser'; Assistant advised: $evictedAsst"
                $script:SummaryBullets.Add($condensedBullet)

                # FIFO Queue: Cap summary bullets to 3 items. Oldest bullets are FORGOTTEN!
                while ($script:SummaryBullets.Count -gt 3) {
                    $script:SummaryBullets.RemoveAt(0)
                }
            }
        }
    }
    catch {
        [System.Windows.MessageBox]::Show("Pipeline Error: $_", "WHS Assistant")
    }
    finally {
        $script:IsProcessing = $false
        $AiBtnSend.IsEnabled = $true
        $AiChatInput.IsEnabled = $true

        if ($sendPath) {
            $sendPath.Data = [System.Windows.Media.Geometry]::Parse($script:ICON_SEND)
        }

        $AiChatScrollViewer.ScrollToBottom()
        $AiChatInput.Focus()
        Sync-UI
    }
}

# 5. Wire Events
$AiBtnSend.Add_Click({ & $ExecuteQuery -QueryText $AiChatInput.Text.Trim() })
$AiChatInput.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Enter) {
        & $ExecuteQuery -QueryText $AiChatInput.Text.Trim()
    }
})

# Clear Chat: Wipes UI, Recency Buffer, and Rolling Summary completely
if ($AiBtnClear) {
    $AiBtnClear.Add_Click({
        if ($script:IsProcessing) { return }
        $script:RecentTurns.Clear()
        $script:SummaryBullets.Clear()
        $script:WHS_LastTopicAnchor = $null
        $AiChatPanel.Children.Clear()
        if ($AiWelcomeHero) {
            $AiChatPanel.Children.Add($AiWelcomeHero) | Out-Null
            $AiWelcomeHero.Visibility = [System.Windows.Visibility]::Visible
        }
    })
}

# Chips
if ($ChipStandby)   { $ChipStandby.Add_Click({ & $ExecuteQuery -QueryText "Why does my laptop get hot and drain battery while sleeping in my backpack?" }) }
if ($ChipGaming)    { $ChipGaming.Add_Click({ & $ExecuteQuery -QueryText "What are the best safe tweaks for gaming performance?" }) }
if ($ChipTelemetry) { $ChipTelemetry.Add_Click({ & $ExecuteQuery -QueryText "Why should I disable telemetry and is it safe?" }) }
if ($ChipEdge)      { $ChipEdge.Add_Click({ & $ExecuteQuery -QueryText "Is it safe to force remove Microsoft Edge?" }) }

# 6. Show Window
$window.ShowDialog() | Out-Null