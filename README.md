<img src="assets/icon.svg" width="64" height="64" alt="">

# Window Manager

Version 0.1.0

Kleine Menüleisten-App für macOS: Du legst fest, welche App auf welchem Bildschirm landet. Sobald Monitore (auch über DisplayLink) angesteckt werden, schiebt sie die Fenster automatisch dorthin.

## Bauen & installieren

```sh
./build.sh install     # baut, kopiert nach /Applications und startet
swift test             # Unit-Tests (Fenster-Zuordnung, Datenformat)
```

Beim ersten Start fragt macOS nach dem **Bedienungshilfen-Zugriff** (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen). Den braucht die App zum Verschieben der Fenster.

> Ohne Entwickler-Zertifikat wird ad-hoc signiert, dann fragt macOS nach jedem Neubau wieder nach der Berechtigung. Mit einem festen Zertifikat ist das weg:
> `CODESIGN_IDENTITY="Apple Development: Dein Name (XXXX)" ./build.sh install`

## Benutzung

1. Fenster so anordnen, wie du sie haben willst.
2. Menüleiste → **Aktuelle Anordnung speichern → Als neues Layout…** → Namen eingeben (z. B. „Büro“, „Meeting“).
3. Für weitere Situationen wiederholen. Jedes Layout merkt sich pro App den Bildschirm und die genaue Fensterposition.
4. In **Einstellungen…** den Bildschirmen Namen geben (**Identifizieren** zeigt, welcher welcher ist) und pro App die Platzierung anpassen (gespeicherte Position, Position beibehalten, Maximieren, linke/rechte Hälfte, Zentrieren).
5. **Beim Anmelden starten** einschalten.

Layout anwenden: in der Menüleiste anklicken oder **⌃⌥⌘1 … 9** (Reihenfolge wie in den Einstellungen). Das zuletzt angewendete Layout ist das *aktive*. Es wird automatisch angewendet, wenn Bildschirme angesteckt werden, der Mac aufwacht oder eine App startet. **⌃⌥⌘W** wendet es erneut an.

### Mehrere Fenster einer App (z. B. zwei Browserfenster)

Jedes Fenster wird einzeln gespeichert, mit eigenem Bildschirm und eigener Position. In den Einstellungen erscheint es als eigene Zeile unter der App. Beim Anwenden wird jedes Fenster so wiedererkannt:

1. über die **Fensternummer** von macOS. Die bleibt gleich, solange das Fenster offen ist, also auch beim Ab- und Anstecken am Dock.
2. über **„Titel enthält …“**, falls du das ausgefüllt hast (z. B. „sellerboard“). Nützlich nach einem Neustart des Browsers, weil die Fensternummern dann neu sind.
3. über den **gleichen Titel** wie beim Speichern.
4. sonst über die **Reihenfolge**.

Wird ein Fenster über 2–4 gefunden, merkt sich die App seine neue Nummer. Zusätzliche Fenster, die nicht im Layout sind, kommen auf den Hauptbildschirm der App.

Wird beim Speichern der Name eines vorhandenen Layouts eingegeben (oder **„In „…“ übernehmen“** gewählt), wird dieses überschrieben: Für jede offene App werden Bildschirme, Fensterpositionen und Platzierung („Gespeicherte Position“) neu gesetzt. Erhalten bleiben nur Ein/Aus und die „Titel enthält …“-Filter. Apps, die gerade nicht laufen, bleiben im Layout.

## Wie es funktioniert

- Bildschirme werden über **Hersteller-, Modell- und Seriennummer** erkannt, nicht über die Display-ID, die DisplayLink bei jedem Anstecken neu vergibt. So bleiben drei gleiche Monitore unterscheidbar.
- Nach einer Bildschirmänderung wartet die App eine einstellbare Zeit (Standard 3 s), weil DisplayLink-Monitore schrittweise hochkommen und macOS danach selbst noch Fenster verschiebt.
- Verschoben wird über die Accessibility-API (`AXUIElement`). Die Fensternummer kommt aus der privaten, aber seit Jahren stabilen Funktion `_AXUIElementGetWindow`, die auch Rectangle, yabai & Co. nutzen. Minimierte Fenster, Fenster im Vollbildmodus und Fenster auf anderen Spaces werden ignoriert.

## Lizenz

[MIT](LICENSE) © 2026 Nils Rosemann
