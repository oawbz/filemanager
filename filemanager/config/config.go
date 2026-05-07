package config

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"gopkg.in/yaml.v3"
)

type UserConfig struct {
	Username string `yaml:"username"`
	Password string `yaml:"password"`
	IsAdmin  bool   `yaml:"-"`
}

type ServerConfig struct {
	Host            string `yaml:"host"`
	Port            int    `yaml:"port"`
	RootDir         string `yaml:"root_dir"`
	DAVPublicPrefix string `yaml:"dav_public_prefix"`
}

type AppConfig struct {
	Server ServerConfig `yaml:"server"`
	Users  []UserConfig `yaml:"users"`
	Shell  bool         `yaml:"shell"`
	MCP    MCPConfig    `yaml:"mcp"`
}

type MCPConfig struct {
	Token string `yaml:"token"`
}

var (
	currentConfig *AppConfig
	configPath    string
	configMu      sync.RWMutex
)

func getConfigPath() string {
	if configPath != "" {
		return configPath
	}

	if exePath, err := os.Executable(); err == nil {
		return filepath.Join(filepath.Dir(exePath), "config.yaml")
	}
	return "config.yaml"
}

func SetConfigPath(path string) {
	configPath = path
}

func Load() (*AppConfig, error) {
	configMu.Lock()
	defer configMu.Unlock()

	path := getConfigPath()

	if _, err := os.Stat(path); os.IsNotExist(err) {
		cfg := getDefaultConfig()
		if err := saveDefaultConfigWithComments(path, cfg); err != nil {
			return nil, fmt.Errorf("创建默认配置文件失败: %w", err)
		}
		initConfig(cfg)
		return cfg, nil
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("读取配置文件失败: %w", err)
	}

	cfg := &AppConfig{}
	if err := yaml.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("解析配置文件失败: %w", err)
	}

	initConfig(cfg)
	return cfg, nil
}

func initConfig(cfg *AppConfig) {
	if len(cfg.Users) > 0 {
		cfg.Users[0].IsAdmin = true
	}

	if cfg.Server.RootDir == "" {
		cfg.Server.RootDir = "./"
	}
	os.MkdirAll(cfg.Server.RootDir, 0755)

	for _, user := range cfg.Users {
		if !user.IsAdmin {
			userDir := filepath.Join(cfg.Server.RootDir, user.Username)
			os.MkdirAll(userDir, 0755)
		}
	}

	currentConfig = cfg
}

func Save() error {
	configMu.RLock()
	cfg := currentConfig
	configMu.RUnlock()

	if cfg == nil {
		return fmt.Errorf("配置未加载")
	}

	return saveConfig(getConfigPath(), cfg)
}

func saveConfig(path string, cfg *AppConfig) error {
	data, err := yaml.Marshal(cfg)
	if err != nil {
		return fmt.Errorf("序列化配置失败: %w", err)
	}
	return os.WriteFile(path, data, 0644)
}

func saveDefaultConfigWithComments(path string, cfg *AppConfig) error {
	content := fmt.Sprintf(`server:
  host: %s # 监听地址
  port: %d # 监听端口
  root_dir: %s # 根目录
  dav_public_prefix: /dav # WebDAV 对外访问前缀（反向代理子路径时设置，例如 /admin/dav） 留空或删除该项时，默认使用 /dav

users:
  # 第一个用户为管理员
  - username: %s
    password: "%s"

shell: %t # 是否启用终端功能 false/true

mcp:
  token: "%s"  # MCP 访问令牌（留空表示关闭）
`, cfg.Server.Host, cfg.Server.Port, cfg.Server.RootDir, cfg.Users[0].Username, cfg.Users[0].Password, cfg.Shell, cfg.MCP.Token)

	return os.WriteFile(path, []byte(content), 0644)
}

func Get() *AppConfig {
	configMu.RLock()
	defer configMu.RUnlock()
	return currentConfig
}

func getDefaultConfig() *AppConfig {
	return &AppConfig{
		Server: ServerConfig{
			Host:    "0.0.0.0",
			Port:    8080,
			RootDir: "./",
		},
		Users: []UserConfig{
			{
				Username: "admin",
				Password: "admin123",
			},
		},
		Shell: false,
		MCP: MCPConfig{
			Token: "",
		},
	}
}

func GetUserByUsername(username string) *UserConfig {
	configMu.RLock()
	defer configMu.RUnlock()

	if currentConfig == nil {
		return nil
	}

	for i := range currentConfig.Users {
		if currentConfig.Users[i].Username == username {
			return &currentConfig.Users[i]
		}
	}
	return nil
}

func CheckPassword(username, password string) bool {
	user := GetUserByUsername(username)
	if user == nil {
		return false
	}
	return user.Password == password
}

func GetUserRootDir(username string) string {
	configMu.RLock()
	defer configMu.RUnlock()

	if currentConfig == nil {
		return ""
	}

	user := GetUserByUsername(username)
	if user == nil {
		return ""
	}

	if user.IsAdmin {
		return currentConfig.Server.RootDir
	}

	return filepath.Join(currentConfig.Server.RootDir, username)
}

func AddUser(username, password string) error {
	configMu.Lock()
	defer configMu.Unlock()

	if currentConfig == nil {
		return fmt.Errorf("配置未加载")
	}

	for _, u := range currentConfig.Users {
		if u.Username == username {
			return fmt.Errorf("用户已存在")
		}
	}

	currentConfig.Users = append(currentConfig.Users, UserConfig{
		Username: username,
		Password: password,
	})

	userDir := filepath.Join(currentConfig.Server.RootDir, username)
	if err := os.MkdirAll(userDir, 0755); err != nil {
		return fmt.Errorf("创建用户目录失败: %w", err)
	}

	return saveConfig(getConfigPath(), currentConfig)
}

func UpdateUser(username, newPassword string) error {
	configMu.Lock()
	defer configMu.Unlock()

	if currentConfig == nil {
		return fmt.Errorf("配置未加载")
	}

	for i := range currentConfig.Users {
		if currentConfig.Users[i].Username == username {
			if newPassword != "" {
				currentConfig.Users[i].Password = newPassword
			}
			return saveConfig(getConfigPath(), currentConfig)
		}
	}

	return fmt.Errorf("用户不存在")
}

func DeleteUser(username string) error {
	configMu.Lock()
	defer configMu.Unlock()

	if currentConfig == nil {
		return fmt.Errorf("配置未加载")
	}

	user := GetUserByUsername(username)
	if user == nil {
		return fmt.Errorf("用户不存在")
	}
	if user.IsAdmin {
		return fmt.Errorf("不能删除管理员")
	}

	for i := range currentConfig.Users {
		if currentConfig.Users[i].Username == username {
			currentConfig.Users = append(currentConfig.Users[:i], currentConfig.Users[i+1:]...)
			return saveConfig(getConfigPath(), currentConfig)
		}
	}

	return fmt.Errorf("用户不存在")
}

func ListUsers() []UserConfig {
	configMu.RLock()
	defer configMu.RUnlock()

	if currentConfig == nil {
		return nil
	}

	return currentConfig.Users
}
