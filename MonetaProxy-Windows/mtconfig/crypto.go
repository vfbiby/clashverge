package mtconfig

import (
	"crypto/md5"
	"encoding/binary"
	"time"
)

// MT4 / MT5 通用 16 字节专用异或加解密密钥
var CryptKey = []byte{
	65, 182, 127, 88, 56, 12, 240, 45, 123, 57,
	8, 254, 33, 187, 65, 88,
}

// MT4 加密
func MT4Encrypt(buf []byte, key []byte) []byte {
	if key == nil {
		key = CryptKey
	}
	num := byte(0)
	res := make([]byte, len(buf))
	for i := 0; i < len(buf); i++ {
		res[i] = buf[i] ^ (num + key[i&0xF])
		num = res[i]
	}
	return res
}

// MT4 解密
func MT4Decrypt(buf []byte, key []byte) []byte {
	if key == nil {
		key = CryptKey
	}
	num := byte(0)
	res := make([]byte, len(buf))
	for i := 0; i < len(buf); i++ {
		res[i] = buf[i] ^ (num + key[i&0xF])
		num = buf[i]
	}
	return res
}

// MT5 EasyCrypt 原地流式加密
func MT5EasyCrypt(buf []byte) []byte {
	num := byte(0)
	for i := 0; i < len(buf); i++ {
		buf[i] ^= (num + CryptKey[i&0xF])
		num = buf[i]
	}
	return buf
}

// MT5 EasyDecrypt 原地流式解密
func MT5EasyDecrypt(buf []byte) []byte {
	num := byte(0)
	for i := 0; i < len(buf); i++ {
		num2 := num
		num = buf[i]
		buf[i] ^= (num2 + CryptKey[i&0xF])
	}
	return buf
}

// 生成硬件特征 ID (与 C# MT4Crypt.CreateHardId 算法一致)
func CreateHardID(seed uint32) []byte {
	if seed == 0 {
		seed = uint32(time.Now().UnixNano() / 100)
	}
	buf := make([]byte, 256)
	for i := 0; i < 256; i++ {
		seed = seed*214013 + 2531011
		buf[i] = byte((seed >> 16) & 0xFF)
	}
	h := md5.Sum(buf)
	res := h[:]
	res[0] = 0
	for j := 1; j < 16; j++ {
		res[0] += res[j]
	}
	return res
}

// 辅助：小端字节转换
func LeUint16(b []byte) uint16 { return binary.LittleEndian.Uint16(b) }
func LeUint32(b []byte) uint32 { return binary.LittleEndian.Uint32(b) }
func LeInt32(b []byte) int32   { return int32(binary.LittleEndian.Uint32(b)) }
func LeInt64(b []byte) int64   { return int64(binary.LittleEndian.Uint64(b)) }

func PutLeUint16(b []byte, v uint16) { binary.LittleEndian.PutUint16(b, v) }
func PutLeUint32(b []byte, v uint32) { binary.LittleEndian.PutUint32(b, v) }
func PutLeInt32(b []byte, v int32)   { binary.LittleEndian.PutUint32(b, uint32(v)) }
func PutLeInt64(b []byte, v int64)   { binary.LittleEndian.PutUint64(b, uint64(v)) }
