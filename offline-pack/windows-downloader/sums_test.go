package main

import (
	"strings"
	"testing"
)

func TestParseSumsCRLFAndUppercase(t *testing.T) {
	got, err := parseSums(strings.NewReader(strings.Repeat("A", 64) + "  models/x.bin\r\n"))
	if err != nil || got["models/x.bin"] != strings.Repeat("a", 64) {
		t.Fatalf("got %#v err %v", got, err)
	}
}
func TestPathSafety(t *testing.T) {
	for _, p := range []string{"../x", "a/../x", "C:/x", "a\\x", "CON.txt", "a/ok. ", "a/*"} {
		if validateRelPath(p) == nil {
			t.Errorf("accepted %q", p)
		}
	}
	if validateRelPath("models/sub/file.bin") != nil {
		t.Fatal("valid path rejected")
	}
}
func TestChunkCount(t *testing.T) {
	for _, tt := range []struct {
		s int64
		n int
	}{{0, 0}, {1, 1}, {chunkSize, 1}, {chunkSize + 1, 2}, {20 << 30, 320}} {
		if got := chunkCount(tt.s); got != tt.n {
			t.Errorf("%d: got %d want %d", tt.s, got, tt.n)
		}
	}
}
