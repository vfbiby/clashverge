package mtconfig

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf16"
	"unsafe"
)

var (
	modcomdlg32         = syscall.NewLazyDLL("comdlg32.dll")
	procGetOpenFileName = modcomdlg32.NewProc("GetOpenFileNameW")

	moduser32        = syscall.NewLazyDLL("user32.dll")
	procMessageBox   = moduser32.NewProc("MessageBoxW")
)

type OPENFILENAME struct {
	StructSize      uint32
	HwndOwner       uintptr
	HInstance       uintptr
	Filter          *uint16
	CustomFilter    *uint16
	MaxCustFilter   uint32
	FilterIndex     uint32
	File            *uint16
	MaxFile         uint32
	FileTitle       *uint16
	MaxFileTitle    uint32
	InitialDir      *uint16
	Title           *uint16
	Flags           uint32
	FileOffset      uint16
	FileExtension   uint16
	DefExt          *uint16
	CustData        uintptr
	FnHook          uintptr
	TemplateName    *uint16
	PvReserved      uintptr
	DwReserved      uint32
	FlagsEx         uint32
}

// 弹窗提示
func ShowMessageBox(title, msg string, isError bool) {
	icon := uintptr(0x40) // MB_ICONINFORMATION
	if isError {
		icon = 0x10 // MB_ICONERROR
	}
	tPtr, _ := syscall.UTF16PtrFromString(title)
	mPtr, _ := syscall.UTF16PtrFromString(msg)
	procMessageBox.Call(0, uintptr(unsafe.Pointer(mPtr)), uintptr(unsafe.Pointer(tPtr)), 0x00|icon)
}

// 弹出文件选择对话框
func SelectMetaTraderFile(title, filterName, filterExts string) (string, error) {
	// 构建 Filter 字符串 (如 "MetaTrader (*.exe;*.lnk)\x00*.exe;*.lnk\x00所有文件 (*.*)\x00*.*\x00\x00")
	filterStr := fmt.Sprintf("%s (%s)\x00%s\x00所有文件 (*.*)\x00*.*\x00\x00", filterName, filterExts, filterExts)
	filterUTF16 := utf16.Encode([]rune(filterStr))

	fileBuf := make([]uint16, 1024)
	tPtr, _ := syscall.UTF16PtrFromString(title)

	var ofn OPENFILENAME
	ofn.StructSize = uint32(unsafe.Sizeof(ofn))
	ofn.Filter = &filterUTF16[0]
	ofn.File = &fileBuf[0]
	ofn.MaxFile = uint32(len(fileBuf))
	ofn.Title = tPtr
	ofn.Flags = 0x00000800 /* OFN_PATHMUSTEXIST */ | 0x00001000 /* OFN_FILEMUSTEXIST */ | 0x00080000 /* OFN_EXPLORER */

	r, _, _ := procGetOpenFileName.Call(uintptr(unsafe.Pointer(&ofn)))
	if r == 0 {
		return "", fmt.Errorf("cancelled")
	}

	return syscall.UTF16ToString(fileBuf), nil
}

// 解析选择的路径（支持 .lnk 快捷方式、.exe 可执行文件、普通文件夹）
func ResolveMetaTraderDirectory(selectedPath string) (string, error) {
	if selectedPath == "" {
		return "", fmt.Errorf("empty path")
	}

	// 如果是 .lnk 快捷方式，用 PowerShell 解析真实目标
	if strings.ToLower(filepath.Ext(selectedPath)) == ".lnk" {
		target, err := resolveShortcut(selectedPath)
		if err == nil && target != "" {
			selectedPath = target
		}
	}

	fi, err := os.Stat(selectedPath)
	if err != nil {
		return "", err
	}

	if fi.IsDir() {
		return selectedPath, nil
	}

	// 如果是 terminal.exe 等文件，返回其所在目录
	return filepath.Dir(selectedPath), nil
}

// 解析 Windows .lnk 快捷方式真实路径
func resolveShortcut(lnkPath string) (string, error) {
	psScript := fmt.Sprintf(`$sh = New-Object -ComObject WScript.Shell; $target = $sh.CreateShortcut('%s').TargetPath; Write-Output $target`, strings.ReplaceAll(lnkPath, "'", "''"))
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", psScript)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// 扫描并获取所有关联的 MT 数据目录（包含选中目录本身，以及 %APPDATA%\MetaQuotes\Terminal\<Hash>\）
func FindAllMatchingTerminalDirs(installDir string) []string {
	var resultDirs []string
	cleanInstallDir := strings.ToLower(filepath.Clean(installDir))

	// 1. 安装目录本身
	resultDirs = append(resultDirs, installDir)

	// 2. 扫描 %APPDATA%\MetaQuotes\Terminal\
	appData := os.Getenv("APPDATA")
	if appData == "" {
		return resultDirs
	}

	terminalRoot := filepath.Join(appData, "MetaQuotes", "Terminal")
	entries, err := os.ReadDir(terminalRoot)
	if err != nil {
		return resultDirs
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		hashDir := filepath.Join(terminalRoot, entry.Name())
		originFile := filepath.Join(hashDir, "origin.txt")

		// 检查 origin.txt 是否匹配该安装路径
		if originData, err := os.ReadFile(originFile); err == nil {
			originPath := strings.ToLower(strings.TrimSpace(DecodeUtf16LE(originData)))
			if originPath == "" {
				originPath = strings.ToLower(strings.TrimSpace(string(originData)))
			}
			if strings.Contains(originPath, cleanInstallDir) || strings.Contains(cleanInstallDir, originPath) {
				resultDirs = append(resultDirs, hashDir)
				continue
			}
		}

		// 如果没有 origin.txt 但存在 config 且包含 servers.ini，也收录
		if _, err := os.Stat(filepath.Join(hashDir, "config", "servers.ini")); err == nil {
			resultDirs = append(resultDirs, hashDir)
		}
	}

	return resultDirs
}
