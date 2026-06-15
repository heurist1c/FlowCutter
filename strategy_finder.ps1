#Requires -Version 3.0
# strategy_finder.ps1 - FlowCutter

$rootDir = Split-Path $MyInvocation.MyCommand.Path
$binDir = Join-Path $rootDir "bin"
$listsDir = Join-Path $rootDir "lists"
$utilsDir = Join-Path $rootDir "utils"

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# --- Utility Functions ---
function Stop-Winws {
    Get-Process -Name "winws" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Start-BatHidden {
    param([string]$BatPath, [string]$WorkDir)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cmd.exe"
    $psi.Arguments = "/c `"$BatPath`""
    $psi.WorkingDirectory = $WorkDir
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { [void][System.Diagnostics.Process]::Start($psi) } catch {}
}

function Start-WinwsHidden {
    param([string]$BatPath, [string]$WorkDir)
    $rawLines = Get-Content $BatPath -ErrorAction SilentlyContinue
    if (-not $rawLines) { return }

    $inCommand = $false
    $cmdParts = @()
    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match 'winws\.exe') {
            $afterExe = $trimmed -replace '.*winws\.exe\s*', ''
            $afterExe = $afterExe -replace '^\s*/min\s*', ''
            $cmdParts += $afterExe
            $inCommand = $true
            continue
        }
        if ($inCommand) {
            if ($trimmed.EndsWith('^')) {
                $cmdParts += $trimmed.TrimEnd('^').Trim()
            } else {
                $cmdParts += $trimmed
                $inCommand = $false
            }
        }
    }

    if ($cmdParts.Count -eq 0) { return }

    $fullCmd = $cmdParts -join ' '
    $fullCmd = $fullCmd -replace '%~dp0', "$WorkDir\"
    $binPath = Join-Path $WorkDir "bin"
    $listsPath = Join-Path $WorkDir "lists"
    $fullCmd = $fullCmd -replace '%BIN%', $binPath
    $fullCmd = $fullCmd -replace '%LISTS%', $listsPath
    $fullCmd = $fullCmd -replace '%GameFilterTCP%', '12'
    $fullCmd = $fullCmd -replace '%GameFilterUDP%', '12'

    $exe = Join-Path $binPath "winws.exe"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $fullCmd
    $psi.WorkingDirectory = $binPath
    $psi.CreateNoWindow = $true
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    try { [void][System.Diagnostics.Process]::Start($psi) } catch {}
}

function Test-TargetUrl {
    param([string]$Url, [int]$TimeoutSeconds = 5)
    foreach ($test in @(
        @{ Args=@("--http1.1") },
        @{ Args=@("--tlsv1.2","--tls-max","1.2") },
        @{ Args=@("--tlsv1.3","--tls-max","1.3") }
    )) {
        try {
            $curlArgs = @("-I","-s","-m",$TimeoutSeconds,"-o","NUL","-w","%{http_code}","--show-error") + $test.Args + @($Url)
            $out = & curl.exe @curlArgs 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -and $out.Trim() -match '^\d{3}$') { return $true }
        } catch {}
    }
    return $false
}

function Read-DomainsFromFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    Get-Content $Path -ErrorAction SilentlyContinue |
        Where-Object { $_.Trim() -ne '' -and $_.Trim() -notlike '#*' } |
        ForEach-Object { $_.Trim() }
}

function Write-DomainsToFile {
    param([string]$Path, [string[]]$Domains)
    $lines = @()
    $lines += "# FlowCutter user list"
    foreach ($d in ($Domains | Sort-Object -Unique)) {
        if ($d -match '^\S+$') { $lines += $d }
    }
    if ($lines.Count -eq 1) { $lines += "# Add domains below this line" }
    [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.Encoding]::UTF8)
}

function Get-GameFilterStatus {
    $flagFile = Join-Path $utilsDir "game_filter.enabled"
    if (-not (Test-Path $flagFile)) { return "Disabled" }
    $mode = (Get-Content $flagFile -First 1 -ErrorAction SilentlyContinue).Trim()
    switch ($mode) {
        "all" { return "TCP + UDP" }
        "tcp" { return "TCP only" }
        "udp" { return "UDP only" }
        default { return "Disabled" }
    }
}

function Set-GameFilterMode {
    param([string]$Mode)
    $flagFile = Join-Path $utilsDir "game_filter.enabled"
    if ($Mode -eq "Disabled") {
        if (Test-Path $flagFile) { Remove-Item $flagFile -Force }
    } else {
        $m = switch ($Mode) {
            "TCP + UDP" { "all" }
            "TCP only"  { "tcp" }
            "UDP only"  { "udp" }
        }
        $m | Out-File $flagFile -Encoding UTF8 -Force
    }
}

function Get-IPSetStatus {
    $listFile = Join-Path $listsDir "ipset-all.txt"
    if (-not (Test-Path $listFile)) { return "None" }
    $raw = (Get-Content $listFile -Raw -ErrorAction SilentlyContinue)
    if ($null -eq $raw -or $raw.Trim() -eq '') { return "Any" }
    $hasDummy = $raw -match '203\.0\.113\.113/32'
    if ($hasDummy) { return "None" } else { return "Loaded" }
}

function Get-UpdateCheckStatus {
    $flagFile = Join-Path $utilsDir "check_updates.enabled"
    if (Test-Path $flagFile) { return "Enabled" } else { return "Disabled" }
}

# --- XAML ---
$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="FlowCutter" Width="880" Height="680"
    WindowStartupLocation="CenterScreen" Background="#0f0f1a">
    <Window.Resources>
        <Style x:Key="BtnPurple" TargetType="Button">
            <Setter Property="Background" Value="#6c5ce7"/>
            <Setter Property="Foreground" Value="#ffffff"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="16,8"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#7c6cf7"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#5b4cd6"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#2d2d44"/>
                                <Setter Property="Foreground" Value="#555570"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="BtnGreen" TargetType="Button" BasedOn="{StaticResource BtnPurple}">
            <Setter Property="Background" Value="#00b894"/>
        </Style>
        <Style x:Key="BtnRed" TargetType="Button" BasedOn="{StaticResource BtnPurple}">
            <Setter Property="Background" Value="#d63031"/>
        </Style>
        <Style x:Key="BtnDark" TargetType="Button" BasedOn="{StaticResource BtnPurple}">
            <Setter Property="Background" Value="#2d2d44"/>
            <Setter Property="Foreground" Value="#aaaacc"/>
        </Style>
        <Style x:Key="TabBtn" TargetType="RadioButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#666680"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="20,10"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="GroupName" Value="Tabs"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <Border x:Name="bd" Background="{TemplateBinding Background}"
                                Padding="{TemplateBinding Padding}" CornerRadius="8,8,0,0">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1e1e36"/>
                                <Setter Property="Foreground" Value="#a29bfe"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#16162a"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="InputBox" TargetType="TextBox">
            <Setter Property="Background" Value="#16162a"/>
            <Setter Property="Foreground" Value="#ccccee"/>
            <Setter Property="BorderBrush" Value="#2a2a44"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="CaretBrush" Value="#a29bfe"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#0f0f1a" Offset="0"/>
                <GradientStop Color="#1a1a2e" Offset="1"/>
            </LinearGradientBrush>
        </Grid.Background>
        <Grid Margin="24,18,24,16">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <StackPanel Grid.Row="0" Margin="0,0,0,10">
                <TextBlock Text="FlowCutter" FontSize="26" FontWeight="Bold" Foreground="#6c5ce7"/>
            </StackPanel>

            <!-- Tabs -->
            <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,0">
                <RadioButton Name="TabScan" Content="Strategy Finder" Style="{StaticResource TabBtn}" IsChecked="True"/>
                <RadioButton Name="TabDomains" Content="Domains" Style="{StaticResource TabBtn}"/>
                <RadioButton Name="TabSettings" Content="Settings" Style="{StaticResource TabBtn}"/>
            </StackPanel>

            <!-- Tab content -->
            <Border Grid.Row="2" Background="#12121f" CornerRadius="0,10,10,10"
                    BorderThickness="1" BorderBrush="#2a2a44" Margin="0,0,0,12">

                <!-- TAB: Strategy Finder -->
                <Grid Name="PanelScan" Visibility="Visible">
                    <Grid Margin="16">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>
                        <Border Grid.Row="0" Background="#16162a" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
                            <TextBlock Name="StatusText" Text="Click 'Find Best' to scan all strategies"
                                       FontSize="12" Foreground="#8888aa"/>
                        </Border>
                        <DataGrid Grid.Row="1" Name="ResultsGrid" AutoGenerateColumns="False" IsReadOnly="True"
                                  Background="Transparent" Foreground="#ccccee"
                                  GridLinesVisibility="None" BorderThickness="0"
                                  RowBackground="Transparent" AlternatingRowBackground="#16162e"
                                  HeadersVisibility="Column" CanUserSortColumns="True"
                                  SelectionMode="Single">
                            <DataGrid.ColumnHeaderStyle>
                                <Style TargetType="DataGridColumnHeader">
                                    <Setter Property="Background" Value="#1e1e36"/>
                                    <Setter Property="Foreground" Value="#7777aa"/>
                                    <Setter Property="Padding" Value="10,6"/>
                                    <Setter Property="FontSize" Value="11"/>
                                    <Setter Property="FontWeight" Value="SemiBold"/>
                                    <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                    <Setter Property="BorderBrush" Value="#2a2a44"/>
                                </Style>
                            </DataGrid.ColumnHeaderStyle>
                            <DataGrid.Columns>
                                <DataGridTextColumn Header="#" Binding="{Binding Index}" Width="36"/>
                                <DataGridTextColumn Header="Strategy" Binding="{Binding StratName}" Width="*"/>
                                <DataGridTextColumn Header="Discord" Binding="{Binding DiscordDisplay}" Width="115"/>
                                <DataGridTextColumn Header="YouTube" Binding="{Binding YouTubeDisplay}" Width="115"/>
                                <DataGridTextColumn Header="Score" Binding="{Binding ScoreDisplay}" Width="68"/>
                            </DataGrid.Columns>
                        </DataGrid>
                        <Grid Grid.Row="2" Margin="0,10,0,10">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <Border Grid.Column="0" Background="#1a1a30" CornerRadius="5" Height="8"
                                    Margin="0,0,10,0" ClipToBounds="True">
                                <Border x:Name="ProgressFill" Background="#6c5ce7" CornerRadius="5"
                                        HorizontalAlignment="Left" Width="0" Height="8"/>
                            </Border>
                            <TextBlock Grid.Column="1" Name="ProgressText" Text="0%"
                                       FontSize="11" Foreground="#666680" VerticalAlignment="Center"/>
                        </Grid>
                        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
                            <Button Name="BtnFindBest" Content="Find Best" Style="{StaticResource BtnPurple}"
                                    Margin="0,0,8,0" MinWidth="110"/>
                            <Button Name="BtnLaunch" Content="Launch" Style="{StaticResource BtnGreen}"
                                    Margin="0,0,0,0" MinWidth="100" IsEnabled="False"/>
                        </StackPanel>
                    </Grid>
                </Grid>

                <!-- TAB: Domains -->
                <Grid Name="PanelDomains" Visibility="Hidden">
                    <Grid Margin="16">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                            <RowDefinition Height="Auto"/>
                        </Grid.RowDefinitions>

                        <!-- Add domain input -->
                        <TextBlock Grid.Row="0" Text="Domain:" FontSize="12" Foreground="#8888aa" Margin="0,0,0,6"/>
                        <Grid Grid.Row="1" Margin="0,0,0,10">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <TextBox Grid.Column="0" Name="DomainInput" Style="{StaticResource InputBox}"
                                     Margin="0,0,8,0" VerticalContentAlignment="Center">
                                <TextBox.ToolTip>Enter domain like: example.com</TextBox.ToolTip>
                            </TextBox>
                            <Button Grid.Column="1" Name="BtnAddBypass" Content="+ Bypass" Style="{StaticResource BtnGreen}"
                                    Margin="0,0,8,0"/>
                            <Button Grid.Column="2" Name="BtnAddExclude" Content="+ Exclude" Style="{StaticResource BtnRed}"/>
                        </Grid>

                        <!-- Bypass list -->
                        <Grid Grid.Row="2">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <DockPanel Grid.Column="0">
                                <TextBlock DockPanel.Dock="Top" Text="Bypass (zapret ON for these)"
                                           FontSize="11" Foreground="#00b894" Margin="0,0,0,4"/>
                                <ListBox Name="BypassList"
                                         BorderThickness="0" Background="Transparent"
                                         Foreground="#ccccee" FontSize="12"
                                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
                            </DockPanel>
                            <Button Grid.Column="1" Name="BtnRemoveBypass" Content="x" Style="{StaticResource BtnRed}"
                                    Margin="8,22,0,0" Width="30" Height="30" VerticalAlignment="Top"
                                    FontSize="14" Padding="0"/>
                        </Grid>

                        <GridSplitter Grid.Row="3" Height="10" HorizontalAlignment="Stretch"
                                      Background="Transparent" Margin="0,4,0,4"/>

                        <!-- Exclude list -->
                        <Grid Grid.Row="4">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="Auto"/>
                            </Grid.ColumnDefinitions>
                            <DockPanel Grid.Column="0">
                                <TextBlock DockPanel.Dock="Top" Text="Exclude (zapret OFF for these)"
                                           FontSize="11" Foreground="#d63031" Margin="0,0,0,4"/>
                                <ListBox Name="ExcludeList"
                                         BorderThickness="0" Background="Transparent"
                                         Foreground="#ccccee" FontSize="12"
                                         ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
                            </DockPanel>
                            <Button Grid.Column="1" Name="BtnRemoveExclude" Content="x" Style="{StaticResource BtnRed}"
                                    Margin="8,22,0,0" Width="30" Height="30" VerticalAlignment="Top"
                                    FontSize="14" Padding="0"/>
                        </Grid>

                        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
                            <Button Name="BtnRefreshDomains" Content="Refresh" Style="{StaticResource BtnDark}"/>
                        </StackPanel>
                    </Grid>
                </Grid>

                <!-- TAB: Settings -->
                <Grid Name="PanelSettings" Visibility="Hidden">
                    <Grid Margin="16">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>

                        <!-- Left column: Settings -->
                        <StackPanel Grid.Column="0" Margin="0,0,16,0">
                            <TextBlock Text="Settings" FontSize="15" FontWeight="SemiBold"
                                       Foreground="#ccccee" Margin="0,0,0,12"/>

                            <!-- Game Filter -->
                            <Border Background="#16162a" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                                <StackPanel>
                                    <TextBlock Text="Game Filter" FontSize="12" FontWeight="SemiBold"
                                               Foreground="#ccccee" Margin="0,0,0,6"/>
                                    <TextBlock Name="GameFilterLabel" FontSize="11" Foreground="#8888aa" Margin="0,0,0,6"/>
                                    <StackPanel Orientation="Horizontal">
                                        <ComboBox Name="GameFilterCombo" Width="160" Background="#1e1e36"
                                                  Foreground="#ccccee" BorderBrush="#2a2a44" FontSize="11">
                                            <ComboBoxItem Content="Disabled"/>
                                            <ComboBoxItem Content="TCP + UDP"/>
                                            <ComboBoxItem Content="TCP only"/>
                                            <ComboBoxItem Content="UDP only"/>
                                        </ComboBox>
                                        <Button Name="BtnApplyGame" Content="Apply" Style="{StaticResource BtnPurple}"
                                                Margin="8,0,0,0"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <!-- IPSet Filter -->
                            <Border Background="#16162a" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                                <StackPanel>
                                    <TextBlock Text="IPSet Filter" FontSize="12" FontWeight="SemiBold"
                                               Foreground="#ccccee" Margin="0,0,0,6"/>
                                    <TextBlock Name="IPSetLabel" FontSize="11" Foreground="#8888aa" Margin="0,0,0,6"/>
                                    <StackPanel Orientation="Horizontal">
                                        <ComboBox Name="IPSetCombo" Width="160" Background="#1e1e36"
                                                  Foreground="#ccccee" BorderBrush="#2a2a44" FontSize="11">
                                            <ComboBoxItem Content="None"/>
                                            <ComboBoxItem Content="Loaded"/>
                                            <ComboBoxItem Content="Any"/>
                                        </ComboBox>
                                        <Button Name="BtnApplyIPSet" Content="Apply" Style="{StaticResource BtnPurple}"
                                                Margin="8,0,0,0"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <!-- Auto Update -->
                            <Border Background="#16162a" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                                <StackPanel>
                                    <TextBlock Text="Auto Update Check" FontSize="12" FontWeight="SemiBold"
                                               Foreground="#ccccee" Margin="0,0,0,6"/>
                                    <TextBlock Name="UpdateLabel" FontSize="11" Foreground="#8888aa" Margin="0,0,0,6"/>
                                    <Button Name="BtnToggleUpdate" Style="{StaticResource BtnPurple}" MinWidth="120"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>

                        <!-- Right column: Service -->
                        <StackPanel Grid.Column="1">
                            <TextBlock Text="Service" FontSize="15" FontWeight="SemiBold"
                                       Foreground="#ccccee" Margin="0,0,0,12"/>

                            <Border Background="#16162a" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                                <StackPanel>
                                    <TextBlock Text="zapret Service" FontSize="12" FontWeight="SemiBold"
                                               Foreground="#ccccee" Margin="0,0,0,6"/>
                                    <TextBlock Name="ServiceLabel" FontSize="11" Foreground="#8888aa" Margin="0,0,0,8"/>
                                    <StackPanel Orientation="Horizontal">
                                        <Button Name="BtnInstallService" Content="Install" Style="{StaticResource BtnGreen}"
                                                Margin="0,0,8,0" MinWidth="80"/>
                                        <Button Name="BtnRemoveService" Content="Remove" Style="{StaticResource BtnRed}"
                                                Margin="0,0,8,0" MinWidth="80"/>
                                        <Button Name="BtnCheckStatus" Content="Status" Style="{StaticResource BtnDark}"
                                                MinWidth="80"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <Border Background="#16162a" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                                <StackPanel>
                                    <TextBlock Text="Update Lists" FontSize="12" FontWeight="SemiBold"
                                               Foreground="#ccccee" Margin="0,0,0,6"/>
                                    <StackPanel Orientation="Horizontal">
                                        <Button Name="BtnUpdateIPSet" Content="Update IPSet" Style="{StaticResource BtnPurple}"
                                                Margin="0,0,8,0"/>
                                        <Button Name="BtnUpdateHosts" Content="Update Hosts" Style="{StaticResource BtnPurple}"/>
                                    </StackPanel>
                                </StackPanel>
                            </Border>

                            <Border Background="#16162a" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                                <StackPanel>
                                    <TextBlock Text="Installed Strategy" FontSize="12" FontWeight="SemiBold"
                                               Foreground="#ccccee" Margin="0,0,0,6"/>
                                    <TextBlock Name="InstalledStrategyLabel" FontSize="11" Foreground="#8888aa"
                                               TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>

                            <Border Background="#16162a" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                                <StackPanel>
                                    <TextBlock Name="SettingsStatus" FontSize="11" Foreground="#8888aa"
                                               TextWrapping="Wrap"/>
                                </StackPanel>
                            </Border>
                        </StackPanel>
                    </Grid>
                </Grid>
            </Border>

            <!-- Bottom close -->
            <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="BtnClose" Content="Close" Style="{StaticResource BtnDark}" MinWidth="80"/>
            </StackPanel>
        </Grid>
    </Grid>
</Window>
'@

# --- Parse XAML ---
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xamlStr)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# --- Find Controls ---
$StatusText        = $window.FindName("StatusText")
$ResultsGrid       = $window.FindName("ResultsGrid")
$ProgressFill      = $window.FindName("ProgressFill")
$ProgressText      = $window.FindName("ProgressText")
$BtnFindBest       = $window.FindName("BtnFindBest")
$BtnLaunch         = $window.FindName("BtnLaunch")
$BtnClose          = $window.FindName("BtnClose")
$TabScan           = $window.FindName("TabScan")
$TabDomains        = $window.FindName("TabDomains")
$TabSettings       = $window.FindName("TabSettings")
$PanelScan         = $window.FindName("PanelScan")
$PanelDomains      = $window.FindName("PanelDomains")
$PanelSettings     = $window.FindName("PanelSettings")
$DomainInput       = $window.FindName("DomainInput")
$BtnAddBypass      = $window.FindName("BtnAddBypass")
$BtnAddExclude     = $window.FindName("BtnAddExclude")
$BypassList        = $window.FindName("BypassList")
$ExcludeList       = $window.FindName("ExcludeList")
$BtnRemoveBypass   = $window.FindName("BtnRemoveBypass")
$BtnRemoveExclude  = $window.FindName("BtnRemoveExclude")
$BtnRefreshDomains = $window.FindName("BtnRefreshDomains")
$GameFilterLabel   = $window.FindName("GameFilterLabel")
$GameFilterCombo   = $window.FindName("GameFilterCombo")
$BtnApplyGame      = $window.FindName("BtnApplyGame")
$IPSetLabel        = $window.FindName("IPSetLabel")
$IPSetCombo        = $window.FindName("IPSetCombo")
$BtnApplyIPSet     = $window.FindName("BtnApplyIPSet")
$UpdateLabel       = $window.FindName("UpdateLabel")
$BtnToggleUpdate   = $window.FindName("BtnToggleUpdate")
$ServiceLabel      = $window.FindName("ServiceLabel")
$BtnInstallService = $window.FindName("BtnInstallService")
$BtnRemoveService  = $window.FindName("BtnRemoveService")
$BtnCheckStatus    = $window.FindName("BtnCheckStatus")
$BtnUpdateIPSet    = $window.FindName("BtnUpdateIPSet")
$BtnUpdateHosts    = $window.FindName("BtnUpdateHosts")
$InstalledStrategyLabel = $window.FindName("InstalledStrategyLabel")
$SettingsStatus    = $window.FindName("SettingsStatus")

$script:selectedBat = $null

# --- Tab Switching ---
$PanelElements = @($PanelScan, $PanelDomains, $PanelSettings)

function Switch-Tab {
    param([string]$TabName)
    $PanelScan.Visibility = "Hidden"
    $PanelDomains.Visibility = "Hidden"
    $PanelSettings.Visibility = "Hidden"
    switch ($TabName) {
        "Scan"    { $PanelScan.Visibility = "Visible" }
        "Domains" { $PanelDomains.Visibility = "Visible" }
        "Settings"{ $PanelSettings.Visibility = "Visible" }
    }
}

$TabScan.Add_Checked({ Switch-Tab "Scan" })
$TabDomains.Add_Checked({ Switch-Tab "Domains" })
$TabSettings.Add_Checked({
    Switch-Tab "Settings"
    Refresh-Settings
})

# --- Domain Management ---
$bypassFile  = Join-Path $listsDir "list-general-user.txt"
$excludeFile = Join-Path $listsDir "list-exclude-user.txt"
$script:bypassDomains  = [System.Collections.ArrayList]::new()
$script:excludeDomains = [System.Collections.ArrayList]::new()

function Refresh-DomainLists {
    $script:bypassDomains.Clear()
    $script:excludeDomains.Clear()
    foreach ($d in Read-DomainsFromFile $bypassFile)  { [void]$script:bypassDomains.Add($d) }
    foreach ($d in Read-DomainsFromFile $excludeFile) { [void]$script:excludeDomains.Add($d) }
    $BypassList.ItemsSource = $null
    $BypassList.ItemsSource = $script:bypassDomains
    $ExcludeList.ItemsSource = $null
    $ExcludeList.ItemsSource = $script:excludeDomains
}

$BtnRefreshDomains.Add_Click({ Refresh-DomainLists })

$BtnAddBypass.Add_Click({
    $domain = $DomainInput.Text.Trim()
    if ($domain -eq '' -or $domain -like '#*') { return }
    if ($script:bypassDomains -contains $domain) { return }
    [void]$script:bypassDomains.Add($domain)
    Write-DomainsToFile $bypassFile $script:bypassDomains
    $DomainInput.Text = ''
    Refresh-DomainLists
})

$BtnAddExclude.Add_Click({
    $domain = $DomainInput.Text.Trim()
    if ($domain -eq '' -or $domain -like '#*') { return }
    if ($script:excludeDomains -contains $domain) { return }
    [void]$script:excludeDomains.Add($domain)
    Write-DomainsToFile $excludeFile $script:excludeDomains
    $DomainInput.Text = ''
    Refresh-DomainLists
})

$BtnRemoveBypass.Add_Click({
    $sel = $BypassList.SelectedItem
    if ($sel) {
        [void]$script:bypassDomains.Remove($sel)
        Write-DomainsToFile $bypassFile $script:bypassDomains
        Refresh-DomainLists
    }
})

$BtnRemoveExclude.Add_Click({
    $sel = $ExcludeList.SelectedItem
    if ($sel) {
        [void]$script:excludeDomains.Remove($sel)
        Write-DomainsToFile $excludeFile $script:excludeDomains
        Refresh-DomainLists
    }
})

# --- Settings ---
function Refresh-Settings {
    $gfStatus = Get-GameFilterStatus
    $GameFilterLabel.Text = "Current: $gfStatus"
    $items = $GameFilterCombo.Items | ForEach-Object { $_.Content }
    $idx = [array]::IndexOf($items, $gfStatus)
    $GameFilterCombo.SelectedIndex = $(if ($idx -ge 0) { $idx } else { 0 })

    $ipsetStatus = Get-IPSetStatus
    $IPSetLabel.Text = "Current: $ipsetStatus"
    $ipItems = $IPSetCombo.Items | ForEach-Object { $_.Content }
    $ipIdx = [array]::IndexOf($ipItems, $ipsetStatus)
    $IPSetCombo.SelectedIndex = $(if ($ipIdx -ge 0) { $ipIdx } else { 0 })

    $updStatus = Get-UpdateCheckStatus
    $UpdateLabel.Text = "Current: $updStatus"
    $BtnToggleUpdate.Content = $(if ($updStatus -eq "Enabled") { "Disable" } else { "Enable" })

    $svcInstalled = $false
    $svcRunning = $false
    try {
        sc query "zapret" 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $svcInstalled = $true }
    } catch {}
    $winwsRunning = (Get-Process -Name "winws" -ErrorAction SilentlyContinue) -ne $null
    $svcLabel = if ($svcInstalled) { "Installed" } else { "Not installed" }
    if ($winwsRunning) { $svcLabel += " | winws: running" } else { $svcLabel += " | winws: stopped" }
    $ServiceLabel.Text = $svcLabel

    $strategy = ""
    try {
        $reg = & reg query "HKLM\System\CurrentControlSet\Services\zapret" /v zapret-discord-youtube 2>&1
        foreach ($line in $reg) {
            if ($line -match "REG_SZ\s+(.+)") { $strategy = $Matches[1].Trim() }
        }
    } catch {}
    if ($strategy -ne "") {
        $InstalledStrategyLabel.Text = "Strategy: $strategy"
    } else {
        $InstalledStrategyLabel.Text = "No strategy installed"
    }

    $SettingsStatus.Text = ""
}

$BtnApplyGame.Add_Click({
    $selected = $GameFilterCombo.SelectedItem
    if ($selected) {
        Set-GameFilterMode -Mode $selected.Content
        Refresh-Settings
        $SettingsStatus.Text = "Game Filter set to: $($selected.Content)"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00b894")
    }
})

$BtnApplyIPSet.Add_Click({
    $selected = $IPSetCombo.SelectedItem
    if ($selected) {
        $listFile = Join-Path $listsDir "ipset-all.txt"
        $backupFile = "$listFile.backup"
        switch ($selected.Content) {
            "None" {
                if (Test-Path $listFile -and -not (Test-Path $backupFile)) {
                    Copy-Item $listFile $backupFile -Force
                }
                "203.0.113.113/32" | Out-File $listFile -Encoding UTF8
            }
            "Any" {
                if (Test-Path $listFile -and -not (Test-Path $backupFile)) {
                    Copy-Item $listFile $backupFile -Force
                }
                [System.IO.File]::WriteAllText($listFile, '', [System.Text.Encoding]::UTF8)
            }
            "Loaded" {
                if (Test-Path $backupFile) {
                    Copy-Item $backupFile $listFile -Force
                    Remove-Item $backupFile -Force
                }
            }
        }
        Refresh-Settings
        $SettingsStatus.Text = "IPSet set to: $($selected.Content)"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00b894")
    }
})

$BtnToggleUpdate.Add_Click({
    $flagFile = Join-Path $utilsDir "check_updates.enabled"
    if (Test-Path $flagFile) {
        Remove-Item $flagFile -Force
    } else {
        "enabled" | Out-File $flagFile -Encoding UTF8
    }
    Refresh-Settings
})

$BtnCheckStatus.Add_Click({
    Refresh-Settings
    $SettingsStatus.Text = "Status refreshed"
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#8888aa")
})

$BtnInstallService.Add_Click({
    Stop-Winws
    $batFiles = Get-ChildItem -Path $rootDir -Filter "general*.bat" |
        Where-Object { $_.Name -notlike "service*" } |
        Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) }

    $items = @()
    $idx = 0
    foreach ($f in $batFiles) {
        $idx++
        $items += "$idx. $($f.Name)"
    }

    $SettingsStatus.Text = "Use 'service.bat > Install Service' to pick a strategy. Available: $($batFiles.Count) configs."
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#8888aa")
})

$BtnRemoveService.Add_Click({
    $r1 = & net stop zapret 2>&1
    $r2 = & sc delete zapret 2>&1
    Stop-Winws
    $r3 = & net stop WinDivert 2>&1
    $r4 = & sc delete WinDivert 2>&1
    Refresh-Settings
    $SettingsStatus.Text = "Service removed."
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00b894")
})

$BtnUpdateIPSet.Add_Click({
    $url = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt"
    $outFile = Join-Path $listsDir "ipset-all.txt"
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "curl.exe"
        $psi.Arguments = "--ssl-no-revoke -L -o `"$outFile`" `"$url`""
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(15000)
        Refresh-Settings
        $SettingsStatus.Text = "IPSet updated."
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00b894")
    } catch {
        $SettingsStatus.Text = "Failed to update IPSet: $_"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#d63031")
    }
})

$BtnUpdateHosts.Add_Click({
    $url = "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/hosts"
    $tempFile = Join-Path $env:TEMP "zapret_hosts.txt"
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "curl.exe"
        $psi.Arguments = "-L -s -o `"$tempFile`" `"$url`""
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit(15000)
        if (Test-Path $tempFile) {
            & notepad $tempFile
            $SettingsStatus.Text = "Hosts file downloaded. Copy content to $env:SystemRoot\System32\drivers\etc\hosts"
            $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#74b9ff")
        }
    } catch {
        $SettingsStatus.Text = "Failed to download hosts: $_"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#d63031")
    }
})

# --- Strategy Finder (background runspace) ---
function Start-Scan {
    $BtnFindBest.IsEnabled = $false
    $BtnLaunch.IsEnabled = $false
    $ResultsGrid.ItemsSource = $null
    $ProgressFill.Width = 0
    $ProgressText.Text = "0%"
    $StatusText.Text = "Scanning..."
    $StatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#8888aa")

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ThreadOptions = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("rootDir", $rootDir)
    $runspace.SessionStateProxy.SetVariable("window", $window)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $runspace

    [void]$ps.AddScript({
        $disp = $window.Dispatcher

        function Push-UI([int]$Pct, [string]$Text) {
            $disp.Invoke([Action]{
                $window.FindName("ProgressText").Text = "$Pct%"
                $window.FindName("StatusText").Text = $Text
                $container = $window.FindName("ProgressFill").Parent
                $maxW = $container.ActualWidth
                if ($maxW -gt 0) {
                    $window.FindName("ProgressFill").Width = $maxW * $Pct / 100
                }
            }, [System.Windows.Threading.DispatcherPriority]::Render)
        }

        $batFiles = Get-ChildItem -Path $rootDir -Filter "general*.bat" |
            Where-Object { $_.Name -notlike "service*" } |
            Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) }

        $total = $batFiles.Count
        if ($total -eq 0) {
            Push-UI -Pct 100 -Text "No strategy files found"
            return
        }
        Push-UI -Pct 0 -Text "Scanning $total strategies..."

        $results = @()
        $idx = 0
        foreach ($bat in $batFiles) {
            $idx++
            $pct = [math]::Round(($idx / $total) * 100)
            Push-UI -Pct $pct -Text "[$idx/$total] $($bat.Name)..."

            Get-Process -Name "winws" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
            Start-Sleep -Milliseconds 500

            $binPath = Join-Path $rootDir "bin"
            $listsPath = Join-Path $rootDir "lists"

            $rawLines = Get-Content $bat.FullName -ErrorAction SilentlyContinue
            if ($rawLines) {
                $inCmd = $false; $parts = @()
                foreach ($l in $rawLines) {
                    $t = $l.Trim()
                    if ($t -match 'winws\.exe') {
                        $after = $t -replace '.*winws\.exe\s*', '' -replace '^\s*/min\s*', ''
                        $parts += $after; $inCmd = $true; continue
                    }
                    if ($inCmd) {
                        if ($t.EndsWith('^')) { $parts += $t.TrimEnd('^').Trim() }
                        else { $parts += $t; $inCmd = $false }
                    }
                }
                if ($parts.Count -gt 0) {
                    $cmd = ($parts -join ' ') -replace '%~dp0',"$rootDir\" -replace '%BIN%',$binPath -replace '%LISTS%',$listsPath -replace '%GameFilterTCP%','12' -replace '%GameFilterUDP%','12'
                    $psi = New-Object System.Diagnostics.ProcessStartInfo
                    $psi.FileName = Join-Path $binPath "winws.exe"
                    $psi.Arguments = $cmd
                    $psi.WorkingDirectory = $binPath
                    $psi.CreateNoWindow = $true
                    $psi.UseShellExecute = $false
                    $psi.RedirectStandardOutput = $true
                    $psi.RedirectStandardError = $true
                    try { [void][System.Diagnostics.Process]::Start($psi) } catch {}
                }
            }
            Start-Sleep -Seconds 6

            $dOk = 0
            foreach ($u in @("https://discord.com","https://gateway.discord.gg")) {
                try {
                    $ca = @("-I","-s","-m","5","-o","NUL","-w","%{http_code}","--show-error","--http1.1",$u)
                    $o = & curl.exe @ca 2>&1 | Out-String
                    if ($LASTEXITCODE -eq 0 -and $o.Trim() -match '^\d{3}$') { $dOk++ }
                } catch {}
            }
            $yOk = 0
            foreach ($u in @("https://www.youtube.com","https://youtu.be")) {
                try {
                    $ca = @("-I","-s","-m","5","-o","NUL","-w","%{http_code}","--show-error","--http1.1",$u)
                    $o = & curl.exe @ca 2>&1 | Out-String
                    if ($LASTEXITCODE -eq 0 -and $o.Trim() -match '^\d{3}$') { $yOk++ }
                } catch {}
            }

            Get-Process -Name "winws" -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
            Start-Sleep -Milliseconds 500

            $dScore = [math]::Round(($dOk / 2) * 100)
            $yScore = [math]::Round(($yOk / 2) * 100)
            $results += [PSCustomObject]@{
                Name=$bat.Name.Replace('.bat',''); DiscordOK=$dOk; DiscordScore=$dScore
                YouTubeOK=$yOk; YouTubeScore=$yScore
                TotalScore=[math]::Round(($dScore+$yScore)/2); Path=$bat.FullName
            }
        }

        $sorted = $results | Sort-Object -Property TotalScore -Descending
        Push-UI -Pct 100 -Text ""

        $disp.Invoke([Action]{
            $gridData = [System.Collections.ArrayList]::new()
            $i = 0
            foreach ($r in $sorted) {
                $i++
                [void]$gridData.Add([PSCustomObject]@{
                    Index=$i; StratName=$r.Name
                    DiscordDisplay="$($r.DiscordOK)/2  ($($r.DiscordScore)%)"
                    YouTubeDisplay="$($r.YouTubeOK)/2  ($($r.YouTubeScore)%)"
                    ScoreDisplay="$($r.TotalScore)%"
                    TotalScore=$r.TotalScore; Path=$r.Path
                })
            }
            $rg = $window.FindName("ResultsGrid")
            $rg.ItemsSource = $gridData
            $window.FindName("ProgressFill").Width = $window.FindName("ProgressFill").Parent.ActualWidth
            $window.FindName("ProgressText").Text = "100%"

            if ($sorted.Count -gt 0) {
                $best = $sorted[0]
                $st = $window.FindName("StatusText")
                $st.Text = "Best: $($best.Name)   |   Discord $($best.DiscordScore)%   |   YouTube $($best.YouTubeScore)%   |   Score $($best.TotalScore)%"
                $st.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a29bfe")
                $script:selectedBat = $best.Path
                $window.FindName("BtnLaunch").IsEnabled = $true
            } else {
                $window.FindName("StatusText").Text = "No results."
            }
            $window.FindName("BtnFindBest").IsEnabled = $true
        }, [System.Windows.Threading.DispatcherPriority]::Normal)
    })

    $ps.BeginInvoke() | Out-Null
}

# --- Events ---
$BtnClose.Add_Click({ $window.Close() })

$BtnLaunch.Add_Click({
    if ($script:selectedBat) {
        Stop-Winws
        Start-BatHidden -BatPath $script:selectedBat -WorkDir $rootDir
        $StatusText.Text = "Launched: $([System.IO.Path]::GetFileName($script:selectedBat))"
    }
})

$BtnFindBest.Add_Click({ Start-Scan })

$ResultsGrid.Add_SelectionChanged({
    $sel = $ResultsGrid.SelectedItem
    if ($sel) {
        $script:selectedBat = $sel.Path
        $BtnLaunch.IsEnabled = $true
    }
})

# --- Init ---
Refresh-DomainLists
$null = $window.ShowDialog()
