#!/usr/bin/env bash
# Ataques contra o servidor do AnythingLLM Desktop (porta $1).
P="$1"; B="http://127.0.0.1:$P/api"
CHROME='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
ELECTRON='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) AnythingLLM/1.16.1 Chrome/138.0.0.0 Electron/37.2.0 Safari/537.36'
code() { curl -s -o /dev/null -w "%{http_code}" -m 10 "$@"; }

echo "===== AnythingLLM (porta $P) ====="
echo "A1 escuta em: $(netstat -ano | grep LISTENING | grep ":$P " | awk '{print $2}' | sort -u | tr '\n' ' ')"

c=$(code -A "$CHROME" -H "Origin: https://site-malicioso.example" -H "Sec-Fetch-Site: cross-site" "$B/workspaces")
[ "$c" = "403" ] && echo "A2 site externo lê a lista de workspaces ........ BLOQUEOU (403)" || echo "A2 site externo lê a lista de workspaces ........ CEDEU ($c)"

c=$(code -A "$CHROME" -X POST -H "Origin: https://site-malicioso.example" -H "Content-Type: text/plain" --data '{"name":"invasor"}' "$B/workspace/new")
[ "$c" = "403" ] && echo "A3 site externo cria workspace (POST text/plain) BLOQUEOU (403)" || echo "A3 site externo cria workspace (POST text/plain) CEDEU ($c)"

c=$(code -A "$ELECTRON" -H "Host: site-malicioso.example:$P" "$B/ping")
[ "$c" = "403" ] && echo "A4 DNS rebinding (Host estranho) ................ BLOQUEOU (403)" || echo "A4 DNS rebinding (Host estranho) ................ CEDEU ($c)"

c=$(code -A "$ELECTRON" "$B/ping")
[ "$c" = "200" ] && echo "A5 o próprio app (Electron) usa /api/ping ....... FUNCIONA (200)" || echo "A5 o próprio app (Electron) usa /api/ping ....... QUEBROU ($c)"

acao=$(curl -s -D - -o /dev/null -m 10 -A "$ELECTRON" -H "Origin: https://site-malicioso.example" "$B/ping" | grep -i "^access-control-allow-origin" | tr -d '\r')
echo "A6 CONTROLE: com a marca do Electron o CORS original continua por baixo -> ${acao:-sem cabeçalho}"
