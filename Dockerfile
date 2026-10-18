FROM node:24-alpine AS web
WORKDIR /app/web
COPY web/package*.json ./
RUN npm ci
COPY web/ ./
RUN npm run build

FROM node:24-alpine
ENV NODE_ENV=production HOUSE_DATA_DIR=/data PORT=8080
WORKDIR /app
COPY --from=web /app/web/dist ./web/dist
COPY web/public/plans ./web/public/plans
COPY web/src/config.js ./web/src/config.js
COPY server/ ./server/
RUN mkdir /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s CMD node -e "fetch('http://127.0.0.1:8080/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server/src.js"]
