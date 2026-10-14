#!/usr/bin/env python3
"""
Testa as APIs usadas no projeto e guarda uma amostra de cada resposta em data/amostras/.
Só usa a biblioteca padrão do Python.  Correr na pasta do projeto:

    python3 scripts/testar_apis.py
"""
import json
import pathlib
import ssl
import urllib.request

# Usa os certificados do pacote "certifi" se estiver instalado
# (resolve o erro CERTIFICATE_VERIFY_FAILED em alguns Python do macOS).
try:
    import certifi
    CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    CTX = ssl.create_default_context()

PASTA = pathlib.Path(__file__).resolve().parent.parent / "data" / "amostras"
PASTA.mkdir(parents=True, exist_ok=True)

APIS = {
    "ipma_previsao_braga": "https://api.ipma.pt/open-data/forecast/meteorology/cities/daily/1030300.json",
    "ipma_previsao_porto": "https://api.ipma.pt/open-data/forecast/meteorology/cities/daily/1131200.json",
    "ipma_previsao_lisboa": "https://api.ipma.pt/open-data/forecast/meteorology/cities/daily/1110600.json",
    "openmeteo_previsao_barcelos": (
        "https://api.open-meteo.com/v1/forecast?latitude=41.5388&longitude=-8.6151"
        "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,"
        "wind_speed_10m_max,wind_direction_10m_dominant,weather_code&timezone=Europe%2FLisbon&forecast_days=5"
    ),
    "ipma_avisos": "https://api.ipma.pt/open-data/forecast/warnings/warnings_www.json",
    "ipma_estados_tempo": "https://api.ipma.pt/open-data/weather-type-classe.json",
    "ipma_classes_vento": "https://api.ipma.pt/open-data/wind-speed-daily-classe.json",
    "ipma_locais": "https://api.ipma.pt/open-data/distrits-islands.json",
    "openmeteo_qualidade_ar_braga": (
        "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=41.5475&longitude=-8.4227"
        "&hourly=pm10,pm2_5,nitrogen_dioxide,ozone&timezone=Europe%2FLisbon&past_days=1&forecast_days=1"
    ),
}


def resumo(nome, dados):
    if isinstance(dados, list):
        return f"array com {len(dados)} elementos; campos: {list(dados[0].keys()) if dados else '-'}"
    if "data" in dados and isinstance(dados["data"], list):
        return f"{len(dados['data'])} registos em 'data'; campos: {list(dados['data'][0].keys())}"
    if "daily" in dados:
        d = dados["daily"]
        return f"{len(d['time'])} dias; variáveis: {[k for k in d if k != 'time']}"
    if "hourly" in dados:
        h = dados["hourly"]
        return f"{len(h['time'])} horas; variáveis: {[k for k in h if k != 'time']}; unidades: {dados.get('hourly_units')}"
    return f"chaves: {list(dados.keys())}"


falhas = 0
for nome, url in APIS.items():
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "ISI-TP1-IPCA"})
        with urllib.request.urlopen(req, timeout=20, context=CTX) as r:
            dados = json.loads(r.read().decode("utf-8"))
        (PASTA / f"{nome}.json").write_text(json.dumps(dados, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"OK    {nome}: {resumo(nome, dados)}")
    except Exception as e:  # noqa: BLE001
        falhas += 1
        print(f"FALHA {nome}: {e}")

print(f"\n{len(APIS) - falhas}/{len(APIS)} APIs OK. Amostras em {PASTA}")
