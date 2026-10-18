//go:build !windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

type Drive struct {
	Root, Label, Type, FS string
	Free, Total           uint64
	Usable                bool
	Reason                string
}

func configureConsole()                   {}
func pauseConsole(bool)                   {}
func preventSleep(bool)                   {}
func installConsoleHandler(func()) func() { return func() {} }
func explorerConsole() bool               { return false }
func drives() []Drive                     { return nil }
func volumeStats(path string) (uint64, uint64, string, error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, "", err
	}
	return st.Bavail * uint64(st.Bsize), st.Blocks * uint64(st.Bsize), fmt.Sprintf("0x%x", st.Type), nil
}
func absPath(p string) string               { p, _ = filepath.Abs(p); return p }
func renameWithRetry(old, new string) error { return os.Rename(old, new) }
func acquireRunLock(root, version string) (*os.File, error) {
	f, err := os.OpenFile(filepath.Join(root, version+".lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("另一个下载程序正在使用这个目录")
	}
	return f, nil
}
