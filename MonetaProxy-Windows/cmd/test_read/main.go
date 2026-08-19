package main

import (
	"fmt"
	"os"
	"path/filepath"

	"monetaproxy-windows/mtconfig"
)

func main() {
	home, _ := os.UserHomeDir()
	testPaths := []string{
		filepath.Join(home, ".wine/drive_c/Program Files (x86)/MetaTrader 4/config/servers.ini"),
		filepath.Join(home, ".wine/drive_c/users/zhangsike/AppData/Roaming/MetaQuotes/Terminal/50CA3DFB510CC5A8F28B48D1BF2A5702/config/servers.ini"),
	}

	for _, p := range testPaths {
		fmt.Printf("=== 测试读取: %s ===\n", p)
		if _, err := os.Stat(p); err != nil {
			fmt.Printf("文件不存在: %v\n", err)
			continue
		}

		entries, err := mtconfig.ReadServersIni(p)
		if err != nil {
			fmt.Printf("读取失败: %v\n", err)
			continue
		}

		fmt.Printf("成功解析到 %d 个服务器:\n", len(entries))
		for i, entry := range entries {
			fmt.Printf("  [%d] 名称: %s, 注释: %s, 接入点数量: %d, 默认主机: %s\n",
				i+1, entry.Main.Name, entry.Main.Comment, len(entry.Accesses), entry.Main.HostAddr)
			for j, acc := range entry.Accesses {
				if j < 3 {
					fmt.Printf("      - 接入点[%d]: %s (描述: %s, IP: %d)\n", j+1, acc.Server, acc.Desc, acc.IP)
				}
			}
			if len(entry.Accesses) > 3 {
				fmt.Printf("      - ... 共有 %d 个接入点\n", len(entry.Accesses))
			}
		}
	}
}
