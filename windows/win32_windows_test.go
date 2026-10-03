package main

import (
	"testing"
	"unsafe"
)

// 这些测试要在真 Windows 上跑（CI 用 windows-latest）

func TestInputStructSize(t *testing.T) {
	if s := unsafe.Sizeof(keyInput{}); s != 40 {
		t.Fatalf("64 位下 INPUT 应为 40 字节，实际 %d", s)
	}
}

func TestSendInputReachesSystem(t *testing.T) {
	// F24 没有任何程序会用，按下期间 GetAsyncKeyState 能看到就说明 SendInput 真的注入进去了
	const vkF24 = 0x87
	down := [1]keyInput{{typ: 1, vk: vkF24}}
	if n, _, _ := procSendInput.Call(1, uintptr(unsafe.Pointer(&down[0])), unsafe.Sizeof(down[0])); n != 1 {
		t.Fatal("SendInput 按下失败")
	}
	pressed := keyDown(vkF24)
	up := [1]keyInput{{typ: 1, vk: vkF24, flags: keyeventfKeyUp}}
	procSendInput.Call(1, uintptr(unsafe.Pointer(&up[0])), unsafe.Sizeof(up[0]))
	if !pressed {
		t.Fatal("发出去的 F24 系统没收到")
	}
	if !tapKey(VKRight) {
		t.Fatal("tapKey 发方向键失败")
	}
}

func TestEnumerateHID(t *testing.T) {
	list, err := listNintendo()
	if err != nil {
		t.Fatalf("枚举 HID 失败：%v", err)
	}
	t.Logf("在线的任天堂手柄：%d 个", len(list))
}

func TestForegroundAndProcess(t *testing.T) {
	t.Logf("前台程序：%q", foregroundExe())
	if processRunning("definitely-not-running.exe") {
		t.Fatal("不存在的进程不该算在跑")
	}
}

func TestAutostartRoundTrip(t *testing.T) {
	was := autostartEnabled()
	if err := setAutostart(true, `C:\fake\JoyClicker.exe`); err != nil || !autostartEnabled() {
		t.Fatalf("打开开机自启失败：%v", err)
	}
	if err := setAutostart(false, ""); err != nil || autostartEnabled() {
		t.Fatalf("关闭开机自启失败：%v", err)
	}
	if was {
		t.Log("测试前就开着开机自启，已被关掉（CI 上不会出现）")
	}
}
