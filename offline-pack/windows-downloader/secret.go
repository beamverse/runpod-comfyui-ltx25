package main

import (
	"bufio"
	"context"
	"io"
	"unicode"
)

// Limit read-ahead so a pasted newline cannot consume the next prompt's input.
type secretByteReader struct{ io.Reader }

func (r secretByteReader) Read(p []byte) (int, error) {
	if len(p) > 1 {
		p = p[:1]
	}
	return r.Reader.Read(p)
}

func readMaskedLine(in io.Reader, out io.Writer) (string, error) {
	reader := bufio.NewReader(secretByteReader{in})
	var value []rune
	escape := 0
	for {
		r, _, err := reader.ReadRune()
		if err != nil {
			return "", err
		}
		// Ignore cursor keys and bracketed-paste markers emitted by VT consoles.
		if escape != 0 {
			if escape == 1 && (r == '[' || r == 'O') {
				escape = 2
				continue
			}
			if escape == 1 || (r >= 0x40 && r <= 0x7e) {
				escape = 0
			}
			continue
		}
		var feedback string
		switch r {
		case '\r', '\n':
			_, err := io.WriteString(out, "\r\n")
			if err != nil {
				return "", err
			}
			return string(value), nil
		case 3:
			_, _ = io.WriteString(out, "\r\n")
			return "", context.Canceled
		case 4, 26:
			return "", io.EOF
		case '\b', 127:
			if len(value) > 0 {
				value = value[:len(value)-1]
				feedback = "\b \b"
			}
		case 21:
			for range value {
				if _, err := io.WriteString(out, "\b \b"); err != nil {
					return "", err
				}
			}
			value = value[:0]
		case 27:
			escape = 1
		default:
			if !unicode.IsControl(r) {
				value = append(value, r)
				feedback = "*"
			}
		}
		if feedback != "" {
			if _, err := io.WriteString(out, feedback); err != nil {
				return "", err
			}
		}
	}
}
