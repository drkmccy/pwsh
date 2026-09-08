<#PSScriptInfo

.VERSION 1.0

.AUTHOR drkmccy

.RELEASENOTES

Version 1.01:    Single table output, tidied column headers, reboot prompt
Version 1.00:    Added connectivity check, download concurrency, driver type filters, installation priority and visual overhaul.

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

    # Driver Type Keyword Mapping & Title Filtering
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

    # Verbose Download Details Output
    $TotalCount = $OrderedUpdates.Count
    $padWidth   = $TotalCount.ToString().Length

    Write-Host "`nPreparing to download $TotalCount driver(s):" -ForegroundColor Cyan
    $DownloadColl = New-Object -ComObject Microsoft.Update.UpdateColl
    
    $dlCounter = 0
    foreach ($upd in $OrderedUpdates) {
        $dlCounter++
        $countStr = $dlCounter.ToString("D$padWidth")
        [void]$DownloadColl.Add($upd)
        
        # Calculate file size in MB
        $sizeMB = [math]::Round($upd.MaxDownloadSize / 1MB, 2)
        $sizeDisplay = if ($sizeMB -gt 0) { "$sizeMB MB" } else { "< 1 MB" }
        
        Write-Host "  [$countStr/$TotalCount] $sizeDisplay - $($upd.Title)" -ForegroundColor Gray
    }

    # Batch Concurrent Background Download Execution
    Write-Host "`nDownloading drivers in parallel..." -ForegroundColor Cyan
    Write-Progress -Activity "Downloading Drivers" -Status "Downloading $TotalCount drivers..." -PercentComplete 50

    $Downloader = $Session.CreateUpdateDownloader()
    $Downloader.Updates = $DownloadColl
    $DownloadResult = $Downloader.Download()

    Write-Progress -Activity "Downloading Drivers" -Completed
    Write-Host "[+] Driver batch download completed.`n" -ForegroundColor Green

    # Live-Updating Console Table Header
    $script:needReboot = $false
    $CurrentIndex = 0

    Write-Host ("{0,-7} {1,-11} {2,-50} {3,-15} {4}" -f "Count", "Status", "Title", "Type", "Reboot Needed") -ForegroundColor Cyan
    Write-Host ("{0,-7} {1,-11} {2,-50} {3,-15} {4}" -f "-----", "------", "-----", "----", "-------------") -ForegroundColor DarkGray

    # Installation Loop
    foreach ($upd in $OrderedUpdates) {
        $CurrentIndex++
        $countStr = $CurrentIndex.ToString("D$padWidth")

        Write-Progress -Activity "Installing Drivers" `
            -Status "[$countStr/$TotalCount] Installing: $($upd.Title)" `
            -PercentComplete (($CurrentIndex / $TotalCount) * 100)

        $InstallColl = New-Object -ComObject Microsoft.Update.UpdateColl
        [void]$InstallColl.Add($upd)

        $Installer = $Session.CreateUpdateInstaller()
        $Installer.Updates = $InstallColl
        $Installer.ForceQuiet = $true

        $InstallResult = $Installer.Install()
        $isSuccess = ($InstallResult.ResultCode -eq 2)
        if ($InstallResult.RebootRequired) { $script:needReboot = $true }

        # Tag Type Classification
        $type = "Other"
        if ($upd.Title -match $chipsetRegex)      { $type = "Chipset" }
        elseif ($upd.Title -match $ClassMap['n']) { $type = "Networking" }
        elseif ($upd.Title -match $ClassMap['v']) { $type = "Video" }
        elseif ($upd.Title -match $ClassMap['s']) { $type = "Sound" }
        elseif ($upd.Title -match $ClassMap['f']) { $type = "Firmware" }
        elseif ($upd.Title -match $ClassMap['t']) { $type = "Touchpad" }

        $titleDisplay = if ($upd.Title.Length -gt 47) { $upd.Title.Substring(0, 44) + "..." } else { $upd.Title }
        $rebootNeededStr = if ($InstallResult.RebootRequired) { "Yes" } else { "No" }

        # Stream formatted row live as each installation completes
        Write-Host ("{0,-7} " -f $countStr) -NoNewline
        if ($isSuccess) {
            Write-Host ("{0,-11} " -f "[SUCCESS]") -ForegroundColor Green -NoNewline
        } else {
            Write-Host ("{0,-11} " -f "[FAILED]") -ForegroundColor Red -NoNewline
        }
        Write-Host ("{0,-50} {1,-15} {2}" -f $titleDisplay, $type, $rebootNeededStr)
    }

    Write-Progress -Activity "Installing Drivers" -Completed
    Write-Host ""

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
