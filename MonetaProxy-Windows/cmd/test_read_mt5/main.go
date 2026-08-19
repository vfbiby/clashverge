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
		filepath.Join(home, ".wine/drive_c/Program Files/MetaTrader 5/config/servers.dat"),
		filepath.Join(home, ".wine/drive_c/Program Files/MetaTrader 5/Bases/servers.dat"),
	}

	for _, p := range testPaths {
		fmt.Printf("=== 测试读取 MT5: %s ===\n", p)
		if _, err := os.Stat(p); err != nil {
			fmt.Printf("文件不存在: %v\n", err)
			continue
		}

		servers, header, err := mtconfig.ReadServersDat(p)
		if err != nil {
			fmt.Printf("读取失败: %v\n", err)
			continue
		}

		fmt.Printf("成功解析到 Header Id: %d, Copyright: %s, 共 %d 个服务器:\n", header.ID, header.Copyright, len(servers))
		for i, srv := range servers {
			fmt.Printf("  [%d] 名称: %s, 公司: %s, 接入组数: %d, 地址: %s\n",
				i+1, srv.Info.ServerName, srv.Info.CompanyName, len(srv.Accesses), srv.Info.Address)
			for j, acc := range srv.Accesses {
				fmt.Printf("      - 接入组[%d] 地址数: %d\n", j+1, len(acc.Addresses))
				for k, addr := range acc.Addresses {
					if k < 2 {
						fmt.Printf("          -> 地址: %s\n", addr.S4)
					}
				}
			}
		}
	}
}
