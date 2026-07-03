const WS_URL = "ws://localhost:4001";

function setStatus(text) {
  document.getElementById("status").textContent = text;
}

function send(rawText, sourceHint, tabUrl) {
  if (!rawText || !rawText.trim()) {
    setStatus("nothing to capture");
    return;
  }

  setStatus("connecting to librarian...");
  const ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    const payload = {
      source: "chrome_ext",
      raw_text: rawText.trim().slice(0, 20000), // keep payloads sane
      hint_tags: [sourceHint],
      metadata: { tab_url: tabUrl || "" }
    };
    setStatus("sending " + payload.raw_text.length + " chars...");
    ws.send(JSON.stringify(payload));
  };

  ws.onmessage = (event) => {
    try {
      const resp = JSON.parse(event.data);
      if (resp.ok) {
        setStatus("captured -> bucket: " + resp.bucket);
      } else {
        setStatus("error: " + resp.error);
      }
    } catch (e) {
      setStatus("got unparseable response");
    }
    ws.close();
  };

  ws.onerror = () => {
    setStatus("could not reach librarian daemon on " + WS_URL + " — is it running?");
  };
}

async function getActiveTabInfo(selectionOnly) {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !tab.id) return { text: "", url: "" };

  const [{ result }] = await chrome.scripting.executeScript({
    target: { tabId: tab.id },
    func: (selectionOnly) => {
      if (selectionOnly) {
        const sel = window.getSelection();
        return sel ? sel.toString() : "";
      }
      return document.body ? document.body.innerText : "";
    },
    args: [selectionOnly]
  });

  return { text: result || "", url: tab.url || "" };
}

document.getElementById("captureSelection").addEventListener("click", async () => {
  setStatus("reading selection...");
  const { text, url } = await getActiveTabInfo(true);
  send(text, "selection", url);
});

document.getElementById("capturePage").addEventListener("click", async () => {
  setStatus("reading page...");
  const { text, url } = await getActiveTabInfo(false);
  send(text, "full_page", url);
});

document.getElementById("captureManual").addEventListener("click", () => {
  const text = document.getElementById("manual").value;
  send(text, "manual_paste", null);
});
