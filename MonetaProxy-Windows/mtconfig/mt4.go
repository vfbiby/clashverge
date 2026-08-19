package mtconfig

import (
	"bytes"
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// MT4 主服务器结构 (352 字节)
type MT4MainServer struct {
	Name          string    // 64 字节 ANSI
	Comment       string    // 128 字节 ANSI
	IsDemo        int32     // 4 字节
	Ping          int32     // 4 字节
	DummyC8       int32     // 4 字节
	DummyCC       int32     // 4 字节
	PtrDataserver int32     // 4 字节
	Count         int32     // 4 字节 (接入点数量)
	HostAddr      string    // 64 字节 ANSI
	Time          int32     // 4 字节
	Dummy11C      [16]int32 // 64 字节
	PtrNext       int32     // 4 字节
}

// MT4 接入点结构 (160 字节)
type MT4ServerAccess struct {
	Server     string // 64 字节 ANSI (如 "18.163.170.234:443" 或 "nlb.xxx.com:443")
	IP         int32  // 4 字节
	Desc       string // 64 字节 ANSI
	IsProxy    int32  // 4 字节
	Priority   int32  // 4 字节
	Loading    int32  // 4 字节
	IPInternal int32  // 4 字节
	Ping       int32  // 4 字节
	Reserved   int32  // 4 字节
	PtrNext    int32  // 4 字节
}

// MT4 组合实体
type MT4ServerEntry struct {
	Main     *MT4MainServer
	Accesses []*MT4ServerAccess
}

const (
	MT4MainServerSize = 352
	MT4ServerSize     = 160
	MT4IniHeaderSize  = 428
)

// 默认 428 字节 servers.ini 头部模板
var MT4DefaultIniHeader = []byte{
	145, 1, 0, 0, 67, 0, 111, 0, 112, 0,
	121, 0, 114, 0, 105, 0, 103, 0, 104, 0,
	116, 0, 32, 0, 50, 0, 48, 0, 48, 0,
	48, 0, 45, 0, 50, 0, 48, 0, 50, 0,
	53, 0, 44, 0, 32, 0, 77, 0, 101, 0,
	116, 0, 97, 0, 81, 0, 117, 0, 111, 0,
	116, 0, 101, 0, 115, 0, 32, 0, 76, 0,
	116, 0, 100, 0, 46, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 83, 0, 101, 0, 114, 0, 118, 0,
	101, 0, 114, 0, 115, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 42, 0, 0, 0, 101, 177, 249, 72,
	211, 0, 131, 135, 190, 132, 103, 207, 80, 206,
	192, 90, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
}

// 序列化 MainServer (352 字节)
func (m *MT4MainServer) Serialize() []byte {
	buf := make([]byte, MT4MainServerSize)
	copy(buf[0:64], []byte(m.Name))
	copy(buf[64:192], []byte(m.Comment))
	PutLeInt32(buf[192:196], m.IsDemo)
	PutLeInt32(buf[196:200], m.Ping)
	PutLeInt32(buf[200:204], m.DummyC8)
	PutLeInt32(buf[204:208], m.DummyCC)
	PutLeInt32(buf[208:212], m.PtrDataserver)
	PutLeInt32(buf[212:216], m.Count)
	copy(buf[216:280], []byte(m.HostAddr))
	PutLeInt32(buf[280:284], m.Time)
	for i := 0; i < 16; i++ {
		PutLeInt32(buf[284+i*4:288+i*4], m.Dummy11C[i])
	}
	PutLeInt32(buf[348:352], m.PtrNext)
	return buf
}

// 反序列化 MainServer (352 字节)
func DeserializeMT4MainServer(buf []byte) (*MT4MainServer, error) {
	if len(buf) < MT4MainServerSize {
		return nil, fmt.Errorf("buffer too small for MT4MainServer: %d < %d", len(buf), MT4MainServerSize)
	}
	m := &MT4MainServer{
		Name:          cString(buf[0:64]),
		Comment:       cString(buf[64:192]),
		IsDemo:        LeInt32(buf[192:196]),
		Ping:          LeInt32(buf[196:200]),
		DummyC8:       LeInt32(buf[200:204]),
		DummyCC:       LeInt32(buf[204:208]),
		PtrDataserver: LeInt32(buf[208:212]),
		Count:         LeInt32(buf[212:216]),
		HostAddr:      cString(buf[216:280]),
		Time:          LeInt32(buf[280:284]),
		PtrNext:       LeInt32(buf[348:352]),
	}
	for i := 0; i < 16; i++ {
		m.Dummy11C[i] = LeInt32(buf[284+i*4 : 288+i*4])
	}
	return m, nil
}

// 序列化 Server 接入点 (160 字节)
func (s *MT4ServerAccess) Serialize() []byte {
	buf := make([]byte, MT4ServerSize)
	copy(buf[0:64], []byte(s.Server))
	PutLeInt32(buf[64:68], s.IP)
	copy(buf[68:132], []byte(s.Desc))
	PutLeInt32(buf[132:136], s.IsProxy)
	PutLeInt32(buf[136:140], s.Priority)
	PutLeInt32(buf[140:144], s.Loading)
	PutLeInt32(buf[144:148], s.IPInternal)
	PutLeInt32(buf[148:152], s.Ping)
	PutLeInt32(buf[152:156], s.Reserved)
	PutLeInt32(buf[156:160], s.PtrNext)
	return buf
}

// 反序列化 Server 接入点 (160 字节)
func DeserializeMT4ServerAccess(buf []byte) (*MT4ServerAccess, error) {
	if len(buf) < MT4ServerSize {
		return nil, fmt.Errorf("buffer too small for MT4ServerAccess: %d < %d", len(buf), MT4ServerSize)
	}
	return &MT4ServerAccess{
		Server:     cString(buf[0:64]),
		IP:         LeInt32(buf[64:68]),
		Desc:       cString(buf[68:132]),
		IsProxy:    LeInt32(buf[132:136]),
		Priority:   LeInt32(buf[136:140]),
		Loading:    LeInt32(buf[140:144]),
		IPInternal: LeInt32(buf[144:148]),
		Ping:       LeInt32(buf[148:152]),
		Reserved:   LeInt32(buf[152:156]),
		PtrNext:    LeInt32(buf[156:160]),
	}, nil
}

// 读取 .srv 单个服务器文件
func ReadSrvFile(filePath string) (*MT4MainServer, []*MT4ServerAccess, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return nil, nil, err
	}
	if len(data) < MT4MainServerSize {
		return nil, nil, fmt.Errorf("invalid srv file size: %d", len(data))
	}

	mainSrv, err := DeserializeMT4MainServer(data[:MT4MainServerSize])
	if err != nil {
		return nil, nil, err
	}

	accesses := make([]*MT4ServerAccess, 0, mainSrv.Count)
	if mainSrv.Count > 0 {
		rawAccesses := data[MT4MainServerSize:]
		decrypted := MT4Decrypt(rawAccesses, nil)
		for i := 0; i < int(mainSrv.Count) && (i+1)*MT4ServerSize <= len(decrypted); i++ {
			chunk := decrypted[i*MT4ServerSize : (i+1)*MT4ServerSize]
			acc, err := DeserializeMT4ServerAccess(chunk)
			if err == nil {
				accesses = append(accesses, acc)
			}
		}
	}
	return mainSrv, accesses, nil
}

// 写入 .srv 单个服务器文件
func WriteSrvFile(filePath string, mainSrv *MT4MainServer, accesses []*MT4ServerAccess) error {
	mainSrv.Count = int32(len(accesses))
	if mainSrv.HostAddr == "" && len(accesses) > 0 {
		mainSrv.HostAddr = accesses[0].Server
	}

	var buf bytes.Buffer
	buf.Write(mainSrv.Serialize())

	var accessBuf bytes.Buffer
	for _, acc := range accesses {
		accessBuf.Write(acc.Serialize())
	}

	if accessBuf.Len() > 0 {
		encrypted := MT4Encrypt(accessBuf.Bytes(), nil)
		buf.Write(encrypted)
	}

	_ = os.MkdirAll(filepath.Dir(filePath), 0755)
	return os.WriteFile(filePath, buf.Bytes(), 0644)
}

// 读取 servers.ini 总表文件
func ReadServersIni(filePath string) ([]*MT4ServerEntry, error) {
	buf, err := os.ReadFile(filePath)
	if err != nil {
		return nil, err
	}
	if len(buf) < MT4IniHeaderSize {
		return nil, fmt.Errorf("servers.ini too small: %d < %d", len(buf), MT4IniHeaderSize)
	}

	// 提取动态 16 字节密钥
	key := make([]byte, 16)
	copy(key, buf[176:192])

	var entries []*MT4ServerEntry
	offset := MT4IniHeaderSize

	for offset+MT4MainServerSize <= len(buf) {
		// 1. 解密 MainServer (352 字节)
		encMain := buf[offset : offset+MT4MainServerSize]
		offset += MT4MainServerSize

		decMain := MT4Decrypt(encMain, key)
		mainSrv, err := DeserializeMT4MainServer(decMain)
		if err != nil || mainSrv.Count < 0 || mainSrv.Count > 256 {
			break
		}

		// 2. 解密 Server 接入点数组
		accessLen := int(mainSrv.Count) * MT4ServerSize
		if offset+accessLen > len(buf) {
			break
		}

		encAccess := buf[offset : offset+accessLen]
		offset += accessLen

		decAccess := MT4Decrypt(encAccess, key)
		accesses := make([]*MT4ServerAccess, 0, mainSrv.Count)
		for i := 0; i < int(mainSrv.Count); i++ {
			chunk := decAccess[i*MT4ServerSize : (i+1)*MT4ServerSize]
			acc, err := DeserializeMT4ServerAccess(chunk)
			if err == nil {
				accesses = append(accesses, acc)
			}
		}

		entries = append(entries, &MT4ServerEntry{
			Main:     mainSrv,
			Accesses: accesses,
		})
	}

	return entries, nil
}

// 写入 / 重建 servers.ini 总表文件
func WriteServersIni(filePath string, entries []*MT4ServerEntry) error {
	header := make([]byte, MT4IniHeaderSize)
	copy(header, MT4DefaultIniHeader)

	// 生成随机 16 字节密钥
	key := make([]byte, 16)
	_, _ = rand.Read(key)
	copy(header[176:192], key)

	var out bytes.Buffer
	out.Write(header)

	for _, entry := range entries {
		entry.Main.Count = int32(len(entry.Accesses))
		if entry.Main.HostAddr == "" && len(entry.Accesses) > 0 {
			entry.Main.HostAddr = entry.Accesses[0].Server
		}

		// 1. 加密 MainServer
		rawMain := entry.Main.Serialize()
		encMain := MT4Encrypt(rawMain, key)
		out.Write(encMain)

		// 2. 加密 Server 接入点
		var accBuf bytes.Buffer
		for _, acc := range entry.Accesses {
			accBuf.Write(acc.Serialize())
		}
		if accBuf.Len() > 0 {
			encAccess := MT4Encrypt(accBuf.Bytes(), key)
			out.Write(encAccess)
		}
	}

	_ = os.MkdirAll(filepath.Dir(filePath), 0755)
	return os.WriteFile(filePath, out.Bytes(), 0644)
}

// 辅助：解析 C 风格以 \0 结尾的 ANSI 字符串
func cString(b []byte) string {
	idx := bytes.IndexByte(b, 0)
	if idx == -1 {
		return string(b)
	}
	return string(b[:idx])
}

// 辅助：格式化合法文件名
func ValidFileName(s string) string {
	for _, char := range []string{"/", "\\", ":", "*", "?", "\"", "<", ">", "|"} {
		s = strings.ReplaceAll(s, char, "_")
	}
	return strings.TrimSpace(s)
}
