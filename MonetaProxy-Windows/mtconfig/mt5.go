package mtconfig

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf16"
)

const (
	MT5DatHeaderSize    = 428
	MT5ServerInfoExSize = 1716
	MT5AccessRecSize    = 356
	MT5AddressRecSize   = 148
	MT5AccessRecExSize  = 3160
	MT5AddressRecExSize = 1284
)

// MT5 servers.dat 头部结构 (428 字节)
type MT5DatHeader struct {
	ID        uint32 // 505 或 506
	Copyright string // 128 字节 UTF-16LE ("Copyright 2000-2025, MetaQuotes Ltd.")
	DataType  string // 32 字节 UTF-16LE ("Servers")
	FileTime  int64  // 8 字节
	ObjNumber int32  // 4 字节
	Md5Key    [16]byte
	SC0       [228]byte
	S1A4      int32
	S1A8      int32
}

// MT5 服务器元信息 (1716 字节)
type MT5ServerInfoEx struct {
	ServerName  string // 128 字节 UTF-16LE
	CompanyName string // 256 字节 UTF-16LE
	S180        int32
	S184        int32
	DST         int32
	TimeZone    int32
	S190        int32
	Address     string // 128 字节 UTF-16LE
	PingTime    int32
	S218        int32
	S21C        int32
	S220        [116]byte
	S294        int32
	S298        int32
	S29C        int64
	S2A4        int64
	CompanyLink string // 512 字节 UTF-16LE
	S4AC        string // 512 字节 UTF-16LE
	S6AC        int64
}

// MT5 接入点组 (标准 MT5 AccessRec 结构: 356 字节)
type MT5Access struct {
	Name      string   // 64 字节 UTF-16LE (如 "AS01", "Access Point 1")
	Addresses []string // 接入点地址列表 (128 字节 UTF-16LE, 如 "18.162.222.24:443")
}

// MT5 整体 Server 对象
type MT5Server struct {
	Info     *MT5ServerInfoEx
	Accesses []*MT5Access
}

// 辅助：UTF-16LE 编解码
func EncodeUtf16LE(str string, fixedSize int) []byte {
	u16 := utf16.Encode([]rune(str))
	buf := make([]byte, fixedSize)
	maxRunes := (fixedSize - 2) / 2
	if len(u16) > maxRunes {
		u16 = u16[:maxRunes]
	}
	for i, r := range u16 {
		binary.LittleEndian.PutUint16(buf[i*2:i*2+2], r)
	}
	return buf
}

func DecodeUtf16LE(b []byte) string {
	u16 := make([]uint16, 0, len(b)/2)
	for i := 0; i+1 < len(b); i += 2 {
		val := binary.LittleEndian.Uint16(b[i : i+2])
		if val == 0 {
			break
		}
		u16 = append(u16, val)
	}
	return string(utf16.Decode(u16))
}

// 序列化 DatHeader (428 字节)
func (h *MT5DatHeader) Serialize() []byte {
	buf := make([]byte, MT5DatHeaderSize)
	PutLeUint32(buf[0:4], h.ID)
	copy(buf[4:132], EncodeUtf16LE(h.Copyright, 128))
	copy(buf[132:164], EncodeUtf16LE(h.DataType, 32))
	PutLeInt64(buf[164:172], h.FileTime)
	PutLeInt32(buf[172:176], h.ObjNumber)
	copy(buf[176:192], h.Md5Key[:])
	copy(buf[192:420], h.SC0[:])
	PutLeInt32(buf[420:424], h.S1A4)
	PutLeInt32(buf[424:428], h.S1A8)
	return buf
}

// 反序列化 DatHeader
func DeserializeMT5DatHeader(buf []byte) (*MT5DatHeader, error) {
	if len(buf) < MT5DatHeaderSize {
		return nil, fmt.Errorf("buffer too small for DatHeader: %d < %d", len(buf), MT5DatHeaderSize)
	}
	h := &MT5DatHeader{
		ID:        LeUint32(buf[0:4]),
		Copyright: DecodeUtf16LE(buf[4:132]),
		DataType:  DecodeUtf16LE(buf[132:164]),
		FileTime:  LeInt64(buf[164:172]),
		ObjNumber: LeInt32(buf[172:176]),
		S1A4:      LeInt32(buf[420:424]),
		S1A8:      LeInt32(buf[424:428]),
	}
	copy(h.Md5Key[:], buf[176:192])
	copy(h.SC0[:], buf[192:420])
	return h, nil
}

// 序列化 ServerInfoEx (1716 字节加密)
func (s *MT5ServerInfoEx) SerializeEncrypted() []byte {
	buf := make([]byte, MT5ServerInfoExSize)
	copy(buf[0:128], EncodeUtf16LE(s.ServerName, 128))
	copy(buf[128:384], EncodeUtf16LE(s.CompanyName, 256))
	PutLeInt32(buf[384:388], s.S180)
	PutLeInt32(buf[388:392], s.S184)
	PutLeInt32(buf[392:396], s.DST)
	PutLeInt32(buf[396:400], s.TimeZone)
	PutLeInt32(buf[400:404], s.S190)
	copy(buf[404:532], EncodeUtf16LE(s.Address, 128))
	PutLeInt32(buf[532:536], s.PingTime)
	PutLeInt32(buf[536:540], s.S218)
	PutLeInt32(buf[540:544], s.S21C)
	copy(buf[544:660], s.S220[:])
	PutLeInt32(buf[660:664], s.S294)
	PutLeInt32(buf[664:668], s.S298)
	PutLeInt64(buf[668:676], s.S29C)
	PutLeInt64(buf[676:684], s.S2A4)
	copy(buf[684:1196], EncodeUtf16LE(s.CompanyLink, 512))
	copy(buf[1196:1708], EncodeUtf16LE(s.S4AC, 512))
	PutLeInt64(buf[1708:1716], s.S6AC)

	return MT5EasyCrypt(buf)
}

// 反序列化 ServerInfoEx
func DeserializeMT5ServerInfoEx(rawDecrypted []byte) (*MT5ServerInfoEx, error) {
	if len(rawDecrypted) < MT5ServerInfoExSize {
		return nil, fmt.Errorf("buffer too small for ServerInfoEx: %d < %d", len(rawDecrypted), MT5ServerInfoExSize)
	}
	s := &MT5ServerInfoEx{
		ServerName:  DecodeUtf16LE(rawDecrypted[0:128]),
		CompanyName: DecodeUtf16LE(rawDecrypted[128:384]),
		S180:        LeInt32(rawDecrypted[384:388]),
		S184:        LeInt32(rawDecrypted[388:392]),
		DST:         LeInt32(rawDecrypted[392:396]),
		TimeZone:    LeInt32(rawDecrypted[396:400]),
		S190:        LeInt32(rawDecrypted[400:404]),
		Address:     DecodeUtf16LE(rawDecrypted[404:532]),
		PingTime:    LeInt32(rawDecrypted[532:536]),
		S218:        LeInt32(rawDecrypted[536:540]),
		S21C:        LeInt32(rawDecrypted[540:544]),
		S294:        LeInt32(rawDecrypted[660:664]),
		S298:        LeInt32(rawDecrypted[664:668]),
		S29C:        LeInt64(rawDecrypted[668:676]),
		S2A4:        LeInt64(rawDecrypted[676:684]),
		CompanyLink: DecodeUtf16LE(rawDecrypted[684:1196]),
		S4AC:        DecodeUtf16LE(rawDecrypted[1196:1708]),
		S6AC:        LeInt64(rawDecrypted[1708:1716]),
	}
	copy(s.S220[:], rawDecrypted[544:660])
	return s, nil
}

// 序列化 AccessRec (356 字节加密)
func SerializeAccessRec(name string) []byte {
	buf := make([]byte, MT5AccessRecSize)
	copy(buf[0:64], EncodeUtf16LE(name, 64))
	PutLeInt32(buf[196:200], 2177) // sC4 默认值 2177
	return MT5EasyCrypt(buf)
}

// 序列化 AddressRec (148 字节加密)
func SerializeAddressRec(addr string) []byte {
	buf := make([]byte, MT5AddressRecSize)
	copy(buf[0:128], EncodeUtf16LE(addr, 128))
	return MT5EasyCrypt(buf)
}

// 读取 servers.dat 文件
func ReadServersDat(filePath string) ([]*MT5Server, *MT5DatHeader, error) {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return nil, nil, err
	}
	if len(data) < MT5DatHeaderSize {
		return nil, nil, fmt.Errorf("servers.dat too small: %d < %d", len(data), MT5DatHeaderSize)
	}

	header, err := DeserializeMT5DatHeader(data[:MT5DatHeaderSize])
	if err != nil {
		return nil, nil, err
	}

	offset := MT5DatHeaderSize
	var servers []*MT5Server

	for offset < len(data) {
		if offset+MT5ServerInfoExSize > len(data) {
			break
		}

		// 1. 解密 ServerInfoEx
		encInfo := make([]byte, MT5ServerInfoExSize)
		copy(encInfo, data[offset:offset+MT5ServerInfoExSize])
		offset += MT5ServerInfoExSize

		decInfo := MT5EasyDecrypt(encInfo)
		info, err := DeserializeMT5ServerInfoEx(decInfo)
		if err != nil || info.ServerName == "" {
			break
		}

		server := &MT5Server{
			Info: info,
		}

		// 2. 读取 Accesses (标准 MT5 AccessRec: 356B + AddressRec: 148B)
		if offset+4 > len(data) {
			break
		}
		accCount := LeInt32(data[offset : offset+4])
		offset += 4

		if accCount > 0 && accCount <= 128 {
			server.Accesses = make([]*MT5Access, 0, accCount)
			for i := 0; i < int(accCount); i++ {
				if offset+MT5AccessRecSize > len(data) {
					break
				}
				encAcc := make([]byte, MT5AccessRecSize)
				copy(encAcc, data[offset:offset+MT5AccessRecSize])
				offset += MT5AccessRecSize

				decAcc := MT5EasyDecrypt(encAcc)
				accName := DecodeUtf16LE(decAcc[0:64])

				if offset+4 > len(data) {
					break
				}
				addrCount := LeInt32(data[offset : offset+4])
				offset += 4

				var addrs []string
				if addrCount > 0 && addrCount <= 128 {
					for j := 0; j < int(addrCount); j++ {
						if offset+MT5AddressRecSize > len(data) {
							break
						}
						encAddr := make([]byte, MT5AddressRecSize)
						copy(encAddr, data[offset:offset+MT5AddressRecSize])
						offset += MT5AddressRecSize

						decAddr := MT5EasyDecrypt(encAddr)
						addrStr := DecodeUtf16LE(decAddr[0:128])
						if addrStr != "" {
							addrs = append(addrs, addrStr)
						}
					}
				}
				server.Accesses = append(server.Accesses, &MT5Access{
					Name:      accName,
					Addresses: addrs,
				})
			}
		}

		// 3. 读取 AccessesEx 数量并跳过
		if offset+4 > len(data) {
			break
		}
		accExCount := LeInt32(data[offset : offset+4])
		offset += 4

		if accExCount > 0 && accExCount <= 128 {
			for i := 0; i < int(accExCount); i++ {
				if offset+MT5AccessRecExSize > len(data) {
					break
				}
				offset += MT5AccessRecExSize

				if offset+4 > len(data) {
					break
				}
				addrCount := LeInt32(data[offset : offset+4])
				offset += 4
				if addrCount > 0 && addrCount <= 128 {
					offset += int(addrCount) * MT5AddressRecExSize
				}
			}
		}

		servers = append(servers, server)
	}

	return servers, header, nil
}

// 写入 / 保存 servers.dat 文件
func SaveServersDat(filePath string, servers []*MT5Server, header *MT5DatHeader) error {
	if header == nil {
		header = &MT5DatHeader{
			ID:        506,
			Copyright: "Copyright 2000-2025, MetaQuotes Ltd.",
			DataType:  "Servers",
		}
	}
	header.ObjNumber = int32(len(servers))

	var out bytes.Buffer
	out.Write(header.Serialize())

	for _, srv := range servers {
		// 1. 写入加密 ServerInfoEx (1716 字节)
		out.Write(srv.Info.SerializeEncrypted())

		// 2. 写入 Accesses 数量
		numBuf := make([]byte, 4)
		PutLeInt32(numBuf, int32(len(srv.Accesses)))
		out.Write(numBuf)

		// 写入每一个 Access (356B + addrs)
		for _, acc := range srv.Accesses {
			out.Write(SerializeAccessRec(acc.Name))

			// 写入 Addresses 数量
			PutLeInt32(numBuf, int32(len(acc.Addresses)))
			out.Write(numBuf)

			// 写入每一个 AddressRec (148B)
			for _, addr := range acc.Addresses {
				out.Write(SerializeAddressRec(addr))
			}
		}

		// 3. 写入 AccessesEx 数量 (0)
		PutLeInt32(numBuf, 0)
		out.Write(numBuf)
	}

	_ = os.MkdirAll(filepath.Dir(filePath), 0755)
	return os.WriteFile(filePath, out.Bytes(), 0644)
}

// 将 JSON 数据转换为 MT5Server 结构体列表
func ConvertRawToMT5(rawList []ServerGroupRaw) []*MT5Server {
	var servers []*MT5Server
	for _, item := range rawList {
		var accesses []*MT5Access
		var allAddrs []string

		for i, n := range item.Nodes {
			addr := n.ResolvedIP
			if addr == "" {
				addr = n.OriginalAddress
			}
			if addr == "" {
				continue
			}
			allAddrs = append(allAddrs, addr)

			// 每个节点作为一个 Access Point
			accesses = append(accesses, &MT5Access{
				Name:      fmt.Sprintf("AS%02d", i+1),
				Addresses: []string{addr},
			})
		}

		defaultAddr := ""
		if len(allAddrs) > 0 {
			defaultAddr = allAddrs[0]
		}

		srv := &MT5Server{
			Info: &MT5ServerInfoEx{
				ServerName:  item.Name,
				CompanyName: item.CompanyName,
				Address:     defaultAddr,
			},
			Accesses: accesses,
		}
		servers = append(servers, srv)
	}
	return servers
}

// 获取当前 Moneta MT5 服务器列表
func GetMonetaMT5Servers() ([]*MT5Server, error) {
	var rawList []ServerGroupRaw
	if err := json.Unmarshal([]byte(DefaultMT5ServersJSON), &rawList); err != nil {
		return nil, err
	}
	return ConvertRawToMT5(rawList), nil
}

// 向指定 MT5 目录注入 Moneta 服务器 (Upsert 追加合并)
func InjectMT5Directory(configOrBasesDir string, monetaServers []*MT5Server) (int, error) {
	datPath := filepath.Join(configOrBasesDir, "servers.dat")

	existingServers, header, err := ReadServersDat(datPath)
	if err != nil {
		existingServers = []*MT5Server{}
		header = nil
	}

	// 合并逻辑：构建 Map
	existingMap := make(map[string]int)
	for idx, srv := range existingServers {
		key := strings.ToLower(strings.TrimSpace(srv.Info.ServerName))
		existingMap[key] = idx
	}

	var mergedServers []*MT5Server
	for _, moneta := range monetaServers {
		key := strings.ToLower(strings.TrimSpace(moneta.Info.ServerName))
		if idx, exists := existingMap[key]; exists {
			// 更新已有
			existingServers[idx].Info.CompanyName = moneta.Info.CompanyName
			existingServers[idx].Info.Address = moneta.Info.Address
			existingServers[idx].Accesses = moneta.Accesses
		} else {
			// 新增置顶
			mergedServers = append(mergedServers, moneta)
		}
	}

	mergedServers = append(mergedServers, existingServers...)

	if err := SaveServersDat(datPath, mergedServers, header); err != nil {
		return 0, err
	}

	return len(monetaServers), nil
}
