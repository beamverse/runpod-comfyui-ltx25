package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestMaskedInput(t *testing.T) {
	for _, tc := range []struct{ name, input, want, feedback string }{
		{"paste", "ltx25:Ab+/=_-\r", "ltx25:Ab+/=_-", strings.Repeat("*", 13) + "\r\n"},
		{"backspace", "abc\b\x7fd\n", "ad", "***\b \b\b \b*\r\n"},
		{"empty backspace", "\b\x7fa\n", "a", "*\r\n"},
		{"clear", "abc\x15d\n", "d", "***" + strings.Repeat("\b \b", 3) + "*\r\n"},
		{"unicode", "码\bA\n", "A", "*\b \b*\r\n"},
		{"VT paste and arrows", "\x1b[200~abc\x1b[201~\x1b[D\n", "abc", "***\r\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			got, err := readMaskedLine(strings.NewReader(tc.input), &out)
			if err != nil || got != tc.want || out.String() != tc.feedback {
				t.Fatalf("masked input or feedback mismatch: err=%v", err)
			}
		})
	}
}

func TestMaskedInputLeavesNextPromptUntouched(t *testing.T) {
	in := strings.NewReader("code\nnext\n")
	if _, err := readMaskedLine(in, io.Discard); err != nil {
		t.Fatal(err)
	}
	rest, _ := io.ReadAll(in)
	if string(rest) != "next\n" {
		t.Fatal("consumed the next prompt's input")
	}
}

func TestMaskedInputInterrupted(t *testing.T) {
	var out bytes.Buffer
	got, err := readMaskedLine(strings.NewReader("secret\x03"), &out)
	if got != "" || !errors.Is(err, context.Canceled) || strings.Contains(out.String(), "secret") {
		t.Fatal("cancellation leaked input or returned the wrong error")
	}
}

func TestSecretPipeInputUnchanged(t *testing.T) {
	var out bytes.Buffer
	got, err := readSecret(strings.NewReader("code\n"), &out)
	if err != nil || got != "code\n" || out.Len() != 0 {
		t.Fatal("redirected input changed")
	}
}
