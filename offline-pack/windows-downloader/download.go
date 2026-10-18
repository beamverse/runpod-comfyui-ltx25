package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type downloader struct {
	r2            *R2
	root, version string
	objects       map[string]Object
	sums          map[string]string
	concurrency   int
	logf          func(string, ...any)
	mu            sync.Mutex
	doneBytes     int64
	runLock       io.Closer
}

func (d *downloader) run(ctx context.Context) error {
	partial := filepath.Join(d.root, d.version+".partial")
	if err := os.MkdirAll(d.root, 0755); err != nil {
		return err
	}
	lock := d.runLock
	if lock == nil {
		var err error
		lock, err = acquireRunLock(d.root, d.version)
		if err != nil {
			return err
		}
		defer lock.Close()
	}
	if err := os.MkdirAll(partial, 0755); err != nil {
		return err
	}
	if d.sums == nil {
		if err := d.downloadSums(ctx, partial); err != nil {
			return err
		}
	}
	sem := make(chan struct{}, d.concurrency)
	for rel, obj := range d.objects {
		if rel == "SHA256SUMS" {
			continue
		}
		expected, ok := d.sums[rel]
		if !ok {
			d.logf("警告：R2中的额外文件已忽略：%s", rel)
			continue
		}
		if err := d.downloadFile(ctx, partial, rel, obj, expected, sem); err != nil {
			return err
		}
	}
	if err := os.RemoveAll(filepath.Join(partial, ".ltx25-state")); err != nil {
		return err
	}
	_ = os.Remove(filepath.Join(partial, ".lock"))
	final := filepath.Join(d.root, d.version)
	if _, err := os.Stat(final); err == nil {
		old := final + ".old-" + time.Now().Format("20060102-150405")
		if err := renameWithRetry(final, old); err != nil {
			return fmt.Errorf("无法保留旧版本：%w", err)
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	return renameWithRetry(partial, final)
}

func (d *downloader) downloadSums(ctx context.Context, partial string) error {
	if err := os.MkdirAll(partial, 0755); err != nil {
		return err
	}
	obj, ok := d.objects["SHA256SUMS"]
	if !ok {
		return errors.New("R2上的安装包不完整：缺少SHA256SUMS")
	}
	rc, _, err := d.r2.get(ctx, d.version, "SHA256SUMS", 0, obj.Size-1)
	if err != nil {
		return err
	}
	defer rc.Close()
	p := filepath.Join(partial, "SHA256SUMS")
	f, err := os.Create(p)
	if err != nil {
		return err
	}
	_, err = io.Copy(f, rc)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	b, err := os.Open(p)
	if err != nil {
		return err
	}
	defer b.Close()
	d.sums, err = parseSums(b)
	return err
}

func (d *downloader) downloadFile(ctx context.Context, partial, rel string, obj Object, expected string, sem chan struct{}) error {
	return d.downloadFileAttempt(ctx, partial, rel, obj, expected, sem, true)
}
func (d *downloader) downloadFileAttempt(ctx context.Context, partial, rel string, obj Object, expected string, sem chan struct{}, allowRetry bool) error {
	d.logf("开始：%s (%d bytes)", rel, obj.Size)
	final, err := safeJoin(partial, rel)
	if err != nil {
		return err
	}
	if st, e := os.Stat(final); e == nil && st.Size() == obj.Size {
		if got, he := hashFile(final); he == nil && got == expected {
			d.logf("跳过已校验文件：%s", rel)
			return nil
		}
		_ = os.Remove(final)
	}
	if err := os.MkdirAll(filepath.Dir(final), 0755); err != nil {
		return err
	}
	part := final + ".part"
	stPath := statePath(partial, rel)
	n := chunkCount(obj.Size)
	s, valid := stateLoad(stPath)
	if !valid || s.Path != rel || s.Size != obj.Size || s.ETag != obj.ETag || s.ChunkSize != chunkSize {
		_ = os.Remove(part)
		_ = os.Remove(stPath)
		s = fileState{Path: rel, Size: obj.Size, ETag: obj.ETag, ChunkSize: chunkSize}
	}
	f, err := os.OpenFile(part, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return err
	}
	closed := false
	defer func() {
		if !closed {
			_ = f.Close()
		}
	}()
	if err := f.Truncate(obj.Size); err != nil {
		return err
	}
	var wg sync.WaitGroup
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		if bitGet(s.Done, i) {
			continue
		}
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			if err := d.chunk(ctx, f, rel, obj, i, n, &s, stPath); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	select {
	case e := <-errs:
		return e
	default:
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	closed = true
	got, err := hashFile(part)
	if err != nil {
		return err
	}
	if got != expected {
		_ = os.Remove(part)
		_ = os.Remove(stPath)
		if allowRetry {
			return d.downloadFileAttempt(ctx, partial, rel, obj, expected, sem, false)
		}
		return verificationError{fmt.Errorf("文件校验失败：%s", rel)}
	}
	if err := renameWithRetry(part, final); err != nil {
		_ = os.Remove(final)
		if err = renameWithRetry(part, final); err != nil {
			return err
		}
	}
	_ = os.Remove(stPath)
	d.logf("完成并校验：%s", rel)
	return nil
}

func (d *downloader) chunk(ctx context.Context, f *os.File, rel string, obj Object, i, n int, s *fileState, state string) error {
	start := int64(i) * chunkSize
	end := start + chunkSize - 1
	if end >= obj.Size {
		end = obj.Size - 1
	}
	var last error
	for attempt := 0; attempt < 10; attempt++ {
		if attempt > 0 {
			delay := time.Duration(1<<min(attempt-1, 6)) * time.Second
			if delay > 60*time.Second {
				delay = 60 * time.Second
			}
			delay += time.Duration(rand.Int63n(int64(delay/4 + 1)))
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(delay):
			}
		}
		rc, etag, err := d.r2.get(ctx, d.version, rel, start, end)
		if err == nil && obj.ETag != "" && etag != obj.ETag {
			rc.Close()
			return errors.New("R2上的文件在下载期间被更新")
		}
		if err == nil {
			buf := make([]byte, 8<<20)
			_, err = io.CopyBuffer(io.NewOffsetWriter(f, start), rc, buf)
			rc.Close()
			if err != nil {
				err = d.r2.explain(err)
			}
			if err == nil {
				d.mu.Lock()
				if syncErr := f.Sync(); syncErr != nil {
					d.mu.Unlock()
					err = syncErr
					last = err
					continue
				}
				s.Done = bitSet(s.Done, n, i)
				snapshot := *s
				err = stateSave(state, snapshot)
				d.mu.Unlock()
				if err == nil {
					return nil
				}
			}
		}
		last = err
		if err != nil && !retryable(err) {
			return err
		}
	}
	return fmt.Errorf("下载%s失败：%w", rel, last)
}

type writerAt struct {
	f   *os.File
	off int64
}

func (w writerAt) Write(p []byte) (int, error) {
	pos, err := w.f.Seek(0, io.SeekCurrent)
	if err != nil {
		return 0, err
	}
	if pos == 0 && w.off != 0 {
		if _, err = w.f.Seek(w.off, io.SeekStart); err != nil {
			return 0, err
		}
	}
	return w.f.Write(p)
}
func retryable(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return !strings.Contains(msg, "没有读取权限") && !strings.Contains(msg, "不存在") && !strings.Contains(msg, "还没有发布") && !strings.Contains(msg, "下载期间被更新")
}
