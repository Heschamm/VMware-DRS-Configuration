# VMware-DRS-Configuration PowerCLI Script

# VMware DRS and vSAN Cluster Script

## Purpose
This PowerCLI script connects to a vCenter, checks vSAN-enabled clusters, reports their DRS status, and allows you to:

1. Enable DRS on DRS-disabled vSAN clusters
2. Disable DRS on DRS-enabled vSAN clusters
3. Change the DRS automation level on DRS-enabled vSAN clusters
4. Run report-only mode with no changes

## Scope
The script works only on **vSAN-enabled clusters**. Non-vSAN clusters are detected and exported, but no DRS changes are applied to them.

## Requirements
- Windows PowerShell
- VMware PowerCLI installed
- vCenter credentials with permission to read and modify cluster settings

Install PowerCLI if needed:

```powershell
Install-Module VMware.PowerCLI -Scope CurrentUser -Force
```

## How to Run
Open PowerShell and run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\VMware-DRS-vSAN-Script.ps1
```

The script will ask for:

- vCenter FQDN or IP
- vCenter credentials
- Action to perform
- DRS automation level, when required

## Output Files
Reports are saved under:

```text
C:\Temp\DRS_vSAN_Report_<timestamp>
```

The script creates:

- vSAN enabled clusters report
- vSAN disabled clusters report
- Script run log

## Notes
When DRS is disabled, the displayed automation level is the current or last configured value only.

Scripted and tested by Hesham Awad Hesham.awad@kyndryl.com.  
In case of any bug or improvement ideas, kindly reach out.
