param(
    [string]$RunStartedUtc = '',
    [string]$JobName = '',
    [string]$PokerStarsPath = ''
)

# PokerStars login helper using the native Edit controls discovered on this PC.
# Windows PowerShell 5.1; no external tools required.
# Does not use mouse coordinates, Tab navigation, SendKeys, or the clipboard.
# Polls through connection/loading dialogs until the real login form and its
# native Login button remain stable. Verifies both fields, then sends the
# experimentally confirmed parent WM_COMMAND / BN_CLICKED notification.

$ErrorActionPreference = 'Stop'

# Read the configured username and DPAPI password from the current Windows profile.
$configFile = Join-Path $env:APPDATA 'PokerLauncher\config.json'
$passwordFile = Join-Path $env:APPDATA 'PokerLauncher\password.dpapi'
$logDirectory = Join-Path $env:LOCALAPPDATA 'PokerLauncher\logs'
$logFile = Join-Path $logDirectory 'login.log'
$errorFile = Join-Path $logDirectory 'login-error.txt'
$loginFormTimeoutSeconds = 180
$postSubmitTimeoutSeconds = 30
$scriptVersion = '1.0.0-native-login-wmcommand'
$runStartedUtcParsed = [DateTime]::MinValue
$launcherJob = [IntPtr]::Zero

$stage = 'initialization'
$exitCode = 0
$securePassword = $null
$passwordBstr = [IntPtr]::Zero
$usernameHwnd = [IntPtr]::Zero
$passwordHwnd = [IntPtr]::Zero
$dialogHandle = [IntPtr]::Zero
$loginButtonHwnd = [IntPtr]::Zero
$nativeTypeLoaded = [bool]('PokerStarsNativeLoginButtonV2' -as [type])

function Write-LoginLog {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
}
Remove-Item -LiteralPath $logFile, $errorFile -Force -ErrorAction SilentlyContinue
Write-LoginLog "Run started. Script version: $scriptVersion."
Write-LoginLog ("Configuration: login-form detection timeout = {0} seconds ({1} minutes); post-submit dialog timeout = {2} seconds." -f $loginFormTimeoutSeconds, ($loginFormTimeoutSeconds / 60), $postSubmitTimeoutSeconds)
Write-LoginLog 'Submission target: parent dialog WM_COMMAND with BN_CLICKED, control ID 16382, and the identified Login button HWND in LPARAM.'

try {
    if (-not [string]::IsNullOrWhiteSpace($JobName)) {
        . (Join-Path $PSScriptRoot 'ProcessJob.ps1')
        $launcherJob = [PokerLauncherProcessJob]::OpenForQuery($JobName)
    }
    if (-not [string]::IsNullOrWhiteSpace($RunStartedUtc)) {
        $runStartedUtcParsed = [DateTime]::Parse(
            $RunStartedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
    }

    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw "Configuration file not found: $configFile. Run PokerLauncher setup from the Start Menu first."
    }
    $config = Get-Content -LiteralPath $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $username = [string]$config.PokerStarsUsername
    if ([string]::IsNullOrWhiteSpace($username)) {
        throw 'PokerStars username is missing from the local configuration. Run Configure PokerLauncher from the Start Menu again.'
    }

    if (-not (Test-Path -LiteralPath $passwordFile -PathType Leaf)) {
        throw "Encrypted password file not found: $passwordFile"
    }

    $stage = 'loading native Windows functions'
    if (-not ('PokerStarsNativeLoginButtonV2' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public sealed class PokerStarsEditInfoButtonV2 {
    public IntPtr Handle;
    public int Style;
    public uint ProcessId;
    public bool Visible;
    public bool Enabled;
    public bool IsPassword { get { return (Style & 0x0020) != 0; } }
}

public sealed class PokerStarsLoginButtonInfoV2 {
    public IntPtr Handle;
    public int ControlId;
    public uint ProcessId;
    public bool Visible;
    public bool Enabled;
}

public static class PokerStarsNativeLoginButtonV2 {
    private const uint GW_OWNER = 4;
    private const int GWL_STYLE = -16;
    private const uint WM_SETTEXT = 0x000C;
    private const uint WM_GETTEXT = 0x000D;
    private const uint WM_GETTEXTLENGTH = 0x000E;
    private const uint EM_GETPASSWORDCHAR = 0x00D2;
    private const uint WM_COMMAND = 0x0111;
    private const uint BN_CLICKED = 0;
    private const int LOGIN_BUTTON_CONTROL_ID = 16382;
    private const string LOGIN_BUTTON_CLASS = "FlutterOnlinePokerButtonClass";
    private const uint SMTO_ABORTIFHUNG = 0x0002;
    private const uint SMTO_ERRORONEXIT = 0x0020;
    private const uint MESSAGE_FLAGS = SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT;
    private const uint MESSAGE_TIMEOUT_MS = 3000;

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsWindowEnabled(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr hWnd, uint command);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetClassNameW(IntPtr hWnd, StringBuilder className, int maxCount);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW", SetLastError = true)]
    private static extern int GetWindowLongStyle(IntPtr hWnd, int index);

    [DllImport("user32.dll")]
    private static extern int GetDlgCtrlID(IntPtr hWnd);

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutPointer(
        IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam,
        uint flags, uint timeout, out IntPtr result);

    [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutBuffer(
        IntPtr hWnd, uint message, IntPtr wParam, StringBuilder lParam,
        uint flags, uint timeout, out IntPtr result);


    private static string LastErrorText() {
        int code = Marshal.GetLastWin32Error();
        if (code == 5) return "Access denied by Windows UIPI. Run this helper at the same or higher integrity level as PokerStars.";
        if (code == 0) return "Windows returned no extended error code.";
        return new System.ComponentModel.Win32Exception(code).Message + " (Win32 " + code + ")";
    }

    private static string ClassNameOf(IntPtr hWnd) {
        StringBuilder name = new StringBuilder(256);
        GetClassNameW(hWnd, name, name.Capacity);
        return name.ToString();
    }

    // The observed login dialog is a visible top-level #32770 window owned by
    // the PokerStars Lobby. The Lobby itself is deliberately not accepted.
    public static IntPtr[] FindOwnedLoginDialogs(IntPtr lobby, uint targetPid) {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hWnd, IntPtr ignored) {
            if (!IsWindowVisible(hWnd)) return true;
            if (GetWindow(hWnd, GW_OWNER) != lobby) return true;

            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid != targetPid) return true;
            if (ClassNameOf(hWnd) != "#32770") return true;

            found.Add(hWnd);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // Return direct child Edit controls only. The supplied diagnostic showed
    // exactly two: one without ES_PASSWORD and one with ES_PASSWORD.
    public static PokerStarsEditInfoButtonV2[] FindDirectEditChildren(IntPtr dialog, uint targetPid) {
        List<PokerStarsEditInfoButtonV2> found = new List<PokerStarsEditInfoButtonV2>();
        EnumChildWindows(dialog, delegate(IntPtr hWnd, IntPtr ignored) {
            if (GetParent(hWnd) != dialog) return true;
            if (ClassNameOf(hWnd) != "Edit") return true;

            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid != targetPid) return true;

            PokerStarsEditInfoButtonV2 item = new PokerStarsEditInfoButtonV2();
            item.Handle = hWnd;
            item.Style = GetWindowLongStyle(hWnd, GWL_STYLE);
            item.ProcessId = pid;
            item.Visible = IsWindowVisible(hWnd);
            item.Enabled = IsWindowEnabled(hWnd);
            if (item.Visible && item.Enabled) found.Add(item);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    // Identify the actual Login button using the observed custom Flutter class
    // and stable dialog control ID. The checkbox uses the same class but ID 0.
    public static PokerStarsLoginButtonInfoV2[] FindDirectLoginButtons(IntPtr dialog, uint targetPid) {
        List<PokerStarsLoginButtonInfoV2> found = new List<PokerStarsLoginButtonInfoV2>();
        EnumChildWindows(dialog, delegate(IntPtr hWnd, IntPtr ignored) {
            if (GetParent(hWnd) != dialog) return true;
            if (ClassNameOf(hWnd) != LOGIN_BUTTON_CLASS) return true;
            if (GetDlgCtrlID(hWnd) != LOGIN_BUTTON_CONTROL_ID) return true;

            uint pid;
            GetWindowThreadProcessId(hWnd, out pid);
            if (pid != targetPid) return true;
            if (!IsWindowVisible(hWnd) || !IsWindowEnabled(hWnd)) return true;

            PokerStarsLoginButtonInfoV2 item = new PokerStarsLoginButtonInfoV2();
            item.Handle = hWnd;
            item.ControlId = GetDlgCtrlID(hWnd);
            item.ProcessId = pid;
            item.Visible = true;
            item.Enabled = true;
            found.Add(item);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    private static bool SendSetTextPointer(IntPtr hWnd, IntPtr textPointer, out string error) {
        error = null;
        IntPtr messageResult;
        IntPtr sent = SendMessageTimeoutPointer(
            hWnd, WM_SETTEXT, IntPtr.Zero, textPointer,
            MESSAGE_FLAGS, MESSAGE_TIMEOUT_MS, out messageResult);

        if (sent == IntPtr.Zero) {
            error = "WM_SETTEXT could not be delivered: " + LastErrorText();
            return false;
        }
        if (messageResult == IntPtr.Zero) {
            error = "The Edit control rejected WM_SETTEXT.";
            return false;
        }
        return true;
    }

    // Sends the experimentally confirmed notification to the parent dialog:
    // WM_COMMAND, LOWORD(control ID)=16382, HIWORD(BN_CLICKED)=0, LPARAM=button HWND.
    // The probe showed that this method visibly activates PokerStars' custom
    // Flutter Login control. Message delivery is still logged separately from
    // the dialog's post-click state.
    public static bool ClickLoginButton(IntPtr dialog, IntPtr button,
                                        uint expectedPid, out string status, out string error) {
        status = null;
        error = null;

        if (!IsWindow(dialog) || !IsWindowVisible(dialog) || !IsWindowEnabled(dialog)) {
            error = "Login dialog is no longer available, visible, and enabled.";
            return false;
        }
        if (!IsWindow(button) || !IsWindowVisible(button) || !IsWindowEnabled(button)) {
            error = "Login button is no longer available, visible, and enabled.";
            return false;
        }
        if (GetParent(button) != dialog) {
            error = "Login button is no longer a direct child of the identified dialog.";
            return false;
        }
        if (ClassNameOf(button) != LOGIN_BUTTON_CLASS ||
            GetDlgCtrlID(button) != LOGIN_BUTTON_CONTROL_ID) {
            error = "The target HWND is no longer the expected PokerStars Login button (FlutterOnlinePokerButtonClass, ID 16382).";
            return false;
        }

        uint dialogPid;
        GetWindowThreadProcessId(dialog, out dialogPid);
        uint buttonPid;
        GetWindowThreadProcessId(button, out buttonPid);
        if (dialogPid != expectedPid || buttonPid != expectedPid) {
            error = "Login dialog or button no longer belongs to the selected PokerStars process.";
            return false;
        }

        // Revalidate immediately before sending, in case PokerStars replaced
        // the dialog/button after credential verification.
        if (!IsWindow(dialog) || !IsWindowVisible(dialog) ||
            !IsWindow(button) || !IsWindowVisible(button) || !IsWindowEnabled(button) ||
            GetParent(button) != dialog || GetDlgCtrlID(button) != LOGIN_BUTTON_CONTROL_ID) {
            error = "Login dialog or button changed immediately before WM_COMMAND; notification was not sent.";
            return false;
        }

        // Match the successful standalone probe exactly. WM_COMMAND is sent to
        // the parent dialog; wParam contains MAKELONG(16382, BN_CLICKED), and
        // lParam contains the Login button HWND.
        IntPtr wParam = new IntPtr(LOGIN_BUTTON_CONTROL_ID | ((int)BN_CLICKED << 16));
        IntPtr messageResult;
        IntPtr sent = SendMessageTimeoutPointer(
            dialog, WM_COMMAND, wParam, button,
            MESSAGE_FLAGS, MESSAGE_TIMEOUT_MS, out messageResult);
        if (sent == IntPtr.Zero) {
            error = "WM_COMMAND/BN_CLICKED could not be delivered to the parent dialog: " + LastErrorText();
            return false;
        }

        status = "WM_COMMAND/BN_CLICKED delivered to parent dialog HWND " + dialog.ToInt64() +
                 " for Login button HWND " + button.ToInt64() +
                 " (class " + LOGIN_BUTTON_CLASS + ", control ID " + LOGIN_BUTTON_CONTROL_ID + ").";
        return true;
    }

    public static bool SetText(IntPtr hWnd, string value, out string error) {
        IntPtr pointer = Marshal.StringToHGlobalUni(value);
        try {
            return SendSetTextPointer(hWnd, pointer, out error);
        }
        finally {
            Marshal.ZeroFreeGlobalAllocUnicode(pointer);
        }
    }

    // Uses the existing BSTR directly. This avoids creating another managed
    // plaintext password string in PowerShell.
    public static bool SetTextFromBstr(IntPtr hWnd, IntPtr bstr, out string error) {
        return SendSetTextPointer(hWnd, bstr, out error);
    }

    public static bool TryGetTextLength(IntPtr hWnd, out int length, out string error) {
        length = -1;
        error = null;
        IntPtr messageResult;
        IntPtr sent = SendMessageTimeoutPointer(
            hWnd, WM_GETTEXTLENGTH, IntPtr.Zero, IntPtr.Zero,
            MESSAGE_FLAGS, MESSAGE_TIMEOUT_MS, out messageResult);
        if (sent == IntPtr.Zero) {
            error = "WM_GETTEXTLENGTH failed: " + LastErrorText();
            return false;
        }
        long value = messageResult.ToInt64();
        if (value < 0 || value > Int32.MaxValue) {
            error = "The Edit control returned an invalid text length.";
            return false;
        }
        length = (int)value;
        return true;
    }

    public static bool UsernameMatches(IntPtr hWnd, string expected, out string error) {
        error = null;
        int expectedLength = expected.Length;
        StringBuilder buffer = new StringBuilder(expectedLength + 2);
        IntPtr messageResult;
        IntPtr sent = SendMessageTimeoutBuffer(
            hWnd, WM_GETTEXT, new IntPtr(buffer.Capacity), buffer,
            MESSAGE_FLAGS, MESSAGE_TIMEOUT_MS, out messageResult);
        if (sent == IntPtr.Zero) {
            error = "WM_GETTEXT could not verify the username: " + LastErrorText();
            buffer.Clear();
            return false;
        }

        int copied = (int)messageResult.ToInt64();
        bool matches = copied == expectedLength &&
                       String.Equals(buffer.ToString(), expected, StringComparison.Ordinal);
        buffer.Clear();
        if (!matches) error = "Username read-back did not exactly match the configured username.";
        return matches;
    }

    // Verifies the password internally without returning or logging its text.
    // If the Edit control returns only its password mask, the exact length is
    // still checked and the result is reported as length-only verification.
    public static bool VerifyPassword(IntPtr hWnd, IntPtr expectedBstr, int expectedLength,
                                      out string verification, out string error) {
        verification = null;
        error = null;

        int actualLength;
        if (!TryGetTextLength(hWnd, out actualLength, out error)) return false;
        if (actualLength != expectedLength) {
            error = "Password field length mismatch. Expected " + expectedLength + ", found " + actualLength + ".";
            return false;
        }

        int capacity = expectedLength + 2;
        StringBuilder buffer = new StringBuilder(capacity);
        IntPtr messageResult;
        IntPtr sent = SendMessageTimeoutBuffer(
            hWnd, WM_GETTEXT, new IntPtr(capacity), buffer,
            MESSAGE_FLAGS, MESSAGE_TIMEOUT_MS, out messageResult);

        if (sent == IntPtr.Zero) {
            // The text-setting message and exact character count succeeded,
            // but this control did not allow a text read-back.
            buffer.Clear();
            verification = "length-only (WM_GETTEXT unavailable)";
            return true;
        }

        int copied = (int)messageResult.ToInt64();
        if (copied == expectedLength) {
            bool exact = true;
            for (int i = 0; i < expectedLength; i++) {
                char expectedChar = (char)Marshal.ReadInt16(expectedBstr, i * 2);
                if (buffer[i] != expectedChar) {
                    exact = false;
                    break;
                }
            }
            if (exact) {
                buffer.Clear();
                verification = "exact password match (checked internally; not logged)";
                return true;
            }

            // Some password Edit controls return only repeated mask characters.
            // Recognize that case without displaying or storing the secret.
            IntPtr maskResult;
            IntPtr maskSent = SendMessageTimeoutPointer(
                hWnd, EM_GETPASSWORDCHAR, IntPtr.Zero, IntPtr.Zero,
                MESSAGE_FLAGS, MESSAGE_TIMEOUT_MS, out maskResult);
            char mask = maskSent != IntPtr.Zero ? (char)(maskResult.ToInt64() & 0xFFFF) : '\0';
            bool isMasked = mask != '\0';
            if (isMasked) {
                for (int i = 0; i < expectedLength; i++) {
                    if (buffer[i] != mask) { isMasked = false; break; }
                }
            }
            buffer.Clear();
            if (isMasked) {
                verification = "length-only (control returned its password mask)";
                return true;
            }

            error = "Password read-back did not match the saved password.";
            return false;
        }

        buffer.Clear();
        error = "Password field returned an unexpected number of characters during read-back.";
        return false;
    }
}
'@
    }
    $nativeTypeLoaded = $true

    $stage = 'decrypting saved password'
    $encryptedPassword = (Get-Content -LiteralPath $passwordFile -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($encryptedPassword)) {
        throw 'The encrypted password file is empty.'
    }
    $securePassword = ConvertTo-SecureString -String $encryptedPassword
    if ($securePassword.Length -le 0) {
        throw 'The saved password is empty.'
    }
    $passwordLength = $securePassword.Length
    $passwordBstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)

    # PokerStars can show an intermediate connection/loading dialog before the
    # real login form. Do not accept a #32770 dialog merely because it exists.
    # Keep polling until the same dialog exposes exactly one normal Edit and
    # one ES_PASSWORD Edit over several consecutive polls.
    $stage = 'waiting for PokerStars login dialog and its two native fields'
    $deadline = (Get-Date).AddSeconds($loginFormTimeoutSeconds)
    $process = $null
    $selectedCandidate = $null
    $stableCandidateKey = $null
    $stablePolls = 0
    $lastStatusLog = (Get-Date).AddSeconds(-15)
    $lastObservedDialogCount = 0
    $lastObservedEditCount = 0
    $lastObservedProcessCount = 0

    while ((Get-Date) -lt $deadline) {
        $validCandidates = @()
        $currentProcesses = @(Get-Process -Name 'PokerStars' -ErrorAction SilentlyContinue |
            Where-Object {
                if ($launcherJob -ne [IntPtr]::Zero -and
                    -not [PokerLauncherProcessJob]::IsRunningInJob($launcherJob, $_, $PokerStarsPath)) { return $false }
                if ($_.MainWindowHandle -eq 0) { return $false }
                if ($runStartedUtcParsed -eq [DateTime]::MinValue) { return $true }
                try {
                    return ($_.StartTime.ToUniversalTime() -ge $runStartedUtcParsed)
                }
                catch {
                    return $false
                }
            })
        $lastObservedProcessCount = $currentProcesses.Count
        $lastObservedDialogCount = 0
        $lastObservedEditCount = 0
        $lastObservedLoginButtonCount = 0

        foreach ($candidateProcess in $currentProcesses) {
            $candidateLobby = [IntPtr]$candidateProcess.MainWindowHandle
            if (-not [PokerStarsNativeLoginButtonV2]::IsWindow($candidateLobby)) { continue }

            $candidateDialogs = @([PokerStarsNativeLoginButtonV2]::FindOwnedLoginDialogs(
                $candidateLobby, [uint32]$candidateProcess.Id
            ))
            $lastObservedDialogCount += $candidateDialogs.Count

            foreach ($candidateDialog in $candidateDialogs) {
                $candidateDialog = [IntPtr]$candidateDialog
                if (-not [PokerStarsNativeLoginButtonV2]::IsWindow($candidateDialog)) { continue }

                [uint32]$candidateDialogPid = 0
                [void][PokerStarsNativeLoginButtonV2]::GetWindowThreadProcessId(
                    $candidateDialog, [ref]$candidateDialogPid
                )
                if ($candidateDialogPid -ne [uint32]$candidateProcess.Id) { continue }

                $candidateEdits = @([PokerStarsNativeLoginButtonV2]::FindDirectEditChildren(
                    $candidateDialog, [uint32]$candidateProcess.Id
                ))
                if ($candidateEdits.Count -gt $lastObservedEditCount) {
                    $lastObservedEditCount = $candidateEdits.Count
                }

                $candidateUsernameEdits = @($candidateEdits | Where-Object { -not $_.IsPassword })
                $candidatePasswordEdits = @($candidateEdits | Where-Object { $_.IsPassword })
                $candidateLoginButtons = @([PokerStarsNativeLoginButtonV2]::FindDirectLoginButtons(
                    $candidateDialog, [uint32]$candidateProcess.Id
                ))
                if ($candidateLoginButtons.Count -gt $lastObservedLoginButtonCount) {
                    $lastObservedLoginButtonCount = $candidateLoginButtons.Count
                }

                # A connecting dialog, an incompletely-created login dialog,
                # or any unrelated dialog is ignored. No fields are touched.
                # The actual custom Login button (control ID 16382) must also exist.
                if ($candidateEdits.Count -ne 2 -or
                    $candidateUsernameEdits.Count -ne 1 -or
                    $candidatePasswordEdits.Count -ne 1 -or
                    $candidateLoginButtons.Count -ne 1) {
                    continue
                }

                $validCandidates += [PSCustomObject]@{
                    Process = $candidateProcess
                    Lobby = $candidateLobby
                    Dialog = $candidateDialog
                    UsernameHandle = [IntPtr]$candidateUsernameEdits[0].Handle
                    PasswordHandle = [IntPtr]$candidatePasswordEdits[0].Handle
                    LoginButtonHandle = [IntPtr]$candidateLoginButtons[0].Handle
                }
            }
        }

        if ($validCandidates.Count -eq 1) {
            $candidate = $validCandidates[0]
            $candidateKey = '{0}|{1}|{2}|{3}|{4}' -f `
                $candidate.Process.Id, $candidate.Dialog.ToInt64(), `
                $candidate.UsernameHandle.ToInt64(), $candidate.PasswordHandle.ToInt64(), `
                $candidate.LoginButtonHandle.ToInt64()

            if ($candidateKey -eq $stableCandidateKey) {
                $stablePolls++
            }
            else {
                $stableCandidateKey = $candidateKey
                $stablePolls = 1
            }

            # Require the same process, dialog, both Edit handles, and Login
            # button handle to remain present for four polls (~1.5 seconds).
            if ($stablePolls -ge 4) {
                $selectedCandidate = $candidate
                break
            }
        }
        else {
            $stableCandidateKey = $null
            $stablePolls = 0
        }

        if (((Get-Date) - $lastStatusLog).TotalSeconds -ge 15) {
            if ($currentProcesses.Count -eq 0) {
                Write-LoginLog 'Still waiting: PokerStars Lobby process/window is not available yet.'
            }
            elseif ($lastObservedDialogCount -eq 0) {
                Write-LoginLog 'Still waiting: no visible owned PokerStars dialog yet.'
            }
            elseif ($validCandidates.Count -eq 0) {
                Write-LoginLog ("Still waiting: found {0} visible owned dialog(s), but none yet has two ready Edit fields (one ES_PASSWORD) and exactly one enabled Login button (control ID 16382). Most Edit fields seen in one dialog: {1}; matching Login buttons seen: {2}." -f $lastObservedDialogCount, $lastObservedEditCount, $lastObservedLoginButtonCount)
            }
            else {
                Write-LoginLog ("Login dialog candidate found; confirming it remains stable ({0}/4 polls)." -f $stablePolls)
            }
            $lastStatusLog = Get-Date
        }

        Start-Sleep -Milliseconds 500
    }

    if ($null -eq $selectedCandidate) {
        throw ("Timed out after {0} seconds ({1} minutes) waiting for the actual login form and Login button. Last observation: {2} PokerStars process(es), {3} visible owned dialog(s), up to {4} Edit control(s) and {5} matching Login button(s) in one dialog. Intermediate connection/loading dialogs are ignored; no fields were changed." -f $loginFormTimeoutSeconds, ($loginFormTimeoutSeconds / 60), $lastObservedProcessCount, $lastObservedDialogCount, $lastObservedEditCount, $lastObservedLoginButtonCount)
    }

    $process = $selectedCandidate.Process
    $dialogHandle = [IntPtr]$selectedCandidate.Dialog
    $usernameHwnd = [IntPtr]$selectedCandidate.UsernameHandle
    $passwordHwnd = [IntPtr]$selectedCandidate.PasswordHandle
    $loginButtonHwnd = [IntPtr]$selectedCandidate.LoginButtonHandle

    Write-LoginLog ("Stable login form detected: PID {0}, dialog HWND {1}, username HWND {2}, password HWND {3}." -f $process.Id, $dialogHandle, $usernameHwnd, $passwordHwnd)

    $stage = 'validating native control handles'
    foreach ($handle in @($usernameHwnd, $passwordHwnd)) {
        if (-not [PokerStarsNativeLoginButtonV2]::IsWindow($handle)) {
            throw 'A login field handle became invalid before entry.'
        }
        if (-not [PokerStarsNativeLoginButtonV2]::IsWindowVisible($handle) -or
            -not [PokerStarsNativeLoginButtonV2]::IsWindowEnabled($handle)) {
            throw 'A login field is no longer visible and enabled.'
        }
        if ([PokerStarsNativeLoginButtonV2]::GetParent($handle) -ne $dialogHandle) {
            throw 'A field is no longer a direct child of the identified login dialog.'
        }
        [uint32]$fieldPid = 0
        [void][PokerStarsNativeLoginButtonV2]::GetWindowThreadProcessId($handle, [ref]$fieldPid)
        if ($fieldPid -ne [uint32]$process.Id) {
            throw 'A field no longer belongs to the selected PokerStars process.'
        }
    }

    # Re-enumerate immediately before modification. This prevents using stale
    # handles if PokerStars replaced the connection dialog during startup.
    $liveEdits = @([PokerStarsNativeLoginButtonV2]::FindDirectEditChildren(
        $dialogHandle, [uint32]$process.Id
    ))
    $liveUsernameEdits = @($liveEdits | Where-Object { -not $_.IsPassword })
    $livePasswordEdits = @($liveEdits | Where-Object { $_.IsPassword })
    $liveUsernameHandle = [IntPtr]::Zero
    $livePasswordHandle = [IntPtr]::Zero
    if ($liveUsernameEdits.Count -eq 1) { $liveUsernameHandle = [IntPtr]($liveUsernameEdits[0].Handle) }
    if ($livePasswordEdits.Count -eq 1) { $livePasswordHandle = [IntPtr]($livePasswordEdits[0].Handle) }
    if ($liveEdits.Count -ne 2 -or $liveUsernameEdits.Count -ne 1 -or
        $livePasswordEdits.Count -ne 1 -or
        $liveUsernameHandle -ne $usernameHwnd -or
        $livePasswordHandle -ne $passwordHwnd) {
        throw 'The login dialog or its fields changed after detection. No credentials were entered; run the helper again.'
    }
    $liveLoginButtons = @([PokerStarsNativeLoginButtonV2]::FindDirectLoginButtons(
        $dialogHandle, [uint32]$process.Id
    ))
    if ($liveLoginButtons.Count -ne 1 -or
        [IntPtr]$liveLoginButtons[0].Handle -ne $loginButtonHwnd) {
        throw 'The Login button changed after detection. No credentials were entered; run the helper again.'
    }

    Write-LoginLog "Found PokerStars PID $($process.Id), login dialog HWND $dialogHandle."
    Write-LoginLog "Identified username Edit HWND $usernameHwnd and password Edit HWND $passwordHwnd from ES_PASSWORD style."
    Write-LoginLog "Identified Login button HWND $loginButtonHwnd (FlutterOnlinePokerButtonClass, control ID 16382)."

    $stage = 'clearing existing username and password fields'
    $nativeError = $null
    if (-not [PokerStarsNativeLoginButtonV2]::SetText($usernameHwnd, '', [ref]$nativeError)) {
        throw "Could not clear the username field: $nativeError"
    }
    if (-not [PokerStarsNativeLoginButtonV2]::SetText($passwordHwnd, '', [ref]$nativeError)) {
        throw "Could not clear the password field: $nativeError"
    }

    $usernameClearedLength = -1
    $passwordClearedLength = -1
    if (-not [PokerStarsNativeLoginButtonV2]::TryGetTextLength($usernameHwnd, [ref]$usernameClearedLength, [ref]$nativeError)) {
        throw "Could not verify that the username field was cleared: $nativeError"
    }
    if (-not [PokerStarsNativeLoginButtonV2]::TryGetTextLength($passwordHwnd, [ref]$passwordClearedLength, [ref]$nativeError)) {
        throw "Could not verify that the password field was cleared: $nativeError"
    }
    if ($usernameClearedLength -ne 0 -or $passwordClearedLength -ne 0) {
        throw "Field clearing verification failed (username length $usernameClearedLength, password length $passwordClearedLength)."
    }
    Write-LoginLog 'Existing contents cleared and verified in both fields.'

    $stage = 'setting username directly in its native Edit control'
    if (-not [PokerStarsNativeLoginButtonV2]::SetText($usernameHwnd, $username, [ref]$nativeError)) {
        throw "Could not set the username field: $nativeError"
    }

    $stage = 'setting password directly in its native Edit control'
    if (-not [PokerStarsNativeLoginButtonV2]::SetTextFromBstr($passwordHwnd, $passwordBstr, [ref]$nativeError)) {
        throw "Could not set the password field: $nativeError"
    }

    Start-Sleep -Milliseconds 150

    $stage = 'verifying username read-back'
    if (-not [PokerStarsNativeLoginButtonV2]::UsernameMatches($usernameHwnd, $username, [ref]$nativeError)) {
        throw $nativeError
    }
    Write-LoginLog 'Username read-back: exact match.'

    $stage = 'verifying password read-back'
    $passwordVerification = $null
    if (-not [PokerStarsNativeLoginButtonV2]::VerifyPassword(
        $passwordHwnd, $passwordBstr, $passwordLength,
        [ref]$passwordVerification, [ref]$nativeError
    )) {
        throw $nativeError
    }
    Write-LoginLog "Password field verification: $passwordVerification."
    Write-LoginLog 'Both credential fields passed the available verification checks.'

    $stage = 'activating PokerStars and notifying the parent dialog with WM_COMMAND / BN_CLICKED'
    $shell = New-Object -ComObject WScript.Shell
    if (-not $shell.AppActivate([int]$process.Id)) {
        throw 'Could not activate PokerStars before notifying the Login dialog. WM_COMMAND was not sent.'
    }
    Start-Sleep -Milliseconds 150

    $buttonStatus = $null
    if (-not [PokerStarsNativeLoginButtonV2]::ClickLoginButton(
        $dialogHandle, $loginButtonHwnd, [uint32]$process.Id,
        [ref]$buttonStatus, [ref]$nativeError
    )) {
        throw "Could not submit the Login button notification: $nativeError"
    }
    Write-LoginLog "LOGIN BUTTON NOTIFICATION: $buttonStatus"

    # The launcher treats a login form that remains visible after submission
    # as a failure. Wait for the UI to react before returning success.
    $stage = 'waiting for the login dialog to close after submission'
    $postSubmitDeadline = (Get-Date).AddSeconds($postSubmitTimeoutSeconds)
    while ((Get-Date) -lt $postSubmitDeadline) {
        if (-not [PokerStarsNativeLoginButtonV2]::IsWindow($dialogHandle) -or
            -not [PokerStarsNativeLoginButtonV2]::IsWindowVisible($dialogHandle)) {
            break
        }
        Start-Sleep -Milliseconds 500
    }

    if ([PokerStarsNativeLoginButtonV2]::IsWindow($dialogHandle) -and
        [PokerStarsNativeLoginButtonV2]::IsWindowVisible($dialogHandle)) {
        throw ("The original PokerStars login dialog remained visible {0} seconds after the Login notification. The login was not confirmed." -f $postSubmitTimeoutSeconds)
    }
    $process.Refresh()
    if ($process.HasExited) {
        throw 'PokerStars exited after the Login notification; the disappearance of its dialog does not confirm a login submission.'
    }
    Write-LoginLog 'Post-submit confirmation: the original login dialog is no longer visible.'
}
catch {
    $exitCode = 1
    $message = $_.Exception.Message
    Write-LoginLog "ERROR during stage '$stage': $message"

    # On any partial failure, clear both fields so the dialog is not left with
    # a possibly mismatched username/password pair.
    if ($nativeTypeLoaded -and $dialogHandle -ne [IntPtr]::Zero -and
        [PokerStarsNativeLoginButtonV2]::IsWindow($dialogHandle)) {
        foreach ($handle in @($usernameHwnd, $passwordHwnd)) {
            if ($handle -eq [IntPtr]::Zero -or -not [PokerStarsNativeLoginButtonV2]::IsWindow($handle)) { continue }
            if ([PokerStarsNativeLoginButtonV2]::GetParent($handle) -ne $dialogHandle) { continue }
            [uint32]$cleanupPid = 0
            [void][PokerStarsNativeLoginButtonV2]::GetWindowThreadProcessId($handle, [ref]$cleanupPid)
            if ($null -ne $process -and $cleanupPid -eq [uint32]$process.Id) {
                $ignored = $null
                [void][PokerStarsNativeLoginButtonV2]::SetText($handle, '', [ref]$ignored)
            }
        }
    }

    @(
        "Stage: $stage"
        "Error: $message"
        "Details: $logFile"
    ) | Set-Content -LiteralPath $errorFile -Encoding UTF8
}
finally {
    if ($launcherJob -ne [IntPtr]::Zero) {
        [PokerLauncherProcessJob]::CloseJob($launcherJob)
    }
    if ($passwordBstr -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordBstr)
    }
    if ($null -ne $securePassword) {
        $securePassword.Dispose()
    }
    $encryptedPassword = $null
}

if ($exitCode -eq 0) {
    Write-LoginLog 'Finished successfully.'
    exit 0
}

exit $exitCode
