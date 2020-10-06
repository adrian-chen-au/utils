<#
.Synopsis
    For reporting on all dashboards in a specific Dynatrace Tenant

.Description
    Very simple script to pull back information about the Dashboards created in a dynatrace tenant.

    Possible Extensions: 
        - Additional processing of the dashboard contents
        - Exporting all or specific dashboards to disk
        - Support being piped into
        - reducing the number of api requests this script performs (not currently possible)

.Notes
    Author: Michael Ball
    Version: 1.1.1 - 20200729

    ChangeLog
        1.1.1
            Updated script with examples
        1.1.0
            Updated script to work with the new scaffolding
        1.0.0
            MVP - Things work - basic script
        
.Example  
    pwsh>./get-tenantDashboard.ps1 |format-table
    Cluster Version Check: https://abc12345.live.dynatrace.com/api/v1/config/clusterversion
    Token Permissions Check: https://abc12345.live.dynatrace.com/api/v1/tokens/lookup
    Get list of Dashboards: https://abc12345.live.dynatrace.com/api/config/v1/dashboards

    Owner                          Name                       Shared SharedViaLink Published ManagementZone NumberOfTiles DefaultTimeFrame ManagementZoneID
    -----                          ----                       ------ ------------- --------- -------------- ------------- ---------------- -------------
    admin                          SableDefault                 True         False      True                           13
    User1@dynatrace.com            Home                        False          True     False                           14
    User2@dynatrace.com            Home                        False          True     False                           14
    User3@dynatrace.com            Home                        False          True     False                           14
    User4@dynatrace.com            Home                        False          True     False                           14
    User5@dynatrace.com            Home                        False         False     False                           14
    User6@dynatrace.com            Home                        False         False     False                           14
    michael.ball@dynatrace.com     Default Dashboard Template  False         False      True                           13
    michael.ball@dynatrace.com     Home                         True          True     False                           10 l_2_HOURS
    michael.ball@dynatrace.com     NAM                         False          True     False                            7 l_2_HOURS
    michael.ball@dynatrace.com     Prestashop                   True         False     False Prestashop                18 l_2_HOURS        -640416780...
    User7@dynatrace.com            Home                        False         False     False                           14
    User8@dynatrace.com            Home                        False         False     False                           14
    User9@dynatrace.com            Home                        False          True     False                           14
    User0@dynatrace.com            Fred's Dashboard            False         False     False                            3 l_72_HOURS
    

#>

[CmdletBinding(DefaultParametersetName = "default")]
PARAM (
    # The cluster or tenant the HU report should be fetched from
    [Parameter()][ValidateNotNullOrEmpty()] $dtenv = $env:dtenv,
    # Token must have Smartscape Read access for a tenant
    [Alias('dttoken')][ValidateNotNullOrEmpty()][string] $token = $env:dttoken,

    # Show a subset of information collected
    [Alias('summary')][switch]$short,
    # Path to output a csv representation of the fetched data.
    [string] $outfile,
    
    # Prints Help output
    [Alias('h')][switch] $help,
    # use this switch to tell this script to not check token or cluster viability
    [switch] $noCheckCompatibility,
    # use this switch to tell powershell to ignore ssl concerns
    [switch] $noCheckCertificate,

    # DO NOT USE - This is set by Script Author
    [String[]]$script:tokenPermissionRequirements = @('DataExport', 'ReadConfig')
)

# Help flag checks
if ($h -or $help) {
    Get-Help $script:MyInvocation.MyCommand.Path -Detailed
    exit 0
}

# Ensure that dtenv and token are both populated
if (!$script:dtenv) {
    return Write-Error "dtenv was not populated - unable to continue"
    
}
elseif (!$script:token) {
    return Write-Error "token/dttoken was not populated - unable to continue"
    
}

# Try to 'fix' a missing https:// in the env
if ($script:dtenv -notlike "https://*" -and $script:dtenv -notlike "http://*") {
    Write-Host -ForegroundColor DarkYellow -Object "WARN: Environment URI was missing 'httpx://' prefix"
    $script:dtenv = "https://$script:dtenv"
    Write-host -ForegroundColor Cyan "New environment URL: $script:dtenv"
}

# Try to 'fix' a trailing '/'
if ($script:dtenv[$script:dtenv.Length - 1] -eq '/') { 
    $script:dtenv = $script:dtenv.Substring(0, $script:dtenv.Length - 1) 
    write-host -ForegroundColor DarkYellow -Object "WARNING: Removed trailing '/' from dtenv input"
}

$baseURL = "$script:dtenv/api/v1"

# Setup Network settings to work from less new setups
if ($nocheckcertificate) {
    # SSL and other compatability settings
    function Disable-SslVerification {
        if (-not ([System.Management.Automation.PSTypeName]"TrustEverything").Type) {
            Add-Type -TypeDefinition  @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustEverything
{
    private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain,
    SslPolicyErrors sslPolicyErrors) { return true; }
    public static void SetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
    public static void UnsetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; } } 
"@
        }
        [TrustEverything]::SetCallback()
    }
    function Enable-SslVerification {
        if (([System.Management.Automation.PSTypeName]"TrustEverything").Type) {
            [TrustEverything]::UnsetCallback()
        }
    }
    Disable-SslVerification   
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocoltype]::Tls12 

# Construct the headers for this API request 
$headers = @{
    Authorization  = "Api-Token $script:token";
    Accept         = "application/json; charset=utf-8";
    "Content-Type" = "application/json; charset=utf-8"
}

function confirm-supportedClusterVersion ($minimumVersion = 176, $logmsg = '') {
    # Environment version check - cancel out if too old 
    $uri = "$baseURL/config/clusterversion"
    Write-Host -ForegroundColor cyan -Object "Cluster Version Check$logmsg`: GET $uri"
    $res = Invoke-RestMethod -Method GET -Headers $headers -Uri $uri 
    $envVersion = $res.version -split '\.'
    if ($envVersion -and (([int]$envVersion[0]) -ne 1 -or ([int]$envVersion[1]) -lt $minimumVersion)) {
        Write-Error "Failed Environment version check - Expected: > 1.$minimumVersion - Got: $($res.version)"
        exit
    }
}

function confirm-requiredTokenPerms ($token, $requirePerms, $logmsg = '') {
    # Token has required Perms Check - cancel out if it doesn't have what's required
    $uri = "$baseURL/tokens/lookup"
    $headers = @{
        Authorization  = "Api-Token $token";
        Accept         = "application/json; charset=utf-8";
        "Content-Type" = "application/json; charset=utf-8"
    }
    Write-Host -ForegroundColor cyan -Object "Token Permissions Check$logmsg`: POST $uri"
    $res = Invoke-RestMethod -Method POST -Headers $headers -Uri $uri -body "{ `"token`": `"$token`"}"
    if (($requirePerms | Where-Object { $_ -notin $res.scopes }).count) {
        Write-Error "Failed Token Permission check. Token requires: $($requirePerms -join ',')"
        write-host "Token provided only had: $($res.scopes -join ',')"
        exit
    }
}

if (!$noCheckCompatibility) {
    <#
        Determine what type environment we have? This script will only work on tenants 
        
        SaaS tenant = https://*.live.dynatrace.com
        Managed tenant = https://*/e/UUID
        Managed Cluster = https://*
    #>
    $envType = 'cluster'
    if ($script:dtenv -like "*.live.dynatrace.com") {
        $envType = 'env'
    }
    elseif ($script:dtenv -like "http*://*/e/*") {
        $envType = 'env'
    }

    # Script won't work on a cluster
    if ($envType -eq 'cluster') {
        write-error "'$script:dtenv' looks like an invalid URL (and Clusters are not supported by this script)"
        return
    }
    
    confirm-supportedClusterVersion 176
    confirm-requireTokenPerms $script:token $script:tokenPermissionRequirements
}
function convertTo-jsDate($date) {
    return [Math]::Floor(1000 * (Get-Date ($date) -UFormat %s))
}

$uri = "$script:dtenv/api/config/v1/dashboards"
Write-host -ForegroundColor cyan "Get list of Dashboards: $uri"
if ($PSVersionTable.PSVersion.Major -lt 6) {
    $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers
}
else {
    $response = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -skipcertificatecheck
}

# iterate through the returned data to construct a PWSH Object, output and possibly save it
$data = @()
Foreach ($row in $response.dashboards) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $completeDashboard = Invoke-RestMethod -Method GET -Uri "$uri/$($row.id)" -Headers $headers
    }
    else {
        $completeDashboard = Invoke-RestMethod -Method GET -Uri "$uri/$($row.id)" -Headers $headers -skipcertificatecheck
    }


    $dashboardSummary = New-Object psobject
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "Owner" -Value $completeDashboard.dashboardMetadata.owner
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "Name" -Value $completeDashboard.dashboardMetadata.name
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "Shared" -Value $completeDashboard.dashboardMetadata.shared
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "SharedViaLink" -Value $completeDashboard.dashboardMetadata.sharingDetails.linkShared
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "Published" -Value $completeDashboard.dashboardMetadata.sharingDetails.published
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "ManagementZone" -Value ($completeDashboard.dashboardMetadata.dashboardFilter.managementZone.name, "" -ne $null)[0]
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "NumberOfTiles" -Value $completeDashboard.tiles.count
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "DefaultTimeFrame" -Value $completeDashboard.dashboardMetadata.dashboardFilter.timeframe
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "ManagementZoneID" -Value ($completeDashboard.dashboardMetadata.dashboardFilter.managementZone.id, "" -ne $null)[0]
    $dashboardSummary | Add-Member -MemberType NoteProperty -Name "id" -Value $completeDashboard.id

    $data += $dashboardSummary
    # $rawdata += $completeDashboard
}

# If we need to output to file
if ($script:outfile) {
    if (!(Split-Path $script:outfile | Test-Path -PathType Container)) {
        New-Item -Path (Split-Path $script:outfile) -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
    }
    $outputFile = New-Item -Path $script:outfile -Force
    $data | ConvertTo-Csv -NoTypeInformation | out-file -FilePath $script:outfile
    write-host "Written to csv table to $($outputFile.fullname)" -ForegroundColor Green
}

# Output
if ($short) {
    $data | Select-Object -Property Owner, Name, Shared, Published, ManagementZone | Sort-Object -Property owner, name
}
else {
    $data | Sort-Object -Property owner, name
}
