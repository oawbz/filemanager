package middleware

import (
	"net/http"
	"strings"

	"filemanager/config"

	"github.com/gin-gonic/gin"
)

func MCPAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		cfg := config.Get()
		if cfg == nil {
			c.JSON(http.StatusForbidden, gin.H{"error": "MCP 未启用"})
			c.Abort()
			return
		}

		token := strings.TrimSpace(cfg.MCP.Token)
		if token == "" {
			c.JSON(http.StatusForbidden, gin.H{"error": "MCP 未启用（未配置 token）"})
			c.Abort()
			return
		}

		auth := strings.TrimSpace(c.GetHeader("Authorization"))
		if !strings.HasPrefix(auth, "Bearer ") {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "未提供 MCP Bearer token"})
			c.Abort()
			return
		}

		provided := strings.TrimSpace(strings.TrimPrefix(auth, "Bearer "))
		if provided != token {
			c.JSON(http.StatusUnauthorized, gin.H{"error": "MCP token 无效"})
			c.Abort()
			return
		}

		c.Next()
	}
}
