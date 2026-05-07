package app

import (
	"io/fs"
	"net/http"
	"strings"

	"filemanager/apiresp"
	"filemanager/config"
	"filemanager/handlers"
	"filemanager/middleware"

	"github.com/gin-gonic/gin"
)

func NewRouter(staticFS fs.FS) *gin.Engine {
	r := gin.New()
	r.Use(recoverJSONMiddleware())
	_ = r.SetTrustedProxies(nil)
	r.MaxMultipartMemory = 32 << 20

	r.GET("/api/health", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	r.GET("/mcp", middleware.MCPAuth(), handlers.HandleMCP)
	r.POST("/mcp", middleware.MCPAuth(), handlers.HandleMCP)

	r.NoMethod(func(c *gin.Context) {
		apiresp.Error(c, http.StatusMethodNotAllowed, "请求方法不被允许")
	})

	// 初始化WebDAV
	handlers.InitWebDAV()

	registerAPIRoutes(r)
	registerWebDAVRoutes(r)
	registerStaticRoutes(r, staticFS)

	return r
}

func registerAPIRoutes(r *gin.Engine) {
	api := r.Group("/api")
	{
		api.POST("/auth/login", handlers.Login)

		auth := api.Group("/", middleware.JWTAuth())
		{
			auth.POST("/auth/change-password", handlers.ChangePassword)
			auth.GET("/auth/settings", handlers.GetUserSettings)
			auth.PUT("/auth/settings", handlers.UpdateUserSettings)

			// 用户管理（管理员）
			auth.GET("/users", handlers.ListUsers)
			auth.POST("/users", handlers.AddUser)
			auth.DELETE("/users", handlers.DeleteUser)

			// 服务器配置（管理员）
			auth.PUT("/server/config", handlers.UpdateServerConfig)

			// 终端（根据配置决定是否启用）
			cfg := config.Get()
			if cfg != nil && cfg.Shell {
				auth.GET("/shell", handlers.ShellTerminal)
			}

			// 文件管理
			auth.GET("/files", handlers.ListFiles)
			auth.GET("/files/properties", handlers.GetFileProperties)
			auth.GET("/files/content", handlers.GetFileContent)
			auth.GET("/files/download", handlers.DownloadFiles)
			auth.GET("/files/preview", handlers.PreviewFile)
			auth.POST("/files/content", handlers.UpdateFileContent)
			auth.POST("/files/create", handlers.CreateFile)
			auth.POST("/files/mkdir", handlers.CreateDirectory)
			auth.POST("/files/copy", handlers.CopyFiles)
			auth.POST("/files/move", handlers.MoveFiles)
			auth.POST("/files/archive", handlers.ArchiveFiles)
			auth.POST("/files/extract", handlers.ExtractArchive)
			auth.POST("/files/upload", handlers.UploadFile)
			auth.POST("/files/upload/init", handlers.InitFileUpload)
			auth.POST("/files/upload/chunk", handlers.UploadFileChunk)
			auth.POST("/files/upload/complete", handlers.CompleteFileUpload)
			auth.DELETE("/files/upload/cancel", handlers.CancelFileUpload)
			auth.POST("/files/rename", handlers.RenameFile)
			auth.POST("/files/delete", handlers.DeleteFile)
		}
	}
}

func registerWebDAVRoutes(r *gin.Engine) {
	// WebDAV路由
	webdavAuth := middleware.WebDAVAuth()

	// Gin 的 Any() 不包含 WebDAV 扩展方法（如 PROPFIND/MKCOL/COPY/MOVE 等），
	// 这里显式注册常见 DAV 方法，确保不同客户端都能进入 WebDAV handler。
	methods := []string{
		"OPTIONS", "GET", "HEAD", "POST", "PUT", "DELETE", "PATCH",
		"PROPFIND", "PROPPATCH", "MKCOL", "COPY", "MOVE", "LOCK", "UNLOCK",
		"ACL", "REPORT", "SEARCH", "CHECKIN", "CHECKOUT", "UNCHECKOUT",
		"MKWORKSPACE", "UPDATE", "LABEL", "MERGE", "MKACTIVITY", "ORDERPATCH",
	}
	for _, method := range methods {
		r.Handle(method, "/dav", webdavAuth, handlers.WebDAVHandler)
		r.Handle(method, "/dav/*path", webdavAuth, handlers.WebDAVHandler)
	}
}

func registerStaticRoutes(r *gin.Engine, staticFS fs.FS) {
	fileServer := http.FileServer(http.FS(staticFS))

	r.NoRoute(func(c *gin.Context) {
		path := c.Request.URL.Path
		
		// 排除 API 和 WebDAV 路径
		if strings.HasPrefix(path, "/api/") || path == "/api" {
			apiresp.Error(c, http.StatusNotFound, "接口不存在")
			return
		}
		if strings.HasPrefix(path, "/dav") {
			return
		}

		// 尝试提供 Brotli 预压缩文件
		if tryServeBrotli(c, staticFS) {
			return
		}

		// 为静态资源添加缓存头
		if isStaticAsset(path) {
			c.Header("Cache-Control", "public, max-age=31536000, immutable")
		}

		_, statErr := fs.Stat(staticFS, strings.TrimPrefix(path, "/"))
		if statErr != nil || path == "/" {
			c.Request.URL.Path = "/"
		}
		fileServer.ServeHTTP(c.Writer, c.Request)
	})
}

// tryServeBrotli 尝试提供 Brotli 预压缩文件
func tryServeBrotli(c *gin.Context, staticFS fs.FS) bool {
	// 检查客户端是否支持 Brotli
	acceptEncoding := c.GetHeader("Accept-Encoding")
	if !strings.Contains(acceptEncoding, "br") {
		return false
	}

	path := c.Request.URL.Path
	if path == "/" || path == "" {
		return false
	}

	// 只处理特定文件类型
	contentType := getCompressibleContentType(path)
	if contentType == "" {
		return false
	}

	// 构造 .br 文件路径
	brPath := strings.TrimPrefix(path, "/") + ".br"

	// 读取 .br 文件
	data, err := fs.ReadFile(staticFS, brPath)
	if err != nil {
		return false
	}

	// 设置响应头
	c.Header("Content-Encoding", "br")
	c.Header("Content-Type", contentType)
	c.Header("Vary", "Accept-Encoding")
	c.Header("Cache-Control", "public, max-age=31536000, immutable")
	c.Data(http.StatusOK, contentType, data)
	return true
}

// getCompressibleContentType 返回可压缩文件的 Content-Type
func getCompressibleContentType(path string) string {
	switch {
	case strings.HasSuffix(path, ".wasm"):
		return "application/wasm"
	case strings.HasSuffix(path, ".js"):
		return "application/javascript"
	case strings.HasSuffix(path, ".mjs"):
		return "application/javascript"
	case strings.HasSuffix(path, ".css"):
		return "text/css"
	case strings.HasSuffix(path, ".json"):
		return "application/json"
	case strings.HasSuffix(path, ".svg"):
		return "image/svg+xml"
	case strings.HasSuffix(path, ".woff2"):
		return "font/woff2"
	default:
		return ""
	}
}

// isStaticAsset 检查是否是静态资源
func isStaticAsset(path string) bool {
	staticExts := []string{
		".js", ".mjs", ".css", ".wasm",
		".woff", ".woff2", ".ttf", ".otf",
		".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico",
		".json", ".xml",
	}
	for _, ext := range staticExts {
		if strings.HasSuffix(path, ext) {
			return true
		}
	}
	return false
}

func recoverJSONMiddleware() gin.HandlerFunc {
	return func(c *gin.Context) {
		defer func() {
			if r := recover(); r != nil {
				apiresp.Error(c, http.StatusInternalServerError, "服务器内部错误")
				c.Abort()
			}
		}()
		c.Next()
	}
}
