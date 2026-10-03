// 和平台无关的部分：按键位、报告解析、按键表、震动编码。逻辑与 Mac 版 JoyClicker.swift 一一对应，
// 改这里记得同步改 Mac 版，反之亦然。
package main

import (
	"math"
	"strings"
)

// Btn 是 0x30 全量报告第 3、4、5 字节拼成的 24 位按键状态
type Btn uint32

const (
	// 第 3 字节：右手柄
	BtnY  Btn = 1 << 0
	BtnX  Btn = 1 << 1
	BtnB  Btn = 1 << 2
	BtnA  Btn = 1 << 3
	BtnRSR Btn = 1 << 4
	BtnRSL Btn = 1 << 5
	BtnR  Btn = 1 << 6
	BtnZR Btn = 1 << 7
	// 第 4 字节：左右共用
	BtnMinus   Btn = 1 << 8
	BtnPlus    Btn = 1 << 9
	BtnRStick  Btn = 1 << 10
	BtnLStick  Btn = 1 << 11
	BtnHome    Btn = 1 << 12
	BtnCapture Btn = 1 << 13
	// 第 5 字节：左手柄
	BtnDown  Btn = 1 << 16
	BtnUp    Btn = 1 << 17
	BtnRight Btn = 1 << 18
	BtnLeft  Btn = 1 << 19
	BtnLSR   Btn = 1 << 20
	BtnLSL   Btn = 1 << 21
	BtnL     Btn = 1 << 22
	BtnZL    Btn = 1 << 23
)

// Windows 虚拟键码
const (
	VKLeft   = 0x25
	VKUp     = 0x26
	VKRight  = 0x27
	VKDown   = 0x28
	VKEscape = 0x1B
	VKB      = 0x42
	VKF5     = 0x74
)

type ActionKind int

const (
	ActKey         ActionKind = iota // 发一个键
	ActStartShow                     // 从头开始放映：按前台程序决定发不发 F5
	ActBlackOrExit                   // 短按 = 黑屏 / 恢复（B），按住 = 退出放映（Esc）
)

type Action struct {
	Kind ActionKind
	VK   uint16
}

type Binding struct {
	Btn    Btn
	Action Action
}

func key(vk uint16) Action { return Action{Kind: ActKey, VK: vk} }

// Keymap 是竖握（像遥控器那样）时的按键表：左手柄十字键、右手柄 X B Y A 都按位置当方向键。
// 截图键、HOME 键不映射，和 Mac 版一致。
var Keymap = []Binding{
	{BtnUp, key(VKUp)}, {BtnDown, key(VKDown)}, {BtnLeft, key(VKLeft)}, {BtnRight, key(VKRight)},
	{BtnX, key(VKUp)}, {BtnB, key(VKDown)}, {BtnY, key(VKLeft)}, {BtnA, key(VKRight)},
	{BtnZL, key(VKRight)}, {BtnZR, key(VKRight)}, // 扳机 = 下一页
	{BtnL, key(VKLeft)}, {BtnR, key(VKLeft)}, // 肩键 = 上一页
	{BtnLSR, key(VKRight)}, {BtnRSR, key(VKRight)}, // 横握时 SR = 下一页
	{BtnLSL, key(VKLeft)}, {BtnRSL, key(VKLeft)}, // 横握时 SL = 上一页
	{BtnMinus, Action{Kind: ActBlackOrExit}}, {BtnPlus, Action{Kind: ActBlackOrExit}},
	{BtnLStick, Action{Kind: ActStartShow}}, {BtnRStick, Action{Kind: ActStartShow}},
}

// ActionFor 找某一个键的动作，没映射返回 false
func ActionFor(b Btn) (Action, bool) {
	for _, k := range Keymap {
		if k.Btn == b {
			return k.Action, true
		}
	}
	return Action{}, false
}

// StartShowKey：前台是演示软件就返回「从头放映」的键（PowerPoint、WPS、LibreOffice 都是 F5）。
// 浏览器里 F5 是刷新，所以不发，免得把 Google 幻灯片刷掉。
func StartShowKey(exe string) (uint16, bool) {
	switch strings.ToLower(exe) {
	case "powerpnt.exe", "wpp.exe", "wps.exe", "soffice.bin", "soffice.exe":
		return VKF5, true
	}
	return 0, false
}

type PadState struct {
	Buttons  Btn
	Battery  int // 0 空 … 4 满
	Charging bool
}

// ParseStandard 解析 0x30（全量）/ 0x21（子命令回复）报告：第 2 字节高 4 位是电量（最低位 = 在充电），第 3~5 字节是按键
func ParseStandard(r []byte) (PadState, bool) {
	if len(r) < 6 || (r[0] != 0x30 && r[0] != 0x21) {
		return PadState{}, false
	}
	nib := int(r[2] >> 4)
	return PadState{
		Buttons:  Btn(uint32(r[3]) | uint32(r[4])<<8 | uint32(r[5])<<16),
		Battery:  nib >> 1,
		Charging: nib&1 == 1,
	}, true
}

// LEDMask：玩家灯当电量格，满 4 格 … 告急 1 格，没电时第 1 格闪
func LEDMask(battery int) byte {
	masks := []byte{0x10, 0x01, 0x03, 0x07, 0x0F}
	if battery < 0 {
		battery = 0
	}
	if battery > 4 {
		battery = 4
	}
	return masks[battery]
}

// QuietFrame 是一帧「不震」
var QuietFrame = []byte{0x00, 0x01, 0x40, 0x40}

// EncodeRumble 是 HD 震动编码（源自 tomayac/joy-con-webhid）；振幅夹在 0~1，再大伤马达
func EncodeRumble(lowFreq, highFreq, amplitude float64) []byte {
	lf0 := math.Min(math.Max(lowFreq, 40.875885), 626.286133)
	hf0 := math.Min(math.Max(highFreq, 81.75177), 1252.572266)
	hf := (int(math.Round(32*math.Log2(hf0*0.1))) - 0x60) * 4
	lf := int(math.Round(32*math.Log2(lf0*0.1))) - 0x40
	amp := math.Min(math.Max(amplitude, 0), 1)
	var hfAmp float64
	switch {
	case amp == 0:
		hfAmp = 0
	case amp < 0.117:
		hfAmp = (math.Log2(amp*1000)*32-0x60)/(5-amp*amp) - 1
	case amp < 0.23:
		hfAmp = math.Log2(amp*1000)*32 - 0x60 - 0x5C
	default:
		hfAmp = (math.Log2(amp*1000)*32-0x60)*2 - 0xF6
	}
	hfAmpI := int(math.Round(hfAmp))
	lfAmp := int(float64(hfAmpI) * 0.5)
	parity := lfAmp % 2
	if parity > 0 {
		lfAmp--
	}
	lfAmp = lfAmp >> 1
	lfAmp += 0x40
	if parity > 0 {
		lfAmp |= 0x8000
	}
	return []byte{byte(hf & 0xFF), byte(hfAmpI + ((hf >> 8) & 0xFF)), byte(lf + ((lfAmp >> 8) & 0xFF)), byte(lfAmp & 0xFF)}
}

// SubcommandReport 拼一个子命令输出报告（0x01，带一帧不震），包序号由发送方填
func SubcommandReport(id byte, args []byte) []byte {
	r := make([]byte, 49)
	r[0] = 0x01
	copy(r[2:6], QuietFrame)
	copy(r[6:10], QuietFrame)
	r[10] = id
	copy(r[11:], args)
	return r
}

// RumbleReport 拼一个只震动的输出报告（0x10）
func RumbleReport(four []byte) []byte {
	r := make([]byte, 10)
	r[0] = 0x10
	copy(r[2:6], four)
	copy(r[6:10], four)
	return r
}
