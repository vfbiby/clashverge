package mtconfig

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// 服务器节点模型
type ServerNodeRaw struct {
	ID              int    `json:"id"`
	OriginalAddress string `json:"originalAddress"`
	ResolvedIP      string `json:"resolvedIp"`
	IsActive        bool   `json:"isActive"`
	LatencyMS       *int   `json:"latencyMs"`
}

// 单个券商服务器定义
type ServerGroupRaw struct {
	CompanyName string          `json:"companyName"`
	Name        string          `json:"name"`
	Nodes       []ServerNodeRaw `json:"nodes"`
}

// 内置默认 MT4 服务器列表 (JSON)
const DefaultMT4ServersJSON = `[
    {
        "companyName": "Moneta Markets Capital Ltd",
        "name": "MonetaMarketsCapitalUK-Live",
        "nodes": [
            {"id": 70, "originalAddress": "192.109.23.147:443", "resolvedIp": "192.109.23.147:443", "isActive": true, "latencyMs": 190}
        ]
    },
    {
        "companyName": "Moneta Markets Trading Limited",
        "name": "MonetaMarketsTrading-Live",
        "nodes": [
            {"id": 147, "originalAddress": "18.163.170.234:443", "resolvedIp": "18.163.170.234:443", "isActive": true, "latencyMs": 0},
            {"id": 148, "originalAddress": "43.198.239.79:443", "resolvedIp": "43.198.239.79:443", "isActive": true, "latencyMs": 0},
            {"id": 141, "originalAddress": "ae5aca0c35d09f850.awsglobalaccelerator.com:700", "resolvedIp": "75.2.23.221:700", "isActive": true, "latencyMs": 0},
            {"id": 142, "originalAddress": "ae5aca0c35d09f850.awsglobalaccelerator.com:701", "resolvedIp": "166.117.188.213:701", "isActive": true, "latencyMs": 0},
            {"id": 143, "originalAddress": "ae5aca0c35d09f850.awsglobalaccelerator.com:702", "resolvedIp": "75.2.23.221:702", "isActive": true, "latencyMs": 0},
            {"id": 144, "originalAddress": "ae5aca0c35d09f850.awsglobalaccelerator.com:703", "resolvedIp": "166.117.188.213:703", "isActive": true, "latencyMs": 0},
            {"id": 145, "originalAddress": "ae5aca0c35d09f850.awsglobalaccelerator.com:704", "resolvedIp": "75.2.23.221:704", "isActive": true, "latencyMs": 0},
            {"id": 146, "originalAddress": "ae5aca0c35d09f850.awsglobalaccelerator.com:705", "resolvedIp": "166.117.188.213:705", "isActive": true, "latencyMs": 0},
            {"id": 152, "originalAddress": "47.243.239.224:700", "resolvedIp": "47.243.239.224:700", "isActive": true, "latencyMs": 1},
            {"id": 154, "originalAddress": "8.218.177.126:702", "resolvedIp": "8.218.177.126:702", "isActive": true, "latencyMs": 1},
            {"id": 153, "originalAddress": "47.76.83.217:701", "resolvedIp": "47.76.83.217:701", "isActive": true, "latencyMs": 2},
            {"id": 150, "originalAddress": "18.162.158.48:443", "resolvedIp": "18.162.158.48:443", "isActive": false, "latencyMs": null},
            {"id": 149, "originalAddress": "18.166.25.95:443", "resolvedIp": "18.166.25.95:443", "isActive": false, "latencyMs": null},
            {"id": 151, "originalAddress": "43.198.162.54:443", "resolvedIp": "43.198.162.54:443", "isActive": false, "latencyMs": null}
        ]
    },
    {
        "companyName": "Moneta Markets Trading Limited",
        "name": "MonetaMarketsTrading-Live2",
        "nodes": [
            {"id": 156, "originalAddress": "a5921e28170000307.awsglobalaccelerator.com:701", "resolvedIp": "15.197.180.225:701", "isActive": true, "latencyMs": 0},
            {"id": 158, "originalAddress": "a5921e28170000307.awsglobalaccelerator.com:703", "resolvedIp": "15.197.180.225:703", "isActive": true, "latencyMs": 0},
            {"id": 160, "originalAddress": "a5921e28170000307.awsglobalaccelerator.com:705", "resolvedIp": "15.197.180.225:705", "isActive": true, "latencyMs": 0},
            {"id": 155, "originalAddress": "a5921e28170000307.awsglobalaccelerator.com:700", "resolvedIp": "166.117.215.243:700", "isActive": true, "latencyMs": 15},
            {"id": 157, "originalAddress": "a5921e28170000307.awsglobalaccelerator.com:702", "resolvedIp": "166.117.215.243:702", "isActive": true, "latencyMs": 16},
            {"id": 159, "originalAddress": "a5921e28170000307.awsglobalaccelerator.com:704", "resolvedIp": "166.117.215.243:704", "isActive": true, "latencyMs": 16},
            {"id": 161, "originalAddress": "35.177.162.210:443", "resolvedIp": "35.177.162.210:443", "isActive": true, "latencyMs": 186},
            {"id": 162, "originalAddress": "18.170.172.76:443", "resolvedIp": "18.170.172.76:443", "isActive": true, "latencyMs": 207},
            {"id": 163, "originalAddress": "13.134.160.31:443", "resolvedIp": "13.134.160.31:443", "isActive": false, "latencyMs": null},
            {"id": 164, "originalAddress": "13.134.240.109:443", "resolvedIp": "13.134.240.109:443", "isActive": false, "latencyMs": null},
            {"id": 165, "originalAddress": "13.134.240.46:443", "resolvedIp": "13.134.240.46:443", "isActive": false, "latencyMs": null}
        ]
    },
    {
        "companyName": "Moneta Markets Trading Limited",
        "name": "MonetaMarketsTrading-Live3",
        "nodes": [
            {"id": 137, "originalAddress": "18.167.13.184:443", "resolvedIp": "18.167.13.184:443", "isActive": true, "latencyMs": 0},
            {"id": 136, "originalAddress": "95.40.139.42:443", "resolvedIp": "95.40.139.42:443", "isActive": true, "latencyMs": 0},
            {"id": 130, "originalAddress": "a681b3cdfdbcb50da.awsglobalaccelerator.com:700", "resolvedIp": "166.117.6.200:700", "isActive": true, "latencyMs": 0},
            {"id": 131, "originalAddress": "a681b3cdfdbcb50da.awsglobalaccelerator.com:701", "resolvedIp": "76.223.24.250:701", "isActive": true, "latencyMs": 0},
            {"id": 132, "originalAddress": "a681b3cdfdbcb50da.awsglobalaccelerator.com:702", "resolvedIp": "166.117.6.200:702", "isActive": true, "latencyMs": 0},
            {"id": 133, "originalAddress": "a681b3cdfdbcb50da.awsglobalaccelerator.com:703", "resolvedIp": "76.223.24.250:703", "isActive": true, "latencyMs": 0},
            {"id": 134, "originalAddress": "a681b3cdfdbcb50da.awsglobalaccelerator.com:704", "resolvedIp": "166.117.6.200:704", "isActive": true, "latencyMs": 0},
            {"id": 135, "originalAddress": "a681b3cdfdbcb50da.awsglobalaccelerator.com:705", "resolvedIp": "76.223.24.250:705", "isActive": true, "latencyMs": 0},
            {"id": 138, "originalAddress": "16.162.18.152:443", "resolvedIp": "16.162.18.152:443", "isActive": false, "latencyMs": null},
            {"id": 140, "originalAddress": "16.163.96.58:443", "resolvedIp": "16.163.96.58:443", "isActive": false, "latencyMs": null},
            {"id": 139, "originalAddress": "95.40.148.63:443", "resolvedIp": "95.40.148.63:443", "isActive": false, "latencyMs": null}
        ]
    },
    {
        "companyName": "Moneta Markets Trading Limited",
        "name": "MonetaMarketsTrading-Demo",
        "nodes": [
            {"id": 166, "originalAddress": "a9c497bae1a044efc.awsglobalaccelerator.com:700", "resolvedIp": "166.117.168.252:700", "isActive": true, "latencyMs": 0},
            {"id": 167, "originalAddress": "a9c497bae1a044efc.awsglobalaccelerator.com:701", "resolvedIp": "166.117.107.238:701", "isActive": true, "latencyMs": 0},
            {"id": 168, "originalAddress": "a9c497bae1a044efc.awsglobalaccelerator.com:702", "resolvedIp": "166.117.168.252:702", "isActive": true, "latencyMs": 0},
            {"id": 169, "originalAddress": "a9c497bae1a044efc.awsglobalaccelerator.com:703", "resolvedIp": "166.117.107.238:703", "isActive": true, "latencyMs": 0},
            {"id": 171, "originalAddress": "18.207.55.161:443", "resolvedIp": "18.207.55.161:443", "isActive": true, "latencyMs": 195},
            {"id": 170, "originalAddress": "34.197.165.28:443", "resolvedIp": "34.197.165.28:443", "isActive": true, "latencyMs": 196},
            {"id": 173, "originalAddress": "3.217.148.144:443", "resolvedIp": "3.217.148.144:443", "isActive": false, "latencyMs": null},
            {"id": 172, "originalAddress": "44.217.149.54:443", "resolvedIp": "44.217.149.54:443", "isActive": false, "latencyMs": null},
            {"id": 174, "originalAddress": "52.5.128.118:443", "resolvedIp": "52.5.128.118:443", "isActive": false, "latencyMs": null}
        ]
    }
]`

// 内置默认 MT5 服务器列表 (JSON)
const DefaultMT5ServersJSON = `[
    {
        "companyName": "Moneta Funded Ltd.",
        "name": "MonetaFunded-Live",
        "nodes": [
            {"id": 182, "originalAddress": "18.162.222.24:443", "resolvedIp": "18.162.222.24:443", "isActive": true, "latencyMs": 0},
            {"id": 176, "originalAddress": "a7b58b3193cffa3ee.awsglobalaccelerator.com:701", "resolvedIp": "166.117.11.250:701", "isActive": true, "latencyMs": 0},
            {"id": 178, "originalAddress": "a7b58b3193cffa3ee.awsglobalaccelerator.com:703", "resolvedIp": "166.117.11.250:703", "isActive": true, "latencyMs": 0},
            {"id": 180, "originalAddress": "a7b58b3193cffa3ee.awsglobalaccelerator.com:705", "resolvedIp": "166.117.11.250:705", "isActive": true, "latencyMs": 0},
            {"id": 184, "originalAddress": "95.40.155.208:443", "resolvedIp": "95.40.155.208:443", "isActive": true, "latencyMs": 1},
            {"id": 175, "originalAddress": "a7b58b3193cffa3ee.awsglobalaccelerator.com:700", "resolvedIp": "166.117.237.157:700", "isActive": true, "latencyMs": 16},
            {"id": 177, "originalAddress": "a7b58b3193cffa3ee.awsglobalaccelerator.com:702", "resolvedIp": "166.117.237.157:702", "isActive": true, "latencyMs": 16},
            {"id": 179, "originalAddress": "a7b58b3193cffa3ee.awsglobalaccelerator.com:704", "resolvedIp": "166.117.237.157:704", "isActive": true, "latencyMs": 16},
            {"id": 183, "originalAddress": "10.30.209.172:443", "resolvedIp": "10.30.209.172:443", "isActive": false, "latencyMs": null},
            {"id": 181, "originalAddress": "10.30.210.234:443", "resolvedIp": "10.30.210.234:443", "isActive": false, "latencyMs": null}
        ]
    },
    {
        "companyName": "Moneta Markets (Pty) Ltd",
        "name": "MonetaMarkets-Live",
        "nodes": [
            {"id": 1029, "originalAddress": "afa0f01957427d184.awsglobalaccelerator.com:700", "resolvedIp": "15.197.190.185:700", "isActive": true, "latencyMs": 0},
            {"id": 1030, "originalAddress": "afa0f01957427d184.awsglobalaccelerator.com:701", "resolvedIp": "166.117.187.1:701", "isActive": true, "latencyMs": 0},
            {"id": 1031, "originalAddress": "afa0f01957427d184.awsglobalaccelerator.com:702", "resolvedIp": "15.197.190.185:702", "isActive": true, "latencyMs": 0},
            {"id": 1032, "originalAddress": "afa0f01957427d184.awsglobalaccelerator.com:703", "resolvedIp": "166.117.187.1:703", "isActive": true, "latencyMs": 0},
            {"id": 1033, "originalAddress": "afa0f01957427d184.awsglobalaccelerator.com:704", "resolvedIp": "15.197.190.185:704", "isActive": true, "latencyMs": 0},
            {"id": 1034, "originalAddress": "afa0f01957427d184.awsglobalaccelerator.com:705", "resolvedIp": "166.117.187.1:705", "isActive": true, "latencyMs": 0},
            {"id": 1037, "originalAddress": "50.19.71.212:443", "resolvedIp": "50.19.71.212:443", "isActive": true, "latencyMs": 199},
            {"id": 1035, "originalAddress": "100.30.95.18:443", "resolvedIp": "100.30.95.18:443", "isActive": true, "latencyMs": 203},
            {"id": 1039, "originalAddress": "nlb-gwgbszcjranq35nshn.cn-shanghai.nlb.aliyuncs.com:443", "resolvedIp": "47.100.207.109:443", "isActive": true, "latencyMs": 230},
            {"id": 1041, "originalAddress": "nlb-9ingqtgn8bceckkoez.cn-chengdu.nlb.aliyuncsslb.com:443", "resolvedIp": "47.109.141.178:443", "isActive": true, "latencyMs": 323},
            {"id": 1040, "originalAddress": "nlb-oz2b5y0rutlifgop68.cn-beijing.nlb.aliyuncsslb.com:443", "resolvedIp": "8.140.56.103:443", "isActive": true, "latencyMs": 367},
            {"id": 1038, "originalAddress": "10.30.16.81:443", "resolvedIp": "10.30.16.81:443", "isActive": false, "latencyMs": null},
            {"id": 1036, "originalAddress": "10.30.28.236:443", "resolvedIp": "10.30.28.236:443", "isActive": false, "latencyMs": null}
        ]
    },
    {
        "companyName": "Moneta Markets Trading Limited",
        "name": "MonetaMarketsTrading-Live",
        "nodes": [
            {"id": 18406, "originalAddress": "a964cad78cf487481.awsglobalaccelerator.com:701", "resolvedIp": "15.197.158.145:701", "isActive": true, "latencyMs": 0},
            {"id": 18408, "originalAddress": "a964cad78cf487481.awsglobalaccelerator.com:703", "resolvedIp": "15.197.158.145:703", "isActive": true, "latencyMs": 0},
            {"id": 18405, "originalAddress": "a964cad78cf487481.awsglobalaccelerator.com:700", "resolvedIp": "35.71.170.105:700", "isActive": true, "latencyMs": 15},
            {"id": 18407, "originalAddress": "a964cad78cf487481.awsglobalaccelerator.com:702", "resolvedIp": "35.71.170.105:702", "isActive": true, "latencyMs": 19},
            {"id": 18411, "originalAddress": "13.43.61.20:443", "resolvedIp": "13.43.61.20:443", "isActive": true, "latencyMs": 187},
            {"id": 18410, "originalAddress": "3.11.102.0:443", "resolvedIp": "3.11.102.0:443", "isActive": true, "latencyMs": 196},
            {"id": 18412, "originalAddress": "10.30.80.53:443", "resolvedIp": "10.30.80.53:443", "isActive": false, "latencyMs": null},
            {"id": 18409, "originalAddress": "10.30.83.224:443", "resolvedIp": "10.30.83.224:443", "isActive": false, "latencyMs": null}
        ]
    },
    {
        "companyName": "Moneta Markets (Pty) Ltd",
        "name": "MonetaMarkets-Demo",
        "nodes": [
            {"id": 199, "originalAddress": "44.194.81.91:443", "resolvedIp": "44.194.81.91:443", "isActive": true, "latencyMs": 199},
            {"id": 198, "originalAddress": "10.10.70.45:443", "resolvedIp": "10.10.70.45:443", "isActive": false, "latencyMs": null},
            {"id": 200, "originalAddress": "44.194.81.91:1950", "resolvedIp": "44.194.81.91:1950", "isActive": false, "latencyMs": null}
        ]
    }
]`

// 获取当前 MT4 服务器列表 (先用默认，异步从 API 刷新)
func GetMonetaMT4Servers() ([]*MT4ServerEntry, error) {
	var rawList []ServerGroupRaw
	if err := json.Unmarshal([]byte(DefaultMT4ServersJSON), &rawList); err != nil {
		return nil, err
	}
	return ConvertRawToMT4(rawList), nil
}

// 将 JSON 数据转换为 MT4 结构体列表
func ConvertRawToMT4(rawList []ServerGroupRaw) []*MT4ServerEntry {
	var entries []*MT4ServerEntry
	for _, item := range rawList {
		isDemo := int32(0)
		if strings.Contains(strings.ToLower(item.Name), "demo") {
			isDemo = 1
		}

		var accesses []*MT4ServerAccess
		// 优先取 active 的节点
		for _, n := range item.Nodes {
			addr := n.ResolvedIP
			if addr == "" {
				addr = n.OriginalAddress
			}
			if addr == "" {
				continue
			}

			accesses = append(accesses, &MT4ServerAccess{
				Server:  addr,
				Desc:    "",
				IsProxy: 0,
			})
		}

		defaultHost := ""
		if len(accesses) > 0 {
			defaultHost = accesses[0].Server
		}

		mainSrv := &MT4MainServer{
			Name:     item.Name,
			Comment:  item.CompanyName,
			IsDemo:   isDemo,
			Count:    int32(len(accesses)),
			HostAddr: defaultHost,
		}

		entries = append(entries, &MT4ServerEntry{
			Main:     mainSrv,
			Accesses: accesses,
		})
	}
	return entries
}

// 异步从远程 API 拉取最新服务器列表
func FetchRemoteServers(apiUrl string) ([]ServerGroupRaw, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(apiUrl)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("bad status code: %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	var rawList []ServerGroupRaw
	if err := json.Unmarshal(body, &rawList); err != nil {
		return nil, err
	}
	return rawList, nil
}
