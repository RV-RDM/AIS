# AIS
Check System for AIS

[AIS-Systemcheck herunterladen](https://raw.githubusercontent.com/RV-RDM/AIS/main/scripts/AIS.ps1)

Nach jeder einzelnen Aufgabe und nach „Alle Aufgaben ausfuehren“ kehrt das Skript zur Auswahl zurueck. Erst mit „Q“ wird der Gesamtbericht abgeschlossen und das Oeffnen im Editor angeboten.

Beim Start zeigt das Skript gefundene `local.ini`-Dateien unter `C:\CGM\albiswin` und `C:\albiswin` sowie den jeweiligen `Main=`-Serverpfad an. Danach werden die zusammengefassten Startpruefungen (bisherige Aufgaben 5, 6, 7, 9, 11, 12 und 28) einmal automatisch ausgefuehrt. Sie bleiben als gemeinsamer Menuepunkt verfuegbar. Die Menuepunkte werden fortlaufend nummeriert.

„ALBIS-Registry-Sicherung“ exportiert nur `HKCU\Software\ALBIS`. „ALBIS-Dateien als ZIP sichern“ erstellt unter `C:\CGM` ein neues, zeitgestempeltes ZIP mit den gefundenen `local.ini`-Dateien und den jeweiligen `albisglb.ini`-Dateien. Die ZIP-Eintraege behalten ihre Installations-Unterordner; vorhandene Archive werden nicht ueberschrieben.
