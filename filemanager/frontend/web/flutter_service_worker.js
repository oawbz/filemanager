'use strict';

const CACHE_NAME = 'filemanager-v1';
const STATIC_ASSETS = [
  './',
  './main.dart.js',
  './canvaskit/chromium/canvaskit.js',
  './canvaskit/chromium/canvaskit.wasm',
  './assets/assets/fonts/SourceHanSansSC-Medium.woff2',
  './assets/assets/fonts/CascadiaMonoPL.woff2',
  './flutter_bootstrap.js',
  './flutter.js',
];

// 安装时预缓存关键资源
self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return cache.addAll(STATIC_ASSETS).catch((err) => {
        console.warn('预缓存部分资源失败:', err);
      });
    })
  );
  self.skipWaiting();
});

// 激活时清理旧缓存
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) => {
      return Promise.all(
        keys
          .filter((key) => key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      );
    })
  );
  self.clients.claim();
});

// 拦截请求，使用缓存优先策略
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);

  // 只处理同源请求
  if (url.origin !== location.origin) {
    return;
  }

  // API 请求使用网络优先
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/dav')) {
    event.respondWith(networkFirst(event.request));
    return;
  }

  // 静态资源使用缓存优先
  event.respondWith(cacheFirst(event.request));
});

// 缓存优先策略
async function cacheFirst(request) {
  const cached = await caches.match(request);
  if (cached) {
    return cached;
  }

  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE_NAME);
      cache.put(request, response.clone());
    }
    return response;
  } catch (err) {
    return new Response('离线', { status: 503 });
  }
}

// 网络优先策略
async function networkFirst(request) {
  try {
    const response = await fetch(request);
    return response;
  } catch (err) {
    const cached = await caches.match(request);
    if (cached) {
      return cached;
    }
    return new Response('离线', { status: 503 });
  }
}
