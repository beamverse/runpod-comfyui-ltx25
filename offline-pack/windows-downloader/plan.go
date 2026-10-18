package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type fileState struct {
	Path      string `json:"path"`
	Size      int64  `json:"size"`
	ETag      string `json:"etag"`
	ChunkSize int64  `json:"chunk_size"`
	Done      string `json:"done"`
}

func statePath(partial, rel string) string {
	h := sha256.Sum256([]byte(rel))
	return filepath.Join(partial, ".ltx25-state", fmt.Sprintf("%x.json", h[:]))
}
func stateLoad(path string) (fileState, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return fileState{}, false
	}
	var s fileState
	if json.Unmarshal(b, &s) != nil || s.Path == "" {
		return fileState{}, false
	}
	return s, true
}
func stateSave(path string, s fileState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + fmt.Sprintf(".%d.tmp", time.Now().UnixNano())
	if err = os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return renameWithRetry(tmp, path)
}
func bitGet(encoded string, i int) bool {
	b, err := base64.StdEncoding.DecodeString(encoded)
	return err == nil && i/8 < len(b) && b[i/8]&(1<<uint(i%8)) != 0
}
func bitSet(encoded string, n, i int) string {
	b, _ := base64.StdEncoding.DecodeString(encoded)
	if len(b) < (n+7)/8 {
		b = append(b, make([]byte, (n+7)/8-len(b))...)
	}
	b[i/8] |= 1 << uint(i%8)
	return base64.StdEncoding.EncodeToString(b)
}
func allBits(encoded string, n int) bool {
	for i := 0; i < n; i++ {
		if !bitGet(encoded, i) {
			return false
		}
	}
	return true
}
