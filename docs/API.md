# Meteor v2 MCP API Documentation

## Overview

Meteor exposes `globalThis.MeteorMCP` in the perplexity extension's service worker, providing a clean async/await interface to the native `chrome.perplexity.mcp.*` APIs.

## API Reference

### `MeteorMCP.getServers()`

Get all configured MCP stdio servers.

**Returns:** `Promise<McpServer[]>`

```typescript
interface McpServer {
  name: string;
  command: string;
  args: string[];
  env: Record<string, string>;
  status: 'pending' | 'running' | 'stopped' | 'error';
}
```

**Example:**
```javascript
const servers = await MeteorMCP.getServers();
console.log(servers);
// [{ name: 'my-server', command: 'npx', args: ['-y', 'mcp-server'], env: {}, status: 'running' }]
```

---

### `MeteorMCP.addServer(name, command, args?, env?)`

Add a new stdio MCP server.

**Parameters:**
- `name` (string): Unique server identifier
- `command` (string): Command to execute (e.g., 'npx', 'python', 'node')
- `args` (string[], optional): Command arguments
- `env` (object, optional): Environment variables

**Returns:** `Promise<McpServer>`

**Example:**
```javascript
// Add an MCP server
const server = await MeteorMCP.addServer(
  'filesystem',
  'npx',
  ['-y', '@anthropic/mcp-server-filesystem', '/home/user'],
  { DEBUG: 'true' }
);
```

---

### `MeteorMCP.removeServer(name)`

Remove an MCP server by name.

**Parameters:**
- `name` (string): Server name to remove

**Returns:** `Promise<void>`

**Example:**
```javascript
await MeteorMCP.removeServer('filesystem');
```

---

### `MeteorMCP.getTools(serverName)`

Get available tools from an MCP server.

**Parameters:**
- `serverName` (string): Name of the MCP server

**Returns:** `Promise<McpTool[]>`

```typescript
interface McpTool {
  name: string;
  description: string;
  inputSchema: object;
}
```

**Example:**
```javascript
const tools = await MeteorMCP.getTools('filesystem');
console.log(tools);
// [{ name: 'read_file', description: 'Read file contents', inputSchema: {...} }, ...]
```

---

### `MeteorMCP.callTool(serverName, toolName, args)`

Call a tool on an MCP server.

**Parameters:**
- `serverName` (string): Name of the MCP server
- `toolName` (string): Name of the tool to call
- `args` (object): Tool arguments matching the input schema

**Returns:** `Promise<McpToolResult>`

```typescript
interface McpToolResult {
  content: Array<{ type: string; text?: string; data?: string }>;
  isError?: boolean;
}
```

**Example:**
```javascript
const result = await MeteorMCP.callTool('filesystem', 'read_file', {
  path: '/home/user/document.txt'
});
console.log(result.content[0].text);
```

---

## Usage Examples

### Setting Up a Complete MCP Server

```javascript
// 1. Add the server
await MeteorMCP.addServer(
  'code-assistant',
  'node',
  ['/path/to/mcp-server.js'],
  { NODE_ENV: 'production' }
);

// 2. Wait for server to initialize
await new Promise(resolve => setTimeout(resolve, 2000));

// 3. Get available tools
const tools = await MeteorMCP.getTools('code-assistant');
console.log('Available tools:', tools.map(t => t.name));

// 4. Call a tool
const result = await MeteorMCP.callTool('code-assistant', 'analyze_code', {
  code: 'function hello() { return "world"; }',
  language: 'javascript'
});

console.log('Analysis:', result.content);
```

### Listing All Servers and Their Status

```javascript
const servers = await MeteorMCP.getServers();

for (const server of servers) {
  console.log(`${server.name}: ${server.status}`);

  if (server.status === 'running') {
    const tools = await MeteorMCP.getTools(server.name);
    console.log(`  Tools: ${tools.map(t => t.name).join(', ')}`);
  }
}
```

### Error Handling

```javascript
try {
  await MeteorMCP.addServer('test', 'nonexistent-command', []);
} catch (error) {
  console.error('Failed to add server:', error.message);
}

try {
  const result = await MeteorMCP.callTool('server', 'tool', {});
  if (result.isError) {
    console.error('Tool returned error:', result.content);
  }
} catch (error) {
  console.error('Tool call failed:', error.message);
}
```

---

## Native API Access

For advanced use cases, you can access the native Chrome APIs directly in the service worker context:

```javascript
// Native APIs (callback-based)
chrome.perplexity.mcp.getStdioServers((servers) => { ... });
chrome.perplexity.mcp.addStdioServer(name, cmd, args, env, (server) => { ... });
chrome.perplexity.mcp.removeStdioServer(name, () => { ... });
chrome.perplexity.mcp.getTools(serverName, (tools) => { ... });
chrome.perplexity.mcp.callTool(serverName, toolName, args, (result) => { ... });
```

See [Perplexity Extension API](../../perplexity_extension_api.md) for complete API documentation.

---

## Feature Flags

Meteor force-enables the following MCP-related feature flags:

| Flag | Value | Effect |
|------|-------|--------|
| `comet-mcp-enabled` | `true` | Enables MCP server management UI |
| `custom-remote-mcps` | `true` | Enables remote HTTP/HTTPS MCP servers |
| `comet-dxt-enabled` | `true` | Enables Desktop Extension packages |

These are set by the feature flag interceptor (`content/feature-flags.js`) and cannot be disabled through the normal Eppo SDK.

---

## Debugging

### Check MeteorMCP Availability

```javascript
// In browser console (with extension context)
console.log(typeof MeteorMCP);
// Should output: 'object'

console.log(Object.keys(MeteorMCP));
// Should output: ['getServers', 'addServer', 'removeServer', 'getTools', 'callTool']
```

### View Feature Flags

```javascript
// In page context (perplexity.ai)
console.log(window.__meteorFeatureFlags?.getAll());
```
