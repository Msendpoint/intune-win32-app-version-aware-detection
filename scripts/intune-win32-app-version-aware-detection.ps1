<#
.SYNOPSIS
    Validates Intune Win32 app registry detection rules to prevent endless reinstall loops.

.DESCRIPTION
    This script addresses the common Intune Win32 app issue where auto-updating software causes
    an endless reinstall loop due to exact-version detection rules. Instead of checking for an
    exact version (which breaks when the app self-updates), this script:

      - Queries the local registry for an installed application's DisplayVersion
      - Compares the installed version against a minimum required version
      - Returns exit code 0 (detected) if installed version >= minimum version
      - Returns exit code 1 (not detected) if the app is missing or below minimum version

    This script is designed to be used as a Custom Script detection rule inside an Intune
    Win32 app deployment. It replaces brittle 'Equals' version checks with a safe
    'Greater Than or Equal To' comparison that survives auto-updates.

    Supported scenarios:
      - Google Chrome, Zoom, Teams Machine-Wide Installer, VPN clients, security agents
      - Any Win32 app that self-updates outside of Intune control

.NOTES
    Author:      Souhaiel Morhag
    Company:     MSEndpoint.com
    Blog:        https://msendpoint.com
    Academy:     https://app.msendpoint.com/academy
    LinkedIn:    https://linkedin.com/in/souhaiel-morhag
    GitHub:      https://github.com/Msendpoint
    License:     MIT

.EXAMPLE
    # Run locally to test detection for an app with a known GUID and minimum version:
    .\Invoke-Win32AppDetection.ps1 -AppGuid '{12345678-1234-1234-1234-123456789012}' -MinimumVersion '1.5.3.2501222'

.EXAMPLE
    # Use as Intune custom script detection (no parameters needed if values are hardcoded):
    # Deploy this script as the Detection Rule for a Win32 app in Intune.
    # Intune interprets exit code 0 as Detected, any other code as Not Detected.
    .\Invoke-Win32AppDetection.ps1
#>

[CmdletBinding()]
param (
    # The GUID of the application as found in the Uninstall registry key.
    # Example: '{12345678-1234-1234-1234-123456789012}'
    # Leave blank to use the hardcoded default below (recommended for Intune deployment).
    [Parameter(Mandatory = $false)]
    [string]$AppGuid = '{YOUR-APP-GUID-HERE}',

    # The minimum acceptable version of the application.
    # Detection passes if installed version >= this value.
    [Parameter(Mandatory = $false)]
    [string]$MinimumVersion = '1.5.3.2501222'
)

#region --- Configuration ---

# Registry paths to check (covers both 32-bit and 64-bit app registrations)
$RegistryPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$AppGuid",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$AppGuid"
)

#endregion

#region --- Helper Functions ---

function Get-InstalledVersion {
    <#
    .SYNOPSIS
        Retrieves the DisplayVersion value from the Uninstall registry key for a given app GUID.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$RegistryPaths
    )

    foreach ($path in $RegistryPaths) {
        if (Test-Path -Path $path) {
            try {
                $regItem = Get-ItemProperty -Path $path -ErrorAction Stop
                if ($regItem.DisplayVersion) {
                    Write-Verbose "Found DisplayVersion '$($regItem.DisplayVersion)' at path: $path"
                    return $regItem.DisplayVersion
                }
            }
            catch {
                Write-Verbose "Could not read registry path '$path': $_"
            }
        }
    }

    # App not found in any registry path
    return $null
}

function Compare-AppVersion {
    <#
    .SYNOPSIS
        Compares two version strings and returns true if InstalledVersion >= MinimumVersion.
    .DESCRIPTION
        Uses [System.Version] for accurate multi-part version comparison.
        Falls back gracefully if version strings cannot be parsed.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$InstalledVersion,

        [Parameter(Mandatory = $true)]
        [string]$MinimumVersion
    )

    try {
        $installed = [System.Version]$InstalledVersion
        $minimum   = [System.Version]$MinimumVersion

        Write-Verbose "Comparing installed version [$installed] >= minimum version [$minimum]"
        return ($installed -ge $minimum)
    }
    catch {
        Write-Warning "Version comparison failed. InstalledVersion='$InstalledVersion', MinimumVersion='$MinimumVersion'. Error: $_"
        # If we cannot parse versions, treat as not detected to be safe
        return $false
    }
}

#endregion

#region --- Main Detection Logic ---

try {
    Write-Verbose "Starting Win32 app detection for GUID: $AppGuid"
    Write-Verbose "Minimum required version: $MinimumVersion"

    # Step 1: Attempt to retrieve the installed version from the registry
    $installedVersion = Get-InstalledVersion -RegistryPaths $RegistryPaths

    if ($null -eq $installedVersion) {
        # App is not installed at all — detection fails
        Write-Verbose "Application not found in registry. Reporting as NOT DETECTED."
        exit 1
    }

    Write-Verbose "Installed version detected: $installedVersion"

    # Step 2: Perform version-aware comparison (>= minimum, not == exact)
    # This is the critical fix: auto-updates increment the version, but detection
    # should still pass as long as the installed version meets the minimum bar.
    $isDetected = Compare-AppVersion -InstalledVersion $installedVersion -MinimumVersion $MinimumVersion

    if ($isDetected) {
        # Version meets or exceeds the minimum — report as DETECTED
        Write-Host "DETECTED: Version $installedVersion is >= minimum $MinimumVersion"
        exit 0
    }
    else {
        # Version is below the minimum — report as NOT DETECTED, trigger reinstall
        Write-Host "NOT DETECTED: Version $installedVersion is below minimum $MinimumVersion"
        exit 1
    }
}
catch {
    # Unhandled exception — treat as not detected to avoid false positives
    Write-Warning "Unexpected error during detection: $_"
    exit 1
}

#endregion
