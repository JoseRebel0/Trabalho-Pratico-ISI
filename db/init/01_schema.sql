-- =====================================================================
-- ISI TP1 — Monitorização Ambiental (Braga, Barcelos, Porto, Lisboa)
-- Esquema da base de dados "ambiente" (PostgreSQL 16)
-- Corre automaticamente na 1.ª vez que o contentor postgres arranca.
--
--   stg_*   : staging (dados em bruto, tal como chegam)
--   dim_*   : dimensões
--   fact_*  : factos (esquema em estrela)
--   agg_*   : agregados calculados pelo ETL
--   etl_*   : logs/controlo das execuções
-- =====================================================================

SET TIME ZONE 'Europe/Lisbon';

-- ---------------------------------------------------------------------
-- DIMENSÕES
-- ---------------------------------------------------------------------

-- Locais monitorizados (carregados pelo Pentaho a partir de config/locais.xml)
-- Barcelos não tem previsão no IPMA -> global_id_local NULL e previsão vinda da Open-Meteo
CREATE TABLE dim_local (
    id_local          SERIAL PRIMARY KEY,
    global_id_local   INTEGER UNIQUE,            -- código IPMA (ex.: 1030300 = Braga); NULL se não existir
    nome              VARCHAR(80)  UNIQUE NOT NULL,
    fonte_previsao    VARCHAR(10)  NOT NULL DEFAULT 'IPMA',  -- IPMA / OPENMETEO
    distrito          VARCHAR(80),
    id_area_aviso     CHAR(3),                   -- código de área de aviso IPMA (ex.: BRG)
    latitude          NUMERIC(8,5),
    longitude         NUMERIC(8,5)
);

-- Estados do tempo (lookup IPMA weather-type-classe.json)
CREATE TABLE dim_estado_tempo (
    id_weather_type   INTEGER PRIMARY KEY,
    descricao_pt      VARCHAR(120),
    descricao_en      VARCHAR(120)
);

-- Classes de intensidade do vento (lookup IPMA wind-speed-daily-classe.json)
CREATE TABLE dim_classe_vento (
    classe            INTEGER PRIMARY KEY,
    descricao_pt      VARCHAR(60),
    descricao_en      VARCHAR(60)
);

-- Dimensão tempo (dias) — preenchida já aqui para 2026–2027
CREATE TABLE dim_data (
    data              DATE PRIMARY KEY,
    ano               SMALLINT,
    mes               SMALLINT,
    dia               SMALLINT,
    dia_semana        SMALLINT,      -- 1 = segunda ... 7 = domingo
    nome_dia          VARCHAR(15),
    fim_de_semana     BOOLEAN
);

INSERT INTO dim_data
SELECT d::date,
       EXTRACT(YEAR FROM d), EXTRACT(MONTH FROM d), EXTRACT(DAY FROM d),
       EXTRACT(ISODOW FROM d),
       (ARRAY['segunda','terça','quarta','quinta','sexta','sábado','domingo'])[EXTRACT(ISODOW FROM d)],
       EXTRACT(ISODOW FROM d) IN (6,7)
FROM generate_series('2026-01-01'::date, '2027-12-31'::date, '1 day') AS d;

-- Sensores físicos (Arduino) — carregados pelo KNIME a partir de XML
CREATE TABLE dim_sensor (
    sensor_id         VARCHAR(20) PRIMARY KEY,   -- ex.: ARD-01
    descricao         VARCHAR(120),
    tipo              VARCHAR(40),               -- ex.: DHT22
    id_local          INTEGER REFERENCES dim_local(id_local)
);

-- ---------------------------------------------------------------------
-- STAGING (dados em bruto)
-- ---------------------------------------------------------------------

-- Leituras do Arduino tal como chegam do Node-RED (podem vir sujas)
CREATE TABLE stg_sensor_leitura (
    id                BIGSERIAL PRIMARY KEY,
    sensor_id         VARCHAR(40),
    ts                TIMESTAMPTZ,
    temp_raw          VARCHAR(20),
    hum_raw           VARCHAR(20),
    payload           JSONB,
    recebido_em       TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------
-- FACTOS — Parte A (Pentaho: APIs)
-- ---------------------------------------------------------------------

-- Previsão diária por local (IPMA para Braga/Porto/Lisboa, Open-Meteo para Barcelos)
CREATE TABLE fact_previsao (
    id                BIGSERIAL PRIMARY KEY,
    id_local          INTEGER NOT NULL REFERENCES dim_local(id_local),
    fonte             VARCHAR(10) NOT NULL,      -- IPMA / OPENMETEO
    data_previsao     DATE    NOT NULL REFERENCES dim_data(data),
    data_atualizacao  TIMESTAMP NOT NULL,        -- dataUpdate do IPMA; dia da carga (00:00) na Open-Meteo
    t_min             NUMERIC(4,1),
    t_max             NUMERIC(4,1),
    amplitude_termica NUMERIC(4,1),              -- calculado: t_max - t_min
    prob_precipitacao NUMERIC(5,1),
    dir_vento         VARCHAR(3),
    classe_vento      INTEGER REFERENCES dim_classe_vento(classe),
    id_weather_type   INTEGER REFERENCES dim_estado_tempo(id_weather_type),
    carregado_em      TIMESTAMPTZ DEFAULT now(),
    UNIQUE (id_local, data_previsao, data_atualizacao)
);

-- Avisos meteorológicos IPMA (só os não-verdes interessam, mas guardamos o nível)
CREATE TABLE fact_aviso (
    id                BIGSERIAL PRIMARY KEY,
    id_area_aviso     CHAR(3)      NOT NULL,
    tipo              VARCHAR(60)  NOT NULL,     -- awarenessTypeName (ex.: Precipitação)
    nivel             VARCHAR(10)  NOT NULL,     -- green / yellow / orange / red
    nivel_num         SMALLINT,                  -- 1..4 (Value Mapper)
    inicio            TIMESTAMP    NOT NULL,
    fim               TIMESTAMP,
    texto             TEXT,
    carregado_em      TIMESTAMPTZ DEFAULT now(),
    UNIQUE (id_area_aviso, tipo, inicio)
);

-- Qualidade do ar horária (Open-Meteo Air Quality API)
CREATE TABLE fact_qualidade_ar (
    id                BIGSERIAL PRIMARY KEY,
    id_local          INTEGER   NOT NULL REFERENCES dim_local(id_local),
    data_hora         TIMESTAMP NOT NULL,
    pm10              NUMERIC(6,1),
    pm2_5             NUMERIC(6,1),
    no2               NUMERIC(6,1),
    o3                NUMERIC(6,1),
    carregado_em      TIMESTAMPTZ DEFAULT now(),
    UNIQUE (id_local, data_hora)
);

-- Agregado diário da qualidade do ar (Group By no Pentaho)
CREATE TABLE agg_qualidade_ar_dia (
    id_local          INTEGER NOT NULL REFERENCES dim_local(id_local),
    data              DATE    NOT NULL REFERENCES dim_data(data),
    pm10_media        NUMERIC(6,1),
    pm10_max          NUMERIC(6,1),
    pm2_5_media       NUMERIC(6,1),
    no2_max           NUMERIC(6,1),
    o3_max            NUMERIC(6,1),
    horas_pm10_acima  SMALLINT,                  -- n.º de horas com PM10 > limite
    excede_limite     BOOLEAN,                   -- média diária PM10 > limite (config.yaml)
    PRIMARY KEY (id_local, data)
);

-- ---------------------------------------------------------------------
-- FACTOS — Parte B (KNIME: sensores)
-- ---------------------------------------------------------------------

-- Leituras limpas e validadas do Arduino
CREATE TABLE fact_sensor (
    id                BIGSERIAL PRIMARY KEY,
    sensor_id         VARCHAR(20) NOT NULL REFERENCES dim_sensor(sensor_id),
    ts                TIMESTAMPTZ NOT NULL,
    temperatura       NUMERIC(4,1),
    humidade          NUMERIC(4,1),
    UNIQUE (sensor_id, ts)
);

-- Alertas gerados (sensor fora de gama, PM10 acima do limite, aviso IPMA laranja/vermelho)
CREATE TABLE fact_alerta (
    id                BIGSERIAL PRIMARY KEY,
    origem            VARCHAR(20) NOT NULL,      -- SENSOR / QUALIDADE_AR / AVISO_IPMA
    id_local          INTEGER REFERENCES dim_local(id_local),
    mensagem          TEXT NOT NULL,
    valor             NUMERIC(8,2),
    limite            NUMERIC(8,2),
    criado_em         TIMESTAMPTZ DEFAULT now(),
    notificado        BOOLEAN DEFAULT false
);

-- ---------------------------------------------------------------------
-- LOGS / CONTROLO
-- ---------------------------------------------------------------------

CREATE TABLE etl_execucao (
    id                BIGSERIAL PRIMARY KEY,
    processo          VARCHAR(60) NOT NULL,      -- ex.: T_previsoes_ipma
    ferramenta        VARCHAR(20) NOT NULL,      -- PENTAHO / KNIME / NODE-RED
    estado            VARCHAR(10) NOT NULL,      -- OK / ERRO
    linhas_lidas      INTEGER,
    linhas_escritas   INTEGER,
    linhas_rejeitadas INTEGER,
    mensagem          TEXT,
    inicio            TIMESTAMPTZ,
    fim               TIMESTAMPTZ DEFAULT now()
);

-- Linhas rejeitadas pelas validações (regex, gamas, nulos) — útil para o relatório
CREATE TABLE etl_rejeitado (
    id                BIGSERIAL PRIMARY KEY,
    processo          VARCHAR(60),
    motivo            VARCHAR(200),
    dados             TEXT,
    criado_em         TIMESTAMPTZ DEFAULT now()
);

-- ---------------------------------------------------------------------
-- VISTAS para o Grafana e relatórios
-- ---------------------------------------------------------------------

-- Última previsão disponível por local e dia
CREATE VIEW v_previsao_atual AS
SELECT DISTINCT ON (p.id_local, p.data_previsao)
       l.nome AS local, p.fonte, p.data_previsao, p.t_min, p.t_max, p.amplitude_termica,
       p.prob_precipitacao, p.dir_vento, cv.descricao_pt AS vento,
       et.descricao_pt AS estado_tempo, p.data_atualizacao
FROM fact_previsao p
JOIN dim_local l             ON l.id_local = p.id_local
LEFT JOIN dim_estado_tempo et ON et.id_weather_type = p.id_weather_type
LEFT JOIN dim_classe_vento cv ON cv.classe = p.classe_vento
ORDER BY p.id_local, p.data_previsao, (p.fonte = 'IPMA') DESC, p.data_atualizacao DESC;

-- Sensor vs previsão IPMA (por dia, para o local do sensor)
CREATE VIEW v_sensor_vs_previsao AS
SELECT s.sensor_id, l.nome AS local, date(s.ts) AS dia,
       round(min(s.temperatura),1) AS sensor_t_min,
       round(max(s.temperatura),1) AS sensor_t_max,
       round(avg(s.humidade),1)    AS sensor_hum_media,
       pa.t_min AS ipma_t_min, pa.t_max AS ipma_t_max,
       round(max(s.temperatura) - pa.t_max, 1) AS desvio_t_max
FROM fact_sensor s
JOIN dim_sensor ds ON ds.sensor_id = s.sensor_id
JOIN dim_local l   ON l.id_local = ds.id_local
LEFT JOIN v_previsao_atual pa ON pa.local = l.nome AND pa.data_previsao = date(s.ts)
GROUP BY s.sensor_id, l.nome, date(s.ts), pa.t_min, pa.t_max;

-- Avisos ativos (não verdes) com o nome dos locais da área
CREATE VIEW v_avisos_ativos AS
SELECT a.id_area_aviso, string_agg(DISTINCT l.nome, ', ') AS locais,
       a.tipo, a.nivel, a.nivel_num, a.inicio, a.fim, a.texto
FROM fact_aviso a
LEFT JOIN dim_local l ON l.id_area_aviso = a.id_area_aviso
WHERE a.nivel <> 'green' AND (a.fim IS NULL OR a.fim > now())
GROUP BY a.id, a.id_area_aviso, a.tipo, a.nivel, a.nivel_num, a.inicio, a.fim, a.texto;
