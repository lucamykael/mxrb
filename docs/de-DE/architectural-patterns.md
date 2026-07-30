# Architekturmuster

[Português](../pt-BR/architectural-patterns.md) · [English](../en-US/architectural-patterns.md) · **Deutsch**

MXRB verwendet Ruby als einzige öffentliche Modellschnittstelle und ordnet
Verantwortungen Domäne, Anwendung, Präsentation und Infrastruktur zu.

```text
Präsentation ─┐
              ├─> Anwendung ─> Domäne
Infrastruktur ┘
```

Entitäten und Regeln halten Geschäftszustand. Microflows sind Anwendungsfälle,
wenn sie diesen Zustand koordinieren. Seiten, Navigation und Nanoflows gehören
zur Präsentation; HTTP, externe Datenbanken, Java und Integrationen zur
Infrastruktur.

Repositories sind an echten externen Grenzen sinnvoll, nicht als Zeremonie um
gewöhnliches Mendix-CRUD. Aufrufe und Abhängigkeiten bleiben im semantischen
Graph sichtbar und können am tatsächlichen Modell geprüft werden.

Security, Navigation und Design System sind Querschnittsrichtlinien unter
`app/`. Deklarierte Navigation wird zusätzlich nativ in Mendix geschrieben.

[Zurück zum Index](README.md)
