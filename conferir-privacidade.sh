#!/usr/bin/env bash
# Trava de privacidade: roda ANTES de publicar. Sai com erro se achar dado pessoal nos arquivos
# que vao para o repositorio publico. Nasceu de um erro real: um "cp" do repositorio privado
# reintroduziu o nome do dono nos scripts ja limpos, e o commit foi publicado assim.
# Uso: bash conferir-privacidade.sh
set -u
padrao='artur|batissoco|crefito-?3|98808|turantunes|@gmail|capitaoxis|instituto ?lumie|vidativa|botucatu|sao manuel|C:\Users\[A-Za-z]+'
achados=$(grep -rniE "$padrao" pendrive/ *.md *.tsv *.ps1 2>/dev/null | grep -viE "crefito coren|<voce>" || true)
if [ -n "$achados" ]; then
  echo "PAROU: achei dado pessoal no que ia ser publicado:"
  echo "$achados" | head -20
  exit 1
fi
echo "OK: nada de dado pessoal nos arquivos publicos."
