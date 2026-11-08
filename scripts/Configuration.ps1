# Shared, side-effect-free configuration model. Loading never starts applications.
function New-ProgramEntry {
    param([string]$Name, [string]$Path, [string]$ApplicationPath = '')
    [pscustomobject]@{ Name = $Name; Path = $Path; ApplicationPath = $ApplicationPath; Arguments = ''; WorkingDirectory = '' }
}
function Convert-LauncherConfiguration {
    param($Config)
    if ($null -eq $Config) {
        return [pscustomobject]@{ SchemaVersion = 2; Integration = 'PokerStars'; PokerClient = (New-ProgramEntry 'PokerStars' ''); Helpers = @(); LoginMode = 'Manual'; PokerStarsUsername = '' }
    }
    if ($Config.SchemaVersion -eq 1) {
        return [pscustomobject]@{
            SchemaVersion = 2; Integration = 'PokerStars'; LoginMode = 'PokerStars'; PokerStarsUsername = [string]$Config.PokerStarsUsername
            PokerClient = (New-ProgramEntry 'PokerStars' $Config.Applications.PokerStarsUpdater (Join-Path ([IO.Path]::GetDirectoryName($Config.Applications.PokerStarsUpdater)) 'PokerStars.exe'))
            Helpers = @((New-ProgramEntry 'Xeester' $Config.Applications.XeesterUpdater (Join-Path ([IO.Path]::GetDirectoryName($Config.Applications.XeesterUpdater)) 'jre\bin\xeester.exe')), (New-ProgramEntry 'StarsCaption' $Config.Applications.StarsCaption))
        }
    }
    if ($Config.SchemaVersion -ne 2) { throw 'Unsupported configuration schema.' }
    return $Config
}
function Read-LauncherConfiguration {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return (Convert-LauncherConfiguration $null) }
    Convert-LauncherConfiguration (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Write-LauncherConfiguration {
    param($Config, [string]$Path)
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Config | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, ($temporary + ".bak")); Remove-Item -LiteralPath ($temporary + ".bak") -Force }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Resolve-ProgramEntry {
    param($Entry)
    if ($null -eq $Entry -or [string]::IsNullOrWhiteSpace($Entry.Name) -or [string]::IsNullOrWhiteSpace($Entry.Path)) { throw 'Each program needs a name and executable path.' }
    $path = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$Entry.Path).Trim().Trim('"')))
    $actual = if ([string]::IsNullOrWhiteSpace($Entry.ApplicationPath)) { $path } else { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Entry.ApplicationPath)) }
    $directory = if ([string]::IsNullOrWhiteSpace($Entry.WorkingDirectory)) { [IO.Path]::GetDirectoryName($path) } else { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Entry.WorkingDirectory)) }
    if ([string]$Entry.Arguments -match '[\x00\r\n]') { throw 'Launch arguments cannot contain NUL or line breaks.' }
    [pscustomobject]@{ Name = [string]$Entry.Name; Path = $path; ApplicationPath = $actual; Arguments = [string]$Entry.Arguments; WorkingDirectory = $directory }
}
function Assert-WindowsExecutable {
    param([string]$Path)
    if ([IO.Path]::GetExtension($Path) -ine '.exe') { throw "Configured executable must be an EXE: $Path" }
    $stream = [IO.File]::OpenRead($Path)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d) { throw "Invalid Windows executable: $Path" }
        $stream.Position = 60; $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 24)) { throw "Invalid PE header: $Path" }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Invalid PE signature: $Path" }
        $stream.Position = $offset + 22; $flags = $reader.ReadUInt16()
        if (($flags -band 2) -eq 0 -or ($flags -band 0x2000) -ne 0) { throw "Not an application executable: $Path" }
    } finally { $reader.Dispose() }
}
function Assert-ProgramFiles {
    param($Entry, [switch]$PokerStars)
    Assert-WindowsExecutable $Entry.Path
    Assert-WindowsExecutable $Entry.ApplicationPath
    if (-not (Test-Path -LiteralPath $Entry.WorkingDirectory -PathType Container)) { throw "Working directory not found: $($Entry.WorkingDirectory)" }
    if ($PokerStars) {
        foreach ($path in @($Entry.Path, $Entry.ApplicationPath)) {
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
            if (($info.ProductName + ' ' + $info.CompanyName) -notmatch '(?i)pokerstars|rational') { throw 'The selected client is not recognized as PokerStars (version metadata).' }
            if ($info.OriginalFilename -notmatch '^(?i:PokerStars(Update)?\.exe)$') { throw 'Unsupported PokerStars executable identity.' }
        }
        if ([IO.Path]::GetFileName($Entry.ApplicationPath) -ine 'PokerStars.exe' -or [IO.Path]::GetDirectoryName($Entry.Path) -ine [IO.Path]::GetDirectoryName($Entry.ApplicationPath)) { throw 'Select PokerStars.exe beside its PokerStars updater.' }
    }
}
function Assert-LauncherConfiguration {
    param($Config, [switch]$CheckHelpers)
    if ($Config.SchemaVersion -ne 2 -or $Config.Integration -ne 'PokerStars') { throw 'Unsupported configuration or poker client integration.' }
    if ($Config.LoginMode -notin @('Manual', 'PokerStars')) { throw 'Unsupported login mode.' }
    if ($Config.LoginMode -eq 'PokerStars' -and [string]::IsNullOrWhiteSpace($Config.PokerStarsUsername)) { throw 'PokerStars username is missing.' }
    $seen = @{}
    $entries = @($Config.PokerClient) + @($Config.Helpers)
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $entry = Resolve-ProgramEntry $entries[$i]
        if ($seen.ContainsKey($entry.ApplicationPath)) { throw "Duplicate application: $($entry.ApplicationPath)" }
        $seen[$entry.ApplicationPath] = $true
        if ($i -eq 0) { Assert-ProgramFiles $entry -PokerStars }
        elseif ($CheckHelpers) { Assert-ProgramFiles $entry }
    }
}
