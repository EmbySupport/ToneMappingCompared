#Requires -Version 5.1
[CmdletBinding()]
param([string]$UserConfigPath)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $PSScriptRoot 'lib\Configuration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'lib\ViewerData.psm1') -Force
$configuration = Get-SuiteConfiguration -RepositoryRoot $repositoryRoot -UserConfigPath $UserConfigPath
$catalog = Read-SuiteJson -Path (Join-Path $repositoryRoot 'config\catalog.json')
$media = Read-SuiteJson -Path (Join-Path $repositoryRoot 'config\media.json')
$destination = Export-SuiteViewerData -RepositoryRoot $repositoryRoot -Configuration $configuration -Catalog $catalog -Media $media
Write-Host ("Exported viewer data: $destination")
