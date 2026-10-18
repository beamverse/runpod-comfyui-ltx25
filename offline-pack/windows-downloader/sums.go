package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode"
)

func parseSums(r io.Reader) (map[string]string, error) {
	result := make(map[string]string)
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 64*1024), 2*1024*1024)
	line := 0
	for s.Scan() {
		line++
		text := strings.TrimSuffix(s.Text(), "\r")
		if text == "" {
			continue
		}
		if len(text) < 66 || text[64:66] != "  " {
			return nil, fmt.Errorf("SHA256SUMS第%d行格式错误", line)
		}
		h := strings.ToLower(text[:64])
		if _, err := hex.DecodeString(h); err != nil {
			return nil, fmt.Errorf("SHA256SUMS第%d行哈希错误", line)
		}
		p := text[66:]
		if err := validateRelPath(p); err != nil {
			return nil, fmt.Errorf("SHA256SUMS第%d行路径无效：%w", line, err)
		}
		if _, ok := result[p]; ok {
			return nil, fmt.Errorf("SHA256SUMS包含重复路径：%s", p)
		}
		result[p] = h
	}
	if err := s.Err(); err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("SHA256SUMS为空")
	}
	return result, nil
}

func validateRelPath(p string) error {
	if p == "" || strings.HasPrefix(p, "/") || strings.HasPrefix(p, "\\") {
		return fmt.Errorf("路径必须是相对路径")
	}
	if strings.ContainsRune(p, '\x00') || strings.ContainsAny(p, `<>:"|?*\\`) {
		return fmt.Errorf("包含Windows不允许的字符")
	}
	for _, part := range strings.Split(p, "/") {
		if part == "" || part == "." || part == ".." || strings.HasSuffix(part, " ") || strings.HasSuffix(part, ".") {
			return fmt.Errorf("包含空、点或尾随空格段")
		}
		upper := strings.ToUpper(strings.TrimSuffix(part, "."))
		if isReserved(upper) {
			return fmt.Errorf("使用了保留设备名")
		}
		for _, r := range part {
			if unicode.IsControl(r) {
				return fmt.Errorf("包含控制字符")
			}
		}
	}
	return nil
}

func isReserved(s string) bool {
	base := strings.SplitN(s, ".", 2)[0]
	if base == "CON" || base == "PRN" || base == "AUX" || base == "NUL" {
		return true
	}
	if len(base) == 4 && (strings.HasPrefix(base, "COM") || strings.HasPrefix(base, "LPT")) && base[3] >= '1' && base[3] <= '9' {
		return true
	}
	return false
}

func safeJoin(root, rel string) (string, error) {
	if err := validateRelPath(rel); err != nil {
		return "", err
	}
	parts := strings.Split(rel, "/")
	p := root
	for _, part := range parts {
		p = filepath.Join(p, part)
	}
	return p, nil
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.CopyBuffer(h, f, make([]byte, 4<<20)); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func chunkCount(size int64) int {
	if size <= 0 {
		return 0
	}
	return int((size + chunkSize - 1) / chunkSize)
}

const chunkSize int64 = 64 << 20
