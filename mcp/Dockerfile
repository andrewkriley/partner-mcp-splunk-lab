FROM node:20-alpine

# Build dependencies
RUN apk add --no-cache git

# Clone the official Splunk MCP server from source
# The published npm package exits immediately in SSE mode — the source repo works correctly
RUN git clone --depth=1 https://github.com/splunk/splunk-mcp-server2 /app

WORKDIR /app/typescript

# Install all dependencies (including devDependencies for ts-node)
RUN npm install

# Overlay the upstream server.ts with our local version (adds Streamable HTTP transport)
COPY server.ts /app/typescript/server.ts

EXPOSE 8050

# Start using ts-node (development mode — avoids build step complexity)
CMD ["npx", "ts-node", "server.ts"]
