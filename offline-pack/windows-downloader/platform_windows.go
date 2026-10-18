//go:build windows

package main

import (
	"fmt"
	"golang.org/x/sys/windows"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unsafe"
)

var (
	kernel32                    = windows.NewLazySystemDLL("kernel32.dll")
	procSetThreadExecutionState = kernel32.NewProc("SetThreadExecutionState")
	procGetConsoleProcessList   = kernel32.NewProc("GetConsoleProcessList")
	procSetConsoleCtrlHandler   = kernel32.NewProc("SetConsoleCtrlHandler")
)

const (
	esContinuous     uint32 = 0x80000000
	esSystemRequired uint32 = 0x00000001
)

type Drive struct {
	Root, Label, Type, FS string
	Free, Total           uint64
	Usable                bool
	Reason                string
}

func configureConsole() {
	h := windows.Handle(os.Stdout.Fd())
	var mode uint32
	if windows.GetConsoleMode(h, &mode) == nil {
		_ = windows.SetConsoleMode(h, mode|0x0004)
	}
	_ = windows.SetConsoleOutputCP(65001)
	_ = windows.SetConsoleCP(65001)
}
func pauseConsole(yes bool) {
	if !yes {
		return
	}
	fmt.Print("按回车键退出")
	var b [1]byte
	_, _ = os.Stdin.Read(b[:])
}
func preventSleep(on bool) {
	flags := esContinuous
	if on {
		flags |= esSystemRequired
	}
	_, _, _ = procSetThreadExecutionState.Call(uintptr(flags))
}
func installConsoleHandler(cancel func()) func() {
	handler := windows.NewCallback(func(ctrl uint32) uintptr {
		if ctrl == 0 || ctrl == 2 || ctrl == 5 || ctrl == 6 {
			cancel()
			return 1
		}
		return 0
	})
	_, _, _ = procSetConsoleCtrlHandler.Call(handler, 1)
	return func() { _, _, _ = procSetConsoleCtrlHandler.Call(handler, 0) }
}
func explorerConsole() bool {
	var p [2]uint32
	n, _, err := procGetConsoleProcessList.Call(uintptr(unsafe.Pointer(&p[0])), 2)
	return err == windows.ERROR_SUCCESS && n == 1
}
func drives() []Drive {
	var result []Drive
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return result
	}
	for i := 0; i < 26; i++ {
		if mask&(1<<uint(i)) == 0 {
			continue
		}
		root := fmt.Sprintf("%c:\\", 'A'+i)
		typ := windows.GetDriveType(windows.StringToUTF16Ptr(root))
		d := Drive{Root: root, Type: map[uint32]string{windows.DRIVE_REMOVABLE: "可移动", windows.DRIVE_FIXED: "固定", windows.DRIVE_REMOTE: "网络", windows.DRIVE_CDROM: "CD-ROM"}[typ]}
		_ = windows.GetDiskFreeSpaceEx(windows.StringToUTF16Ptr(root), &d.Free, &d.Total, nil)
		var label [windows.MAX_PATH + 1]uint16
		var fs [windows.MAX_PATH + 1]uint16
		var flags uint32
		_ = windows.GetVolumeInformation(windows.StringToUTF16Ptr(root), &label[0], uint32(len(label)), nil, nil, &flags, &fs[0], uint32(len(fs)))
		d.Label = windows.UTF16ToString(label[:])
		d.FS = windows.UTF16ToString(fs[:])
		d.Usable = d.Type != "CD-ROM" && !strings.EqualFold(d.FS, "FAT") && !strings.EqualFold(d.FS, "FAT32") && flags&windows.FILE_READ_ONLY_VOLUME == 0
		if !d.Usable {
			d.Reason = "FAT/FAT32、只读或CD-ROM"
		}
		result = append(result, d)
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].Type == "可移动" && result[j].Type != "可移动" })
	return result
}
func volumeStats(path string) (uint64, uint64, string, error) {
	var root [windows.MAX_PATH]uint16
	if err := windows.GetVolumePathName(windows.StringToUTF16Ptr(path), &root[0], uint32(len(root))); err != nil {
		return 0, 0, "", err
	}
	var free, total uint64
	if err := windows.GetDiskFreeSpaceEx(&root[0], &free, &total, nil); err != nil {
		return 0, 0, "", err
	}
	var fs [windows.MAX_PATH + 1]uint16
	_ = windows.GetVolumeInformation(&root[0], nil, 0, nil, nil, nil, &fs[0], uint32(len(fs)))
	return free, total, windows.UTF16ToString(fs[:]), nil
}
func absPath(p string) string { p, _ = filepath.Abs(p); return p }
func renameWithRetry(old, new string) error {
	var err error
	for i := 0; i < 20; i++ {
		err = os.Rename(old, new)
		if err == nil {
			return nil
		}
		time.Sleep(time.Duration(i+1) * 250 * time.Millisecond)
	}
	return err
}

func acquireRunLock(root, version string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(root, version+".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	var ov windows.Overlapped
	if err := windows.LockFileEx(windows.Handle(f.Fd()), windows.LOCKFILE_EXCLUSIVE_LOCK|windows.LOCKFILE_FAIL_IMMEDIATELY, 0, 1, 0, &ov); err != nil {
		f.Close()
		return nil, fmt.Errorf("另一个下载程序正在使用这个目录")
	}
	return f, nil
}
