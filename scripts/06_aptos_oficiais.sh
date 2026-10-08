#!/usr/bin/env bash
# Gera data/aptos_munzona.csv: eleitorado apto OFICIAL do TSE por ano, turno,
# cargo, UF e município, a partir do detalhe_votacao_munzona de cada ano.
# Entrada de sql/43_fix_eleitorado.sql (ver lá o porquê).
#
# Uso: scripts/06_aptos_oficiais.sh [anos]   (default: 2012 2014 ... 2026)
#
# Baixe (01_download.sh ou à mão) e extraia antes:
#   https://cdn.tse.jus.br/estatistica/sead/odsele/detalhe_votacao_munzona/detalhe_votacao_munzona_<ano>.zip
#   -> data/raw/detalhe_votacao_munzona/<ano>/detalhe_votacao_munzona_<ano>_BRASIL.csv
# O _BRASIL.csv traz todas as UFs + ZZ e todos os cargos (o _BR.csv é só o
# recorte federal). Arquivo em latin1; o de 2014 tem fim de linha \r\n.
#
# Saída sem cabeçalho, separada por ';':
#   ano;nr_turno;cd_cargo;uf;cd_municipio;aptos;comparecimento
# Só eleição ordinária (CD_TIPO_ELEICAO = 2), mesma regra do 20_transform.sql.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

anos="${1:-2012 2014 2016 2018 2020 2022 2024 2026}"
out="data/aptos_munzona.csv"
: > "$out"

for ano in $anos; do
  csv="data/raw/detalhe_votacao_munzona/$ano/detalhe_votacao_munzona_${ano}_BRASIL.csv"
  if [ ! -f "$csv" ]; then
    echo "!! falta $csv — pulei $ano" >&2
    continue
  fi
  iconv -f latin1 -t utf-8 "$csv" | tr -d '\r' | awk -F';' -v OFS=';' '
    NR == 1 { for (i = 1; i <= NF; i++) { gsub(/"/, "", $i); c[$i] = i }; next }
    { for (i = 1; i <= NF; i++) gsub(/"/, "", $i) }
    $c["CD_TIPO_ELEICAO"] == 2 {
      k = $c["ANO_ELEICAO"] OFS $c["NR_TURNO"] OFS $c["CD_CARGO"] OFS $c["SG_UF"] OFS $c["CD_MUNICIPIO"]
      ap[k] += $c["QT_APTOS"]; cp[k] += $c["QT_COMPARECIMENTO"]
    }
    END { for (k in ap) print k, ap[k], cp[k] }' >> "$out"
  echo "$ano: $(grep -c "^$ano;" "$out") linhas"
done
echo "-> $out"
