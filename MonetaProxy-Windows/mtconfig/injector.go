package mtconfig

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// 向指定 MT4 config 目录注入 Moneta 服务器
func InjectMT4Directory(configDir string, monetaServers []*MT4ServerEntry) (int, error) {
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return 0, err
	}

	// 1. 为每个 Moneta 服务器写入独立的 .srv 文件
	for _, entry := range monetaServers {
		srvFileName := ValidFileName(entry.Main.Name) + ".srv"
		srvPath := filepath.Join(configDir, srvFileName)
		if err := WriteSrvFile(srvPath, entry.Main, entry.Accesses); err != nil {
			return 0, fmt.Errorf("failed to write %s: %w", srvFileName, err)
		}
	}

	// 2. 读取现有的 servers.ini (追加合并 Upsert)
	iniPath := filepath.Join(configDir, "servers.ini")
	existingEntries, err := ReadServersIni(iniPath)
	if err != nil {
		// 如果原文件不存在或损坏，直接使用 Moneta 列表创建
		existingEntries = []*MT4ServerEntry{}
	}

	// 合并逻辑：构建 Map
	existingMap := make(map[string]int)
	for idx, entry := range existingEntries {
		key := strings.ToLower(strings.TrimSpace(entry.Main.Name))
		existingMap[key] = idx
	}

	var mergedEntries []*MT4ServerEntry
	injectedCount := 0

	// 优先插入/更新 Moneta 服务器
	for _, moneta := range monetaServers {
		key := strings.ToLower(strings.TrimSpace(moneta.Main.Name))
		if idx, exists := existingMap[key]; exists {
			// 更新已有
			existingEntries[idx].Main.Comment = moneta.Main.Comment
			existingEntries[idx].Main.IsDemo = moneta.Main.IsDemo
			existingEntries[idx].Accesses = moneta.Accesses
			existingEntries[idx].Main.Count = int32(len(moneta.Accesses))
			if len(moneta.Accesses) > 0 {
				existingEntries[idx].Main.HostAddr = moneta.Accesses[0].Server
			}
		} else {
			// 新增置顶
			mergedEntries = append(mergedEntries, moneta)
			injectedCount++
		}
	}

	// 追加其余原有券商
	mergedEntries = append(mergedEntries, existingEntries...)

	// 写入新的 servers.ini
	if err := WriteServersIni(iniPath, mergedEntries); err != nil {
		return 0, fmt.Errorf("failed to write servers.ini: %w", err)
	}

	return len(monetaServers), nil
}
