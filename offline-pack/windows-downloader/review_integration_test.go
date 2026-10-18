package main

import (
	"context"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

type fakeS3 struct{ files map[string][]byte }

func (f *fakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/bucket")
	if path == "" || path == "/" {
		prefix := r.URL.Query().Get("prefix")
		var keys []string
		for k := range f.files {
			if strings.HasPrefix(k, prefix) {
				keys = append(keys, k)
			}
		}
		sort.Strings(keys)
		var b strings.Builder
		b.WriteString(`<?xml version="1.0" encoding="UTF-8"?><ListBucketResult><Name>bucket</Name><Prefix>` + prefix + `</Prefix><KeyCount>` + strconv.Itoa(len(keys)) + `</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated>`)
		for _, k := range keys {
			fmt.Fprintf(&b, `<Contents><Key>%s</Key><Size>%d</Size><ETag>"%x"</ETag><LastModified>2026-10-18T00:00:00.000Z</LastModified></Contents>`, k, len(f.files[k]), md5.Sum(f.files[k]))
		}
		b.WriteString(`</ListBucketResult>`)
		w.Header().Set("Content-Type", "application/xml")
		w.Write([]byte(b.String()))
		return
	}
	key, _ := url.PathUnescape(strings.TrimPrefix(path, "/"))
	data, ok := f.files[key]
	if !ok {
		w.WriteHeader(404)
		w.Write([]byte(`<Error><Code>NoSuchKey</Code></Error>`))
		return
	}
	w.Header().Set("ETag", fmt.Sprintf(`"%x"`, md5.Sum(data)))
	w.Header().Set("Last-Modified", "Sun, 18 Oct 2026 00:00:00 GMT")
	start, end := 0, len(data)-1
	if rg := r.Header.Get("Range"); rg != "" {
		fmt.Sscanf(rg, "bytes=%d-%d", &start, &end)
		if end >= len(data) {
			end = len(data) - 1
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(data)))
		w.Header().Set("Content-Length", strconv.Itoa(end-start+1))
		w.WriteHeader(206)
	} else {
		w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	}
	if r.Method == http.MethodHead {
		return
	}
	body := data[start : end+1]
	for len(body) > 0 { // small writes so the client reads in many pieces
		n := 1 << 20 // large writes: small ones are very slow over WSL loopback
		if n > len(body) {
			n = len(body)
		}
		w.Write(body[:n])
		body = body[n:]
	}
}

func setup(t *testing.T) (*R2, map[string]Object, string, map[string][]byte) {
	big := make([]byte, 3<<20+12345)
	rand.Read(big)
	files := map[string][]byte{"models/a/big.bin": big, "pack.env": []byte("PACK_FORMAT=1\n"), "empty.txt": {}}
	var sums strings.Builder
	var names []string
	for k := range files {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		h := sha256.Sum256(files[k])
		fmt.Fprintf(&sums, "%s  %s\n", hex.EncodeToString(h[:]), k)
	}
	files["SHA256SUMS"] = []byte(sums.String())
	srv := map[string][]byte{}
	for k, v := range files {
		srv["ltx25/test-1/"+k] = v
	}
	ts := httptest.NewServer(&fakeS3{srv})
	t.Cleanup(ts.Close)
	m, err := minio.New(strings.TrimPrefix(ts.URL, "http://"), &minio.Options{Creds: credentials.NewStaticV4("AK", "SK", ""), Secure: false, Region: "auto", BucketLookup: minio.BucketLookupPath})
	if err != nil {
		t.Fatal(err)
	}
	r := &R2{client: m, bucket: "bucket", prefix: "ltx25", accessKey: "AK", secretKey: "SK"}
	objs, err := r.list(context.Background(), "test-1")
	if err != nil {
		t.Fatal(err)
	}
	return r, objs, t.TempDir(), files
}

// Same order as runMain: SHA256SUMS is fetched into <version>.partial before run() creates it.
func TestReviewMainOrderFreshDownload(t *testing.T) {
	r, objs, root, _ := setup(t)
	d := &downloader{r2: r, root: root, version: "test-1", objects: objs, concurrency: 4, logf: t.Logf}
	err := d.downloadSums(context.Background(), filepath.Join(root, "test-1.partial"))
	t.Logf("downloadSums on a fresh root: err=%v", err)
	if err != nil {
		t.Errorf("FRESH DOWNLOAD FAILS BEFORE ANY DATA IS FETCHED: %v", err)
	}
}

func TestReviewRunContent(t *testing.T) {
	r, objs, root, files := setup(t)
	d := &downloader{r2: r, root: root, version: "test-1", objects: objs, concurrency: 4, logf: t.Logf}
	err := d.run(context.Background())
	t.Logf("run: err=%v", err)
	if err != nil {
		t.Fatalf("run failed: %v", err)
	}
	for k, want := range files {
		got, e := os.ReadFile(filepath.Join(root, "test-1", filepath.FromSlash(k)))
		if e != nil || string(got) != string(want) {
			t.Errorf("%s mismatch (%v)", k, e)
		}
	}
}

func TestReviewStaleLockBlocksResume(t *testing.T) {
	r, objs, root, _ := setup(t)
	partial := filepath.Join(root, "test-1.partial")
	os.MkdirAll(partial, 0755)
	os.WriteFile(filepath.Join(partial, ".lock"), nil, 0600) // left behind by a killed process
	d := &downloader{r2: r, root: root, version: "test-1", objects: objs, concurrency: 4, logf: t.Logf}
	if err := d.run(context.Background()); err != nil {
		t.Errorf("resume after a killed run is blocked: %v", err)
	}
}
