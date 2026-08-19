package main

import (
	"fmt"
	"os"
	"path/filepath"

	"monetaproxy-windows/mtconfig"
)

func main() {
	home, _ := os.UserHomeDir()
	targetDirs := []string{
		filepath.Join(home, ".wine/drive_c/Program Files (x86)/MetaTrader 4/config"),
		filepath.Join(home, ".wine/drive_c/users/zhangsike/AppData/Roaming/MetaQuotes/Terminal/50CA3DFB510CC5A8F28B48D1BF2A5702/config"),
	}

	monetaServers, err := mtconfig.GetMonetaMT4Servers()
	if err != nil {
		fmt.Printf("获取 Moneta MT4 服务器列表失败: %v\n", err)
		return
	}

	fmt.Printf("准备注入 %d 个 Moneta MT4 服务器:\n", len(monetaServers))
	for i, s := range monetaServers {
		fmt.Printf("  [%d] %s (%s, 包含 %d 个接入点)\n", i+1, s.Main.Name, s.Main.Comment, len(s.Accesses))
	}

	for _, dir := range targetDirs {
		fmt.Printf("\n=== 开始注入目标目录: %s ===\n", dir)
		count, err := mtconfig.InjectMT4Directory(dir, monetaServers)
		if err != nil {
			fmt.Printf("❌ 注入失败: %v\n", err)
			continue
		}
		fmt.Printf("✅ 注入成功！已将 %d 个服务器配置写入并更新 servers.ini\n", count)

		// 验证回读
		iniPath := filepath.Join(dir, "servers.ini")
		entries, err := mtconfig.ReadServersIni(iniPath)
		if err != nil {
			fmt.Printf("❌ 回读验证失败: %v\n", err)
		} else {
			fmt.Printf("🔍 回读验证通过: 当前 servers.ini 共包含 %d 个服务器\n", len(entries))
			for j := 0; j < len(monetaServers) && j < len(entries); j++ {
				fmt.Printf("   -> 置顶服务器[%d]: %s (接入点数: %d)\n", j+1, entries[j].Main.Name, len(entries[j].Accesses))
			}
		}
	}
}
