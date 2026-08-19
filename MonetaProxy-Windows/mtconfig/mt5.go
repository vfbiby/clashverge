package mtconfig

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"unicode/utf16"
)

const (
	MT5DatHeaderSize    = 428
	MT5ServerInfoExSize = 1716
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

// MT5 接入点组
type MT5AccessEx struct {
	RawRec    [MT5AccessRecExSize]byte // 3160 字节
	Addresses []*MT5AddressRecEx
}

// MT5 具体的接入点地址 (1284 字节)
type MT5AddressRecEx struct {
	S0   int32  // 4 字节
	S4   string // 512 字节 UTF-16LE (IP/域名:端口, 如 "1.2.3.4:443")
	S204 string // 512 字节 UTF-16LE
	S404 [256]byte
}

// MT5 整体 Server 对象
type MT5Server struct {
	Info     *MT5ServerInfoEx
	Accesses []*MT5AccessEx
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

// 序列化 AddressRecEx (1284 字节加密)
func (a *MT5AddressRecEx) SerializeEncrypted() []byte {
	buf := make([]byte, MT5AddressRecExSize)
	PutLeInt32(buf[0:4], a.S0)
	copy(buf[4:516], EncodeUtf16LE(a.S4, 512))
	copy(buf[516:1028], EncodeUtf16LE(a.S204, 512))
	copy(buf[1028:1284], a.S404[:])
	return MT5EasyCrypt(buf)
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
		// 1. 写入加密 ServerInfoEx
		out.Write(srv.Info.SerializeEncrypted())

		// 2. 写入 Accesses 数量 (0)
		numBuf := make([]byte, 4)
		PutLeInt32(numBuf, 0)
		out.Write(numBuf)

		// 3. 写入 AccessesEx 数量
		PutLeInt32(numBuf, int32(len(srv.Accesses)))
		out.Write(numBuf)

		// 4. 写入每一个 AccessEx
		for _, acc := range srv.Accesses {
			rawRecEnc := make([]byte, MT5AccessRecExSize)
			copy(rawRecEnc, acc.RawRec[:])
			MT5EasyCrypt(rawRecEnc)
			out.Write(rawRecEnc)

			// 写入 Addresses 数量
			PutLeInt32(numBuf, int32(len(acc.Addresses)))
			out.Write(numBuf)

			// 写入每一个 AddressRecEx
			for _, addr := range acc.Addresses {
				out.Write(addr.SerializeEncrypted())
			}
		}
	}

	_ = os.MkdirAll(filepath.Dir(filePath), 0755)
	return os.WriteFile(filePath, out.Bytes(), 0644)
}
