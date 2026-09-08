<#
.SYNOPSIS
Installs Windows drivers with class filtering, concurrent downloading, chipset prioritization, and progress visualizers.
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory = $False)] [ValidateSet('Soft', 'Hard', 'None', 'Delayed')] [String] $Reboot = 'Soft',
    [Parameter(Mandatory = $False)] [Int32] $RebootTimeout = 120,
    [Parameter(Mandatory = $False)] [switch] $ExcludeDrivers = $false,
    [Parameter(Mandatory = $False)] [switch] $ExcludeUpdates = $true,
    [Parameter(Mandatory = $False)] [String] $Class
)

Begin {
    # 1. Internet Connectivity Verification
    function Test-InternetAccess {
        do {
            Write-Host "Checking internet connectivity..." -ForegroundColor Cyan
            $isOnline = Test-Connection -ComputerName "www.microsoft.com" -Count 1 -Quiet -ErrorAction SilentlyContinue
            if (-not $isOnline) {
                $isOnline = Test-Connection -ComputerName "1.1.1.1" -Count 1 -Quiet -ErrorAction SilentlyContinue
            }
            if (-not $isOnline) {
                Write-Host "[!] No internet connection detected." -ForegroundColor Red
                $choice = Read-Host "Connect to the internet and press Enter to retry (or type 'Q' to quit)"
                if ($choice -eq 'Q' -or $choice -eq 'q') {
                    Write-Host "Execution cancelled." -ForegroundColor Yellow
                    Exit 1
                }
            }
        } while (-not $isOnline)
        Write-Host "[+] Internet connection confirmed.`n" -ForegroundColor Green
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
            if ($Class)          { $scriptArgs += " -Class `"$Class`"" }

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

    Write-Progress -Activity "Windows Driver Update" -Status "Searching for available updates..." -PercentComplete 5
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

    if ($RawUpdates.Count -eq 0) {
        Write-Host "No updates found." -ForegroundColor Yellow
        Stop-Transcript
        Exit 0
    }

    # Class Keyword Mapping & Title Filtering
    $ClassMap = @{
        'n' = "Network|Wi-Fi|Wireless|WLAN|Ethernet|Bluetooth|LAN|NIC"
        'f' = "Firmware|BIOS|System Hardware"
        's' = "Audio|Sound|Realtek|Media"
        'v' = "Graphics|Display|Video|NVIDIA|AMD|Radeon|Intel.*Graphics"
        'o' = "Card Reader|Camera|Sensor|PCI|USB"
        't' = "Touchpad|Synaptics|HID|Input|Trackpad"
        'c' = "Chipset|Management Engine|MEI|Serial IO"
    }

    $FilteredUpdates = @()
    if ($PSBoundParameters.ContainsKey('Class') -and -not [string]::IsNullOrWhiteSpace($Class)) {
        $charList = $Class.ToLower().ToCharArray() | Select-Object -Unique
        $regexPatterns = @()
        foreach ($char in $charList) {
            if ($ClassMap.ContainsKey([string]$char)) {
                $regexPatterns += $ClassMap[[string]$char]
            }
        }
        
        if ($regexPatterns.Count -gt 0) {
            $combinedRegex = "(?i)" + ($regexPatterns -join "|")
            foreach ($upd in $RawUpdates) {
                if ($upd.Title -match $combinedRegex) {
                    $FilteredUpdates += $upd
                }
            }
        } else {
            $FilteredUpdates = @($RawUpdates)
        }
    } else {
        $FilteredUpdates = @($RawUpdates)
    }

    if ($FilteredUpdates.Count -eq 0) {
        Write-Host "No drivers match the specified class filter: '$Class'" -ForegroundColor Yellow
        Stop-Transcript
        Exit 0
    }

    # Sorting Logic: Prioritize Chipset Drivers First
    $chipsetRegex = "(?i)Chipset|Management Engine|MEI|Serial IO"
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

    # Assemble updates into collection for downloading
    $DownloadColl = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($upd in $OrderedUpdates) {
        [void]$DownloadColl.Add($upd)
    }

    # Batch Download Execution
    Write-Host "Starting batch download for $($OrderedUpdates.Count) driver(s)..." -ForegroundColor Cyan
    Write-Progress -Activity "Downloading Drivers" -Status "Downloading $($OrderedUpdates.Count) drivers..." -PercentComplete 50

    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $DownloadColl
    $DownloadResult = $Downloader.Download()

    Write-Progress -Activity "Downloading Drivers" -Completed
    Write-Host "[+] Batch driver download complete (Result Code: $($DownloadResult.ResultCode)).`n" -ForegroundColor Green

    # Sequential Installation & Visual UI Tracking
    $TotalCount   = $OrderedUpdates.Count
    $CurrentIndex = 0
    $ResultsList  = [System.Collections.Generic.List[PSCustomObject]]::new()
    $script:needReboot = $false

    Write-Host "Starting Driver Installation Sequence..." -ForegroundColor Cyan

    foreach ($upd in $OrderedUpdates) {
        $CurrentIndex++
        $Remaining = $TotalCount - $CurrentIndex

        Write-Progress -Activity "Installing Drivers" `
            -Status "[$CurrentIndex/$TotalCount] Installing: $($upd.Title)" `
            -PercentComplete (($CurrentIndex / $TotalCount) * 100)

        $InstallColl = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$InstallColl.Add($upd)

        $Installer = $Session.CreateUpdateInstaller()
        $Installer.Updates = $InstallColl
        $Installer.ForceQuiet = $true

        $InstallResult = $Installer.Install()
        $isSuccess = ($InstallResult.ResultCode -eq 2)
        if ($InstallResult.RebootRequired) { $script:needReboot = $true }

        # Real-time Colored Console Feedback
        if ($isSuccess) {
            Write-Host "[SUCCESS] ($CurrentIndex/$TotalCount) $($upd.Title) | Remaining: $Remaining" -ForegroundColor Green
        } else {
            Write-Host "[FAILED]  ($CurrentIndex/$TotalCount) $($upd.Title) (HResult: $($InstallResult.HResult)) | Remaining: $Remaining" -ForegroundColor Red
        }

        # Tag Category for Final Summary Table
        $cat = "Other"
        if ($upd.Title -match $chipsetRegex)    { $cat = "Chipset" }
        elseif ($upd.Title -match $ClassMap['n']) { $cat = "Networking" }
        elseif ($upd.Title -match $ClassMap['v']) { $cat = "Video" }
        elseif ($upd.Title -match $ClassMap['s']) { $cat = "Sound" }
        elseif ($upd.Title -match $ClassMap['f']) { $cat = "Firmware" }
        elseif ($upd.Title -match $ClassMap['t']) { $cat = "Touchpad" }

        $ResultsList.Add([PSCustomObject]@{
            Step         = "$CurrentIndex/$TotalCount"
            Category     = $cat
            DriverTitle  = $upd.Title
            Status       = if ($isSuccess) { "Success" } else { "Failed" }
            RebootNeeded = $InstallResult.RebootRequired
        })
    }

    Write-Progress -Activity "Installing Drivers" -Completed

    # Final Display Table Output
    Write-Host "`n======================= Driver Installation Results =======================" -ForegroundColor Cyan
    $ResultsList | Format-Table -AutoSize

    # System Reboot Handling
    if ($script:needReboot) {
        Write-Host "Windows Update indicates a reboot is required." -ForegroundColor Yellow
        if ($Reboot -eq "Hard") {
            Stop-Transcript
            Exit 1641
        } elseif ($Reboot -eq "Soft") {
            Stop-Transcript
            Exit 3010
        } elseif ($Reboot -eq "Delayed") {
            Write-Host "Scheduling reboot in $RebootTimeout seconds..." -ForegroundColor Yellow
            & shutdown.exe /r /t $RebootTimeout /c "Rebooting to complete driver installation."
            Exit 0
        }
    } else {
        Write-Host "All driver updates completed without requiring a reboot." -ForegroundColor Green
    }

    Stop-Transcript
    Exit 0
}
