// JoyClicker Windows 版：把 Joy-Con 变成 PPT 翻页笔的托盘小工具
//
// 做法和 Mac 版一样：直接读手柄的蓝牙 HID 原始报告，切到 0x30 全量模式（约 60Hz），
// 键「刚按下」的那一刻用 SendInput 给前台程序发键。Windows 没有插拔通知，每 2 秒枚举一次。
// 所有状态都在一个事件循环 goroutine 里改，读报告、计时器只往通道里扔事件，不用加锁。
package main

import (
	_ "embed"
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"fyne.io/systray"
	"golang.org/x/sys/windows"
)

//go:embed icon.ico
var iconICO []byte

const (
	holdTime      = 800 * time.Millisecond // − / + 按住多久算长按（退出放映）
	keepAliveSpan = 30 * time.Minute       // 最后一次按键后保活多久
	glintExe      = "Glint.exe"            // 作者的眼动阅读器，也直接读 Joy-Con
)

type pad struct {
	info      hidInfo
	side      string
	rd, wr    windows.Handle // 读写分开两个句柄：同步句柄上读和写会互相排队
	outLen    int
	out       chan []byte
	state     PadState
	lastPress time.Time
	lastFull  time.Time
	lastInit  time.Time
	shownLED  int
	greeted   bool
	gone      bool
}

type evKind int

const (
	evReport evKind = iota
	evGone
	evTick
	evHold
)

type event struct {
	kind evKind
	p    *pad
	data []byte
	btn  Btn
}

type app struct {
	events    chan event
	pads      map[string]*pad
	paused    atomic.Bool // 托盘线程写、事件循环读
	holds     map[string]*time.Timer
	longFired map[string]bool
	glint     bool
	smoke     bool

	mu     sync.Mutex
	status []string
}

func main() {
	smoke := len(os.Args) > 1 && os.Args[1] == "--smoke"
	// 单实例：已经开着就直接退出
	name, _ := windows.UTF16PtrFromString(`Local\JoyClicker`)
	if _, err := windows.CreateMutex(nil, false, name); err == windows.ERROR_ALREADY_EXISTS && !smoke {
		return
	}
	a := &app{events: make(chan event, 256), pads: map[string]*pad{}, holds: map[string]*time.Timer{}, longFired: map[string]bool{}, smoke: smoke}
	go a.loop()
	go func() {
		for {
			a.events <- event{kind: evTick}
			time.Sleep(2 * time.Second)
		}
	}()
	systray.Run(a.onTrayReady, func() { a.restoreAll() })
}

// ---------- 事件循环 ----------

func (a *app) loop() {
	for e := range a.events {
		switch e.kind {
		case evTick:
			a.tick()
		case evReport:
			a.handle(e.p, e.data)
		case evGone:
			a.detach(e.p)
		case evHold:
			a.holdFired(e.p, e.btn)
		}
	}
}

func (a *app) tick() {
	a.glint = processRunning(glintExe)
	if list, err := listNintendo(); err == nil {
		for _, info := range list {
			if _, ok := a.pads[info.Path]; !ok {
				a.attach(info)
			}
		}
	}
	now := time.Now()
	for _, p := range a.pads {
		// 看门狗：3 秒没收到全量报告 = 手柄刚醒回到简单模式，或被别的程序改了模式
		if now.Sub(p.lastFull) > 3*time.Second && now.Sub(p.lastInit) > 3*time.Second {
			a.initialize(p)
		}
		// 保活：讲一页讲久了也不让手柄闲置休眠
		if now.Sub(p.lastPress) < keepAliveSpan {
			a.send(p, RumbleReport(QuietFrame))
		}
	}
	a.refreshStatus()
}

func (a *app) attach(info hidInfo) {
	rd, err := openPath(info.Path, windows.GENERIC_READ|windows.GENERIC_WRITE)
	if err != nil {
		return
	}
	wr, err := openPath(info.Path, windows.GENERIC_READ|windows.GENERIC_WRITE)
	if err != nil {
		windows.CloseHandle(rd)
		return
	}
	inLen, outLen := reportLengths(rd)
	side := map[uint16]string{0x2006: "Joy-Con (L)", 0x2007: "Joy-Con (R)", 0x2009: "Pro 手柄"}[info.ProductID]
	p := &pad{info: info, side: side, rd: rd, wr: wr, outLen: outLen, out: make(chan []byte, 64),
		state: PadState{Battery: -1}, lastPress: time.Now(), shownLED: -1}
	a.pads[info.Path] = p
	go a.reader(p, inLen)
	go a.writer(p)
	a.initialize(p)
}

func (a *app) detach(p *pad) {
	if p.gone {
		return
	}
	p.gone = true
	delete(a.pads, p.info.Path)
	close(p.out)
	windows.CloseHandle(p.rd)
	for id, t := range a.holds {
		if strings.HasPrefix(id, p.info.Path+"#") {
			t.Stop()
			delete(a.holds, id)
			delete(a.longFired, id)
		}
	}
	a.refreshStatus()
}

// reader 阻塞读输入报告，读出错（手柄断开）就报告 evGone
func (a *app) reader(p *pad, inLen int) {
	buf := make([]byte, inLen)
	for {
		var n uint32
		if err := windows.ReadFile(p.rd, buf, &n, nil); err != nil || n == 0 {
			a.events <- event{kind: evGone, p: p}
			return
		}
		data := make([]byte, n)
		copy(data, buf[:n])
		a.events <- event{kind: evReport, p: p, data: data}
	}
}

// writer 按节拍发输出报告：每包隔 15ms，子命令之间至少隔 60ms，发快了手柄会丢
func (a *app) writer(p *pad) {
	var packet byte
	var lastSub time.Time
	for r := range p.out {
		if r[0] == 0x01 {
			if d := 60*time.Millisecond - time.Since(lastSub); d > 0 {
				time.Sleep(d)
			}
			lastSub = time.Now()
		}
		buf := make([]byte, p.outLen) // WriteFile 要求按设备声明的输出报告长度补齐
		copy(buf, r)
		buf[1] = packet & 0x0F
		packet++
		var n uint32
		windows.WriteFile(p.wr, buf, &n, nil)
		time.Sleep(15 * time.Millisecond)
	}
	windows.CloseHandle(p.wr)
}

func (a *app) send(p *pad, r []byte) {
	if a.glint || p.gone {
		return // Glint 在管手柄时不插手
	}
	select {
	case p.out <- r:
	default: // 队列满了就丢，保活帧丢几个没关系
	}
}

func (a *app) initialize(p *pad) {
	p.lastInit = time.Now()
	p.shownLED = -1
	a.send(p, SubcommandReport(0x03, []byte{0x30})) // 切到 0x30 全量模式
	a.send(p, SubcommandReport(0x48, []byte{0x01})) // 允许震动
}

func (a *app) buzz(p *pad, segs [][2]float64) {
	for _, s := range segs {
		four := QuietFrame
		if s[1] > 0 {
			four = EncodeRumble(160, 320, s[1])
		}
		for i := 0; i < max(1, int(s[0]/15+0.5)); i++ {
			a.send(p, RumbleReport(four))
		}
	}
	a.send(p, RumbleReport(QuietFrame))
}

func (a *app) handle(p *pad, r []byte) {
	if p.gone || len(r) == 0 {
		return
	}
	if r[0] == 0x3F {
		if time.Since(p.lastInit) > time.Second {
			a.initialize(p)
		}
		return
	}
	s, ok := ParseStandard(r)
	if !ok {
		return
	}
	if r[0] == 0x30 {
		p.lastFull = time.Now()
		if !p.greeted {
			p.greeted = true
			a.buzz(p, [][2]float64{{60, 0.5}, {60, 0}, {60, 0.5}}) // 连上了：震两下
			a.refreshStatus()
		}
	}
	pressed, released := s.Buttons&^p.state.Buttons, p.state.Buttons&^s.Buttons
	changed := s.Battery != p.state.Battery || s.Charging != p.state.Charging
	p.state = s
	if pressed != 0 {
		p.lastPress = time.Now()
		a.pressed(p, pressed)
	}
	if released != 0 {
		a.released(p, released)
	}
	if m := int(LEDMask(s.Battery)); m != p.shownLED && !a.glint {
		p.shownLED = m
		a.send(p, SubcommandReport(0x30, []byte{byte(m)}))
	}
	if changed {
		a.refreshStatus()
	}
}

func (a *app) canSend() bool {
	return !a.paused.Load() && !strings.EqualFold(foregroundExe(), glintExe)
}

func (a *app) pressed(p *pad, btns Btn) {
	if !a.canSend() {
		return
	}
	for _, k := range Keymap {
		if btns&k.Btn == 0 {
			continue
		}
		switch k.Action.Kind {
		case ActKey:
			tapKey(k.Action.VK)
		case ActStartShow:
			if vk, ok := StartShowKey(foregroundExe()); ok {
				tapKey(vk)
			} else {
				a.buzz(p, [][2]float64{{40, 0.4}, {60, 0}, {40, 0.4}}) // 前台不是演示软件：震两下表示没动作
			}
		case ActBlackOrExit:
			id := fmt.Sprintf("%s#%d", p.info.Path, k.Btn)
			if t := a.holds[id]; t != nil {
				t.Stop()
			}
			b := k.Btn
			a.holds[id] = time.AfterFunc(holdTime, func() { a.events <- event{kind: evHold, p: p, btn: b} })
		}
	}
}

func (a *app) holdFired(p *pad, b Btn) {
	id := fmt.Sprintf("%s#%d", p.info.Path, b)
	if a.holds[id] == nil || p.gone {
		return
	}
	a.longFired[id] = true
	tapKey(VKEscape)
	a.buzz(p, [][2]float64{{90, 0.6}}) // 退出放映了，震一下告诉你可以松手
}

func (a *app) released(p *pad, btns Btn) {
	for _, k := range Keymap {
		if btns&k.Btn == 0 || k.Action.Kind != ActBlackOrExit {
			continue
		}
		id := fmt.Sprintf("%s#%d", p.info.Path, k.Btn)
		t := a.holds[id]
		if t == nil {
			continue
		}
		t.Stop()
		delete(a.holds, id)
		if !a.longFired[id] {
			tapKey(VKB) // 没到长按：黑屏 / 恢复
		}
		delete(a.longFired, id)
	}
}

// restoreAll 退出前把手柄切回简单模式，免得一直 60Hz 发报告耗电
func (a *app) restoreAll() {
	if a.glint {
		return
	}
	for _, p := range a.pads {
		buf := make([]byte, p.outLen)
		copy(buf, SubcommandReport(0x03, []byte{0x3F}))
		var n uint32
		windows.WriteFile(p.wr, buf, &n, nil)
	}
}

// ---------- 托盘 ----------

var statusItems []*systray.MenuItem

func (a *app) refreshStatus() {
	lines := []string{}
	for _, p := range a.pads {
		if p.state.Battery < 0 {
			lines = append(lines, p.side+"　连接中…")
			continue
		}
		bars := strings.Repeat("●", p.state.Battery) + strings.Repeat("○", 4-p.state.Battery)
		line := fmt.Sprintf("%s　电量 %s", p.side, bars)
		if p.state.Charging {
			line += " 充电中"
		}
		lines = append(lines, line)
	}
	if len(lines) == 0 {
		lines = []string{"没连上 Joy-Con（蓝牙里先配对）"}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for i, it := range statusItems {
		if i < len(lines) {
			it.SetTitle(lines[i])
			it.Show()
		} else {
			it.Hide()
		}
	}
	tip := "JoyClicker：" + strings.Join(lines, "；")
	if a.paused.Load() {
		tip += "（已暂停）"
	}
	systray.SetTooltip(tip)
}

func (a *app) onTrayReady() {
	systray.SetIcon(iconICO)
	systray.SetTitle("JoyClicker")
	a.mu.Lock()
	for i := 0; i < 3; i++ {
		it := systray.AddMenuItem("", "")
		it.Disable()
		statusItems = append(statusItems, it)
	}
	a.mu.Unlock()
	systray.AddSeparator()
	help := systray.AddMenuItem("按键说明", "")
	for _, line := range []string{
		"十字键 ＝ 方向键：→ ↓ 下一页，← ↑ 上一页",
		"ZL / ZR 扳机　下一页",
		"L / R 肩键　上一页",
		"− / +　短按黑屏（再按恢复），按住 1 秒退出放映",
		"按下摇杆　从头放映（PowerPoint / WPS 发 F5）",
		"右手柄的 X B Y A 按位置当方向键",
		"手柄上亮几格灯 ＝ 剩几格电",
	} {
		help.AddSubMenuItem(line, "").Disable()
	}
	pause := systray.AddMenuItemCheckbox("暂停翻页", "", false)
	auto := systray.AddMenuItemCheckbox("开机自动启动", "", autostartEnabled())
	systray.AddSeparator()
	quit := systray.AddMenuItem("退出 JoyClicker", "")
	a.refreshStatus()

	exe, _ := os.Executable()
	// 第一次运行默认打开开机自启
	if !autostartEnabled() && !a.smoke && firstRun() {
		if setAutostart(true, exe) == nil {
			auto.Check()
		}
	}
	go func() {
		for {
			select {
			case <-pause.ClickedCh:
				if !a.paused.Load() {
					a.paused.Store(true)
					pause.Check()
				} else {
					a.paused.Store(false)
					pause.Uncheck()
				}
				a.events <- event{kind: evTick}
			case <-auto.ClickedCh:
				on := !auto.Checked()
				if setAutostart(on, exe) == nil {
					if on {
						auto.Check()
					} else {
						auto.Uncheck()
					}
				}
			case <-quit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
	if a.smoke {
		// 冒烟测试：托盘起来、枚举跑过一轮就正常退出
		go func() {
			time.Sleep(3 * time.Second)
			systray.Quit()
		}()
	}
}

// firstRun 用 %APPDATA%\JoyClicker\configured 记一下，只在第一次运行时自动打开开机自启
func firstRun() bool {
	dir, err := os.UserConfigDir()
	if err != nil {
		return false
	}
	flag := dir + `\JoyClicker\configured`
	if _, err := os.Stat(flag); err == nil {
		return false
	}
	os.MkdirAll(dir+`\JoyClicker`, 0o755)
	os.WriteFile(flag, []byte("1"), 0o644)
	return true
}
