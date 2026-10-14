/*
  ISI TP1 — Monitorização Ambiental
  Arduino Uno + DHT22 (ou DHT11) -> Serial (USB) -> Node-RED -> MQTT

  Ligações:
    DHT VCC  -> 5V
    DHT GND  -> GND
    DHT DATA -> pino 2  (com resistência 10kΩ entre DATA e VCC se não for módulo)
    LED      -> pino 13 (LED da placa) — acende quando o ETL envia um alerta

  Biblioteca: "DHT sensor library" (Adafruit) + "Adafruit Unified Sensor"

  Saída: uma linha JSON por leitura, a cada INTERVALO_MS:
    {"sensor":"ARD-01","seq":12,"temp":22.40,"hum":61.10}
  Se a leitura falhar, o DHT devolve NaN e enviamos "nan" de propósito:
  a limpeza/validação faz parte do processo ETL (fase T), não do Arduino.

  Entrada (vinda do Node-RED): 'A' = alerta (LED ligado), 'N' = normal (LED desligado)
*/

#include <DHT.h>

#define DHTPIN       2
#define DHTTYPE      DHT22     // trocar para DHT11 se for esse o sensor
#define LED_ALERTA   13
#define SENSOR_ID    "ARD-01"
#define INTERVALO_MS 10000UL   // 10 segundos

DHT dht(DHTPIN, DHTTYPE);
unsigned long seq = 0;
unsigned long ultimaLeitura = 0;

void setup() {
  Serial.begin(9600);
  pinMode(LED_ALERTA, OUTPUT);
  digitalWrite(LED_ALERTA, LOW);
  dht.begin();
}

void imprimeValor(float v) {
  if (isnan(v)) Serial.print("\"nan\"");
  else          Serial.print(v, 2);
}

void loop() {
  // comandos vindos do Node-RED (não bloqueia)
  while (Serial.available() > 0) {
    char c = Serial.read();
    if (c == 'A') digitalWrite(LED_ALERTA, HIGH);
    if (c == 'N') digitalWrite(LED_ALERTA, LOW);
  }

  if (millis() - ultimaLeitura >= INTERVALO_MS) {
    ultimaLeitura = millis();
    float t = dht.readTemperature();
    float h = dht.readHumidity();

    Serial.print("{\"sensor\":\"");
    Serial.print(SENSOR_ID);
    Serial.print("\",\"seq\":");
    Serial.print(seq++);
    Serial.print(",\"temp\":");
    imprimeValor(t);
    Serial.print(",\"hum\":");
    imprimeValor(h);
    Serial.println("}");
  }
}
