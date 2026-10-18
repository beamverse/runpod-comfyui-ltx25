package main

import (
	"encoding/base64"
	"testing"
)

func TestParseLatest(t *testing.T) {
	v, err := parseLatest([]byte(`{"format":1,"version":"test-1","path":"ltx25/test-1"}`))
	if err != nil || v.Version != "test-1" {
		t.Fatalf("%#v %v", v, err)
	}
	if _, err := parseLatest([]byte(`{"format":2,"version":"x"}`)); err == nil {
		t.Fatal("unsupported format accepted")
	}
}

func TestParseDownloadCodeVariants(t *testing.T) {
	key, secret := "abcdefghijklmnop", "ssssssssssssssssssssssssssssssss"
	raw := base64.StdEncoding.EncodeToString([]byte(key + ":" + secret))
	for _, in := range []string{raw, base64.RawStdEncoding.EncodeToString([]byte(key + ":" + secret)), "ltx25:" + raw, " " + raw[:len(raw)/2] + "\n" + raw[len(raw)/2:]} {
		k, s, err := parseDownloadCode(in)
		if err != nil || k != key || s != secret {
			t.Fatalf("%q: %q %q %v", in, k, s, err)
		}
	}
	for _, in := range []string{"nope", raw + "x"} {
		if _, _, err := parseDownloadCode(in); err == nil {
			t.Fatalf("accepted %q", in)
		}
	}
}
