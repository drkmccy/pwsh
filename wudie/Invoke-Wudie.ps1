<#PSScriptInfo

.SYNOPSIS
Installs Windows drivers with class filtering, per-driver streaming downloads/installs, chipset prioritization, live visual reporting, and interactive reboot handling.

.VERSION 1.03

.AUTHOR drkmccy

.RELEASENOTES
Version 1.06:	Changed connectivity check to actual Windows Update endpoints, tidied up table output.
Version 1.05:	Replaced Write-Progress with [Console]::Write, improved feedback.
Version 1.04:	Connectivity check now displayed, added "other" driver type, tidied up the output table.
Version 1.03:	Connectivity check changed to actual Microsoft endpoints, driver type mapping improved.
Version 1.02:	Dropped download concurrency so switched to interleaved download>Install pipeline.
Version 1.01:	Single table output, tidied column headers, reboot prompt.
Version 1.00:	Added connectivity check, download concurrency, driver type filters, installation priority and visual overhaul.

#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $False)] [ValidateSet('Soft', 'Hard', 'None', 'Delayed')] [String] $Reboot = 'Soft',
    [Parameter(Mandatory = $False)] [Int32] $RebootTimeout = 120,
    [Parameter(Mandatory = $False)] [switch] $ExcludeDrivers = $false,
    [Parameter(Mandatory = $False)] [switch] $ExcludeUpdates = $true,
    [Parameter(Mandatory = $False)] [String] $DriverType
)

Begin {
    $ProgressPreference = 'SilentlyContinue'
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    # 1. Internet & Endpoint Connectivity Verification
    function Test-InternetAccess {
        $endpoints = @(
            "windowsupdate.microsoft.com",
            "download.windowsupdate.com",
            "go.microsoft.com",
            "ctldl.windowsupdate.com"
        )
        do {
            Write-Host "Checking connectivity to Windows Update endpoints...`n" -ForegroundColor Cyan
            Write-Host ("{0,-35} {1,-10}" -f @("Endpoint", "Status")) -ForegroundColor Cyan
            Write-Host ("{0,-35} {1,-10}" -f @("--------", "------")) -ForegroundColor DarkGray

            $allOnline = $true

            foreach ($endpoint in $endpoints) {
                [Console]::Write("{0,-35} " -f $endpoint)

                $isOnline = $false
                # Try standard ICMP Ping first
                if (Test-Connection -ComputerName $endpoint -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                    $isOnline = $true
                } else {
                    # Fallback to TCP Port 443 check if ICMP is blocked
                    $tcpTest = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
                    if ($tcpTest.TcpTestSucceeded) {
                        $isOnline = $true
                    }
                }

                if ($isOnline) {
                    [Console]::ForegroundColor = [ConsoleColor]::Green
                    [Console]::WriteLine("[OK]")
                } else {
                    [Console]::ForegroundColor = [ConsoleColor]::Red
                    [Console]::WriteLine("[KO]")
                    $allOnline = $false
                }
                [Console]::ResetColor()
            }

            if (-not $allOnline) {
                Write-Host "`n[!] Cannot reach required Windows Update endpoints." -ForegroundColor Red
                $choice = Read-Host "Connect to the internet and press Enter to retry (or type 'Q' to quit)"
                if ($choice -eq 'Q' -or $choice -eq 'q') {
                    Write-Host "Execution cancelled." -ForegroundColor Yellow
                    Exit 1
                }
            }
        } while (-not $allOnline)
        Write-Host "`n[+] Connection to Windows Update endpoints confirmed.`n" -ForegroundColor Green
    }
}

Process {
    Test-InternetAccess

    # 64-bit Process Relaunch Check
    if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64") {
        if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe") {
            $scriptArgs = "-Reboot $Reboot -RebootTimeout $RebootTimeout"
            if ($ExcludeDrivers) { $scriptArgs += " -ExcludeDrivers" }
            if ($ExcludeUpdates) { $scriptArgs += " -ExcludeUpdates" }
            if ($DriverType)     { $scriptArgs += " -DriverType `"$DriverType`"" }

            Start-Process "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe" `
                -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$PSCommandPath`" $scriptArgs" -Wait
            Exit $lastexitcode
        }
    }

    # Tagging and Logging Setup
    if (-not (Test-Path "$($env:ProgramData)\Microsoft\UpdateOS")) {
        New-Item -ItemType Directory -Path "$($env:ProgramData)\Microsoft\UpdateOS" -Force | Out-Null
    }
    Set-Content -Path "$($env:ProgramData)\Microsoft\UpdateOS\UpdateOS.ps1.tag" -Value "Installed"
    Start-Transcript "$($env:ProgramData)\Microsoft\UpdateOS\UpdateOS.log" -Append

    # Opt into Microsoft Update Service
    Write-Host "Opting into Microsoft Update..." -ForegroundColor Cyan
    $ServiceManager = New-Object -ComObject "Microsoft.Update.ServiceManager"
    $ServiceID = "7971f918-a847-4430-9279-4a52d1efe18d"
    $ServiceManager.AddService2($ServiceID, 7, "") | Out-Null

    # Build Queries
    if ($ExcludeDrivers)     { $queries = @("IsInstalled=0 and Type='Software'") }
    elseif ($ExcludeUpdates) { $queries = @("IsInstalled=0 and Type='Driver'") }
    else                     { $queries = @("IsInstalled=0 and Type='Software'", "IsInstalled=0 and Type='Driver'") }

    [Console]::Write("`rSearching for available driver updates...   ")
    $Session = New-Object -ComObject Microsoft.Update.Session
    $Searcher = $Session.CreateUpdateSearcher()
    $RawUpdates = New-Object -ComObject Microsoft.Update.UpdateColl

    foreach ($q in $queries) {
        try {
            $searchResults = $Searcher.Search($q)
            foreach ($upd in $searchResults.Updates) {
                if (-not $upd.EulaAccepted) { $upd.AcceptEula() }
                
                $isFeatureUpdate = $upd.Categories | Where-Object { $_.CategoryID -eq "3689BDC8-B205-4AF4-8D4A-A63924C5E9D5" }
                if (-not $isFeatureUpdate -and $upd.Title -notmatch "Preview") {
                    [void]$RawUpdates.Add($upd)
                }
            }
        } catch {
            Write-Warning "Unable to search updates: $_"
        }
    }

    [Console]::WriteLine("`rSearching for available driver updates... Done!   ")

    if ($RawUpdates.Count -eq 0) {
        Write-Host "No updates found." -ForegroundColor Yellow
        Stop-Transcript
        Exit 0
    }

    # Known Driver Type Keyword Mapping (Explicit Categories)
    $DriverTypeMap = @{
        'n' = "Network|Wi-Fi|Wireless|WLAN|Ethernet|Bluetooth|LAN|NIC| net "
        'f' = "Firmware|BIOS|System Hardware"
        's' = "Audio|Sound|Realtek|Media"
        'v' = "Graphics|Display|Video|NVIDIA|AMD|Radeon|Intel.*Graphics"
        't' = "Touchpad|Synaptics|ELAN|HID|Input|Trackpad"
        'c' = "Chipset|Management Engine|MEI|Serial IO| System "
    }

    # Combined Regex for all explicitly defined categories
    $allKnownRegex = "(?i)" + (($DriverTypeMap.Values) -join "|")

    # Driver Type Filtering
    $FilteredUpdates = @()
    if ($PSBoundParameters.ContainsKey('DriverType') -and -not [string]::IsNullOrWhiteSpace($DriverType)) {
        $charList = $DriverType.ToLower().ToCharArray() | Select-Object -Unique

        foreach ($upd in $RawUpdates) {
            $matchFound = $false
            foreach ($char in $charList) {
                $cStr = [string]$char
                if ($cStr -eq 'o') {
                    # 'o' matches anything NOT covered by defined categories
                    if ($upd.Title -notmatch $allKnownRegex) {
                        $matchFound = $true
                        break
                    }
                } elseif ($DriverTypeMap.ContainsKey($cStr)) {
                    if ($upd.Title -match ("(?i)" + $DriverTypeMap[$cStr])) {
                        $matchFound = $true
                        break
                    }
                }
            }
            if ($matchFound) {
                $FilteredUpdates += $upd
            }
        }
    } else {
        $FilteredUpdates = @($RawUpdates)
    }

    if ($FilteredUpdates.Count -eq 0) {
        Write-Host "No drivers match the specified driver type filter: '$DriverType'" -ForegroundColor Yellow
        Stop-Transcript
        Exit 0
    }

    # Sorting Logic: Prioritize Chipset Drivers First
    $chipsetRegex = "(?i)" + $DriverTypeMap['c']
    $chipsetGroup = @()
    $otherGroup   = @()

    foreach ($upd in $FilteredUpdates) {
        if ($upd.Title -match $chipsetRegex) {
            $chipsetGroup += $upd
        } else {
            $otherGroup += $upd
        }
    }
    $OrderedUpdates = $chipsetGroup + $otherGroup

    # Setup Dynamic Counters and Visual Table Header
    $TotalCount   = $OrderedUpdates.Count
    $padWidth     = $TotalCount.ToString().Length
    $CurrentIndex = 0
    $script:needReboot = $false

    Write-Host "`nProcessing $TotalCount driver update(s)...`n" -ForegroundColor Cyan
    Write-Host ("{0,-4} {1,-50} {2,-15} {3,-8} {4,-22}" -f @("#", "Title", "Type", "Reboot", "Status")) -ForegroundColor Cyan
    Write-Host ("{0,-4} {1,-50} {2,-15} {3,-8} {4,-22}" -f @("---", "-----", "----", "------", "------")) -ForegroundColor DarkGray

    # Streaming Download & Install Loop with Live Console Overwrites
    foreach ($upd in $OrderedUpdates) {
        $CurrentIndex++
        $remainingCount = $TotalCount - $CurrentIndex + 1
        $countStr = $remainingCount.ToString("D$padWidth")

        # Calculate Size
        $sizeMB = [math]::Round($upd.MaxDownloadSize / 1MB, 2)
        $sizeDisplay = if ($sizeMB -gt 0) { "$sizeMB MB" } else { "< 1 MB" }

        # Tag Type Classification
        $type = "Other"
        if ($upd.Title -match $chipsetRegex)                      { $type = "Chipset" }
        elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['n'])) { $type = "Networking" }
        elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['v'])) { $type = "Video" }
        elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['s'])) { $type = "Sound" }
        elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['f'])) { $type = "Firmware" }
        elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['t'])) { $type = "Touchpad" }

        $titleDisplay = if ($upd.Title.Length -gt 47) { $upd.Title.Substring(0, 44) + "..." } else { $upd.Title }

        # Single Item Collection
        $singleColl = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$singleColl.Add($upd)

        # 1. LIVE UPDATE: Download Phase (Status at End)
        $dlStatusStr = "Download ($sizeDisplay)"
        [Console]::Write("`r{0,-4} {1,-50} {2,-15} {3,-8} " -f @($countStr, $titleDisplay, $type, "-"))
        [Console]::ForegroundColor = [ConsoleColor]::Cyan
        [Console]::Write("{0,-22}" -f $dlStatusStr)
        [Console]::ResetColor()

        $Downloader = $Session.CreateUpdateDownloader()
        $Downloader.Updates = $singleColl
        $DownloadResult = $Downloader.Download()

        # 2. LIVE UPDATE: Install Phase (Status at End)
        $instStatusStr = "Installing..."
        [Console]::Write("`r{0,-4} {1,-50} {2,-15} {3,-8} " -f @($countStr, $titleDisplay, $type, "-"))
        [Console]::ForegroundColor = [ConsoleColor]::Yellow
        [Console]::Write("{0,-22}" -f $instStatusStr)
        [Console]::ResetColor()

        $Installer = $Session.CreateUpdateInstaller()
        $Installer.Updates = $singleColl
        $Installer.ForceQuiet = $true

        $InstallResult = $Installer.Install()
        $isSuccess = ($InstallResult.ResultCode -eq 2)
        if ($InstallResult.RebootRequired) { $script:needReboot = $true }
        $rebootNeededStr = if ($InstallResult.RebootRequired) { "Yes" } else { "No" }

        # 3. FINAL LOCK-IN: Overwrite line with final Reboot status and [SUCCESS] or [FAILURE]
        [Console]::Write("`r{0,-4} {1,-50} {2,-15} {3,-8} " -f @($countStr, $titleDisplay, $type, $rebootNeededStr))
        if ($isSuccess) {
            [Console]::ForegroundColor = [ConsoleColor]::Green
            [Console]::Write("{0,-22}" -f "[SUCCESS]")
        } else {
            [Console]::ForegroundColor = [ConsoleColor]::Red
            [Console]::Write("{0,-22}" -f "[FAILURE]")
        }
        [Console]::ResetColor()
        [Console]::WriteLine("")
    }

    [Console]::WriteLine("")

    # Interactive Reboot Verification
    if ($script:needReboot) {
        Write-Host "[!] A system reboot is required to complete driver installation." -ForegroundColor Yellow
        $rebootChoice = Read-Host "Would you like to reboot immediately? (Y/N) [Default: N]"
        
        if ($rebootChoice -match "^[Yy]$") {
            Write-Host "Rebooting system..." -ForegroundColor Red
            Stop-Transcript
            & shutdown.exe /r /t 0 /c "Rebooting to complete driver installation."
            Exit 0
        } else {
            Write-Host "Reboot deferred. Please reboot your computer later to apply updates." -ForegroundColor Yellow
            Stop-Transcript
            Exit 0
        }
    } else {
        Write-Host "All driver updates completed without requiring a reboot." -ForegroundColor Green
        Stop-Transcript
        Exit 0
    }
}
