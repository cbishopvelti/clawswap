// Listens to a smee.io channel, which relays the GitHub webhook to this machine (it has no public URL).
// smee.io serves the channel as Server-Sent Events: a "ready" event, "ping"s, and one plain message per
// delivery whose data is the request's headers with `body` and `query` added.
//
// The watcher only takes a delivery as a hint to look again: anyone who knows the channel URL can post to
// it, so nothing in the payload is acted on.

// Splits a chunk of an event stream into events, keeping an unfinished one for the next chunk.
export const parseEvents = (buffer) => {
  const events = [];
  const blocks = buffer.replace(/\r\n?/g, "\n").split("\n\n");
  const rest = blocks.pop();
  for (const block of blocks) {
    let event = "message";
    const data = [];
    for (const line of block.split("\n")) {
      if (!line || line.startsWith(":")) continue;
      const colon = line.indexOf(":");
      const field = colon === -1 ? line : line.slice(0, colon);
      const value = colon === -1 ? "" : line.slice(colon + 1).replace(/^ /, "");
      if (field === "event") event = value;
      else if (field === "data") data.push(value);
    }
    events.push({ event, data: data.join("\n") });
  }
  return { events, rest };
};

// The GitHub event a delivery carries ("push", "create", "pull_request"...), or undefined for anything else.
export const githubEvent = (data) => {
  try {
    const delivery = JSON.parse(data);
    return delivery["x-github-event"];
  } catch {
    return undefined;
  }
};

// Connects to the channel and calls onDelivery(githubEvent) for each delivery, onOpen() each time the stream
// (re)connects and onDrop(reason) when it's lost. Reconnects after an error, waiting longer each time up to a minute. Returns stop().
export const listen = (url, { onDelivery, onOpen = () => {}, onDrop = () => {}, log = () => {}, fetchImpl = fetch, setTimer = setTimeout }) => {
  let stopped = false;
  let controller;
  let delay = 1000;

  const connect = async () => {
    if (stopped) return;
    controller = new AbortController();
    try {
      const response = await fetchImpl(url, { headers: { Accept: "text/event-stream" }, signal: controller.signal });
      if (!response.ok || !response.body) throw new Error(`smee answered ${response.status}`);
      const decoder = new TextDecoder();
      let buffer = "";
      for await (const chunk of response.body) {
        buffer += decoder.decode(chunk, { stream: true });
        const { events, rest } = parseEvents(buffer);
        buffer = rest;
        for (const { event, data } of events) {
          if (event === "ready") {
            delay = 1000;
            log("Listening for GitHub webhooks on smee.io");
            onOpen();
          } else if (event === "message") {
            const kind = githubEvent(data);
            if (kind) onDelivery(kind);
          }
        }
      }
      throw new Error("smee closed the stream");
    } catch (error) {
      if (stopped) return;
      onDrop(error.message);
      log(`smee: ${error.message}; reconnecting in ${delay / 1000} s`);
      setTimer(connect, delay);
      delay = Math.min(delay * 2, 60_000);
    }
  };
  connect();

  return () => {
    stopped = true;
    controller?.abort();
  };
};

// A new channel URL: smee.io/new redirects to one.
export const newChannel = async (fetchImpl = fetch) => {
  const response = await fetchImpl("https://smee.io/new", { method: "HEAD", redirect: "manual" });
  const location = response.headers.get("location");
  if (!location) throw new Error(`smee.io didn't make a channel (${response.status})`);
  return new URL(location, "https://smee.io").toString();
};
