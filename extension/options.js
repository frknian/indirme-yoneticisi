import { DEFAULT_CONFIG, STATUS_TEXT, isValidPort, pingApp } from "./lib.js";

const token = document.getElementById("token");
const port = document.getElementById("port");
const status = document.getElementById("status");

const config = await chrome.storage.local.get(DEFAULT_CONFIG);
token.value = config.token;
port.value = config.port;

document.getElementById("save").addEventListener("click", async () => {
  const portValue = Number(port.value);
  if (!isValidPort(portValue)) {
    status.textContent = "Port 1024 ile 65535 arasında olmalı";
    return;
  }
  const next = { token: token.value.trim(), port: portValue };
  await chrome.storage.local.set(next);
  status.textContent = STATUS_TEXT[await pingApp(next)];
});
