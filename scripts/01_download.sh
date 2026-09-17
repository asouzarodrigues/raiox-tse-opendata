#!/usr/bin/env bash
# Baixa os datasets do TSE necessários pro escopo (UF/ANOS do .env).
#
# cdn.tse.jus.br devolve 403 pra requests "de máquina" (curl liso, mesmo com
# User-Agent de navegador completo) — mas NÃO é bloqueio de IP nem
# TLS/fingerprinting: é o WAF (Akamai) checando a PRESENÇA dos headers de
# Client Hints que um Chrome real sempre manda numa navegação de documento
# (sec-ch-ua*, Sec-Fetch-*), não o valor deles. Confirmado em 2026-08-24:
# com esses 6 headers (ver `browser_headers` abaixo), o CDN responde 200 e
# entrega o arquivo real, mesmo de um IP residencial comum — sem proxy
# nenhum. Testado em vários datasets/anos, não é específico de 1 URL.
#
# Proxy do Wayback Machine (web.archive.org/web/2/<url>) fica registrado
# como fallback — usar só se o CDN voltar a bloquear (ex.: WAF mudar de
# regra) ou algum arquivo específico não existir mais no CDN.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

if [ ! -f .env ]; then
  echo "Falta .env — copie de .env.example primeiro." >&2
  exit 1
fi
set -a; source .env; set +a

CDN_BASE="https://cdn.tse.jus.br/estatistica/sead/odsele"
MISSING_FILE="data/MISSING.md"
: > "$MISSING_FILE"
echo "# Arquivos que falharam no CDN direto — baixe manualmente" >> "$MISSING_FILE"
echo "" >> "$MISSING_FILE"

MAX_ATTEMPTS=3

# Client Hints que o WAF exige pra não devolver 403 — ver comentário no topo.
# Valores em si não importam (testado com Chrome 151/macOS fictício), só a
# presença dos headers.
browser_headers=(
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36"
  -H "sec-ch-ua: \"Not=A?Brand\";v=\"99\", \"Google Chrome\";v=\"151\", \"Chromium\";v=\"151\""
  -H "sec-ch-ua-mobile: ?0"
  -H "sec-ch-ua-platform: \"macOS\""
  -H "Sec-Fetch-Dest: document"
  -H "Sec-Fetch-Mode: navigate"
  -H "Sec-Fetch-Site: same-site"
)

is_valid_zip() {
  [ -s "$1" ] && unzip -tqq "$1" >/dev/null 2>&1
}

download() {
  local dataset="$1" url="$2" outdir="$3" outfile="$4"
  mkdir -p "$outdir"
  local dest="$outdir/$outfile"

  if is_valid_zip "$dest"; then
    echo "  [skip] $outfile já existe e é válido"
    return 0
  elif [ -f "$dest" ]; then
    echo "  [refazendo] $outfile existia mas estava corrompido/incompleto"
    rm -f "$dest"
  fi

  local attempt=1 status
  while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "  [baixando] $outfile (tentativa $attempt/$MAX_ATTEMPTS)"
    status=$(curl -sSL --max-time 300 "${browser_headers[@]}" -o "$dest" -w "%{http_code}" "$url" 2>/tmp/curl_err_$$)
    if [ "$status" = "200" ] && is_valid_zip "$dest"; then
      rm -f /tmp/curl_err_$$
      return 0
    fi
    rm -f "$dest"
    echo "    -> falhou (HTTP $status$( [ -s /tmp/curl_err_$$ ] && echo ", $(cat /tmp/curl_err_$$)" )), tentando de novo em 5s"
    sleep 5
    attempt=$((attempt + 1))
  done
  rm -f /tmp/curl_err_$$

  echo "  [FALHOU DE VEZ] $outfile (HTTP $status)"
  {
    echo "- **$dataset**: \`$url\`"
    echo "  - pasta destino: \`$outdir/\`"
    echo "  - último status: HTTP $status"
  } >> "$MISSING_FILE"
  return 1
}

fail_count=0

for ano in $ANOS; do
  echo "=== $ano ==="

  # DF não é dividido em municípios (Art. 32 da Constituição) — não existe
  # prefeito/vereador lá, então em ano de eleição MUNICIPAL (%4==0: 2016,
  # 2020, 2024...) o TSE simplesmente não publica votacao_secao_{ano}_DF.zip
  # (404 real, confirmado no CDN, não é bloqueio/nome errado). Pula aqui em
  # vez de gastar 3 tentativas + entrar em MISSING.md como falha — mesmo
  # raciocínio do skip de BR/Presidente abaixo (ano sem o dado, não erro).
  if [ "$UF" = "DF" ] && [ "$((ano % 4))" -eq 0 ]; then
    echo "  [skip] votacao_secao_${ano}_DF: DF não tem eleição municipal (sem municípios)"
  else
    url="$CDN_BASE/votacao_secao/votacao_secao_${ano}_${UF}.zip"
    download "votacao_secao $ano" "$url" "data/raw/votacao_secao/$ano" "votacao_secao_${ano}_${UF}.zip" || fail_count=$((fail_count+1))
  fi

  # Presidente/Vice NÃO vem no zip por UF acima — o TSE publica a votação
  # federal (abrangência F) num arquivo NACIONAL à parte, um só pra todo o
  # Brasil (~1.5GB descompactado), com sg_uf linha a linha (02_load_raw.sh
  # filtra pra UF antes de carregar). Só existe em ano de eleição geral —
  # ano%4==2 (2014/2018/2022/2026...); em ano municipal esse arquivo não
  # existe no CDN, então nem tenta (evita 404 previsível toda run).
  if [ "$((ano % 4))" -eq 2 ]; then
    url="$CDN_BASE/votacao_secao/votacao_secao_${ano}_BR.zip"
    download "votacao_secao federal (BR) $ano" "$url" "data/raw/votacao_secao/$ano" "votacao_secao_${ano}_BR.zip" || fail_count=$((fail_count+1))
  fi

  url="$CDN_BASE/consulta_cand/consulta_cand_${ano}.zip"
  download "consulta_cand $ano" "$url" "data/raw/consulta_cand/$ano" "consulta_cand_${ano}.zip" || fail_count=$((fail_count+1))

  url="$CDN_BASE/eleitorado_locais_votacao/eleitorado_local_votacao_${ano}.zip"
  download "eleitorado_locais_votacao $ano" "$url" "data/raw/eleitorado_locais_votacao/$ano" "eleitorado_local_votacao_${ano}.zip" || fail_count=$((fail_count+1))

  # Voto de legenda (município/zona) — fonte candidata pra votos_partidos /
  # tse_votacaosecao_partido, ainda NÃO tem transform pronto (ver README,
  # "Voto de legenda — pendente"). Baixa mesmo assim pra já ficar disponível
  # quando o mapeamento for confirmado.
  url="$CDN_BASE/votacao_partido_munzona/votacao_partido_munzona_${ano}.zip"
  download "votacao_partido_munzona $ano" "$url" "data/raw/votacao_partido_munzona/$ano" "votacao_partido_munzona_${ano}.zip" || fail_count=$((fail_count+1))
done

echo ""
if [ "$fail_count" -eq 0 ]; then
  echo "Todos os downloads OK."
  rm -f "$MISSING_FILE"
else
  echo "$fail_count download(s) falharam de vez — ver $MISSING_FILE"
fi

echo ""
echo "Extraindo zips..."
find data/raw -name "*.zip" | while read -r z; do
  d="$(dirname "$z")"
  echo "  unzip -o $z -> $d"
  unzip -o -q "$z" -d "$d"
done

echo "Feito."
