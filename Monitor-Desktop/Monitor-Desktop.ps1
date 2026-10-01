param([switch]$InstallStartup, [switch]$RemoveStartup)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName @('PresentationFramework', 'PresentationCore', 'WindowsBase')
$dataDir = Join-Path $env:LOCALAPPDATA 'MonitorDesktop'
[void][IO.Directory]::CreateDirectory($dataDir)
$settingsFile = Join-Path $dataDir 'preferencias.json'
$startupFile = Join-Path ([Environment]::GetFolderPath('Startup')) 'Monitor Desktop.lnk'
if ($RemoveStartup) {
    Remove-Item -LiteralPath $startupFile -Force -ErrorAction SilentlyContinue
    [void][Windows.MessageBox]::Show('Inicio automatico desativado.', 'Monitor Desktop'); exit
}
if ($InstallStartup) {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($startupFile)
    $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
    $shortcut.WorkingDirectory = $PSScriptRoot
    $shortcut.Save()
    [void][Windows.MessageBox]::Show('O painel abrira no proximo login. Mantenha a pasta no mesmo local.', 'Monitor Desktop'); exit
}
$restoreEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::AutoReset, 'Local\MonitorDesktopRestore')
$created = $false
$mutex = New-Object Threading.Mutex($true, 'Local\MonitorDesktop', [ref]$created)
if (-not $created) { [void]$restoreEvent.Set(); $restoreEvent.Dispose(); $mutex.Dispose(); exit }
$script:collector = $null; $script:urlWorker = $null; $script:timer = $null
try {
    [xml]$xaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Painel.xaml') -Raw -Encoding UTF8
    $reader = New-Object Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $ui = @{}
    foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
        $name = $node.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($name) { $ui[$name] = $window.FindName($name) }
    }
    $script:sample = $null; $script:previous = $null
    $script:collectHandle = $null; $script:urlHandle = $null
    $script:nextCollect = [DateTime]::MinValue; $script:nextUrl = [DateTime]::MaxValue
    $script:urlResults = @(); $script:urlHistory = @(); $script:showHistory = $false
    $script:oldDiskUsage = @{}
    $script:pages = @{ Processes = 0; Connections = 0; Services = 0; Sensors = 0; Adapters = 0; Urls = 0 }
    $script:settings = $null
    if (Test-Path -LiteralPath $settingsFile) {
        try { $script:settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json } catch { }
    }
    function Format-Size($bytes) {
        if ($null -eq $bytes) { return '--' }
        if ($bytes -ge 1099511627776) { return ('{0:N2} TiB' -f ($bytes / 1099511627776)) }
        if ($bytes -ge 1073741824) { return ('{0:N1} GiB' -f ($bytes / 1073741824)) }
        if ($bytes -ge 1048576) { return ('{0:N1} MiB' -f ($bytes / 1048576)) }
        return ('{0:N1} KiB' -f ($bytes / 1024))
    }
    function Format-Rate($bytes) { if ($null -eq $bytes) { return '--' }; return ((Format-Size $bytes) + '/s') }
    function Escape-Xml([string]$value) { return [Security.SecurityElement]::Escape($value) }
    function Animate-Value($element, $property, [double]$from, [double]$to, [int]$duration) {
        if (-not [Windows.SystemParameters]::ClientAreaAnimation -or [Math]::Abs($to - $from) -lt 0.01) { return }
        $animation = New-Object Windows.Media.Animation.DoubleAnimation
        $animation.From = $from; $animation.To = $to
        $animation.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds($duration))
        $ease = New-Object Windows.Media.Animation.CubicEase
        $ease.EasingMode = [Windows.Media.Animation.EasingMode]::EaseOut
        $animation.EasingFunction = $ease
        $animation.FillBehavior = [Windows.Media.Animation.FillBehavior]::Stop
        $element.BeginAnimation($property, $animation)
    }
    function Get-PanelOpacity { if ($ui.SemiOption.IsChecked -eq $true) { return 0.5 }; return 1.0 }
    function Set-PanelOpacity([bool]$animate = $true) {
        $from = $window.Opacity
        $window.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
        $target = Get-PanelOpacity; $window.Opacity = $target
        if ($animate) { Animate-Value $window ([Windows.UIElement]::OpacityProperty) $from $target 220 }
    }
    function Fit-Panel {
        $area = [Windows.SystemParameters]::WorkArea
        $ui.FitBox.MaxWidth = [Math]::Max(1, $area.Width - 24)
        $ui.FitBox.MaxHeight = [Math]::Max(1, $area.Height - 24)
        if ($window.IsLoaded) {
            $window.UpdateLayout()
            $window.Left = [Math]::Max($area.Left, [Math]::Min($window.Left, $area.Right - $window.ActualWidth))
            $window.Top = [Math]::Max($area.Top, [Math]::Min($window.Top, $area.Bottom - $window.ActualHeight))
        }
    }
    function Set-Metric([string]$key, [string]$value, [string]$detail) {
        $ui[$key + 'Value'].Text = $value
        $ui[$key + 'Detail'].Text = $detail
        $ui[$key + 'Detail'].ToolTip = $detail
    }
    function Set-UsageBar([string]$key, $value) {
        $bar = $ui[$key + 'Bar']
        if ($null -eq $value) { $bar.Visibility = [Windows.Visibility]::Hidden; return }
        $bar.Visibility = [Windows.Visibility]::Visible
        $from = $bar.Value
        $bar.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $null)
        $target = [Math]::Max(0, [Math]::Min(100, [double]$value))
        $bar.Value = $target
        $tone = 'Healthy'
        if ($target -ge 90) { $tone = 'Critical' } elseif ($target -ge 75) { $tone = 'Warning' }
        $bar.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, $tone)
        Animate-Value $bar ([Windows.Controls.Primitives.RangeBase]::ValueProperty) $from $target 650
    }
    function Render-Overview {
        $s = $script:sample
        $cpuText = '--'
        if ($null -ne $s.CPU) { $cpuText = '{0:N0}%' -f $s.CPU }
        Set-UsageBar 'CPU' $s.CPU
        Set-Metric 'CPU' $cpuText ([string][Environment]::ProcessorCount + ' processadores logicos')
        $ramText = '--'; $ramDetail = 'Leitura indisponivel'
        if ($null -ne $s.RamTotal -and $s.RamTotal -gt 0) {
            $ramText = '{0:N0}%' -f (100 * $s.RamUsed / $s.RamTotal)
            $ramDetail = (Format-Size $s.RamUsed) + ' usados de ' + (Format-Size $s.RamTotal)
        }
        $ramUsage = $null
        if ($null -ne $s.RamTotal -and $s.RamTotal -gt 0) { $ramUsage = 100 * $s.RamUsed / $s.RamTotal }
        Set-UsageBar 'RAM' $ramUsage
        Set-Metric 'RAM' $ramText $ramDetail
        Set-Metric 'Network' (Format-Rate $s.Download) ('Saida ' + (Format-Rate $s.Upload) + ' | entrada no destaque')
        Set-Metric 'DiskIO' (Format-Rate $s.DiskRead) ('Gravacao ' + (Format-Rate $s.DiskWrite))
        $gpuText = 'Indisponivel'
        if ($null -ne $s.GPU) { $gpuText = '{0:N0}%' -f $s.GPU }
        Set-UsageBar 'GPU' $s.GPU
        Set-Metric 'GPU' $gpuText ('Dedicada usada: ' + (Format-Size $s.GPUDedicated))
        $tempText = 'Sem sensores'; $tempDetail = 'Veja Hardware / Rede para configurar'
        if ($s.Sensors.Count -gt 0) {
            $hottest = $s.Sensors | Sort-Object Temperature -Descending | Select-Object -First 1
            $tempText = '{0:N1} °C' -f $hottest.Temperature
            $tempDetail = 'Maior leitura: ' + $hottest.Device + ' / ' + $hottest.Name
        }
        Set-Metric 'Temperature' $tempText $tempDetail
        $ui.DrivesPanel.Children.Clear()
        foreach ($disk in $s.Disks) {
            if ($disk.Error) {
                $notice = New-Object Windows.Controls.TextBlock
                $notice.Text = $disk.Name + ': indisponivel'
                $notice.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Warning')
                [void]$ui.DrivesPanel.Children.Add($notice); continue
            }
            $freePct = 100 - $disk.Used; $tone = 'Healthy'
            if ($freePct -lt 10) { $tone = 'Critical' } elseif ($freePct -lt 20) { $tone = 'Warning' }
            $title = Escape-Xml ($disk.Name + ' ' + $disk.Label)
            $main = Escape-Xml ((Format-Size $disk.Free) + ' livres')
            $detail = Escape-Xml ('de ' + (Format-Size $disk.Total) + (' | {0:N0}% livre' -f $freePct))
            $rates = Escape-Xml ('L ' + (Format-Rate $disk.Read) + ' | G ' + (Format-Rate $disk.Write))
            $usage = ([double]$disk.Used).ToString('F2', [Globalization.CultureInfo]::InvariantCulture)
            [xml]$cardXml = @"
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Background="{DynamicResource Card}" CornerRadius="8" Padding="10" Margin="0,0,7,7" Height="110">
 <StackPanel><TextBlock Text="$title" FontSize="11" TextTrimming="CharacterEllipsis" ToolTip="$title"/><TextBlock Text="$main" FontSize="18" FontWeight="SemiBold" Margin="0,3,0,0"/><TextBlock Text="$detail" Foreground="{DynamicResource Muted}" FontSize="10" Margin="0,3,0,7"/><ProgressBar x:Name="Bar" Value="$usage" Maximum="100" Height="5" Foreground="{DynamicResource $tone}" Background="{DynamicResource Track}" BorderThickness="0" ToolTip="Espaco ocupado"/><TextBlock Text="$rates" Foreground="{DynamicResource Muted}" FontSize="10" Margin="0,7,0,0"/></StackPanel>
</Border>
"@
            $cardReader = New-Object Xml.XmlNodeReader $cardXml
            $card = [Windows.Markup.XamlReader]::Load($cardReader)
            [void]$ui.DrivesPanel.Children.Add($card)
            $from = 0.0
            if ($script:oldDiskUsage.ContainsKey($disk.Name)) { $from = $script:oldDiskUsage[$disk.Name] }
            Animate-Value ($card.FindName('Bar')) ([Windows.Controls.Primitives.RangeBase]::ValueProperty) $from $disk.Used 650
            $script:oldDiskUsage[$disk.Name] = $disk.Used
        }
        if ($s.Disks.Count -eq 0) {
            $notice = New-Object Windows.Controls.TextBlock
            $notice.Text = 'Nenhuma unidade local disponivel.'
            [void]$ui.DrivesPanel.Children.Add($notice)
        }
        $top = @($s.Processes | Sort-Object -Property @('CPU', 'RAM') -Descending | Select-Object -First 3 | ForEach-Object { $_.Name + ' (PID ' + $_.PID + ')' })
        $ui.TopProcesses.Text = 'Maior consumo: ' + ($top -join '  |  ')
        $ui.MachineInfo.Text = $env:COMPUTERNAME + ' | ligado ha ' + $s.Uptime + ' | ' + $s.Processes.Count + ' processos'
        $ui.GPUInfo.Text = 'GPU: ' + $s.GPUName + "`nMemoria dedicada usada: " + (Format-Size $s.GPUDedicated) + ' | compartilhada usada: ' + (Format-Size $s.GPUShared) + ' | carga do motor mais ocupado: ' + $gpuText
        $ui.SensorHelp.Text = 'Leituras do Libre Hardware Monitor/Open Hardware Monitor, quando disponiveis via WMI. Zonas ACPI sao identificadas separadamente e nao equivalem a temperatura da CPU.'
        $ui.Updated.Text = 'Dados ' + $s.Finished.ToString('HH:mm:ss') + ' | coleta em segundo plano'
        $ui.Notes.Text = $s.Notes
    }
    function Get-Rows([string]$prefix) {
        if ($prefix -eq 'Urls') {
            if ($script:showHistory) { return $script:urlHistory }
            return $script:urlResults
        }
        if ($null -eq $script:sample) { return @() }
        $rows = @($script:sample.$prefix)
        if ($prefix -eq 'Adapters') {
            $rows = @($script:sample.Network | ForEach-Object { [pscustomobject]@{ Name = $_.Name; IP = $_.IP; Link = $_.Link; DownloadText = Format-Rate $_.Download; UploadText = Format-Rate $_.Upload } })
        }
        if ($ui.ContainsKey($prefix + 'Search')) {
            $query = $ui[$prefix + 'Search'].Text.Trim()
            if ($query) {
                $rows = @($rows | Where-Object {
                    $content = ($_.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join ' '
                    $content.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0
                })
            }
        }
        switch ($prefix) {
            'Processes' {
                switch ($ui.ProcessesSort.SelectedIndex) {
                    1 { $rows = @($rows | Sort-Object RAM -Descending) }
                    2 { $rows = @($rows | Sort-Object Name) }
                    3 { $rows = @($rows | Sort-Object PID) }
                    default { $rows = @($rows | Sort-Object -Property @('CPU', 'RAM') -Descending) }
                }
            }
            'Connections' { $rows = @($rows | Sort-Object -Property @('Name', 'PID', 'Protocol', 'Local')) }
            'Services' { $rows = @($rows | Sort-Object Name) }
            'Sensors' { $rows = @($rows | Sort-Object Temperature -Descending) }
        }
        return $rows
    }
    function Render-Table([string]$prefix) {
        $rows = @(Get-Rows $prefix)
        $size = 12
        if ($prefix -eq 'Urls') { $size = 8 }
        if ($prefix -eq 'Sensors') { $size = 6 }
        if ($prefix -eq 'Adapters') { $size = 4 }
        $totalPages = [Math]::Max(1, [Math]::Ceiling($rows.Count / [double]$size))
        $script:pages[$prefix] = [int][Math]::Max(0, [Math]::Min($script:pages[$prefix], $totalPages - 1))
        $pageRows = @($rows | Select-Object -Skip ($script:pages[$prefix] * $size) -First $size)
        $table = $ui[$prefix + 'Table']
        $selected = $table.SelectedItem
        $table.ItemsSource = $pageRows
        if ($null -ne $selected) {
            $match = @($pageRows | Where-Object {
                if ($prefix -eq 'Processes') { $_.Identity -eq $selected.Identity }
                elseif ($prefix -eq 'Connections') { $_.PID -eq $selected.PID -and $_.Local -eq $selected.Local -and $_.Remote -eq $selected.Remote -and $_.Protocol -eq $selected.Protocol }
                elseif ($prefix -eq 'Services') { $_.Name -eq $selected.Name }
                else { $false }
            } | Select-Object -First 1)
            if ($match.Count) { $table.SelectedItem = $match[0] }
        }
        if ($ui.ContainsKey($prefix + 'Page')) { $ui[$prefix + 'Page'].Text = '{0} registros | pagina {1}/{2}' -f $rows.Count, ($script:pages[$prefix] + 1), $totalPages }
        if ($ui.ContainsKey($prefix + 'Prev')) { $ui[$prefix + 'Prev'].IsEnabled = ($script:pages[$prefix] -gt 0) }
        if ($ui.ContainsKey($prefix + 'Next')) { $ui[$prefix + 'Next'].IsEnabled = ($script:pages[$prefix] -lt $totalPages - 1) }
    }
    function Render-Tables { foreach ($prefix in @('Processes', 'Connections', 'Services', 'Sensors', 'Adapters', 'Urls')) { Render-Table $prefix } }
    foreach ($prefix in @('Processes', 'Connections', 'Services', 'Sensors', 'Adapters', 'Urls')) {
        if ($ui.ContainsKey($prefix + 'Search')) {
            $ui[$prefix + 'Search'].Add_TextChanged({
                param($sender, $eventArgs)
                $key = $sender.Name -replace 'Search$', ''
                $script:pages[$key] = 0; Render-Table $key
            })
        }
        if ($ui.ContainsKey($prefix + 'Prev')) {
            $ui[$prefix + 'Prev'].Add_Click({
                param($sender, $eventArgs)
                $key = $sender.Name -replace 'Prev$', ''
                $script:pages[$key]--; Render-Table $key
            })
            $ui[$prefix + 'Next'].Add_Click({
                param($sender, $eventArgs)
                $key = $sender.Name -replace 'Next$', ''
                $script:pages[$key]++; Render-Table $key
            })
        }
        if ($ui.ContainsKey($prefix + 'Copy')) {
            $ui[$prefix + 'Copy'].Add_Click({
                param($sender, $eventArgs)
                $key = $sender.Name -replace 'Copy$', ''
                $selected = $ui[$key + 'Table'].SelectedItem
                if ($null -ne $selected) { try { [Windows.Clipboard]::SetText([string]$selected.PID) } catch { } }
            })
        }
        if ($ui.ContainsKey($prefix + 'Detail')) {
            $ui[$prefix + 'Table'].Add_SelectionChanged({
                param($sender, $eventArgs)
                $key = $sender.Name -replace 'Table$', ''
                $selected = $sender.SelectedItem
                $text = 'Selecione uma linha para ver os detalhes.'
                if ($null -ne $selected) {
                    if ($key -eq 'Processes') { $text = 'PID ' + $selected.PID + ' | ' + $selected.Name + "`n" + $selected.Path }
                    elseif ($key -eq 'Services') { $text = 'PID ' + $selected.PID + ' | ' + $selected.Display + "`n" + $selected.Path }
                    elseif ($key -eq 'Connections') { $text = 'PID ' + $selected.PID + ' | ' + $selected.Name + ' | ' + $selected.Protocol + ' | ' + $selected.State + "`n" + $selected.Local + ' -> ' + $selected.Remote }
                    elseif ($key -eq 'Urls') { $text = $selected.Final + "`n" + $selected.Detail }
                }
                $ui[$key + 'Detail'].Text = $text
            })
        }
    }
    $ui.ProcessesSort.Add_SelectionChanged({ $script:pages.Processes = 0; Render-Table 'Processes' })
    $ui.SemiOption.Add_Checked({ Set-PanelOpacity })
    $ui.FullOption.Add_Checked({ Set-PanelOpacity })
    $ui.PinCheck.Add_Checked({ $window.Topmost = $true })
    $ui.PinCheck.Add_Unchecked({ $window.Topmost = $false })
    $ui.CloseButton.Add_Click({ $window.Close() })
    $ui.Header.Add_MouseLeftButtonDown({
        param($sender, $eventArgs)
        $source = $eventArgs.OriginalSource
        while ($null -ne $source) {
            if ($source -is [Windows.Controls.Button]) { return }
            try { $source = [Windows.Media.VisualTreeHelper]::GetParent($source) } catch { break }
        }
        $window.DragMove()
    })
    $ui.Tabs.Add_SelectionChanged({ param($sender, $eventArgs); if ($eventArgs.Source -eq $ui.Tabs) { Fit-Panel } })
    $script:collector = [PowerShell]::Create()
    $script:urlWorker = [PowerShell]::Create()
    function Start-Collection {
        $script:collector.Commands.Clear(); $script:collector.Streams.Error.Clear()
        [void]$script:collector.AddCommand((Join-Path $PSScriptRoot 'Coletar.ps1')).AddParameter('Previous', $script:previous)
        $script:collectHandle = $script:collector.BeginInvoke()
    }
    function Start-UrlCheck {
        if ($null -ne $script:urlHandle) { return }
        $urls = @($ui.UrlInput.Text -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($urls.Count -eq 0) { $ui.UrlStatus.Text = 'Adicione pelo menos uma URL.'; return }
        if ($urls.Count -gt 50) { $ui.UrlStatus.Text = 'Use no maximo 50 URLs por lista.'; return }
        $script:urlWorker.Commands.Clear(); $script:urlWorker.Streams.Error.Clear()
        [void]$script:urlWorker.AddCommand((Join-Path $PSScriptRoot 'Verificar-URLs.ps1')).AddParameter('Urls', [string[]]$urls)
        $script:urlHandle = $script:urlWorker.BeginInvoke()
        $ui.UrlCheck.IsEnabled = $false
        $ui.UrlStatus.Text = 'Verificando ' + $urls.Count + ' URLs em segundo plano...'
        $script:nextUrl = [DateTime]::MaxValue
    }
    $ui.UrlCheck.Add_Click({ Start-UrlCheck })
    $ui.UrlAuto.Add_Checked({ $script:nextUrl = Get-Date })
    $ui.UrlAuto.Add_Unchecked({ $script:nextUrl = [DateTime]::MaxValue })
    $ui.UrlHistoryToggle.Add_Click({
        $script:showHistory = -not $script:showHistory
        if ($script:showHistory) { $ui.UrlHistoryToggle.Content = 'Ver atuais' } else { $ui.UrlHistoryToggle.Content = 'Ver historico' }
        $script:pages.Urls = 0; Render-Table 'Urls'
    })
    $ui.UrlExport.Add_Click({
        $rows = @(Get-Rows 'Urls')
        if ($rows.Count -eq 0) { $ui.UrlStatus.Text = 'Nenhum resultado para exportar.'; return }
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = 'CSV (*.csv)|*.csv'; $dialog.FileName = 'URLs-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv'
        if ($dialog.ShowDialog() -eq $true) {
            try { $rows | Select-Object -Property @('Url', 'Status', 'Milliseconds', 'Checked', 'Detail', 'Final') | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';'; $ui.UrlStatus.Text = 'CSV exportado.' }
            catch { $ui.UrlStatus.Text = 'Nao foi possivel exportar: ' + $_.Exception.Message }
        }
    })
    $window.Add_ContentRendered({
        Fit-Panel
        $area = [Windows.SystemParameters]::WorkArea
        $window.Left = $area.Right - $window.ActualWidth - 12; $window.Top = $area.Top + 12
        if ($null -ne $script:settings) {
            try {
                $window.Left = [double]$script:settings.Left; $window.Top = [double]$script:settings.Top
                $ui.PinCheck.IsChecked = [bool]$script:settings.Topmost
                if ($script:settings.Opacity -eq 50) { $ui.SemiOption.IsChecked = $true }
                $ui.UrlInput.Text = [string]$script:settings.Urls
                $ui.UrlAuto.IsChecked = [bool]$script:settings.UrlAuto
            } catch { }
        }
        Fit-Panel; Set-PanelOpacity -animate $false
        Animate-Value $window ([Windows.UIElement]::OpacityProperty) 0 (Get-PanelOpacity) 350
    })
    $script:timer = New-Object Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:timer.Add_Tick({
        try {
            if ($restoreEvent.WaitOne(0)) { $ui.FullOption.IsChecked = $true; Set-PanelOpacity; [void]$window.Activate() }
            if ($null -ne $script:collectHandle -and $script:collectHandle.IsCompleted) {
                try {
                    $result = @($script:collector.EndInvoke($script:collectHandle))
                    if ($result.Count -gt 0) {
                        $script:sample = $result[-1]; $script:previous = $script:sample.Next
                        Render-Overview; Render-Tables; Fit-Panel
                    } else { $ui.Notes.Text = 'Coleta indisponivel. Tentando novamente em 5 s.' }
                } catch { $ui.Notes.Text = 'Falha na coleta: ' + $_.Exception.Message }
                $script:collectHandle = $null; $script:nextCollect = (Get-Date).AddSeconds(5)
            }
            if ($null -eq $script:collectHandle -and (Get-Date) -ge $script:nextCollect) { Start-Collection }
            if ($null -ne $script:urlHandle -and $script:urlHandle.IsCompleted) {
                try {
                    $script:urlResults = @($script:urlWorker.EndInvoke($script:urlHandle))
                    $script:urlHistory = @(@($script:urlResults) + @($script:urlHistory) | Select-Object -First 200)
                    Render-Table 'Urls'
                    $ui.UrlStatus.Text = 'Concluido: ' + $script:urlResults.Count + ' URLs. 200 verde | 404 vermelho | demais amarelo.'
                } catch { $ui.UrlStatus.Text = 'Falha na verificacao: ' + $_.Exception.Message }
                $script:urlHandle = $null; $ui.UrlCheck.IsEnabled = $true
                $script:nextUrl = (Get-Date).AddSeconds(60)
            }
            if ($ui.UrlAuto.IsChecked -eq $true -and $null -eq $script:urlHandle -and (Get-Date) -ge $script:nextUrl) {
                $script:nextUrl = (Get-Date).AddSeconds(60); Start-UrlCheck
            }
        } catch { $ui.Notes.Text = 'Erro de atualizacao: ' + $_.Exception.Message }
    })
    $window.Add_Closing({
        $script:timer.Stop()
        try {
            @{ Left = $window.Left; Top = $window.Top; Topmost = $window.Topmost; Opacity = ((Get-PanelOpacity) * 100); Urls = $ui.UrlInput.Text; UrlAuto = [bool]$ui.UrlAuto.IsChecked } |
                ConvertTo-Json | Set-Content -LiteralPath $settingsFile -Encoding UTF8
        } catch { }
    })
    Render-Tables; Fit-Panel
    $script:timer.Start()
    [void]$window.ShowDialog()
} catch {
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $dataDir 'erro.txt') -Encoding UTF8
    [void][Windows.MessageBox]::Show('Nao foi possivel abrir o painel. Detalhes em ' + $dataDir + '\erro.txt', 'Monitor Desktop')
} finally {
    if ($null -ne $script:timer) { $script:timer.Stop() }
    foreach ($worker in @($script:collector, $script:urlWorker)) {
        if ($null -ne $worker) { try { $worker.Stop(); $worker.Dispose() } catch { } }
    }
    $restoreEvent.Dispose(); $mutex.ReleaseMutex(); $mutex.Dispose()
}
