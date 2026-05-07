package handlers

import (
	"log"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"filemanager/config"

	"github.com/gin-gonic/gin"
	"golang.org/x/net/webdav"
)

var webdavHandlers map[string]*webdav.Handler

func InitWebDAV() {
	webdavHandlers = make(map[string]*webdav.Handler)
}

func WebDAVHandler(c *gin.Context) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("[DAV] PANIC: %v", r)
			if !c.Writer.Written() {
				c.AbortWithStatus(http.StatusInternalServerError)
			}
		}
	}()

	handler := getWebDAVHandler(c)
	if handler == nil {
		c.AbortWithStatus(http.StatusInternalServerError)
		return
	}

	req, effectivePrefix := adaptRequestForPublicPrefix(c.Request, handler.Prefix)
	effectiveHandler := handler
	if effectivePrefix != handler.Prefix {
		h := *handler
		h.Prefix = effectivePrefix
		effectiveHandler = &h
	}

	normalizeDestinationForProxy(req, effectiveHandler.Prefix)

	if shouldBlockMacMetadataRequest(req) {
		log.Printf("[DAV] IGNORE method=%s path=%q dest=%q", req.Method, req.URL.Path, req.Header.Get("Destination"))
		if isWriteLikeDAVMethod(req.Method) {
			c.Status(http.StatusNoContent)
			return
		}
		c.Status(http.StatusNotFound)
		return
	}

	setWebDAVHeaders(c)
	logRequest(req)
	if req.Method == "PROPFIND" {
		log.Printf("[DAV] PROPFIND prefix internal=%q effective=%q", handler.Prefix, effectiveHandler.Prefix)
	}

	// 重要：
	// 不要手动修改 c.Request.URL.Path
	// 不要手动修改 Destination
	// 让 golang.org/x/net/webdav 按 Prefix 原生处理
	effectiveHandler.ServeHTTP(c.Writer, req)
}

func shouldBlockMacMetadataRequest(r *http.Request) bool {
	if isMacMetadataPath(r.URL.Path) {
		return true
	}

	dest := r.Header.Get("Destination")
	if dest == "" {
		return false
	}

	u, err := url.Parse(dest)
	if err != nil {
		return false
	}

	return isMacMetadataPath(u.Path)
}

func isMacMetadataPath(requestPath string) bool {
	base := path.Base(requestPath)
	return base == ".DS_Store" || strings.HasPrefix(base, "._")
}

func isWriteLikeDAVMethod(method string) bool {
	switch method {
	case "PUT", "POST", "DELETE", "MKCOL", "COPY", "MOVE", "LOCK", "UNLOCK", "PROPPATCH", "PATCH":
		return true
	default:
		return false
	}
}

func adaptRequestForPublicPrefix(r *http.Request, internalPrefix string) (*http.Request, string) {
	internalPrefix = ensureAbsolutePath(internalPrefix)
	publicPrefix := resolvePublicPrefix(r, internalPrefix)
	if publicPrefix == internalPrefix {
		return r, internalPrefix
	}

	newPath, ok := remapRequestPathPrefix(r.URL.Path, internalPrefix, publicPrefix)
	if !ok {
		return r, internalPrefix
	}

	cloned := r.Clone(r.Context())
	oldPath := cloned.URL.Path
	cloned.URL.Path = newPath
	if cloned.URL.RawPath != "" {
		if rawPath, ok := remapRequestPathPrefix(cloned.URL.RawPath, internalPrefix, publicPrefix); ok {
			cloned.URL.RawPath = rawPath
		} else {
			cloned.URL.RawPath = ""
		}
	}
	log.Printf("[DAV] REWRITE request path from=%q to=%q", oldPath, newPath)

	return cloned, publicPrefix
}

func resolvePublicPrefix(r *http.Request, internalPrefix string) string {
	internalPrefix = ensureAbsolutePath(internalPrefix)

	if cfg := config.Get(); cfg != nil {
		if configured := strings.TrimSpace(cfg.Server.DAVPublicPrefix); configured != "" {
			p := ensureAbsolutePath(configured)
			if p == internalPrefix || strings.HasSuffix(p, internalPrefix) {
				return p
			}
			if p == "/" {
				return internalPrefix
			}
			return strings.TrimRight(p, "/") + internalPrefix
		}
	}

	if configured := strings.TrimSpace(os.Getenv("FILEMANAGER_DAV_PUBLIC_PREFIX")); configured != "" {
		p := ensureAbsolutePath(configured)
		if p == internalPrefix || strings.HasSuffix(p, internalPrefix) {
			return p
		}
		if p == "/" {
			return internalPrefix
		}
		return strings.TrimRight(p, "/") + internalPrefix
	}

	if candidate := firstHeaderValue(r.Header.Get("X-Forwarded-Prefix")); candidate != "" {
		p := ensureAbsolutePath(candidate)
		if p == internalPrefix || strings.HasSuffix(p, internalPrefix) {
			return p
		}
		if p == "/" {
			return internalPrefix
		}
		return strings.TrimRight(p, "/") + internalPrefix
	}

	if candidate := firstHeaderValue(r.Header.Get("X-Script-Name")); candidate != "" {
		p := ensureAbsolutePath(candidate)
		if p == "/" {
			return internalPrefix
		}
		return strings.TrimRight(p, "/") + internalPrefix
	}

	for _, header := range []string{"X-Forwarded-Uri", "X-Original-URI", "X-Rewrite-URL"} {
		if candidate := firstHeaderValue(r.Header.Get(header)); candidate != "" {
			if p, ok := derivePrefixFromURI(candidate, internalPrefix); ok {
				return p
			}
		}
	}

	return internalPrefix
}

func firstHeaderValue(v string) string {
	v = strings.TrimSpace(v)
	if v == "" {
		return ""
	}
	if idx := strings.Index(v, ","); idx >= 0 {
		v = strings.TrimSpace(v[:idx])
	}
	return v
}

func derivePrefixFromURI(uriText, internalPrefix string) (string, bool) {
	u, err := url.Parse(uriText)
	if err != nil {
		return "", false
	}

	p := u.Path
	if p == "" {
		p = uriText
	}
	p = ensureAbsolutePath(p)

	internalPrefix = ensureAbsolutePath(internalPrefix)
	idx := strings.Index(p, internalPrefix)
	if idx < 0 {
		return "", false
	}
	end := idx + len(internalPrefix)
	if end < len(p) && p[end] != '/' {
		return "", false
	}

	return p[:end], true
}

func remapRequestPathPrefix(requestPath, fromPrefix, toPrefix string) (string, bool) {
	requestPath = ensureAbsolutePath(requestPath)
	fromPrefix = ensureAbsolutePath(fromPrefix)
	toPrefix = ensureAbsolutePath(toPrefix)

	if requestPath == fromPrefix {
		return toPrefix, true
	}
	if strings.HasPrefix(requestPath, fromPrefix+"/") {
		return toPrefix + requestPath[len(fromPrefix):], true
	}

	return "", false
}

func normalizeDestinationForProxy(r *http.Request, prefix string) {
	dest := r.Header.Get("Destination")
	if dest == "" || prefix == "" || prefix == "/" {
		return
	}

	u, rawPath, err := parseDestination(dest)
	if err != nil {
		return
	}

	if rawPath == "" {
		return
	}

	if normalized, ok := normalizeMatchedPrefixPath(rawPath, prefix); ok {
		if normalized == rawPath {
			return
		}
		old := rawPath
		u.Path = normalized
		u.RawPath = ""
		r.Header.Set("Destination", u.String())
		log.Printf("[DAV] REWRITE destination path from=%q to=%q", old, normalized)
		return
	}

	if strings.HasPrefix(rawPath, prefix) {
		return
	}
}

func parseDestination(dest string) (*url.URL, string, error) {
	u, err := url.Parse(dest)
	if err != nil {
		return nil, "", err
	}

	rawPath := u.Path
	if rawPath == "" {
		rawPath = dest
	}

	return u, ensureAbsolutePath(rawPath), nil
}

func normalizeMatchedPrefixPath(requestPath, prefix string) (string, bool) {
	requestPath = ensureAbsolutePath(requestPath)
	prefix = ensureAbsolutePath(prefix)

	if requestPath == prefix || strings.HasPrefix(requestPath, prefix+"/") {
		return requestPath, true
	}

	segments := splitPathSegments(requestPath)
	prefixSegments := splitPathSegments(prefix)
	if len(prefixSegments) == 0 || len(segments) < len(prefixSegments) {
		return "", false
	}

	for i := 0; i+len(prefixSegments) <= len(segments); i++ {
		if slices.Equal(segments[i:i+len(prefixSegments)], prefixSegments) {
			normalized := "/" + strings.Join(segments[i:], "/")
			if strings.HasSuffix(requestPath, "/") && normalized != "/" {
				normalized += "/"
			}
			return normalized, true
		}
	}

	return "", false
}

func ensureAbsolutePath(p string) string {
	if p == "" {
		return "/"
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	if p == "/" {
		return p
	}
	hasTrailingSlash := strings.HasSuffix(p, "/")
	cleaned := path.Clean(p)
	if hasTrailingSlash && cleaned != "/" {
		cleaned += "/"
	}
	return cleaned
}

func splitPathSegments(p string) []string {
	p = strings.Trim(p, "/")
	if p == "" {
		return nil
	}
	return strings.Split(p, "/")
}

func getWebDAVHandler(c *gin.Context) *webdav.Handler {
	username := c.GetString("username")
	isAdmin := c.GetBool("is_admin")

	prefix := getWebDAVPrefix(c)

	cacheKey := username + "|" + prefix
	if isAdmin {
		cacheKey = "admin|" + prefix
	}

	if handler, ok := webdavHandlers[cacheKey]; ok {
		return handler
	}

	cfg := config.Get()
	if cfg == nil {
		log.Printf("[DAV] 配置为空")
		return nil
	}

	var rootPath string
	if isAdmin {
		rootPath = cfg.Server.RootDir
	} else {
		rootPath = filepath.Join(cfg.Server.RootDir, username)
	}

	absPath, err := filepath.Abs(rootPath)
	if err != nil {
		log.Printf("[DAV] 获取绝对路径失败: %q, err=%v", rootPath, err)
		absPath = rootPath
	}

	if err := os.MkdirAll(absPath, 0755); err != nil {
		log.Printf("[DAV] 创建 WebDAV 根目录失败: %q, err=%v", absPath, err)
		return nil
	}

	log.Printf(
		"[DAV] 初始化 - 用户=%q, isAdmin=%v, Prefix=%q, 根目录=%q",
		username,
		isAdmin,
		prefix,
		absPath,
	)

	handler := &webdav.Handler{
		Prefix:     prefix,
		FileSystem: webdav.Dir(absPath),
		LockSystem: webdav.NewMemLS(),
		Logger: func(r *http.Request, err error) {
			logDAVError(r, err)
		},
	}

	webdavHandlers[cacheKey] = handler
	return handler
}

func getWebDAVPrefix(c *gin.Context) string {
	// 如果 Gin 路由是：
	// r.Any("/dav/*path", handlers.WebDAVHandler)
	// c.FullPath() 通常是 "/dav/*path"
	fullPath := c.FullPath()
	if fullPath != "" {
		if idx := strings.Index(fullPath, "/*"); idx >= 0 {
			prefix := fullPath[:idx]
			if prefix == "" {
				return "/"
			}
			return strings.TrimRight(prefix, "/")
		}
	}

	// 兜底：你的项目现在使用的是 /dav
	return "/dav"
}

func setWebDAVHeaders(c *gin.Context) {
	c.Header("DAV", "1, 2")
	c.Header("MS-Author-Via", "DAV")
	c.Header("Allow", "OPTIONS, GET, HEAD, POST, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK")

	// 只做缓存控制，不改变 WebDAV 语义
	c.Header("Cache-Control", "no-cache, no-store, must-revalidate")
	c.Header("Pragma", "no-cache")
	c.Header("Expires", "0")

	c.Header("X-Content-Type-Options", "nosniff")
}

func logRequest(r *http.Request) {
	dest := r.Header.Get("Destination")
	if dest != "" {
		log.Printf(
			"[DAV] %s path=%q rawPath=%q dest=%q",
			r.Method,
			r.URL.Path,
			r.URL.RawPath,
			dest,
		)
		return
	}

	log.Printf(
		"[DAV] %s path=%q rawPath=%q",
		r.Method,
		r.URL.Path,
		r.URL.RawPath,
	)
}

func logDAVError(r *http.Request, err error) {
	if err == nil {
		return
	}

	method := r.Method
	requestPath := r.URL.Path
	dest := r.Header.Get("Destination")
	errText := err.Error()

	if isExpectedDAVMiss(method, requestPath, errText) {
		log.Printf(
			"[DAV] MISS method=%s path=%q dest=%q err=%v",
			method,
			requestPath,
			dest,
			err,
		)
		return
	}

	log.Printf(
		"[DAV] ERROR method=%s path=%q dest=%q err=%v",
		method,
		requestPath,
		dest,
		err,
	)
}

func isExpectedDAVMiss(method, requestPath, errText string) bool {
	if !strings.Contains(errText, "no such file or directory") {
		return false
	}

	base := path.Base(requestPath)

	// macOS Finder 经常探测 AppleDouble 元数据文件。
	// 这些文件不存在是正常情况。
	if base == "._." || strings.HasPrefix(base, "._") || base == ".DS_Store" {
		return true
	}

	// Finder 创建文件夹前，会先 PROPFIND 目标路径是否存在。
	// Finder 改名、删除后，也会继续 PROPFIND 旧路径刷新状态。
	// 所以 PROPFIND 的 no such file or directory 大多是正常探测。
	if method == "PROPFIND" {
		return true
	}

	return false
}
