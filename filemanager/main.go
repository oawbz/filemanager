package main

import (
	"context"
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"filemanager/app"
	"filemanager/config"
	"filemanager/handlers"

	"github.com/gin-gonic/gin"
)

//go:embed static
var staticFiles embed.FS

func main() {
	// 解析命令行参数
	configPath := flag.String("config", "", "配置文件路径")
	flag.Parse()

	// 设置配置文件路径
	if *configPath != "" {
		config.SetConfigPath(*configPath)
	}

	// 加载配置
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("加载配置失败: %v", err)
	}

	// 初始化WebDAV
	handlers.InitWebDAV()

	gin.SetMode(gin.ReleaseMode)

	addr := fmt.Sprintf("%s:%d", cfg.Server.Host, cfg.Server.Port)

	sub, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatalf("无法读取静态文件: %v", err)
	}
	r := app.NewRouter(sub)

	srv := &http.Server{
		Addr:              addr,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       15 * time.Minute,
		WriteTimeout:      30 * time.Minute,
		IdleTimeout:       120 * time.Second,
	}

	log.Printf("FileManager 启动在 %s", addr)

	go func() {
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("服务启动失败: %v", err)
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	log.Println("收到退出信号，正在优雅关闭...")

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("优雅关闭失败: %v", err)
		return
	}
	log.Println("服务已关闭")
}
