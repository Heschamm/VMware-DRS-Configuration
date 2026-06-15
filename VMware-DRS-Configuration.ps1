$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

Clear-Host

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "VMware DRS and vSAN Cluster Configuration Script" -ForegroundColor Cyan
Write-Host "Scripted and tested by Hesham Awad Hesham.awad@kyndryl.com" -ForegroundColor Cyan
Write-Host "In case of any bug or improvement ideas, kindly reach out." -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking VMware PowerCLI module..." -ForegroundColor Cyan

$powerCliModule = Get-Module -ListAvailable -Name VMware.VimAutomation.Core |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $powerCliModule) {
    Write-Host "ERROR: VMware PowerCLI Core module is not installed." -ForegroundColor Red
    Write-Host "Install it using this command:" -ForegroundColor Yellow
    Write-Host "Install-Module VMware.PowerCLI -Scope CurrentUser -Force" -ForegroundColor Cyan
    return
}

try {
    Write-Host "Loading VMware.VimAutomation.Core version $($powerCliModule.Version)..." -ForegroundColor Cyan
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    Write-Host "PowerCLI module loaded successfully." -ForegroundColor Green
}
catch {
    Write-Host "ERROR: Failed to load VMware.VimAutomation.Core." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}

try {
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
}
catch {
    Write-Host "Warning: Could not update PowerCLI configuration. Continuing..." -ForegroundColor Yellow
}

$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$reportPath = "C:\Temp\DRS_vSAN_Report_$timestamp"

if (-not (Test-Path $reportPath)) {
    New-Item -Path $reportPath -ItemType Directory -Force | Out-Null
}

$transcriptPath = Join-Path $reportPath "Script_Run_Log_$timestamp.txt"

try {
    Start-Transcript -Path $transcriptPath -Force | Out-Null
}
catch {
    Write-Host "Warning: Could not start transcript logging. Continuing..." -ForegroundColor Yellow
}

$viConnection = $null

function Get-ClusterDrsVsanReport {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Clusters
    )

    foreach ($cluster in $Clusters) {
        Write-Host "Reading cluster: $($cluster.Name)" -ForegroundColor DarkCyan

        $clusterView = Get-View -Id $cluster.Id -ErrorAction Stop
        $vsanEnabled = $false

        if (
            $null -ne $clusterView.ConfigurationEx -and
            $null -ne $clusterView.ConfigurationEx.VsanConfigInfo
        ) {
            $vsanEnabled = [bool]$clusterView.ConfigurationEx.VsanConfigInfo.Enabled
        }

        if (-not $cluster.DrsEnabled) {
            $drsCategory = "DRS OFF"
        }
        elseif ($cluster.DrsAutomationLevel -eq "Manual") {
            $drsCategory = "DRS Manual"
        }
        elseif ($cluster.DrsAutomationLevel -eq "PartiallyAutomated") {
            $drsCategory = "DRS Partially Automated"
        }
        elseif ($cluster.DrsAutomationLevel -eq "FullyAutomated") {
            $drsCategory = "DRS Fully Automated"
        }
        else {
            $drsCategory = "Unknown"
        }

        if ($vsanEnabled) {
            $vsanCategory = "vSAN Enabled"
        }
        else {
            $vsanCategory = "vSAN Disabled"
        }

        [PSCustomObject]@{
            ClusterName                                  = $cluster.Name
            DrsEnabled                                   = $cluster.DrsEnabled
            "DrsAutomationLevel(Current/LastConfigured)" = $cluster.DrsAutomationLevel
            DRSCategory                                  = $drsCategory
            VsanEnabled                                  = $vsanEnabled
            vSANCategory                                 = $vsanCategory
        }
    }
}

function Show-DrsAutomationSummary {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Report
    )

    $partiallyAutomatedCount = @($Report | Where-Object { $_.DRSCategory -eq "DRS Partially Automated" }).Count
    $fullyAutomatedCount     = @($Report | Where-Object { $_.DRSCategory -eq "DRS Fully Automated" }).Count
    $manualCount             = @($Report | Where-Object { $_.DRSCategory -eq "DRS Manual" }).Count
    $drsOffCount             = @($Report | Where-Object { $_.DRSCategory -eq "DRS OFF" }).Count

    @(
        [PSCustomObject]@{
            Name  = "DRS Partially Automated"
            Count = $partiallyAutomatedCount
        }
        [PSCustomObject]@{
            Name  = "DRS Fully Automated"
            Count = $fullyAutomatedCount
        }
        [PSCustomObject]@{
            Name  = "DRS Manual"
            Count = $manualCount
        }
        [PSCustomObject]@{
            Name  = "DRS OFF"
            Count = $drsOffCount
        }
    ) | Format-Table -AutoSize
}

function Show-DrsEnabledSummaryForVsanClusters {
    param (
        [Parameter(Mandatory = $true)]
        [array]$Report
    )

    $drsEnabledCount  = @($Report | Where-Object { $_.DrsEnabled -eq $true }).Count
    $drsDisabledCount = @($Report | Where-Object { $_.DrsEnabled -eq $false }).Count

    @(
        [PSCustomObject]@{
            Name  = "DRS Enabled"
            Count = $drsEnabledCount
        }
        [PSCustomObject]@{
            Name  = "DRS Disabled"
            Count = $drsDisabledCount
        }
    ) | Format-Table -AutoSize
}

function Select-DrsAutomationLevel {
    Write-Host ""
    Write-Host "Choose the DRS automation level:" -ForegroundColor Cyan
    Write-Host "1. Manual"
    Write-Host "2. Partially Automated"
    Write-Host "3. Fully Automated"

    $choice = Read-Host "Enter 1, 2, or 3"

    switch ($choice) {
        "1" {
            return "Manual"
        }
        "2" {
            return "PartiallyAutomated"
        }
        "3" {
            return "FullyAutomated"
        }
        default {
            return $null
        }
    }
}

try {
    $vCenterServer = Read-Host "Enter vCenter FQDN or IP address"

    if ([string]::IsNullOrWhiteSpace($vCenterServer)) {
        Write-Host "ERROR: vCenter Server cannot be empty. Exiting." -ForegroundColor Red
        return
    }

    $credential = Get-Credential -Message "Enter credentials for vCenter: $vCenterServer"

    Write-Host ""
    Write-Host "Connecting to vCenter: $vCenterServer ..." -ForegroundColor Cyan

    $viConnection = Connect-VIServer `
        -Server $vCenterServer `
        -Credential $credential `
        -ErrorAction Stop

    Write-Host "Connected to vCenter: $($viConnection.Name)" -ForegroundColor Green

    $vsanEnabledCsv  = Join-Path $reportPath "vSAN_Enabled_Clusters_$timestamp.csv"
    $vsanDisabledCsv = Join-Path $reportPath "vSAN_Disabled_Clusters_$timestamp.csv"

    Write-Host ""
    Write-Host "Checking visible clusters..." -ForegroundColor Cyan

    $allClusters = @(Get-Cluster -Server $viConnection -ErrorAction Stop | Sort-Object Name)

    Write-Host "Number of visible clusters found: $($allClusters.Count)" -ForegroundColor Yellow

    if ($allClusters.Count -eq 0) {
        Write-Host ""
        Write-Host "No clusters were returned from this vCenter." -ForegroundColor Red
        Write-Host "Possible reasons:" -ForegroundColor Yellow
        Write-Host "1. The user has no permission to view clusters."
        Write-Host "2. You connected to the wrong vCenter."
        Write-Host "3. There are no clusters in the visible inventory scope."
        Write-Host ""
        Write-Host "Log file: $transcriptPath" -ForegroundColor Cyan
        return
    }

    Write-Host ""
    Write-Host "Collecting vSAN status for all visible clusters..." -ForegroundColor Cyan

    $allClusterReport = @(Get-ClusterDrsVsanReport -Clusters $allClusters)

    $vsanEnabledClustersReport = @(
        $allClusterReport |
        Where-Object { $_.VsanEnabled -eq $true } |
        Sort-Object ClusterName
    )

    $vsanDisabledClustersReport = @(
        $allClusterReport |
        Where-Object { $_.VsanEnabled -eq $false } |
        Sort-Object ClusterName
    )

    $vsanEnabledClustersReport | Export-Csv -Path $vsanEnabledCsv -NoTypeInformation -Encoding UTF8
    $vsanDisabledClustersReport | Export-Csv -Path $vsanDisabledCsv -NoTypeInformation -Encoding UTF8

    if ($vsanEnabledClustersReport.Count -eq 0) {
        Write-Host ""
        Write-Host "No vSAN-enabled clusters found." -ForegroundColor Red
        Write-Host "No DRS changes can be made because the script scope is vSAN-enabled clusters only." -ForegroundColor Yellow
        Write-Host "vSAN enabled report:    $vsanEnabledCsv"
        Write-Host "vSAN disabled report:   $vsanDisabledCsv"
        Write-Host "Log file:               $transcriptPath"
        return
    }

    $targetClusterNames = @($vsanEnabledClustersReport | Select-Object -ExpandProperty ClusterName)

    $targetClusters = @(
        $allClusters |
        Where-Object { $targetClusterNames -contains $_.Name } |
        Sort-Object Name
    )

    Write-Host ""
    Write-Host "vSAN-enabled clusters in scope:" -ForegroundColor Cyan
    $targetClusters | Select-Object Name | Format-Table -AutoSize

    Write-Host ""
    Write-Host "Collecting DRS and vSAN status BEFORE action for vSAN-enabled clusters..." -ForegroundColor Cyan

    $beforeReport = @(Get-ClusterDrsVsanReport -Clusters $targetClusters)

    Write-Host ""
    Write-Host "DRS summary BEFORE:" -ForegroundColor Cyan
    Show-DrsAutomationSummary -Report $beforeReport

    Write-Host ""
    Write-Host "Current DRS for vSAN Cluster(s) summary:" -ForegroundColor Cyan
    Show-DrsEnabledSummaryForVsanClusters -Report $beforeReport

    $drsOffClusters = @(
        $targetClusters |
        Where-Object { $_.DrsEnabled -eq $false } |
        Sort-Object Name
    )

    $drsOnClusters = @(
        $targetClusters |
        Where-Object { $_.DrsEnabled -eq $true } |
        Sort-Object Name
    )

    Write-Host ""
    Write-Host "DRS-disabled vSAN cluster count: $($drsOffClusters.Count)" -ForegroundColor Yellow
    Write-Host "DRS-enabled vSAN cluster count:  $($drsOnClusters.Count)" -ForegroundColor Yellow

    if ($drsOffClusters.Count -gt 0) {
        Write-Host ""
        Write-Host "DRS-disabled vSAN clusters:" -ForegroundColor Yellow
        $drsOffClusters |
            Select-Object `
                Name,
                DrsEnabled,
                @{Name = "DrsAutomationLevel(Current/LastConfigured)"; Expression = { $_.DrsAutomationLevel }} |
            Format-Table -AutoSize
    }
    else {
        Write-Host ""
        Write-Host "No DRS-disabled vSAN clusters found." -ForegroundColor Yellow
    }

    if ($drsOnClusters.Count -gt 0) {
        Write-Host ""
        Write-Host "DRS-enabled vSAN clusters:" -ForegroundColor Green
        $drsOnClusters |
            Select-Object `
                Name,
                DrsEnabled,
                @{Name = "DrsAutomationLevel(Current/LastConfigured)"; Expression = { $_.DrsAutomationLevel }} |
            Format-Table -AutoSize
    }
    else {
        Write-Host ""
        Write-Host "No DRS-enabled vSAN clusters found." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Choose the action to perform:" -ForegroundColor Cyan
    Write-Host "1. Enable DRS on all DRS-disabled vSAN clusters"
    Write-Host "2. Disable DRS on all DRS-enabled vSAN clusters"
    Write-Host "3. Change DRS automation level on all DRS-enabled vSAN clusters"
    Write-Host "4. Report only - no changes"

    $actionChoice = Read-Host "Enter 1, 2, 3, or 4"
    $changeResults = @()

    switch ($actionChoice) {
        "1" {
            if ($drsOffClusters.Count -eq 0) {
                Write-Host ""
                Write-Host "No DRS-disabled vSAN clusters found. Nothing to enable." -ForegroundColor Yellow
                break
            }

            $selectedAutomationLevel = Select-DrsAutomationLevel

            if (-not $selectedAutomationLevel) {
                Write-Host ""
                Write-Host "Invalid automation level selection. No changes made." -ForegroundColor Red
                break
            }

            Write-Host ""
            Write-Host "Selected DRS automation level: $selectedAutomationLevel" -ForegroundColor Yellow

            $finalConfirm = Read-Host "This will enable DRS on $($drsOffClusters.Count) vSAN cluster(s). Type YES to proceed"

            if ($finalConfirm -ne "YES") {
                Write-Host ""
                Write-Host "No changes made." -ForegroundColor Yellow
                break
            }

            Write-Host ""
            Write-Host "Applying DRS enable configuration..." -ForegroundColor Cyan

            $changeResults = foreach ($cluster in $drsOffClusters) {
                try {
                    Write-Host "Enabling DRS on cluster: $($cluster.Name)" -ForegroundColor Cyan

                    Set-Cluster `
                        -Cluster $cluster `
                        -DrsEnabled:$true `
                        -DrsAutomationLevel $selectedAutomationLevel `
                        -Confirm:$false `
                        -ErrorAction Stop | Out-Null

                    [PSCustomObject]@{
                        Cluster             = $cluster.Name
                        Action              = "Enable DRS"
                        ChangeStatus        = "Success"
                        Before_DrsEnabled   = $false
                        RequestedDRSState   = "Enabled"
                        RequestedAutomation = $selectedAutomationLevel
                        ErrorMessage        = ""
                    }
                }
                catch {
                    [PSCustomObject]@{
                        Cluster             = $cluster.Name
                        Action              = "Enable DRS"
                        ChangeStatus        = "Failed"
                        Before_DrsEnabled   = $false
                        RequestedDRSState   = "Enabled"
                        RequestedAutomation = $selectedAutomationLevel
                        ErrorMessage        = $_.Exception.Message
                    }
                }
            }
        }

        "2" {
            if ($drsOnClusters.Count -eq 0) {
                Write-Host ""
                Write-Host "No DRS-enabled vSAN clusters found. Nothing to disable." -ForegroundColor Yellow
                break
            }

            $finalConfirm = Read-Host "This will DISABLE DRS on $($drsOnClusters.Count) vSAN cluster(s). Type YES to proceed"

            if ($finalConfirm -ne "YES") {
                Write-Host ""
                Write-Host "No changes made." -ForegroundColor Yellow
                break
            }

            Write-Host ""
            Write-Host "Applying DRS disable configuration..." -ForegroundColor Cyan

            $changeResults = foreach ($cluster in $drsOnClusters) {
                try {
                    Write-Host "Disabling DRS on cluster: $($cluster.Name)" -ForegroundColor Cyan

                    Set-Cluster `
                        -Cluster $cluster `
                        -DrsEnabled:$false `
                        -Confirm:$false `
                        -ErrorAction Stop | Out-Null

                    [PSCustomObject]@{
                        Cluster             = $cluster.Name
                        Action              = "Disable DRS"
                        ChangeStatus        = "Success"
                        Before_DrsEnabled   = $true
                        RequestedDRSState   = "Disabled"
                        RequestedAutomation = "N/A"
                        ErrorMessage        = ""
                    }
                }
                catch {
                    [PSCustomObject]@{
                        Cluster             = $cluster.Name
                        Action              = "Disable DRS"
                        ChangeStatus        = "Failed"
                        Before_DrsEnabled   = $true
                        RequestedDRSState   = "Disabled"
                        RequestedAutomation = "N/A"
                        ErrorMessage        = $_.Exception.Message
                    }
                }
            }
        }

        "3" {
            if ($drsOnClusters.Count -eq 0) {
                Write-Host ""
                Write-Host "No DRS-enabled vSAN clusters found. Nothing to change." -ForegroundColor Yellow
                break
            }

            $selectedAutomationLevel = Select-DrsAutomationLevel

            if (-not $selectedAutomationLevel) {
                Write-Host ""
                Write-Host "Invalid automation level selection. No changes made." -ForegroundColor Red
                break
            }

            Write-Host ""
            Write-Host "Selected DRS automation level: $selectedAutomationLevel" -ForegroundColor Yellow

            $finalConfirm = Read-Host "This will change the DRS automation level on $($drsOnClusters.Count) DRS-enabled vSAN cluster(s). Type YES to proceed"

            if ($finalConfirm -ne "YES") {
                Write-Host ""
                Write-Host "No changes made." -ForegroundColor Yellow
                break
            }

            Write-Host ""
            Write-Host "Applying DRS automation level change..." -ForegroundColor Cyan

            $changeResults = foreach ($cluster in $drsOnClusters) {
                try {
                    Write-Host "Changing DRS automation level on cluster: $($cluster.Name)" -ForegroundColor Cyan

                    Set-Cluster `
                        -Cluster $cluster `
                        -DrsEnabled:$true `
                        -DrsAutomationLevel $selectedAutomationLevel `
                        -Confirm:$false `
                        -ErrorAction Stop | Out-Null

                    [PSCustomObject]@{
                        Cluster             = $cluster.Name
                        Action              = "Change DRS Automation Level"
                        ChangeStatus        = "Success"
                        Before_DrsEnabled   = $true
                        RequestedDRSState   = "Enabled"
                        RequestedAutomation = $selectedAutomationLevel
                        ErrorMessage        = ""
                    }
                }
                catch {
                    [PSCustomObject]@{
                        Cluster             = $cluster.Name
                        Action              = "Change DRS Automation Level"
                        ChangeStatus        = "Failed"
                        Before_DrsEnabled   = $true
                        RequestedDRSState   = "Enabled"
                        RequestedAutomation = $selectedAutomationLevel
                        ErrorMessage        = $_.Exception.Message
                    }
                }
            }
        }

        "4" {
            Write-Host ""
            Write-Host "Report only selected. No changes will be made." -ForegroundColor Yellow
        }

        default {
            Write-Host ""
            Write-Host "Invalid action selection. No changes made." -ForegroundColor Red
        }
    }

    if ($changeResults.Count -gt 0) {
        Write-Host ""
        Write-Host "Change results:" -ForegroundColor Cyan
        $changeResults | Format-Table -AutoSize
    }

    $allClustersAfter = @(Get-Cluster -Server $viConnection -ErrorAction Stop | Sort-Object Name)

    $targetClustersAfter = @(
        $allClustersAfter |
        Where-Object { $targetClusterNames -contains $_.Name } |
        Sort-Object Name
    )

    Write-Host ""
    Write-Host "Collecting DRS and vSAN status AFTER action for vSAN-enabled clusters..." -ForegroundColor Cyan

    $afterReport = @(Get-ClusterDrsVsanReport -Clusters $targetClustersAfter)

    Write-Host ""
    Write-Host "DRS summary BEFORE:" -ForegroundColor Cyan
    Show-DrsAutomationSummary -Report $beforeReport

    Write-Host ""
    Write-Host "DRS summary AFTER:" -ForegroundColor Cyan
    Show-DrsAutomationSummary -Report $afterReport

    Write-Host ""
    Write-Host "Current DRS for vSAN Cluster(s) summary:" -ForegroundColor Cyan
    Show-DrsEnabledSummaryForVsanClusters -Report $afterReport

    Write-Host ""
    Write-Host "Reports exported successfully:" -ForegroundColor Green
    Write-Host "vSAN enabled report:    $vsanEnabledCsv"
    Write-Host "vSAN disabled report:   $vsanDisabledCsv"
    Write-Host "Log file:               $transcriptPath"
    Write-Host ""
    Write-Host "Completed." -ForegroundColor Green
}
catch {
    Write-Host ""
    Write-Host "SCRIPT FAILED:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red

    if ($_.ScriptStackTrace) {
        Write-Host ""
        Write-Host "Stack trace:" -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace
    }

    Write-Host ""
    Write-Host "Log file: $transcriptPath" -ForegroundColor Cyan
}
finally {
    if ($viConnection) {
        Write-Host ""
        Write-Host "Disconnecting from vCenter: $($viConnection.Name) ..." -ForegroundColor Cyan
        Disconnect-VIServer -Server $viConnection -Confirm:$false | Out-Null
        Write-Host "Disconnected." -ForegroundColor Green
    }

    try {
        Stop-Transcript | Out-Null
    }
    catch {
    }
}
