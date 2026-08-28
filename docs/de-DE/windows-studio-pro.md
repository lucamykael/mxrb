# Windows- und Studio-Pro-Validierung mit Omarchy

Geprüft am 12. August 2026: AMD-V und KVM sind verfügbar. Omarchy stellt
folgenden Befehl bereit:

```bash
omarchy windows vm install
```

Der Standard-Installer verwendet `dockurr/windows`, RDP und `~/Windows` und
benötigt 74 GB freien Speicher. Auf dem Root-Dateisystem waren 60 GB frei;
deshalb wurde keine VM installiert. Die sekundäre ext4-SSD hatte 435 GB frei,
wurde nur lesend geprüft und unverändert ausgehängt. Fortfahren darf man erst,
nachdem mindestens 14 GB auf Root freigegeben oder ein beschreibbares VM-Ziel
auf der sekundären SSD ausdrücklich bestätigt wurde.

Nach Klärung des Speicherplatzes:

```bash
omarchy windows vm install
omarchy windows vm status
omarchy windows vm start
```

In Studio Pro eine Kopie mit derselben Version öffnen, das App Directory
synchronisieren, Domain-Regeln, Seiten, Navigation, Microflows und Nanoflows
prüfen und anschließend Seite → Nanoflow → Microflow → sichtbares Ergebnis
testen. Die GUI-Prüfung ergänzt die Linux-, Docker-, TypeScript-, Chromium- und
`mxbuild`-Gates, ersetzt sie aber nicht.
