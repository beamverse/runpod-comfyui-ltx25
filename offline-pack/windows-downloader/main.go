package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var buildVersion = "dev"
var versionRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func main() { os.Exit(runMain()) }

func runMain() int {
	configureConsole()
	fs := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	dest := fs.String("dest", "", "Root directory (required for scripts)")
	requested := fs.String("version", "", "Pack version")
	yes := fs.Bool("yes", false, "Skip confirmations")
	verifyOnly := fs.Bool("verify-only", false, "Verify an existing pack")
	conc := fs.Int("concurrency", 16, "Concurrent range requests")
	noPause := fs.Bool("no-pause", false, "Never pause before exit")
	about := fs.Bool("about", false, "Print build version")
	makeCode := fs.Bool("make-code", false, "Create a download code")
	if err := fs.Parse(os.Args[1:]); err != nil {
		return 2
	}
	if *about {
		fmt.Printf("ltx25-download %s\n", buildVersion)
		return 0
	}
	if *makeCode {
		return makeDownloadCode(os.Stdin, os.Stdout)
	}
	if *conc < 1 || *conc > 128 {
		fmt.Fprintln(os.Stderr, "--concurrency必须在1到128之间")
		return 2
	}
	interactive := *dest == "" && !*verifyOnly
	if *verifyOnly {
		if *dest == "" || *requested == "" {
			fmt.Fprintln(os.Stderr, "--verify-only需要同时指定--dest和--version")
			return 2
		}
		return finish(verifyExisting(*dest, *requested), *noPause, false)
	}
	var root string
	var err error
	if *dest != "" {
		root = absPath(*dest)
	}
	creds, err := LoadCredentials(os.Stdin, os.Stdout, !*yes)
	if err != nil {
		return finish(err, *noPause, interactive)
	}
	r2, err := newR2(creds, *conc)
	if err != nil {
		return finish(err, *noPause, interactive)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	removeConsoleHandler := installConsoleHandler(cancel)
	defer removeConsoleHandler()
	preventSleep(true)
	defer preventSleep(false)
	var latestRaw []byte
	version := *requested
	var comfyRef string
	if version == "" {
		latest, raw, e := r2.latest(ctx)
		if e != nil {
			return finish(e, *noPause, interactive)
		}
		version, latestRaw = latest.Version, raw
		comfyRef = latest.ComfyUI.Ref
	}
	if !versionRE.MatchString(version) {
		return finish(errors.New("版本号无效"), *noPause, interactive)
	}
	objects, err := r2.list(ctx, version)
	if err != nil {
		return finish(err, *noPause, interactive)
	}
	if _, ok := objects["SHA256SUMS"]; !ok {
		return finish(errors.New("R2上的安装包不完整：缺少SHA256SUMS"), *noPause, interactive)
	}
	if comfyRef != "" {
		fmt.Printf("安装包版本：%s  ComfyUI：%s  总大小：%s\n", version, comfyRef, formatBytes(sumObjectBytes(objects)))
	}
	if root == "" {
		root, err = chooseDestination(os.Stdin, os.Stdout, sumObjectBytes(objects))
		if err != nil {
			return finish(err, *noPause, interactive)
		}
	}
	if err = os.MkdirAll(root, 0755); err != nil {
		return finish(err, *noPause, interactive)
	}
	partial := filepath.Join(root, version+".partial")
	final := filepath.Join(root, version)
	if _, e := os.Stat(filepath.Join(final, "SHA256SUMS")); e == nil {
		if _, pe := os.Stat(partial); os.IsNotExist(pe) {
			fmt.Printf("版本%s已经下载。\n", version)
			if *yes {
				return finishCode(0, *noPause, interactive)
			}
			fmt.Print("[V] 重新校验  [Q] 退出（默认） ")
			var answer string
			fmt.Scanln(&answer)
			if strings.EqualFold(strings.TrimSpace(answer), "v") {
				return finish(verifyExisting(root, version), *noPause, interactive)
			}
			return finishCode(0, *noPause, interactive)
		}
	}
	var sums map[string]string
	// The authority check is done after the small SHA256SUMS object is downloaded.
	runLock, lockErr := acquireRunLock(root, version)
	if lockErr != nil {
		return finish(lockErr, *noPause, interactive)
	}
	defer runLock.Close()
	logFile, logErr := logWriter(root, version)
	if logErr != nil {
		return finish(logErr, *noPause, interactive)
	}
	defer logFile.Close()
	logf := func(f string, a ...any) {
		line := fmt.Sprintf(f, a...)
		fmt.Println(line)
		_, _ = fmt.Fprintln(logFile, line)
	}
	if creds.CodeWarning != "" {
		logf("警告：%s", creds.CodeWarning)
	}
	d := &downloader{r2: r2, root: root, version: version, objects: objects, concurrency: *conc, logf: logf, runLock: runLock}
	keys := make([]string, 0, len(objects))
	for k := range objects {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		_, _ = fmt.Fprintf(logFile, "对象：%s (%d bytes)\n", k, objects[k].Size)
	}
	if err = d.downloadSums(ctx, partial); err != nil {
		return finish(err, *noPause, interactive)
	}
	sums = d.sums
	for rel := range sums {
		if _, ok := objects[rel]; !ok {
			return finish(fmt.Errorf("R2上的安装包不完整：缺少%s", rel), *noPause, interactive)
		}
	}
	for rel := range objects {
		if rel != "SHA256SUMS" {
			if _, ok := sums[rel]; !ok {
				d.logf("警告：R2中的额外文件已忽略：%s", rel)
			}
		}
	}
	if free, _, _, e := volumeStats(root); e == nil {
		var missing int64
		for rel, obj := range objects {
			if rel == "SHA256SUMS" {
				continue
			}
			p, _ := safeJoin(final, rel)
			if _, e := os.Stat(p); os.IsNotExist(e) {
				missing += obj.Size
			}
		}
		if int64(free) < missing+1<<30 {
			return finish(fmt.Errorf("磁盘空间不足：需要至少%s", formatBytes(missing+1<<30)), *noPause, interactive)
		}
	}
	if !*yes {
		fmt.Printf("将下载%s到%s，继续？[Y/n] ", formatBytes(sumObjectBytes(objects)), filepath.Join(root, version))
		var answer string
		fmt.Scanln(&answer)
		if answer != "" && !strings.EqualFold(answer, "y") {
			return 0
		}
	}
	if err = d.run(ctx); err != nil {
		if errors.Is(err, context.Canceled) {
			fmt.Println("已暂停，重新运行即可继续下载")
			return finishCode(3, *noPause, interactive)
		}
		return finish(err, *noPause, interactive)
	}
	if *requested == "" {
		tmp := filepath.Join(root, "latest.json.tmp")
		if err = os.WriteFile(tmp, latestRaw, 0644); err == nil {
			err = renameWithRetry(tmp, filepath.Join(root, "latest.json"))
		}
		if err != nil {
			return finish(err, *noPause, interactive)
		}
	}
	fmt.Printf("安装包位置：%s\n请先在任务栏中「安全删除硬件」再拔出硬盘\n在服务器上运行：sudo bash /mnt/ssd/ltx25/%s/ltx25-pack-deploy.sh install\n", final, version)
	return finishCode(0, *noPause, interactive)
}

func makeDownloadCode(in io.Reader, out io.Writer) int {
	r := bufio.NewReader(in)
	fmt.Fprint(out, "Access key ID: ")
	keyLine, err := r.ReadString('\n')
	if err != nil && err != io.EOF {
		return 2
	}
	key := strings.TrimSpace(keyLine)
	fmt.Fprint(out, "Secret access key: ")
	secret, err := readSecret(r, out)
	if err != nil {
		return 2
	}
	fmt.Fprintln(out)
	secret = strings.TrimSpace(secret)
	if !keyIDRE.MatchString(key) || !secretRE.MatchString(secret) {
		fmt.Fprintln(os.Stderr, "下载码内容无效：请向管理员重新索取")
		return 1
	}
	fmt.Fprintln(out, base64.StdEncoding.EncodeToString([]byte(key+":"+secret)))
	return 0
}

func verifyExisting(root, version string) error {
	if !versionRE.MatchString(version) {
		return errors.New("版本号无效")
	}
	p := filepath.Join(absPath(root), version, "SHA256SUMS")
	f, err := os.Open(p)
	if err != nil {
		return fmt.Errorf("无法打开SHA256SUMS：%w", err)
	}
	defer f.Close()
	sums, err := parseSums(f)
	if err != nil {
		return err
	}
	return verifyDir(absPath(root), version, sums, func(string, ...any) {})
}
func sumObjectBytes(m map[string]Object) int64 {
	var n int64
	for _, o := range m {
		n += o.Size
	}
	return n
}
func finish(err error, noPause, interactive bool) int {
	if err == nil {
		return 0
	}
	fmt.Fprintln(os.Stderr, "错误：", err)
	var ve verificationError
	if errors.As(err, &ve) {
		return finishCode(4, noPause, interactive)
	}
	return finishCode(1, noPause, interactive)
}
func finishCode(code int, noPause, interactive bool) int {
	if (interactive || explorerConsole()) && !noPause {
		pauseConsole(explorerConsole())
	}
	return code
}
