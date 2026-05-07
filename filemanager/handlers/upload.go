package handlers

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"filemanager/apiresp"

	"github.com/gin-gonic/gin"
)

type uploadSessionInitRequest struct {
	Parent      string `json:"parent"`
	Name        string `json:"name"`
	Size        int64  `json:"size"`
	TotalChunks int    `json:"total_chunks"`
	ChunkSize   int64  `json:"chunk_size"`
}

type chunkUploadSession struct {
	ID          string
	Parent      string
	FileName    string
	TotalSize   int64
	TotalChunks int
	TempDir     string
	TargetPath  string
	TempPath    string
	NextChunk   int
	CreatedAt   time.Time
	LastSeenAt  time.Time
	mu          sync.Mutex
}

var (
	uploadSessionsMu sync.Mutex
	uploadSessions   = map[string]*chunkUploadSession{}
)

const uploadSessionTTL = 24 * time.Hour

func newUploadSessionID() string {
	return fmt.Sprintf("%d-%d", time.Now().UnixNano(), os.Getpid())
}

func cleanupExpiredUploadSessions() {
	now := time.Now()
	for id, session := range uploadSessions {
		if now.Sub(session.LastSeenAt) <= uploadSessionTTL {
			continue
		}
		_ = os.RemoveAll(session.TempDir)
		delete(uploadSessions, id)
	}
}

func createChunkUploadSession(session *chunkUploadSession) error {
	tempDir, err := os.MkdirTemp("", "filemanager-upload-*")
	if err != nil {
		return err
	}
	session.ID = newUploadSessionID()
	session.TempDir = tempDir
	session.CreatedAt = time.Now()
	session.LastSeenAt = session.CreatedAt

	uploadSessionsMu.Lock()
	defer uploadSessionsMu.Unlock()
	cleanupExpiredUploadSessions()
	uploadSessions[session.ID] = session
	return nil
}

func getChunkUploadSession(id string) (*chunkUploadSession, error) {
	uploadSessionsMu.Lock()
	defer uploadSessionsMu.Unlock()
	cleanupExpiredUploadSessions()
	session := uploadSessions[id]
	if session == nil {
		return nil, fmt.Errorf("上传会话不存在或已过期")
	}
	session.LastSeenAt = time.Now()
	return session, nil
}

func removeChunkUploadSession(id string) {
	uploadSessionsMu.Lock()
	session := uploadSessions[id]
	if session != nil {
		delete(uploadSessions, id)
	}
	uploadSessionsMu.Unlock()
	if session != nil {
		_ = os.Remove(session.TempPath)
		_ = os.RemoveAll(session.TempDir)
	}
}

func setChunkUploadTargetPaths(session *chunkUploadSession) {
	session.TargetPath = filepath.Join(session.Parent, filepath.Base(session.FileName))
	session.TempPath = filepath.Join(
		session.Parent,
		fmt.Sprintf(".%s.upload-%s.part", filepath.Base(session.FileName), session.ID),
	)
}

func prepareChunkUploadTarget(session *chunkUploadSession) error {
	if err := os.MkdirAll(filepath.Dir(session.TempPath), 0755); err != nil {
		return err
	}
	return os.WriteFile(session.TempPath, []byte{}, 0644)
}

func appendChunkToSession(session *chunkUploadSession, index int, src io.Reader) error {
	session.mu.Lock()
	defer session.mu.Unlock()
	if index < session.NextChunk {
		return nil
	}
	if index > session.NextChunk {
		return fmt.Errorf("分片顺序无效，期望索引 %d", session.NextChunk)
	}

	file, err := os.OpenFile(session.TempPath, os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		return err
	}
	defer file.Close()

	if _, err := io.Copy(file, src); err != nil {
		return err
	}

	session.NextChunk++
	session.LastSeenAt = time.Now()
	return nil
}

func finalizeChunkUploadSession(session *chunkUploadSession) error {
	session.mu.Lock()
	defer session.mu.Unlock()
	if session.NextChunk != session.TotalChunks {
		return fmt.Errorf("上传尚未完成，已接收 %d/%d 个分片", session.NextChunk, session.TotalChunks)
	}

	if session.TotalSize > 0 {
		info, err := os.Stat(session.TempPath)
		if err != nil {
			return fmt.Errorf("校验上传文件大小失败: %w", err)
		}
		if info.Size() != session.TotalSize {
			return fmt.Errorf("上传大小不一致：期望 %d 字节，实际 %d 字节", session.TotalSize, info.Size())
		}
	}

	return os.Rename(session.TempPath, session.TargetPath)
}

func InitFileUpload(c *gin.Context) {
	var req uploadSessionInitRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresp.Error(c, http.StatusBadRequest, "请求参数无效")
		return
	}

	fileName := strings.TrimSpace(req.Name)
	if fileName == "" || strings.Contains(fileName, "/") {
		apiresp.Error(c, http.StatusBadRequest, "文件名无效")
		return
	}
	if req.TotalChunks <= 0 {
		apiresp.Error(c, http.StatusBadRequest, "分片数量无效")
		return
	}

	totalChunks := req.TotalChunks
	if req.Size > 0 && req.ChunkSize > 0 {
		calculated := int((req.Size + req.ChunkSize - 1) / req.ChunkSize)
		if calculated > 0 {
			totalChunks = calculated
		}
	}

	// 使用权限控制解析路径
	actualParent, err := resolveFilePath(c, req.Parent)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, "路径无效")
		return
	}

	session := &chunkUploadSession{
		Parent:      actualParent,
		FileName:    fileName,
		TotalSize:   req.Size,
		TotalChunks: totalChunks,
	}

	if err := createChunkUploadSession(session); err != nil {
		apiresp.Error(c, http.StatusInternalServerError, "创建上传会话失败")
		return
	}

	setChunkUploadTargetPaths(session)
	if err := prepareChunkUploadTarget(session); err != nil {
		removeChunkUploadSession(session.ID)
		apiresp.Error(c, http.StatusBadGateway, "初始化上传会话失败")
		return
	}

	c.JSON(http.StatusCreated, gin.H{
		"upload_id":    session.ID,
		"total_chunks": session.TotalChunks,
	})
}

func UploadFileChunk(c *gin.Context) {
	uploadID := strings.TrimSpace(c.Query("upload_id"))
	index, err := strconv.Atoi(strings.TrimSpace(c.Query("index")))
	if uploadID == "" || err != nil || index < 0 {
		apiresp.Error(c, http.StatusBadRequest, "分片参数无效")
		return
	}

	session, err := getChunkUploadSession(uploadID)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, err.Error())
		return
	}

	if index >= session.TotalChunks {
		apiresp.Error(c, http.StatusBadRequest, "分片索引越界")
		return
	}

	if err := appendChunkToSession(session, index, c.Request.Body); err != nil {
		apiresp.Error(c, http.StatusBadGateway, "写入上传分片失败")
		return
	}

	c.Status(http.StatusNoContent)
}

func CompleteFileUpload(c *gin.Context) {
	uploadID := strings.TrimSpace(c.Query("upload_id"))
	if uploadID == "" {
		apiresp.Error(c, http.StatusBadRequest, "缺少上传会话")
		return
	}

	session, err := getChunkUploadSession(uploadID)
	if err != nil {
		apiresp.Error(c, http.StatusBadRequest, err.Error())
		return
	}

	if err := finalizeChunkUploadSession(session); err != nil {
		apiresp.Error(c, http.StatusBadGateway, fmt.Sprintf("上传文件失败: %s", err.Error()))
		return
	}

	targetPath := session.TargetPath
	removeChunkUploadSession(uploadID)

	c.JSON(http.StatusCreated, gin.H{
		"path": targetPath,
	})
}

func CancelFileUpload(c *gin.Context) {
	uploadID := strings.TrimSpace(c.Query("upload_id"))
	if uploadID == "" {
		apiresp.Error(c, http.StatusBadRequest, "缺少上传会话")
		return
	}

	removeChunkUploadSession(uploadID)
	c.Status(http.StatusNoContent)
}
