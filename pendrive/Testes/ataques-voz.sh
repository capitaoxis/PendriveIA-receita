#!/usr/bin/env bash
# Uso: bash ataques-voz.sh [porta, padrão 10091]
# Ataques contra o servidor de voz do AnythingLLM (AnythingLLM/pendrive/voz.py: fala e microfone), com
# controle: o mesmo pedido com a chave certa precisa FUNCIONAR, senão o teste não prova nada.
# A chave é lida do arquivo do pendrive e vai por arquivo de cabeçalho (não aparece na linha de comando).
set -u
PORTA="${1:-10091}"
B="http://127.0.0.1:$PORTA"
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
printf 'Authorization: Bearer %s\n' "$(tr -d '\r\n' < "$RAIZ/AnythingLLM/dados/llm-api-key.txt")" > "$TMP/chave.txt"
# JSON em arquivo UTF-8: texto com acento pela linha de comando do Git Bash sai em cp1252.
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({model:"piper",voice:"faber",input:"Bom dia. Hoje vamos fazer exercícios de equilíbrio."}))' "$TMP/fala.json"

pedido() { curl -s -o "$TMP/r" -w "%{http_code}" "$@"; }
veredito() { # nome, código, esperado_bloqueio(1)/esperado_funcionar(0)
  if [ "$3" = 1 ]; then
    case "$2" in 401|403|404|413) echo "$1: BLOQUEOU ($2)";; *) echo "$1: CEDEU ($2)  <-- FALHA";; esac
  else
    if [ "$2" = 200 ] && [ "$(head -c4 "$TMP/r")" = "RIFF" ]; then echo "$1: FUNCIONA ($2, WAV)"; else echo "$1: NAO FUNCIONOU ($2)  <-- FALHA"; fi
  fi
}

veredito "V1 sem chave"                "$(pedido -X POST "$B/v1/audio/speech" --data-binary @"$TMP/fala.json")" 1
veredito "V2 chave errada"             "$(pedido -X POST "$B/v1/audio/speech" -H 'Authorization: Bearer 0123456789abcdef0123456789abcdef' --data-binary @"$TMP/fala.json")" 1
veredito "V3 site aberto no navegador" "$(pedido -X POST "$B/v1/audio/speech" -H @"$TMP/chave.txt" -H 'Origin: https://site-malicioso.example' --data-binary @"$TMP/fala.json")" 1
veredito "V4 DNS rebinding"            "$(pedido -X POST "$B/v1/audio/speech" -H @"$TMP/chave.txt" -H "Host: site-malicioso.example:$PORTA" --data-binary @"$TMP/fala.json")" 1
head -c 2000000 /dev/zero | tr '\0' a > "$TMP/grande"
veredito "V5 corpo de 2 MB"            "$(pedido -X POST "$B/v1/audio/speech" -H @"$TMP/chave.txt" --data-binary @"$TMP/grande")" 1
veredito "V6 uso legítimo (controle)"  "$(pedido -X POST "$B/v1/audio/speech" -H @"$TMP/chave.txt" --data-binary @"$TMP/fala.json")" 0
# Microfone: reaproveita o WAV que acabou de ser falado (V6) como gravação.
cp "$TMP/r" "$TMP/gravacao.wav"
veredito "V8 microfone sem chave"        "$(pedido -X POST "$B/v1/audio/transcriptions" -F model=x -F file=@"$TMP/gravacao.wav")" 1
veredito "V9 microfone de site aberto"   "$(pedido -X POST "$B/v1/audio/transcriptions" -H @"$TMP/chave.txt" -H 'Origin: https://site-malicioso.example' -F model=x -F file=@"$TMP/gravacao.wav")" 1
codigo="$(pedido -X POST "$B/v1/audio/transcriptions" -H @"$TMP/chave.txt" -F model=x -F file=@"$TMP/gravacao.wav")"
if [ "$codigo" = 200 ] && grep -qi "equil" "$TMP/r"; then echo "V10 microfone legítimo (controle): FUNCIONA ($codigo, $(cat "$TMP/r"))"; else echo "V10 microfone legítimo (controle): NAO FUNCIONOU ($codigo $(head -c 200 "$TMP/r"))  <-- FALHA"; fi
escutando="$(netstat -ano | grep LISTENING | grep -E ":$PORTA\b")"
if [ -z "$escutando" ]; then
  echo "V7 porta: nada escutando na $PORTA  <-- FALHA"
elif echo "$escutando" | grep -vq "127.0.0.1:$PORTA"; then
  echo "V7 porta: ABERTA ALÉM DE 127.0.0.1  <-- FALHA"
else
  echo "V7 porta: só em 127.0.0.1"
fi
