package main

import (
	"bytes"
	"testing"
)

func TestParseStandard(t *testing.T) {
	r := make([]byte, 49)
	r[0], r[2], r[5] = 0x30, 0x8E, 0x04
	s, ok := ParseStandard(r)
	if !ok || s.Buttons != BtnRight || s.Battery != 4 || s.Charging {
		t.Fatalf("第 5 字节 0x04 应是左手柄 →、满电没充电，得到 %+v", s)
	}
	r[2] = 0x3E
	if s, _ := ParseStandard(r); s.Battery != 1 || !s.Charging {
		t.Fatalf("0x3 应是告急 1 格、在充电，得到 %+v", s)
	}
	r[3], r[5] = 0x88, 0x80
	if s, _ := ParseStandard(r); s.Buttons != BtnA|BtnZR|BtnZL {
		t.Fatalf("A + ZR + ZL 解析错：%x", s.Buttons)
	}
	r[4] = 0x0B
	if s, _ := ParseStandard(r); s.Buttons&(BtnMinus|BtnPlus|BtnLStick) != BtnMinus|BtnPlus|BtnLStick {
		t.Fatalf("第 4 字节 0x0B 应是 − + 左摇杆按下")
	}
	r[0] = 0x3F
	if _, ok := ParseStandard(r); ok {
		t.Fatal("简单模式 0x3F 不该当全量报告解析")
	}
}

func TestKeymap(t *testing.T) {
	cases := []struct {
		b    Btn
		want Action
	}{
		{BtnRight, key(VKRight)}, {BtnZL, key(VKRight)}, {BtnUp, key(VKUp)}, {BtnL, key(VKLeft)},
		{BtnA, key(VKRight)}, {BtnX, key(VKUp)},
		{BtnMinus, Action{Kind: ActBlackOrExit}}, {BtnLStick, Action{Kind: ActStartShow}},
	}
	for _, c := range cases {
		if a, ok := ActionFor(c.b); !ok || a != c.want {
			t.Errorf("%x 的动作是 %+v，应为 %+v", c.b, a, c.want)
		}
	}
	for _, b := range []Btn{BtnCapture, BtnHome} {
		if _, ok := ActionFor(b); ok {
			t.Errorf("截图键 / HOME 不该映射：%x", b)
		}
	}
}

func TestStartShowKey(t *testing.T) {
	for _, exe := range []string{"POWERPNT.EXE", "wpp.exe", "wps.exe", "soffice.bin"} {
		if vk, ok := StartShowKey(exe); !ok || vk != VKF5 {
			t.Errorf("%s 应发 F5", exe)
		}
	}
	for _, exe := range []string{"chrome.exe", "msedge.exe", "explorer.exe", ""} {
		if _, ok := StartShowKey(exe); ok {
			t.Errorf("%s 不该发键（浏览器里 F5 是刷新）", exe)
		}
	}
}

func TestEncodingAndReports(t *testing.T) {
	if !bytes.Equal(EncodeRumble(160, 320, 0), QuietFrame) {
		t.Fatal("振幅 0 应正好编码成「不震」帧")
	}
	if LEDMask(4) != 0x0F || LEDMask(1) != 0x01 || LEDMask(0) != 0x10 || LEDMask(-1) != 0x10 {
		t.Fatal("电量 → 玩家灯不对")
	}
	r := SubcommandReport(0x03, []byte{0x30})
	if len(r) != 49 || r[0] != 0x01 || r[10] != 0x03 || r[11] != 0x30 || !bytes.Equal(r[2:6], QuietFrame) {
		t.Fatalf("子命令报告格式不对：% x", r[:12])
	}
	if rr := RumbleReport(QuietFrame); len(rr) != 10 || rr[0] != 0x10 {
		t.Fatal("震动报告格式不对")
	}
}
