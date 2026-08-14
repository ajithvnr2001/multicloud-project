# Stage 1: Build & Package Dependencies
FROM node:20-alpine AS builder
WORKDIR /usr/src/app

COPY package*.json ./
RUN npm ci --only=production

# Stage 2: Runtime Release
FROM node:20-alpine
WORKDIR /usr/src/app

# Security Hardening: Upgrade OS libraries
RUN apk update && apk upgrade --no-cache

# Run as non-root user
USER node

# Copy dependencies and source code from Stage 1 builder
COPY --chown=node:node --from=builder /usr/src/app/node_modules ./node_modules
COPY --chown=node:node . .

# Set environment variables
ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
  CMD node -e "fetch('http://localhost:8080/health').then(r => r.ok ? process.exit(0) : process.exit(1)).catch(() => process.exit(1))"

CMD ["node", "server.js"]
