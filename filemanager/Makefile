.PHONY: all build build-frontend build-backend tidy-backend clean clean-canvaskit compress-assets run

# 输出目录
BACKEND_DIR := .
FRONTEND_DIR := frontend
STATIC_DIR := static
OUTPUT := filemanager
FRONTEND_PKG_CONFIG := $(FRONTEND_DIR)/.dart_tool/package_config.json
FLUTTER := /home/x/flutter/bin/flutter

all: build

## Flutter 依赖（仅在 pubspec 变化后执行）
$(FRONTEND_PKG_CONFIG): $(FRONTEND_DIR)/pubspec.yaml $(FRONTEND_DIR)/pubspec.lock
	cd $(FRONTEND_DIR) && $(FLUTTER) pub get

## 1. 编译 Flutter Web (WASM-GC only)
build-frontend: $(FRONTEND_PKG_CONFIG)
	@echo ">>> 编译 Flutter Web (WASM-GC)..."
	cd $(FRONTEND_DIR) && $(FLUTTER) build web --release --base-href / --wasm
	@echo ">>> 清理未使用的变体和调试符号..."
	@rm -rf $(FRONTEND_DIR)/build/web/canvaskit/chromium \
	       $(FRONTEND_DIR)/build/web/canvaskit/canvaskit.js \
	       $(FRONTEND_DIR)/build/web/canvaskit/canvaskit.wasm \
	       $(FRONTEND_DIR)/build/web/canvaskit/canvaskit.js.symbols \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm_heavy.js.symbols \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm.js.symbols \
	       $(FRONTEND_DIR)/build/web/canvaskit/wimp.wasm \
	       $(FRONTEND_DIR)/build/web/canvaskit/wimp.js \
	       $(FRONTEND_DIR)/build/web/canvaskit/wimp.js.symbols \
	       $(FRONTEND_DIR)/build/web/main.dart.js \
	       $(FRONTEND_DIR)/build/web/main.dart.js.map
	@echo ">>> 复制静态文件到 static ..."
	rsync -a --delete $(FRONTEND_DIR)/build/web/ $(STATIC_DIR)/
	@echo ">>> 修改 base href 为相对路径 ..."
	@sed -i 's|<base href="/">|<base href="./">|g' "$(STATIC_DIR)/index.html"
	@echo ">>> 强制本地化 Flutter Web 默认外链 ..."
	@find "$(STATIC_DIR)" -type f -name "*.js" -print0 | xargs -0 perl -0pi -e "s#https://www\\.gstatic\\.com/flutter-canvaskit/[a-f0-9]+/#canvaskit/#g; s#https://fonts\\.gstatic\\.com/s/#assets/font_fallbacks/#g"
	@echo ">>> Brotli 预压缩大文件（woff2 已自带 Brotli，跳过）..."
	@find "$(STATIC_DIR)" -type f \( -name "*.wasm" -o -name "*.js" -o -name "*.mjs" \) -size +50k -exec sh -c 'brotli -f -q 11 -o "$$1.br" "$$1" && echo "  压缩: $$1 -> $$1.br"' _ {} \;

## 2. 编译 Go 后端（单文件，嵌入静态资源）
build-backend:
	@echo ">>> 编译 Go 后端..."
	CGO_ENABLED=0 go build -ldflags="-s -w" -o $(OUTPUT) .
	@echo ">>> 编译完成: $(OUTPUT)"

## 手动整理 Go 依赖（按需执行）
tidy-backend:
	go mod tidy

## 完整构建
build: build-frontend build-backend

## 仅运行后端（开发模式，需已构建 Flutter）
run:
	./$(OUTPUT) -host 127.0.0.1:8080

## 清理未使用的 CanvasKit 变体（单独执行）
clean-canvaskit:
	@echo ">>> 清理未使用的 CanvasKit 变体..."
	@rm -f $(FRONTEND_DIR)/build/web/canvaskit/canvaskit.wasm \
	       $(FRONTEND_DIR)/build/web/canvaskit/canvaskit.js.symbols \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm_heavy.wasm \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm_heavy.js \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm_heavy.js.symbols \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm.wasm \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm.js \
	       $(FRONTEND_DIR)/build/web/canvaskit/skwasm.js.symbols \
	       $(FRONTEND_DIR)/build/web/canvaskit/wimp.wasm \
	       $(FRONTEND_DIR)/build/web/canvaskit/wimp.js \
	       $(FRONTEND_DIR)/build/web/canvaskit/wimp.js.symbols \
	       $(FRONTEND_DIR)/build/web/canvaskit/chromium/canvaskit.js.symbols
	@echo ">>> 复制 chromium canvaskit 到根目录..."
	@cp $(FRONTEND_DIR)/build/web/canvaskit/chromium/canvaskit.js $(FRONTEND_DIR)/build/web/canvaskit/canvaskit.js
	@cp $(FRONTEND_DIR)/build/web/canvaskit/chromium/canvaskit.wasm $(FRONTEND_DIR)/build/web/canvaskit/canvaskit.wasm
	@echo ">>> 清理完成"

## Brotli 预压缩大文件（单独执行，woff2 已自带 Brotli 跳过）
compress-assets:
	@echo ">>> Brotli 预压缩大文件（woff2 已自带 Brotli，跳过）..."
	@find "$(STATIC_DIR)" -type f \( -name "*.wasm" -o -name "*.js" -o -name "*.mjs" \) -size +50k -exec sh -c 'brotli -f -q 11 -o "$$1.br" "$$1" && echo "  压缩: $$1 -> $$1.br"' _ {} \;
	@echo ">>> 压缩完成"

## 清理
clean:
	rm -f $(OUTPUT)
	rm -rf $(FRONTEND_DIR)/build
	rm -rf $(STATIC_DIR)
