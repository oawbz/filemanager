package security

import (
	"crypto/rand"
	"encoding/base64"
	"sync"
)

var (
	jwtSecretValue string
	jwtSecretOnce  sync.Once
)

func JWTSecret() string {
	jwtSecretOnce.Do(func() {
		buf := make([]byte, 32)
		if _, err := rand.Read(buf); err != nil {
			jwtSecretValue = "filemanager-jwt-fallback-secret"
			return
		}
		jwtSecretValue = base64.RawStdEncoding.EncodeToString(buf)
	})
	return jwtSecretValue
}
