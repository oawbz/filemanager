package handlers

import (
	"archive/tar"
	"archive/zip"
	"compress/bzip2"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"filemanager/apiresp"
	"filemanager/config"

	"github.com/gin-gonic/gin"
)

const filePreviewLimit = 128 * 1024

type fileEntryResponse struct {
	Name           string `json:"name"`
	Path           string `json:"path"`
	IsDir          bool   `json:"is_dir"`
	Size           int64  `json:"size"`
	Permissions    string `json:"permissions"`
	PermissionMode string `json:"permission_mode"`
	Owner          string `json:"owner"`
	Group          string `json:"group"`
	ModifiedAt     string `json:"modified_at"`
	CreatedAt      string `json:"created_at"`
}

type fileListResponse struct {
	Path    string              `json:"path"`
	Parent  string              `json:"parent"`
	Entries []fileEntryResponse `json:"entries"`
}

type filePropertiesResponse struct {
	Path           string `json:"path"`
	Type           string `json:"type"`
	Permissions    string `json:"permissions"`
	PermissionMode string `json:"permission_mode"`
	Owner          string `json:"owner"`
	Group          string `json:"group"`
	Size           int64  `json:"size"`
	SizeCalculated bool   `json:"size_calculated"`
	ModifiedAt     string `json:"modified_at"`
	CreatedAt      string `json:"created_at"`
}

type mkdirRequest struct {
	Parent string `json:"parent"`
	Name   string `json:"name"`
}

type createFileRequest struct {
	Parent string `json:"parent"`
	Name   string `json:"name"`
}

type renameRequest struct {
	Path    string `json:"path"`
	NewName string `json:"new_name"`
}

type deleteRequest struct {
	Path string `json:"path"`
}

type transferRequest struct {
	Paths     []string `json:"paths"`
	TargetDir string   `json:"target_dir"`
}

type archiveRequest struct {
	Paths       []string `json:"paths"`
	TargetDir   string   `json:"target_dir"`
	ArchiveName string   `json:"archive_name"`
}

type extractRequest struct {
	Path string `json:"path"`
}

type fileContentUpdateRequest struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

func normalizePath(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || trimmed == "." {
		return "/"
	}
	if !strings.HasPrefix(trimmed, "/") {
		trimmed = "/" + trimmed
	}
	cleaned := filepath.Clean(trimmed)
	if cleaned == "." {
		return "/"
	}
	return cleaned
}

// getUserRootDir 获取用户的根目录
func getUserRootDir(c *gin.Context) string {
	username := c.GetString("username")
	isAdmin := c.GetBool("is_admin")
	
	cfg := config.Get()
	if cfg == nil {
		return ""
	}
	
	var rootDir string
	if isAdmin {
		rootDir = cfg.Server.RootDir
	} else {
		rootDir = filepath.Join(cfg.Server.RootDir, username)
	}
	
	// 转换为绝对路径
	absPath, err := filepath.Abs(rootDir)
	if err != nil {
		return rootDir
	}
	return absPath
}

// resolveFilePath 将用户路径转换为实际文件路径
func resolveFilePath(c *gin.Context, userPath string) (string, error) {
	userRoot := getUserRootDir(c)
	if userRoot == "" {
		return "", fmt.Errorf("无法获取用户目录")
	}
	
	normalizedPath := normalizePath(userPath)
	fullPath := filepath.Join(userRoot, normalizedPath)
	
	// 确保路径在用户根目录内
	cleanRoot := filepath.Clean(userRoot)
	cleanFull := filepath.Clean(fullPath)
	
	if !strings.HasPrefix(cleanFull, cleanRoot) {
		return "", fmt.Errorf("路径越界")
	}
	
	return fullPath, nil
}

// getUserRelativePath 获取相对于用户根目录的路径
func getUserRelativePath(c *gin.Context, fullPath string) string {
	userRoot := getUserRootDir(c)
	if userRoot == "" {
		return "/"
	}
	
	cleanRoot := filepath.Clean(userRoot)
	cleanFull := filepath.Clean(fullPath)
	
	if !strings.HasPrefix(cleanFull, cleanRoot) {
		return "/"
	}
	
	rel, err := filepath.Rel(cleanRoot, cleanFull)
	if err != nil {
		return "/"
	}
	
	if rel == "." {
		return "/"
	}
	
	return "/" + rel
}

func getFileModeString(mode os.FileMode) string {
	return fmt.Sprintf("%04o", mode.Perm())
}

func getFileInfo(path string) (fileEntryResponse, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return fileEntryResponse{}, err
	}

	stat := info
	if info.Mode()&os.ModeSymlink != 0 {
		if realInfo, err := os.Stat(path); err == nil {
			stat = realInfo
		}
	}

	owner, group := getFileOwnerGroup(path)

	return fileEntryResponse{
		Name:           info.Name(),
		Path:           path,
		IsDir:          stat.IsDir(),
		Size:           stat.Size(),
		Permissions:    stat.Mode().Perm().String(),
		PermissionMode: getFileModeString(stat.Mode()),
		Owner:          owner,
		Group:          group,
		ModifiedAt:     stat.ModTime().Format("2006-01-02 15:04:05"),
		CreatedAt:      stat.ModTime().Format("2006-01-02 15:04:05"),
	}, nil
}

func getFileOwnerGroup(path string) (string, string) {
	return "-", "-"
}

func calculateDirSize(path string) (int64, error) {
	var size int64
	err := filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() {
			size += info.Size()
		}
		return nil
	})
	return size, err
}

func ListFiles(c *gin.Context) {
	userPath := c.Query("path")
	
	// 解析实际路径
	actualPath, err := resolveFilePath(c, userPath)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}

	info, err := os.Stat(actualPath)
	if err != nil {
		if os.IsNotExist(err) {
			apiresp.Error(c, http.StatusBadRequest, "路径不存在或不可访问")
		} else {
			apiresp.Error(c, http.StatusBadRequest, "读取目录失败")
		}
		return
	}
	if !info.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目标不是目录")
		return
	}

	dirEntries, err := os.ReadDir(actualPath)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "读取目录失败")
		return
	}

	respEntries := make([]fileEntryResponse, 0, len(dirEntries))
	for _, entry := range dirEntries {
		fullPath := filepath.Join(actualPath, entry.Name())
		fileInfo, err := getFileInfo(fullPath)
		if err != nil {
			continue
		}
		// 转换为用户相对路径
		fileInfo.Path = getUserRelativePath(c, fullPath)
		respEntries = append(respEntries, fileInfo)
	}

	sort.Slice(respEntries, func(i, j int) bool {
		if respEntries[i].IsDir != respEntries[j].IsDir {
			return respEntries[i].IsDir
		}
		return strings.ToLower(respEntries[i].Name) < strings.ToLower(respEntries[j].Name)
	})

	// 获取用户相对路径
	relativePath := getUserRelativePath(c, actualPath)
	parent := ""
	if relativePath != "/" {
		parentPath := filepath.Dir(actualPath)
		parent = getUserRelativePath(c, parentPath)
		if parent == "" {
			parent = "/"
		}
	}

	c.JSON(http.StatusOK, fileListResponse{
		Path:    relativePath,
		Parent:  parent,
		Entries: respEntries,
	})
}

func GetFileContent(c *gin.Context) {
	actualPath, err := resolveFilePath(c, c.Query("path"))
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}

	info, err := os.Stat(actualPath)
	if err != nil {
		if os.IsNotExist(err) {
			apiresp.Error(c, http.StatusBadRequest, "文件不存在或不可访问")
		} else {
			apiresp.Error(c, http.StatusBadRequest, "读取文件失败")
		}
		return
	}
	if info.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目录不支持预览")
		return
	}

	f, err := os.Open(actualPath)
	if err != nil {
		apiresp.Error(c, http.StatusBadGateway, "读取文件失败")
		return
	}
	defer f.Close()

	buf := make([]byte, filePreviewLimit+1)
	n, err := f.Read(buf)
	if err != nil && err != io.EOF {
		apiresp.Error(c, http.StatusBadGateway, "读取文件失败")
		return
	}
	content := buf[:n]
	truncated := n > filePreviewLimit
	if truncated {
		content = content[:filePreviewLimit]
	}

	if !utf8.Valid(content) {
		apiresp.Error(c, http.StatusBadRequest, "该文件不是 UTF-8 文本，暂不支持预览")
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"path":        getUserRelativePath(c, actualPath),
		"name":        filepath.Base(actualPath),
		"size":        info.Size(),
		"modified_at": info.ModTime().Format("2006-01-02 15:04:05"),
		"content":     string(content),
		"truncated":   truncated,
	})
}

func UpdateFileContent(c *gin.Context) {
	var req fileContentUpdateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}

	actualPath, err := resolveFilePath(c, req.Path)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}

	info, err := os.Stat(actualPath)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "文件不存在或不可访问")
		return
	}
	if info.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目录不支持在线编辑")
		return
	}

	if err := os.WriteFile(actualPath, []byte(req.Content), 0644); err != nil {
		apiresp.Error(c, http.StatusBadGateway, "保存文件失败")
		return
	}

	c.Status(http.StatusNoContent)
}

func GetFileProperties(c *gin.Context) {
	actualPath, err := resolveFilePath(c, c.Query("path"))
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	calculateSize := strings.EqualFold(strings.TrimSpace(c.Query("calculate_size")), "true")

	info, err := os.Stat(actualPath)
	if err != nil {
		if os.IsNotExist(err) {
			apiresp.Error(c, http.StatusBadRequest, "文件不存在或不可访问")
		} else {
			apiresp.Error(c, http.StatusBadRequest, "读取文件信息失败")
		}
		return
	}

	size := info.Size()
	sizeCalculated := !info.IsDir()
	if info.IsDir() && calculateSize {
		size, err = calculateDirSize(actualPath)
		if err != nil {
			apiresp.Error(c, http.StatusBadGateway, "计算目录大小失败")
			return
		}
		sizeCalculated = true
	}

	fileType := "file"
	if info.IsDir() {
		fileType = "dir"
	}

	owner, group := getFileOwnerGroup(actualPath)

	c.JSON(http.StatusOK, filePropertiesResponse{
		Path:           getUserRelativePath(c, actualPath),
		Type:           fileType,
		Permissions:    info.Mode().Perm().String(),
		PermissionMode: getFileModeString(info.Mode()),
		Owner:          owner,
		Group:          group,
		Size:           size,
		SizeCalculated: sizeCalculated,
		ModifiedAt:     info.ModTime().Format("2006-01-02 15:04:05"),
		CreatedAt:      info.ModTime().Format("2006-01-02 15:04:05"),
	})
}

func CreateDirectory(c *gin.Context) {
	var req mkdirRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		apiresp.Error(c, http.StatusBadRequest, "目录名称不能为空")
		return
	}
	if strings.Contains(req.Name, "/") {
		apiresp.Error(c, http.StatusBadRequest, "目录名称不能包含 /")
		return
	}

	actualParent, err := resolveFilePath(c, req.Parent)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	target := filepath.Join(actualParent, req.Name)

	if err := os.MkdirAll(target, 0755); err != nil {
		apiresp.Error(c, http.StatusBadGateway, "创建目录失败")
		return
	}

	c.JSON(http.StatusCreated, gin.H{"path": getUserRelativePath(c, target)})
}

func CreateFile(c *gin.Context) {
	var req createFileRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		apiresp.Error(c, http.StatusBadRequest, "文件名称不能为空")
		return
	}
	if strings.Contains(req.Name, "/") {
		apiresp.Error(c, http.StatusBadRequest, "文件名称不能包含 /")
		return
	}

	actualParent, err := resolveFilePath(c, req.Parent)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	target := filepath.Join(actualParent, req.Name)

	if _, err := os.Stat(target); err == nil {
		apiresp.Error(c, http.StatusBadRequest, "目标已存在")
		return
	}

	f, err := os.Create(target)
	if err != nil {
		apiresp.Error(c, http.StatusBadGateway, "创建文件失败")
		return
	}
	f.Close()

	c.JSON(http.StatusCreated, gin.H{"path": getUserRelativePath(c, target)})
}

func UploadFile(c *gin.Context) {
	actualParent, err := resolveFilePath(c, c.Query("parent"))
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	fileName := strings.TrimSpace(c.Query("name"))

	if fileName == "" {
		apiresp.Error(c, http.StatusBadRequest, "缺少文件名")
		return
	}
	if strings.Contains(fileName, "/") {
		apiresp.Error(c, http.StatusBadRequest, "文件名不能包含 /")
		return
	}

	target := filepath.Join(actualParent, filepath.Base(fileName))

	f, err := os.Create(target)
	if err != nil {
		apiresp.Error(c, http.StatusBadGateway, "上传文件失败")
		return
	}
	defer f.Close()

	if _, err := io.Copy(f, c.Request.Body); err != nil {
		apiresp.Error(c, http.StatusBadGateway, "上传文件失败")
		return
	}

	c.JSON(http.StatusCreated, gin.H{"path": getUserRelativePath(c, target)})
}

func CopyFiles(c *gin.Context) {
	var req transferRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}

	paths := req.Paths
	if len(paths) == 0 {
		apiresp.Error(c, http.StatusBadRequest, "请至少选择一个文件或目录")
		return
	}

	actualTargetDir, err := resolveFilePath(c, req.TargetDir)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "目标路径无效")
		return
	}
	targetInfo, err := os.Stat(actualTargetDir)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "目标目录不存在或不可访问")
		return
	}
	if !targetInfo.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目标不是目录")
		return
	}

	for _, src := range paths {
		actualSrc, err := resolveFilePath(c, src)
		if err != nil {
			apiresp.Error(c, http.StatusBadRequest, "源路径无效")
			return
		}
		dst := filepath.Join(actualTargetDir, filepath.Base(actualSrc))
		if err := copyPath(actualSrc, dst); err != nil {
			apiresp.Error(c, http.StatusBadGateway, fmt.Sprintf("复制 %s 失败: %v", filepath.Base(actualSrc), err))
			return
		}
	}

	c.JSON(http.StatusOK, gin.H{"count": len(paths)})
}

func copyPath(src, dst string) error {
	srcInfo, err := os.Stat(src)
	if err != nil {
		return err
	}

	if srcInfo.IsDir() {
		return filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			relPath, err := filepath.Rel(src, path)
			if err != nil {
				return err
			}
			dstPath := filepath.Join(dst, relPath)
			if info.IsDir() {
				return os.MkdirAll(dstPath, info.Mode())
			}
			return copyFile(path, dstPath)
		})
	}

	return copyFile(src, dst)
}

func copyFile(src, dst string) error {
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	_, err = io.Copy(dstFile, srcFile)
	return err
}

func MoveFiles(c *gin.Context) {
	var req transferRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}

	paths := req.Paths
	if len(paths) == 0 {
		apiresp.Error(c, http.StatusBadRequest, "请至少选择一个文件或目录")
		return
	}

	actualTargetDir, err := resolveFilePath(c, req.TargetDir)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "目标路径无效")
		return
	}
	targetInfo, err := os.Stat(actualTargetDir)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "目标目录不存在或不可访问")
		return
	}
	if !targetInfo.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目标不是目录")
		return
	}

	for _, src := range paths {
		actualSrc, err := resolveFilePath(c, src)
		if err != nil {
			apiresp.Error(c, http.StatusBadRequest, "源路径无效")
			return
		}
		dst := filepath.Join(actualTargetDir, filepath.Base(actualSrc))
		if err := os.Rename(actualSrc, dst); err != nil {
			apiresp.Error(c, http.StatusBadGateway, fmt.Sprintf("移动 %s 失败: %v", filepath.Base(actualSrc), err))
			return
		}
	}

	c.JSON(http.StatusOK, gin.H{"count": len(paths)})
}

func ArchiveFiles(c *gin.Context) {
	var req archiveRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}

	paths := req.Paths
	if len(paths) == 0 {
		apiresp.Error(c, http.StatusBadRequest, "请至少选择一个文件或目录")
		return
	}

	actualTargetDir, err := resolveFilePath(c, req.TargetDir)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "目标路径无效")
		return
	}
	archiveName := strings.TrimSpace(req.ArchiveName)
	if archiveName == "" {
		apiresp.Error(c, http.StatusBadRequest, "压缩包名称不能为空")
		return
	}
	if strings.Contains(archiveName, "/") {
		apiresp.Error(c, http.StatusBadRequest, "压缩包名称不能包含 /")
		return
	}
	if !strings.HasSuffix(strings.ToLower(archiveName), ".tar") {
		archiveName += ".tar"
	}

	targetInfo, err := os.Stat(actualTargetDir)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "目标目录不存在或不可访问")
		return
	}
	if !targetInfo.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目标不是目录")
		return
	}

	target := filepath.Join(actualTargetDir, archiveName)
	if _, err := os.Stat(target); err == nil {
		apiresp.Error(c, http.StatusBadRequest, "目标压缩包已存在")
		return
	}

	actualFirstPath, err := resolveFilePath(c, paths[0])
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "源路径无效")
		return
	}
	baseDir := filepath.Dir(actualFirstPath)

	tarFile, err := os.Create(target)
	if err != nil {
		apiresp.Error(c, http.StatusBadGateway, "创建压缩包失败")
		return
	}
	defer tarFile.Close()

	tw := tar.NewWriter(tarFile)
	defer tw.Close()

	for _, path := range paths {
		actualPath, err := resolveFilePath(c, path)
		if err != nil {
			apiresp.Error(c, http.StatusBadRequest, "源路径无效")
			return
		}
		err = filepath.Walk(actualPath, func(walkPath string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}

			relPath, err := filepath.Rel(baseDir, walkPath)
			if err != nil {
				return err
			}

			// 处理符号链接
			linkTarget := ""
			if info.Mode()&os.ModeSymlink != 0 {
				if target, err := os.Readlink(walkPath); err == nil {
					linkTarget = target
				}
			}

			header, err := tar.FileInfoHeader(info, linkTarget)
			if err != nil {
				return err
			}
			header.Name = relPath

			if err := tw.WriteHeader(header); err != nil {
				return err
			}

			if !info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
				file, err := os.Open(walkPath)
				if err != nil {
					return err
				}
				_, copyErr := io.Copy(tw, file)
				file.Close()
				if copyErr != nil {
					return copyErr
				}
			}

			return nil
		})
		if err != nil {
			apiresp.Error(c, http.StatusBadGateway, fmt.Sprintf("压缩失败: %v", err))
			return
		}
	}

	c.JSON(http.StatusCreated, gin.H{"path": getUserRelativePath(c, target)})
}

func ExtractArchive(c *gin.Context) {
	var req extractRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}

	actualPath, err := resolveFilePath(c, req.Path)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	if getUserRelativePath(c, actualPath) == "/" {
		apiresp.Error(c, http.StatusBadRequest, "不支持解压根目录")
		return
	}

	info, err := os.Stat(actualPath)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "文件不存在或不可访问")
		return
	}
	if info.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目录不支持解压")
		return
	}

	targetDir := filepath.Dir(actualPath)
	lowerName := strings.ToLower(actualPath)

	switch {
	case strings.HasSuffix(lowerName, ".zip"):
		err = extractZip(actualPath, targetDir)
	case strings.HasSuffix(lowerName, ".tar.gz") || strings.HasSuffix(lowerName, ".tgz"):
		err = extractTarGz(actualPath, targetDir)
	case strings.HasSuffix(lowerName, ".tar.bz2") || strings.HasSuffix(lowerName, ".tbz2"):
		err = extractTarBz2(actualPath, targetDir)
	case strings.HasSuffix(lowerName, ".tar"):
		err = extractTar(actualPath, targetDir)
	default:
		apiresp.Error(c, http.StatusBadRequest, "不支持的压缩格式，支持: .tar, .tar.gz, .tgz, .tar.bz2, .tbz2, .zip")
		return
	}

	if err != nil {
		apiresp.Error(c, http.StatusBadGateway, fmt.Sprintf("解压失败: %v", err))
		return
	}

	c.Status(http.StatusNoContent)
}

func extractTar(archivePath, targetDir string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("打开压缩包失败: %w", err)
	}
	defer file.Close()

	return extractTarReader(file, targetDir)
}

func extractTarGz(archivePath, targetDir string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("打开压缩包失败: %w", err)
	}
	defer file.Close()

	gz, err := gzip.NewReader(file)
	if err != nil {
		return fmt.Errorf("创建gzip reader失败: %w", err)
	}
	defer gz.Close()

	return extractTarReader(gz, targetDir)
}

func extractTarBz2(archivePath, targetDir string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("打开压缩包失败: %w", err)
	}
	defer file.Close()

	bz2 := bzip2.NewReader(file)
	return extractTarReader(bz2, targetDir)
}

func extractTarReader(r io.Reader, targetDir string) error {
	tr := tar.NewReader(r)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("读取tar条目失败: %w", err)
		}

		target := filepath.Join(targetDir, header.Name)
		if !strings.HasPrefix(filepath.Clean(target), filepath.Clean(targetDir)) {
			continue
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, os.FileMode(header.Mode)); err != nil {
				return fmt.Errorf("创建目录失败: %w", err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
				return fmt.Errorf("创建目录失败: %w", err)
			}
			outFile, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode))
			if err != nil {
				return fmt.Errorf("创建文件失败: %w", err)
			}
			if _, err := io.Copy(outFile, tr); err != nil {
				outFile.Close()
				return fmt.Errorf("写入文件失败: %w", err)
			}
			outFile.Close()
		}
	}
	return nil
}

func extractZip(archivePath, targetDir string) error {
	r, err := zip.OpenReader(archivePath)
	if err != nil {
		return fmt.Errorf("打开zip文件失败: %w", err)
	}
	defer r.Close()

	for _, f := range r.File {
		target := filepath.Join(targetDir, f.Name)
		if !strings.HasPrefix(filepath.Clean(target), filepath.Clean(targetDir)) {
			continue
		}

		if f.FileInfo().IsDir() {
			if err := os.MkdirAll(target, f.Mode()); err != nil {
				return fmt.Errorf("创建目录失败: %w", err)
			}
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return fmt.Errorf("创建目录失败: %w", err)
		}

		outFile, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, f.Mode())
		if err != nil {
			return fmt.Errorf("创建文件失败: %w", err)
		}

		rc, err := f.Open()
		if err != nil {
			outFile.Close()
			return fmt.Errorf("打开zip条目失败: %w", err)
		}

		if _, err := io.Copy(outFile, rc); err != nil {
			rc.Close()
			outFile.Close()
			return fmt.Errorf("写入文件失败: %w", err)
		}

		rc.Close()
		outFile.Close()
	}
	return nil
}

func DownloadFiles(c *gin.Context) {
	paths := c.QueryArray("path")
	if len(paths) == 0 {
		apiresp.Error(c, http.StatusBadRequest, "请至少选择一个文件或目录")
		return
	}

	if len(paths) == 1 {
		actualPath, err := resolveFilePath(c, paths[0])
		if err != nil {
			apiresp.Error(c, http.StatusBadRequest, "路径无效")
			return
		}
		info, err := os.Stat(actualPath)
		if err != nil {
			apiresp.Error(c, http.StatusBadRequest, "文件不存在或不可访问")
			return
		}
		if !info.IsDir() {
			c.Header("Content-Description", "File Transfer")
			c.Header("Content-Transfer-Encoding", "binary")
			c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%s", filepath.Base(actualPath)))
			c.Header("Content-Type", "application/octet-stream")
			c.File(actualPath)
			return
		}
	}

	archiveName := "archive.tar"
	if len(paths) == 1 {
		archiveName = filepath.Base(paths[0]) + ".tar"
	}

	c.Header("Content-Type", "application/x-tar")
	c.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%s", archiveName))

	tw := tar.NewWriter(c.Writer)
	defer tw.Close()

	actualFirstPath, err := resolveFilePath(c, paths[0])
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	baseDir := filepath.Dir(actualFirstPath)

	for _, path := range paths {
		actualPath, err := resolveFilePath(c, path)
		if err != nil {
			apiresp.Error(c, http.StatusBadRequest, "路径无效")
			return
		}
		err = filepath.Walk(actualPath, func(walkPath string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}

			relPath, err := filepath.Rel(baseDir, walkPath)
			if err != nil {
				return err
			}

			// 处理符号链接
			linkTarget := ""
			if info.Mode()&os.ModeSymlink != 0 {
				if target, err := os.Readlink(walkPath); err == nil {
					linkTarget = target
				}
			}

			header, err := tar.FileInfoHeader(info, linkTarget)
			if err != nil {
				return err
			}
			header.Name = relPath

			if err := tw.WriteHeader(header); err != nil {
				return err
			}

			if !info.IsDir() && info.Mode()&os.ModeSymlink == 0 {
				file, err := os.Open(walkPath)
				if err != nil {
					return err
				}
				_, copyErr := io.Copy(tw, file)
				file.Close()
				if copyErr != nil {
					return copyErr
				}
			}

			return nil
		})
		if err != nil {
			return
		}
	}
}

func RenameFile(c *gin.Context) {
	var req renameRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}
	if strings.TrimSpace(req.NewName) == "" {
		apiresp.Error(c, http.StatusBadRequest, "新名称不能为空")
		return
	}
	if strings.Contains(req.NewName, "/") {
		apiresp.Error(c, http.StatusBadRequest, "新名称不能包含 /")
		return
	}

	actualOldPath, err := resolveFilePath(c, req.Path)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	newPath := filepath.Join(filepath.Dir(actualOldPath), req.NewName)

	if _, err := os.Stat(actualOldPath); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "源文件不存在")
		return
	}

	if _, err := os.Stat(newPath); err == nil {
		apiresp.Error(c, http.StatusBadRequest, "目标已存在")
		return
	}

	if err := os.Rename(actualOldPath, newPath); err != nil {
		apiresp.Error(c, http.StatusBadGateway, "重命名失败")
		return
	}

	c.JSON(http.StatusOK, gin.H{"path": getUserRelativePath(c, newPath)})
}

func DeleteFile(c *gin.Context) {
	var req deleteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}

	actualPath, err := resolveFilePath(c, req.Path)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	if getUserRelativePath(c, actualPath) == "/" {
		apiresp.Error(c, http.StatusBadRequest, "不支持删除根目录")
		return
	}

	if _, err := os.Stat(actualPath); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "目标不存在或不可访问")
		return
	}

	if err := os.RemoveAll(actualPath); err != nil {
		apiresp.Error(c, http.StatusBadGateway, "删除文件失败")
		return
	}

	c.Status(http.StatusNoContent)
}

func PreviewFile(c *gin.Context) {
	actualPath, err := resolveFilePath(c, c.Query("path"))
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}
	inline := strings.EqualFold(strings.TrimSpace(c.Query("inline")), "true")

	info, err := os.Stat(actualPath)
	if err != nil {
		if os.IsNotExist(err) {
			apiresp.Error(c, http.StatusBadRequest, "文件不存在或不可访问")
		} else {
			apiresp.Error(c, http.StatusBadRequest, "读取文件失败")
		}
		return
	}
	if info.IsDir() {
		apiresp.Error(c, http.StatusBadRequest, "目录不支持预览")
		return
	}

	c.Header("Content-Description", "File Transfer")
	c.Header("Content-Transfer-Encoding", "binary")
	c.Header("Content-Length", fmt.Sprintf("%d", info.Size()))

	disposition := "attachment"
	if inline {
		disposition = "inline"
	}
	c.Header("Content-Disposition", fmt.Sprintf("%s; filename=%s", disposition, filepath.Base(actualPath)))
	c.Header("Content-Type", "application/octet-stream")
	c.File(actualPath)
}

func formatTime(t time.Time) string {
	return t.Format("2006-01-02 15:04:05")
}
