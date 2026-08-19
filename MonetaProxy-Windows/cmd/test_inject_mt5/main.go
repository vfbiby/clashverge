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
		filepath.Join(home, ".wine/drive_c/Program Files/MetaTrader 5/config"),
	}

	monetaServers, err := mtconfig.GetMonetaMT5Servers()
	if err != nil {
		fmt.Printf("获取 Moneta MT5 服务器列表失败: %v\n", err)
		return
	}

	fmt.Printf("准备注入 %d 个 Moneta MT5 服务器:\n", len(monetaServers))
	for i, s := range monetaServers {
		fmt.Printf("  [%d] %s (%s, 包含 %d 个接入点)\n", i+1, s.Info.ServerName, s.Info.CompanyName, len(s.Accesses))
	}

	for _, dir := range targetDirs {
		fmt.Printf("\n=== 开始注入目标目录: %s ===\n", dir)
		count, err := mtconfig.InjectMT5Directory(dir, monetaServers)
		if err != nil {
			fmt.Printf("❌ 注入失败: %v\n", err)
			continue
		}
		fmt.Printf("✅ 注入成功！已写入 %d 个服务器\n", count)

		// 验证回读
		datPath := filepath.Join(dir, "servers.dat")
		servers, header, err := mtconfig.ReadServersDat(datPath)
		if err != nil {
			fmt.Printf("❌ 回读验证失败: %v\n", err)
		} else {
			fmt.Printf("🔍 回读验证通过 (Header ID: %d): 当前 servers.dat 共包含 %d 个服务器\n", header.ID, len(servers))
			for j := 0; j < len(monetaServers) && j < len(servers); j++ {
				fmt.Printf("   -> 置顶服务器[%d]: %s (%s, 接入组数: %d, 默认地址: %s)\n",
					j+1, servers[j].Info.ServerName, servers[j].Info.CompanyName, len(servers[j].Accesses), servers[j].Info.Address)
				for k, acc := range servers[j].Accesses {
					if k < 2 {
						fmt.Printf("        - 接入点[%d]: %s -> %v\n", k+1, acc.Name, acc.Addresses)
					}
				}
			}
		}
	}
}
