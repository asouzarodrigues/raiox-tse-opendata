# Plano: migrar `nome_foto` do MySQL legado pro Postgres

Status: **resolvido sem migração** (2026-09-10). O acesso ao MySQL foi liberado (usuário
criou um usuário dedicado, `raiox_migracao`, credenciais em `.env` na raiz do
workspace) e usado pra rodar a Fase 1 (descoberta) — mas o resultado da Fase 1 foi
"não precisa de Fase 2/3": o nome do arquivo é **dedutível algoritmicamente** a partir
de dados que o Postgres novo já tem, sem importar nada do MySQL. Implementado em
`raiox-votos-node/src/lib/fotos.ts` + `app-sgdi-gabinete-online/src/app/shared/utils/foto-fallback.ts`
(ver JOURNAL.md dos dois repos, 2026-09-10). Esta seção documenta a descoberta que
fechou o plano; as fases 2-3 abaixo ficam registradas como o caminho que **não** foi
necessário, não como pendência.

## O problema

`raiox.tse_candidatos.nome_foto` no Postgres está `NULL` pra 100% dos candidatos —
achado e documentado em `raiox-votos-node/docs/decisions/JOURNAL.md` (2026-08-25). Causa:
`raiox-tse-opendata/sql/20_transform.sql:410` grava `NULL::varchar AS nome_foto` de
propósito, porque o dataset público do TSE (fonte do pipeline novo) não inclui nome de
arquivo de foto — nunca incluiu.

No sistema legado (MySQL, `raiox-api`), a mesma tabela `tse_candidatos` tem essa coluna
**preenchida**, alimentada por um processo antigo que não existe mais. É esse dado que
precisa migrar.

## O que já descobri (sem precisar do MySQL)

**Conexão MySQL** (`raiox-api/configs/<UF>.php` + `configTec.php`):
- Host real: `177.73.235.209` (as configs per-UF dizem `localhost` porque o PHP roda
  *nesse mesmo* servidor — de fora, é preciso o IP).
- 1 banco por estado: `gabineteonline1_<uf-minúsculo>` (ex.: `gabineteonline1_sp`).
- Usuário = nome do banco (`gabineteonline1_sp` também é o `db_user` de SP).
- Senha **igual pra todos os estados**: `Cp23@xxhugovai`.
- Testei conexão com AC agora (deste ambiente) — `ETIMEDOUT`, mesmo bloqueio de IP que
  o usuário mencionou. Confirma o problema, não é só no lado dele.

**Schema e uso real** (`raiox-api/Models/Votos.php`):
- Tabela: `tse_candidatos` — **mesmo nome** no MySQL e no Postgres.
- Chave de casamento entre os dois bancos: `(uf, sq_candidato, ano_eleicao)` — inferida
  do INSERT do pipeline novo (`20_transform.sql:385-419`, mesma chave usada lá) e das
  queries do PHP legado (sempre filtra por `sq_candidato` + `ano_eleicao`). Vale
  confirmar com 1-2 candidatos reais assim que o MySQL estiver acessível — `num_turno`
  pode precisar entrar na chave também (candidato de 2º turno tem 2 linhas na tabela).
- URL final da foto, montada em produção (`Votos.php:701`):
  ```
  https://www.gabineteonline1.com.br/cdn/gabinete-online/img/parlamentares/<UF>/<ano_eleicao>/<nome_foto>
  ```
  Ou seja, `nome_foto` é só o **nome do arquivo** (ex.: algo como `FSP<sq_candidato>_div.jpg`,
  citado no JOURNAL de 25/08) — a foto em si mora nesse CDN, não no banco.
- Fallback conhecido: quando `nome_foto` é vazio, o app usa
  `https://www.gabineteonline1.com.br/cdn/gabinete-online/img/sem_foto.png`.

**CDN legado**: testei agora — `sem_foto.png` responde **HTTP 200**. O domínio está de
pé. Não testei um arquivo de foto real (preciso de um `nome_foto` de verdade pra isso,
só vem do MySQL) — é o primeiro teste a fazer amanhã.

## Fonte alternativa: fotos oficiais do TSE (2026-09-10)

Durante o discovery da apuração 2026 (`app-sgdi-gabinete-online/docs/plans/apuracao-2026-tse-tempo-real.md`)
achei que `resultados.tse.jus.br` publica fotos oficiais em
`.../ele{ANO}/{idEleicao}/fotos/{uf}/{sq_candidato}.jpeg` — mesma chave `sq_candidato`
que já existe no Postgres. Testei se esse padrão vale "pra todos os anos" (pergunta
original) antes de mexer neste plano. Resultado: **não vale de forma uniforme** — dá
pra usar, mas só cobre uma fatia do problema que este plano resolve.

**O que confirmei com dado real:**
- **2024 funciona de ponta a ponta.** Peguei `sqcand` reais de candidatos a prefeito de
  SP (Ricardo Nunes `250002098117`, Guilherme Boulos `250001926547`, etc. — extraídos do
  `dados/sp/sp71072-c0011-e000619-u.json`, o mesmo arquivo já validado no discovery da
  apuração) e busquei a foto: `.../ele2024/619/fotos/sp/250001926547.jpeg` retornou um
  JPEG de verdade (~5,5KB, assinatura `JFIF` válida). Confirma o achado original do
  usuário, com prova.
- **2022 (o ano geral mais recente, o mais parecido com o que viria depois de 2024) já
  degrada.** Os arquivos de configuração "fixos" (`config/mun-e000544-cm.json`,
  `config/mun-e000546-cm.json`) ainda respondem (dado real, gerado em 02/10/2022) — mas
  **todo arquivo de resultado/candidatos que eu tentei pra governador ou presidente
  deu 404**: o padrão municipal (`dados/sp/sp71072-c0003-e000546-u.json`), o padrão
  agregado por UF/país achado num repositório de terceiros
  (`{eleicao}/{uf}/{uf}-c{cargo}-e{eleicao}-r.json`, testado com SP e com o exemplo
  literal do repo) — nenhum resolveu. Sem um arquivo de resultado vivo, não teve como
  extrair um `sq_candidato` real de 2022 pra testar a foto diretamente.
- **O próprio índice de eleições do TSE não lista nada antes de 2024.**
  `resultados.tse.jus.br/oficial/comum/config/ele-c.json` (o arquivo "mestre" que lista
  toda eleição conhecida do sistema) só tem entradas de 2024 em diante. Isso é sinal
  estrutural, não só uma URL individual quebrada: `resultados.tse.jus.br` parece ser a
  infra de apuração **ao vivo** de cada ciclo, não um arquivo histórico permanente — o
  que sobra de 2022 (os `config/` fixos) é resíduo, não uma garantia de retenção.
- **`divulgacandcontas.tse.jus.br`** (o portal de registro de candidatura/contas, que é
  conceitualmente o lugar certo pra uma foto "de cadastro" permanente, diferente do
  portal de apuração) tem o mesmo bloqueio de WAF que já documentei no discovery da
  apuração (`403` mesmo com user-agent de navegador) — não dá pra confirmar
  programaticamente se ele tem uma URL de foto estável por candidatura. Fica em aberto,
  só verificável manualmente.

**Implicação estrutural, independente do que eu consegui testar:** `sq_candidato` não é
uma identidade estável de pessoa — é por `(candidatura, ano_eleicao)`. O mesmo político
concorrendo em 2022 e 2024 tem dois `sq_candidato` diferentes. Então mesmo nos anos em
que o padrão funciona, "a mesma URL pra todos os anos" nunca significa reaproveitar um
identificador — significa, pra CADA linha de `tse_candidatos`, saber o `sq_candidato`
daquele ano (isso o Postgres já tem) **e** o `idEleicao` interno do TSE daquele ano
(isso **não existe** em lugar nenhum do schema hoje — nem no Postgres novo, nem no MySQL
legado; é um identificador específico do `resultados.tse.jus.br`, sem relação óbvia com
`cd_eleicao`/`cd_pleito` do dataset aberto do TSE). Os únicos valores de `idEleicao`
conhecidos até agora, todos achados manualmente nesta sessão: `619` (municipal 2024),
`544` (federal 2022) e `546` (estadual 2022) — não existe uma tabela ou fórmula pra
gerar os demais.

**Conclusão — isso reduz o escopo deste plano, não o substitui:**
- **Pra 2024 em diante (2026 incluído)**: dá pra usar a foto oficial do TSE direto,
  sem depender do MySQL nem de `nome_foto` nenhum — só precisa de um mapeamento pequeno
  e estático `ano_eleicao → idEleicao` (crescendo um valor por ciclo eleitoral, ~1 a cada
  2 anos), guardado onde for mais simples (constante no código, ou uma tabelinha de
  config). Isso pode até **tirar 2024 do escopo desta migração** — em vez de migrar
  `nome_foto` de 2024 do MySQL, o backend passa a montar a URL do TSE direto.
- **Pra anos anteriores a 2024 (o que este plano existe pra resolver)**: a fonte do TSE
  **não é confiável hoje** — 2022 já demonstrou falha nos arquivos de resultado, e não
  há como nem testar 2020/2018/2016/2014 sem primeiro descobrir o `idEleicao` de cada um
  (nenhum índice público lista isso). O plano de migração do MySQL abaixo continua sendo
  o caminho pra esses anos — não tem substituto identificado ainda.
- Recomendação prática: tratar como **duas fontes complementares**, não uma escolha
  única — TSE oficial pra ciclos correntes/futuros (custo quase zero, sem dependência do
  CDN legado nem do MySQL), migração do MySQL pra backfill histórico (o que este plano já
  cobre). Vale abrir esse "path TSE" como uma tarefa pequena e independente, sem esperar
  o acesso ao MySQL de amanhã — não tem relação de bloqueio entre as duas.

## Resolução: o nome do arquivo é dedutível (2026-09-10)

Com acesso liberado, varri as 28 bases MySQL de ponta a ponta (uma conexão por UF +
`gabineteonline1_br`, todas as linhas de `tse_candidatos` com `nome_foto` preenchido:
**1.821.385 linhas**). Objetivo: testar a hipótese do usuário — o nome segue
`UF+SQ_CANDIDATO+"_div.jpg"`? Resposta: **quase exatamente isso**, com 2 ajustes finos:

```
[F]<UF><sq_candidato>_div.<jpg|jpeg>
```

- **Prefixo "F"**: existe só a partir de `ano_eleicao >= 2016` — 2012 e 2014 nunca têm
  (confirmado por ano em todas as UFs testadas a fundo: AC, SP, BR). 14 linhas de 2016
  (RJ, RS, SE) saíram sem F mesmo assim — resíduo da transição naquele ano, sem
  problema real porque o fallback de extensão do app também serve de fallback pra isso
  (tenta a extensão alternativa, e se a URL "com F" 404, cai no placeholder de qualquer
  forma — não tentei uma 3ª variante sem F por não valer o esforço pra 14 linhas).
- **UF**: bate com a coluna `sigla_uf` da própria linha, não necessariamente com o
  banco onde a linha mora — candidato a presidente (`cd_cargo=1`) tem `sigla_uf='BR'`
  mesmo dentro do banco de cada estado (linha duplicada em todo banco de UF), e o nome
  do arquivo reflete isso (`FBR<sqcand>_div.jpg`). `candidatos.service.ts` já tratava
  esse caso (`ufFoto = cdCargo===1 ? 'BR' : estado`) — generalizado pros outros
  endpoints.

**Taxa de acerto da fórmula**: 1.821.381 / 1.821.385 = **99,9998%**. As 4 exceções são
dado corrompido no MySQL legado, não falha da fórmula: 2 linhas (BA, GO) têm o nome de
alguém vazado na extensão (`..._div.dilton urnajpg`), 1 (RO) tem o `sq_candidato` do
arquivo truncado em 1 dígito na base de 2012, 1 (SC) referencia o `sq_candidato` de
OUTRO candidato. Aceito como risco residual — não dá pra prever, e mesmo migrando o
dado real do MySQL essas 4 linhas continuariam sendo o valor (corrompido) que sempre
foram lá.

**O único dado genuinamente não dedutível: a extensão.** `jpg` vs `jpeg` sai misturado
mesmo dentro do mesmo UF/ano/candidato — ~89% `jpg` / ~11% `jpeg` no dataset inteiro,
sem correlação encontrada com nenhuma coluna (`ano_eleicao`, `cd_cargo`, nada). Isso já
era esperado pelo próprio comentário existente no app
(`apuracao.page.ts:180`, hardcoded como exemplo antes desta sessão) mostrar um `.jpg`,
mas o dataset real tem os dois. Resolvido com fallback client-side, não com dado
migrado: o backend sempre monta a URL assumindo `.jpg` (maioria), e o app tenta
`.jpeg` no `(error)` do `<img>` antes de cair no placeholder `sem_foto.png` que já
existia — cobre os ~11% sem precisar saber a extensão de antemão.

**Por que isso fecha o plano em vez de só reduzir o escopo dele**: mesmo se a Fase 2-3
abaixo rodasse e importasse `nome_foto` de verdade do MySQL, a ambiguidade de extensão
continuaria existindo no dado migrado (é assim que o legado já é) — ou seja, o
fallback client-side seria necessário de qualquer forma. Com isso, migrar o dado real
não compra nada que a fórmula + fallback já não resolvam, só custa mais (pipeline de
export/import, 27 bases, risco do "patch único vs. permanente" nunca resolvido abaixo).

## O que eu NÃO sabia antes de ter acesso (histórico — respondido acima)

- Quantas linhas de `tse_candidatos` por estado têm `nome_foto` preenchido — dá o volume
  real da migração.
- Se a chave `(uf, sq_candidato, ano_eleicao)` bate 100% entre os dois bancos, ou se há
  candidatos no MySQL sem correspondência no Postgres (datasets de origens diferentes —
  legado proprietário vs. TSE opendata oficial) e vice-versa.
- Se o padrão de nome de arquivo é uniforme entre estados/anos ou tem exceções.
- Se as fotos em si (os arquivos, não só o nome) ainda existem de verdade no CDN pra uma
  amostra ampla, ou só pros casos mais recentes.

## O plano original, em 3 fases (Fase 1 rodou; Fases 2-3 não foram necessárias)

### Fase 1 — Descoberta (rodou em 2026-09-10, ver seção "Resolução" acima)

1. Conectar em 2-3 estados (ex.: AC, SP, e um médio) e confirmar:
   - Schema exato de `tse_candidatos` (`DESCRIBE`/`SHOW COLUMNS`).
   - Contagem de linhas com `nome_foto` preenchido vs. vazio, por ano.
   - Confirmar a chave de casamento testando 3-5 candidatos reais contra o Postgres
     (`SELECT uf, sq_candidato, ano_eleicao, num_turno FROM raiox.tse_candidatos WHERE
     uf=... AND sq_candidato=...`).
2. Pegar 5-10 `nome_foto` reais e testar a URL do CDN pra cada um — confirma se os
   arquivos realmente existem, não só o nome no banco.
3. Com esses números, decidir se o volume é "rodar um script simples uma vez" (dezenas
   de milhares de linhas) ou "precisa de paginação/retry cuidadoso" (milhões).

### Fase 2 — Exportar do MySQL (por estado, 27x) — não executada, não necessária

Script (Node + `mysql2`, mesmo padrão já usado nesta sessão pra testar a conexão) que,
pra cada UF:
```sql
SELECT uf, sq_candidato, ano_eleicao, num_turno, nome_foto
  FROM tse_candidatos
 WHERE nome_foto IS NOT NULL AND nome_foto != ''
```
e grava um arquivo (CSV ou JSON) por estado. Roda da máquina/IP que tiver acesso
liberado — não precisa ser o mesmo lugar que depois faz a importação no Postgres, por
isso a exportação vira um artefato próprio (fica salvo, auditável, reaproveitável) em vez
de um pipe direto MySQL→Postgres.

Validação nesta fase: contagem exportada por UF bate com a contagem da Fase 1; nenhuma
linha com `sq_candidato`/`ano_eleicao` nulo.

### Fase 3 — Importar no Postgres — não executada, não necessária

Script que lê os arquivos da Fase 2 e faz `UPDATE raiox.tse_candidatos SET nome_foto =
... WHERE uf = ... AND sq_candidato = ... AND ano_eleicao = ... [AND num_turno = ...]` —
em lote (`COPY` pra tabela temporária + `UPDATE ... FROM`, mais eficiente que um UPDATE
por linha se o volume for grande; decidido depois de ver os números da Fase 1).

Validação: quantas linhas exportadas realmente bateram no Postgres (relatar as que não
bateram — esperado ter alguma divergência, datasets de origens diferentes, não é erro
necessariamente). Reaproveita o padrão de scripts de corretude já usado em
`raiox-votos-node/scripts/valida-*.mjs` nesta mesma sessão.

## Decisão em aberto (histórica) — resolvida por não precisar mais dela

**A migração é um patch único, ou precisa ser permanente no pipeline?** Ficou sem
objeto: `20_transform.sql` continua gravando `NULL` em `nome_foto` de propósito, e
está correto assim — o backend não lê mais essa coluna pra montar a foto (usa
`src/lib/fotos.ts`, formula-based). Nenhuma tabela de staging, nenhum step novo no
pipeline.

**O CDN legado (`gabineteonline1.com.br`) continua sendo infraestrutura fora do
controle do pipeline novo** — isso não mudou, só que agora nem o *nome* do arquivo
depende do MySQL, só a URL final (que sempre dependeu do CDN, migração ou não). Se a
intenção for ter fotos como algo confiável a longo prazo, independente do CDN legado,
baixar os arquivos de verdade e hospedar em storage próprio (ex.: Neon Object Storage)
continua sendo uma extensão possível — decisão de escopo separada, não bloqueada por
nada deste plano.

## Riscos (históricos — plano encerrado, ficam pra referência)

- ~~IP bloqueado pode continuar bloqueado~~ — resolvido, usuário criou credencial
  dedicada (`raiox_migracao`) pro acesso de leitura usado na Fase 1.
- Senha em texto puro nos arquivos `.php` de config do legado — continua existindo
  (não é problema deste plano criar ou resolver), mas deixou de ser relevante aqui:
  a credencial nova (`raiox_migracao`, em `.env`) foi usada só pra leitura pontual de
  descoberta, não fica embutida em nenhum script/serviço permanente.
- Volume/formato desconhecido até ter acesso — respondido: 1.821.385 linhas nas 28
  bases, formato uniforme o suficiente (99,9998%) pra não precisar de importação.
