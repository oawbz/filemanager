package handlers

import (
	"log"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"time"

	"filemanager/apiresp"
	"filemanager/config"

	"github.com/creack/pty"
	"github.com/gin-gonic/gin"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin:      func(r *http.Request) bool { return true },
	HandshakeTimeout: 10 * time.Second,
}

// ShellTerminal 通过 WebSocket 直连本机 shell
func ShellTerminal(c *gin.Context) {
	// 检查管理员权限
	isAdmin := c.GetBool("is_admin")
	if !isAdmin {
		apiresp.Error(c, http.StatusForbidden, "需要管理员权限")
		return
	}

	// 检查 shell 功能是否开启
	cfg := config.Get()
	if cfg == nil || !cfg.Shell {
		apiresp.Error(c, http.StatusForbidden, "Shell 功能未开启")
		return
	}

	ws, err := upgrader.Upgrade(c.Writer, c.Request, nil)
	if err != nil {
		log.Printf("WebSocket upgrade error: %v", err)
		return
	}
	defer ws.Close()

	// 获取默认 shell
	shell := getDefaultShell()

	// 创建命令
	cmd := exec.Command(shell)

	// 设置工作目录为用户家目录
	if home, err := os.UserHomeDir(); err == nil {
		cmd.Dir = home
	}

	// 设置环境变量
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	// 启动伪终端
	ptmx, err := pty.Start(cmd)
	if err != nil {
		sendWSError(ws, "启动 Shell 失败: "+err.Error())
		return
	}
	defer func() {
		_ = ptmx.Close()
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()

	// PTY 输出 -> WebSocket
	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := ptmx.Read(buf)
			if n > 0 {
				_ = ws.WriteMessage(websocket.BinaryMessage, buf[:n])
			}
			if err != nil {
				break
			}
		}
	}()

	// WebSocket -> PTY 输入
	for {
		_, msg, err := ws.ReadMessage()
		if err != nil {
			break
		}

		// 处理 resize 消息，格式: \x01<rows_hi><rows_lo><cols_hi><cols_lo>
		if len(msg) == 5 && msg[0] == 0x01 {
			rows := int(msg[1])<<8 | int(msg[2])
			cols := int(msg[3])<<8 | int(msg[4])
			_ = pty.Setsize(ptmx, &pty.Winsize{
				Rows: uint16(rows),
				Cols: uint16(cols),
			})
			continue
		}

		if _, err := ptmx.Write(msg); err != nil {
			break
		}
	}
}

func getDefaultShell() string {
	if runtime.GOOS == "windows" {
		// Windows 优先使用 PowerShell，回退到 cmd
		if _, err := exec.LookPath("powershell"); err == nil {
			return "powershell"
		}
		return "cmd"
	}

	// Unix-like 系统优先使用用户 SHELL 环境变量
	if shell := os.Getenv("SHELL"); shell != "" {
		return shell
	}

	// 回退到常见 shell
	shells := []string{"/bin/bash", "/bin/sh", "/bin/zsh"}
	for _, shell := range shells {
		if _, err := os.Stat(shell); err == nil {
			return shell
		}
	}

	return "/bin/sh"
}

func sendWSError(ws *websocket.Conn, msg string) {
	_ = ws.WriteMessage(websocket.TextMessage, []byte("\r\n\033[31m错误: "+msg+"\033[0m\r\n"))
}
