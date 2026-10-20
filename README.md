# MiniNote — un blocco note completo in 2560 byte

> *Immaginate un Windows che già contiene tutto il necessario per creare finestre, colori ecc...
> togliete un po' di schifezze e con un linguaggio VELOCE...*

Questo è il risultato: un **blocco note vero** per Windows, scritto in **assembly x86**, che compilato pesa **2560 byte**. Sono 2,5 KB in tutto: meno di questa pagina di testo, meno di un'icona.

Non usa runtime, framework, motori web o installer. È un solo `.exe` che parla direttamente con Windows. Tutto il necessario, cioè finestre, menu, controllo di testo, dialoghi Apri/Salva e font, **è già dentro il sistema operativo**. Basta chiederlo senza strati in mezzo.

Per confronto, molte app "moderne" per mostrare una finestra di testo si portano dietro un browser intero e occupano **centinaia di megabyte**.

## Cosa sa fare

- **File:** Nuovo (Ctrl+N), Apri (Ctrl+O), Salva (Ctrl+S), Salva con nome (Ctrl+Maiusc+S), Esci
- **Modifica:** Annulla, Taglia, Copia, Incolla, Seleziona tutto (Ctrl+A), più il menu col tasto destro
- Chiede **se salvare le modifiche** prima di chiudere o cambiare file
- Apre il file passato da riga di comando ("Apri con...") o **trascinato** sulla finestra
- **UTF-8** in lettura e scrittura: accenti, €, 日本, emoji 😀. Il BOM viene riconosciuto e i file ANSI hanno un ripiego
- I fine riga Unix (LF) diventano CRLF, nessun limite di 32 KB, font Consolas
- Si avvia all'istante e usa pochi MB di RAM

## Compilazione

Serve solo [NASM](https://www.nasm.us/), senza linker:

```
nasm -f bin mininote.asm -o mininote.exe
```

Su Windows NASM si installa con `scoop install nasm`. L'eseguibile già compilato è incluso nel repository.

## "Windows ha protetto il PC": perché compare e perché è normale

Al primo avvio di `mininote.exe` scaricato da GitHub, Windows può mostrare la schermata blu di **Microsoft Defender SmartScreen**. **Non vuol dire che sia stato trovato un virus.** SmartScreen non analizza cosa fa il programma, valuta la sua **reputazione**:

- **Il file non è firmato.** Una firma digitale (code signing) costa da qualche centinaio di euro all'anno in su ed è pensata per le aziende, non per un esperimento da 2,5 KB
- **Il file è nuovo e poco scaricato.** SmartScreen si fida dei programmi che migliaia di persone hanno già eseguito senza problemi. Un exe appena pubblicato parte da zero, anche se firmato
- **Il file arriva da Internet.** Il browser lo segna come "scaricato dal web" (Mark of the Web), e questo fa scattare il controllo

Per avviarlo comunque: clicca **"Ulteriori informazioni"**, poi **"Esegui comunque"**. Basta farlo una volta.

Se preferisci non fidarti dell'exe (ed è giusto chiederselo), hai due alternative:

- **Compilalo tu.** Il sorgente è tutto qui, leggibile e commentato. Con NASM ottieni lo stesso file da 2560 byte, e un exe compilato sul tuo PC non ha il segno "scaricato dal web", quindi SmartScreen non interviene
- **Controllalo.** Puoi caricarlo su [VirusTotal](https://www.virustotal.com/), oppure togliere il segno di provenienza con *tasto destro → Proprietà → Sblocca*, dopo esserti fidato

Qualche antivirus potrebbe anche segnalarlo per **euristica**: un eseguibile così piccolo, con l'header scritto a mano e le funzioni risolte a runtime, somiglia per forma ai trucchi usati dai malware compressi. È un falso positivo tipico dei programmi in assembly "sizecoding". Il codice fa solo quello che vedi nel sorgente: apre e salva i file di testo che scegli tu.

## Come ci sta in 2,5 KB

- **Header PE scritto a mano** nel sorgente, byte per byte
- **Tabella import minima:** contiene solo `LoadLibraryA` e `GetProcAddress`. Le altre 32 API di Windows vengono risolte all'avvio da una lista compatta di nomi
- **Chiamate da 3 byte:** i puntatori alle API e le variabili stanno attorno al registro EBX, così ogni chiamata è `call [ebx+disp8]` invece dei soliti 6 byte
- **Header riciclato:** l'optional header ha solo 2 data directory. Nei byte liberi dell'header stanno i dati in sola lettura: stringhe, scorciatoie, classe della finestra e nomi delle funzioni
- **Il sistema fa il lavoro:** editing, scrolling, appunti e annulla li gestisce il controllo `EDIT` di Windows

Una nota per chi vuole provarci: il loader di Windows 11 **ignora la tabella import se il descrittore sta dentro l'header**. Il programma parte, ma nessuna funzione viene collegata e crasha subito. Il descrittore deve stare in una sezione; i nomi invece possono restare nell'header.

## Limiti

È un esercizio di essenzialità, non un sostituto completo: niente a capo automatico, Trova/Sostituisci, stampa o barra di stato. È un programma a 32 bit e gira su Windows 64 bit tramite WOW64.

---

Scritto con [Claude Code](https://claude.com/claude-code), partendo da una domanda semplice: *"si può fare un Notepad che compilato non superi 2,5 KB?"*
