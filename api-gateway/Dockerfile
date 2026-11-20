# Construa a partir da raiz do projeto: docker build -f api-gateway/Dockerfile -t geponto-api .
FROM node:20-alpine
WORKDIR /app
COPY api-gateway/server.mjs ./server.mjs
COPY docs/api/openapi.yaml ./openapi.yaml
ENV PORT=8080
EXPOSE 8080
USER node
CMD ["node", "server.mjs"]
