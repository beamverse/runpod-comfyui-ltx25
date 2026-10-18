package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func chooseDestination(in io.Reader, out io.Writer, required int64) (string, error) {
	ds := drives()
	if len(ds) > 0 {
		fmt.Fprintln(out, "可用磁盘：")
		for i, d := range ds {
			if d.Usable && int64(d.Free) < required+1<<30 {
				d.Usable = false
				d.Reason = "可用空间不足"
				ds[i] = d
			}
			fmt.Fprintf(out, "%d) %s %s %s %s 可用%s/%s", i+1, d.Root, d.Label, d.Type, d.FS, formatBytes(int64(d.Free)), formatBytes(int64(d.Total)))
			if !d.Usable {
				fmt.Fprintf(out, " 不可用：%s", d.Reason)
			}
			fmt.Fprintln(out)
		}
	}
	s := bufio.NewScanner(in)
	for attempt := 0; attempt < 5; attempt++ {
		fmt.Fprint(out, "输入磁盘编号或自定义绝对路径：")
		if !s.Scan() {
			return "", s.Err()
		}
		v := strings.TrimSpace(s.Text())
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= len(ds) && ds[n-1].Usable {
			return filepath.Join(ds[n-1].Root, "ltx25"), nil
		}
		if filepath.IsAbs(v) {
			return absPath(v), nil
		}
		fmt.Fprintln(out, "选择无效，请重新输入。")
	}
	return "", fmt.Errorf("磁盘选择失败次数过多")
}
func formatBytes(n int64) string { const g = 1 << 30; return fmt.Sprintf("%.1f GiB", float64(n)/g) }
func logWriter(root, version string) (*os.File, error) {
	return os.OpenFile(filepath.Join(root, "ltx25-download-"+version+".log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
}
