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
    if (-not $rawLines) { return $null }

    $binPath = (Join-Path $WorkDir "bin") + "\"
    $listsPath = (Join-Path $WorkDir "lists") + "\"

    $inCommand = $false
    $cmdParts = @()
    foreach ($line in $rawLines) {
        $trimmed = $line.Trim()
        if ($trimmed -match 'winws\.exe') {
            $afterExe = ($trimmed -replace '.*winws\.exe["\s]*', '').TrimEnd('^').Trim()
            $cmdParts += $afterExe
            $inCommand = $true
            continue
        }
        if ($inCommand) {
            if ($trimmed) {
                if ($trimmed.EndsWith('^')) { $cmdParts += $trimmed.TrimEnd('^').Trim() }
                else { $cmdParts += $trimmed; $inCommand = $false }
            }
        }
    }

    if ($cmdParts.Count -eq 0) { return $null }

    $fullCmd = $cmdParts -join ' '
    $gf = Get-GameFilterValues
    $fullCmd = $fullCmd -replace '%BIN%', $binPath
    $fullCmd = $fullCmd -replace '%LISTS%', $listsPath
    $fullCmd = $fullCmd -replace '%GameFilterTCP%', $gf.TCP
    $fullCmd = $fullCmd -replace '%GameFilterUDP%', $gf.UDP

    $prepBat = "$env:TEMP\flowcutter_prep.bat"
    $prepContent = @"
@echo off
cd /d "$WorkDir"
call "service.bat" status_zapret >nul 2>&1
call "service.bat" check_updates >nul 2>&1
call "service.bat" load_game_filter >nul 2>&1
call "service.bat" load_user_lists >nul 2>&1
"@
    [System.IO.File]::WriteAllText($prepBat, $prepContent, [System.Text.Encoding]::Default)

    try {
        $prep = Start-Process cmd.exe "/c `"$prepBat`"" -WindowStyle Hidden -WorkingDirectory $WorkDir -Wait -PassThru
        if (-not $prep.HasExited) { $prep.WaitForExit(5000) }
        if (-not $prep.HasExited) {
            Write-Host "Prep script timed out, killing..."
            $prep.Kill()
        }
    } catch { Write-Host "Prep error: $_" }

    $exe = Join-Path $binPath "winws.exe"
    if (-not (Test-Path $exe)) {
        Write-Host "winws.exe not found at: $exe"
        return $null
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "WARNING: Not running as admin. WinDivert requires elevation."
    }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $fullCmd
        $psi.WorkingDirectory = $binPath
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.CreateNoWindow = $true
        $psi.UseShellExecute = $false
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        return $proc
    } catch {
        Write-Host "Error launching winws.exe: $_"
        return $null
    }
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

function Get-GameFilterValues {
    $flagFile = Join-Path $utilsDir "game_filter.enabled"
    if (-not (Test-Path $flagFile)) { return @{ TCP = '12'; UDP = '12' } }
    $mode = (Get-Content $flagFile -First 1 -ErrorAction SilentlyContinue).Trim()
    switch ($mode) {
        "all" { return @{ TCP = '1024-65535'; UDP = '1024-65535' } }
        "tcp" { return @{ TCP = '1024-65535'; UDP = '12' } }
        "udp" { return @{ TCP = '12'; UDP = '1024-65535' } }
        default { return @{ TCP = '12'; UDP = '12' } }
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

function Get-LocalVersion {
    $verFile = Join-Path $rootDir ".service\version.txt"
    if (Test-Path $verFile) {
        return (Get-Content $verFile -First 1).Trim()
    }
    return "unknown"
}

function Get-FlowsealVersion {
    try {
        $headers = @{ "Cache-Control" = "no-cache"; "User-Agent" = "FlowCutter" }
        $resp = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt" -Headers $headers -TimeoutSec 10
        return $resp.Trim()
    } catch {
        return $null
    }
}

function Get-FlowCutterRelease {
    $repo = "heurist1c/FlowCutter"
    try {
        $headers = @{ "Cache-Control" = "no-cache"; "User-Agent" = "FlowCutter" }
        $resp = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -TimeoutSec 10
        return $resp
    } catch {
        return $null
    }
}

function Get-FlowsealLocalVersion {
    $verFile = Join-Path $rootDir ".service\flowseal_version.txt"
    if (Test-Path $verFile) {
        return (Get-Content $verFile -First 1).Trim()
    }
    return "unknown"
}

function Set-FlowsealLocalVersion {
    param([string]$Version)
    $verFile = Join-Path $rootDir ".service\flowseal_version.txt"
    [System.IO.File]::WriteAllText($verFile, $Version, [System.Text.Encoding]::UTF8)
}

function Download-FlowCutterUpdate {
    param([string]$ZipUrl, [string]$Version)
    $tempDir = Join-Path $env:TEMP "FlowCutter_update_$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $zipFile = Join-Path $tempDir "update.zip"

    try {
        $headers = @{ "User-Agent" = "FlowCutter" }
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipFile -Headers $headers -TimeoutSec 60 -UseBasicParsing

        Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

        $repoDir = Get-ChildItem -Path $tempDir -Directory | Where-Object { $_.Name -like "FlowCutter*" -or $_.Name -like "zapret*" } | Select-Object -First 1
        if (-not $repoDir) {
            $repoDir = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
        }
        if (-not $repoDir) { throw "No repo directory found in zip" }

        $filesToCopy = @(
            "strategy_finder.ps1",
            "strategy finder.bat",
            "service.bat"
        )
        $dirsToCopy = @(
            "lists",
            "utils",
            ".service"
        )

        $copied = 0
        foreach ($f in $filesToCopy) {
            $src = Join-Path $repoDir.FullName $f
            if (Test-Path $src) {
                Copy-Item $src $rootDir -Force
                $copied++
            }
        }
        foreach ($d in $dirsToCopy) {
            $src = Join-Path $repoDir.FullName $d
            if (Test-Path $src) {
                Copy-Item $src $rootDir -Recurse -Force
                $copied++
            }
        }

        $batSrc = Get-ChildItem -Path $repoDir.FullName -Filter "general*.bat" -File
        foreach ($bat in $batSrc) {
            Copy-Item $bat.FullName $rootDir -Force
            $copied++
        }

        return @{ Success = $true; Copied = $copied }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Download-FlowsealUpdate {
    param([string]$Version)
    $zipUrl = "https://github.com/Flowseal/zapret-discord-youtube/archive/refs/tags/$Version.zip"
    $tempDir = Join-Path $env:TEMP "Flowseal_update_$([System.IO.Path]::GetRandomFileName())"
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $zipFile = Join-Path $tempDir "update.zip"

    try {
        $headers = @{ "User-Agent" = "FlowCutter" }
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -Headers $headers -TimeoutSec 60 -UseBasicParsing

        Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

        $repoDir = Get-ChildItem -Path $tempDir -Directory | Where-Object { $_.Name -like "zapret*" } | Select-Object -First 1
        if (-not $repoDir) {
            $repoDir = Get-ChildItem -Path $tempDir -Directory | Select-Object -First 1
        }
        if (-not $repoDir) { throw "No repo directory found in zip" }

        $filesToCopy = @("service.bat")
        $dirsToCopy = @("lists")

        $copied = 0
        foreach ($f in $filesToCopy) {
            $src = Join-Path $repoDir.FullName $f
            if (Test-Path $src) {
                Copy-Item $src $rootDir -Force
                $copied++
            }
        }
        foreach ($d in $dirsToCopy) {
            $src = Join-Path $repoDir.FullName $d
            if (Test-Path $src) {
                Copy-Item $src $rootDir -Recurse -Force
                $copied++
            }
        }

        $batSrc = Get-ChildItem -Path $repoDir.FullName -Filter "general*.bat" -File
        foreach ($bat in $batSrc) {
            Copy-Item $bat.FullName $rootDir -Force
            $copied++
        }

        Set-FlowsealLocalVersion -Version $Version

        return @{ Success = $true; Copied = $copied }
    } catch {
        return @{ Success = $false; Error = $_.Exception.Message }
    } finally {
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- XAML ---
$xamlStr = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="FlowCutter" Width="880" Height="680"
    WindowStartupLocation="CenterScreen" Background="#0a0a0a">
    <Window.Resources>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#2a2a2a"/>
            <Setter Property="Foreground" Value="#bbbbbb"/>
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
                                <Setter TargetName="bd" Property="Background" Value="#3a3a3a"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#1a1a1a"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="bd" Property="Background" Value="#161616"/>
                                <Setter Property="Foreground" Value="#444444"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource BtnPrimary}">
            <Setter Property="Background" Value="#1e3a2e"/>
            <Setter Property="Foreground" Value="#6a9a7a"/>
        </Style>
        <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource BtnPrimary}">
            <Setter Property="Background" Value="#3a1e1e"/>
            <Setter Property="Foreground" Value="#9a6a6a"/>
        </Style>
        <Style x:Key="BtnMuted" TargetType="Button" BasedOn="{StaticResource BtnPrimary}">
            <Setter Property="Background" Value="#1a1a1a"/>
            <Setter Property="Foreground" Value="#888888"/>
        </Style>
        <Style x:Key="TabBtn" TargetType="RadioButton">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="#444444"/>
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
                                <Setter TargetName="bd" Property="Background" Value="#111111"/>
                                <Setter Property="Foreground" Value="#888888"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="bd" Property="Background" Value="#0e0e0e"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="InputBox" TargetType="TextBox">
            <Setter Property="Background" Value="#0e0e0e"/>
            <Setter Property="Foreground" Value="#888888"/>
            <Setter Property="BorderBrush" Value="#1e1e1e"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,8"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="CaretBrush" Value="#666666"/>
        </Style>
        <Style x:Key="DarkCombo" TargetType="ComboBox">
            <Setter Property="Background" Value="#0e0e0e"/>
            <Setter Property="Foreground" Value="#aaaaaa"/>
            <Setter Property="BorderBrush" Value="#222222"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border x:Name="Bd" Background="#0e0e0e" BorderBrush="#222222" BorderThickness="1"
                                    CornerRadius="4" Padding="{TemplateBinding Padding}">
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="36"/>
                                    </Grid.ColumnDefinitions>
                                    <ContentPresenter IsHitTestVisible="False"
                                                      Grid.Column="0"
                                                      Content="{TemplateBinding SelectionBoxItem}"
                                                      ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                                                      Margin="{TemplateBinding Padding}"
                                                      VerticalAlignment="{TemplateBinding VerticalContentAlignment}"
                                                      HorizontalAlignment="Left"/>
                                    <ToggleButton Grid.Column="1"
                                                  IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                                  Focusable="False" IsTabStop="False"
                                                  Cursor="Hand">
                                        <ToggleButton.Template>
                                            <ControlTemplate TargetType="ToggleButton">
                                                <Grid>
                                                    <Path x:Name="Arrow" Data="M0,0 L5,4 L10,0" Stroke="#666666"
                                                          StrokeThickness="1.5" Fill="Transparent"
                                                          HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                                </Grid>
                                            </ControlTemplate>
                                        </ToggleButton.Template>
                                    </ToggleButton>
                                </Grid>
                            </Border>
                            <Popup IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True"
                                   Focusable="False" PopupAnimation="Slide">
                                <Border Background="#141414" BorderBrush="#222222" BorderThickness="1"
                                        CornerRadius="4" Margin="0,2,0,0">
                                    <ScrollViewer MaxHeight="{TemplateBinding MaxDropDownHeight}"
                                                  SnapsToDevicePixels="True">
                                        <StackPanel IsItemsHost="True"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="DarkComboItem" TargetType="ComboBoxItem">
            <Setter Property="Background" Value="#141414"/>
            <Setter Property="Foreground" Value="#bbbbbb"/>
            <Setter Property="Padding" Value="8,5"/>
            <Style.Triggers>
                <Trigger Property="IsHighlighted" Value="True">
                    <Setter Property="Background" Value="#1e1e1e"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="8"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid>
                            <Border Background="#0e0e0e" CornerRadius="4"/>
                            <Track x:Name="PART_Track" IsDirectionReversed="True">
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Template>
                                            <ControlTemplate TargetType="Thumb">
                                                <Border Background="#2a2a2a" CornerRadius="4" Margin="1"/>
                                            </ControlTemplate>
                                        </Thumb.Template>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="Height" Value="8"/>
                </Trigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>

    <Grid Margin="24,18,24,16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Margin="0,0,0,10">
            <TextBlock Text="FlowCutter" FontSize="26" FontWeight="Bold" Foreground="#cccccc"/>
        </StackPanel>

        <!-- Tabs -->
        <StackPanel Grid.Row="1" Orientation="Horizontal">
            <RadioButton Name="TabScan" Content="Strategy Finder" Style="{StaticResource TabBtn}" IsChecked="True"/>
            <RadioButton Name="TabDomains" Content="Domains" Style="{StaticResource TabBtn}"/>
            <RadioButton Name="TabSettings" Content="Settings" Style="{StaticResource TabBtn}"/>
        </StackPanel>

        <!-- Tab content -->
        <Border Grid.Row="2" Background="#0e0e0e" CornerRadius="0,10,10,10"
                BorderThickness="1" BorderBrush="#1a1a1a" Margin="0,0,0,12">
            <Grid>
            <!-- TAB: Strategy Finder -->
            <Grid Name="PanelScan" Visibility="Visible">
                <Grid Margin="16">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <!-- Quick Launch -->
                    <Border Grid.Row="0" Background="#141414" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="Strategy:" FontSize="12" Foreground="#dddddd"
                                       VerticalAlignment="Center" Margin="0,0,10,0"/>
                            <ComboBox Name="StrategyCombo" Width="340" Style="{StaticResource DarkCombo}"
                                      ItemContainerStyle="{StaticResource DarkComboItem}"/>
                            <Button Name="BtnRunStrategy" Content="Launch" Style="{StaticResource BtnAccent}"
                                    Margin="10,0,0,0" MinWidth="80"/>
                        </StackPanel>
                    </Border>

                    <!-- Status -->
                    <Border Grid.Row="1" Background="#141414" CornerRadius="6" Padding="12,8" Margin="0,0,0,10">
                        <TextBlock Name="StatusText" Text="Select a strategy or click Find Best to scan"
                                   FontSize="12" Foreground="#dddddd"/>
                    </Border>

                    <!-- Results -->
                    <DataGrid Grid.Row="2" Name="ResultsGrid" AutoGenerateColumns="False" IsReadOnly="True"
                              Background="Transparent" Foreground="#cccccc"
                              GridLinesVisibility="None" BorderThickness="0"
                              RowBackground="Transparent" AlternatingRowBackground="#0c0c0c"
                              HeadersVisibility="Column" CanUserSortColumns="True"
                              SelectionMode="Single">
                        <DataGrid.ColumnHeaderStyle>
                            <Style TargetType="DataGridColumnHeader">
                                <Setter Property="Background" Value="#111111"/>
                                <Setter Property="Foreground" Value="#444444"/>
                                <Setter Property="Padding" Value="10,6"/>
                                <Setter Property="FontSize" Value="11"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                                <Setter Property="BorderThickness" Value="0,0,0,1"/>
                                <Setter Property="BorderBrush" Value="#1a1a1a"/>
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

                    <!-- Progress -->
                    <Grid Grid.Row="3" Margin="0,10,0,10">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Background="#0e0e0e" CornerRadius="5" Height="8"
                                Margin="0,0,10,0" ClipToBounds="True">
                            <Border x:Name="ProgressFill" Background="#444444" CornerRadius="5"
                                    HorizontalAlignment="Left" Width="0" Height="8"/>
                        </Border>
                        <TextBlock Grid.Column="1" Name="ProgressText" Text="0%"
                                   FontSize="11" Foreground="#cccccc" VerticalAlignment="Center"/>
                    </Grid>

                    <!-- Buttons -->
                    <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button Name="BtnFindBest" Content="Find Best" Style="{StaticResource BtnPrimary}"
                                Margin="0,0,8,0" MinWidth="110"/>
                        <Button Name="BtnStop" Content="Stop" Style="{StaticResource BtnDanger}"
                                Margin="0,0,8,0" MinWidth="80" IsEnabled="False"/>
                        <Button Name="BtnLaunch" Content="Launch Selected" Style="{StaticResource BtnAccent}"
                                MinWidth="100" IsEnabled="False"/>
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

                    <TextBlock Grid.Row="0" Text="Domain:" FontSize="12" Foreground="#dddddd" Margin="0,0,0,6"/>
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
                        <Button Grid.Column="1" Name="BtnAddBypass" Content="+ Bypass" Style="{StaticResource BtnAccent}"
                                Margin="0,0,8,0"/>
                        <Button Grid.Column="2" Name="BtnAddExclude" Content="+ Exclude" Style="{StaticResource BtnDanger}"/>
                    </Grid>

                    <Grid Grid.Row="2">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <DockPanel Grid.Column="0">
                            <TextBlock DockPanel.Dock="Top" Text="Bypass (zapret ON for these)"
                                       FontSize="11" Foreground="#4a7a5a" Margin="0,0,0,4"/>
                            <ListBox Name="BypassList"
                                     BorderThickness="0" Background="Transparent"
                                     Foreground="#cccccc" FontSize="12"
                                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
                        </DockPanel>
                        <Button Grid.Column="1" Name="BtnRemoveBypass" Content="x" Style="{StaticResource BtnDanger}"
                                Margin="8,22,0,0" Width="30" Height="30" VerticalAlignment="Top"
                                FontSize="14" Padding="0"/>
                    </Grid>

                    <GridSplitter Grid.Row="3" Height="10" HorizontalAlignment="Stretch"
                                  Background="Transparent" Margin="0,4,0,4"/>

                    <Grid Grid.Row="4">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <DockPanel Grid.Column="0">
                            <TextBlock DockPanel.Dock="Top" Text="Exclude (zapret OFF for these)"
                                       FontSize="11" Foreground="#7a4a4a" Margin="0,0,0,4"/>
                            <ListBox Name="ExcludeList"
                                     BorderThickness="0" Background="Transparent"
                                     Foreground="#cccccc" FontSize="12"
                                     ScrollViewer.HorizontalScrollBarVisibility="Disabled"/>
                        </DockPanel>
                        <Button Grid.Column="1" Name="BtnRemoveExclude" Content="x" Style="{StaticResource BtnDanger}"
                                Margin="8,22,0,0" Width="30" Height="30" VerticalAlignment="Top"
                                FontSize="14" Padding="0"/>
                    </Grid>

                    <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
                        <Button Name="BtnRefreshDomains" Content="Refresh" Style="{StaticResource BtnMuted}"/>
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

                    <StackPanel Grid.Column="0" Margin="0,0,16,0">
                        <TextBlock Text="Settings" FontSize="15" FontWeight="SemiBold"
                                   Foreground="#cccccc" Margin="0,0,0,12"/>

                        <Border Background="#141414" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Text="Game Filter" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#cccccc" Margin="0,0,0,6"/>
                                <TextBlock Name="GameFilterLabel" FontSize="11" Foreground="#dddddd" Margin="0,0,0,6"/>
                                <StackPanel Orientation="Horizontal">
                                    <ComboBox Name="GameFilterCombo" Width="160" Style="{StaticResource DarkCombo}"
                                              ItemContainerStyle="{StaticResource DarkComboItem}">
                                        <ComboBoxItem Content="Disabled"/>
                                        <ComboBoxItem Content="TCP + UDP"/>
                                        <ComboBoxItem Content="TCP only"/>
                                        <ComboBoxItem Content="UDP only"/>
                                    </ComboBox>
                                    <Button Name="BtnApplyGame" Content="Apply" Style="{StaticResource BtnPrimary}"
                                            Margin="8,0,0,0"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <Border Background="#141414" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Text="IPSet Filter" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#cccccc" Margin="0,0,0,6"/>
                                <TextBlock Name="IPSetLabel" FontSize="11" Foreground="#dddddd" Margin="0,0,0,6"/>
                                <StackPanel Orientation="Horizontal">
                                    <ComboBox Name="IPSetCombo" Width="160" Style="{StaticResource DarkCombo}"
                                              ItemContainerStyle="{StaticResource DarkComboItem}">
                                        <ComboBoxItem Content="None"/>
                                        <ComboBoxItem Content="Loaded"/>
                                        <ComboBoxItem Content="Any"/>
                                    </ComboBox>
                                    <Button Name="BtnApplyIPSet" Content="Apply" Style="{StaticResource BtnPrimary}"
                                            Margin="8,0,0,0"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <Border Background="#141414" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Text="Updates" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#cccccc" Margin="0,0,0,6"/>
                                <TextBlock Name="FlowsealLabel" FontSize="11" Foreground="#dddddd" Margin="0,0,0,4"/>
                                <TextBlock Name="FlowsealRemoteLabel" FontSize="11" Foreground="#888888" Margin="0,0,0,6"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button Name="BtnCheckFlowseal" Content="Check Base" Style="{StaticResource BtnPrimary}"
                                            Margin="0,0,8,0" MinWidth="90"/>
                                    <Button Name="BtnDownloadFlowseal" Content="Update Base" Style="{StaticResource BtnAccent}"
                                            MinWidth="100" Visibility="Hidden"/>
                                </StackPanel>
                                <Border Height="1" Background="#1a1a1a" Margin="0,8,0,8"/>
                                <TextBlock Name="UpdateLabel" FontSize="11" Foreground="#dddddd" Margin="0,0,0,4"/>
                                <TextBlock Name="UpdateRemoteLabel" FontSize="11" Foreground="#888888" Margin="0,0,0,6"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button Name="BtnCheckUpdate" Content="Check Overlay" Style="{StaticResource BtnPrimary}"
                                            Margin="0,0,8,0" MinWidth="90"/>
                                    <Button Name="BtnDownloadUpdate" Content="Update Overlay" Style="{StaticResource BtnAccent}"
                                            MinWidth="100" Visibility="Hidden"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>
                    </StackPanel>

                    <StackPanel Grid.Column="1">
                        <TextBlock Text="Service" FontSize="15" FontWeight="SemiBold"
                                   Foreground="#cccccc" Margin="0,0,0,12"/>

                        <Border Background="#141414" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Text="zapret Service" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#cccccc" Margin="0,0,0,6"/>
                                <TextBlock Name="ServiceLabel" FontSize="11" Foreground="#dddddd" Margin="0,0,0,8"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button Name="BtnInstallService" Content="Install" Style="{StaticResource BtnAccent}"
                                            Margin="0,0,8,0" MinWidth="80"/>
                                    <Button Name="BtnRemoveService" Content="Remove" Style="{StaticResource BtnDanger}"
                                            Margin="0,0,8,0" MinWidth="80"/>
                                    <Button Name="BtnCheckStatus" Content="Status" Style="{StaticResource BtnMuted}"
                                            MinWidth="80"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <Border Background="#141414" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Text="Update Lists" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#cccccc" Margin="0,0,0,6"/>
                                <StackPanel Orientation="Horizontal">
                                    <Button Name="BtnUpdateIPSet" Content="Update IPSet" Style="{StaticResource BtnPrimary}"
                                            Margin="0,0,8,0"/>
                                    <Button Name="BtnUpdateHosts" Content="Update Hosts" Style="{StaticResource BtnPrimary}"/>
                                </StackPanel>
                            </StackPanel>
                        </Border>

                        <Border Background="#141414" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Text="Installed Strategy" FontSize="12" FontWeight="SemiBold"
                                           Foreground="#cccccc" Margin="0,0,0,6"/>
                                <TextBlock Name="InstalledStrategyLabel" FontSize="11" Foreground="#dddddd"
                                           TextWrapping="Wrap"/>
                            </StackPanel>
                        </Border>

                        <Border Background="#141414" CornerRadius="8" Padding="12,10" Margin="0,0,0,8">
                            <StackPanel>
                                <TextBlock Name="SettingsStatus" FontSize="11" Foreground="#dddddd"
                                           TextWrapping="Wrap"/>
                            </StackPanel>
                        </Border>
                    </StackPanel>
                </Grid>
            </Grid>
            </Grid>
        </Border>

        <!-- Bottom close -->
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="BtnClose" Content="Close" Style="{StaticResource BtnMuted}" MinWidth="80"/>
        </StackPanel>
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
$BtnStop           = $window.FindName("BtnStop")
$BtnClose          = $window.FindName("BtnClose")
$StrategyCombo     = $window.FindName("StrategyCombo")
$BtnRunStrategy    = $window.FindName("BtnRunStrategy")
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
$FlowsealLabel     = $window.FindName("FlowsealLabel")
$FlowsealRemoteLabel = $window.FindName("FlowsealRemoteLabel")
$BtnCheckFlowseal  = $window.FindName("BtnCheckFlowseal")
$BtnDownloadFlowseal = $window.FindName("BtnDownloadFlowseal")
$UpdateLabel       = $window.FindName("UpdateLabel")
$UpdateRemoteLabel = $window.FindName("UpdateRemoteLabel")
$BtnCheckUpdate    = $window.FindName("BtnCheckUpdate")
$BtnDownloadUpdate = $window.FindName("BtnDownloadUpdate")
$ServiceLabel      = $window.FindName("ServiceLabel")
$BtnInstallService = $window.FindName("BtnInstallService")
$BtnRemoveService  = $window.FindName("BtnRemoveService")
$BtnCheckStatus    = $window.FindName("BtnCheckStatus")
$BtnUpdateIPSet    = $window.FindName("BtnUpdateIPSet")
$BtnUpdateHosts    = $window.FindName("BtnUpdateHosts")
$InstalledStrategyLabel = $window.FindName("InstalledStrategyLabel")
$SettingsStatus    = $window.FindName("SettingsStatus")

$script:selectedBat = $null
$script:winwsProcess = $null

# --- Populate Strategy Combo ---
$script:batFiles = Get-ChildItem -Path $rootDir -Filter "general*.bat" |
    Where-Object { $_.Name -notlike "service*" } |
    Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) }

foreach ($f in $script:batFiles) {
    [void]$StrategyCombo.Items.Add($f.Name.Replace('.bat',''))
}
if ($StrategyCombo.Items.Count -gt 0) { $StrategyCombo.SelectedIndex = 0 }

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

# --- Strategy Launch from Combo ---
$BtnRunStrategy.Add_Click({
    $idx = $StrategyCombo.SelectedIndex
    if ($idx -ge 0 -and $idx -lt $script:batFiles.Count) {
        Stop-Winws
        $bat = $script:batFiles[$idx]
        $proc = Start-WinwsHidden -BatPath $bat.FullName -WorkDir $rootDir
        if (-not $proc) {
            $StatusText.Text = "Failed to start: $($bat.Name.Replace('.bat','')) (could not launch process)"
            $BtnStop.IsEnabled = $false
            return
        }
        $script:winwsProcess = $proc
        Start-Sleep -Seconds 3
        $running = (Get-Process -Name "winws" -ErrorAction SilentlyContinue) -ne $null
        if ($running) {
            $StatusText.Text = "Running: $($bat.Name.Replace('.bat',''))"
            $BtnStop.IsEnabled = $true
            $BtnLaunch.IsEnabled = $false
        } else {
            $stderr = ""
            $exitCode = -1
            try {
                if (-not $proc.HasExited) { $proc.WaitForExit(2000) }
                $stderr = $proc.StandardError.ReadToEnd()
                $exitCode = $proc.ExitCode
            } catch {}
            $detail = "exit=$exitCode"
            if ($stderr -and $stderr.Trim().Length -gt 0) {
                $shortErr = $stderr.Trim().Substring(0, [Math]::Min(120, $stderr.Trim().Length))
                $detail += " | $shortErr"
            }
            $StatusText.Text = "Failed: $($bat.Name.Replace('.bat','')) ($detail)"
            Write-Host "winws stderr: $stderr"
            $BtnStop.IsEnabled = $false
        }
    }
})

# --- Domain Management ---
$bypassFile     = Join-Path $listsDir "list-general-user.txt"
$excludeFile    = Join-Path $listsDir "list-exclude-user.txt"
$builtinBypass  = Join-Path $listsDir "list-general.txt"
$builtinExclude = Join-Path $listsDir "list-exclude.txt"
$script:bypassDomains  = [System.Collections.ArrayList]::new()
$script:excludeDomains = [System.Collections.ArrayList]::new()

function Refresh-DomainLists {
    $script:bypassDomains.Clear()
    $script:excludeDomains.Clear()
    foreach ($d in Read-DomainsFromFile $builtinBypass)  { [void]$script:bypassDomains.Add($d) }
    foreach ($d in Read-DomainsFromFile $bypassFile)      { [void]$script:bypassDomains.Add($d) }
    foreach ($d in Read-DomainsFromFile $builtinExclude) { [void]$script:excludeDomains.Add($d) }
    foreach ($d in Read-DomainsFromFile $excludeFile)     { [void]$script:excludeDomains.Add($d) }
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
    $userOnly = @($script:bypassDomains | Where-Object { $_ -notin (Read-DomainsFromFile $builtinBypass) })
    Write-DomainsToFile $bypassFile $userOnly
    $DomainInput.Text = ''
    Refresh-DomainLists
})

$BtnAddExclude.Add_Click({
    $domain = $DomainInput.Text.Trim()
    if ($domain -eq '' -or $domain -like '#*') { return }
    if ($script:excludeDomains -contains $domain) { return }
    [void]$script:excludeDomains.Add($domain)
    $userOnly = @($script:excludeDomains | Where-Object { $_ -notin (Read-DomainsFromFile $builtinExclude) })
    Write-DomainsToFile $excludeFile $userOnly
    $DomainInput.Text = ''
    Refresh-DomainLists
})

$BtnRemoveBypass.Add_Click({
    $sel = $BypassList.SelectedItem
    if ($sel) {
        [void]$script:bypassDomains.Remove($sel)
        $userOnly = @($script:bypassDomains | Where-Object { $_ -notin (Read-DomainsFromFile $builtinBypass) })
        Write-DomainsToFile $bypassFile $userOnly
        Refresh-DomainLists
    }
})

$BtnRemoveExclude.Add_Click({
    $sel = $ExcludeList.SelectedItem
    if ($sel) {
        [void]$script:excludeDomains.Remove($sel)
        $userOnly = @($script:excludeDomains | Where-Object { $_ -notin (Read-DomainsFromFile $builtinExclude) })
        Write-DomainsToFile $excludeFile $userOnly
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

    $localVer = Get-LocalVersion
    $UpdateLabel.Text = "Overlay: v$localVer"
    $UpdateRemoteLabel.Text = ""
    $BtnDownloadUpdate.Visibility = "Hidden"

    $flowsealLocal = Get-FlowsealLocalVersion
    $FlowsealLabel.Text = "Base: v$flowsealLocal"
    $FlowsealRemoteLabel.Text = ""
    $BtnDownloadFlowseal.Visibility = "Hidden"

    $svcInstalled = $false
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
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
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
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
    }
})

$script:latestRelease = $null
$script:latestFlowsealVer = $null

$BtnCheckFlowseal.Add_Click({
    $FlowsealRemoteLabel.Text = "Checking..."
    $FlowsealRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
    $BtnCheckFlowseal.IsEnabled = $false
    $BtnDownloadFlowseal.Visibility = "Hidden"

    $remoteVer = Get-FlowsealVersion
    $script:latestFlowsealVer = $remoteVer
    $localVer = Get-FlowsealLocalVersion

    if (-not $remoteVer) {
        $FlowsealRemoteLabel.Text = "Failed to check (network error)"
        $FlowsealRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
        $BtnCheckFlowseal.IsEnabled = $true
        return
    }

    $FlowsealRemoteLabel.Text = "Remote: v$remoteVer"

    if ($remoteVer -ne $localVer) {
        $FlowsealRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a9a6a")
        $BtnDownloadFlowseal.Visibility = "Visible"
        $BtnDownloadFlowseal.Content = "Update to v$remoteVer"
    } else {
        $FlowsealRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
    }
    $BtnCheckFlowseal.IsEnabled = $true
})

$BtnDownloadFlowseal.Add_Click({
    if (-not $script:latestFlowsealVer) {
        $SettingsStatus.Text = "No version info. Click Check Base first."
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
        return
    }

    $ver = $script:latestFlowsealVer

    $SettingsStatus.Text = "Downloading Flowseal v$ver ..."
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
    $BtnDownloadFlowseal.IsEnabled = $false
    $BtnCheckFlowseal.IsEnabled = $false

    $result = Download-FlowsealUpdate -Version $ver

    if ($result.Success) {
        $SettingsStatus.Text = "Base updated to v$ver! ($($result.Copied) items)"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
        $BtnDownloadFlowseal.Visibility = "Hidden"
        $FlowsealRemoteLabel.Text = "Remote: v$ver (downloaded)"
    } else {
        $SettingsStatus.Text = "Download failed: $($result.Error)"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
    }
    $BtnDownloadFlowseal.IsEnabled = $true
    $BtnCheckFlowseal.IsEnabled = $true
})

$BtnCheckUpdate.Add_Click({
    $UpdateRemoteLabel.Text = "Checking..."
    $UpdateRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
    $BtnCheckUpdate.IsEnabled = $false
    $BtnDownloadUpdate.Visibility = "Hidden"

    $release = Get-FlowCutterRelease
    $script:latestRelease = $release

    if (-not $release) {
        $UpdateRemoteLabel.Text = "Failed to check (no releases or network error)"
        $UpdateRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
        $BtnCheckUpdate.IsEnabled = $true
        return
    }

    $remoteVer = $release.tag_name.TrimStart("v")
    $localVer = Get-LocalVersion
    $UpdateRemoteLabel.Text = "Remote: v$remoteVer"

    if ($remoteVer -ne $localVer) {
        $UpdateRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a9a6a")
        $BtnDownloadUpdate.Visibility = "Visible"
        $BtnDownloadUpdate.Content = "Update to v$remoteVer"
    } else {
        $UpdateRemoteLabel.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
    }
    $BtnCheckUpdate.IsEnabled = $true
})

$BtnDownloadUpdate.Add_Click({
    if (-not $script:latestRelease) {
        $SettingsStatus.Text = "No release info. Click Check first."
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
        return
    }

    $zipUrl = $script:latestRelease.zipball_url
    $ver = $script:latestRelease.tag_name

    $SettingsStatus.Text = "Downloading $ver ..."
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
    $BtnDownloadUpdate.IsEnabled = $false
    $BtnCheckUpdate.IsEnabled = $false

    $result = Download-FlowCutterUpdate -ZipUrl $zipUrl -Version $ver

    if ($result.Success) {
        $SettingsStatus.Text = "Updated to $ver! ($($result.Copied) items) Restart FlowCutter to apply."
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
        $BtnDownloadUpdate.Visibility = "Hidden"
        $UpdateRemoteLabel.Text = "Remote: $ver (downloaded)"
    } else {
        $SettingsStatus.Text = "Download failed: $($result.Error)"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
    }
    $BtnDownloadUpdate.IsEnabled = $true
    $BtnCheckUpdate.IsEnabled = $true
})

$BtnCheckStatus.Add_Click({
    Refresh-Settings
    $SettingsStatus.Text = "Status refreshed"
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#666666")
})

$BtnInstallService.Add_Click({
    Stop-Winws
    $batFiles = Get-ChildItem -Path $rootDir -Filter "general*.bat" |
        Where-Object { $_.Name -notlike "service*" } |
        Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) }

    $SettingsStatus.Text = "Use 'service.bat > Install Service' to pick a strategy. Available: $($batFiles.Count) configs."
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#666666")
})

$BtnRemoveService.Add_Click({
    $r1 = & net stop zapret 2>&1
    $r2 = & sc delete zapret 2>&1
    Stop-Winws
    $r3 = & net stop WinDivert 2>&1
    $r4 = & sc delete WinDivert 2>&1
    Refresh-Settings
    $SettingsStatus.Text = "Service removed."
    $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
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
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#6a9a7a")
    } catch {
        $SettingsStatus.Text = "Failed to update IPSet: $_"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
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
            $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#666666")
        }
    } catch {
        $SettingsStatus.Text = "Failed to download hosts: $_"
        $SettingsStatus.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9a6a6a")
    }
})

# --- Strategy Finder (background runspace) ---
function Start-Scan {
    $BtnFindBest.IsEnabled = $false
    $BtnLaunch.IsEnabled = $false
    $BtnStop.IsEnabled = $false
    $ResultsGrid.ItemsSource = $null
    $ProgressFill.Width = 0
    $ProgressText.Text = "0%"
    $StatusText.Text = "Scanning..."
    $StatusText.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#555555")

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
                        $after = $t -replace '.*winws\.exe["\s]*', ''
                        $parts += $after; $inCmd = $true; continue
                    }
                    if ($inCmd) {
                        if ($t.EndsWith('^')) { $parts += $t.TrimEnd('^').Trim() }
                        else { $parts += $t; $inCmd = $false }
                    }
                }
                if ($parts.Count -gt 0) {
                    $gf = Get-GameFilterValues
                    $cmd = ($parts -join ' ') -replace '%BIN%',$binPath -replace '%LISTS%',$listsPath -replace '%GameFilterTCP%',$gf.TCP -replace '%GameFilterUDP%',$gf.UDP
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
                $st.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#888888")
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
        $proc = Start-WinwsHidden -BatPath $script:selectedBat -WorkDir $rootDir
        if (-not $proc) {
            $StatusText.Text = "Failed to start: $([System.IO.Path]::GetFileNameWithoutExtension($script:selectedBat)) (could not launch process)"
            $BtnStop.IsEnabled = $false
            return
        }
        $script:winwsProcess = $proc
        Start-Sleep -Seconds 3
        $running = (Get-Process -Name "winws" -ErrorAction SilentlyContinue) -ne $null
        if ($running) {
            $StatusText.Text = "Running: $([System.IO.Path]::GetFileNameWithoutExtension($script:selectedBat))"
            $BtnStop.IsEnabled = $true
            $BtnLaunch.IsEnabled = $false
        } else {
            $stderr = ""
            $exitCode = -1
            try {
                if (-not $proc.HasExited) { $proc.WaitForExit(2000) }
                $stderr = $proc.StandardError.ReadToEnd()
                $exitCode = $proc.ExitCode
            } catch {}
            $detail = "exit=$exitCode"
            if ($stderr -and $stderr.Trim().Length -gt 0) {
                $shortErr = $stderr.Trim().Substring(0, [Math]::Min(120, $stderr.Trim().Length))
                $detail += " | $shortErr"
            }
            $StatusText.Text = "Failed: $([System.IO.Path]::GetFileNameWithoutExtension($script:selectedBat)) ($detail)"
            Write-Host "winws stderr: $stderr"
            $BtnStop.IsEnabled = $false
        }
    }
})

$BtnStop.Add_Click({
    Stop-Winws
    $script:winwsProcess = $null
    $StatusText.Text = "Stopped"
    $BtnStop.IsEnabled = $false
})

$BtnFindBest.Add_Click({ Start-Scan })

$ResultsGrid.Add_SelectionChanged({
    $sel = $ResultsGrid.SelectedItem
    if ($sel) {
        $script:selectedBat = $sel.Path
        $BtnLaunch.IsEnabled = $true
        for ($i = 0; $i -lt $StrategyCombo.Items.Count; $i++) {
            if ($StrategyCombo.Items[$i] -eq $sel.StratName) {
                $StrategyCombo.SelectedIndex = $i
                break
            }
        }
    }
})

# --- Status Polling Timer ---
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    $running = (Get-Process -Name "winws" -ErrorAction SilentlyContinue) -ne $null
    if (-not $running -and $BtnStop.IsEnabled) {
        $BtnStop.IsEnabled = $false
        $StatusText.Text = "winws stopped"
    } elseif ($running -and -not $BtnStop.IsEnabled -and $script:selectedBat) {
        $BtnStop.IsEnabled = $true
    }
})
$timer.Start()

# --- Init ---
Refresh-DomainLists
$null = $window.ShowDialog()
$timer.Stop()
