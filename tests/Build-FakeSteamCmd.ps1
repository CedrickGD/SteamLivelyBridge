param([Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
# Use the Windows .NET Framework compiler so the same native fixture runs under PS 5.1 and 7.
Add-Type -Path (Join-Path $PSScriptRoot 'FakeSteamCmd.cs') -OutputAssembly $OutputPath -OutputType ConsoleApplication
