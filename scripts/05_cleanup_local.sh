#!/usr/bin/env bash
# Limpa staging (raiox_tse_raw) e CSVs/zips brutos locais de um ano já
# promovido pra produção — passo final da cadeia 01 (download) -> 02 (load
# raw) -> 03 (transform local) -> 04 (promove) -> 05 (limpa). Só apaga
# depois de confirmar que a contagem local bate com a produção (mesma
# checagem do 04_promote.sh) — nunca apaga sem essa confirmação, e nunca
# para o script no meio (um ano que falhar a checagem é pulado, os outros
# continuam).
#
# Uso: scripts/05_cleanup_local.sh [ano ano ...]   (default: $ANOS do .env)
#
# O que limpa, por ano:
#  - staging (raiox_tse_raw): DROP das tabelas votacao_secao_<ano>,
#    consulta_cand_<ano>, eleitorado_locais_votacao_<ano> — schema
#    compartilhado entre UFs, não é dado permanente de propósito.
#  - CSVs/zips brutos locais desse ano: votacao_secao (por UF) e os
#    datasets nacionais (consulta_cand, eleitorado_locais_votacao,
#    votacao_partido_munzona). Os nacionais serão baixados de novo se você
#    processar outro estado no mesmo ano — com o CDN direto (ver
#    01_download.sh) isso é rápido agora, não vale manter em disco só por
#    isso.
#
# O que NÃO limpa: o schema final `raiox` local (tse_votacaosecao_<uf>_<ano>
# etc.) fica intacto de propósito — é o maior consumidor de disco (~7-9GB
# por ano de SP), mas mantê-lo local serve de conferência rápida sem
# depender de rede até você se sentir confortável. Se precisar do espaço
# extra depois de confirmar que está tudo certo em produção, é um
# TRUNCATE manual nas tabelas desse ano — não incluído aqui de propósito
# (mais um passo destrutivo do que faz sentido automatizar sem pedir).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
set -a; source .env; set +a
export PATH="/opt/homebrew/opt/libpq/bin:$PATH"

: "${PROD_DATABASE_URL:?defina PROD_DATABASE_URL no .env (connection DIRECT da produção real)}"

anos="${*:-$ANOS}"
echo "== Limpeza local pós-promoção: UF=$UF anos: $anos =="

for ano in $anos; do
  echo "-- ano=$ano --"
  leaf="tse_votacaosecao_${UF_LOWER}_${ano}"
  local_n=$(psql "$DATABASE_URL" -tA -c "SELECT count(*) FROM raiox.\"$leaf\";" 2>/dev/null || echo "")
  prod_n=$(psql "$PROD_DATABASE_URL" -tA -c "SELECT count(*) FROM raiox.\"$leaf\";" 2>/dev/null || echo "")

  if [[ -z "$local_n" || -z "$prod_n" || "$local_n" != "$prod_n" ]]; then
    echo "  PULADO: $leaf não bate (local=${local_n:-?} produção=${prod_n:-?}) — não confirmado como promovido, nada apagado."
    continue
  fi
  echo "  confirmado promovido: $leaf = $local_n linhas (local e produção batem)"

  echo "  limpando staging (raiox_tse_raw) do ano $ano"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c "
    DROP TABLE IF EXISTS raiox_tse_raw.\"votacao_secao_${ano}\";
    DROP TABLE IF EXISTS raiox_tse_raw.\"consulta_cand_${ano}\";
    DROP TABLE IF EXISTS raiox_tse_raw.\"eleitorado_locais_votacao_${ano}\";
  " >/dev/null

  echo "  apagando CSVs/zips brutos locais do ano $ano"
  rm -rf "data/raw/votacao_secao/${ano}"
  rm -rf "data/raw/consulta_cand/${ano}"
  rm -rf "data/raw/eleitorado_locais_votacao/${ano}"
  rm -rf "data/raw/votacao_partido_munzona/${ano}"

  echo "  OK: ano=$ano limpo (schema final em raiox continua intacto, local e produção)"
done

echo ""
echo "Feito. Espaço em disco agora:"
df -h /System/Volumes/Data 2>/dev/null || df -h /
