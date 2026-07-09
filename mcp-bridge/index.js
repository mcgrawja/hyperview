#!/usr/bin/env node
//
// Hyperview MCP bridge (§7.2).
//
// Claude Desktop launches this as a stdio MCP server; it proxies tools/list
// and tools/call to the running Hyperview app's token-gated localhost HTTP
// shim. The app must be running — it owns the data, the live IMAP
// connections, and the TCC permission grants.
//
// Configured via env (set in claude_desktop_config.json, which Hyperview's
// Claude tab generates): HYPERVIEW_PORT, HYPERVIEW_TOKEN.
//

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";

const PORT = process.env.HYPERVIEW_PORT || "48219";
const TOKEN = process.env.HYPERVIEW_TOKEN || "";
const BASE = `http://127.0.0.1:${PORT}`;

async function api(path, options = {}) {
  let response;
  try {
    response = await fetch(BASE + path, {
      ...options,
      headers: {
        "content-type": "application/json",
        "x-hyperview-token": TOKEN,
      },
    });
  } catch {
    throw new Error(
      "Hyperview isn't reachable. Open the Hyperview app and make sure the MCP server toggle (Claude tab) is on."
    );
  }
  if (response.status === 401) {
    throw new Error(
      "Hyperview rejected the token. Re-copy the configuration from Hyperview's Claude tab and restart Claude Desktop."
    );
  }
  return response.json();
}

const server = new Server(
  { name: "hyperview", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  const { tools } = await api("/tools");
  return { tools };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const result = await api("/call", {
    method: "POST",
    body: JSON.stringify({
      name: request.params.name,
      arguments: request.params.arguments || {},
    }),
  });
  return {
    content: [{ type: "text", text: result.ok ? result.content : result.error }],
    isError: !result.ok,
  };
});

await server.connect(new StdioServerTransport());
