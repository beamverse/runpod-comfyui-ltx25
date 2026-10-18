package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

type R2 struct {
	client               *minio.Client
	bucket, prefix       string
	accessKey, secretKey string
}
type Latest struct {
	Format  int                          `json:"format"`
	Version string                       `json:"version"`
	Path    string                       `json:"path"`
	Created string                       `json:"created"`
	ComfyUI struct{ Ref, Commit string } `json:"comfyui"`
	Bytes   int64                        `json:"bytes"`
}
type Object struct {
	Path string
	Size int64
	ETag string
}

func newR2(c Credentials, concurrency int) (*R2, error) {
	tr := &http.Transport{Proxy: http.ProxyFromEnvironment, DialContext: (&net.Dialer{Timeout: 30 * time.Second, KeepAlive: 30 * time.Second}).DialContext, ForceAttemptHTTP2: true, IdleConnTimeout: 90 * time.Second, MaxIdleConns: concurrency + 4, MaxIdleConnsPerHost: concurrency + 4, TLSHandshakeTimeout: 15 * time.Second, ResponseHeaderTimeout: 60 * time.Second, DisableKeepAlives: false}
	m, err := minio.New(c.AccountID+".r2.cloudflarestorage.com", &minio.Options{Creds: credentials.NewStaticV4(c.AccessKey, c.SecretKey, ""), Secure: true, Region: "auto", BucketLookup: minio.BucketLookupPath, Transport: tr})
	if err != nil {
		return nil, err
	}
	return &R2{client: m, bucket: c.Bucket, prefix: strings.Trim(c.Prefix, "/"), accessKey: c.AccessKey, secretKey: c.SecretKey}, nil
}

func (r *R2) explain(err error) error {
	e := explainR2Error(err)
	if e == nil {
		return nil
	}
	msg := e.Error()
	if r.accessKey != "" {
		msg = strings.ReplaceAll(msg, r.accessKey, "<access-key>")
	}
	if r.secretKey != "" {
		msg = strings.ReplaceAll(msg, r.secretKey, "<secret>")
	}
	return errors.New(msg)
}

func (r *R2) objectKey(parts ...string) string {
	vals := append([]string{r.prefix}, parts...)
	return strings.Join(vals, "/")
}

func (r *R2) latest(ctx context.Context) (Latest, []byte, error) {
	obj, err := r.client.GetObject(ctx, r.bucket, r.objectKey("latest.json"), minio.GetObjectOptions{})
	if err != nil {
		return Latest{}, nil, r.explain(err)
	}
	defer obj.Close()
	b, err := io.ReadAll(obj)
	if err != nil {
		return Latest{}, nil, r.explain(err)
	}
	v, err := parseLatest(b)
	if err != nil {
		return Latest{}, nil, err
	}
	return v, b, nil
}

func parseLatest(b []byte) (Latest, error) {
	var v Latest
	if err := json.Unmarshal(b, &v); err != nil {
		return v, fmt.Errorf("latest.json格式错误：%w", err)
	}
	if v.Format != 1 {
		return v, fmt.Errorf("此下载器版本过旧，无法读取安装包格式%d", v.Format)
	}
	if !versionRE.MatchString(v.Version) {
		return v, errors.New("latest.json中的version无效")
	}
	return v, nil
}

func (r *R2) list(ctx context.Context, version string) (map[string]Object, error) {
	result := make(map[string]Object)
	prefix := r.objectKey(version) + "/"
	for obj := range r.client.ListObjects(ctx, r.bucket, minio.ListObjectsOptions{Prefix: prefix, Recursive: true}) {
		if obj.Err != nil {
			return nil, r.explain(obj.Err)
		}
		rel := strings.TrimPrefix(obj.Key, prefix)
		if rel == "" {
			continue
		}
		result[rel] = Object{Path: rel, Size: obj.Size, ETag: strings.Trim(obj.ETag, `"`)}
	}
	return result, nil
}

func (r *R2) get(ctx context.Context, version, rel string, start, end int64) (io.ReadCloser, string, error) {
	opts := minio.GetObjectOptions{}
	if err := opts.SetRange(start, end); err != nil {
		return nil, "", err
	}
	obj, err := r.client.GetObject(ctx, r.bucket, r.objectKey(version, rel), opts)
	if err != nil {
		return nil, "", r.explain(err)
	}
	st, err := obj.Stat()
	if err != nil {
		obj.Close()
		return nil, "", r.explain(err)
	}
	return obj, strings.Trim(st.ETag, `"`), nil
}

func explainR2Error(err error) error {
	if err == nil {
		return nil
	}
	var e minio.ErrorResponse
	if errors.As(err, &e) {
		switch e.Code {
		case "InvalidAccessKeyId":
			return errors.New("R2_ACCESS_KEY_ID错误，或该token已删除/过期")
		case "SignatureDoesNotMatch":
			return errors.New("R2_SECRET_ACCESS_KEY与R2_ACCESS_KEY_ID不匹配")
		case "NoSuchBucket":
			return errors.New("bucket不存在（或创建时选了EU jurisdiction）")
		case "AccessDenied":
			return errors.New("token对该bucket没有读取权限")
		case "NoSuchKey":
			return errors.New("R2上还没有发布任何版本")
		}
		if e.StatusCode == http.StatusForbidden {
			return errors.New("token对该bucket没有读取权限")
		}
	}
	var ne net.Error
	var ue *url.Error
	if (errors.As(err, &ne) && (ne.Timeout() || ne.Temporary())) || errors.As(err, &ue) {
		return errors.New("无法连接R2，请检查网络和R2_ACCOUNT_ID")
	}
	return fmt.Errorf("R2请求失败：%s", err.Error())
}
