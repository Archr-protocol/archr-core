# syntax=docker/dockerfile:1
FROM node:22-slim
WORKDIR /app
# Install ALL deps (tsx/typescript are devDependencies but needed at runtime),
# then switch to production mode for the running process.
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
ENV NODE_ENV=production
# Liveness. Every COMPLETED tick touches the heartbeat file; a tick that threw
# leaves it stale, which is what should be seen. Keeper liveness bounds the
# pending reward pot, so a wedged keeper has to be distinguishable from a
# working one.
# Interval is deliberately ~3x the default INTERVAL_MS so a slow tick is not
# flagged; adjust both together.
HEALTHCHECK --interval=60s --timeout=5s --start-period=90s --retries=3 \
  CMD node -e "const{statSync}=require('fs');const f=process.env.HEARTBEAT_FILE||'/tmp/keeper-heartbeat';const age=Date.now()-statSync(f).mtimeMs;if(age>Number(process.env.HEARTBEAT_MAX_AGE_MS||180000)){console.error('stale heartbeat: '+age+'ms');process.exit(1)}" || exit 1
CMD ["npm", "run", "start"]
