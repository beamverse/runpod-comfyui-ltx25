package main

import (
	"bufio"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"

	"golang.org/x/term"
)

var defaultAccountID, defaultBucket = "", ""
var defaultPrefix = "ltx25"

type Credentials struct {
	AccountID, Bucket, AccessKey, SecretKey, Prefix string
	CodeWarning                                     string
}

var (
	accountIDRE = regexp.MustCompile(`^[a-f0-9]{32}$`)
	bucketRE    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`)
	prefixRE    = regexp.MustCompile(`^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$`)
	keyIDRE     = regexp.MustCompile(`^[A-Za-z0-9]{16,128}$`)
	secretRE    = regexp.MustCompile(`^[A-Za-z0-9+/=_-]{32,128}$`)
)

func (c Credentials) Validate() error {
	if !accountIDRE.MatchString(c.AccountID) {
		return errors.New("R2_ACCOUNT_ID必须是32位小写十六进制账号ID")
	}
	if !bucketRE.MatchString(c.Bucket) {
		return errors.New("R2_BUCKET不是有效的bucket名称")
	}
	if !keyIDRE.MatchString(c.AccessKey) || !secretRE.MatchString(c.SecretKey) {
		return errors.New("下载码内容无效：请向管理员重新索取")
	}
	if !prefixRE.MatchString(c.Prefix) || strings.Contains("/"+c.Prefix+"/", "/../") {
		return errors.New("R2_PREFIX只能包含字母、数字、点、下划线、连字符和斜杠")
	}
	return nil
}

func LoadCredentials(in io.Reader, out io.Writer, allowPrompt bool) (Credentials, error) {
	return loadCredentialsWith(os.Getenv, in, out, allowPrompt)
}

func loadCredentialsWith(get func(string) string, in io.Reader, out io.Writer, allowPrompt bool) (Credentials, error) {
	trimmed := func(name string) string { return strings.TrimSpace(get(name)) }
	c := Credentials{AccountID: trimmed("R2_ACCOUNT_ID"), Bucket: trimmed("R2_BUCKET"), Prefix: trimmed("R2_PREFIX")}
	if c.AccountID == "" {
		c.AccountID = strings.TrimSpace(defaultAccountID)
	}
	if c.Bucket == "" {
		c.Bucket = strings.TrimSpace(defaultBucket)
	}
	if c.Prefix == "" {
		c.Prefix = strings.TrimSpace(defaultPrefix)
		if c.Prefix == "" {
			c.Prefix = "ltx25"
		}
	}
	missing := func() []string {
		var m []string
		for n, v := range map[string]string{"R2_ACCOUNT_ID": c.AccountID, "R2_BUCKET": c.Bucket} {
			if v == "" {
				m = append(m, n)
			}
		}
		sort.Strings(m)
		return m
	}
	if len(missing()) > 0 && !allowPrompt {
		return c, fmt.Errorf("缺少环境变量：%s", strings.Join(missing(), ", "))
	}
	reader := bufio.NewReader(in)
	for _, item := range []struct {
		name string
		dst  *string
	}{{"R2_ACCOUNT_ID", &c.AccountID}, {"R2_BUCKET", &c.Bucket}} {
		if *item.dst != "" {
			continue
		}
		if _, err := fmt.Fprintf(out, "%s: ", item.name); err != nil {
			return c, err
		}
		v, err := reader.ReadString('\n')
		if err != nil && err != io.EOF {
			return c, err
		}
		*item.dst = strings.TrimSpace(v)
	}
	code := trimmed("LTX25_DOWNLOAD_CODE")
	if code != "" {
		key, secret, err := parseDownloadCode(code)
		if err != nil {
			return c, fmt.Errorf("LTX25_DOWNLOAD_CODE无效：%w", err)
		}
		c.AccessKey, c.SecretKey = key, secret
		c.CodeWarning = codeWarning(key, secret)
	} else {
		key, secret := trimmed("R2_ACCESS_KEY_ID"), trimmed("R2_SECRET_ACCESS_KEY")
		if key != "" || secret != "" {
			if key == "" {
				return c, errors.New("缺少环境变量：R2_ACCESS_KEY_ID")
			}
			if secret == "" {
				return c, errors.New("缺少环境变量：R2_SECRET_ACCESS_KEY")
			}
			c.AccessKey, c.SecretKey = key, secret
		} else {
			if !allowPrompt {
				return c, errors.New("缺少下载码：请设置LTX25_DOWNLOAD_CODE")
			}
			var last error
			for attempt := 0; attempt < 3; attempt++ {
				fmt.Fprint(out, "请粘贴下载码，然后按回车：")
				secretReader := io.Reader(reader)
				if f, ok := in.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
					secretReader = in
				}
				raw, err := readSecret(secretReader, out)
				if err != nil {
					return c, err
				}
				key, secret, err := parseDownloadCode(raw)
				if err != nil {
					last = err
					fmt.Fprintln(out, err)
					continue
				}
				c.AccessKey, c.SecretKey = key, secret
				c.CodeWarning = codeWarning(key, secret)
				fmt.Fprintf(out, "已读取下载码（%d个字符）\n", len([]rune(strings.TrimSpace(raw))))
				last = nil
				break
			}
			if last != nil {
				return c, last
			}
		}
	}
	if err := c.Validate(); err != nil {
		return c, err
	}
	return c, nil
}

func parseDownloadCode(s string) (string, string, error) {
	s = strings.TrimPrefix(strings.Join(strings.Fields(s), ""), "ltx25:")
	var decoded []byte
	var err error
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		decoded, err = enc.DecodeString(s)
		if err == nil {
			break
		}
	}
	if err != nil {
		return "", "", errors.New("下载码格式不对：请完整复制，不要漏掉开头或结尾")
	}
	parts := strings.Split(string(decoded), ":")
	if len(parts) != 2 || !keyIDRE.MatchString(parts[0]) || !secretRE.MatchString(parts[1]) {
		return "", "", errors.New("下载码内容无效：请向管理员重新索取")
	}
	return parts[0], parts[1], nil
}
func codeWarning(key, secret string) string {
	if len(key) != 32 || len(secret) != 64 {
		return fmt.Sprintf("下载码长度异常：key=%d secret=%d", len(key), len(secret))
	}
	return ""
}
func readSecret(in io.Reader, out io.Writer) (string, error) {
	if br, ok := in.(*bufio.Reader); ok {
		return br.ReadString('\n')
	}
	if f, ok := in.(*os.File); ok && term.IsTerminal(int(f.Fd())) {
		b, e := term.ReadPassword(int(f.Fd()))
		fmt.Fprintln(out)
		return string(b), e
	}
	return bufio.NewReader(in).ReadString('\n')
}
