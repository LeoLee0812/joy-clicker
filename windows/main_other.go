//go:build !windows

package main

import "fmt"

// 非 Windows 平台只为了能跑 core 的单元测试；Mac 请用仓库根目录的 Swift 版
func main() { fmt.Println("这是 Windows 版，Mac 请用仓库根目录的 JoyClicker.swift") }
