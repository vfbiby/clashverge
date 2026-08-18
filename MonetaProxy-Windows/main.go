package main

import (
	_ "embed"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"syscall"

	"github.com/energye/systray"
	"golang.org/x/sys/windows/registry"
)

//go:embed embedded/sing-box.exe
var singBoxExe []byte

//go:embed embedded/config.json
var configFile []byte

//go:embed embedded/icon.ico
var iconData []byte

const (
	ProxyAddr     = "127.0.0.1:7891"
	TargetWebsite = "https://monetamarket.com"
	AppName       = "MonetaProxy"
	AppTitle      = "MonetaProxy - 单站点专用代理"
)

var (
	modwininet            = syscall.NewLazyDLL("wininet.dll")
	procInternetSetOption = modwininet.NewProc("InternetSetOptionW")

	mu         sync.Mutex
	proxyCmd   *exec.Cmd
	proxyState = true // default enabled
)

func main() {
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetIcon(iconData)
	systray.SetTitle(AppName)
	systray.SetTooltip(AppTitle)

	// 1. 释放并启动 sing-box 核心
	if err := startCore(); err != nil {
		fmt.Printf("启动核心失败: %v\n", err)
	}

	// 2. 默认开启系统代理
	setSystemProxy(true)

	// 3. 构建右键菜单
	mStatus := systray.AddMenuItem("🟢 代理状态：已连接 (127.0.0.1:7891)", "当前代理状态")
	mStatus.Disable()

	mToggle := systray.AddMenuItem("⏸ 暂停代理（直连）", "切换系统代理开关")
	systray.AddSeparator()

	mOpen := systray.AddMenuItem("🌐 打开 Moneta 官网", "在默认浏览器中打开目标网站")
	systray.AddSeparator()

	isAuto := checkAutoStart()
	mAutoStart := systray.AddMenuItemCheckbox("🔄 开机自动启动", "开机时自动在后台启动", isAuto)
	systray.AddSeparator()

	mExit := systray.AddMenuItem("❌ 退出程序", "关闭代理并退出")

	// 事件监听
	mToggle.Click(func() {
		mu.Lock()
		defer mu.Unlock()
		proxyState = !proxyState
		if proxyState {
			setSystemProxy(true)
			mStatus.SetTitle("🟢 代理状态：已连接 (127.0.0.1:7891)")
			mToggle.SetTitle("⏸ 暂停代理（直连）")
			systray.SetTooltip("MonetaProxy - 代理已连接")
		} else {
			setSystemProxy(false)
			mStatus.SetTitle("⚪ 代理状态：已暂停（直连）")
			mToggle.SetTitle("▶️ 启用代理")
			systray.SetTooltip("MonetaProxy - 代理已暂停")
		}
	})

	mOpen.Click(func() {
		openBrowser(TargetWebsite)
	})

	mAutoStart.Click(func() {
		if mAutoStart.Checked() {
			setAutoStart(false)
			mAutoStart.Uncheck()
		} else {
			setAutoStart(true)
			mAutoStart.Check()
		}
	})

	mExit.Click(func() {
		systray.Quit()
	})
}

func onExit() {
	// 退出时恢复网络、杀死后台核心
	setSystemProxy(false)
	stopCore()
}

// 释放并启动 sing-box
func startCore() error {
	mu.Lock()
	defer mu.Unlock()

	appDir := filepath.Join(os.Getenv("LOCALAPPDATA"), "MonetaProxy")
	_ = os.MkdirAll(appDir, 0755)

	exePath := filepath.Join(appDir, "sing-box.exe")
	cfgPath := filepath.Join(appDir, "config.json")

	// 写入二进制及配置
	_ = os.WriteFile(exePath, singBoxExe, 0755)
	_ = os.WriteFile(cfgPath, configFile, 0644)

	// 后台无窗口启动
	cmd := exec.Command(exePath, "run", "-c", cfgPath)
	cmd.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: 0x08000000, // CREATE_NO_WINDOW
	}

	if err := cmd.Start(); err != nil {
		return err
	}

	proxyCmd = cmd
	return nil
}

func stopCore() {
	mu.Lock()
	defer mu.Unlock()

	if proxyCmd != nil && proxyCmd.Process != nil {
		_ = proxyCmd.Process.Kill()
		proxyCmd = nil
	}
}

// 设置 Windows 系统代理
func setSystemProxy(enable bool) {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Internet Settings`, registry.SET_VALUE)
	if err != nil {
		return
	}
	defer k.Close()

	if enable {
		_ = k.SetDWordValue("ProxyEnable", 1)
		_ = k.SetStringValue("ProxyServer", ProxyAddr)
		_ = k.SetStringValue("ProxyOverride", "<local>;localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*")
	} else {
		_ = k.SetDWordValue("ProxyEnable", 0)
	}

	// 立即刷新 WinINet 选项（无需重启浏览器即生效）
	const (
		INTERNET_OPTION_SETTINGS_CHANGED = 39
		INTERNET_OPTION_REFRESH          = 37
	)
	procInternetSetOption.Call(0, uintptr(INTERNET_OPTION_SETTINGS_CHANGED), 0, 0)
	procInternetSetOption.Call(0, uintptr(INTERNET_OPTION_REFRESH), 0, 0)
}

func openBrowser(url string) {
	exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
}

func checkAutoStart() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()

	_, _, err = k.GetStringValue(AppName)
	return err == nil
}

func setAutoStart(enable bool) {
	k, err := registry.OpenKey(registry.CURRENT_USER, `Software\Microsoft\Windows\CurrentVersion\Run`, registry.SET_VALUE)
	if err != nil {
		return
	}
	defer k.Close()

	if enable {
		exePath, err := os.Executable()
		if err == nil {
			_ = k.SetStringValue(AppName, fmt.Sprintf("\"%s\"", exePath))
		}
	} else {
		_ = k.DeleteValue(AppName)
	}
}
