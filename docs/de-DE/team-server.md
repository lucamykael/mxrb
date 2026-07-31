# Team Server

MXRB verbindet sich ohne `mx`, Studio Pro oder Model SDK direkt mit offiziellen
Team-Server-Git-Repositories und der App Repository API:

```sh
mxrb team-server login --pat-file /secure/team-server.env
mxrb team-server clone APP_ID ./app
mxrb team-server branches APP_ID
mxrb team-server pull ./app
```

Im empfohlenen Modus wird nur der absolute Pfad zur PAT-Datei gespeichert.
Unterstützt werden Klartext, JSON und `.env` mit `MXRB_TEAM_SERVER_PAT`. Der PAT
wird nur für Anfragen gelesen und Git über einen temporären `GIT_ASKPASS`-Helfer
übergeben; er erscheint nie in URLs, Argumenten oder `.git/config`.

Lesen benötigt `mx:modelrepository:repo:read`, Push zusätzlich
`mx:modelrepository:repo:write`. Laut Mendix erhalten externe Klone nicht die
gesamte Studio-Pro-Nachbearbeitung und Revisionsmetadaten. MXRB validiert
MPR-Dateien nach Clone und Pull, kann aber keine Mendix-Cloud-Revisionsmetadaten
erzeugen.

Das Repository `a9e4af8a-2776-4b10-a471-8c42df8f5f43` wurde über die App
Repository API abgefragt und per HTTPS geklont. MXRB validierte
`MyFirstModule.mpr`, erkannte `main` und bestätigte eine Remote-URL ohne PAT.
Die temporäre Zugangsdaten-Datei wurde anschließend zerstört.
