package main

import (
	"bytes"
	"crypto/rand"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// Network bodies arrive in many Read calls; each one becomes a separate Write.
func TestReviewWriterAtOffsets(t *testing.T) {
	want := make([]byte, 64<<10)
	rand.Read(want)
	p := filepath.Join(t.TempDir(), "x.part")
	f, _ := os.Create(p)
	f.Truncate(int64(len(want)) + 100)
	const start = 100
	_, err := io.CopyBuffer(writerAt{f, start}, smallReader{bytes.NewReader(want)}, make([]byte, 8<<20))
	f.Close()
	got, _ := os.ReadFile(p)
	if err != nil || !bytes.Equal(got[start:], want) {
		nonzero := 0
		for _, b := range got[start+4096:] {
			if b != 0 {
				nonzero++
			}
		}
		t.Errorf("chunk written incorrectly: err=%v, bytes beyond the first write that are non-zero: %d of %d", err, nonzero, len(want)-4096)
	}
}

type smallReader struct{ r io.Reader }

func (s smallReader) Read(p []byte) (int, error) {
	if len(p) > 1024 {
		p = p[:1024]
	}
	return s.r.Read(p)
}
