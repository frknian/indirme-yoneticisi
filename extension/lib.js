// Tarayıcı API'sine bağlı olmayan yardımcılar. Node testleri de bunları kullanır.

export const DEFAULT_PORT = 38765;

export const DEFAULT_CONFIG = Object.freeze({
  token: "",
  port: DEFAULT_PORT,
  intercept: true,
});

export function isCapturableUrl(url) {
  try {
    const { protocol } = new URL(url);
    return protocol === "http:" || protocol === "https:" || protocol === "magnet:";
  } catch {
    return false;
  }
}

export function isValidPort(port) {
  return Number.isInteger(port) && port >= 1024 && port <= 65535;
}

export function endpoint(config, path) {
  return `http://127.0.0.1:${config.port}${path}`;
}

/** Uygulamaya indirme gönderir. Başarıda true, aksi halde false döner; hata fırlatmaz. */
export async function sendToApp(config, { url, referer, fileName }, fetchImpl = fetch) {
  if (!config.token || !isCapturableUrl(url)) return false;
  try {
    const response = await fetchImpl(endpoint(config, "/download"), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-DM-Token": config.token,
      },
      body: JSON.stringify({
        url,
        referer: isCapturableUrl(referer) ? referer : undefined,
        fileName: fileName || undefined,
      }),
    });
    return response.status === 202;
  } catch {
    return false; // Uygulama kapalı: indirme tarayıcıda devam etmeli.
  }
}

/** Bağlantı durumu: "ok", "bad_token", "offline" veya "no_token". */
export async function pingApp(config, fetchImpl = fetch) {
  if (!config.token) return "no_token";
  try {
    const response = await fetchImpl(endpoint(config, "/ping"), {
      headers: { "X-DM-Token": config.token },
    });
    if (response.status === 200) return "ok";
    if (response.status === 401) return "bad_token";
    return "offline";
  } catch {
    return "offline";
  }
}

export const STATUS_TEXT = Object.freeze({
  ok: "Uygulamaya bağlı",
  bad_token: "Anahtar yanlış. Ayarlardan düzeltin.",
  offline: "Uygulama kapalı veya port yanlış",
  no_token: "Önce eşleştirme anahtarını girin",
});
