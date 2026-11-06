import { DEFAULT_CONFIG, STATUS_TEXT, pingApp } from "./lib.js";

const intercept = document.getElementById("intercept");
const status = document.getElementById("status");

const config = await chrome.storage.local.get(DEFAULT_CONFIG);
intercept.checked = config.intercept;
intercept.addEventListener("change", () =>
  chrome.storage.local.set({ intercept: intercept.checked }),
);
document.getElementById("options").addEventListener("click", () =>
  chrome.runtime.openOptionsPage(),
);
status.textContent = STATUS_TEXT[await pingApp(config)];
