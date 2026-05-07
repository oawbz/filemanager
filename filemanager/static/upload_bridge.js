(function () {
  let activeXhr = null;
  let activeReject = null;
  let activeCancelUpload = null;

  // Compute the page's directory URL (always ends with /)
  const __pageBase = (function () {
    var loc = window.location.href;
    var idx = loc.lastIndexOf('/');
    return idx >= 0 ? loc.substring(0, idx + 1) : loc + '/';
  })();

  function resolveUrl(url) {
    if (/^[a-z][a-z0-9+.\-]*:\/\//i.test(url)) return url;
    if (url.startsWith('//')) return url;
    if (url.startsWith('/')) url = '.' + url;
    try { return new URL(url, __pageBase).href; } catch (_) { return url; }
  }

  function formatBytes(value) {
    const units = ["B", "KB", "MB", "GB", "TB"];
    let size = Number(value) || 0;
    let unitIndex = 0;
    while (size >= 1024 && unitIndex < units.length - 1) {
      size /= 1024;
      unitIndex += 1;
    }
    const digits = unitIndex === 0 ? 0 : size < 10 ? 1 : 0;
    return `${size.toFixed(digits)} ${units[unitIndex]}`;
  }

  function ensureOverlay() {
    let overlay = document.getElementById("spanel-native-upload-overlay");
    if (overlay) {
      return overlay;
    }

    overlay = document.createElement("div");
    overlay.id = "spanel-native-upload-overlay";
    overlay.style.position = "fixed";
    overlay.style.top = "16px";
    overlay.style.left = "50%";
    overlay.style.transform = "translateX(-50%)";
    overlay.style.width = "360px";
    overlay.style.maxWidth = "calc(100vw - 32px)";
    overlay.style.boxSizing = "border-box";
    overlay.style.padding = "16px";
    overlay.style.borderRadius = "14px";
    overlay.style.border = "1px solid #28455F";
    overlay.style.background = "rgba(17, 24, 39, 0.95)";
    overlay.style.boxShadow = "0 10px 20px rgba(0, 0, 0, 0.2)";
    overlay.style.zIndex = "999999";
    overlay.style.pointerEvents = "auto";
    overlay.style.fontFamily =
      '"Source Han Sans SC", "PingFang SC", "Microsoft YaHei", sans-serif';
    overlay.style.color = "#F3F4F6";
    overlay.style.display = "none";

    overlay.innerHTML = [
      '<div style="display:flex;align-items:center;gap:12px;">',
      '<div data-role="title" style="flex:1;font-size:14px;font-weight:700;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"></div>',
      '<button type="button" data-role="close" style="flex-shrink:0;width:22px;height:22px;border:0;border-radius:999px;background:#223043;color:#D7E3F0;cursor:pointer;font-size:14px;line-height:22px;padding:0;">×</button>',
      "</div>",
      '<div data-role="file" style="margin-top:8px;font-size:12px;color:#B8C4D0;line-height:1.5;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"></div>',
      '<div style="margin-top:14px;height:9px;border-radius:999px;background:#1E2936;overflow:hidden;">',
      '<div data-role="bar" style="height:100%;width:0%;background:#4EA1F3;"></div>',
      "</div>",
      '<div style="margin-top:10px;display:flex;align-items:center;gap:12px;">',
      '<div data-role="detail" style="flex:1;font-size:12px;color:#8FA0B2;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"></div>',
      '<div data-role="percent" style="font-size:12px;font-weight:700;color:#F3F4F6;flex-shrink:0;"></div>',
      "</div>",
    ].join("");

    document.body.appendChild(overlay);
    overlay
      .querySelector('[data-role="close"]')
      .addEventListener("click", function () {
        if (typeof activeCancelUpload === "function") {
          activeCancelUpload();
          return;
        }
        if (activeXhr) {
          activeXhr.abort();
          return;
        }
        if (activeReject) {
          activeReject(new Error("上传已取消"));
          activeReject = null;
        }
        hideOverlay();
      });
    return overlay;
  }

  function showOverlay(state) {
    const overlay = ensureOverlay();
    overlay.style.display = "block";
    overlay.querySelector('[data-role="title"]').textContent = state.title;
    overlay.querySelector('[data-role="file"]').textContent = state.fileLabel;
    overlay.querySelector('[data-role="detail"]').textContent = state.detail;
    overlay.querySelector('[data-role="percent"]').textContent = state.percent;
    overlay.querySelector('[data-role="bar"]').style.width = state.width;
  }

  function hideOverlay() {
    ensureOverlay().style.display = "none";
  }

  function toErrorMessage(xhr) {
    const fallback = `上传失败 (${xhr.status || 0})`;
    const text = xhr.responseText || "";
    if (!text) {
      return fallback;
    }
    try {
      const parsed = JSON.parse(text);
      if (parsed && parsed.error) {
        return String(parsed.error);
      }
    } catch (_) {}
    return text;
  }

  function buildUrl(endpointUrl, query, fileName) {
    const url = new URL(resolveUrl(endpointUrl));
    if (query && typeof query === "object") {
      Object.entries(query).forEach(([key, value]) => {
        if (value !== undefined && value !== null && value !== "") {
          url.searchParams.set(key, String(value));
        }
      });
    }
    if (fileName) {
      url.searchParams.set("name", fileName);
    }
    return url.toString();
  }

  async function requestJson(url, token, method, body) {
    const response = await fetch(url, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        "Content-Type": "application/json",
      },
      body: body == null ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) {
      let message = text || `请求失败 (${response.status})`;
      try {
        const parsed = JSON.parse(text);
        if (parsed && parsed.error) {
          message = String(parsed.error);
        }
      } catch (_) {}
      throw new Error(message);
    }
    if (!text) {
      return {};
    }
    return JSON.parse(text);
  }

  async function requestNoContent(url, token, method) {
    const response = await fetch(url, {
      method,
      headers: token ? { Authorization: `Bearer ${token}` } : undefined,
    });
    if (!response.ok) {
      const text = await response.text();
      let message = text || `请求失败 (${response.status})`;
      try {
        const parsed = JSON.parse(text);
        if (parsed && parsed.error) {
          message = String(parsed.error);
        }
      } catch (_) {}
      throw new Error(message);
    }
  }

  function buildChunkUrl(baseUrl, uploadId, index) {
    const url = new URL(resolveUrl(baseUrl));
    url.searchParams.set("upload_id", uploadId);
    url.searchParams.set("index", String(index));
    return url.toString();
  }

  function buildUploadSessionUrl(baseUrl, uploadId) {
    const url = new URL(resolveUrl(baseUrl));
    url.searchParams.set("upload_id", uploadId);
    return url.toString();
  }

  function uploadChunkRequest(url, token, blob) {
    return new Promise((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      activeXhr = xhr;
      xhr.open("POST", url, true);
      if (token) {
        xhr.setRequestHeader("Authorization", `Bearer ${token}`);
      }
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      xhr.onerror = function () {
        activeXhr = null;
        reject(new Error("上传失败，网络连接异常"));
      };
      xhr.onabort = function () {
        activeXhr = null;
        reject(new Error("上传已取消"));
      };
      xhr.onload = function () {
        activeXhr = null;
        if (xhr.status >= 200 && xhr.status < 300) {
          resolve();
          return;
        }
        reject(new Error(toErrorMessage(xhr)));
      };
      xhr.send(blob);
    });
  }

  async function uploadFileInChunks(options, file, index, total) {
    const chunkSize = Math.max(1, Number(options.chunkSize) || 0);
    const requestedChunks = Math.max(1, Math.ceil(file.size / chunkSize));
    const retryCount = Math.max(0, Number(options.retryCount) || 0);
    const initResp = await requestJson(
      buildUrl(options.chunkInitUrl, options.query, ""),
      options.token,
      "POST",
      {
        parent: options.query && options.query.parent ? options.query.parent : "",
        name: file.name,
        size: file.size,
        total_chunks: requestedChunks,
        chunk_size: chunkSize,
      },
    );
    const uploadId = initResp && initResp.upload_id ? String(initResp.upload_id) : "";
    if (!uploadId) {
      throw new Error("创建上传会话失败");
    }
    const totalChunks = Math.max(
      1,
      Number(initResp && initResp.total_chunks) || requestedChunks,
    );

    let cancelled = false;
    activeCancelUpload = async function () {
      if (cancelled) {
        return;
      }
      cancelled = true;
      const currentXhr = activeXhr;
      if (currentXhr) {
        currentXhr.abort();
      }
      try {
        await requestNoContent(
          buildUploadSessionUrl(options.cancelUrl, uploadId),
          options.token,
          "DELETE",
        );
      } catch (_) {}
      if (activeReject) {
        activeReject(new Error("上传已取消"));
        activeReject = null;
      }
      hideOverlay();
    };

    let sentBytes = 0;
    try {
      for (let chunkIndex = 0; chunkIndex < totalChunks; chunkIndex += 1) {
        const start = chunkIndex * chunkSize;
        const end = Math.min(file.size, start + chunkSize);
        const blob = file.slice(start, end);
        let lastError = null;

        for (let attempt = 0; attempt <= retryCount; attempt += 1) {
          if (cancelled) {
            throw new Error("上传已取消");
          }
          try {
            showOverlay({
              title: options.title || "正在上传文件",
              fileLabel: `${index}/${total} · ${file.name}`,
              detail: `分片 ${chunkIndex + 1}/${totalChunks}${attempt > 0 ? ` · 重试 ${attempt}/${retryCount}` : ""}`,
              percent: `${file.size > 0 ? Math.min(100, Math.round((sentBytes * 100) / file.size)) : 0}%`,
              width: `${file.size > 0 ? Math.min(100, Math.round((sentBytes * 100) / file.size)) : 0}%`,
            });
            await uploadChunkRequest(
              buildChunkUrl(options.chunkUrl, uploadId, chunkIndex),
              options.token,
              blob,
            );
            sentBytes = end;
            const percent =
              file.size > 0
                ? Math.min(100, Math.round((sentBytes * 100) / file.size))
                : 100;
            showOverlay({
              title: options.title || "正在上传文件",
              fileLabel: `${index}/${total} · ${file.name}`,
              detail: `${formatBytes(sentBytes)} / ${formatBytes(file.size)} · 分片 ${chunkIndex + 1}/${totalChunks}`,
              percent: `${percent}%`,
              width: `${percent}%`,
            });
            lastError = null;
            break;
          } catch (error) {
            lastError = error;
            if (attempt >= retryCount) {
              throw error;
            }
          }
        }

        if (lastError) {
          throw lastError;
        }
      }

      showOverlay({
        title: options.title || "正在上传文件",
        fileLabel: `${index}/${total} · ${file.name}`,
        detail: "分片已上传完成，服务器正在处理中...",
        percent: "100%",
        width: "100%",
      });

      await requestJson(
        buildUploadSessionUrl(options.completeUrl, uploadId),
        options.token,
        "POST",
      );
    } catch (error) {
      if (!cancelled) {
        try {
          await requestNoContent(
            buildUploadSessionUrl(options.cancelUrl, uploadId),
            options.token,
            "DELETE",
          );
        } catch (_) {}
      }
      throw error;
    } finally {
      activeXhr = null;
      activeCancelUpload = null;
    }
  }

  function shouldUseChunkUpload(options, file) {
    return (
      file &&
      typeof file.slice === "function" &&
      Number(options.chunkSize) > 0 &&
      options.chunkInitUrl &&
      options.chunkUrl &&
      options.completeUrl &&
      options.cancelUrl &&
      file.size >= Number(options.chunkSize)
    );
  }

  function uploadSingleFile(options, file, index, total) {
    return new Promise((resolve, reject) => {
      activeReject = reject;
      if (shouldUseChunkUpload(options, file)) {
        uploadFileInChunks(options, file, index, total).then(resolve).catch(reject);
        return;
      }

      const xhr = new XMLHttpRequest();
      activeXhr = xhr;
      xhr.open(
        "POST",
        buildUrl(options.endpointUrl, options.query, file.name),
        true,
      );
      if (options.token) {
        xhr.setRequestHeader("Authorization", `Bearer ${options.token}`);
      }
      xhr.setRequestHeader("Content-Type", "application/octet-stream");

      activeCancelUpload = function () {
        xhr.abort();
      };

      showOverlay({
        title: options.title || "正在上传文件",
        fileLabel: `${index}/${total} · ${file.name}`,
        detail: `0 B / ${formatBytes(file.size)}`,
        percent: "0%",
        width: "0%",
      });

      xhr.upload.onprogress = function (event) {
        const totalBytes = event.lengthComputable ? event.total : file.size;
        const sentBytes = event.loaded || 0;
        const percent =
          totalBytes > 0 ? Math.min(100, Math.round((sentBytes * 100) / totalBytes)) : 0;
        showOverlay({
          title: options.title || "正在上传文件",
          fileLabel: `${index}/${total} · ${file.name}`,
          detail: `${formatBytes(sentBytes)} / ${formatBytes(totalBytes)}`,
          percent: `${percent}%`,
          width: `${percent}%`,
        });
      };

      xhr.onerror = function () {
        activeXhr = null;
        activeReject = null;
        activeCancelUpload = null;
        reject(new Error("上传失败，网络连接异常"));
      };
      xhr.onabort = function () {
        activeXhr = null;
        activeReject = null;
        activeCancelUpload = null;
        reject(new Error("上传已取消"));
      };
      xhr.onload = function () {
        activeXhr = null;
        activeReject = null;
        activeCancelUpload = null;
        if (xhr.status >= 200 && xhr.status < 300) {
          resolve();
          return;
        }
        reject(new Error(toErrorMessage(xhr)));
      };

      xhr.send(file);
    });
  }

  async function uploadFilesInternal(options, filesLike) {
    const files = Array.from(filesLike || []).filter(
      (file) => file && typeof file.name === "string" && file.name.trim() !== "",
    );
    if (!files.length) {
      return { uploadedCount: 0, skippedCount: 0 };
    }

    let uploadedCount = 0;
    try {
      for (let index = 0; index < files.length; index += 1) {
        await uploadSingleFile(options, files[index], index + 1, files.length);
        uploadedCount += 1;
      }
      showOverlay({
        title: "上传完成，正在刷新目录",
        fileLabel: "浏览器正在收尾本次上传任务",
        detail: `已完成 ${uploadedCount}/${files.length} 个文件`,
        percent: "",
        width: "100%",
      });
      return { uploadedCount, skippedCount: files.length - uploadedCount };
    } finally {
      activeXhr = null;
      activeReject = null;
      activeCancelUpload = null;
      window.setTimeout(hideOverlay, 320);
    }
  }

  function pickAndUpload(options) {
    return new Promise((resolve, reject) => {
      const input = document.createElement("input");
      input.type = "file";
      input.multiple = !!options.multiple;
      if (options.accept) {
        input.accept = options.accept;
      }
      input.style.display = "none";
      document.body.appendChild(input);

      const cleanup = function () {
        window.removeEventListener("focus", handleWindowFocus);
        input.remove();
      };

      let settled = false;
      const finish = function (handler) {
        return function (value) {
          if (settled) {
            return;
          }
          settled = true;
          cleanup();
          handler(value);
        };
      };

      const resolveOnce = finish(resolve);
      const rejectOnce = finish(reject);

      const handleWindowFocus = function () {
        window.setTimeout(function () {
          if (!settled && (!input.files || !input.files.length)) {
            resolveOnce({ uploadedCount: 0, skippedCount: 0 });
          }
        }, 300);
      };

      input.addEventListener(
        "change",
        async function () {
          if (!input.files || !input.files.length) {
            resolveOnce({ uploadedCount: 0, skippedCount: 0 });
            return;
          }
          try {
            const result = await uploadFilesInternal(options, input.files);
            resolveOnce(result);
          } catch (error) {
            rejectOnce(error);
          }
        },
        { once: true },
      );

      window.addEventListener("focus", handleWindowFocus);
      input.click();
    });
  }

  window.SPanelUploadBridge = {
    pickAndUpload,
    uploadFiles: function (options, files) {
      return uploadFilesInternal(options, files);
    },
  };

  window.sPanelPickAndUpload = function (
    endpointUrl,
    token,
    parent,
    multiple,
    chunkInitUrl,
    chunkUrl,
    completeUrl,
    cancelUrl,
    chunkSize,
    retryCount,
    accept,
    title,
  ) {
    return pickAndUpload({
      endpointUrl,
      token,
      query: parent ? { parent } : {},
      multiple: !!multiple,
      chunkInitUrl: chunkInitUrl || "",
      chunkUrl: chunkUrl || "",
      completeUrl: completeUrl || "",
      cancelUrl: cancelUrl || "",
      chunkSize: Number(chunkSize) || 0,
      retryCount: Number(retryCount) || 0,
      accept: accept || "",
      title: title || "",
    });
  };

  window.sPanelUploadBrowserFiles = function (
    endpointUrl,
    token,
    parent,
    chunkInitUrl,
    chunkUrl,
    completeUrl,
    cancelUrl,
    chunkSize,
    retryCount,
    files,
    title,
  ) {
    return uploadFilesInternal(
      {
        endpointUrl,
        token,
        query: parent ? { parent } : {},
        multiple: true,
        chunkInitUrl: chunkInitUrl || "",
        chunkUrl: chunkUrl || "",
        completeUrl: completeUrl || "",
        cancelUrl: cancelUrl || "",
        chunkSize: Number(chunkSize) || 0,
        retryCount: Number(retryCount) || 0,
        title: title || "",
      },
      files,
    );
  };

  window._callGlobal = function (name, args) {
    return window[name].apply(window, args);
  };
  window._callPickAndUploadJson = async function (optsJson) {
    const opts = JSON.parse(optsJson || "{}");
    const result = await window.sPanelPickAndUpload(
      opts.endpointUrl || "",
      opts.token || "",
      opts.parent || "",
      !!opts.multiple,
      opts.chunkInitUrl || "",
      opts.chunkUrl || "",
      opts.completeUrl || "",
      opts.cancelUrl || "",
      Number(opts.chunkSize) || 0,
      Number(opts.retryCount) || 0,
      opts.accept || "",
      opts.title || ""
    );
    return JSON.stringify(result || { uploadedCount: 0, skippedCount: 0 });
  };
  window._callUploadFilesJson = async function (optsJson, files) {
    const opts = JSON.parse(optsJson || "{}");
    const result = await window.sPanelUploadBrowserFiles(
      opts.endpointUrl || "",
      opts.token || "",
      opts.parent || "",
      opts.chunkInitUrl || "",
      opts.chunkUrl || "",
      opts.completeUrl || "",
      opts.cancelUrl || "",
      Number(opts.chunkSize) || 0,
      Number(opts.retryCount) || 0,
      files,
      opts.title || ""
    );
    return JSON.stringify(result || { uploadedCount: 0, skippedCount: 0 });
  };
})();
