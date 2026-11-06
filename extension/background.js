import { DEFAULT_CONFIG, isCapturableUrl, sendToApp } from "./lib.js";

const MENU_ID = "dm-download-link";

async function getConfig() {
  return { ...DEFAULT_CONFIG, ...(await chrome.storage.local.get(DEFAULT_CONFIG)) };
}

chrome.runtime.onInstalled.addListener((details) => {
  chrome.contextMenus.create({
    id: MENU_ID,
    title: "İndirme Yöneticisi ile indir",
    contexts: ["link", "image", "video", "audio"],
  });
  if (details.reason === "install") chrome.runtime.openOptionsPage();
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId !== MENU_ID) return;
  const url = info.linkUrl || info.srcUrl;
  const sent = await sendToApp(await getConfig(), {
    url,
    referer: info.pageUrl || tab?.url,
  });
  if (!sent) await showBadge("!");
});

// Tarayıcının başlattığı indirmeyi uygulamaya devreder. Önce uygulamaya gönderilir,
// yalnızca kabul edilirse tarayıcıdaki iptal edilir: uygulama kapalıysa indirme kaybolmaz.
chrome.downloads.onCreated.addListener(async (item) => {
  const config = await getConfig();
  if (!config.intercept || !config.token) return;
  const url = item.finalUrl || item.url;
  if (!isCapturableUrl(url) || item.state !== "in_progress") return;

  const sent = await sendToApp(config, { url, referer: item.referrer });
  if (!sent) return;
  try {
    await chrome.downloads.cancel(item.id);
    await chrome.downloads.erase({ id: item.id });
  } catch (error) {
    // Dosya çok küçükse indirme zaten bitmiş olabilir; ikisi de zararsız kalır.
    console.warn("Tarayıcı indirmesi iptal edilemedi", error);
  }
});

async function showBadge(text) {
  await chrome.action.setBadgeBackgroundColor({ color: "#B3261E" });
  await chrome.action.setBadgeText({ text });
  setTimeout(() => chrome.action.setBadgeText({ text: "" }), 4000);
}
