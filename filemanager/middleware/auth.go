package middleware

import (
	"encoding/base64"
	"net/http"
	"strings"

	"filemanager/apiresp"
	"filemanager/config"
	"filemanager/security"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

func JWTAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		token := c.GetHeader("Authorization")
		if token == "" {
			token = c.Query("token")
		}
		token = strings.TrimPrefix(token, "Bearer ")
		if token == "" {
			apiresp.AbortError(c, 401, "未提供 token")
			return
		}

		secret := security.JWTSecret()
		t, err := jwt.Parse(token, func(t *jwt.Token) (interface{}, error) {
			return []byte(secret), nil
		}, jwt.WithValidMethods([]string{"HS256"}))
		if err != nil || !t.Valid {
			apiresp.AbortError(c, 401, "token 无效")
			return
		}

		claims, _ := t.Claims.(jwt.MapClaims)
		username, _ := claims["username"].(string)
		isAdmin, _ := claims["is_admin"].(bool)
		
		c.Set("username", username)
		c.Set("is_admin", isAdmin)
		c.Next()
	}
}

func WebDAVAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		authHeader := c.GetHeader("Authorization")
		
		if strings.HasPrefix(authHeader, "Bearer ") {
			token := strings.TrimPrefix(authHeader, "Bearer ")
			secret := security.JWTSecret()
			t, err := jwt.Parse(token, func(t *jwt.Token) (interface{}, error) {
				return []byte(secret), nil
			}, jwt.WithValidMethods([]string{"HS256"}))
			if err == nil && t.Valid {
				if claims, ok := t.Claims.(jwt.MapClaims); ok {
					username, _ := claims["username"].(string)
					isAdmin, _ := claims["is_admin"].(bool)
					c.Set("username", username)
					c.Set("is_admin", isAdmin)
					c.Next()
					return
				}
			}
		}

		if strings.HasPrefix(authHeader, "Basic ") {
			decoded, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(authHeader, "Basic "))
			if err == nil {
				parts := strings.SplitN(string(decoded), ":", 2)
				if len(parts) == 2 {
					username := parts[0]
					password := parts[1]

					if config.CheckPassword(username, password) {
						user := config.GetUserByUsername(username)
						c.Set("username", user.Username)
						c.Set("is_admin", user.IsAdmin)
						c.Next()
						return
					}
				}
			}
		}

		c.Header("WWW-Authenticate", `Basic realm="WebDAV"`)
		c.AbortWithStatus(http.StatusUnauthorized)
	}
}
