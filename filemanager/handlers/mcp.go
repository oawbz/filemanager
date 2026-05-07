package handlers

import (
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"github.com/gin-gonic/gin"
)

type mcpRequest struct {
	JSONRPC string                 `json:"jsonrpc"`
	ID      interface{}            `json:"id"`
	Method  string                 `json:"method"`
	Params  map[string]interface{} `json:"params"`
}

func HandleMCP(c *gin.Context) {
	if c.Request.Method == http.MethodGet {
		c.JSON(http.StatusOK, gin.H{
			"name":        "FileManager MCP",
			"endpoint":    "/mcp",
			"transport":   "streamable-http",
			"auth":        "Authorization: Bearer <mcp-token>",
			"description": "MCP 已启用。使用 POST /mcp 发送 JSON-RPC 请求。",
		})
		return
	}

	if c.Request.Method != http.MethodPost {
		c.JSON(http.StatusMethodNotAllowed, gin.H{"error": "method not allowed"})
		return
	}

	var req mcpRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"jsonrpc": "2.0",
			"id":      nil,
			"error": gin.H{
				"code":    -32700,
				"message": "Parse error",
			},
		})
		return
	}

	if req.ID == nil {
		c.Status(http.StatusAccepted)
		return
	}

	switch strings.TrimSpace(req.Method) {
	case "initialize":
		c.JSON(http.StatusOK, gin.H{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"result": gin.H{
				"protocolVersion": "2025-03-26",
				"capabilities": gin.H{
					"tools": gin.H{"listChanged": false},
				},
				"serverInfo": gin.H{
					"name":    "FileManager MCP",
					"version": "1.0.0",
				},
			},
		})
	case "ping", "initialized", "notifications/initialized":
		c.JSON(http.StatusOK, gin.H{"jsonrpc": "2.0", "id": req.ID, "result": gin.H{}})
	case "tools/list":
		c.JSON(http.StatusOK, gin.H{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"result": gin.H{
				"tools": []gin.H{
					{
						"name":        "shell",
						"description": "执行本机 shell 命令",
						"inputSchema": gin.H{
							"type": "object",
							"properties": gin.H{
								"command": gin.H{"type": "string", "description": "要执行的命令"},
								"cwd":     gin.H{"type": "string", "description": "执行目录（可选）"},
							},
							"required": []string{"command"},
						},
					},
				},
			},
		})
	case "tools/call":
		handleMCPToolCall(c, req)
	default:
		c.JSON(http.StatusOK, gin.H{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"error": gin.H{
				"code":    -32601,
				"message": "Method not found",
			},
		})
	}
}

func handleMCPToolCall(c *gin.Context, req mcpRequest) {
	name, _ := req.Params["name"].(string)
	if strings.TrimSpace(strings.ToLower(name)) != "shell" {
		c.JSON(http.StatusOK, gin.H{
			"jsonrpc": "2.0",
			"id":      req.ID,
			"error": gin.H{"code": -32000, "message": "Tool not found"},
		})
		return
	}

	arguments, _ := req.Params["arguments"].(map[string]interface{})
	command, _ := arguments["command"].(string)
	command = strings.TrimSpace(command)
	if command == "" {
		c.JSON(http.StatusOK, mcpTextResult(req.ID, "shell 需要参数: command", true))
		return
	}

	cwd := "/"
	if rawCwd, ok := arguments["cwd"].(string); ok {
		rawCwd = strings.TrimSpace(rawCwd)
		if rawCwd != "" {
			cwd = rawCwd
		}
	}

	output, runErr := runLocalShell(command, cwd)
	if runErr != nil {
		c.JSON(http.StatusOK, mcpTextResult(req.ID, fmt.Sprintf("shell 执行失败: %s\n输出:\n%s", runErr.Error(), strings.TrimSpace(output)), true))
		return
	}

	text := fmt.Sprintf("$ %s\n%s", command, strings.TrimSpace(output))
	c.JSON(http.StatusOK, mcpTextResult(req.ID, text, false))
}

func runLocalShell(command string, cwd string) (string, error) {
	sh := "sh"
	args := []string{"-c", command}
	if runtime.GOOS == "windows" {
		sh = "cmd"
		args = []string{"/C", command}
	}

	cmd := exec.Command(sh, args...)
	if cwd != "" && cwd != "/" {
		cmd.Dir = cwd
	}
	if cwd != "" && cwd != "/" {
		if _, err := os.Stat(cwd); err != nil {
			return "", fmt.Errorf("cwd 无效: %w", err)
		}
	}
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func mcpTextResult(id interface{}, text string, isError bool) gin.H {
	return gin.H{
		"jsonrpc": "2.0",
		"id":      id,
		"result": gin.H{
			"content": []gin.H{
				{"type": "text", "text": text},
			},
			"isError": isError,
		},
	}
}
