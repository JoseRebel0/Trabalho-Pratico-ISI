# Guia KNIME (Elemento B) — Sensores, alertas e relatório

Workflow(s) em `knime/` (exportar com *File → Export KNIME Workflow* para `.knwf` e pôr no Git).
Leiam também o `pentaho/GUIA_PENTAHO.md` para saberem o que a Parte A já deixa na BD.

## 0. Preparação
- KNIME Analytics Platform (5.x). Extensões: *KNIME Database*, *KNIME JSON*, *KNIME XML*, *KNIME REST Client*, *KNIME Reporting*, *KNIME Email* (instalam-se em *File → Install KNIME Extensions*).
- Ligação BD: nó **PostgreSQL Connector** — host `localhost`, porta `5432`, BD `ambiente`, user `isi` / `isi2026`.

## W1 — Sensores: dimensão (XML) e leituras (JSON Lines / CSV)

```
XML Reader (config/locais.xml) → XPath (/monitorizacao/sensores/sensor) → DB Insert/Merge dim_sensor
JSON Reader / Line Reader (data/sensores/leituras.jsonl) → JSON to Table
   → String Manipulation / Rule Engine (limpeza) → Duplicate Row Filter → Rule-based Row Splitter
       ├→ válidos   → DB Merge fact_sensor
       └→ inválidos → DB Insert etl_rejeitado
```

1. **XML Reader** + **XPath** — `@id`, `@tipo`, `descricao`, `local`; depois **DB Query Reader** em `dim_local` + **Joiner** por `nome = local` para obter `id_local` (lookup ✔). Os sensores estão em Barcelos.
2. **Line Reader** em `data/sensores/leituras.jsonl` → **String to JSON** → **JSON Path** (`$.sensor`, `$.seq`, `$.ts`, `$.temp`, `$.hum`, `$.origem`).
   (Alternativa: **CSV Reader** em `leituras.csv`, separador `;`, sem cabeçalho — é outro formato para o relatório.)
3. Limpeza (✔ ER):
   - **Regex Split** / **String Manipulation** `regexMatcher($temp$, "^-?\\d+(\\.\\d+)?$")` → leituras `"nan"` ficam inválidas.
   - Validar `sensor` com `^(ARD|SIM)-\d{2}$`.
   - **String to Number** em `temp`, `hum`; **String to Date&Time** em `ts` (ISO).
   - **Rule Engine**: inválido se `temp < -15 OR temp > 50 OR hum < 0 OR hum > 100` (limites do `config.yaml`, lidos com um **Python Script** ou copiados para variáveis de fluxo).
   - **Duplicate Row Filter** por `sensor, seq, ts` (o simulador manda duplicados de propósito).
4. **DB Merge** em `fact_sensor` (chave `sensor_id, ts`) e **DB Insert** dos rejeitados em `etl_rejeitado`.

## W2 — Cruzamento e alertas

```
DB Query Reader (v_sensor_vs_previsao) → Math Formula (|desvio|) → Row Filter (desvio > 3 °C)
DB Query Reader (fact_alerta WHERE notificado = false)
   → Concatenate → Send Email (resumo) → DB Update notificado = true
```
- **Send Email**: SMTP `localhost`, porta `1025` (Mailpit, ver em http://localhost:8025).
- (Opcional) publicar `{"nivel":"ALERTA"}` em MQTT `isi/alertas` → LED do Arduino (com nó **Python Script** + `paho-mqtt`, ou deixar o Node-RED fazer isso a partir da BD).

## W3 — Relatório PDF (✔ CSV/BD → PDF)
- **DB Query Reader** em `v_previsao_atual`, `agg_qualidade_ar_dia`, `v_sensor_vs_previsao`.
- Gráficos com **Line Plot** / **Bar Chart**; montar com **KNIME Reporting** (*Report Template Creator* → *Report PDF Writer*).
- Guardar em `data/exportacoes/relatorio_AAAAMMDD.pdf` e anexar no **Send Email**.

## Orquestração
- Um workflow "principal" que chama W1 → W2 → W3 com **Call Workflow Service** (ou componentes em sequência).
- Agendar: KNIME em batch (`knime -nosplash -application org.knime.product.KNIME_BATCH_APPLICATION -workflowFile=...`) via `cron`.
- Log: **DB Insert** em `etl_execucao` (`ferramenta = 'KNIME'`) no fim de cada execução.
