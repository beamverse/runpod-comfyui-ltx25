package main

import (
	"fmt"
	"os"
	"path/filepath"
)

type verificationError struct{ err error }

func (e verificationError) Error() string { return e.err.Error() }
func (e verificationError) Unwrap() error { return e.err }

func verifyDir(root, version string, sums map[string]string, logf func(string, ...any)) error {
	failed := 0
	for rel, expected := range sums {
		p, err := safeJoin(filepath.Join(root, version), rel)
		if err != nil {
			failed++
			fmt.Printf("失败 %s：%v\n", rel, err)
			continue
		}
		st, err := os.Stat(p)
		if err != nil {
			failed++
			fmt.Printf("失败 %s：文件不存在\n", rel)
			continue
		}
		got, err := hashFile(p)
		if err != nil {
			failed++
			fmt.Printf("失败 %s：%v\n", rel, err)
			continue
		}
		if got != expected {
			failed++
			fmt.Printf("失败 %s：SHA256不匹配\n", rel)
		} else {
			logf("验证通过：%s (%d bytes)", rel, st.Size())
		}
	}
	if failed > 0 {
		return verificationError{fmt.Errorf("校验失败：%d个文件", failed)}
	}
	fmt.Println("全部文件匹配SHA256SUMS。")
	return nil
}
