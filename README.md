# Monitorização Ambiental — Braga, Barcelos, Porto e Lisboa · ISI TP1 (2026/27)

Processo ETL que integra, para **Braga, Barcelos, Porto e Lisboa**, **previsões e avisos do IPMA**, **previsão e qualidade do ar da Open-Meteo** e **leituras de um sensor Arduino no IPCA, em Barcelos (MQTT)** numa base de dados PostgreSQL, com alertas por email, exportação de ficheiros por SFTP e dashboard em Grafana.

Integração de Sistemas de Informação · Licenciatura em Engenharia de Sistemas Informáticos · IPCA — EST
Entrega: **22 de outubro de 2026**

| Elemento | Ferramenta | Parte |
|---|---|---|
| A — Joe | Pentaho Data Integration | APIs IPMA + Open-Meteo → BD, exportações, Job (SFTP, email, logs) |
| B — _(colega)_ | KNIME Analytics Platform | Sensores (MQTT/JSON/CSV/XML) → limpeza → cruzamento → alertas e relatório PDF |
| Em comum | Node-RED, Mosquitto, PostgreSQL, Grafana | Infraestrutura e dashboard |

## Arquitetura

```
 EXTRACT                          TRANSFORM                         LOAD
 ───────                          ─────────                         ────
 API IPMA (JSON) ──────┐  Braga, Porto, Lisboa
 API Open-Meteo (JSON) ┼──► Pentaho (T0–T5, J_principal)   Barcelos + qualidade do ar (4 locais) ──┐   ┌─► PostgreSQL (dim_/fact_/agg_)
 config.yaml (YAML) ───┤                                    ├──►┤─► CSV / JSON / XML / SQL ─► SFTP
 locais.xml (XML) ─────┘                                    │   ├─► Email (Mailpit)
                                                            │   └─► Grafana (dashboard)
 Arduino DHT22 ─USB─► Node-RED ─MQTT─► Mosquitto            │
                         └─► leituras.jsonl / .csv ──► KNIME (W1–W3) ─► relatório PDF, alertas
                                                            │
                     isi/alertas (MQTT) ◄── alertas ────────┘──► LED no Arduino
```

## Estrutura do repositório

```
docker-compose.yml        Postgres, Adminer, Mosquitto, Grafana, Mailpit (email), SFTP
db/init/01_schema.sql     Esquema em estrela + staging + logs + vistas (corre sozinho no 1.º arranque)
config/config.yaml        Limites, URLs, email, SFTP (lido pelo Pentaho)
config/locais.xml         Locais (códigos IPMA) e sensores
arduino/sensor_dht/       Sketch do Arduino (DHT22 → JSON pela porta série; LED de alerta)
node-red/flows.json       Fluxos: Arduino → MQTT, Simulador → MQTT, MQTT → ficheiros
pentaho/GUIA_PENTAHO.md   Passo a passo das transformações T0–T5 e do job J_principal
pentaho/transformacoes/   *.ktr  (criados no Spoon)
pentaho/jobs/             *.kjb  (criados no Spoon)
knime/GUIA_KNIME.md       Passo a passo dos workflows W1–W3
scripts/testar_apis.py    Testa as APIs e guarda amostras em data/amostras/
data/                     sensores/, exportacoes/, logs/, amostras/ (gerados)
docs/                     Relatório, diagramas, QR code do vídeo
```

## Arranque rápido

```bash
# 1. Infraestrutura
docker compose up -d
#    Adminer  http://localhost:8080  (Sistema PostgreSQL, servidor postgres, isi / isi2026, BD ambiente)
#    Grafana  http://localhost:3000  (admin / admin)
#    Mailpit  http://localhost:8025  (emails enviados pelo ETL)

# 2. Confirmar as APIs
python3 scripts/testar_apis.py

# 3. Node-RED (instalado no Mac, não em Docker, para aceder à porta USB)
npm install -g --unsafe-perm node-red
cd ~/.node-red && npm install node-red-node-serialport && cd -
node-red            # arrancar A PARTIR DA PASTA DO PROJETO (caminhos data/... são relativos)
#    http://localhost:1880 → menu ☰ → Import → node-red/flows.json → Deploy
#    Porta do Arduino: ls /dev/cu.usbmodem*  → editar o nó de configuração "Arduino"
#    Sem Arduino: ativar o separador "Simulador → MQTT" (duplo clique no separador → Enabled)

# 4. Arduino
#    Arduino IDE → instalar "DHT sensor library" (Adafruit) → carregar arduino/sensor_dht/sensor_dht.ino
#    Fechar o Serial Monitor antes de arrancar o Node-RED (só um programa pode usar a porta)

# 5. Pentaho / KNIME → seguir os guias
```

Ver o tráfego MQTT (opcional): `docker exec -it isi_mosquitto mosquitto_sub -t 'isi/#' -v`

## Locais

| Local | Previsão | Código IPMA | Área de aviso | Qualidade do ar | Sensor |
|---|---|---|---|---|---|
| Braga | IPMA | 1030300 | BRG | Open-Meteo | — |
| Barcelos | Open-Meteo (não existe no IPMA) | — | BRG | Open-Meteo | ARD-01 (IPCA) |
| Porto | IPMA | 1131200 | PTO | Open-Meteo | — |
| Lisboa | IPMA | 1110600 | LSB | Open-Meteo | — |

## Modelo de dados

| Tabela | Conteúdo | Quem escreve |
|---|---|---|
| `dim_local` | Locais (código IPMA, área de aviso, coordenadas) | Pentaho T1 |
| `dim_estado_tempo`, `dim_classe_vento` | Lookups IPMA | Pentaho T1 |
| `dim_data` | Calendário 2026–2027 | SQL inicial |
| `dim_sensor` | Sensores (do XML) | KNIME W1 |
| `fact_previsao` | Previsão diária por local (coluna `fonte`: IPMA / OPENMETEO) | Pentaho T2 + T2b |
| `fact_aviso` | Avisos meteorológicos | Pentaho T3 |
| `fact_qualidade_ar` / `agg_qualidade_ar_dia` | PM10, PM2.5, NO2, O3 horário / diário | Pentaho T4 |
| `fact_sensor` | Leituras limpas do Arduino | KNIME W1 |
| `fact_alerta` | Alertas (aviso IPMA, PM10, sensor) | Pentaho T3/T4, KNIME W2 |
| `etl_execucao`, `etl_rejeitado` | Logs e linhas rejeitadas | Todos |
| `v_previsao_atual`, `v_sensor_vs_previsao`, `v_avisos_ativos` | Vistas para Grafana/relatório | — |

## Dashboard Grafana (sugestão de painéis)

A ligação à BD já vem configurada (*Ambiente (PostgreSQL)*). *Dashboards → New → Add visualization*:

| Painel | Tipo | Query |
|---|---|---|
| Temperatura do sensor | Time series | `SELECT ts AS time, temperatura, humidade FROM fact_sensor WHERE $__timeFilter(ts) ORDER BY ts` |
| PM10 por local | Time series | `SELECT data_hora AS time, l.nome AS metric, pm10 FROM fact_qualidade_ar q JOIN dim_local l USING (id_local) WHERE $__timeFilter(data_hora) ORDER BY 1` |
| Previsão | Table | `SELECT * FROM v_previsao_atual WHERE data_previsao >= current_date` |
| Sensor vs IPMA | Bar chart | `SELECT dia::text, sensor_t_max, ipma_t_max FROM v_sensor_vs_previsao ORDER BY dia` |
| Avisos ativos | Table | `SELECT locais, tipo, nivel, inicio, fim FROM v_avisos_ativos` |
| Alertas (24 h) | Stat | `SELECT count(*) FROM fact_alerta WHERE criado_em > now() - interval '24 hours'` |

Exportem o dashboard (*Share → Export → Save to file*) para `grafana/dashboard.json` e ponham-no no Git.

## Fontes de dados

- IPMA — API de dados abertos: https://api.ipma.pt
- Open-Meteo — Forecast API: https://open-meteo.com/en/docs
- Open-Meteo — Air Quality API: https://open-meteo.com/en/docs/air-quality-api
- Limites PM10: Decreto-Lei n.º 102/2010 (transpõe a Diretiva 2008/50/CE)

## Calendário

| Datas | Tarefa |
|---|---|
| 14–15 out | Registar tema na folha partilhada, criar repositório Git, `docker compose up`, Node-RED + Arduino a publicar |
| 16–18 out | Transformações (A: T0–T4 + T2b · B: W1) |
| 19–20 out | Job/orquestração, alertas, exportações, Grafana (A: T5 + J · B: W2–W3) |
| 21 out | Relatório + vídeo (QR code) |
| 22 out | Entrega no e-learning |
