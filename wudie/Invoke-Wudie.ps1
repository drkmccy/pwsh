<#PSScriptInfo

.SYNOPSIS
Installs Windows drivers with class filtering, per-driver streaming downloads/installs, chipset prioritization, live visual reporting, and interactive reboot handling.

.VERSION 1.08

.AUTHOR drkmccy

.RELEASENOTES
Version 1.08:	Dropped TCP connectivity check, added AC power warning for firmware updates, table now has dynamic filesize.
Version 1.07:	Added retry loop logic for install failures, fixed update endpoint check bug.
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
            "download.windowsupdate.com",
            "download.microsoft.com",
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
                if (Test-Connection -ComputerName $endpoint -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                    $isOnline = $true
                } else {
                    $tcpTest = Test-NetConnection -ComputerName $endpoint -Port 443 -WarningAction SilentlyContinue
                    if ($tcpTest.TcpTestSucceeded) { $isOnline = $true }
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

    # Helper function for dynamic file size formatting
    function Format-FileSize ([double]$bytes) {
        if ($bytes -ge 1GB)       { return ("{0:0.00} GB" -f ($bytes / 1GB)) }
        elseif ($bytes -ge 100MB) { return ("{0:0} MB"   -f ($bytes / 1MB)) }
        elseif ($bytes -ge 10MB)  { return ("{0:0.0} MB" -f ($bytes / 1MB)) }
        elseif ($bytes -ge 1MB)   { return ("{0:0.00} MB" -f ($bytes / 1MB)) }
        elseif ($bytes -ge 1KB)   { return ("{0:0} KB"   -f ($bytes / 1KB)) }
        elseif ($bytes -gt 0)     { return ("< 1 KB") }
        else                      { return ("0 KB") }
    }

    # Helper function for AC Power Check
    function Test-ACPower {
        $batteries = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
        if (-not $batteries) { return $true } # Desktop PC has no battery (always AC)
        $charging = $batteries | Where-Object { $_.BatteryStatus -in @(2, 6, 7, 8, 9) }
        if ($charging) { return $true }
        
        $bs = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue
        if ($bs -and $bs.PowerOnline) { return $true }
        return $false
    }

    # Helper function for non-blocking timeout prompt
    function Get-InputWithTimeout {
        param([string]$PromptText, [int]$TimeoutSeconds = 10)
        
        $startTime = [DateTime]::Now
        while (([DateTime]::Now - $startTime).TotalSeconds -lt $TimeoutSeconds) {
            $secondsLeft = [math]::Max(0, [int]($TimeoutSeconds - ([DateTime]::Now - $startTime).TotalSeconds))
            [Console]::Write("`r$PromptText ($secondsLeft`s left): ")
            
            if ([Console]::KeyAvailable) {
                $keyInfo = [Console]::ReadKey($true)
                if ($keyInfo.Key -eq [ConsoleKey]::Enter) {
                    [Console]::WriteLine("")
                    return ""
                } else {
                    $keyChar = $keyInfo.KeyChar.ToString()
                    [Console]::WriteLine($keyChar)
                    return $keyChar
                }
            }
            Start-Sleep -Milliseconds 100
        }
        [Console]::WriteLine("")
        return ""
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

    [Console]::Write("Searching for available driver updates...   ")
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
        'i' = "Touchpad|Synaptics|ELAN|HID|Input|Trackpad"
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

    # Three-Tier Sorting: Chipset Drivers First, Other Drivers Middle, Firmware Drivers LAST
    $chipsetRegex  = "(?i)" + $DriverTypeMap['c']
    $firmwareRegex = "(?i)" + $DriverTypeMap['f']

    $chipsetGroup  = @()
    $firmwareGroup = @()
    $otherGroup    = @()

    foreach ($upd in $FilteredUpdates) {
        if ($upd.Title -match $chipsetRegex) {
            $chipsetGroup += $upd
        } elseif ($upd.Title -match $firmwareRegex) {
            $firmwareGroup += $upd
        } else {
            $otherGroup += $upd
        }
    }
    
    $BatchToProcess = $chipsetGroup + $otherGroup + $firmwareGroup

    # Firmware Power Check & Warning
    if ($firmwareGroup.Count -gt 0) {
        if (-not (Test-ACPower)) {
            Write-Host "`n[!] WARNING: $($firmwareGroup.Count) Firmware/BIOS update(s) detected!" -ForegroundColor Yellow
            Write-Host "    Please connect your device to AC power. Firmware updates are scheduled to install LAST." -ForegroundColor Yellow
        }
    }

    $script:needReboot = $false
    $previousFailureCount = [int]::MaxValue

    # Installation and Retry Loop
    do {
        $TotalCount   = $BatchToProcess.Count
        $padWidth     = $TotalCount.ToString().Length
        $CurrentIndex = 0
        $failedUpdates = @()

        Write-Host "`nProcessing $TotalCount driver update(s)...`n" -ForegroundColor Cyan
        Write-Host ("{0,-4} {1,-60} {2,-12} {3,-9} {4,-16} {5,-8}" -f @("#", "Title", "Type", "Size", "Status", "Reboot")) -ForegroundColor Cyan
        Write-Host ("{0,-4} {1,-60} {2,-12} {3,-9} {4,-16} {5,-8}" -f @("---", "-----", "----", "----", "------", "------")) -ForegroundColor DarkGray

        foreach ($upd in $BatchToProcess) {
            $CurrentIndex++
            $remainingCount = $TotalCount - $CurrentIndex + 1
            $countStr = $remainingCount.ToString("D$padWidth")

            # Calculate Formatted Size
            $sizeDisplay = Format-FileSize -bytes $upd.MaxDownloadSize

            # Tag Type Classification
            $type = "Other"
            if ($upd.Title -match $chipsetRegex)                      { $type = "Chipset" }
            elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['n'])) { $type = "Networking" }
            elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['v'])) { $type = "Video" }
            elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['s'])) { $type = "Sound" }
            elseif ($upd.Title -match $firmwareRegex)                 { $type = "Firmware" }
            elseif ($upd.Title -match ("(?i)" + $DriverTypeMap['i'])) { $type = "Input" }

            $titleDisplay = if ($upd.Title.Length -gt 57) { $upd.Title.Substring(0, 54) + "..." } else { $upd.Title }

            # Single Item Collection
            $singleColl = New-Object -ComObject Microsoft.Update.UpdateColl
            [void]$singleColl.Add($upd)

            # 1. LIVE UPDATE: Download Phase
            [Console]::Write("`r{0,-4} {1,-60} {2,-12} {3,-9} " -f @($countStr, $titleDisplay, $type, $sizeDisplay))
            [Console]::ForegroundColor = [ConsoleColor]::Cyan
            [Console]::Write("{0,-16}" -f "Downloading")
            [Console]::ResetColor()
            [Console]::Write("{0,-8}" -f "-")

            $Downloader = $Session.CreateUpdateDownloader()
            $Downloader.Updates = $singleColl
            $DownloadResult = $Downloader.Download()

            # 2. LIVE UPDATE: Install Phase
            [Console]::Write("`r{0,-4} {1,-60} {2,-12} {3,-9} " -f @($countStr, $titleDisplay, $type, $sizeDisplay))
            [Console]::ForegroundColor = [ConsoleColor]::Yellow
            [Console]::Write("{0,-16}" -f "Installing...")
            [Console]::ResetColor()
            [Console]::Write("{0,-8}" -f "-")

            $Installer = $Session.CreateUpdateInstaller()
            $Installer.Updates = $singleColl
            $Installer.ForceQuiet = $true

            $InstallResult = $Installer.Install()
            $isSuccess = ($InstallResult.ResultCode -eq 2)
            if ($InstallResult.RebootRequired) { $script:needReboot = $true }
            $rebootNeededStr = if ($InstallResult.RebootRequired) { "Yes" } else { "No" }

            # 3. FINAL LOCK-IN: Overwrite line with [SUCCESS]/[FAILURE] in Status column, followed by Reboot column
            [Console]::Write("`r{0,-4} {1,-60} {2,-12} {3,-9} " -f @($countStr, $titleDisplay, $type, $sizeDisplay))
            if ($isSuccess) {
                [Console]::ForegroundColor = [ConsoleColor]::Green
                [Console]::Write("{0,-16}" -f "[SUCCESS]")
            } else {
                [Console]::ForegroundColor = [ConsoleColor]::Red
                [Console]::Write("{0,-16}" -f "[FAILURE]")
                $failedUpdates += $upd
            }
            [Console]::ResetColor()
            [Console]::Write("{0,-8}" -f $rebootNeededStr)
            [Console]::WriteLine("")
        }

        [Console]::WriteLine("")

        # Evaluate Failures and Prompt Logic
        if ($failedUpdates.Count -gt 0) {
            if ($failedUpdates.Count -ge $previousFailureCount) {
                Write-Host "[!] $($failedUpdates.Count) driver(s) failed to install again. Stopping retry attempts." -ForegroundColor Red
                break
            }

            $previousFailureCount = $failedUpdates.Count
            Write-Host "[!] $($failedUpdates.Count) driver installation(s) failed." -ForegroundColor Yellow
            $userChoice = Get-InputWithTimeout -PromptText "Press Enter to retry failed installs, 'R' to reboot, or 'Q' to quit" -TimeoutSeconds 10

            if ($userChoice -match "^[Qq]$") {
                Write-Host "Execution cancelled by user." -ForegroundColor Yellow
                Stop-Transcript
                Exit 1
            } elseif ($userChoice -match "^[Rr]$") {
                break
            } else {
                $BatchToProcess = $failedUpdates
                Write-Host "`nRetrying $($failedUpdates.Count) failed driver update(s)..." -ForegroundColor Cyan
            }
        } else {
            break
        }
    } while ($true)

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
        Write-Host "All processed driver updates completed without requiring a reboot." -ForegroundColor Green
        Stop-Transcript
        Exit 0
    }
}
