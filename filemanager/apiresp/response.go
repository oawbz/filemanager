package apiresp

import (
	"strings"

	"github.com/gin-gonic/gin"
)

const RequestIDKey = "request_id"

func RequestID(c *gin.Context) string {
	if id := strings.TrimSpace(c.GetString(RequestIDKey)); id != "" {
		return id
	}
	if id := strings.TrimSpace(c.Writer.Header().Get("X-Request-Id")); id != "" {
		return id
	}
	if id := strings.TrimSpace(c.GetHeader("X-Request-Id")); id != "" {
		return id
	}
	return ""
}

func Error(c *gin.Context, status int, message string) {
	body := gin.H{"error": message}
	if requestID := RequestID(c); requestID != "" {
		body["request_id"] = requestID
	}
	c.JSON(status, body)
}

func AbortError(c *gin.Context, status int, message string) {
	body := gin.H{"error": message}
	if requestID := RequestID(c); requestID != "" {
		body["request_id"] = requestID
	}
	c.AbortWithStatusJSON(status, body)
}
