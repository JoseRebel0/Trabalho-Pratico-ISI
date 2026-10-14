# Guia Pentaho (Elemento A) — APIs IPMA + Qualidade do Ar

Este guia explica, passo a passo, como construir no **Spoon** (Pentaho Data Integration) as transformações e o job da Parte A.
As transformações são montadas por vocês no Spoon, de propósito: na defesa individual têm de saber explicar cada passo. Guardem os ficheiros em `pentaho/transformacoes/*.ktr` e `pentaho/jobs/*.kjb`.

> Convenção: **[Passo]** = nome do passo no Spoon (painel *Design*, usem a pesquisa no topo).

---

## 0. Preparação

1. **Java** — instalem a versão de Java pedida pela vossa versão do PDI (PDI 9.x → Java 11; PDI 10.x → Java 17/21). Confirmem com `java -version`.
2. **PDI** — descomprimam e arranquem com `./spoon.sh` (Mac/Linux) ou `Spoon.bat` (Windows).
3. **Infraestrutura** — na pasta do projeto: `docker compose up -d` (Postgres, Mosquitto, Grafana, Mailpit, SFTP).
4. **Testar as APIs** — `python3 scripts/testar_apis.py` (deve dizer OK em todas).

### 0.1 Ligação à base de dados (uma vez)
*View → Database connections → New*:

| Campo | Valor |
|---|---|
| Connection name | `ambiente` |
| Type | PostgreSQL (Native JDBC) |
| Host / Port | `localhost` / `5432` |
| Database | `ambiente` |
| User / Password | `isi` / `isi2026` |

Botão **Test** → OK. Depois botão direito na ligação → **Share** (fica disponível em todas as transformações).

### 0.2 Parâmetro com a pasta do projeto
Em cada transformação e no job: *Edit → Settings → Parameters* → `PROJ_DIR` = caminho da pasta do projeto (ex.: `/Users/joe/isi-tp1-ambiente`).
Todos os caminhos de ficheiros usam `${PROJ_DIR}/...`.

---

## T0 — `T0_config.ktr` · Ler configuração YAML

Objetivo: ler `config/config.yaml` e transformar os limites em **variáveis** usadas pelas outras transformações (formato YAML ✔).

```
[YAML Input] → [Select values] → [Set Variables]
```

1. **[YAML Input]**
   - File: `${PROJ_DIR}/config/config.yaml`
   - Separador *Fields* → **Get fields**. Ficam campos como `limites/pm10_diario`, `limites/temperatura_max`, etc.
2. **[Select values]** — renomear para nomes simples: `pm10_diario`, `pm2_5_diario`, `nivel_aviso_alerta`, `smtp_servidor`, `smtp_porta`, `destinatario`…
3. **[Set Variables]** — *Get fields*; *Variable scope type* = **Valid in the root job**. Ex.: `pm10_diario` → `PM10_LIMITE`, `nivel_aviso_alerta` → `NIVEL_ALERTA`, `smtp_servidor` → `SMTP_HOST`, `smtp_porta` → `SMTP_PORT`.

> Na defesa: "a configuração está fora do código; mudar o limite não obriga a mexer no ETL."

---

## T1 — `T1_dimensoes.ktr` · Locais (XML) + lookups do IPMA (JSON)

Três fluxos independentes na mesma transformação.

### (a) Locais — XML → `dim_local`
```
[Get data from XML] → [Regex Evaluation] →(válidos)→ [Insert / Update: dim_local]
                                         →(inválidos)→ [Table output: etl_rejeitado]
```
1. **[Get data from XML]**
   - File: `${PROJ_DIR}/config/locais.xml`
   - Content → Loop XPath: `/monitorizacao/locais/local`
   - Fields (Get fields ou à mão):

     | Name | XPath | Type |
     |---|---|---|
     | global_id_local | `@globalIdLocal` | String |
     | id_area_aviso | `@idAreaAviso` | String |
     | fonte_previsao | `@fontePrevisao` | String |
     | nome | `nome` | String |
     | distrito | `distrito` | String |
     | latitude | `latitude` | Number |
     | longitude | `longitude` | Number |
2. **[Regex Evaluation]** (validação com ER ✔)
   - Field to evaluate: `global_id_local`; Result field: `id_valido`
   - Regex: `^(\d{7})?$` (7 dígitos **ou vazio** — Barcelos não tem código IPMA)
   - Um segundo **[Regex Evaluation]** para `id_area_aviso` com `^[A-Z]{3}$` → `area_valida`.
3. **[Filter rows]** `id_valido = Y AND area_valida = Y` → *true* para **[Insert / Update]**, *false* para **[Table output]**.
4. **[If field value is null]** / **[Null if]** — `global_id_local` vazio → null. Depois **[Select values]** (*Meta-data*): `global_id_local` → Integer.
5. **[Insert / Update]** — tabela `dim_local`; *Key*: `nome = nome`; *Update fields*: global_id_local, fonte_previsao, distrito, id_area_aviso, latitude, longitude.
6. Ramo inválido: **[Add constants]** `processo = T1_dimensoes`, `motivo = codigo IPMA invalido` → **[Concat fields]** (junta tudo em `dados`) → **[Table output]** `etl_rejeitado`.

### (b) Estados do tempo — REST → `dim_estado_tempo`
```
[Generate rows] → [REST Client] → [JSON Input] → [Filter rows] → [Insert / Update]
```
1. **[Generate rows]** — 1 linha, campo `url` (String) = `https://api.ipma.pt/open-data/weather-type-classe.json`
2. **[REST Client]** — *Accept URL from field* ✔ → `url`; Method GET; *Result fieldname* `json`; *HTTP status code fieldname* `http_status`.
3. **[JSON Input]** — separador *File*: ✔ *Source is defined in a field* → `json`.
   Fields:

   | Name | Path | Type |
   |---|---|---|
   | id_weather_type | `$.data[*].idWeatherType` | Integer |
   | descricao_pt | `$.data[*].descWeatherTypePT` | String |
   | descricao_en | `$.data[*].descWeatherTypeEN` | String |
4. **[Filter rows]** `id_weather_type > -99` (o IPMA usa **-99** como "sem valor").
5. **[Insert / Update]** `dim_estado_tempo`, chave `id_weather_type`.

### (c) Classes de vento — igual a (b)
URL: `https://api.ipma.pt/open-data/wind-speed-daily-classe.json`

| Name | Path | Type |
|---|---|---|
| classe | `$.data[*].classWindSpeed` | Integer |
| descricao_pt | `$.data[*].descClassWindSpeedDailyPT` | String |
| descricao_en | `$.data[*].descClassWindSpeedDailyEN` | String |

→ filtrar `classe > -99` → **[Insert / Update]** `dim_classe_vento`.

---

## T2 — `T2_previsoes_ipma.ktr` · Previsão diária IPMA (JSON) → `fact_previsao`

Uma chamada à API **por local** (os locais vêm da BD): Braga, Porto e Lisboa. Barcelos não existe no IPMA e é tratado na T2b.

```
[Table input: dim_local] → [User Defined Java Expression: url] → [REST Client]
   → [Filter rows: http_status = 200] → [JSON Input] → [Regex Evaluation: data válida?]
   → [Replace in string: dataUpdate] → [Null if: -99] → [Select values: tipos]
   → [Calculator: amplitude] → [Sort rows] → [Unique rows] → [Insert / Update: fact_previsao]
```

1. **[Table input]** (ligação `ambiente`):
   ```sql
   SELECT id_local, global_id_local, nome FROM dim_local
   WHERE fonte_previsao = 'IPMA' ORDER BY id_local
   ```
2. **[User Defined Java Expression]** — novo campo `url` (String):
   ```java
   "https://api.ipma.pt/open-data/forecast/meteorology/cities/daily/" + global_id_local + ".json"
   ```
3. **[REST Client]** — URL from field `url`; result `json`; status `http_status`.
4. **[Filter rows]** `http_status = 200`. *False* → **[Write to log]** ("API IPMA falhou para ${nome}") e **[Table output]** `etl_rejeitado`.
5. **[JSON Input]** — source from field `json`. Fields (todos String de início — vêm como texto na API):

   | Name | Path |
   |---|---|
   | data_previsao | `$.data[*].forecastDate` |
   | t_min | `$.data[*].tMin` |
   | t_max | `$.data[*].tMax` |
   | prob_precipitacao | `$.data[*].precipitaProb` |
   | dir_vento | `$.data[*].predWindDir` |
   | classe_vento | `$.data[*].classWindSpeed` |
   | id_weather_type | `$.data[*].idWeatherType` |
   | data_atualizacao | `$.dataUpdate` |

   Os campos de entrada (`id_local`, `nome`) continuam na linha. Se a vossa versão não os passar, voltem a juntá-los com **[Stream lookup]** por `global_id_local` (aproveitem e expliquem isso na defesa como *lookup*).
   > Nota: `$.dataUpdate` devolve 1 valor e as outras paths 5. Se o JSON Input se queixar, extraiam `dataUpdate` num segundo JSON Input e juntem com **[Join rows (cartesian product)]**.
6. **[Regex Evaluation]** em `data_previsao`, regex `^\d{4}-\d{2}-\d{2}$` → `data_ok`. **[Filter rows]** `data_ok = Y`; inválidos → `etl_rejeitado`.
7. **[Replace in string]** (ER ✔) — campo `data_atualizacao`, ✔ *use RegEx*:
   - Search: `^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})$`  Replace with: `$1 $2`
   - Campo `dir_vento`: search `\s+` replace `` (vazio) + *Set empty string?* N; e converter para maiúsculas com **[String operations]** (*Lower/Upper* = upper).
8. **[Null if]** — `t_min`, `t_max`, `prob_precipitacao` com valor `-99.0`; `classe_vento`, `id_weather_type` com `-99`.
9. **[Select values]** → *Meta-data*:

   | Field | Type | Format |
   |---|---|---|
   | data_previsao | Date | `yyyy-MM-dd` |
   | data_atualizacao | Timestamp | `yyyy-MM-dd HH:mm:ss` |
   | t_min, t_max, prob_precipitacao | Number | `#.#` (*Decimal* = `.`) |
   | classe_vento, id_weather_type | Integer | |

   ⚠️ Mac em português usa vírgula decimal: definam *Decimal* = `.` e *Grouping* vazio para não ler `13.0` como 130.
10. **[Calculator]** — `amplitude_termica` = `t_max` **A - B** `t_min` (Number).
11. **[Sort rows]** por `id_local, data_previsao, data_atualizacao` → **[Unique rows]** com os mesmos campos (remoção de duplicados ✔ — corre o job duas vezes seguidas e mostra que não duplica).
12. **[Add constants]** `fonte` = `IPMA`.
13. **[Insert / Update]** `fact_previsao`:
    - Keys: `id_local`, `data_previsao`, `data_atualizacao`
    - Update: `fonte, t_min, t_max, amplitude_termica, prob_precipitacao, dir_vento, classe_vento, id_weather_type`

---

## T2b — `T2b_previsao_openmeteo.ktr` · Previsão de Barcelos (Open-Meteo) → `fact_previsao`

Barcelos não está na lista do IPMA, por isso a previsão vem de outra API com **outro formato** (arrays diários, vento em km/h e graus, códigos WMO). O trabalho aqui é **mapear este schema para o mesmo formato do IPMA** e juntar tudo na mesma tabela — bom exemplo de *merge* de fontes e *reestruturação de schemas* para o relatório.

```
[Table input: locais OPENMETEO] → [Select values: lat/lon texto] → [UDJE: url] → [REST Client]
  → [JSON Input: arrays diários] → [Select values: tipos] → [Number range: graus → N/NE/E…]
  → [Number range: km/h → classe 1–4] → [Value Mapper: WMO → idWeatherType IPMA]
  → [Calculator: amplitude] → [Get System Info: hoje] → [Add constants: fonte] → [Insert / Update]
```

1. **[Table input]**
   ```sql
   SELECT id_local, nome, latitude, longitude FROM dim_local WHERE fonte_previsao = 'OPENMETEO'
   ```
2. **[Select values]** — `latitude`, `longitude` → String, formato `0.0000`, *Decimal* `.`.
3. **[User Defined Java Expression]** `url`:
   ```java
   "https://api.open-meteo.com/v1/forecast?latitude=" + latitude + "&longitude=" + longitude + "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,wind_speed_10m_max,wind_direction_10m_dominant,weather_code&timezone=Europe%2FLisbon&forecast_days=5"
   ```
4. **[REST Client]** → `json`, `http_status` → **[Filter rows]** 200.
5. **[JSON Input]** (arrays paralelos, como na T4):

   | Name | Path | Type |
   |---|---|---|
   | data_previsao | `$.daily.time[*]` | String |
   | t_max | `$.daily.temperature_2m_max[*]` | Number |
   | t_min | `$.daily.temperature_2m_min[*]` | Number |
   | prob_precipitacao | `$.daily.precipitation_probability_max[*]` | Number |
   | vento_kmh | `$.daily.wind_speed_10m_max[*]` | Number |
   | vento_graus | `$.daily.wind_direction_10m_dominant[*]` | Number |
   | wmo_code | `$.daily.weather_code[*]` | Integer |
6. **[Select values]** — `data_previsao` → Date `yyyy-MM-dd`.
7. **[Number range]** (✔ converter) — input `vento_graus`, output `dir_vento`:

   | Lower | Upper | Value |
   |---|---|---|
   | 0 | 22.5 | N |
   | 22.5 | 67.5 | NE |
   | 67.5 | 112.5 | E |
   | 112.5 | 157.5 | SE |
   | 157.5 | 202.5 | S |
   | 202.5 | 247.5 | SW |
   | 247.5 | 292.5 | W |
   | 292.5 | 337.5 | NW |
   | 337.5 | 360.1 | N |

   (O IPMA usa as mesmas siglas em inglês: N, NE, E, SE, S, SW, W, NW.)
8. **[Number range]** — input `vento_kmh`, output `classe_vento`: `0–15 → 1` (fraco), `15–35 → 2` (moderado), `35–55 → 3` (forte), `55–999 → 4` (muito forte). Depois **[Select values]** → Integer.
9. **[Value Mapper]** — `wmo_code` → `id_weather_type` (códigos WMO da Open-Meteo → tipos do IPMA). Confirmem as descrições em `data/amostras/ipma_estados_tempo.json`:

   | WMO | Significado | IPMA |
   |---|---|---|
   | 0 | Céu limpo | 1 |
   | 1 | Pouco nublado | 2 |
   | 2 | Parcialmente nublado | 3 |
   | 3 | Encoberto | 4 |
   | 45, 48 | Nevoeiro | 16 |
   | 51, 53, 55 | Chuvisco | 10 |
   | 61, 63 | Chuva | 9 |
   | 65 | Chuva forte | 11 |
   | 80, 81, 82 | Aguaceiros | 6 |
   | 95, 96, 99 | Trovoada | 19 |

   *Default upon non-matching*: vazio (fica null). Depois **[Select values]** → Integer.
10. **[Calculator]** `amplitude_termica` = `t_max - t_min`.
11. **[Get System Info]** `hoje` = *Today 00:00:00* → usar como `data_atualizacao` (a Open-Meteo não tem data de atualização; assim fica 1 linha por dia e o Insert/Update atualiza-a durante o dia).
12. **[Add constants]** `fonte` = `OPENMETEO`.
13. **[Insert / Update]** `fact_previsao` — mesmas chaves e campos da T2 (mapear `hoje → data_atualizacao`).

> Na defesa: "duas APIs com formatos diferentes acabam na mesma tabela com o mesmo significado; a vista `v_previsao_atual` mostra os 4 locais lado a lado."

---

## T3 — `T3_avisos_ipma.ktr` · Avisos meteorológicos → `fact_aviso` + alertas

```
[Generate rows: url] → [REST Client] → [JSON Input]
  → [Stream lookup: só áreas dos nossos locais] → [Filter rows: encontrada]
  → [Value Mapper: nível → número] → [Replace in string: limpar texto]
  → [Select values: datas] → [Insert / Update: fact_aviso]
  → [Get Variables: NIVEL_ALERTA] → [Filter rows: nivel_num >= NIVEL_ALERTA] → [Table output: fact_alerta]
```

1. **[Generate rows]** `url` = `https://api.ipma.pt/open-data/forecast/warnings/warnings_www.json`
2. **[REST Client]** → `json`.
3. **[JSON Input]** — a resposta é um **array na raiz**:

   | Name | Path |
   |---|---|
   | id_area_aviso | `$[*].idAreaAviso` |
   | tipo | `$[*].awarenessTypeName` |
   | nivel | `$[*].awarenessLevelID` |
   | inicio | `$[*].startTime` |
   | fim | `$[*].endTime` |
   | texto | `$[*].text` |
4. **[Table input]** (fluxo paralelo): `SELECT DISTINCT id_area_aviso FROM dim_local` → ligar como *lookup step* de um **[Stream lookup]** (chave `id_area_aviso`, devolve o próprio campo como `area_ok`). **[Filter rows]** `area_ok IS NOT NULL` (só BRG, PTO e LSB).
5. **[Value Mapper]** (✔ operação "converter") — fonte `nivel`, destino `nivel_num`: `green→1`, `yellow→2`, `orange→3`, `red→4`.
6. **[Replace in string]** (ER) sobre `texto`: `<[^>]+>` → `` (tirar HTML) e `\s{2,}` → ` ` (espaços repetidos). Em `inicio`/`fim`: `T` → ` ` como em T2.
7. **[Select values]** — `inicio`, `fim` → Timestamp `yyyy-MM-dd HH:mm:ss`; `nivel_num` → Integer.
8. **[Insert / Update]** `fact_aviso` — keys `id_area_aviso, tipo, inicio`; update `nivel, nivel_num, fim, texto`.
9. **[Get Variables]** `NIVEL_ALERTA` → campo `nivel_alerta` (Integer). **[Filter rows]** `nivel_num >= nivel_alerta`.
10. **[Formula]** / **[Concat fields]** → `mensagem` = `"Aviso " + nivel + " de " + tipo + " na área " + id_area_aviso`; **[Add constants]** `origem = AVISO_IPMA` → **[Table output]** `fact_alerta` (origem, mensagem, valor = nivel_num, limite = nivel_alerta).
11. *(Opcional, mais-valia de integração)* **[MQTT Producer]** — broker `tcp://localhost:1883`, tópico `isi/alertas`, mensagem `{"nivel":"ALERTA"}` → o Node-RED acende o LED do Arduino.

---

## T4 — `T4_qualidade_ar.ktr` · Open-Meteo (JSON horário) → fact + agregado diário

```
[Table input: dim_local] → [UDJE: url] → [REST Client] → [JSON Input: arrays horários]
   → [Replace in string: T→espaço] → [Null if] → [Select values]
   ├→ [Insert / Update: fact_qualidade_ar]
   └→ [Get Variables: PM10_LIMITE] → [Calculator: dia + flag] → [Sort rows]
        → [Group by: id_local, dia] → [Calculator: excede] ├→ [Insert / Update: agg_qualidade_ar_dia]
                                                         └→ [Filter: excede] → [Table output: fact_alerta]
```

1. **[Table input]** `SELECT id_local, nome, latitude, longitude FROM dim_local`
2. **[Select values]** — `latitude`, `longitude` → String, formato `0.0000`, *Decimal* `.` (senão o URL sai com vírgulas!).
3. **[User Defined Java Expression]** `url`:
   ```java
   "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=" + latitude + "&longitude=" + longitude + "&hourly=pm10,pm2_5,nitrogen_dioxide,ozone&timezone=Europe%2FLisbon&past_days=1&forecast_days=1"
   ```
4. **[REST Client]** → `json`, `http_status` → **[Filter rows]** 200.
5. **[JSON Input]** — a API devolve **arrays paralelos** (um array por variável, mesma posição = mesma hora). O JSON Input junta-os linha a linha:

   | Name | Path |
   |---|---|
   | data_hora | `$.hourly.time[*]` |
   | pm10 | `$.hourly.pm10[*]` |
   | pm2_5 | `$.hourly.pm2_5[*]` |
   | no2 | `$.hourly.nitrogen_dioxide[*]` |
   | o3 | `$.hourly.ozone[*]` |

   > Isto é um bom exemplo de *mapeamento e reestruturação de schemas* (colunas → linhas) para o relatório.
6. **[Replace in string]** `data_hora`: regex `^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})$` → `$1 $2:00`.
7. **[Select values]** `data_hora` → Timestamp `yyyy-MM-dd HH:mm:ss`; poluentes → Number (*Decimal* `.`). Valores `null` da API ficam nulos.
8. **[Insert / Update]** `fact_qualidade_ar` — keys `id_local, data_hora`.
9. Ramo de agregação (copiem as linhas: botão direito no passo → *Data movement → Copy data to next steps*):
   - **[Get Variables]** `PM10_LIMITE` → `pm10_limite` (Number).
   - **[Calculator]** `dia` = *Date A without time* (`data_hora`)… ou **[Formula]** `DATEVALUE([data_hora])`.
   - **[Formula]** `acima` = `IF([pm10] > [pm10_limite]; 1; 0)`
   - **[Sort rows]** `id_local, dia`
   - **[Group by]** (agregações ✔) — group: `id_local, dia`; aggregates:

     | Name | Subject | Type |
     |---|---|---|
     | pm10_media | pm10 | Average |
     | pm10_max | pm10 | Maximum |
     | pm2_5_media | pm2_5 | Average |
     | no2_max | no2 | Maximum |
     | o3_max | o3 | Maximum |
     | horas_pm10_acima | acima | Sum |
     | pm10_limite | pm10_limite | First value |
   - **[Formula]** `excede_limite` = `[pm10_media] > [pm10_limite]` (Boolean).
   - **[Insert / Update]** `agg_qualidade_ar_dia` — keys `id_local, data` (mapear `dia → data`).
   - **[Filter rows]** `excede_limite = Y` → mensagem → **[Table output]** `fact_alerta` (origem `QUALIDADE_AR`, valor `pm10_media`, limite `pm10_limite`).

---

## T5 — `T5_exportacoes.ktr` · Exportar CSV / JSON / XML / SQL

```
[Table input: v_previsao_atual] ├→ [Text file output]  → previsoes_AAAAMMDD.csv
                                ├→ [JSON output]       → previsoes_AAAAMMDD.json
                                └→ [XML output]        → previsoes_AAAAMMDD.xml
[Table input: agg_qualidade_ar_dia + dim_local] → [SQL File Output] → qualidade_ar_AAAAMMDD.sql
[Table input: fact_alerta WHERE notificado = false] → [Text file output] → alertas.csv
```

- Ficheiros em `${PROJ_DIR}/data/exportacoes/` com ✔ *Include date in filename*.
- **[Text file output]**: separador `;`, *Header* ✔, encoding UTF-8.
- **[JSON output]**: *Json bloc name* `previsoes`, *Nr rows in a bloc* 0 (tudo num array), *Output value*/ficheiro.
- **[XML output]**: *Parent XML element* `previsoes`, *Row XML element* `previsao`.
- **[SQL File Output]**: ligação `ambiente`, tabela `agg_qualidade_ar_dia`, ✔ *Add create table statement* (gera um dump reutilizável).

---

## J — `J_principal.kjb` · Orquestração (Job)

```
[START] → [Check Db connections] → [T0_config] → [T1_dimensoes] → [T2_previsoes_ipma]
   → [T2b_previsao_openmeteo] → [T3_avisos_ipma] → [T4_qualidade_ar] → [T5_exportacoes]
   → [Put a file with SFTP] → [SQL: log OK] → [Mail: relatório] → [Success]

Qualquer passo (seta vermelha "on failure")
   → [SQL: log ERRO] → [Mail: erro + log] → [Abort job]
```

1. **[START]** — ✔ *Repeat*, *Type* Interval, 60 minutos (corre de hora a hora enquanto o Spoon/Kitchen estiver aberto).
2. **[Check Db connections]** → `ambiente`.
3. **[Transformation]** × 7 — *Transformation filename* `${Internal.Entry.Current.Directory}/../transformacoes/T2_previsoes_ipma.ktr`, etc. Passar o parâmetro `PROJ_DIR` (separador *Parameters* → ✔ *Pass all parameter values down*).
4. **[Put a file with SFTP]** (✔ serviços remotos)
   - Server `localhost`, port `2222`, user `isi`, password `isi2026`
   - Remote directory `upload`
   - Local directory `${PROJ_DIR}/data/exportacoes`, **Wildcard (regex)**: `.*_\d{8}\.(csv|json|xml|sql)$`
5. **[SQL]** (log OK):
   ```sql
   INSERT INTO etl_execucao (processo, ferramenta, estado, mensagem, inicio)
   VALUES ('J_principal', 'PENTAHO', 'OK', 'Execução completa', now() - interval '1 minute');
   ```
6. **[Mail]** (✔ notificação)
   - SMTP server `${SMTP_HOST}` (localhost), port `${SMTP_PORT}` (1025), sem autenticação
   - Destination `grupo@isi.local`, Sender `etl-ambiente@isi.local`
   - Subject `[ISI] Relatório ETL ambiente — ${Internal.Job.Name}`
   - Separador *Attached files*: ✔ anexar ficheiros (escolham *Result files* e, nas transformações de exportação, ✔ *Add filenames to result*).
   - Ver os emails em **http://localhost:8025** (Mailpit).
7. Ramo de erro: **[SQL]** com `estado = 'ERRO'` → **[Mail]** com ✔ *Include log* → **[Abort job]**.

### Logs (✔ geração de logs)
- *Edit → Settings → Logging* em cada transformação → *Transformation* → ligação `ambiente`, tabela `etl_log_pdi` → botão **SQL** (cria a tabela) → Execute.
- No job: *Settings → Log* → tabela `etl_log_job`.
- Correr em linha de comandos (para o vídeo/agendamento):
  ```bash
  ./kitchen.sh -file=/caminho/isi-tp1-ambiente/pentaho/jobs/J_principal.kjb \
               -param:PROJ_DIR=/caminho/isi-tp1-ambiente -level=Basic \
               -logfile=/caminho/isi-tp1-ambiente/data/logs/job_$(date +%Y%m%d_%H%M).log
  ```

---

## Checklist vs. critérios do enunciado

| Critério | Onde está |
|---|---|
| ≥ 2–3 formatos | JSON (APIs), XML (locais.xml), YAML (config), CSV (exportação) |
| Fontes variadas | APIs REST (IPMA, Open-Meteo previsão e qualidade do ar), ficheiros locais, BD PostgreSQL (+ MQTT na parte B) |
| Merge de fontes | Previsão IPMA (Braga, Porto, Lisboa) + Open-Meteo (Barcelos) na mesma tabela (T2 + T2b) |
| Expressões regulares | Regex Evaluation (IDs, datas), Replace in string (datas, HTML, espaços), wildcard SFTP |
| Limpeza / nulos / duplicados | Null if (-99), Filter rows, Unique rows |
| Joins / lookups | Stream lookup (áreas de aviso, campos de local), Insert/Update por chave, Value Mapper / Number range (WMO → IPMA, graus → direção) |
| Agregações e cálculos | Group by diário, Calculator (amplitude), Formula (excedências) |
| Conversão de formatos | JSON → BD → CSV / JSON / XML / SQL |
| Reestruturação de schema | Arrays paralelos Open-Meteo → linhas |
| Jobs com serviços remotos | SFTP, email, verificação de BD |
| Logs | Tabelas etl_log_pdi / etl_execucao, ficheiro .log do Kitchen |
| Persistência | PostgreSQL em estrela (dim_* / fact_* / agg_*) |
| Dashboard | Grafana sobre as vistas `v_*` |

## O que mostrar no vídeo (parte A)
1. `docker compose up -d` e o Adminer com as tabelas vazias.
2. Correr `J_principal` no Spoon → tudo verde.
3. Tabelas preenchidas; correr outra vez → **não duplica**.
4. Mudar `pm10_diario` no YAML para 5 → correr → aparecem alertas + email no Mailpit.
5. Ficheiros em `data/exportacoes` e no SFTP.
6. Dashboard no Grafana.
