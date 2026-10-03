// Windows 系统调用：HID 枚举和读写、SendInput 发键、前台进程、开机自启
package main

import (
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

var (
	hidDLL                      = windows.NewLazySystemDLL("hid.dll")
	procHidDGetAttributes       = hidDLL.NewProc("HidD_GetAttributes")
	procHidDGetSerialNumber     = hidDLL.NewProc("HidD_GetSerialNumberString")
	procHidDGetPreparsedData    = hidDLL.NewProc("HidD_GetPreparsedData")
	procHidDFreePreparsedData   = hidDLL.NewProc("HidD_FreePreparsedData")
	procHidPGetCaps             = hidDLL.NewProc("HidP_GetCaps")
	user32                      = windows.NewLazySystemDLL("user32.dll")
	procSendInput               = user32.NewProc("SendInput")
	procMapVirtualKeyW          = user32.NewProc("MapVirtualKeyW")
	procGetForegroundWindow     = user32.NewProc("GetForegroundWindow")
	procGetWindowThreadProcessId = user32.NewProc("GetWindowThreadProcessId")
	procGetAsyncKeyState        = user32.NewProc("GetAsyncKeyState")
)

// HID 设备接口类 {4D1E55B2-F16F-11CF-88CB-001111000030}
var hidGUID = windows.GUID{Data1: 0x4D1E55B2, Data2: 0xF16F, Data3: 0x11CF, Data4: [8]byte{0x88, 0xCB, 0x00, 0x11, 0x11, 0x00, 0x00, 0x30}}

type hidAttributes struct {
	Size      uint32
	VendorID  uint16
	ProductID uint16
	Version   uint16
}

// hidCaps 是 HIDP_CAPS，只用到前几个字段，后面整块留空间
type hidCaps struct {
	Usage, UsagePage                                         uint16
	InputReportByteLength, OutputReportByteLength, FeatureLen uint16
	_                                                         [17 + 10]uint16
}

type hidInfo struct {
	Path      string
	ProductID uint16
	Serial    string
}

// listNintendo 枚举在线的任天堂 HID 设备（Joy-Con L / R、Pro 手柄）
func listNintendo() ([]hidInfo, error) {
	paths, err := windows.CM_Get_Device_Interface_List("", &hidGUID, windows.CM_GET_DEVICE_INTERFACE_LIST_PRESENT)
	if err != nil {
		return nil, err
	}
	var out []hidInfo
	for _, p := range paths {
		// 访问权限给 0 只查属性，键盘鼠标这类拒绝读写的设备也能打开
		h, err := openPath(p, 0)
		if err != nil {
			continue
		}
		attr := hidAttributes{Size: uint32(unsafe.Sizeof(hidAttributes{}))}
		ok, _, _ := procHidDGetAttributes.Call(uintptr(h), uintptr(unsafe.Pointer(&attr)))
		if ok != 0 && attr.VendorID == 0x057E && (attr.ProductID == 0x2006 || attr.ProductID == 0x2007 || attr.ProductID == 0x2009) {
			buf := make([]uint16, 128)
			procHidDGetSerialNumber.Call(uintptr(h), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)*2))
			out = append(out, hidInfo{Path: p, ProductID: attr.ProductID, Serial: windows.UTF16ToString(buf)})
		}
		windows.CloseHandle(h)
	}
	return out, nil
}

func openPath(path string, access uint32) (windows.Handle, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return 0, err
	}
	return windows.CreateFile(p, access, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
}

// reportLengths 读设备声明的输入 / 输出报告长度（含报告号）；读不到就用 Joy-Con 蓝牙的 362 / 49
func reportLengths(h windows.Handle) (in, out int) {
	in, out = 362, 49
	var pp uintptr
	if ok, _, _ := procHidDGetPreparsedData.Call(uintptr(h), uintptr(unsafe.Pointer(&pp))); ok == 0 {
		return
	}
	defer procHidDFreePreparsedData.Call(pp)
	var caps hidCaps
	if st, _, _ := procHidPGetCaps.Call(pp, uintptr(unsafe.Pointer(&caps))); st == 0x00110000 { // HIDP_STATUS_SUCCESS
		if caps.InputReportByteLength > 0 {
			in = int(caps.InputReportByteLength)
		}
		if caps.OutputReportByteLength > 0 {
			out = int(caps.OutputReportByteLength)
		}
	}
	return
}

// keyInput 是 64 位下的 INPUT（type + KEYBDINPUT，联合体按 MOUSEINPUT 补到 40 字节）
type keyInput struct {
	typ   uint32
	_     uint32
	vk    uint16
	scan  uint16
	flags uint32
	time  uint32
	_     uint32
	extra uint64
	_     [8]byte
}

const (
	keyeventfExtended = 0x0001
	keyeventfKeyUp    = 0x0002
)

func isExtended(vk uint16) bool {
	switch vk {
	case VKLeft, VKUp, VKRight, VKDown:
		return true
	}
	return false
}

// tapKey 用 SendInput 发一次按下 + 松开；方向键是扩展键，要带 EXTENDEDKEY 标志
func tapKey(vk uint16) bool {
	scan, _, _ := procMapVirtualKeyW.Call(uintptr(vk), 0)
	var flags uint32
	if isExtended(vk) {
		flags = keyeventfExtended
	}
	in := [2]keyInput{
		{typ: 1, vk: vk, scan: uint16(scan), flags: flags},
		{typ: 1, vk: vk, scan: uint16(scan), flags: flags | keyeventfKeyUp},
	}
	n, _, _ := procSendInput.Call(2, uintptr(unsafe.Pointer(&in[0])), unsafe.Sizeof(in[0]))
	return n == 2
}

// foregroundExe 返回前台窗口所属程序的文件名（如 POWERPNT.EXE）
func foregroundExe() string {
	hwnd, _, _ := procGetForegroundWindow.Call()
	if hwnd == 0 {
		return ""
	}
	var pid uint32
	procGetWindowThreadProcessId.Call(hwnd, uintptr(unsafe.Pointer(&pid)))
	return processExe(pid)
}

func processExe(pid uint32) string {
	h, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return ""
	}
	defer windows.CloseHandle(h)
	buf := make([]uint16, windows.MAX_PATH)
	size := uint32(len(buf))
	if windows.QueryFullProcessImageName(h, 0, &buf[0], &size) != nil {
		return ""
	}
	return filepath.Base(windows.UTF16ToString(buf[:size]))
}

// processRunning 看有没有叫这个名字的进程在跑
func processRunning(name string) bool {
	snap, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPPROCESS, 0)
	if err != nil {
		return false
	}
	defer windows.CloseHandle(snap)
	var e windows.ProcessEntry32
	e.Size = uint32(unsafe.Sizeof(e))
	for err = windows.Process32First(snap, &e); err == nil; err = windows.Process32Next(snap, &e) {
		if strings.EqualFold(windows.UTF16ToString(e.ExeFile[:]), name) {
			return true
		}
	}
	return false
}

func keyDown(vk uint16) bool {
	r, _, _ := procGetAsyncKeyState.Call(uintptr(vk))
	return r&0x8000 != 0
}

// 开机自启：写当前用户的 Run 键，不需要管理员权限
const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

func autostartEnabled() bool {
	k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false
	}
	defer k.Close()
	_, _, err = k.GetStringValue("JoyClicker")
	return err == nil
}

func setAutostart(on bool, exe string) error {
	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if on {
		return k.SetStringValue("JoyClicker", `"`+exe+`"`)
	}
	if err := k.DeleteValue("JoyClicker"); err != nil && err != syscall.ERROR_FILE_NOT_FOUND {
		return err
	}
	return nil
}
