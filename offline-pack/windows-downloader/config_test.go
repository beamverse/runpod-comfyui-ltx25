package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestCredentialValidation(t *testing.T) {
	c := Credentials{AccountID: "0123456789abcdef0123456789abcdef", Bucket: "my-bucket", AccessKey: "abcdefghijklmnop", SecretKey: "ssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssssss", Prefix: "ltx25"}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []Credentials{{AccountID: "bad", Bucket: c.Bucket, AccessKey: c.AccessKey, SecretKey: c.SecretKey, Prefix: c.Prefix}, {AccountID: c.AccountID, Bucket: "BAD", AccessKey: c.AccessKey, SecretKey: c.SecretKey, Prefix: c.Prefix}, {AccountID: c.AccountID, Bucket: c.Bucket, AccessKey: c.AccessKey, SecretKey: c.SecretKey, Prefix: "a/../b"}} {
		if bad.Validate() == nil {
			t.Errorf("accepted invalid %#v", bad)
		}
	}
}

func TestCredentialPrecedence(t *testing.T) {
	oldA, oldB, oldP := defaultAccountID, defaultBucket, defaultPrefix
	defer func() { defaultAccountID, defaultBucket, defaultPrefix = oldA, oldB, oldP }()
	defaultAccountID = "0123456789abcdef0123456789abcdef"
	defaultBucket = "default-bucket"
	defaultPrefix = "default-prefix"
	code := base64.StdEncoding.EncodeToString([]byte("abcdefghijklmnop:ssssssssssssssssssssssssssssssss"))
	get := func(k string) string {
		switch k {
		case "R2_ACCOUNT_ID":
			return "  abcdefabcdefabcdefabcdefabcdefab "
		case "R2_BUCKET":
			return " env-bucket "
		case "LTX25_DOWNLOAD_CODE":
			return code
		}
		return ""
	}
	c, err := loadCredentialsWith(get, strings.NewReader(""), &strings.Builder{}, true)
	if err != nil {
		t.Fatal(err)
	}
	if c.AccountID != "abcdefabcdefabcdefabcdefabcdefab" || c.Bucket != "env-bucket" || c.Prefix != "default-prefix" {
		t.Fatalf("precedence: %#v", c)
	}
}
