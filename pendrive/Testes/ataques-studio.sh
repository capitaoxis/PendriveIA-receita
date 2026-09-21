#!/usr/bin/env bash
# Uso: ataques.sh <porta> <rotulo>
# Imprime, para cada ataque, se o servidor CEDEU ou BLOQUEOU.
P="$1"; L="$2"; B="http://127.0.0.1:$P"

code() { curl -s -o /dev/null -w "%{http_code}" --path-as-is "$@"; }

echo "===== $L (porta $P) ====="

# T1: leitura de arquivo fora da pasta (C:\Windows\win.ini)
body=$(curl -s --path-as-is "$B/../../../../../../../../Windows/win.ini")
if printf '%s' "$body" | grep -qi "for 16-bit app support\|\[fonts\]"; then
  echo "T1 ler C:\\Windows\\win.ini pela URL ......... CEDEU (arquivo do disco devolvido)"
else
  echo "T1 ler C:\\Windows\\win.ini pela URL ......... BLOQUEOU (resposta: $(printf '%s' "$body" | head -c 40 | tr -d '\r\n'))"
fi

# T1c: a mesma leitura mirando um arquivo da MESMA unidade. Rodando do pendrive, o ../../..
# sobe ate a raiz do pendrive, onde nao existe Windows/win.ini: sem este teste um servidor
# vulneravel apareceria como BLOQUEOU (falso verde).
body=$(curl -s --path-as-is "$B/../../../../../../../../LEIA-ME.md")
if printf '%s' "$body" | grep -q "^# PendriveIA"; then
  echo "T1c ler LEIA-ME.md da raiz pela URL ........ CEDEU (arquivo do disco devolvido)"
else
  echo "T1c ler LEIA-ME.md da raiz pela URL ........ BLOQUEOU"
fi

# T2: outro site lendo a API (Origin estranha)
h=$(curl -s -D - -o /dev/null -H "Origin: https://site-malicioso.example" -H "Sec-Fetch-Site: cross-site" "$B/api/health")
st=$(printf '%s' "$h" | head -1 | tr -d '\r')
acao=$(printf '%s' "$h" | grep -i "^access-control-allow-origin" | tr -d '\r')
if printf '%s' "$st" | grep -q " 200"; then
  echo "T2 site externo lê /api/health ............ CEDEU ($st; ${acao:-sem CORS})"
else
  echo "T2 site externo lê /api/health ............ BLOQUEOU ($st)"
fi

# T3: POST text/plain de outro site (sem preflight) em rota que age
c=$(code -X POST -H "Origin: https://site-malicioso.example" -H "Sec-Fetch-Site: cross-site" -H "Content-Type: text/plain" --data '{}' "$B/api/llm/stop")
[ "$c" = "403" ] && echo "T3 site externo dispara POST /api/llm/stop .. BLOQUEOU (403)" || echo "T3 site externo dispara POST /api/llm/stop .. CEDEU ($c)"

# T4: DNS rebinding (Host de outro domínio)
c=$(code -H "Host: site-malicioso.example:$P" "$B/api/health")
[ "$c" = "403" ] && echo "T4 DNS rebinding (Host estranho) ........... BLOQUEOU (403)" || echo "T4 DNS rebinding (Host estranho) ........... CEDEU ($c)"

# T5: uso legítimo pela própria interface (tem que continuar funcionando)
c=$(code -H "Origin: http://127.0.0.1:$P" -H "Sec-Fetch-Site: same-origin" "$B/api/health")
[ "$c" = "200" ] && echo "T5 própria interface usa /api/health ....... FUNCIONA (200)" || echo "T5 própria interface usa /api/health ....... QUEBROU ($c)"
c=$(code "$B/")
echo "T5b página inicial (navegação direta) ....... HTTP $c"

# T6: em que endereço a porta escuta
echo "T6 escuta em: $(netstat -ano | grep "LISTENING" | grep ":$P " | awk '{print $2}' | sort -u | tr '\n' ' ')"
