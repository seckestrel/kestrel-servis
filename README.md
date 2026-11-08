<p align="center"><img src="docs/logo.png" width="140" alt="KestrelTech logo"></p>

<h1 align="center">KestrelTech Servis Toolkit</h1>

<p align="center">Servisni alat za Windows 10/11 sa grafickim interfejsom - dijagnostika, popravke, optimizacija, backup i izvjestaj za klijenta na jednom mjestu.</p>

---

## Pokretanje

1. Preuzmi **[Kestrel-Servis_v3.2.zip](https://github.com/seckestrel/kestrel-servis/raw/main/preuzmi/Kestrel-Servis_v3.2.zip)** (alat + LibreHardwareMonitor, spremno za USB).
2. Desni klik na ZIP → **Properties** → oznaci **Unblock** → OK, pa raspakuj (najbolje na USB).
3. Dupli klik na **`Pokreni-Servis.bat`** (trazi Administrator prava).

Alat se sam azurira: pri pokretanju provjeri `verzija.json` u ovom repozitoriju i ponudi novu verziju (sa SHA256 provjerom).

## Mogucnosti

| Oblast | Sta radi |
|---|---|
| **Dijagnostika** | Brzi pregled sistema, SMART i temperature diskova, plavi ekrani sa savjetima, baterija, sigurnosna provjera |
| **Senzori** | Kruzni mjeraci uzivo (CPU, RAM, GPU, disk), sve temperature i ventilatori preko LibreHardwareMonitora, CPU stres test |
| **Optimizacija** | Programi pri pokretanju (ukljuci / iskljuci / obrisi), uklanjanje bloatware-a i reklama u Windowsu |
| **Popravke** | DISM + SFC, CHKDSK, reset Windows Update-a, mreza i Wi-Fi, ciscenje sistema, **domena (Active Directory)** |
| **Backup** | Drajveri, korisnicki podaci, Wi-Fi lozinke i licenca, BitLocker kljucevi, tacka vracanja |
| **Programi** | Svi instalirani programi (64/32-bit, svi korisnici, Store) sa deinstalacijom, winget azuriranje i paketi |
| **Klijent** | Radni nalog sa cjenovnikom (KM), **PDF izvjestaj** sa poredjenjem *prije / poslije* servisa |
| **O alatu** | Provjera azuriranja, prijava greske, paket za testere |

## Za testere

Procitaj **[TESTIRANJE.txt](TESTIRANJE.txt)**. Greske prijavljuj preko *O ALATU → Prijavi gresku* (ZIP ne sadrzi lozinke ni podatke klijenata) ili ovdje kroz **[Issues](../../issues)**.

## Temperature (opcionalno)

Za tacne temperature procesora i grafike raspakuj [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/releases) (`LibreHardwareMonitor.zip`) u `Alati\LibreHardwareMonitor`.

## Zahtjevi

Windows 10 ili 11, Windows PowerShell 5.1 (dolazi uz Windows), administratorska prava.

---

<p align="center">© KestrelTech</p>
