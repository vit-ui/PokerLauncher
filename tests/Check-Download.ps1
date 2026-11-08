param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Local')][string]$Path,
    [Parameter(Mandatory = $true, ParameterSetName = 'Published')][uri]$DownloadUrl,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256,
    [uri]$SourceUrl = 'https://github.com/vit-ui/PokerStarsLauncher/releases/latest/download/PokerLauncher.exe'
)

$ErrorActionPreference = 'Stop'
# Save invokes Windows Attachment Services, used by Chromium downloads for
# antivirus checks and Internet-origin evidence. It never executes the file.
# https://learn.microsoft.com/windows/win32/api/shobjidl_core/nf-shobjidl_core-iattachmentexecute-save
if (-not ('PokerLauncherDownloadCheck' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class PokerLauncherDownloadCheck {
    [ComImport, Guid("73DB1241-1E85-4581-8E4F-A81E1D0F8C57")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAttachmentExecute {
        void SetClientTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetClientGuid(ref Guid guid);
        void SetLocalPath([MarshalAs(UnmanagedType.LPWStr)] string path);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void SetSource([MarshalAs(UnmanagedType.LPWStr)] string source);
        void SetReferrer([MarshalAs(UnmanagedType.LPWStr)] string referrer);
        [PreserveSig] int CheckPolicy();
        void Prompt(IntPtr parent, int prompt, out int action);
        [PreserveSig] int Save();
    }

    public static int Check(string path, string source) {
        var instance = Activator.CreateInstance(Type.GetTypeFromCLSID(
            new Guid("4125DD96-E03A-4103-8F70-E0597D803B9C")));
        try {
            var attachment = (IAttachmentExecute)instance;
            var client = new Guid("C83BC658-82F5-4A1A-A627-B78F33E57148");
            attachment.SetClientGuid(ref client);
            attachment.SetLocalPath(path);
            attachment.SetSource(source);
            attachment.SetReferrer("https://github.com/vit-ui/PokerStarsLauncher/releases");
            return attachment.Save();
        }
        finally { Marshal.FinalReleaseComObject(instance); }
    }
}
'@
}

$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('PokerLauncher-download-check-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$download = Join-Path $testDirectory 'PokerLauncher.exe'
try {
    if ($PSCmdlet.ParameterSetName -eq 'Published') {
        if ($DownloadUrl.Scheme -ne 'https') { throw 'Published download verification requires HTTPS.' }
        $SourceUrl = $DownloadUrl
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $DownloadUrl.AbsoluteUri -OutFile $download
    }
    else {
        Copy-Item -LiteralPath $Path -Destination $download
    }
    if ($SourceUrl.Scheme -ne 'https') { throw 'Download origin must use HTTPS.' }
    if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $ExpectedSha256) {
        throw 'The downloaded executable does not match the expected release checksum.'
    }

    $result = [PokerLauncherDownloadCheck]::Check($download, $SourceUrl.AbsoluteUri)
    Write-Host ('Windows Attachment Services Save HRESULT: 0x{0:X8}' -f $result)
    if ($result -ne 0) { throw 'Windows Attachment Services rejected or could not validate the download.' }
    if (-not (Test-Path -LiteralPath $download -PathType Leaf) -or
        (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $ExpectedSha256) {
        throw 'Windows download scanning removed or changed the release executable.'
    }
    $zone = @(Get-Content -LiteralPath $download -Stream Zone.Identifier)
    if ($zone -notcontains 'ZoneId=3') { throw 'Windows did not attach Internet-origin metadata to the download.' }
    $status = Get-MpComputerStatus
    Write-Host "Download verification passed with Defender signatures $($status.AntivirusSignatureVersion). SHA256: $ExpectedSha256"
}
catch {
    # Keep the actual antivirus verdict in the workflow log when a live scan
    # blocks the file before hashing or Attachment Services can finish.
    try {
        $detections = @(Get-MpThreatDetection | Where-Object { ($_.Resources -join ' ') -like "*$testDirectory*" })
        $ids = @($detections | Select-Object -ExpandProperty ThreatID -Unique)
        Get-MpThreat | Where-Object { $ids -contains $_.ThreatID } |
            Select-Object ThreatName, ThreatID, IsActive | Format-List | Out-String | Write-Host
    }
    catch { Write-Warning "Could not read Defender detection details: $_" }
    throw
}
finally { Remove-Item -LiteralPath $testDirectory -Recurse -Force }
