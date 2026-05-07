package handlers

import (
	"net/http"
	"strings"
	"time"

	"filemanager/apiresp"
	"filemanager/config"
	"filemanager/security"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
)

type loginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

type changePasswordRequest struct {
	OldPassword string `json:"old_password" binding:"required"`
	NewPassword string `json:"new_password" binding:"required,min=6"`
}

type userSettingsResponse struct {
	Username string `json:"username"`
	IsAdmin  bool   `json:"is_admin"`
}

type updateUserSettingsRequest struct {
	OldPassword *string `json:"old_password"`
	NewPassword *string `json:"new_password"`
}

type addUserRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required,min=6"`
}

type deleteUserRequest struct {
	Username string `json:"username" binding:"required"`
}

func Login(c *gin.Context) {
	var req loginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "参数错误")
		return
	}

	if !config.CheckPassword(req.Username, req.Password) {
		apiresp.Error(c, http.StatusUnauthorized, "用户名或密码错误")
		return
	}

	user := config.GetUserByUsername(req.Username)
	if user == nil {
		apiresp.Error(c, http.StatusUnauthorized, "用户名或密码错误")
		return
	}

	secret := security.JWTSecret()
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"username": user.Username,
		"is_admin": user.IsAdmin,
		"exp":      time.Now().Add(24 * time.Hour).Unix(),
	})
	signed, err := token.SignedString([]byte(secret))
	if err != nil {
		apiresp.Error(c, http.StatusInternalServerError, "生成 token 失败")
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"token":         signed,
		"username":      user.Username,
		"is_admin":      user.IsAdmin,
		"shell_enabled": config.Get().Shell,
	})
}

func ChangePassword(c *gin.Context) {
	username := c.GetString("username")
	var req changePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "参数错误")
		return
	}

	if !config.CheckPassword(username, req.OldPassword) {
		apiresp.Error(c, http.StatusUnauthorized, "原密码错误")
		return
	}

	if err := config.UpdateUser(username, req.NewPassword); err != nil {
		apiresp.Error(c, http.StatusInternalServerError, "修改密码失败")
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "密码修改成功"})
}

func GetUserSettings(c *gin.Context) {
	username := c.GetString("username")
	isAdmin := c.GetBool("is_admin")

	c.JSON(http.StatusOK, userSettingsResponse{
		Username: username,
		IsAdmin:  isAdmin,
	})
}

func UpdateUserSettings(c *gin.Context) {
	username := c.GetString("username")
	var req updateUserSettingsRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "参数错误")
		return
	}

	oldPwdProvided := req.OldPassword != nil && strings.TrimSpace(*req.OldPassword) != ""
	newPwdProvided := req.NewPassword != nil && strings.TrimSpace(*req.NewPassword) != ""
	if oldPwdProvided || newPwdProvided {
		if !oldPwdProvided || !newPwdProvided {
			apiresp.Error(c, http.StatusBadRequest, "修改密码需要同时填写原密码和新密码")
			return
		}
		nextPassword := strings.TrimSpace(*req.NewPassword)
		if len(nextPassword) < 6 {
			apiresp.Error(c, http.StatusBadRequest, "新密码至少 6 位")
			return
		}
		if !config.CheckPassword(username, strings.TrimSpace(*req.OldPassword)) {
			apiresp.Error(c, http.StatusUnauthorized, "原密码错误")
			return
		}
		if err := config.UpdateUser(username, nextPassword); err != nil {
			apiresp.Error(c, http.StatusInternalServerError, "修改密码失败")
			return
		}
	}

	user := config.GetUserByUsername(username)
	c.JSON(http.StatusOK, userSettingsResponse{
		Username: username,
		IsAdmin:  user.IsAdmin,
	})
}

func ListUsers(c *gin.Context) {
	isAdmin := c.GetBool("is_admin")
	if !isAdmin {
		apiresp.Error(c, http.StatusForbidden, "需要管理员权限")
		return
	}

	users := config.ListUsers()
	result := make([]gin.H, 0, len(users))
	for _, u := range users {
		result = append(result, gin.H{
			"username": u.Username,
			"is_admin": u.IsAdmin,
		})
	}

	c.JSON(http.StatusOK, result)
}

func AddUser(c *gin.Context) {
	isAdmin := c.GetBool("is_admin")
	if !isAdmin {
		apiresp.Error(c, http.StatusForbidden, "需要管理员权限")
		return
	}

	var req addUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "参数错误")
		return
	}

	if err := config.AddUser(req.Username, req.Password); err != nil {
		apiresp.Error(c, http.StatusBadRequest, err.Error())
		return
	}

	c.JSON(http.StatusCreated, gin.H{"message": "用户创建成功"})
}

func DeleteUser(c *gin.Context) {
	isAdmin := c.GetBool("is_admin")
	if !isAdmin {
		apiresp.Error(c, http.StatusForbidden, "需要管理员权限")
		return
	}

	var req deleteUserRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "参数错误")
		return
	}

	if err := config.DeleteUser(req.Username); err != nil {
		apiresp.Error(c, http.StatusBadRequest, err.Error())
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "用户删除成功"})
}

func UpdateServerConfig(c *gin.Context) {
	isAdmin := c.GetBool("is_admin")
	if !isAdmin {
		apiresp.Error(c, http.StatusForbidden, "需要管理员权限")
		return
	}

	var req struct {
		Host    *string `json:"host"`
		Port    *int    `json:"port"`
		RootDir *string `json:"root_dir"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "参数错误")
		return
	}

	cfg := config.Get()
	if cfg == nil {
		apiresp.Error(c, http.StatusInternalServerError, "配置未加载")
		return
	}

	if req.Host != nil {
		cfg.Server.Host = *req.Host
	}
	if req.Port != nil {
		cfg.Server.Port = *req.Port
	}
	if req.RootDir != nil {
		cfg.Server.RootDir = *req.RootDir
	}

	if err := config.Save(); err != nil {
		apiresp.Error(c, http.StatusInternalServerError, "保存配置失败")
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "配置更新成功"})
}
