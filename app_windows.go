//go:build windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	errorCancelled        = syscall.Errno(1223)
	seeMaskNoCloseProcess = 0x00000040
	swShowNormal          = 1
	mbOK                  = 0x00000000
	mbIconError           = 0x00000010
	mbIconInformation     = 0x00000040
	createNoWindow        = 0x08000000
	tokenQuery            = 0x0008
	tokenElevation        = 20
)

const launcherAlreadyRunningExitCode = 2

var errPokerStarsAlreadyRunning = errors.New("PokerStars is already running")

type shellExecuteInfo struct {
	cbSize       uint32
	fMask        uint32
	hwnd         uintptr
	lpVerb       *uint16
	lpFile       *uint16
	lpParameters *uint16
	lpDirectory  *uint16
	nShow        int32
	hInstApp     uintptr
	lpIDList     uintptr
	lpClass      *uint16
	hkeyClass    uintptr
	dwHotKey     uint32
	hIcon        uintptr
	hProcess     uintptr
}

type tokenElevationInfo struct {
	TokenIsElevated uint32
}

var (
	shell32                 = syscall.NewLazyDLL("shell32.dll")
	user32                  = syscall.NewLazyDLL("user32.dll")
	kernel32                = syscall.NewLazyDLL("kernel32.dll")
	procShellExecuteExW     = shell32.NewProc("ShellExecuteExW")
	procMessageBoxW         = user32.NewProc("MessageBoxW")
	procOpenProcessToken    = advapi32.NewProc("OpenProcessToken")
	procGetTokenInformation = advapi32.NewProc("GetTokenInformation")
	procWaitForSingleObject = kernel32.NewProc("WaitForSingleObject")
	procGetExitCodeProcess  = kernel32.NewProc("GetExitCodeProcess")
	procCloseHandle         = kernel32.NewProc("CloseHandle")
	advapi32                = syscall.NewLazyDLL("advapi32.dll")
)

func run() error {
	args := os.Args[1:]
	mode := ""
	if len(args) > 0 {
		mode = strings.ToLower(strings.TrimSpace(args[0]))
	}

	if mode == "--launch-elevated" {
		if !isElevated() {
			return fmt.Errorf("the elevated launcher entry point was invoked without administrator privileges")
		}
		runLauncherController()
		return nil
	}

	if mode != "--uninstall" {
		switch mode {
		case "", "--setup", "--launch":
		default:
			return fmt.Errorf("unknown command-line option: %s", mode)
		}

		installDir, err := installationDirectory()
		if err != nil {
			return err
		}
		if err := installOrUpdate(installDir); err != nil {
			return err
		}
		if err := runPowerShellInDirectory(installDir, "migrate.ps1"); err != nil {
			return fmt.Errorf("migrating existing settings: %w", err)
		}
		if err := runPowerShellInDirectory(installDir, "register.ps1"); err != nil {
			return fmt.Errorf("refreshing application shortcuts and uninstall registration: %w", err)
		}
		targetExe := filepath.Join(installDir, "PokerLauncher.exe")
		sourceExe, err := os.Executable()
		if err != nil {
			return fmt.Errorf("locating the running executable: %w", err)
		}
		if !samePath(sourceExe, targetExe) {
			if mode == "" {
				if configExists() {
					showMessage("PokerLauncher updated", "Version "+version+" has been installed.\r\n\r\nUse the PokerLauncher shortcut when you're ready to start your applications.", mbOK|mbIconInformation)
					return nil
				} else {
					mode = "--setup"
				}
			}
			return runInstalledCopy(targetExe, mode)
		}
	}

	switch mode {
	case "--setup":
		return runPowerShell("setup.ps1")
	case "--launch":
		if !configExists() {
			return runPowerShell("setup.ps1")
		}
		return launchElevated()
	case "--uninstall":
		return runPowerShell("uninstall.ps1")
	case "", "--help", "-h", "/?":
		if !configExists() {
			return runPowerShell("setup.ps1")
		}
		return launchElevated()
	default:
		return fmt.Errorf("unknown command-line option: %s", mode)
	}
}

func runInstalledCopy(executable, argument string) error {
	command := exec.Command(executable, argument)
	command.Dir = filepath.Dir(executable)
	command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	if err := command.Start(); err != nil {
		return fmt.Errorf("starting the installed application: %w", err)
	}
	return command.Process.Release()
}

func installationDirectory() (string, error) {
	localAppData := os.Getenv("LOCALAPPDATA")
	if strings.TrimSpace(localAppData) == "" {
		return "", fmt.Errorf("Windows did not provide LOCALAPPDATA for this user profile")
	}
	return filepath.Join(localAppData, "Programs", "PokerLauncher"), nil
}

func configExists() bool {
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return false
	}
	info, err := os.Stat(filepath.Join(appData, "PokerLauncher", "config.json"))
	return err == nil && !info.IsDir()
}

func installOrUpdate(installDir string) error {
	if err := os.MkdirAll(installDir, 0755); err != nil {
		return fmt.Errorf("creating the per-user installation directory: %w", err)
	}

	sourceExe, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locating the running executable: %w", err)
	}
	sourceExe, _ = filepath.Abs(sourceExe)
	targetExe := filepath.Join(installDir, "PokerLauncher.exe")
	if !samePath(sourceExe, targetExe) {
		if err := copyFileAtomically(sourceExe, targetExe); err != nil {
			return fmt.Errorf("installing PokerLauncher.exe: %w", err)
		}
	}

	for _, directory := range []string{"scripts", "assets"} {
		if err := extractEmbeddedDirectory(directory, installDir); err != nil {
			return err
		}
	}

	versionPath := filepath.Join(installDir, "version.txt")
	if err := os.WriteFile(versionPath, []byte(version+"\r\n"), 0644); err != nil {
		return fmt.Errorf("writing application version: %w", err)
	}
	return nil
}

func extractEmbeddedDirectory(directory, destinationRoot string) error {
	return fs.WalkDir(embeddedResources, directory, func(sourcePath string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative := strings.TrimPrefix(sourcePath, directory)
		relative = strings.TrimPrefix(relative, "/")
		target := filepath.Join(destinationRoot, directory, filepath.FromSlash(relative))
		if entry.IsDir() {
			if err := os.MkdirAll(target, 0755); err != nil {
				return fmt.Errorf("creating resource directory %s: %w", target, err)
			}
			return nil
		}
		data, err := embeddedResources.ReadFile(sourcePath)
		if err != nil {
			return fmt.Errorf("reading embedded resource %s: %w", sourcePath, err)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return fmt.Errorf("creating resource directory for %s: %w", target, err)
		}
		if err := os.WriteFile(target, data, 0644); err != nil {
			return fmt.Errorf("extracting embedded resource %s: %w", sourcePath, err)
		}
		return nil
	})
}

func copyFileAtomically(source, destination string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()

	output, err := os.CreateTemp(filepath.Dir(destination), ".PokerLauncher-*.tmp")
	if err != nil {
		return err
	}
	temporary := output.Name()
	defer os.Remove(temporary)

	if _, err := input.Seek(0, 0); err != nil {
		output.Close()
		return err
	}
	if _, err := output.ReadFrom(input); err != nil {
		output.Close()
		return err
	}
	if err := output.Close(); err != nil {
		return err
	}
	if err := os.Chmod(temporary, 0755); err != nil {
		return err
	}
	if err := os.Rename(temporary, destination); err != nil {
		return err
	}
	return nil
}

func samePath(left, right string) bool {
	left = filepath.Clean(left)
	right = filepath.Clean(right)
	return strings.EqualFold(left, right)
}

func launchElevated() error {
	if isElevated() {
		runLauncherController()
		return nil
	}

	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locating the installed executable: %w", err)
	}
	if err := shellExecuteWait(executable, "--launch-elevated", filepath.Dir(executable), "runas"); err != nil {
		if errors.Is(err, errorCancelled) {
			showMessage("PokerLauncher", "Administrator approval was cancelled. No applications were started.", mbOK|mbIconInformation)
			return nil
		}
		return fmt.Errorf("requesting administrator permission: %w", err)
	}
	return nil
}

func shellExecuteWait(file, parameters, workingDirectory, verb string) error {
	verbPtr, err := syscall.UTF16PtrFromString(verb)
	if err != nil {
		return err
	}
	filePtr, err := syscall.UTF16PtrFromString(file)
	if err != nil {
		return err
	}
	parametersPtr, err := syscall.UTF16PtrFromString(parameters)
	if err != nil {
		return err
	}
	directoryPtr, err := syscall.UTF16PtrFromString(workingDirectory)
	if err != nil {
		return err
	}

	info := shellExecuteInfo{
		cbSize:       uint32(unsafe.Sizeof(shellExecuteInfo{})),
		fMask:        seeMaskNoCloseProcess,
		lpVerb:       verbPtr,
		lpFile:       filePtr,
		lpParameters: parametersPtr,
		lpDirectory:  directoryPtr,
		nShow:        swShowNormal,
	}
	result, _, callErr := procShellExecuteExW.Call(uintptr(unsafe.Pointer(&info)))
	if result == 0 {
		if callErr != syscall.Errno(0) {
			return callErr
		}
		return syscall.GetLastError()
	}
	if info.hProcess == 0 {
		return fmt.Errorf("Windows started the elevated process but did not return a process handle")
	}
	defer closeHandle(info.hProcess)

	waitResult, _, waitErr := procWaitForSingleObject.Call(info.hProcess, ^uintptr(0))
	if uint32(waitResult) != 0 {
		if waitErr != syscall.Errno(0) {
			return fmt.Errorf("waiting for the elevated launcher: %w", waitErr)
		}
		return fmt.Errorf("waiting for the elevated launcher returned status 0x%x", waitResult)
	}

	var exitCode uint32
	ok, _, exitErr := procGetExitCodeProcess.Call(info.hProcess, uintptr(unsafe.Pointer(&exitCode)))
	if ok == 0 {
		if exitErr != syscall.Errno(0) {
			return fmt.Errorf("reading the elevated launcher exit code: %w", exitErr)
		}
		return syscall.GetLastError()
	}
	if exitCode != 0 {
		return fmt.Errorf("the elevated launcher exited with code %d", exitCode)
	}
	return nil
}

func isElevated() bool {
	var token syscall.Token
	process := syscall.Handle(^uintptr(0)) // GetCurrentProcess pseudo-handle (-1).
	result, _, _ := procOpenProcessToken.Call(uintptr(process), tokenQuery, uintptr(unsafe.Pointer(&token)))
	if result == 0 {
		return false
	}
	defer token.Close()

	var elevation tokenElevationInfo
	var returned uint32
	result, _, _ = procGetTokenInformation.Call(
		uintptr(token), tokenElevation,
		uintptr(unsafe.Pointer(&elevation)),
		unsafe.Sizeof(elevation), uintptr(unsafe.Pointer(&returned)),
	)
	return result != 0 && elevation.TokenIsElevated != 0
}

func closeHandle(handle uintptr) {
	if handle != 0 {
		procCloseHandle.Call(handle)
	}
}

func powerShellProcessOptions(scriptName, scriptPath string) ([]string, *syscall.SysProcAttr) {
	// Setup and uninstall display Windows Forms dialogs. CREATE_NO_WINDOW
	// suppresses PowerShell's console without hiding GUI windows. Do not set
	// HideWindow/SW_HIDE for these interactive scripts.
	interactive := scriptName == "setup.ps1" || scriptName == "uninstall.ps1"
	arguments := []string{"-NoLogo", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass"}
	if !interactive {
		arguments = append(arguments, "-WindowStyle", "Hidden")
	}
	arguments = append(arguments, "-File", scriptPath)

	attributes := &syscall.SysProcAttr{CreationFlags: createNoWindow}
	if !interactive {
		attributes.HideWindow = true
	}
	return arguments, attributes
}

func runPowerShell(scriptName string) error {
	executable, err := os.Executable()
	if err != nil {
		return fmt.Errorf("locating the installed application: %w", err)
	}
	return runPowerShellInDirectory(filepath.Dir(executable), scriptName)
}

func runPowerShellInDirectory(directory, scriptName string) error {
	scriptPath := filepath.Join(directory, "scripts", scriptName)
	if _, err := os.Stat(scriptPath); err != nil {
		return fmt.Errorf("required application component is missing (%s): %w", scriptName, err)
	}

	powerShell := filepath.Join(os.Getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
	// Setup and uninstall display Windows Forms dialogs. Create PowerShell
	// without a console, but do not set STARTF_USESHOWWINDOW/SW_HIDE: that
	// startup hint can also hide the WinForms dialog created by the script.
	// CREATE_NO_WINDOW suppresses the console while leaving GUI windows visible.
	arguments, processAttributes := powerShellProcessOptions(scriptName, scriptPath)
	command := exec.Command(powerShell, arguments...)
	command.Dir = directory
	command.SysProcAttr = processAttributes
	command.Env = append(os.Environ(), fmt.Sprintf("POKERSTARSL_PARENT_PID=%d", os.Getpid()))
	output, err := command.CombinedOutput()
	return powerShellResultError(scriptName, output, err)
}

func powerShellResultError(scriptName string, output []byte, err error) error {
	if err != nil {
		var exitError *exec.ExitError
		if scriptName == "launch.ps1" && errors.As(err, &exitError) && exitError.ExitCode() == 3 {
			return fmt.Errorf("helper startup failures: %s", strings.TrimSpace(string(output)))
		}
		if scriptName == "launch.ps1" && errors.As(err, &exitError) && exitError.ExitCode() == launcherAlreadyRunningExitCode {
			return errPokerStarsAlreadyRunning
		}
		trimmed := strings.TrimSpace(string(output))
		if trimmed != "" {
			return fmt.Errorf("%s failed: %w\n%s", scriptName, err, trimmed)
		}
		return fmt.Errorf("%s failed: %w", scriptName, err)
	}
	return nil
}

func runLauncherController() {
	if err := runPowerShell("launch.ps1"); err != nil {
		if !errors.Is(err, errPokerStarsAlreadyRunning) {
			logApplicationError(err)
		}
		title, message, flags := launchErrorDialog(err)
		showMessage(title, message, flags)
	}
}

func launchErrorDialog(err error) (string, string, uintptr) {
	if err != nil && strings.HasPrefix(err.Error(), "helper startup failures:") {
		detail := err.Error()
		if index := strings.Index(detail, "Some helpers could not start:"); index >= 0 {
			detail = detail[index:]
		}
		return "Some helpers could not start", detail, mbOK | mbIconInformation
	}
	if errors.Is(err, errPokerStarsAlreadyRunning) {
		return "PokerStars is already running",
			"Close PokerStars when you're ready, then open PokerLauncher again.\r\n\r\nYour current session has been left running.",
			mbOK | mbIconInformation
	}
	return "PokerLauncher", formatLaunchError(err), mbOK | mbIconError
}

func formatLaunchError(err error) string {
	detail := ""
	if err != nil {
		detail = err.Error()
	}
	setup := "Open Configure PokerLauncher from the Start Menu, check your settings, and try again."
	switch {
	case strings.Contains(detail, "saved password"), strings.Contains(detail, "username is missing"),
		strings.Contains(detail, "Configuration not found"), strings.Contains(detail, "Unsupported configuration"),
		strings.Contains(detail, "Configured executable"):
		return "Your saved launcher settings need attention.\r\n\r\n" + setup
	case strings.Contains(detail, "installing PokerLauncher.exe"):
		return "The update could not be installed.\r\n\r\nClose any other PokerLauncher windows and run the downloaded EXE again. Your poker applications can stay open."
	case strings.Contains(detail, "registration"), strings.Contains(detail, "register.ps1"):
		return "The installation could not finish updating its shortcuts and Windows Apps entry.\r\n\r\nRun the downloaded EXE again to repair the installation."
	case strings.Contains(detail, "required application component is missing"), strings.Contains(detail, "login helper not found"):
		return "The launcher installation is missing a required file.\r\n\r\nRun the latest downloaded EXE to repair the installation."
	case strings.Contains(detail, "login helper failed"):
		return "PokerStars login could not be completed.\r\n\r\nOpen PokerStars directly to check for a sign-in or connection message, then try the launcher again."
	case strings.Contains(detail, "did not complete within"):
		return "Starting the applications took too long.\r\n\r\nCheck for connection problems or update prompts in the applications, then try again."
	}
	applications := []struct{ label, executable, display string }{
		{"PokerStars updater", "pokerstars.exe", "PokerStars"},
		{"Xeester updater", "xeester.exe", "Xeester"},
		{"StarsCaption", "starscaption.exe", "StarsCaption"},
	}
	for _, app := range applications {
		if strings.Contains(detail, "Could not start "+app.label) || strings.Contains(detail, app.label+" exited with code") ||
			(strings.Contains(detail, "exited unexpectedly") && strings.Contains(strings.ToLower(detail), app.executable)) {
			return app.display + " could not finish starting.\r\n\r\nOpen " + app.display + " directly to check for an update or error message, then try the launcher again."
		}
	}
	return "The launcher could not complete startup.\r\n\r\nTry again. If the problem continues, the technical details are in the launcher logs."
}

// Keep diagnostics on disk instead of copying scripts and history into dialogs.
func logApplicationError(err error) {
	if err == nil || strings.TrimSpace(os.Getenv("LOCALAPPDATA")) == "" {
		return
	}
	directory := filepath.Join(os.Getenv("LOCALAPPDATA"), "PokerLauncher", "logs")
	if os.MkdirAll(directory, 0755) != nil {
		return
	}
	file, openErr := os.OpenFile(filepath.Join(directory, "application.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if openErr != nil {
		return
	}
	defer file.Close()
	fmt.Fprintf(file, "%s  %v\r\n", time.Now().Format("2006-01-02 15:04:05.000"), err)
}

func showFatal(err error) {
	logApplicationError(err)
	showMessage("PokerLauncher", formatLaunchError(err), mbOK|mbIconError)
}

func showMessage(title, message string, flags uintptr) {
	titlePtr, _ := syscall.UTF16PtrFromString(title)
	messagePtr, _ := syscall.UTF16PtrFromString(message)
	procMessageBoxW.Call(0, uintptr(unsafe.Pointer(messagePtr)), uintptr(unsafe.Pointer(titlePtr)), flags)
}
